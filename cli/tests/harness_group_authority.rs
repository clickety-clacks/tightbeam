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

    let harness = Command::new(binary)
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
    // Own teardown from the instant the leader identity is known — before any fallible floor call or
    // assertion — so every return AND every unwind path waits the wrapper, reaps only the owned
    // group, and clears the scratch directory.
    let _session = OwnedSession::own(harness, &leader_identity, &dir);

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

    // Teardown (wrapper wait, owned-group reap, scratch removal) is owned by `_session`'s Drop, so
    // it runs on this normal return and on any assertion unwind above.
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

    let harness = Command::new(binary)
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
    // Own teardown from the instant the leader identity is known — before any fallible floor call or
    // assertion — so every return AND every unwind path waits the wrapper, reaps only the owned
    // group, and clears the scratch directory.
    let _session = OwnedSession::own(harness, &leader_identity, &dir);

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

    // Teardown (wrapper wait, owned-group reap, scratch removal) is owned by `_session`'s Drop, so
    // it runs on this normal return and on any assertion unwind above.
}

struct Identity {
    path: String,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    boot: String,
    starttime: u64,
}

/// The Linux birth token for a pid: field 22 (`starttime`) of `/proc/<pid>/stat`. `comm` (field 2)
/// can contain spaces and parentheses, so parse the fields after the final `)`. Two processes that
/// reuse the same pid cannot share a starttime, so this distinguishes the captured leader from any
/// later pid/pgid reuse.
fn proc_starttime(pid: libc::pid_t) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.rsplit_once(')')?.1;
    // Post-`)` fields begin at `state` (field 3), so `starttime` (field 22) is index 19.
    after.split_whitespace().nth(19)?.parse().ok()
}

/// Owns unconditional teardown of one harness-launched session. Constructed the instant the leader
/// identity is known — BEFORE any fallible floor call or assertion — so a failing assertion that
/// unwinds still reaps everything the test created. On drop it: (1) kills AND waits the harness-exec
/// wrapper it owns directly; (2) SIGKILLs the detached leader group ONLY while the captured pid
/// still leads the captured pgid with the same birth token, so a recycled pgid this test no longer
/// owns is never signalled; (3) removes the scratch directory. Every path — normal return or panic —
/// runs all three.
struct OwnedSession {
    harness: std::process::Child,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    starttime: u64,
    dir: std::path::PathBuf,
}

impl OwnedSession {
    fn own(harness: std::process::Child, identity: &Identity, dir: &std::path::Path) -> Self {
        // The birth token is always valid: `await_identity` only returns once it has read a live
        // starttime for this pid. There is no absent-token state, so teardown can never silently
        // skip the owned group.
        OwnedSession {
            harness,
            pid: identity.pid,
            pgid: identity.pgid,
            starttime: identity.starttime,
            dir: dir.to_path_buf(),
        }
    }
}

impl Drop for OwnedSession {
    fn drop(&mut self) {
        // The wrapper is our direct child: kill and reap it on every path, including panic.
        let _ = self.harness.kill();
        let _ = self.harness.wait();

        // Signal the detached leader group only while it is provably still the one we captured — the
        // pid alive, still the leader of the recorded pgid, with an unchanged birth token. A gone or
        // recycled pid fails this check, so no unowned group is ever SIGKILLed.
        let owned = proc_starttime(self.pid) == Some(self.starttime)
            && unsafe { libc::getpgid(self.pid) } == self.pgid;
        if owned {
            unsafe {
                libc::killpg(self.pgid, libc::SIGKILL);
            }
        }

        // Clear the scratch directory on every path, so a failing regression control leaves no debris.
        let _ = std::fs::remove_dir_all(&self.dir);
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
                    // Capture the birth token in the same loop that confirms the leader is live, so a
                    // constructed Identity always carries a valid starttime — never an absent one that
                    // could later make teardown skip the owned group. A momentary /proc miss retries.
                    if let Some(starttime) = proc_starttime(pid) {
                        return Identity {
                            path: path.to_string_lossy().into_owned(),
                            pid,
                            pgid,
                            boot: boot.to_owned(),
                            starttime,
                        };
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    panic!("{} was never written", path.display());
}
