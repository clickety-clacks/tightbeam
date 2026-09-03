//! Regression coverage for harness-group instance authority and errno classification.
//!
//! Named classes from att_981d3490: same-group pre-stop, signal-time revalidation failure,
//! and (in unit tests) PID/PGID reuse plus macOS individual-PID EPERM handling.
//!
//! Per ruling att_a96078c0 the test-side cleanup is deliberately NOT a group supervisor: a
//! privileged cgroup/PID-namespace boundary is unavailable to the test user. Each control launches a
//! SINGLE-PROCESS detached leader (harness-exec execs one bounded `sleep`, so the session has no child
//! process tree), captures a `pidfd` for that exact instance after identity, and `OwnedSession::Drop`
//! SIGKILLs it DIRECTLY through `pidfd_send_signal`. That is reuse-proof (a pidfd is bound to one
//! instance) and needs no `/proc`; there is no numeric `killpg`. Production harness-group authority is
//! asserted separately below via the real `harness-group` command — the test cleanup does not re-prove
//! it.

use std::fs;
use std::io;
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// A bounded lifetime for every single-process leader: long enough to outlive any control, short
/// enough that an escaped leader self-exits rather than lingering.
const LEADER_SECONDS: &str = "600";

/// Same-group protection must run before SIGSTOP: a caller inside the recorded group must
/// not freeze itself and hang forever. (Production harness-group authority assertion.)
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

    let harness = spawn_sleep_leader(binary, &identity_path);

    // Arm teardown the instant the wrapper exists — before `await_identity`, any floor call, or any
    // assertion — so even a failure to acquire the identity still waits the wrapper and clears the
    // scratch dir without ever signalling anything it did not birth-verify.
    let mut session = OwnedSession::arm(harness, &dir);
    let leader_identity = await_identity(&identity_path);
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

    // Teardown (direct pidfd SIGKILL of the leader, wrapper wait, scratch removal) is owned by
    // `session`'s Drop, so it runs on this normal return and on any assertion unwind above.
}

/// Identity revalidation at signal time must refuse a boot mismatch before any kill.
/// (Production harness-group authority assertion.)
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

    let harness = spawn_sleep_leader(binary, &identity_path);

    let mut session = OwnedSession::arm(harness, &dir);
    let leader_identity = await_identity(&identity_path);
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
}

/// `adopt` must classify a gone leader DETERMINISTICALLY from `pidfd_open`'s own errno, with no numeric
/// check and no reuse window. Rather than race a real leader's exit, this adopts an UNALLOCATABLE pid
/// (strictly above `/proc/sys/kernel/pid_max`), which the kernel can never allocate, so `pidfd_open`
/// always fails with `ESRCH` → `Gone`. Meanwhile an `OwnedSession` already owns a real wrapper and
/// scratch dir (from a single-process leader that self-exits): the guard must still kill and wait the
/// wrapper and remove the scratch, and must NEVER signal an instance it could not capture.
#[test]
fn adopt_classifies_an_unallocatable_pid_as_gone_without_signalling() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-gone-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let identity_path = dir.join("leader.identity");

    // A real wrapper + scratch dir owned from spawn. The leader self-exits (`/bin/true`), so leaving it
    // unadopted below cannot leak it.
    let harness = spawn_leader(binary, &identity_path, &["/bin/true"]);
    let mut session = OwnedSession::arm(harness, &dir);
    let wrapper_pid = session.harness.id() as libc::pid_t;

    // Adopt an identity whose pid can never exist. `pidfd_open` fails with `ESRCH` atomically, so this
    // is a deterministic `Gone` with no live process and no check-to-open reuse race.
    let gone = unallocatable_pid();
    let identity = Identity {
        path: identity_path.to_string_lossy().into_owned(),
        pid: gone,
        pgid: gone,
        boot: String::new(),
    };
    assert_eq!(
        session.adopt(&identity),
        AdoptOutcome::Gone,
        "an unallocatable pid must classify as Gone from pidfd_open's ESRCH"
    );
    assert!(
        session.leader.is_none(),
        "a Gone leader must never be armed for signalling"
    );

    drop(session);

    assert!(
        !dir.exists(),
        "scratch directory must be removed even when no leader was adopted"
    );
    assert!(
        wait_gone(wrapper_pid),
        "the harness-exec wrapper must be killed and reaped"
    );
}

