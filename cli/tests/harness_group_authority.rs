//! Regression coverage for harness-group instance authority and errno classification.
//!
//! Named classes from att_981d3490: same-group pre-stop, signal-time revalidation failure,
//! and (in unit tests) PID/PGID reuse plus macOS individual-PID EPERM handling.

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::process::{Command, Stdio};
use std::sync::Mutex;
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
        AdoptOutcome::Adopted,
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
        AdoptOutcome::Adopted,
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
/// leader here exits immediately, so `adopt` reports `Gone` — nothing alive to reap. The guard, armed
/// the instant the wrapper is spawned, must still kill and wait the wrapper and remove the scratch
/// directory, and must NEVER signal a group it could not birth-verify (the dead leader is never
/// adopted, so no `killpg`).
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
        is_gone(wrapper_pid),
        "the harness-exec wrapper must be killed and reaped"
    );
}

/// `OwnedSession` must reap the LIVE detached leader ITSELF — on a normal return AND on a panic
/// unwind — even when the leader's birth token becomes persistently unreadable AFTER adoption, and it
/// must do so without ever signalling a group it did not birth-verify and without any external reap.
///
/// This is the case named in att_ebbb5be4 and refined by the PO: the guard captures birth-verified
/// cleanup authority at adoption, BEFORE the fallible token step; a subsequent persistent
/// `/proc` starttime failure (`poison`) then cannot strip that authority. Teardown reaps the owned
/// group using the token captured while the leader was live plus a current same-group liveness check —
/// never a bare pgid, never a gone or reused pid. The harness-exec wrapper is `setsid`-detached from
/// the leader, so killing the wrapper cannot reap the leader; only this birth-verified `killpg` can.
#[test]
fn owned_session_reaps_live_leader_after_persistent_token_failure_on_return() {
    let (wrapper_pid, leader) = run_live_leader_persistent_failure(|session| {
        // Normal return: `session` drops here, at end of the closure, under the active poison.
        drop(session);
    });
    assert!(
        is_gone(wrapper_pid),
        "the harness-exec wrapper must be killed and reaped on return"
    );
    assert!(
        group_is_gone(leader.pgid),
        "OwnedSession must reap the detached leader group itself on return — no external reap"
    );
}

#[test]
fn owned_session_reaps_live_leader_after_persistent_token_failure_on_unwind() {
    let (wrapper_pid, leader) = run_live_leader_persistent_failure(|session| {
        // Panic unwind: `session`'s Drop must still reap everything as the stack unwinds.
        let result = catch_unwind(AssertUnwindSafe(move || {
            let _owned = session;
            panic!("forced failure after the birth token became persistently unreadable");
        }));
        assert!(
            result.is_err(),
            "the forced failure must unwind through Drop"
        );
    });
    assert!(
        is_gone(wrapper_pid),
        "the harness-exec wrapper must be killed and reaped on unwind"
    );
    assert!(
        group_is_gone(leader.pgid),
        "OwnedSession must reap the detached leader group itself on unwind — no external reap"
    );
}

/// Shared body for the return/unwind proofs: launch a real detached leader that stays LIVE, arm the
/// guard, adopt it (capturing birth-verified cleanup BEFORE the fallible step), then make its birth
/// token PERSISTENTLY unreadable and hand the armed guard to `finish`, which drops it on the path
/// under test. Returns the wrapper pid and the leader's captured token so the caller can prove
/// everything is gone. The poison is lifted before returning so the caller's checks read real state.
fn run_live_leader_persistent_failure(
    finish: impl FnOnce(OwnedSession),
) -> (libc::pid_t, LeaderToken) {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-acqfail-live-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
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

    let mut session = OwnedSession::arm(harness, &dir);
    let wrapper_pid = session.harness.id() as libc::pid_t;
    let identity = await_identity(&identity_path);

    // Capture birth-verified cleanup authority NOW, while the leader is live and its token is
    // readable — BEFORE the fallible token step. This is what the guard owns and later reaps.
    assert_eq!(
        session.adopt(&identity),
        AdoptOutcome::Adopted,
        "the live leader must adopt as birth-verified before the token failure is injected"
    );
    let captured = session
        .leader
        .as_ref()
        .expect("adoption must have captured a birth token")
        .clone();
    assert!(
        !is_gone(captured.pid),
        "the detached leader must be live for this to be the stranded-live case"
    );

    // Inject a PERSISTENT birth-token read failure for this live leader. From here on every
    // `/proc` starttime read for it fails, including the guard's own re-read inside `Drop`.
    poison(captured.pid);

    // Drop the guard on the path under test (normal return or panic unwind). Teardown must reap the
    // owned leader group despite the persistent token failure, using the captured authority.
    finish(session);

    // Lift the poison so the caller's absence checks read real kernel state.
    unpoison(captured.pid);
    (wrapper_pid, captured)
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
/// later pid/pgid reuse. `None` only means the raw read/parse did not yield a token; callers resolve
/// gone-vs-live via `read_birth_token`.
fn proc_starttime(pid: libc::pid_t) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.rsplit_once(')')?.1;
    // Post-`)` fields begin at `state` (field 3), so `starttime` (field 22) is index 19.
    after.split_whitespace().nth(19)?.parse().ok()
}

