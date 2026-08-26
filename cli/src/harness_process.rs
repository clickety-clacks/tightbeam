use crate::process_tree::Snapshot;
use std::collections::BTreeSet;
use std::fs;
use std::fs::OpenOptions;
use std::io::{Read, Write};
#[cfg(target_os = "macos")]
use std::os::darwin::fs::MetadataExt as DarwinMetadataExt;
#[cfg(target_os = "macos")]
use std::os::unix::fs::MetadataExt as UnixMetadataExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

pub fn session_exec(args: &[String]) -> Result<i32, String> {
    let separator = args.iter().position(|arg| arg == "--").ok_or_else(|| {
        "usage: tightbeam harness-exec <identity-path> <launch-id> -- <command> [args...]"
            .to_string()
    })?;

    if separator != 2 || args.len() <= separator + 1 {
        return Err(
            "usage: tightbeam harness-exec <identity-path> <launch-id> -- <command> [args...]"
                .into(),
        );
    }

    let identity_path = Path::new(&args[0]);

    if let Some(parent) = identity_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("harness identity directory could not be created: {error}"))?;
    }

    let mut identity = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(identity_path)
        .map_err(|error| format!("harness identity could not be opened: {error}"))?;

    match unsafe { libc::fork() } {
        -1 => {
            return Err(format!(
                "harness session launcher could not fork: {}",
                std::io::Error::last_os_error()
            ));
        }
        0 => {}
        child => return wait_for_session_child(child),
    }

    if unsafe { libc::setsid() } == -1 {
        return Err(format!(
            "harness session could not be created: {}",
            std::io::Error::last_os_error()
        ));
    }

    let pid = unsafe { libc::getpid() };
    let pgid = unsafe { libc::getpgrp() };

    if pid != pgid {
        return Err(format!(
            "harness session leader mismatch: pid {pid}, process group {pgid}"
        ));
    }

    let boot_identity = boot_identity()?;
    let launch_id = &args[1];

    writeln!(identity, "{pid}\t{pgid}\t{boot_identity}\t{launch_id}")
        .and_then(|_| identity.sync_all())
        .map_err(|error| format!("harness identity could not be written: {error}"))?;

    let error = Command::new(&args[separator + 1])
        .args(&args[separator + 2..])
        .exec();

    Err(format!("harness command could not be executed: {error}"))
}

fn wait_for_session_child(child: libc::pid_t) -> Result<i32, String> {
    let mut status = 0;

    loop {
        let waited = unsafe { libc::waitpid(child, &mut status, 0) };

        if waited == child {
            if libc::WIFEXITED(status) {
                return Ok(libc::WEXITSTATUS(status));
            }

            if libc::WIFSIGNALED(status) {
                return Ok(128 + libc::WTERMSIG(status));
            }

            return Err("harness session child ended without an exit status".into());
        }

        let error = std::io::Error::last_os_error();

        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(format!(
                "harness session child could not be waited: {error}"
            ));
        }
    }
}

pub fn print_boot_identity() -> Result<(), String> {
    println!("{}", boot_identity()?);
    Ok(())
}

pub fn group(args: &[String]) -> Result<i32, String> {
    if args.len() != 4 {
        return Err(
            "usage: tightbeam harness-group <process-group-id> <identity-path> <boot-identity> <launch-id>"
                .into(),
        );
    }

    let pgid: libc::pid_t = args[0]
        .parse::<i32>()
        .ok()
        .filter(|pgid| *pgid > 0)
        .ok_or_else(|| "process group id must be a positive integer".to_string())?;

    let target = HarnessTarget {
        pgid,
        identity_path: args[1].clone(),
        boot_identity: args[2].clone(),
        launch_id: args[3].clone(),
    };
    target.revalidate_before_signal()?;

    kill_harness_tree(&target, freeze_harness_tree(&target)?)
}

/// The authorized harness instance every signal in a sweep must still be killing.
struct HarnessTarget {
    pgid: libc::pid_t,
    identity_path: String,
    boot_identity: String,
    launch_id: String,
}

