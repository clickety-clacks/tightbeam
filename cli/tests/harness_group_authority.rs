//! Regression coverage for harness-group instance authority and errno classification.
//!
//! Named classes from att_981d3490: same-group pre-stop, signal-time revalidation failure,
//! and (in unit tests) PID/PGID reuse plus macOS individual-PID EPERM handling.

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
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
    assert_eq!(
        session.adopt(&leader_identity),
        AdoptOutcome::Verified,
        "a live leader must adopt as birth-verified"
    );

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
    assert_eq!(
        session.adopt(&leader_identity),
        AdoptOutcome::Verified,
        "a live leader must adopt as birth-verified"
    );

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

/// OWN-AT-SPAWN closes the leak class even when the leader is already GONE by the time we look. The
/// leader here exits immediately, so its `/proc` starttime is never readable for a live process and
/// `adopt` reports `Gone` — nothing alive to reap. The guard, armed the instant the wrapper is
/// spawned, must still kill and wait the wrapper and remove the scratch directory, and must NEVER
/// signal a group it could not birth-verify (the dead leader is never adopted, so no `killpg`).
#[test]
fn gone_leader_leaves_nothing_without_unowned_signal() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-gone-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let identity_path = dir.join("leader.identity");
    // The leader exits immediately: it is gone before its birth token can be captured.
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
    // leader, `adopt` finds it gone, so no leader is ever adopted.
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if let Ok(text) = fs::read_to_string(&identity_path) {
            let fields: Vec<&str> = text.trim_end().split('\t').collect();
            if let [pid, pgid, boot, _launch] = fields[..] {
                if let (Ok(pid), Ok(pgid)) = (pid.parse(), pgid.parse()) {
                    let _outcome = session.adopt(&Identity {
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

/// A LIVE detached leader whose birth token cannot be acquired must be SURFACED — never silently
/// dropped — and must still be disposed of, without the teardown guard ever signalling a group it
/// has not birth-verified.
///
/// This forces the hard case named in att_ebbb5be4: a real detached leader has written its identity
/// and remains LIVE, while `/proc` starttime acquisition is made to fail persistently before
/// adoption (`POISONED_TOKEN_PID`). The old optional-token `adopt` mapped this to a silent no-op,
/// leaving the running leader as a PID 1 orphan with no signal and no report. The fixed `adopt`
/// returns `StrandedLive`, so the caller learns a live leader could not be birth-verified and
/// disposes of it through authority captured while the leader was provably live — BEFORE the token
/// acquisition could fail. Teardown itself still issues no `killpg` for an un-birth-verified group.
#[test]
fn live_leader_with_persistent_token_failure_is_surfaced_and_reaped_without_unowned_signal() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-acqfail-live-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let identity_path = dir.join("leader.identity");
    // The leader stays LIVE for the whole test: its birth token IS readable, but acquisition is
    // forced to fail persistently below, so this exercises a live leader we cannot birth-verify.
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

    // OWN-AT-SPAWN: the guard owns the wrapper and scratch dir the instant the wrapper exists.
    let mut session = OwnedSession::arm(harness, &dir);
    let wrapper_pid = session.harness.id() as libc::pid_t;
    let leader_identity = await_identity(&identity_path);

    // Teardown ownership of the LIVE leader is captured HERE — before any token acquisition can fail
    // — so a later failure can never leak it. This birth-verified authority is exactly what the guard
    // may not fabricate once the token read fails, and what the test uses for bounded cleanup.
    let reaper = LeaderToken::capture(&leader_identity)
        .expect("the live leader must yield a birth token before failure is injected");
    assert_eq!(
        unsafe { libc::kill(reaper.pid, 0) },
        0,
        "the detached leader must be live so this is the stranded-live case, not the gone case"
    );

    // Force a PERSISTENT birth-token acquisition failure for this live leader, then adopt.
    POISONED_TOKEN_PID.store(leader_identity.pid, Ordering::SeqCst);
    let outcome = session.adopt(&leader_identity);
    POISONED_TOKEN_PID.store(0, Ordering::SeqCst);

    // The live leader was SURFACED, not silently classified as gone (the old-path bug), and was NOT
    // birth-verified by the guard, so teardown will issue no group signal for it.
    assert_eq!(
        outcome,
        AdoptOutcome::StrandedLive,
        "a live leader whose token cannot be read must surface as stranded, never a silent no-op"
    );
    assert!(
        session.leader.is_none(),
        "an un-birth-verified leader must never be armed for signalling"
    );

    drop(session);

    // The guard signalled no group (no birth authority), so the live leader is still running — it was
    // surfaced, not silently leaked. Dispose of it through the birth-verified authority captured while
    // it was provably live.
    assert_eq!(
        unsafe { libc::kill(reaper.pid, 0) },
        0,
        "teardown must not have signalled the un-birth-verified leader group"
    );
    reaper.reap_if_still_owned();
    wait_for_group_absence(reaper.pgid);

    // Everything is gone: wrapper reaped, scratch removed, leader group reaped.
    assert!(
        !dir.exists(),
        "scratch directory must be removed on persistent acquisition failure"
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
/// later pid/pgid reuse. `None` only means the raw read/parse did not yield a token; callers must
/// separately decide whether the pid is gone or live-but-unreadable (see `read_birth_token`).
fn proc_starttime(pid: libc::pid_t) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.rsplit_once(')')?.1;
    // Post-`)` fields begin at `state` (field 3), so `starttime` (field 22) is index 19.
    after.split_whitespace().nth(19)?.parse().ok()
}

/// Test-only injection of a PERSISTENT birth-token acquisition failure for one live pid. Keyed on pid
/// so a poisoned leader never disturbs the unrelated leaders of concurrently running tests. This lets
/// a control keep a leader genuinely LIVE while its `/proc` starttime is treated as unreadable — the
/// case a real `/proc` read failure on a running process would produce.
static POISONED_TOKEN_PID: AtomicI32 = AtomicI32::new(0);

/// The outcome of reading a leader's birth token, distinguishing a process that is GONE (nothing to
/// reap, no signal needed) from one that is LIVE but whose token could not be read (a fail-closed
/// condition that must never be silently classified as gone). Mirrors production
/// `verify_process_instance`, which fails closed on a live pid whose start time cannot be read rather
/// than silently treating it as absent.
enum BirthToken {
    /// The leader is live and its birth token was captured: birth authority to reap its group.
    Captured(u64),
    /// The leader is gone (ESRCH): there is nothing alive to reap and no group is ever signalled.
    Gone,
    /// The leader is still LIVE but its birth token could not be read. Fail closed: it may not be
    /// signalled (no birth authority) and it must NOT be treated as gone.
    Unreadable,
}

/// Read a leader's birth token, resolving the gone-vs-live-but-unreadable ambiguity that a bare
/// `Option<u64>` hides. A live pid whose token cannot be read is the exact case the old optional-token
/// `adopt` silently dropped, leaking the running leader.
fn read_birth_token(pid: libc::pid_t) -> BirthToken {
    // A poisoned pid stands in for a persistent `/proc` read failure against a still-running process.
    let token = if POISONED_TOKEN_PID.load(Ordering::SeqCst) == pid {
        None
    } else {
        proc_starttime(pid)
    };
    match token {
        Some(starttime) => BirthToken::Captured(starttime),
        None => {
            // No token. A gone pid is correctly never signalled; a still-live pid must not be
            // silently classified as gone.
            let gone = unsafe { libc::kill(pid, 0) } == -1
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
            if gone {
                BirthToken::Gone
            } else {
                BirthToken::Unreadable
            }
        }
    }
}

/// The result of adopting a detached leader for teardown. Marked `#[must_use]` so a live leader that
/// could not be birth-verified (`StrandedLive`) can never be silently ignored at a call site — the
/// silent no-op that leaked a running leader is now a compile error, not a latent bug.
#[must_use]
#[derive(Debug, PartialEq, Eq)]
enum AdoptOutcome {
    /// The leader is live and birth-verified; its group is now armed for reaping by `Drop`.
    Verified,
    /// The leader is already gone; there is nothing to reap and no group will be signalled.
    Gone,
    /// The leader is still LIVE but could not be birth-verified, so it was NOT armed for signalling.
    /// The caller must dispose of the captured group through authority it already holds; teardown
    /// will not signal an un-birth-verified group.
    StrandedLive,
}

/// A detached leader this test has birth-verified and may reap: its pid, its recorded pgid, and the
/// `/proc` starttime captured while it was live.
struct LeaderToken {
    pid: libc::pid_t,
    pgid: libc::pid_t,
    starttime: u64,
}

impl LeaderToken {
    /// Capture birth-verified reaping authority for a leader that is live right now, or `None` if its
    /// token cannot be read. Used to own teardown of a live leader BEFORE any later token acquisition
    /// can fail — the authority a fail-closed guard may not fabricate afterward.
    fn capture(identity: &Identity) -> Option<LeaderToken> {
        proc_starttime(identity.pid).map(|starttime| LeaderToken {
            pid: identity.pid,
            pgid: identity.pgid,
            starttime,
        })
    }

    /// SIGKILL the captured group, but only while the captured pid still leads the captured pgid with
    /// an unchanged birth token — so a reused pid/pgid is never signalled.
    fn reap_if_still_owned(&self) {
        let owned = proc_starttime(self.pid) == Some(self.starttime)
            && unsafe { libc::getpgid(self.pid) } == self.pgid;
        if owned {
            unsafe {
                libc::killpg(self.pgid, libc::SIGKILL);
            }
        }
    }
}

/// Owns unconditional teardown of one harness-launched session. ARMED the instant the wrapper is
/// spawned — before `await_identity`, any floor call, or any assertion — so that even a failure to
/// acquire the leader identity or its birth token (an `await_identity` panic, or a leader whose token
/// cannot be read) still waits the wrapper and clears the scratch directory, and NEVER signals a
/// group it has not birth-verified. The detached leader is ADOPTED only once its identity and a live
/// `/proc` starttime are captured. A leader that is gone yields `AdoptOutcome::Gone` (nothing to
/// reap); a leader that is still LIVE but whose token cannot be read yields `AdoptOutcome::StrandedLive`
/// and is deliberately NOT armed for signalling — never silently dropped. On drop, on every path —
/// normal return or panic: (1) kill and wait the owned wrapper; (2) SIGKILL the adopted leader group
/// only while its captured pid still leads its captured pgid with an unchanged starttime; (3) remove
/// the scratch dir.
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

    /// Adopt the detached leader once its identity is known. `await_identity` has just confirmed the
    /// leader wrote its identity, so a live leader's `/proc` starttime is readable. The outcome is
    /// `#[must_use]`: `Gone` means the leader already exited (nothing to reap, no signal);
    /// `StrandedLive` means the leader is still live but could not be birth-verified, so it is NOT
    /// armed for signalling and the caller must dispose of it — it is never silently dropped.
    fn adopt(&mut self, identity: &Identity) -> AdoptOutcome {
        match read_birth_token(identity.pid) {
            BirthToken::Captured(starttime) => {
                self.leader = Some(LeaderToken {
                    pid: identity.pid,
                    pgid: identity.pgid,
                    starttime,
                });
                AdoptOutcome::Verified
            }
            BirthToken::Gone => AdoptOutcome::Gone,
            BirthToken::Unreadable => AdoptOutcome::StrandedLive,
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
        // pid alive, still leading the recorded pgid, with an unchanged birth token. An unadopted,
        // stranded, or gone/recycled leader is never signalled, so no unowned group is ever SIGKILLed.
        if let Some(leader) = &self.leader {
            leader.reap_if_still_owned();
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

/// Poll until no process remains in the group, bounded — proof that a reaped leader group is gone
/// rather than merely signalled. The detached leader is not our child, so it is reaped by its
/// subreaper after the SIGKILL; `killpg(pgid, 0)` returns `ESRCH` once the group is empty.
fn wait_for_group_absence(pgid: libc::pid_t) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let gone = unsafe { libc::killpg(pgid, 0) } == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
        if gone {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("process group {pgid} was still present after bounded reap");
}
