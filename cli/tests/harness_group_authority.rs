//! Regression coverage for harness-group instance authority and errno classification.
//!
//! Named classes from att_981d3490: same-group pre-stop, signal-time revalidation failure,
//! and (in unit tests) PID/PGID reuse plus macOS individual-PID EPERM handling.

use std::fs;
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::process::{Child, Command, Stdio};
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

    let harness = spawn_harness(binary, &identity_path, &leader);

    // Arm teardown the instant the wrapper exists — before `await_identity`, any floor call, or any
    // assertion — so even a failure to acquire the identity/token still waits the wrapper and clears
    // the scratch dir without ever signalling an unowned group.
    let mut session = OwnedSession::arm(harness, &dir);
    let leader_identity = await_identity(&identity_path);
    // The leader is live now; adopt it so teardown reaps exactly its birth-verified instance.
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

    // Teardown (owned-instance reap, wrapper wait, scratch removal) is owned by `session`'s Drop, so
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

    let harness = spawn_harness(binary, &identity_path, &leader);

    // Arm teardown the instant the wrapper exists — before `await_identity`, any floor call, or any
    // assertion — so even a failure to acquire the identity/token still waits the wrapper and clears
    // the scratch dir without ever signalling an unowned group.
    let mut session = OwnedSession::arm(harness, &dir);
    let leader_identity = await_identity(&identity_path);
    // The leader is live now; adopt it so teardown reaps exactly its birth-verified instance.
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

    // Teardown (owned-instance reap, wrapper wait, scratch removal) is owned by `session`'s Drop, so
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
    // The leader exits immediately: it is gone before its instance handle can be captured.
    let leader = script(&dir, "leader.sh", "exit 0\n");

    let harness = spawn_harness(binary, &identity_path, &leader);

    // OWN-AT-SPAWN: the guard owns the wrapper and scratch dir the instant the wrapper exists.
    let mut session = OwnedSession::arm(harness, &dir);
    let wrapper_pid = session.harness.id() as libc::pid_t;

    // Bounded acquisition attempt. Whether or not harness-exec wrote an identity for the already-dead
    // leader, `adopt` finds it gone, so no leader is ever adopted.
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if let Some(identity) = read_identity(&identity_path) {
            let _outcome = session.adopt(&identity);
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    // The dead leader is never adopted, so teardown will not signal any group.
    assert!(
        session.leader.is_none(),
        "a leader without a live instance handle must never be adopted"
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
/// unwind — even when the leader's `/proc` birth token is persistently unreadable, and it must do so
/// without ever signalling a group it did not birth-verify and without any external reap.
///
/// Authority is a `pidfd` captured at adoption: bound to the exact process instance, so teardown
/// reaps only while THAT instance is alive, immune to pid/pgid reuse and needing no `/proc` read. The
/// harness-exec wrapper is `setsid`-detached from the leader, so killing the wrapper cannot reap the
/// leader; only this instance-exact `killpg` can.
#[test]
fn owned_session_reaps_live_leader_after_persistent_token_failure_on_return() {
    let (wrapper_pid, leader_pgid) = run_live_leader_persistent_failure(|session| {
        // Normal return: `session` drops here, at end of the closure, under the active poison.
        drop(session);
    });
    assert!(
        is_gone(wrapper_pid),
        "the harness-exec wrapper must be killed and reaped on return"
    );
    assert!(
        group_is_gone(leader_pgid),
        "OwnedSession must reap the detached leader group itself on return — no external reap"
    );
}

#[test]
fn owned_session_reaps_live_leader_after_persistent_token_failure_on_unwind() {
    let (wrapper_pid, leader_pgid) = run_live_leader_persistent_failure(|session| {
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
        group_is_gone(leader_pgid),
        "OwnedSession must reap the detached leader group itself on unwind — no external reap"
    );
}

/// The pidfd authority must EXCLUDE pid/pgid reuse the numeric approach could not. Here a token
/// carries the numeric pid/pgid of a LIVE decoy but an instance handle (pidfd) for a DEAD victim,
/// while the decoy's `/proc` birth token is made unreadable — the exact situation where a stored
/// starttime plus current numeric pid/pgid cannot tell the decoy apart from the reaped victim. The
/// pidfd is bound to the victim instance, so teardown must issue NO signal and the live decoy, whose
/// numbers the token carried, must survive. (A fragile numeric reap would `killpg` the decoy — see the
/// RED control in the evidence.)
#[test]
fn a_gone_instance_is_never_signalled_even_when_its_numbers_are_reused() {
    let binary = env!("CARGO_BIN_EXE_tightbeam");

    // A live decoy leader we must NOT kill.
    let (decoy_dir, mut decoy_wrapper, decoy) = launch_detached_leader(binary, "decoy");
    // A victim leader: capture its instance handle, then kill it so the pidfd refers to a GONE instance.
    let (victim_dir, mut victim_wrapper, victim) = launch_detached_leader(binary, "victim");
    let victim_pidfd = pidfd_open(victim.pid).expect("victim pidfd must open while it is live");
    unsafe {
        libc::killpg(victim.pgid, libc::SIGKILL);
    }
    let _ = victim_wrapper.kill();
    let _ = victim_wrapper.wait();
    let deadline = Instant::now() + Duration::from_secs(5);
    while pidfd_instance_alive(&victim_pidfd) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !pidfd_instance_alive(&victim_pidfd),
        "the victim instance must be gone so its pidfd is a dead handle"
    );

    // Make the decoy's /proc birth token unreadable: the numeric-plus-starttime approach now has
    // nothing to distinguish the live decoy from the reaped victim — only the pidfd can.
    poison(decoy.pid);
    assert!(
        matches!(read_birth_token(decoy.pid), BirthToken::Unreadable),
        "the decoy's /proc token must be unreadable for this to exercise the fail-closed path"
    );

    // Token: numeric identity = LIVE decoy, instance handle = DEAD victim.
    let token = LeaderToken {
        pid: decoy.pid,
        pgid: decoy.pgid,
        pidfd: victim_pidfd,
    };
    token.reap_if_still_owned(); // pidfd(victim) is gone -> NO signal
    unpoison(decoy.pid);

    // Give any errant signal time to land, then require the decoy to still be alive: the pidfd
    // excluded the reuse. A fragile numeric reap would have SIGKILLed the decoy's group by now.
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        !is_gone(decoy.pid) && !group_is_gone_fast(decoy.pgid),
        "the live decoy sharing the token's pid/pgid must survive — pidfd excludes instance reuse"
    );

    // Cleanup: reap the decoy group and both wrappers/scratch dirs.
    unsafe {
        libc::killpg(decoy.pgid, libc::SIGKILL);
    }
    let _ = decoy_wrapper.kill();
    let _ = decoy_wrapper.wait();
    let _ = fs::remove_dir_all(&decoy_dir);
    let _ = fs::remove_dir_all(&victim_dir);
    assert!(group_is_gone(decoy.pgid), "decoy group must be cleaned up");
}

/// Shared body for the return/unwind proofs: launch a real detached leader that stays LIVE, arm the
/// guard, adopt it (capturing a pidfd instance handle BEFORE the fallible token step), then make its
/// `/proc` birth token PERSISTENTLY unreadable and hand the armed guard to `finish`, which drops it on
/// the path under test. Returns the wrapper pid and the leader's pgid so the caller can prove
/// everything is gone. The poison is lifted before returning so the caller's checks read real state.
fn run_live_leader_persistent_failure(
    finish: impl FnOnce(OwnedSession),
) -> (libc::pid_t, libc::pid_t) {
    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-acqfail-live-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let identity_path = dir.join("leader.identity");
    let leader = script(&dir, "leader.sh", "while :; do sleep 1; done\n");
    let harness = spawn_harness(binary, &identity_path, &leader);

    let mut session = OwnedSession::arm(harness, &dir);
    let wrapper_pid = session.harness.id() as libc::pid_t;
    let identity = await_identity(&identity_path);

    // Capture instance-exact cleanup authority (a pidfd) NOW, while the leader is live — BEFORE the
    // fallible token step. This is what the guard owns and later reaps.
    assert_eq!(
        session.adopt(&identity),
        AdoptOutcome::Adopted,
        "the live leader must adopt as birth-verified before the token failure is injected"
    );
    let leader_pgid = session
        .leader
        .as_ref()
        .expect("adoption captured a leader")
        .pgid;

    // Inject a PERSISTENT /proc birth-token read failure for this live leader. The pidfd reap does not
    // read /proc, so this must not affect teardown — that is exactly what these controls prove.
    poison(identity.pid);
    assert!(
        matches!(read_birth_token(identity.pid), BirthToken::Unreadable),
        "the leader's /proc token must be unreadable while it stays live"
    );

    // Drop the guard on the path under test (normal return or panic unwind). Teardown must reap the
    // owned instance despite the persistent token failure, using the pidfd authority.
    finish(session);

    unpoison(identity.pid);
    (wrapper_pid, leader_pgid)
}

struct Identity {
    path: String,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    boot: String,
}

/// Spawn the harness-exec wrapper for a leader script, detaching stdio.
fn spawn_harness(binary: &str, identity_path: &std::path::Path, leader: &std::path::Path) -> Child {
    Command::new(binary)
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
        .expect("the harness session launcher must start")
}

/// Launch a detached leader that stays live and return its scratch dir, wrapper child, and identity.
fn launch_detached_leader(binary: &str, tag: &str) -> (std::path::PathBuf, Child, Identity) {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let identity_path = dir.join("leader.identity");
    let leader = script(&dir, "leader.sh", "while :; do sleep 1; done\n");
    let harness = spawn_harness(binary, &identity_path, &leader);
    let identity = await_identity(&identity_path);
    (dir, harness, identity)
}

/// The Linux birth token for a pid: field 22 (`starttime`) of `/proc/<pid>/stat`. `comm` (field 2)
/// can contain spaces and parentheses, so parse the fields after the final `)`. `None` only means the
/// raw read/parse did not yield a token; callers resolve gone-vs-live via `read_birth_token`. This is
/// the legacy `/proc` token the reap path no longer trusts — kept only to establish the "unreadable"
/// precondition in the controls and to drive the fragile RED.
fn proc_starttime(pid: libc::pid_t) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.rsplit_once(')')?.1;
    // Post-`)` fields begin at `state` (field 3), so `starttime` (field 22) is index 19.
    after.split_whitespace().nth(19)?.parse().ok()
}