impl HarnessTarget {
    /// Re-read boot identity, the identity file, and the live session leader before a signal.
    ///
    /// A pgid can be reused once the leader is gone; signalling the number alone is not enough
    /// to know the process group still belongs to this launch.
    fn revalidate_before_signal(&self) -> Result<(), String> {
        authorize_group_signal(
            Path::new(&self.identity_path),
            self.pgid,
            &self.boot_identity,
            &self.launch_id,
        )?;
        verify_session_leader_alive(self.pgid)
    }
}

/// The recorded session leader must still lead `pgid` whenever it is still live.
///
/// Once the leader has exited, `getpgid` cannot answer for it; the identity file and the
/// freeze snapshot are what still bind the sweep. A live pid that is no longer the leader
/// of `pgid` is reuse and must refuse before any signal is sent.
fn verify_session_leader_alive(pgid: libc::pid_t) -> Result<(), String> {
    let actual_pgid = unsafe { libc::getpgid(pgid) };
    if actual_pgid == -1 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }
        return Err(format!(
            "harness session leader {pgid} process group could not be read: {error}"
        ));
    }
    if actual_pgid != pgid {
        return Err(format!(
            "process group {pgid} no longer matches its session leader \
             (now in group {actual_pgid})"
        ));
    }

    Ok(())
}

/// How many times the sweep re-reads the table looking for something new to freeze.
///
/// Each round freezes everything the last one found, so a tree that is merely deep or
/// merely busy settles in two or three. The bound is what a tree that forks faster than it
/// can be frozen runs into, and reaching it is not a reason to stop: the frozen majority
/// still gets killed below, and the alternative to killing what we have is killing nothing.
const FREEZE_ROUNDS: usize = 8;

/// Stop the harness tree, so the set that is enumerated is the set that exists.
///
/// The defect this closes, measured live on pi 0.84.2 (spike 2026-08-23): harnesses spawn
/// bash children with node's `detached: true`, which `setsid`s each one into a process
/// group of its own. The floor's single `killpg(10421)` killed the harness and left its
/// `sleep 400` grandchild — group 10957 — alive and reparented to init. opencode 1.18.18
/// has the same signature. The harness cannot be asked to tidy up after itself on this
/// path: the premise of the floor is that it was SIGKILLed and never got the chance.
///
/// A running tree cannot be enumerated correctly. Between a snapshot and the kill it forks,
/// and a child of an escapee we have not found yet is an escapee we never see. SIGSTOP
/// cannot be caught or blocked, so freezing first turns the walk into a reading of
/// something that is holding still.
///
/// Nothing from here to the kill may return early. A frozen tree that never gets its
/// SIGKILL never dies at all — strictly worse than the orphan this replaces — so every
/// failure below is recorded on the sweep rather than silently dropped.
fn freeze_harness_tree(target: &HarnessTarget) -> Result<Sweep, String> {
    let pgid = target.pgid;
    // Us, and the group we are in. `harness-group` run BY HAND from inside the very session
    // it is parking is a descendant of the group it sweeps: freezing ourselves there stops
    // this process forever, with the whole tree stopped behind it and nothing left running
    // to kill any of it. Same-group protection runs BEFORE any killpg(SIGSTOP), so an
    // in-group caller can exclude itself instead of stopping the whole walk.
    let me = unsafe { libc::getpid() };
    let my_group = unsafe { libc::getpgrp() };

    let mut sweep = Sweep {
        frozen: BTreeSet::new(),
        groups: BTreeSet::from([pgid]),
        incomplete: false,
    };
    sweep.groups.remove(&my_group);

    target.revalidate_before_signal()?;

    if pgid == my_group {
        // Never killpg the recorded group: we are in it. The first snapshot round below
        // SIGSTOPs the other members individually.
    } else {
        signal_process_group(pgid, libc::SIGSTOP, target)?;
    }

    let mut rounds = 0;
    let mut found_more = true;
    while rounds < FREEZE_ROUNDS {
        target.revalidate_before_signal()?;

        let snapshot = match Snapshot::capture() {
            Ok(snapshot) => snapshot,
            Err(reason) => {
                sweep.incomplete = true;
                eprintln!(
                    "harness-group: process table unreadable ({reason}); \
                     signalling the recorded group only"
                );
                break;
            }
        };

        let tree = snapshot.group_tree(pgid);
        sweep.groups.extend(snapshot.process_groups(&tree));

        found_more = false;
        for pid in tree {
            if pid == me || !sweep.frozen.insert(pid) {
                continue;
            }
            found_more = true;
            signal_process(pid, libc::SIGSTOP, target)?;
        }

        // The exit condition is the state itself — a reading that adds nobody — not a
        // count of rounds that usually suffices.
        if !found_more {
            break;
        }
        rounds += 1;
    }

    if found_more {
        sweep.incomplete = true;
    }

    Ok(sweep)
}

