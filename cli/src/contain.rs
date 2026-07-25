use std::io::{self, BufRead, Read, Write};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const PASS: i32 = 0;
const SCRIPT_ERROR: i32 = 10;
const SCRIPT_TIMEOUT: i32 = 20;
const CONTAINED_REFUSED: i32 = 30;

struct RailExecArgs {
    profile: String,
    timeout: Duration,
    script: String,
}

pub fn rail_exec(args: &[String]) -> Result<i32, String> {
    let args = parse(args)?;
    Ok(run(args))
}

fn parse(args: &[String]) -> Result<RailExecArgs, String> {
    if args.len() != 6 || args[0] != "--profile" || args[2] != "--timeout-ms" || args[4] != "--" {
        return Err(
            "usage: tightbeam rail-exec --profile <SBPL> --timeout-ms <N> -- <script-path>"
                .to_owned(),
        );
    }

    let timeout_ms = args[3]
        .parse::<u64>()
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| "--timeout-ms must be a positive integer".to_owned())?;

    if args[1].is_empty() || args[5].is_empty() {
        return Err("--profile and script-path must be non-empty".to_owned());
    }

    Ok(RailExecArgs {
        profile: args[1].clone(),
        timeout: Duration::from_millis(timeout_ms),
        script: args[5].clone(),
    })
}

fn run(args: RailExecArgs) -> i32 {
    let mut input = Vec::new();
    if io::stdin().lock().read_until(b'\n', &mut input).is_err() {
        return SCRIPT_ERROR;
    }

    run_with_input(args, input)
}

fn run_with_input(args: RailExecArgs, input: Vec<u8>) -> i32 {
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .arg("-p")
        .arg(&args.profile)
        .arg("--")
        .arg(&args.script)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }

            libc::signal(libc::SIGPIPE, libc::SIG_DFL);
            libc::signal(libc::SIGINT, libc::SIG_DFL);
            libc::signal(libc::SIGTERM, libc::SIG_DFL);
            Ok(())
        });
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!("sandbox-exec: {error}");
            return CONTAINED_REFUSED;
        }
    };

    let mut child_stdin = child.stdin.take().expect("piped child stdin");
    let stdin_writer = thread::spawn(move || {
        let result = child_stdin.write_all(&input);
        drop(child_stdin);
        result
    });

    let mut child_stdout = child.stdout.take().expect("piped child stdout");
    let stdout_reader = thread::spawn(move || {
        let mut output = Vec::new();
        child_stdout.read_to_end(&mut output).map(|_| output)
    });

    let mut child_stderr = child.stderr.take().expect("piped child stderr");
    let stderr_reader = thread::spawn(move || {
        let mut output = Vec::new();
        child_stderr.read_to_end(&mut output).map(|_| output)
    });

    let started = Instant::now();
    let mut status = None;
    let timed_out = loop {
        if status.is_none() {
            match child.try_wait() {
                Ok(Some(child_status)) => status = Some(child_status),
                Ok(None) => {}
                Err(error) => {
                    eprintln!("rail-exec wait failed: {error}");
                    let pgid = child.id() as libc::pid_t;
                    unsafe {
                        libc::killpg(pgid, libc::SIGKILL);
                    }
                    let _ = child.wait();
                    return SCRIPT_ERROR;
                }
            }
        }

        if status.is_some()
            && stdin_writer.is_finished()
            && stdout_reader.is_finished()
            && stderr_reader.is_finished()
        {
            break false;
        }

        if started.elapsed() >= args.timeout {
            let pgid = child.id() as libc::pid_t;
            unsafe {
                // killpg sends SIGKILL to every process in the child's process group.
                libc::killpg(pgid, libc::SIGKILL);
            }

            if status.is_none() {
                let _ = child.wait();
            }

            break true;
        }

        thread::sleep(Duration::from_millis(2));
    };

    if timed_out {
        drop(stdin_writer);
        drop(stdout_reader);
        drop(stderr_reader);
        return SCRIPT_TIMEOUT;
    }

    let stdin_delivered = matches!(stdin_writer.join(), Ok(Ok(())));
    let stdout = stdout_reader
        .join()
        .ok()
        .and_then(Result::ok)
        .unwrap_or_default();
    let stderr = stderr_reader
        .join()
        .ok()
        .and_then(Result::ok)
        .unwrap_or_default();

    let _ = io::stderr().write_all(&stderr);

    if !stdin_delivered {
        eprintln!("tightbeam rail-exec child exit: 1");
        return SCRIPT_ERROR;
    }

    let status = status.expect("child status present when pipe workers finish");

    if status.success() {
        let _ = io::stdout().write_all(&stdout);
        return PASS;
    }

    if profile_apply_failed(status.code(), &stdout, &stderr) {
        return CONTAINED_REFUSED;
    }

    let child_code = status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(1);
    eprintln!("tightbeam rail-exec child exit: {child_code}");
    SCRIPT_ERROR
}