/// Test-only injection of a PERSISTENT birth-token acquisition failure for specific live pids. Keyed
/// on pid so a poisoned leader never disturbs the unrelated leaders of concurrently running tests, and
/// held in a set so several tests can each poison their own leader at once. Modelling a real `/proc`
/// read failure against a still-running process is how the controls establish that the pidfd reap
/// survives `/proc` unreadability.
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

/// True iff the pid is gone: `kill(pid, 0)` fails with `ESRCH`. Numeric and reuse-prone; used only for
/// coarse liveness of a wrapper/decoy, never as reaping authority.
fn is_gone(pid: libc::pid_t) -> bool {
    (unsafe { libc::kill(pid, 0) }) == -1
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

/// Open a pidfd for a pid: a handle bound to that exact process INSTANCE at open time. Unlike a bare
/// pid/pgid it cannot be silently rebound by reuse, and unlike a `/proc` starttime read it keeps
/// working when `/proc` is unavailable. `None` if the pid is already gone (or pidfd is unsupported).
fn pidfd_open(pid: libc::pid_t) -> Option<OwnedFd> {
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        None
    } else {
        // Safety: `pidfd_open` returned a fresh, owned file descriptor.
        Some(unsafe { OwnedFd::from_raw_fd(fd as RawFd) })
    }
}

