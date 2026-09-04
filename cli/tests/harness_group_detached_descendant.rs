//! The floor has to reach a harness child that took itself out of the harness's group.
//!
//! Measured live on pi 0.84.2 (spike 2026-08-23, `pi-harness-spike-2026-08-23.md`) and on
//! opencode 1.18.18 before it: harnesses spawn bash commands with node's `detached: true`,
//! which `setsid`s each one into a process group of its OWN. The floor's single
//! `killpg(recorded_pgid)` killed the harness — pid 10421 — and left `sleep 400` at 10957
//! alive, reparented to init. The harness cannot clean up after itself here; the premise of
//! this path is that it was SIGKILLed and never got the chance.
//!
//! Everything below the leader is built out of THIS binary's own `harness-exec`, which is
//! the `setsid` the harnesses perform, so the escape is real rather than mimed — and the
//! escapee records its own pid on the way, which is what makes its death checkable instead
//! of inferred from a stopwatch.
//!
//! Regression value, stated so it can be checked rather than trusted: reverting `group` to
//! the single `killpg` it used to be leaves the escapee alive and turns this test red. That
//! was confirmed against this test before it landed.

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// A tree three deep, so passing needs a transitive walk and not a look at the leader's
/// own children:
///
///   leader sh      the session `harness-exec` mints — pid == pgid
///     worker sh    a child, still in the leader's group
///       harness-exec wrapper   also in the leader's group
///         sleep 400            `setsid` put it in a group of its own
#[test]
fn a_detached_grandchild_does_not_outlive_the_floor() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-detached-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let leader_identity = dir.join("leader.identity");
    let escapee_identity = dir.join("escapee.identity");

    // Each level stays alive after spawning the next. A shell that exits instead would
    // hand its child to init and break the parent links this walk follows, which would
    // make the test pass without proving the walk.
    let worker = script(
        &dir,
        "worker.sh",
        &format!(
            "{binary} harness-exec {} escapee-launch -- /bin/sleep 400 &\n\
             while :; do sleep 1; done\n",
            escapee_identity.display()
        ),
    );
    let leader = script(
        &dir,
        "leader.sh",
        &format!(
            "/bin/sh {} &\nwhile :; do sleep 1; done\n",
            worker.display()
        ),
    );

    let mut harness = Command::new(binary)
        .args([
            "harness-exec",
            &leader_identity.to_string_lossy(),
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

    // Wait for the EVENT — both identities written — rather than for a duration. Under a
    // loaded runner a fixed nap would fire before the escape and prove nothing.
    let leader_identity = await_identity(&leader_identity);
    let escapee_identity = await_identity(&escapee_identity);
    let escapee = escapee_identity.pid;

    assert_ne!(
        escapee_identity.pgid, leader_identity.pgid,
        "the escapee shared the harness's process group, so a single killpg would have \
         reached it and this run proves nothing"
    );
    assert!(
        alive(escapee),
        "the escapee was gone before the floor fired"
    );

    let floor = Command::new(binary)
        .args([
            "harness-group",
            &leader_identity.pgid.to_string(),
            &leader_identity.path,
            &leader_identity.boot,
            "leader-launch",
        ])
        .output()
        .expect("the floor must run");

    assert!(
        floor.status.success(),
        "the floor refused: {}",
        String::from_utf8_lossy(&floor.stderr)
    );

    let leaked = !died(escapee);
    if leaked {
        unsafe { libc::kill(escapee, libc::SIGKILL) };
    }
    let _ = harness.wait();
    let _ = fs::remove_dir_all(&dir);

    assert!(
        !leaked,
        "the detached grandchild ({escapee}) outlived the floor — the orphan signature \
         measured on pi 0.84.2 and opencode 1.18.18"
    );
    assert!(
        died(leader_identity.pid),
        "the harness leader ({}) outlived its own floor",
        leader_identity.pid
    );
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

/// The launcher writes `pid\tpgid\tboot\tlaunch` and syncs it, so a complete line is the
/// arrival signal. A partial read is retried rather than parsed.
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

fn alive(pid: libc::pid_t) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Gone from the process table, bounded — not "gone after a nap".
///
/// The wait is for the REAP, not for the kill: a SIGKILLed process whose parent is being
/// killed in the same sweep is a zombie until init inherits and reaps it, and a zombie
/// still answers `kill(pid, 0)`.
fn died(pid: libc::pid_t) -> bool {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}
