use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
#[cfg(target_os = "macos")]
use std::os::darwin::fs::MetadataExt as DarwinMetadataExt;
#[cfg(target_os = "macos")]
use std::os::unix::fs::MetadataExt as UnixMetadataExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

pub fn session_exec(args: &[String]) -> Result<i32, String> {
    let separator = args.iter().position(|arg| arg == "--").ok_or_else(|| {
        "usage: tightbeam harness-exec <identity-path> <launch-id> -- <command> [args...]"
            .to_string()
    })?;

    if separator != 2 || args.len() <= separator + 1 {
        return Err(
            "usage: tightbeam harness-exec <identity-path> <launch-id> -- <command> [args...]"
                .into(),
        );
    }

    let identity_path = Path::new(&args[0]);

    if let Some(parent) = identity_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("harness identity directory could not be created: {error}"))?;
    }

    let mut identity = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(identity_path)
        .map_err(|error| format!("harness identity could not be opened: {error}"))?;

    if unsafe { libc::flock(identity.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(format!(
            "harness identity lock could not be acquired: {}",
            std::io::Error::last_os_error()
        ));
    }

    if unsafe { libc::fcntl(identity.as_raw_fd(), libc::F_SETFD, 0) } == -1 {
        return Err(format!(
            "harness identity lock could not cross exec: {}",
            std::io::Error::last_os_error()
        ));
    }

    match unsafe { libc::fork() } {
        -1 => {
            return Err(format!(
                "harness session launcher could not fork: {}",
                std::io::Error::last_os_error()
            ));
        }
        0 => {}
        child => return wait_for_session_child(child),
    }

    if unsafe { libc::setsid() } == -1 {
        return Err(format!(
            "harness session could not be created: {}",
            std::io::Error::last_os_error()
        ));
    }

    let pid = unsafe { libc::getpid() };
    let pgid = unsafe { libc::getpgrp() };

    if pid != pgid {
        return Err(format!(
            "harness session leader mismatch: pid {pid}, process group {pgid}"
        ));
    }

    let boot_identity = boot_identity()?;
    let launch_id = &args[1];

    writeln!(identity, "{pid}\t{pgid}\t{boot_identity}\t{launch_id}")
        .and_then(|_| identity.sync_all())
        .map_err(|error| format!("harness identity could not be written: {error}"))?;

    let error = Command::new(&args[separator + 1])
        .args(&args[separator + 2..])
        .exec();

    Err(format!("harness command could not be executed: {error}"))
}

fn wait_for_session_child(child: libc::pid_t) -> Result<i32, String> {
    let mut status = 0;

    loop {
        let waited = unsafe { libc::waitpid(child, &mut status, 0) };

        if waited == child {
            if libc::WIFEXITED(status) {
                return Ok(libc::WEXITSTATUS(status));
            }

            if libc::WIFSIGNALED(status) {
                return Ok(128 + libc::WTERMSIG(status));
            }

            return Err("harness session child ended without an exit status".into());
        }

        let error = std::io::Error::last_os_error();

        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(format!(
                "harness session child could not be waited: {error}"
            ));
        }
    }
}

pub fn group(args: &[String]) -> Result<i32, String> {
    if args.len() != 4 {
        return Err(
            "usage: tightbeam harness-group <process-group-id> <identity-path> <boot-identity> <launch-id>"
                .into(),
        );
    }

    let pgid: libc::pid_t = args[0]
        .parse::<i32>()
        .ok()
        .filter(|pgid| *pgid > 0)
        .ok_or_else(|| "process group id must be a positive integer".to_string())?;

    authorize_group_signal(Path::new(&args[1]), pgid, &args[2], &args[3])?;

    let result = unsafe { libc::killpg(pgid, libc::SIGKILL) };

    if result == 0 {
        return Ok(0);
    }

    let error = std::io::Error::last_os_error();

    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(0)
    } else {
        Err(format!(
            "process group {pgid} could not be signalled: {error}"
        ))
    }
}

#[cfg(target_os = "linux")]
fn boot_identity() -> Result<String, String> {
    fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|value| value.trim().to_owned())
        .map_err(|error| format!("kernel boot identity unavailable: {error}"))
}

#[cfg(target_os = "macos")]
fn boot_identity() -> Result<String, String> {
    let metadata = fs::metadata("/var/run/com.apple.logind.didRunThisBoot")
        .map_err(|error| format!("boot marker unavailable: {error}"))?;
    Ok(format!(
        "logind-this-boot:{}:{}:{}",
        metadata.dev(),
        metadata.ino(),
        metadata.st_birthtime()
    ))
}

fn authorize_group_signal(
    path: &Path,
    pgid: libc::pid_t,
    expected_boot_identity: &str,
    launch_id: &str,
) -> Result<(), String> {
    if boot_identity()? != expected_boot_identity {
        return Err("harness boot identity does not match the current boot".into());
    }

    let identity = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|error| format!("harness identity could not be opened: {error}"))?;

    let lock_result = unsafe { libc::flock(identity.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if lock_result == 0 {
        let _ = unsafe { libc::flock(identity.as_raw_fd(), libc::LOCK_UN) };
        return Err("harness identity lock is not held".into());
    }

    let error = std::io::Error::last_os_error();
    if error.raw_os_error() != Some(libc::EWOULDBLOCK) {
        return Err(format!(
            "harness identity lock could not be checked: {error}"
        ));
    }

    let recorded = fs::read_to_string(path)
        .map_err(|error| format!("harness identity could not be read: {error}"))?;
    if recorded.trim_end() != format!("{pgid}\t{pgid}\t{expected_boot_identity}\t{launch_id}") {
        return Err("harness identity does not match the requested process group".into());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_rejects_non_positive_ids() {
        assert!(
            group(&[
                "0".into(),
                "identity".into(),
                "boot".into(),
                "launch".into()
            ])
            .is_err()
        );
        assert!(
            group(&[
                "-1".into(),
                "identity".into(),
                "boot".into(),
                "launch".into()
            ])
            .is_err()
        );
    }

    #[test]
    fn group_refuses_a_different_boot_before_signalling() {
        let pgid = unsafe { libc::getpgrp() };

        assert_eq!(
            group(&[
                pgid.to_string(),
                "/identity/path/that/does/not/exist".into(),
                "wrong-boot".into(),
                "wrong-launch".into()
            ]),
            Err("harness boot identity does not match the current boot".into())
        );
    }
}