/// What one freeze pass established: the pids it stopped, and every group they sit in.
///
/// Neither set ever names this process or its group — `freeze_harness_tree` is the only
/// thing that fills them, and it excludes both. Everything in here is signalable.
struct Sweep {
    frozen: BTreeSet<libc::pid_t>,
    groups: BTreeSet<libc::pid_t>,
    /// True when the walk could not prove it saw the whole tree before the kill.
    incomplete: bool,
}

fn signal_process_group(
    pgid: libc::pid_t,
    signal: libc::c_int,
    target: &HarnessTarget,
) -> Result<(), String> {
    target.revalidate_before_signal()?;
    if unsafe { libc::killpg(pgid, signal) } == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if group_signal_target_gone(&error) {
        return Ok(());
    }
    Err(format!(
        "process group {pgid} could not be signalled: {error}"
    ))
}

fn signal_process(
    pid: libc::pid_t,
    signal: libc::c_int,
    target: &HarnessTarget,
) -> Result<(), String> {
    target.revalidate_before_signal()?;
    if unsafe { libc::kill(pid, signal) } == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Ok(());
    }
    Err(format!("process {pid} could not be signalled: {error}"))
}

/// A group with no live members to signal — linux says ESRCH, darwin often EPERM.
fn group_signal_target_gone(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH)
        || (cfg!(target_os = "macos") && error.raw_os_error() == Some(libc::EPERM))
}

/// SIGKILL everything the freeze proved was ours, then the recorded group last.
///
/// SIGKILL reaches a stopped process — neither signal can be caught or blocked, and the
/// kernel wakes a stopped task to die — so the freeze above needs no SIGCONT to undo.
///
/// Escaped groups are signalled BEFORE the recorded one. On the hand-run path the recorded
/// group can contain this very process, and a sweep that killed its own caller first would
/// leave behind precisely the escapees it had just finished identifying.
///
/// The pid-by-pid pass is not redundant with the group pass: it kills exactly what the walk
/// proved, where the group pass also reaches anything that appeared inside those groups
/// since the last reading.
///
/// Incomplete cleanup is a loud failure: exit non-zero so the adapter fence stays up until
/// an operator clears it. A recorded-group kill that succeeded while escapees remain must
/// not read as success.
fn kill_harness_tree(target: &HarnessTarget, sweep: Sweep) -> Result<i32, String> {
    let pgid = target.pgid;
    let mut cleanup_failures = Vec::new();

    if sweep.incomplete {
        cleanup_failures.push("harness tree freeze did not prove complete before kill".to_string());
    }

    for group in sweep.groups.iter().filter(|group| **group != pgid) {
        if let Some(reason) = sigkill_stray(Stray::Group(*group), target) {
            cleanup_failures.push(reason);
        }
    }

    for pid in &sweep.frozen {
        if let Some(reason) = sigkill_stray(Stray::Process(*pid), target) {
            cleanup_failures.push(reason);
        }
    }

    target.revalidate_before_signal()?;
    let recorded = if unsafe { libc::killpg(pgid, libc::SIGKILL) } == 0 {
        Ok(0)
    } else {
        classify_group_kill(pgid, std::io::Error::last_os_error())
    };

    if cleanup_failures.is_empty() {
        recorded
    } else {
        Err(format!(
            "harness cleanup incomplete: {}",
            cleanup_failures.join("; ")
        ))
    }
}

