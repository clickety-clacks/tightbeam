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
    // Own teardown from the moment the group identity is known, so a failing assertion below still
    // reaps it on unwind.
    let _reaper = DetachedGroup(leader_identity.pgid);

    let floor_script = script(
        &dir,
        "floor.sh",
        &format!(
            "{binary} harness-group {pgid} {path} {boot} leader-launch\n",
            pgid = leader_identity.pgid,
            path = leader_identity.path,
            boot = leader_identity.boot,
        ),
    );

    let floor = Command::new("/bin/sh")
        .arg(&floor_script)
        .output()
        .expect("same-group floor must run");

    assert!(
        floor.status.success(),
        "same-group floor must not hang or fail: {}",
        String::from_utf8_lossy(&floor.stderr)
    );

    let _ = harness.kill();
    let _ = harness.wait();
    let _ = fs::remove_dir_all(&dir);
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
    // Own teardown from the moment the group identity is known, so a failing assertion below still
    // reaps it on unwind.
    let _reaper = DetachedGroup(leader_identity.pgid);

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

    let _ = harness.kill();
    let _ = harness.wait();
    let _ = fs::remove_dir_all(&dir);
}

struct Identity {
    path: String,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    boot: String,
}

/// The harness session launcher forks a `setsid` leader into its own process group. Killing only
/// the launcher wrapper leaves that detached leader alive under PID 1 — a boot mismatch refuses
/// before signalling, so `harness-group` never reaps it. Teardown must kill the group the test
/// created so it does not pollute developer and CI hosts. SIGKILL the recorded group; an
/// already-gone group (ESRCH) is the success case and is ignored.
fn reap_detached_group(pgid: libc::pid_t) {
    unsafe {
        libc::killpg(pgid, libc::SIGKILL);
    }
}

/// Owns teardown of the detached leader group unconditionally. A test asserts after identity
/// capture, so a failing assertion unwinds before any explicit teardown line — leaving the leader
/// alive under PID 1 on the regression path. Holding the group in a drop guard reaps it whether the
/// test returns normally or panics, so no code path pollutes developer and CI hosts.
struct DetachedGroup(libc::pid_t);

impl Drop for DetachedGroup {
    fn drop(&mut self) {
        reap_detached_group(self.0);
    }
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
