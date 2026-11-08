use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Running {
    child: Child,
    output: BufReader<ChildStdout>,
    lock: String,
}

impl Drop for Running {
    fn drop(&mut self) {
        self.child.stdin.take();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.lock);
    }
}

fn start(script: &str) -> Running {
    let lock = std::env::temp_dir()
        .join(format!(
            "harklight-child-{}-{}.lock",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ))
        .to_string_lossy()
        .into_owned();
    let mut child = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args([
            "harklight-child",
            "--lock",
            &lock,
            "--",
            "/bin/sh",
            "-c",
            script,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    output.read_line(&mut line).unwrap();
    assert_eq!(line, "TIGHTBEAM_CHILD_READY\n");
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"continue\n")
        .unwrap();
    Running {
        child,
        output,
        lock,
    }
}

fn barrier(lock: &str) -> Child {
    Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["harklight-child", "--lock", lock, "--wait"])
        .stdin(Stdio::null())
        .spawn()
        .unwrap()
}

fn child_pid(running: &mut Running) -> i32 {
    let mut line = String::new();
    running.output.read_line(&mut line).unwrap();
    line.trim().parse().unwrap()
}

#[test]
fn preserves_child_output_and_status() {
    let mut running = start("printf 'payload\\n'; printf 'diagnostic\\n' >&2; exit 23");
    let mut output = String::new();
    running.output.read_to_string(&mut output).unwrap();
    assert_eq!(output, "payload\n");
    assert_eq!(running.child.wait().unwrap().code(), Some(23));
    let mut errors = String::new();
    running
        .child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut errors)
        .unwrap();
    assert_eq!(errors, "diagnostic\n");
}

#[test]
fn input_eof_terminates_and_reaps_the_cli() {
    let mut running = start("echo $$; exec sleep 60");
    let pid = child_pid(&mut running);
    running.child.stdin.take();
    running.child.wait().unwrap();
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    assert!(barrier(&running.lock).wait().unwrap().success());
}

#[test]
fn stop_barrier_waits_for_the_live_cli() {
    let mut running = start("echo $$; exec sleep 60");
    let pid = child_pid(&mut running);
    let mut waiting = barrier(&running.lock);
    std::thread::sleep(Duration::from_millis(100));
    assert!(waiting.try_wait().unwrap().is_none());
    running
        .child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"stop\n")
        .unwrap();
    running.child.wait().unwrap();
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    assert!(waiting.wait().unwrap().success());
}

#[test]
fn wrapper_death_cannot_masquerade_as_child_exit() {
    let mut running = start("echo $$; exec sleep 60");
    let pid = child_pid(&mut running);
    running.child.kill().unwrap();
    running.child.wait().unwrap();
    let mut waiting = barrier(&running.lock);
    std::thread::sleep(Duration::from_millis(100));
    assert!(waiting.try_wait().unwrap().is_none());
    assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0);
    assert!(waiting.wait().unwrap().success());
}