fn profile_apply_failed(code: Option<i32>, stdout: &[u8], stderr: &[u8]) -> bool {
    code == Some(65) && stdout.is_empty() && stderr.starts_with(b"sandbox-exec:")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(1);

    fn temp_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-rail-exec-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn script(dir: &Path, name: &str, body: &str) -> String {
        let path = dir.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn permissive_profile() -> String {
        "(version 1)\n(allow default)".to_owned()
    }

    #[test]
    fn parses_the_pinned_form() {
        let parsed = parse(&[
            "--profile".into(),
            "profile".into(),
            "--timeout-ms".into(),
            "25".into(),
            "--".into(),
            "/tmp/check".into(),
        ])
        .unwrap();
        assert_eq!(parsed.timeout, Duration::from_millis(25));
        assert_eq!(parsed.script, "/tmp/check");
    }

    #[test]
    fn successful_child_preserves_stdout_and_has_the_pass_band() {
        let dir = temp_dir();
        let check = script(&dir, "passes", "echo pass");
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_secs(1),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, PASS);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn profile_apply_failure_has_its_own_band() {
        let dir = temp_dir();
        let check = script(&dir, "never-runs", "exit 0");
        let status = run_with_input(
            RailExecArgs {
                profile: "(version 1) (this-is-invalid)".into(),
                timeout: Duration::from_secs(1),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, CONTAINED_REFUSED);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn child_nonzero_has_the_script_error_band() {
        let dir = temp_dir();
        let check = script(&dir, "fails", "exit 7");
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_secs(1),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_ERROR);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn timeout_kills_the_whole_process_group() {
        let dir = temp_dir();
        let marker = dir.join("descendant-survived");
        let check = script(
            &dir,
            "hangs",
            &format!(
                "(sleep 1; echo survived > '{}') &\nsleep 5",
                marker.display()
            ),
        );
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_millis(40),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        thread::sleep(Duration::from_millis(1_100));
        assert!(!marker.exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn timeout_stays_armed_when_the_leader_exits_before_a_descendant() {
        let dir = temp_dir();
        let marker = dir.join("descendant-survived");
        let check = script(
            &dir,
            "leader-exits",
            &format!(
                "(sleep 1; echo survived > '{}') &\nexit 0",
                marker.display()
            ),
        );
        let started = Instant::now();
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_millis(40),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        assert!(started.elapsed() < Duration::from_millis(500));
        thread::sleep(Duration::from_millis(1_100));
        assert!(!marker.exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn timeout_does_not_join_a_reader_held_open_by_an_escaped_descendant() {
        let dir = temp_dir();
        let check = script(
            &dir,
            "daemonizes",
            "/usr/bin/perl -MPOSIX=setsid -e 'if (fork) { sleep 30 } else { setsid(); sleep 1 }'",
        );
        let started = Instant::now();
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_millis(40),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        assert!(started.elapsed() < Duration::from_millis(500));
        thread::sleep(Duration::from_millis(1_100));
        fs::remove_dir_all(dir).unwrap();
    }
}