/// One escapee the walk found — a whole group of them, or a single process.
enum Stray {
    Group(libc::pid_t),
    Process(libc::pid_t),
}

/// SIGKILL one escapee, and report if it would not die.
///
/// The signal and the `errno` read are in the same function on purpose: `errno` describes
/// the last failing call on this thread, and the file already learned once (`bounded_command`)
/// what it costs when a failure is reported against a call that did not produce it.
///
/// "Already gone" is the ordinary outcome here, not an anomaly: the freeze does not stop a
/// process that had already exited, and darwin reports an emptied group as EPERM — the same
/// fact `classify_group_kill` records for the recorded group, for the same reason, which is
/// that the target was established as ours before it was signalled.
fn sigkill_stray(stray: Stray, target: &HarnessTarget) -> Option<String> {
    if let Err(error) = target.revalidate_before_signal() {
        return Some(error);
    }

    let (result, target_label) = match stray {
        Stray::Group(pgid) => (
            unsafe { libc::killpg(pgid, libc::SIGKILL) },
            format!("process group {pgid}"),
        ),
        Stray::Process(pid) => (
            unsafe { libc::kill(pid, libc::SIGKILL) },
            format!("process {pid}"),
        ),
    };

    if result == 0 {
        return None;
    }

    let error = std::io::Error::last_os_error();
    let gone = group_signal_target_gone(&error);

    if gone {
        None
    } else {
        let reason = format!("escaped {target_label} outlived SIGKILL: {error}");
        eprintln!("harness-group: {reason}");
        Some(reason)
    }
}

/// A group that is already gone is a success, and darwin says so differently.
///
/// linux answers ESRCH when nothing in the group can be signalled. macOS answers EPERM once
/// the group's members have all exited -- the group id still resolves, but there is nothing
/// live in it to own. Treating that as a failure turns "already dead" into "could not kill",
/// which is what it did: a live onboarding aborted with
/// `kill_failed: process group 62968 could not be signalled: Operation not permitted`
/// against a group that `kill -0` reported as no such process.
///
/// EPERM is only read this way AFTER `authorize_group_signal` has established the group is
/// ours by identity and boot epoch. Without that check EPERM would be ambiguous with
/// somebody else's group, which is exactly what it means on linux and why this is
/// darwin-only. `child_process.rs` already carries the same guard for the same reason; this
/// is the one place that knew the fact in only one language.
fn classify_group_kill(pgid: libc::pid_t, error: std::io::Error) -> Result<i32, String> {
    if group_signal_target_gone(&error) {
        Ok(0)
    } else {
        Err(format!(
            "process group {pgid} could not be signalled: {error}"
        ))
    }
}

#[cfg(test)]
mod group_kill_tests {
    use super::classify_group_kill;
    use std::io::Error;

    /// linux's answer for "nothing here to signal".
    #[test]
    fn esrch_is_already_gone_on_every_platform() {
        assert!(classify_group_kill(1234, Error::from_raw_os_error(libc::ESRCH)).is_ok());
    }

    /// darwin's answer for the same state. Read as a failure it aborted a live onboarding
    /// against a group `kill -0` reported as no such process.
    #[test]
    #[cfg(target_os = "macos")]
    fn eperm_is_already_gone_on_darwin() {
        assert!(classify_group_kill(1234, Error::from_raw_os_error(libc::EPERM)).is_ok());
    }