/// `OwnedSession` must reap the LIVE detached leader ITSELF — on a normal return AND on a panic
/// unwind — leaving zero wrapper/leader/PID1/scratch, with no external reap. Authority is a `pidfd`
/// captured at adoption and SIGKILLed directly: bound to the exact instance, immune to pid reuse, and
/// needing no `/proc`. The harness-exec wrapper is `setsid`-detached from the leader, so killing the
/// wrapper cannot reap the leader; only this direct pidfd signal can.
#[test]
fn owned_session_reaps_live_leader_on_return() {
    let (wrapper_pid, leader_pid) = run_live_leader(|session| {
        // Normal return: `session` drops here, at end of the closure.
        drop(session);
    });
    assert!(
        wait_gone(wrapper_pid),
        "the harness-exec wrapper must be killed and reaped on return"
    );
    assert!(
        wait_gone(leader_pid),
        "OwnedSession must reap the detached leader itself on return — no external reap"
    );
}

#[test]
fn owned_session_reaps_live_leader_on_unwind() {
    let (wrapper_pid, leader_pid) = run_live_leader(|session| {
        // Panic unwind: `session`'s Drop must still reap everything as the stack unwinds.
        let result = catch_unwind(AssertUnwindSafe(move || {
            let _owned = session;
            panic!("forced failure inside the guarded scope");
        }));
        assert!(
            result.is_err(),
            "the forced failure must unwind through Drop"
        );
    });
    assert!(
        wait_gone(wrapper_pid),
        "the harness-exec wrapper must be killed and reaped on unwind"
    );
    assert!(
        wait_gone(leader_pid),
        "OwnedSession must reap the detached leader itself on unwind — no external reap"
    );
}

/// The pidfd authority must EXCLUDE pid reuse that a numeric signal could not. A token carries the
/// numeric pid of a LIVE decoy but a `pidfd` for a DEAD victim. A DIRECT pidfd SIGKILL must return
/// `ESRCH` (the victim instance is gone) and leave the live decoy untouched. A numeric fallback would
/// signal the decoy's pid — see the RED control in the evidence.
#[test]
fn a_gone_instance_is_never_signalled_even_when_its_pid_is_reused() {
    let binary = env!("CARGO_BIN_EXE_tightbeam");

    // Both sessions take teardown ownership at spawn (an `OwnedSession` each), BEFORE any identity
    // acquisition or assertion below, so a panic anywhere in this control still reaps every wrapper,
    // leader, and scratch dir on unwind — no manual cleanup, nothing to leak.
    let (decoy_session, decoy_pid) = launch_owned_leader(binary, "decoy");

    let (victim_session, victim_pid) = launch_owned_leader(binary, "victim");
    // A pidfd bound to the victim instance, captured while it is live and kept past the victim's death.
    let victim_pidfd = pidfd_open(victim_pid).expect("victim pidfd must open while it is live");
    // Reap the victim: its own guard SIGKILLs it directly, waits its wrapper, and removes its scratch.
    drop(victim_session);
    let deadline = Instant::now() + Duration::from_secs(5);
    while pidfd_kill(&victim_pidfd).is_ok() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }

    // Token: numeric pid = LIVE decoy, instance handle = DEAD victim.
    let token = LeaderToken {
        pid: decoy_pid,
        pidfd: victim_pidfd,
    };

    // A direct pidfd SIGKILL targets the captured (dead victim) instance and must report ESRCH; it
    // cannot reach the decoy that now holds the same numeric pid.
    let err = token
        .reap()
        .expect_err("signalling a dead instance's pidfd must fail");
    assert_eq!(
        err.raw_os_error(),
        Some(libc::ESRCH),
        "a dead pidfd must yield ESRCH, never a signal to a reused pid"
    );

    // Give any errant signal time to land, then require the decoy to still be alive.
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        !is_gone(decoy_pid),
        "the live decoy sharing the token's pid must survive — pidfd excludes instance reuse"
    );

    // The decoy's guard reaps it (directly, then its wrapper and scratch) here — and equally on any
    // panic above, since it owned teardown from spawn.
    drop(decoy_session);
    assert!(
        wait_gone(decoy_pid),
        "the decoy must be reaped by its guard"
    );
}

