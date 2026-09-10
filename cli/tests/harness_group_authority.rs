//! Regression coverage for harness-group instance authority and errno classification.
//!
//! Named classes from att_981d3490: same-group pre-stop, signal-time revalidation failure,
//! and (in unit tests) PID/PGID reuse plus macOS individual-PID EPERM handling.

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Same-group protection must run before SIGSTOP: a caller inside the recorded group must
/// not freeze itself and hang forever.
#[test]
fn same_group_caller_is_not_frozen_by_the_initial_stop() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-same-group-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let identity_path = dir.join("leader.identity");

    let child_path = dir.join("member.pid");
    let leader = script(
        &dir,
        "leader.sh",
        &format!(
            "/bin/sleep 400 &\necho $! > {child}\nIFS='\t' read pid pgid boot launch < {identity}\nexec {binary} harness-group \"$pgid\" {identity} \"$boot\" leader-launch\n",
            child = child_path.display(),
            identity = identity_path.display(),
        ),
    );
    let mut harness = Command::new(binary)
        .args([
            "harness-exec",
            &identity_path.to_string_lossy(),
            "leader-launch",
            "--",
            "/bin/sh",
            &leader.to_string_lossy(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the harness session launcher must start");
    let identity = await_identity(&identity_path);
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = harness.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            // This fixture's launcher still owns the unreaped group leader.
            unsafe {
                libc::killpg(identity.pgid, libc::SIGKILL);
            }
            let _ = harness.wait();
            panic!("in-group helper froze itself");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let child: libc::pid_t = fs::read_to_string(&child_path)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // The exec preserves the leader PID/PGID; this fixture really invokes the floor
    // from inside its target group, unlike an unrelated shell calling it from outside.
    assert_eq!(identity.pid, identity.pgid);
    let member_gone = await_gone(child);
    if !member_gone {
        unsafe {
            libc::kill(child, libc::SIGKILL);
        }
    }
    assert!(member_gone, "same-group member survived the floor");
    assert!(
        status.success(),
        "in-group helper did not complete successfully"
    );
    fs::remove_dir_all(&dir).unwrap();
}

/// Identity revalidation at signal time must refuse a boot mismatch before any kill.
#[test]
fn signal_time_revalidation_refuses_a_boot_mismatch() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-revalidate-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let identity_path = dir.join("leader.identity");
    let leader = script(&dir, "leader.sh", "while :; do sleep 1; done\n");

    let mut harness = Command::new(binary)
        .args([
            "harness-exec",
            &identity_path.to_string_lossy(),
            "leader-launch",
            "--",
            "/bin/sh",
            &leader.to_string_lossy(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("the harness session launcher must start");

    let leader_identity = await_identity(&identity_path);

    let floor = Command::new(binary)
        .args([
            "harness-group",
            &leader_identity.pgid.to_string(),
            &leader_identity.path,
            "wrong-boot-identity",
            "leader-launch",
        ])
        .output()
        .expect("the floor must run");

    assert!(
        !floor.status.success(),
        "boot mismatch must refuse before signalling"
    );
    assert!(
        String::from_utf8_lossy(&floor.stderr).contains("boot identity"),
        "stderr must name the boot mismatch"
    );

    let cleanup = Command::new(binary)
        .args([
            "harness-group",
            &leader_identity.pgid.to_string(),
            &leader_identity.path,
            &leader_identity.boot,
            "leader-launch",
        ])
        .output()
        .unwrap();
    assert!(
        cleanup.status.success(),
        "owned fixture cleanup failed: {}",
        String::from_utf8_lossy(&cleanup.stderr)
    );
    let _ = harness.wait();
    let _ = fs::remove_dir_all(&dir);
}

struct Identity {
    path: String,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    boot: String,
}

fn script(dir: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
    let path = dir.join(name);
    let mut file = fs::File::create(&path).unwrap();
    file.write_all(format!("#!/bin/sh\n{body}").as_bytes())
        .unwrap();
    file.sync_all().unwrap();
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&path, permissions).unwrap();
    path
}

fn await_identity(path: &std::path::Path) -> Identity {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Ok(text) = fs::read_to_string(path) {
            let fields: Vec<&str> = text.trim_end().split('\t').collect();
            if let [pid, pgid, boot, _launch] = fields[..] {
                if let (Ok(pid), Ok(pgid)) = (pid.parse(), pgid.parse()) {
                    return Identity {
                        path: path.to_string_lossy().into_owned(),
                        pid,
                        pgid,
                        boot: boot.to_owned(),
                    };
                }
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    panic!("{} was never written", path.display());
}

fn await_gone(pid: libc::pid_t) -> bool {
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if unsafe { libc::kill(pid, 0) } == -1 {
            return true;
        }
        #[cfg(target_os = "linux")]
        if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) {
            if stat
                .rsplit_once(')')
                .is_some_and(|(_, tail)| tail.trim_start().starts_with('Z'))
            {
                return true;
            }
        }
        #[cfg(target_os = "macos")]
        {
            let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
            let read = unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    std::ptr::addr_of_mut!(info).cast(),
                    size_of::<libc::proc_bsdinfo>() as i32,
                )
            };
            if read == size_of::<libc::proc_bsdinfo>() as i32 && info.pbi_status == 5 {
                return true;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}