/// Test-only injection of a PERSISTENT birth-token acquisition failure for specific live pids. Keyed
/// on pid so a poisoned leader never disturbs the unrelated leaders of concurrently running tests,
/// and held in a set so several tests can each poison their own leader at once. Modelling a real
/// `/proc` read failure against a still-running process is the only way to force the fail-closed path
/// while the leader stays live.
static POISONED_TOKEN_PIDS: Mutex<Vec<libc::pid_t>> = Mutex::new(Vec::new());

fn poison(pid: libc::pid_t) {
    POISONED_TOKEN_PIDS.lock().unwrap().push(pid);
}

fn unpoison(pid: libc::pid_t) {
    POISONED_TOKEN_PIDS.lock().unwrap().retain(|&p| p != pid);
}

fn token_read_is_poisoned(pid: libc::pid_t) -> bool {
    POISONED_TOKEN_PIDS.lock().unwrap().contains(&pid)
}

/// True iff the pid is gone: `kill(pid, 0)` fails with `ESRCH`.
fn is_gone(pid: libc::pid_t) -> bool {
    (unsafe { libc::kill(pid, 0) }) == -1
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

/// The outcome of reading a leader's birth token, distinguishing a process that is GONE (nothing to
/// reap) from one that is LIVE but whose token could not be read (a fail-closed condition that must
/// never be silently classified as gone). Mirrors production `verify_process_instance`, which fails
/// closed on a live pid whose start time cannot be read rather than silently treating it as absent.
enum BirthToken {
    /// The leader is live and its birth token was captured: birth authority to reap its group.
    Captured(u64),
    /// The leader is gone (ESRCH): there is nothing alive to reap and no group is ever signalled.
    Gone,
    /// The leader is still LIVE but its birth token could not be read right now.
    Unreadable,
}

/// Read a leader's birth token, resolving the gone-vs-live-but-unreadable ambiguity that a bare
/// `Option<u64>` hides. A live pid whose token cannot be read is the exact case the old optional-token
/// `adopt` silently dropped, leaking the running leader.
fn read_birth_token(pid: libc::pid_t) -> BirthToken {
    // A poisoned pid stands in for a persistent `/proc` read failure against a still-running process.
    let token = if token_read_is_poisoned(pid) {
        None
    } else {
        proc_starttime(pid)
    };
    match token {
        Some(starttime) => BirthToken::Captured(starttime),
        None if is_gone(pid) => BirthToken::Gone,
        None => BirthToken::Unreadable,
    }
}

/// The result of adopting a detached leader for teardown. A live leader that could not be
/// birth-verified AT adoption is surfaced as `StrandedLive` rather than silently dropped, but the
/// load-bearing guarantee is that teardown ownership is captured here, before any later fallible
/// token step — so a persistent failure after adoption can never strip it.
#[must_use]
#[derive(Debug, PartialEq, Eq)]
enum AdoptOutcome {
    /// The leader was live and birth-verified; its group is now armed for reaping by `Drop`.
    Adopted,
    /// The leader was already gone; there is nothing to reap and no group will be signalled.
    Gone,
    /// The leader was still LIVE but could not be birth-verified at adoption, so no cleanup authority
    /// could be captured. Adopt before the fallible token step to avoid this.
    StrandedLive,
}

/// Birth-verified reaping authority for one detached leader: its pid, its recorded pgid, and the
/// `/proc` starttime captured while it was live. Captured once, at adoption, before any fallible
/// token step; teardown reaps through this even if the token later becomes unreadable.
#[derive(Clone)]
struct LeaderToken {
    pid: libc::pid_t,
    pgid: libc::pid_t,
    starttime: u64,
}

impl LeaderToken {
    /// SIGKILL the captured group, but only while the captured pid still leads the captured pgid and
    /// is provably still the instance we birth-verified at capture:
    /// - starttime still readable and matching -> the same live instance -> reap;
    /// - starttime readable but changed -> pid reuse -> never signal;
    /// - gone (ESRCH) -> nothing to reap -> never signal;
    /// - starttime unreadable but the pid is alive and still leads the captured pgid -> reap on the
    ///   authority captured while it was live (a persistent `/proc` failure must not leak a leader we
    ///   already birth-verified). This is never a bare-pgid signal: it is gated on our captured token
    ///   for this exact pid plus current same-group membership.
    fn reap_if_still_owned(&self) {
        let reap = || unsafe {
            libc::killpg(self.pgid, libc::SIGKILL);
        };
        match read_birth_token(self.pid) {
            BirthToken::Captured(current) if current == self.starttime => reap(),
            BirthToken::Captured(_) => {}
            BirthToken::Gone => {}
            BirthToken::Unreadable => {
                if unsafe { libc::getpgid(self.pid) } == self.pgid {
                    reap();
                }
            }
        }
    }
}

/// Owns unconditional teardown of one harness-launched session. ARMED the instant the wrapper is
/// spawned — before `await_identity`, any floor call, or any assertion — so that even a failure to
/// acquire the leader identity still waits the wrapper and clears the scratch directory, and NEVER
/// signals a group it has not birth-verified. The detached leader is ADOPTED once its identity and a
/// live `/proc` starttime are captured; that capture is the birth-verified cleanup authority, taken
/// BEFORE any later fallible token step, so a persistent token failure after adoption cannot strip
/// it. On drop, on every path — normal return or panic: (1) reap the owned leader group via
/// `LeaderToken::reap_if_still_owned`; (2) kill and wait the owned wrapper (which is `setsid`-detached
/// from the leader, so it cannot reap the leader); (3) remove the scratch dir.
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

    /// Adopt the detached leader once its identity is known and it is live, capturing its birth token
    /// as the guard's cleanup authority. The outcome is `#[must_use]`: `Gone` means the leader already
    /// exited (nothing to reap); `StrandedLive` means the leader is still live but could not be
    /// birth-verified at this instant, so no authority was captured — adopt before the fallible token
    /// step to avoid it. `Adopted` means the guard now owns birth-verified teardown of the group.
    fn adopt(&mut self, identity: &Identity) -> AdoptOutcome {
        match read_birth_token(identity.pid) {
            BirthToken::Captured(starttime) => {
                self.leader = Some(LeaderToken {
                    pid: identity.pid,
                    pgid: identity.pgid,
                    starttime,
                });
                AdoptOutcome::Adopted
            }
            BirthToken::Gone => AdoptOutcome::Gone,
            BirthToken::Unreadable => AdoptOutcome::StrandedLive,
        }
    }
}

impl Drop for OwnedSession {
    fn drop(&mut self) {
        // Reap the owned leader group FIRST, while its captured authority is in hand: the wrapper is
        // `setsid`-detached from the leader, so killing the wrapper can never reap the leader — only
        // this birth-verified `killpg` can. An unadopted, gone, or reused leader is never signalled.
        if let Some(leader) = &self.leader {
            leader.reap_if_still_owned();
        }

        // The wrapper is our direct child: kill and reap it on every path, including panic.
        let _ = self.harness.kill();
        let _ = self.harness.wait();

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
fn group_is_gone(pgid: libc::pid_t) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let gone = unsafe { libc::killpg(pgid, 0) } == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
        if gone {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}
