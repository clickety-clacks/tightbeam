// Harklight subprocess ownership. The lifetime lock is also inherited by the
// CLI, so a wrapper failure cannot be mistaken for that CLI having exited.
use std::fs::OpenOptions;
use std::io::{BufRead, Write};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub fn run(args: &[String]) -> Result<i32, String> {
    if args.len() < 3 || args[0] != "--lock" {
        return Err("expected --lock <path> --wait | -- <executable> <args...>".into());
    }
    let path = std::path::Path::new(&args[1]);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(|e| e.to_string())?;
    if args[2] == "--wait" && args.len() == 3 {
        lock_exclusive(lock.as_raw_fd())?;
        return Ok(0);
    }
    if args[2] != "--" || args.len() < 4 {
        return Err("expected command after --".into());
    }

    let stopped = Arc::new(AtomicBool::new(false));
    let child_pid = Arc::new(Mutex::new(None::<u32>));
    let input_stopped = stopped.clone();
    let input_pid = child_pid.clone();
    let (release, released) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut input = stdin.lock();
        let mut line = String::new();
        let continuing = input.read_line(&mut line).is_ok() && line == "continue\n";
        let _ = release.send(continuing);
        if continuing {
            line.clear();
            let _ = input.read_line(&mut line);
        }
        input_stopped.store(true, Ordering::SeqCst);
        if let Some(pid) = *input_pid.lock().unwrap() {
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGKILL);
            }
        }
    });

    lock_exclusive(lock.as_raw_fd())?;
    // A wrapper that was still waiting for the lock when its port closed
    // must never launch later, after a restart barrier has passed.
    let mut input = libc::pollfd {
        fd: 0,
        events: libc::POLLHUP,
        revents: 0,
    };
    unsafe {
        libc::poll(&mut input, 1, 0);
    }
    if stopped.load(Ordering::SeqCst) || input.revents & libc::POLLHUP != 0 {
        return Ok(0);
    }
    let fd = lock.as_raw_fd();
    let mut command = Command::new(&args[3]);
    command
        .args(&args[4..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(fd, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    *child_pid.lock().unwrap() = Some(child.id());
    if stopped.load(Ordering::SeqCst) {
        let _ = child.kill();
    }
    let ready = std::io::stdout()
        .write_all(b"TIGHTBEAM_CHILD_READY\n")
        .and_then(|_| std::io::stdout().flush());
    if ready.is_err() || !released.recv().unwrap_or(false) {
        let _ = child.kill();
    }
    let mut errors = child.stderr.take().unwrap();
    let copy_errors = std::thread::spawn(move || {
        let _ = std::io::copy(&mut errors, &mut std::io::stderr());
    });
    let mut output = child.stdout.take().unwrap();
    let copy = std::thread::spawn(move || {
        let _ = std::io::copy(&mut output, &mut std::io::stdout());
    });
    let status = child.wait().map_err(|e| e.to_string())?;
    *child_pid.lock().unwrap() = None;
    let _ = copy.join();
    let _ = copy_errors.join();
    // Keep the lock until both child exit and output drain have been observed.
    drop(lock);
    Ok(status.code().unwrap_or(1))
}

fn lock_exclusive(fd: i32) -> Result<(), String> {
    loop {
        if unsafe { libc::flock(fd, libc::LOCK_EX) } == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error.to_string());
        }
    }
}