/// Shared body for the return/unwind proofs: launch a real single-process detached leader that stays
/// LIVE, arm the guard, adopt it (capturing a pidfd instance handle), and hand the armed guard to
/// `finish`, which drops it on the path under test. Returns the wrapper and leader pids so the caller
/// can prove both are gone.
fn run_live_leader(finish: impl FnOnce(OwnedSession)) -> (libc::pid_t, libc::pid_t) {
    let binary = env!("CARGO_BIN_EXE_tightbeam");
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-live-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let identity_path = dir.join("leader.identity");
    let harness = spawn_sleep_leader(binary, &identity_path);

    let mut session = OwnedSession::arm(harness, &dir);
    let wrapper_pid = session.harness.id() as libc::pid_t;
    let identity = await_identity(&identity_path);

    assert_eq!(
        session.adopt(&identity),
        AdoptOutcome::Adopted,
        "the live leader must adopt as birth-verified"
    );
    let leader_pid = session
        .leader
        .as_ref()
        .expect("adoption captured a leader")
        .pid;

    // Drop the guard on the path under test (normal return or panic unwind). Teardown must reap the
    // owned instance directly through its pidfd.
    finish(session);

    (wrapper_pid, leader_pid)
}

struct Identity {
    path: String,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    boot: String,
}

/// Spawn the harness-exec wrapper for a leader command, detaching stdio. `leader_argv` is the exact
/// program the detached session leader execs — a SINGLE process, no shell/child tree.
fn spawn_leader(binary: &str, identity_path: &std::path::Path, leader_argv: &[&str]) -> Child {
    let mut args = vec![
        "harness-exec",
        &identity_path.to_str().unwrap(),
        "leader-launch",
        "--",
    ];
    args.extend_from_slice(leader_argv);
    Command::new(binary)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("the harness session launcher must start")
}

/// Spawn a single-process leader that stays live for the whole control: one bounded `sleep`.
fn spawn_sleep_leader(binary: &str, identity_path: &std::path::Path) -> Child {
    spawn_leader(binary, identity_path, &["/bin/sleep", LEADER_SECONDS])
}

/// Launch a live single-process leader already OWNED by an armed+adopted `OwnedSession`, returning the
/// guard and the leader pid. Ownership of the wrapper and scratch dir exists from the instant the
/// wrapper is spawned (before `await_identity`), and the leader is adopted for direct pidfd reaping, so
/// the caller can perform fallible steps knowing a panic will still reap the wrapper, leader, and
/// scratch on unwind.
fn launch_owned_leader(binary: &str, tag: &str) -> (OwnedSession, libc::pid_t) {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-harness-group-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let identity_path = dir.join("leader.identity");
    let harness = spawn_sleep_leader(binary, &identity_path);
    let mut session = OwnedSession::arm(harness, &dir);
    let identity = await_identity(&identity_path);
    assert_eq!(
        session.adopt(&identity),
        AdoptOutcome::Adopted,
        "a live leader must adopt as birth-verified"
    );
    (session, identity.pid)
}

