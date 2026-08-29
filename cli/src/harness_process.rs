use std::fs;
use std::fs::OpenOptions;
use std::io::{Read, Write};
#[cfg(target_os = "macos")]
use std::os::darwin::fs::MetadataExt as DarwinMetadataExt;
#[cfg(target_os = "macos")]
use std::os::unix::fs::MetadataExt as UnixMetadataExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

pub fn session_exec(args: &[String]) -> Result<i32, String> {
    session_exec_with_mode(args, 0o600)
}

pub fn cursor_session_exec(args: &[String]) -> Result<i32, String> {
    session_exec_with_mode(args, 0o640)
}

fn session_exec_with_mode(args: &[String], identity_mode: u32) -> Result<i32, String> {
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
        .create_new(true)
        .write(true)
        .mode(identity_mode)
        .open(identity_path)
        .map_err(|error| format!("harness identity could not be opened: {error}"))?;

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

pub fn print_boot_identity() -> Result<(), String> {
    println!("{}", boot_identity()?);
    Ok(())
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

    classify_group_kill(pgid, std::io::Error::last_os_error())
}

/// A group that is already gone is a success, and darwin says so differently.
///
/// linux answers ESRCH when nothing in the group can be signalled. macOS answers EPERM once
/// the group's members have all exited -- the group id still resolves, but there is nothing
/// live in it to own. Treating that as a failure turns "already dead" into "could not kill",
/// which is what it did: a live onboarding aborted with
/// `kill_failed: process group 62968 could not be signalled: Operation not permitted`
/// against a group that `kill -0` reported as no such process.
///
/// EPERM is only read this way AFTER `authorize_group_signal` has established the group is
/// ours by identity and boot epoch. Without that check EPERM would be ambiguous with
/// somebody else's group, which is exactly what it means on linux and why this is
/// darwin-only. `child_process.rs` already carries the same guard for the same reason; this
/// is the one place that knew the fact in only one language.
fn classify_group_kill(pgid: libc::pid_t, error: std::io::Error) -> Result<i32, String> {
    let gone = error.raw_os_error() == Some(libc::ESRCH)
        || (cfg!(target_os = "macos") && error.raw_os_error() == Some(libc::EPERM));

    if gone {
        Ok(0)
    } else {
        Err(format!(
            "process group {pgid} could not be signalled: {error}"
        ))
    }
}

#[cfg(test)]
mod group_kill_tests {
    use super::classify_group_kill;
    use std::io::Error;

    /// linux's answer for "nothing here to signal".
    #[test]
    fn esrch_is_already_gone_on_every_platform() {
        assert!(classify_group_kill(1234, Error::from_raw_os_error(libc::ESRCH)).is_ok());
    }

    /// darwin's answer for the same state. Read as a failure it aborted a live onboarding
    /// against a group `kill -0` reported as no such process.
    #[test]
    #[cfg(target_os = "macos")]
    fn eperm_is_already_gone_on_darwin() {
        assert!(classify_group_kill(1234, Error::from_raw_os_error(libc::EPERM)).is_ok());
    }

    /// On linux EPERM means somebody else's group, which must stay an error -- the darwin
    /// reading is not portable and must not leak across.
    #[test]
    #[cfg(target_os = "linux")]
    fn eperm_is_still_a_refusal_on_linux() {
        assert!(classify_group_kill(1234, Error::from_raw_os_error(libc::EPERM)).is_err());
    }

    /// Anything else is a real failure and must name itself.
    #[test]
    fn an_unexpected_errno_is_reported_with_the_group() {
        let error = classify_group_kill(4321, Error::from_raw_os_error(libc::EINVAL)).unwrap_err();
        assert!(error.contains("4321"), "{error}");
        assert!(error.contains("could not be signalled"), "{error}");
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

    let mut identity = OpenOptions::new()
        .read(true)
        .open(path)
        .map_err(|error| format!("harness identity could not be opened: {error}"))?;

    let mut recorded = String::new();
    identity
        .read_to_string(&mut recorded)
        .map_err(|error| format!("harness identity could not be read: {error}"))?;
    if recorded.trim_end() != format!("{pgid}\t{pgid}\t{expected_boot_identity}\t{launch_id}") {
        return Err("harness identity does not match the requested process group".into());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn test_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "tightbeam-harness-process-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

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

    #[test]
    fn session_exec_refuses_a_pre_existing_identity_file() {
        let path = test_path("existing");
        fs::write(&path, "existing identity").unwrap();

        let result = session_exec(&[
            path.to_string_lossy().into_owned(),
            "launch".into(),
            "--".into(),
            "unused".into(),
        ]);

        assert!(matches!(
            result,
            Err(ref reason) if reason.starts_with("harness identity could not be opened:")
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "existing identity");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn session_exec_refuses_an_identity_symlink() {
        let target = test_path("symlink-target");
        let path = test_path("symlink");
        fs::write(&target, "target identity").unwrap();
        symlink(&target, &path).unwrap();

        let result = session_exec(&[
            path.to_string_lossy().into_owned(),
            "launch".into(),
            "--".into(),
            "unused".into(),
        ]);

        assert!(matches!(
            result,
            Err(ref reason) if reason.starts_with("harness identity could not be opened:")
        ));
        assert_eq!(fs::read_to_string(&target).unwrap(), "target identity");
        fs::remove_file(path).unwrap();
        fs::remove_file(target).unwrap();
    }
}
