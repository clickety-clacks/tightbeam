use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

pub fn session_exec(args: &[String]) -> Result<i32, String> {
    let separator = args.iter().position(|arg| arg == "--").ok_or_else(|| {
        "usage: tightbeam harness-exec <identity-path> -- <command> [args...]".to_string()
    })?;

    if separator != 1 || args.len() <= separator + 1 {
        return Err("usage: tightbeam harness-exec <identity-path> -- <command> [args...]".into());
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

    writeln!(identity, "{pgid}")
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
    if args.len() != 1 {
        return Err("usage: tightbeam harness-group <process-group-id>".into());
    }

    let pgid: libc::pid_t = args[0]
        .parse::<i32>()
        .ok()
        .filter(|pgid| *pgid > 0)
        .ok_or_else(|| "process group id must be a positive integer".to_string())?;

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_rejects_non_positive_ids() {
        assert!(group(&["0".into()]).is_err());
        assert!(group(&["-1".into()]).is_err());
    }
}