    /// On linux EPERM means somebody else's group, which must stay an error -- the darwin
    /// reading is not portable and must not leak across.
    #[test]
    #[cfg(target_os = "linux")]
    fn eperm_is_still_a_refusal_on_linux() {
        assert!(classify_group_kill(1234, Error::from_raw_os_error(libc::EPERM)).is_err());
    }

    /// Anything else is a real failure and must name itself.
    #[test]
    fn an_unexpected_errno_is_reported_with_the_group() {
        let error = classify_group_kill(4321, Error::from_raw_os_error(libc::EINVAL)).unwrap_err();
        assert!(error.contains("4321"), "{error}");
        assert!(error.contains("could not be signalled"), "{error}");
    }
}

#[cfg(target_os = "linux")]
fn boot_identity() -> Result<String, String> {
    fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|value| value.trim().to_owned())
        .map_err(|error| format!("kernel boot identity unavailable: {error}"))
}

#[cfg(target_os = "macos")]
fn boot_identity() -> Result<String, String> {
    let metadata = fs::metadata("/var/run/com.apple.logind.didRunThisBoot")
        .map_err(|error| format!("boot marker unavailable: {error}"))?;
    Ok(format!(
        "logind-this-boot:{}:{}:{}",
        metadata.dev(),
        metadata.ino(),
        metadata.st_birthtime()
    ))
}

fn authorize_group_signal(
    path: &Path,
    pgid: libc::pid_t,
    expected_boot_identity: &str,
    launch_id: &str,
) -> Result<(), String> {
    if boot_identity()? != expected_boot_identity {
        return Err("harness boot identity does not match the current boot".into());
    }

    let mut identity = OpenOptions::new()
        .read(true)
        .open(path)
        .map_err(|error| format!("harness identity could not be opened: {error}"))?;

    let mut recorded = String::new();
    identity
        .read_to_string(&mut recorded)
        .map_err(|error| format!("harness identity could not be read: {error}"))?;
    if recorded.trim_end() != format!("{pgid}\t{pgid}\t{expected_boot_identity}\t{launch_id}") {
        return Err("harness identity does not match the requested process group".into());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn test_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "tightbeam-harness-process-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn group_rejects_non_positive_ids() {
        assert!(
            group(&[
                "0".into(),
                "identity".into(),
                "boot".into(),
                "launch".into()
            ])
            .is_err()
        );
        assert!(
            group(&[
                "-1".into(),
                "identity".into(),
                "boot".into(),
                "launch".into()
            ])
            .is_err()
        );
    }

    #[test]
    fn group_refuses_a_different_boot_before_signalling() {
        let pgid = unsafe { libc::getpgrp() };

        assert_eq!(
            group(&[
                pgid.to_string(),
                "/identity/path/that/does/not/exist".into(),
                "wrong-boot".into(),
                "wrong-launch".into()
            ]),
            Err("harness boot identity does not match the current boot".into())
        );
    }

    #[test]
    fn session_exec_refuses_a_pre_existing_identity_file() {
        let path = test_path("existing");
        fs::write(&path, "existing identity").unwrap();

        let result = session_exec(&[
            path.to_string_lossy().into_owned(),
            "launch".into(),
            "--".into(),
            "unused".into(),
        ]);

        assert!(matches!(
            result,
            Err(ref reason) if reason.starts_with("harness identity could not be opened:")
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "existing identity");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn session_exec_refuses_an_identity_symlink() {
        let target = test_path("symlink-target");
        let path = test_path("symlink");
        fs::write(&target, "target identity").unwrap();
        symlink(&target, &path).unwrap();

        let result = session_exec(&[
            path.to_string_lossy().into_owned(),
            "launch".into(),
            "--".into(),
            "unused".into(),
        ]);

        assert!(matches!(
            result,
            Err(ref reason) if reason.starts_with("harness identity could not be opened:")
        ));
        assert_eq!(fs::read_to_string(&target).unwrap(), "target identity");
        fs::remove_file(path).unwrap();
        fs::remove_file(target).unwrap();
    }
}