/// True iff the pid is gone: `kill(pid, 0)` fails with `ESRCH`. Numeric and reuse-prone; used only for
/// coarse liveness of a wrapper/decoy, never as reaping authority.
fn is_gone(pid: libc::pid_t) -> bool {
    (unsafe { libc::kill(pid, 0) }) == -1
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

/// Poll until the pid is gone, bounded. A reaped detached leader may briefly linger as a zombie until
/// its subreaper collects it; this waits that out.
fn wait_gone(pid: libc::pid_t) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if is_gone(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

/// Open a pidfd for a pid: a handle bound to that exact process INSTANCE at open time. Unlike a bare
/// pid it cannot be silently rebound by reuse, and unlike a `/proc` read it needs no procfs. This is a
/// SINGLE syscall that atomically both checks liveness and binds the instance, so it carries its own
/// authority — `Err(ESRCH)` iff the pid has no process, without any separate check-then-open window a
/// reused pid could slip through. The errno is preserved so callers can classify it.
fn pidfd_open(pid: libc::pid_t) -> io::Result<OwnedFd> {
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        // Safety: `pidfd_open` returned a fresh, owned file descriptor.
        Ok(unsafe { OwnedFd::from_raw_fd(fd as RawFd) })
    }
}

/// A Linux pid strictly greater than `/proc/sys/kernel/pid_max`: the kernel can never allocate it, so
/// `pidfd_open` on it deterministically fails with `ESRCH`. Used to exercise the `Gone` classification
/// without a live process or any reuse race.
fn unallocatable_pid() -> libc::pid_t {
    let pid_max: i64 = std::fs::read_to_string("/proc/sys/kernel/pid_max")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(4_194_304);
    // Stay within pid_t while remaining above pid_max.
    libc::pid_t::try_from(pid_max + 1).unwrap_or(libc::pid_t::MAX)
}

/// SIGKILL the exact instance the pidfd was opened for. Reuse-proof: the pidfd is instance-bound, so a
/// later process reusing the pid can never be reached. A gone instance yields `Err(ESRCH)`.
fn pidfd_kill(pidfd: &OwnedFd) -> io::Result<()> {
    let rc = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            pidfd.as_raw_fd(),
            libc::SIGKILL,
            std::ptr::null_mut::<libc::siginfo_t>(),
            0,
        )
    };
    if rc == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// The result of adopting a detached leader for teardown.
#[must_use]
#[derive(Debug, PartialEq, Eq)]
enum AdoptOutcome {
    /// The leader was live and a pidfd instance handle was captured; it is armed for a direct reap.
    Adopted,
    /// The leader was already gone; there is nothing to reap and nothing will be signalled.
    Gone,
}

/// Instance-exact reaping authority for one single-process detached leader: a `pidfd` bound to the
/// exact instance captured while it was live. The pid is retained only for diagnostics/absence checks;
/// the pidfd is the sole signalling authority.
struct LeaderToken {
    pid: libc::pid_t,
    pidfd: OwnedFd,
}

impl LeaderToken {
    /// SIGKILL the captured instance DIRECTLY through its pidfd — never a numeric pid/pgid signal. A
    /// gone instance returns `Err(ESRCH)` and nothing else is ever touched.
    fn reap(&self) -> io::Result<()> {
        pidfd_kill(&self.pidfd)
    }
}

/// Owns unconditional teardown of one harness-launched session. ARMED the instant the wrapper is
/// spawned — before `await_identity` or any assertion — so that even a failure to acquire the leader
/// identity still waits the wrapper and clears the scratch directory, and NEVER signals anything it
/// did not capture. The single-process detached leader is ADOPTED once its identity is known and a
/// `pidfd` for its live instance is captured. On drop, on every path — normal return or panic: (1)
/// SIGKILL the owned leader directly through its pidfd (the wrapper is `setsid`-detached from the
/// leader, so killing the wrapper cannot reap the leader — only this can); (2) kill and wait the owned
/// wrapper; (3) remove the scratch dir.
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

    /// Adopt the detached leader from a single `pidfd_open`, which atomically both checks liveness and
    /// binds the exact instance. The classification is the syscall's own errno — no separate numeric
    /// check that a reused pid could slip through between: a returned pidfd is authority to reap this
    /// instance (`Adopted`); `ESRCH` means the pid has no process, so there is nothing to reap (`Gone`);
    /// any other errno means exact-instance authority is unavailable, and we refuse loudly rather than
    /// fall back to numeric signalling.
    fn adopt(&mut self, identity: &Identity) -> AdoptOutcome {
        match pidfd_open(identity.pid) {
            Ok(pidfd) => {
                self.leader = Some(LeaderToken {
                    pid: identity.pid,
                    pidfd,
                });
                AdoptOutcome::Adopted
            }
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => AdoptOutcome::Gone,
            Err(error) => panic!(
                "pidfd_open failed for leader {} with {error}: no exact-instance authority — refusing \
                 to fall back to numeric signalling",
                identity.pid
            ),
        }
    }
}

impl Drop for OwnedSession {
    fn drop(&mut self) {
        // Reap the owned leader FIRST, directly through its pidfd: the wrapper is `setsid`-detached
        // from the leader, so killing the wrapper can never reap the leader. A gone leader returns
        // ESRCH and nothing else is signalled; an unadopted leader is never touched.
        if let Some(leader) = &self.leader {
            let _ = leader.reap();
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
