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

const ABSENT: i32 = 3;

pub fn session_exec(args: &[String]) -> Result<i32, String> {
    let separator = args.iter().position(|arg| arg == "--").ok_or_else(|| {
        "usage: tightbeam harness-exec <identity-path> -- <command> [args...]".to_string()
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
    if args.len() != 5 || !matches!(args[0].as_str(), "status" | "kill") {
        return Err(
            "usage: tightbeam harness-group <status|kill> <process-group-id> <identity-path> <boot-identity> <launch-id>"
                .into(),
        );
    }

    let pgid: libc::pid_t = args[1]
        .parse::<i32>()
        .ok()
        .filter(|pgid| *pgid > 0)
        .ok_or_else(|| "process group id must be a positive integer".to_string())?;

    if boot_identity()? != args[3]
        || !identity_lock_held(Path::new(&args[2]), pgid, &args[3], &args[4])?
    {
        return Ok(ABSENT);
    }

    if unsafe { libc::getpgid(pgid) } != pgid {
        return Ok(ABSENT);
    }

    // Status and termination share this identity check in one helper invocation.
    // POSIX has no conditional killpg primitive, so a group that exits and is
    // recycled between the check above and this syscall remains the irreducible
    // check-to-act window.
    let signal = if args[0] == "status" {
        0
    } else {
        libc::SIGKILL
    };
    let result = unsafe { libc::killpg(pgid, signal) };

    if result == 0 {
        return Ok(0);
    }

    let error = std::io::Error::last_os_error();

    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(ABSENT)
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

fn identity_lock_held(
    path: &Path,
    pgid: libc::pid_t,
    boot_identity: &str,
    launch_id: &str,
) -> Result<bool, String> {
    let identity = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|error| format!("harness identity could not be opened: {error}"))?;

    let lock_result = unsafe { libc::flock(identity.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if lock_result == 0 {
        let _ = unsafe { libc::flock(identity.as_raw_fd(), libc::LOCK_UN) };
        return Ok(false);
    }

    let error = std::io::Error::last_os_error();
    if error.raw_os_error() != Some(libc::EWOULDBLOCK) {
        return Err(format!(
            "harness identity lock could not be checked: {error}"
        ));
    }

    let recorded = fs::read_to_string(path)
        .map_err(|error| format!("harness identity could not be read: {error}"))?;
    Ok(recorded.trim_end() == format!("{pgid}\t{pgid}\t{boot_identity}\t{launch_id}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_rejects_non_positive_ids() {
        assert!(
            group(&[
                "status".into(),
                "0".into(),
                "identity".into(),
                "boot".into(),
                "start".into()
            ])
            .is_err()
        );
        assert!(
            group(&[
                "kill".into(),
                "-1".into(),
                "identity".into(),
                "boot".into(),
                "start".into()
            ])
            .is_err()
        );
    }
}
