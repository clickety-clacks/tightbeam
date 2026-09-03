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

    // Arm teardown the instant the wrapper exists — before `await_identity`, any floor call, or any
    // assertion — so even a failure to acquire the identity/token still waits the wrapper and clears
    // the scratch dir without ever signalling an unowned group.
    let mut session = OwnedSession::arm(harness, &dir);
    let leader_identity = await_identity(&identity_path);
    // The leader is live now; adopt it so teardown reaps exactly its birth-verified group.
    session.adopt(&leader_identity);

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

    // Teardown (wrapper wait, owned-group reap, scratch removal) is owned by `session`'s Drop, so
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

    // Arm teardown the instant the wrapper exists — before `await_identity`, any floor call, or any
    // assertion — so even a failure to acquire the identity/token still waits the wrapper and clears
    // the scratch dir without ever signalling an unowned group.
    let mut session = OwnedSession::arm(harness, &dir);
    let leader_identity = await_identity(&identity_path);
    // The leader is live now; adopt it so teardown reaps exactly its birth-verified group.
    session.adopt(&leader_identity);

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

    // Teardown (wrapper wait, owned-group reap, scratch removal) is owned by `session`'s Drop, so
    // it runs on this normal return and on any assertion unwind above.
}

/// OWN-AT-SPAWN closes the leak class even when the leader identity/birth token can never be
/// acquired. The leader here exits immediately, so its `/proc` starttime is never readable for a live
/// process — a persistent acquisition failure. The guard, armed the instant the wrapper is spawned,
/// must still kill and wait the wrapper and remove the scratch directory, and must NEVER signal a
/// group it could not birth-verify (the dead leader is never adopted, so no `killpg` is issued).
#[test]
fn persistent_acquisition_failure_leaves_nothing_without_unowned_signal() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-acqfail-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let identity_path = dir.join("leader.identity");
    // The leader exits immediately: its birth token can never be acquired for a live process.
    let leader = script(&dir, "leader.sh", "exit 0\n");

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

    // OWN-AT-SPAWN: the guard owns the wrapper and scratch dir the instant the wrapper exists.
    let mut session = OwnedSession::arm(harness, &dir);
    let wrapper_pid = session.harness.id() as libc::pid_t;

    // Bounded acquisition attempt. Whether or not harness-exec wrote an identity for the already-dead
    // leader, `adopt` finds no live starttime, so no leader is ever adopted.
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if let Ok(text) = fs::read_to_string(&identity_path) {
            let fields: Vec<&str> = text.trim_end().split('\t').collect();
            if let [pid, pgid, boot, _launch] = fields[..] {
                if let (Ok(pid), Ok(pgid)) = (pid.parse(), pgid.parse()) {
                    session.adopt(&Identity {
                        path: identity_path.to_string_lossy().into_owned(),
                        pid,
                        pgid,
                        boot: boot.to_owned(),
                    });
                    break;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    // The dead leader is never adopted, so teardown will not signal any group.
    assert!(
        session.leader.is_none(),
        "a leader without a live birth token must never be adopted"
    );

    drop(session);

    // Teardown left nothing: wrapper reaped, scratch removed. No unowned group was signalled because
    // no leader was ever adopted (asserted above).
    assert!(
        !dir.exists(),
        "scratch directory must be removed on acquisition failure"
    );
    assert!(
        unsafe { libc::kill(wrapper_pid, 0) } == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH),
        "the harness-exec wrapper must be killed and reaped"
    );
}

struct Identity {
    path: String,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    boot: String,
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

/// A detached leader this test has birth-verified and may reap: its pid, its recorded pgid, and the
/// `/proc` starttime captured while it was live.
struct LeaderToken {
    pid: libc::pid_t,
    pgid: libc::pid_t,
    starttime: u64,
}

/// Owns unconditional teardown of one harness-launched session. ARMED the instant the wrapper is
/// spawned — before `await_identity`, any floor call, or any assertion — so that even a failure to
/// acquire the leader identity or its birth token (an `await_identity` panic, or a leader that never
/// yields a token) still waits the wrapper and clears the scratch directory, and NEVER signals a
/// group it has not birth-verified. The detached leader is ADOPTED only once its identity and a live
/// `/proc` starttime are captured; a leader that is already gone yields no token, so it is correctly
/// never signalled (there is nothing alive to reap). On drop, on every path — normal return or
/// panic: (1) kill and wait the owned wrapper; (2) SIGKILL the adopted leader group only while its
/// captured pid still leads its captured pgid with an unchanged starttime; (3) remove the scratch dir.
struct OwnedSession {
    harness: std::process::Child,
    dir: std::path::PathBuf,
    leader: Option<LeaderToken>,
}

impl OwnedSession {
    /// Take ownership of the wrapper and scratch dir immediately, before any fallible step, with no
    /// leader yet.
    fn arm(harness: std::process::Child, dir: &std::path::Path) -> Self {
        OwnedSession {
            harness,
            dir: dir.to_path_buf(),
            leader: None,
        }
    }

    /// Adopt the detached leader once its identity is known and it is still live. `await_identity`
    /// has just confirmed the leader wrote its identity, so its `/proc` starttime is readable; a
    /// `None` here means the leader has already exited, in which case there is nothing to reap and no
    /// group is ever signalled.
    fn adopt(&mut self, identity: &Identity) {
        if let Some(starttime) = proc_starttime(identity.pid) {
            self.leader = Some(LeaderToken {
                pid: identity.pid,
                pgid: identity.pgid,
                starttime,
            });
        }
    }
}

impl Drop for OwnedSession {
    fn drop(&mut self) {
        // The wrapper is our direct child: kill and reap it on every path, including panic — even if
        // the leader was never adopted.
        let _ = self.harness.kill();
        let _ = self.harness.wait();

        // Signal the leader group only if one was adopted and is provably still the one we captured —
        // pid alive, still leading the recorded pgid, with an unchanged birth token. An unadopted or
        // gone/recycled leader is never signalled, so no unowned group is ever SIGKILLed.
        if let Some(leader) = &self.leader {
            let owned = proc_starttime(leader.pid) == Some(leader.starttime)
                && unsafe { libc::getpgid(leader.pid) } == leader.pgid;
            if owned {
                unsafe {
                    libc::killpg(leader.pgid, libc::SIGKILL);
                }
            }
        }

        // Clear the scratch directory on every path, so a failing control or panic leaves no debris.
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