/// True iff the EXACT instance the pidfd was opened for is still alive. The null signal (`0`) probes
/// liveness without delivering anything: `0` if that instance is alive, `-1`/`ESRCH` once it is gone.
/// Because the pidfd is instance-bound, this can never be fooled by a later process reusing the pid.
fn pidfd_instance_alive(pidfd: &OwnedFd) -> bool {
    let rc = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            pidfd.as_raw_fd(),
            0,
            std::ptr::null_mut::<libc::siginfo_t>(),
            0,
        )
    };
    rc == 0
}

/// The outcome of reading a leader's `/proc` birth token, distinguishing a process that is GONE from
/// one that is LIVE but whose token could not be read. Used by the controls to assert the "unreadable"
/// precondition; the reap path itself relies on the pidfd, not this.
enum BirthToken {
    Captured(u64),
    Gone,
    Unreadable,
}

fn read_birth_token(pid: libc::pid_t) -> BirthToken {
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

/// The result of adopting a detached leader for teardown.
#[must_use]
#[derive(Debug, PartialEq, Eq)]
enum AdoptOutcome {
    /// The leader was live and a pidfd instance handle was captured; its group is armed for reaping.
    Adopted,
    /// The leader was already gone; there is nothing to reap and no group will be signalled.
    Gone,
}

/// Instance-exact reaping authority for one detached leader: its recorded pid/pgid for the group
/// signal, plus a `pidfd` bound to the exact process instance captured while it was live. The pidfd is
/// the authority; the pid/pgid are only the numeric target of the group signal, which is issued solely
/// while the pidfd proves the captured instance is still alive.
struct LeaderToken {
    pid: libc::pid_t,
    pgid: libc::pid_t,
    pidfd: OwnedFd,
}

impl LeaderToken {
    /// SIGKILL the captured group, but only while the pidfd proves the EXACT instance we adopted is
    /// still alive. The harness leader ran `setsid`, so it is its own session/group leader with
    /// `pid == pgid`; while that instance is alive it uniquely owns its process group, so `killpg`
    /// cannot reach a group formed by a later process that reused the numbers. A gone instance (pidfd
    /// `ESRCH`) is never signalled. No `/proc` read is involved, so a persistent starttime failure
    /// cannot strip this authority — and a reused pid/pgid cannot borrow it.
    fn reap_if_still_owned(&self) {
        if pidfd_instance_alive(&self.pidfd) {
            debug_assert_eq!(
                self.pid, self.pgid,
                "a harness leader is its own group leader (setsid): pid must equal pgid"
            );
            unsafe {
                libc::killpg(self.pgid, libc::SIGKILL);
            }
        }
    }
}

/// Owns unconditional teardown of one harness-launched session. ARMED the instant the wrapper is
/// spawned — before `await_identity`, any floor call, or any assertion — so that even a failure to
/// acquire the leader identity still waits the wrapper and clears the scratch directory, and NEVER
/// signals a group it has not birth-verified. The detached leader is ADOPTED once its identity is
/// known and a `pidfd` for its live instance is captured; that pidfd is the instance-exact cleanup
/// authority, taken BEFORE any later fallible token step, so a persistent `/proc` token failure — or a
/// later pid/pgid reuse — can neither strip it nor borrow it. On drop, on every path — normal return
/// or panic: (1) reap the owned leader group via `LeaderToken::reap_if_still_owned` (only while the
/// pidfd-verified instance is alive); (2) kill and wait the owned wrapper (which is `setsid`-detached
/// from the leader, so it cannot reap the leader); (3) remove the scratch dir.
struct OwnedSession {
    harness: Child,
    dir: std::path::PathBuf,
    leader: Option<LeaderToken>,
}

impl OwnedSession {
    /// Take ownership of the wrapper and scratch dir immediately, before any fallible step, with no
    /// leader yet.
    fn arm(harness: Child, dir: &std::path::Path) -> Self {
        OwnedSession {
            harness,
            dir: dir.to_path_buf(),
            leader: None,
        }
    }

    /// Adopt the detached leader once its identity is known and it is live, capturing a `pidfd` for its
    /// exact instance as the guard's cleanup authority. `Gone` means the leader already exited (nothing
    /// to reap). If `pidfd_open` fails for a leader that is NOT gone, exact-instance authority is
    /// unavailable and we refuse loudly rather than fall back to unsafe numeric signalling.
    fn adopt(&mut self, identity: &Identity) -> AdoptOutcome {
        match pidfd_open(identity.pid) {
            Some(pidfd) if pidfd_instance_alive(&pidfd) => {
                assert_eq!(
                    identity.pid, identity.pgid,
                    "harness leader must be its own group leader (setsid): pid == pgid"
                );
                self.leader = Some(LeaderToken {
                    pid: identity.pid,
                    pgid: identity.pgid,
                    pidfd,
                });
                AdoptOutcome::Adopted
            }
            Some(_) => AdoptOutcome::Gone,
            None if is_gone(identity.pid) => AdoptOutcome::Gone,
            None => panic!(
                "pidfd_open failed for live leader {}: no exact-instance authority — refusing to fall \
                 back to numeric signalling",
                identity.pid
            ),
        }
    }
}

impl Drop for OwnedSession {
    fn drop(&mut self) {
        // Reap the owned leader group FIRST, while its instance handle is in hand: the wrapper is
        // `setsid`-detached from the leader, so killing the wrapper can never reap the leader — only
        // this instance-exact `killpg` can. An unadopted or gone leader is never signalled.
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

/// Parse a written identity file into an `Identity`, or `None` if it is not yet fully written.
fn read_identity(path: &std::path::Path) -> Option<Identity> {
    let text = fs::read_to_string(path).ok()?;
    let fields: Vec<&str> = text.trim_end().split('\t').collect();
    if let [pid, pgid, boot, _launch] = fields[..] {
        if let (Ok(pid), Ok(pgid)) = (pid.parse(), pgid.parse()) {
            return Some(Identity {
                path: path.to_string_lossy().into_owned(),
                pid,
                pgid,
                boot: boot.to_owned(),
            });
        }
    }
    None
}

fn await_identity(path: &std::path::Path) -> Identity {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Some(identity) = read_identity(path) {
            return identity;
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    panic!("{} was never written", path.display());
}

/// Poll until no process remains in the group, bounded — proof that a reaped leader group is gone
/// rather than merely signalled. The detached leader is not our child, so it is reaped by its
/// subreaper after the SIGKILL; `killpg(pgid, 0)` returns `ESRCH` once the group is empty.
/// Non-blocking check: is the group already empty right now?
fn group_is_gone_fast(pgid: libc::pid_t) -> bool {
    (unsafe { libc::killpg(pgid, 0) }) == -1
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

fn group_is_gone(pgid: libc::pid_t) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let gone = (unsafe { libc::killpg(pgid, 0) }) == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
        if gone {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}
