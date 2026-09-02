use crate::process_tree::Snapshot;
use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::fs;
use std::fs::OpenOptions;
use std::io;
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

/// A deterministic post-stop revalidation fault for the freeze cleanup controls.
///
/// The freeze must never strand a stopped tree, but a live reproduction needs the recorded
/// target's identity to drift AFTER the initial SIGSTOP and only then — a race no test can pin
/// without a seam. The negative control arms one of two modes; `freeze_harness_tree` promotes
/// an armed fault to firing the instant the recorded group is stopped. `Once` fires at the
/// next revalidation and disarms, so the kill phase still authorizes its SIGKILL (a transient
/// failure that recovers). `Persistent` fires on EVERY revalidation until the test disarms it,
/// so group authority never recovers and terminal cleanup must rest on the members captured at
/// the validated stop, each disposed by its own birth token — never the bare pgid.
#[cfg(test)]
#[derive(Clone, Copy, PartialEq)]
enum PostStopFault {
    Disarmed,
    ArmedOnce,
    FiringOnce,
    ArmedPersistent,
    FiringPersistent,
}

#[cfg(test)]
thread_local! {
    static POST_STOP_FAULT: std::cell::Cell<PostStopFault> =
        const { std::cell::Cell::new(PostStopFault::Disarmed) };
}

impl HarnessTarget {
    /// Re-read boot identity, the identity file, and the live session leader before a signal.
    ///
    /// A pgid can be reused once the leader is gone; signalling the number alone is not enough
    /// to know the process group still belongs to this launch.
    fn revalidate_before_signal(&self) -> Result<(), String> {
        #[cfg(test)]
        if POST_STOP_FAULT.with(|fault| match fault.get() {
            PostStopFault::FiringOnce => {
                fault.set(PostStopFault::Disarmed);
                true
            }
            PostStopFault::FiringPersistent => true,
            _ => false,
        }) {
            return Err("injected post-stop revalidation fault".into());
        }

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

/// Kernel start time — the stable instance token that survives only for THIS process.
///
/// Numeric pids and pgids are reused once a leader is reaped; start time is what
/// probe.rs and child_process.rs already use to tell the same slot from a new occupant.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ProcessStartTime {
    seconds: libc::time_t,
    microseconds: i32,
}

/// One process the freeze proved was ours, bound to the start time read at capture.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ProcessInstance {
    pid: libc::pid_t,
    pgid: libc::pid_t,
    start_time: ProcessStartTime,
}

impl Ord for ProcessInstance {
    fn cmp(&self, other: &Self) -> Ordering {
        self.pid.cmp(&other.pid)
    }
}

impl PartialOrd for ProcessInstance {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(target_os = "macos")]
fn read_process_start_time(pid: libc::pid_t) -> io::Result<ProcessStartTime> {
    let pid = libc::c_int::try_from(pid)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "pid exceeds c_int"))?;
    let mut mib = [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid];
    let mut size = 0;
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } == -1
    {
        return Err(io::Error::last_os_error());
    }
    if size < std::mem::size_of::<libc::timeval>() {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "KERN_PROC_PID returned no kinfo_proc",
        ));
    }

    let mut buffer = vec![0u8; size];
    let mut written = buffer.len();
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buffer.as_mut_ptr().cast(),
            &mut written,
            std::ptr::null_mut(),
            0,
        )
    } == -1
    {
        return Err(io::Error::last_os_error());
    }
    if written < std::mem::size_of::<libc::timeval>() {
        if unsafe { libc::kill(pid, 0) } == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return Err(error);
            }
        }
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "KERN_PROC_PID returned truncated kinfo_proc",
        ));
    }

    let start = unsafe { buffer.as_ptr().cast::<libc::timeval>().read_unaligned() };
    Ok(ProcessStartTime {
        seconds: start.tv_sec,
        microseconds: start.tv_usec,
    })
}

#[cfg(target_os = "linux")]
fn read_process_start_time(pid: libc::pid_t) -> io::Result<ProcessStartTime> {
    let stat = std::fs::read(format!("/proc/{pid}/stat"))
        .map_err(|error| io::Error::new(error.kind(), error))?;
    let start_ticks = parse_proc_starttime(&stat).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "process stat did not carry a start time",
        )
    })?;
    Ok(ProcessStartTime {
        seconds: start_ticks as libc::time_t,
        microseconds: 0,
    })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read_process_start_time(_pid: libc::pid_t) -> io::Result<ProcessStartTime> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "process start time is only available on linux and macOS",
    ))
}

/// Field 22 of `/proc/<pid>/stat` after the closing paren — starttime in clock ticks.
#[cfg(any(target_os = "linux", test))]
fn parse_proc_starttime(stat: &[u8]) -> Option<u64> {
    let close = stat.iter().rposition(|byte| *byte == b')')?;
    let rest = stat.get(close + 2..)?;
    let fields = rest
        .split(|byte| byte.is_ascii_whitespace())
        .filter(|field| !field.is_empty())
        .collect::<Vec<_>>();
    std::str::from_utf8(fields.get(19)?).ok()?.parse().ok()
}

/// The captured instance must still be the same process before a pid signal is sent.
fn verify_process_instance(instance: &ProcessInstance) -> Result<(), String> {
    match read_process_start_time(instance.pid) {
        Ok(current) if current == instance.start_time => {
            let actual_pgid = unsafe { libc::getpgid(instance.pid) };
            if actual_pgid == -1 {
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(libc::ESRCH) {
                    return Ok(());
                }
                return Err(format!(
                    "process {} process group could not be read: {error}",
                    instance.pid
                ));
            }
            if actual_pgid != instance.pgid {
                return Err(format!(
                    "process {} moved from group {} to {actual_pgid} (group reuse)",
                    instance.pid, instance.pgid
                ));
            }
            Ok(())
        }
        Ok(_) => Err(format!(
            "process {} no longer matches its captured instance (pid reuse)",
            instance.pid
        )),
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(()),
        Err(error) => Err(format!(
            "process {} start time could not be read: {error}",
            instance.pid
        )),
    }
}

enum EscapeeGroupAuthority {
    Live,
    Gone,
}

/// An inferred escapee group may be signalled only while a captured member still matches.
fn authorize_escapee_group(
    pgid: libc::pid_t,
    frozen: &BTreeSet<ProcessInstance>,
) -> Result<EscapeeGroupAuthority, String> {
    let members: Vec<_> = frozen
        .iter()
        .filter(|instance| instance.pgid == pgid)
        .collect();
    if members.is_empty() {
        return Ok(EscapeeGroupAuthority::Gone);
    }

    let mut any_live = false;
    for instance in members {
        match read_process_start_time(instance.pid) {
            Ok(current) if current == instance.start_time => {
                let actual_pgid = unsafe { libc::getpgid(instance.pid) };
                if actual_pgid == -1 {
                    let error = io::Error::last_os_error();
                    if error.raw_os_error() == Some(libc::ESRCH) {
                        continue;
                    }
                    return Err(format!(
                        "process {} process group could not be read: {error}",
                        instance.pid
                    ));
                }
                if actual_pgid != pgid {
                    return Err(format!(
                        "process group {pgid} no longer matches captured member {} \
                         (now in group {actual_pgid})",
                        instance.pid
                    ));
                }
                any_live = true;
            }
            Ok(_) => {
                return Err(format!(
                    "process {} no longer matches its captured instance (pid reuse)",
                    instance.pid
                ));
            }
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {}
            Err(error) => {
                return Err(format!(
                    "process {} start time could not be read: {error}",
                    instance.pid
                ));
            }
        }
    }

    if any_live {
        Ok(EscapeeGroupAuthority::Live)
    } else {
        Ok(EscapeeGroupAuthority::Gone)
    }
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
        failures: Vec::new(),
    };
    sweep.groups.remove(&my_group);

    target.revalidate_before_signal()?;

    if pgid == my_group {
        // Never killpg the recorded group: we are in it. The first snapshot round below
        // SIGSTOPs the other members individually.
    } else {
        signal_process_group(pgid, libc::SIGSTOP, target)?;

        // Capture the recorded group's members NOW, under the identity that just authorized the
        // stop and before any post-stop revalidation can fail. Their birth tokens are the ONLY
        // authority by which the kill phase may later dispose of them: once group identity is in
        // doubt, the bare pgid must never be signalled (it may have been reused), but a captured
        // member whose birth token still matches is provably the process we stopped. Reading is
        // safe without a fresh revalidation — the group was just verified and is now held still.
        if let Ok(snapshot) = Snapshot::capture() {
            for pid in snapshot.group_tree(pgid) {
                if pid == me || snapshot.pgid_of(pid) != Some(pgid) {
                    continue;
                }
                if let Ok(start_time) = read_process_start_time(pid) {
                    sweep.frozen.insert(ProcessInstance {
                        pid,
                        pgid,
                        start_time,
                    });
                }
            }
        }
    }

    // The tree is now stopped. Promote an armed post-stop fault so the negative control's
    // next revalidation drifts exactly here, proving the loop below records and continues.
    #[cfg(test)]
    POST_STOP_FAULT.with(|fault| match fault.get() {
        PostStopFault::ArmedOnce => fault.set(PostStopFault::FiringOnce),
        PostStopFault::ArmedPersistent => fault.set(PostStopFault::FiringPersistent),
        _ => {}
    });

    let mut rounds = 0;
    let mut found_more = true;
    while rounds < FREEZE_ROUNDS {
        // Post-stop: revalidation now guards fresh signals against identity that drifted
        // since the freeze began. A failure here means the target is no longer provably
        // ours, so we stop enumerating NEW members — but the members already frozen were
        // each verified before capture and still get killed below, so record and break to
        // the kill phase rather than unwinding out with the tree left stopped.
        if let Err(reason) = target.revalidate_before_signal() {
            sweep.incomplete = true;
            sweep.failures.push(reason);
            break;
        }

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
            if pid == me || sweep.frozen.iter().any(|instance| instance.pid == pid) {
                continue;
            }
            let Some(member_pgid) = snapshot.pgid_of(pid) else {
                continue;
            };
            let start_time = match read_process_start_time(pid) {
                Ok(start_time) => start_time,
                Err(error) if error.raw_os_error() == Some(libc::ESRCH) => continue,
                Err(error) => {
                    // Post-stop: the recorded group is frozen. An unreadable start time for
                    // one member means we cannot bind an instance token to it, so we do not
                    // freeze it — but we must not abandon the members already stopped. Record
                    // the gap (the walk is now incomplete) and keep going to the kill phase.
                    sweep.incomplete = true;
                    sweep.failures.push(format!(
                        "process {pid} start time could not be read before freeze: {error}"
                    ));
                    continue;
                }
            };
            let instance = ProcessInstance {
                pid,
                pgid: member_pgid,
                start_time,
            };
            found_more = true;
            sweep.frozen.insert(instance);
            // Post-stop: this instance is already recorded in `frozen`, so a failed SIGSTOP
            // is recorded rather than propagated — the kill phase still SIGKILLs it under its
            // captured birth token. Unwinding here would strand the whole frozen tree.
            if let Err(reason) = signal_process(instance, libc::SIGSTOP, target) {
                sweep.incomplete = true;
                sweep.failures.push(reason);
            }
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
    frozen: BTreeSet<ProcessInstance>,
    groups: BTreeSet<libc::pid_t>,
    /// True when the walk could not prove it saw the whole tree before the kill.
    incomplete: bool,
    /// Every post-stop failure the freeze met, recorded rather than returned. Once the tree
    /// is frozen, a failure that unwinds out of the freeze leaves it stopped forever (worse
    /// than the orphan the sweep replaces), so each is carried here and surfaced loudly by
    /// `kill_harness_tree` AFTER every kill has run.
    failures: Vec<String>,
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
    instance: ProcessInstance,
    signal: libc::c_int,
    target: &HarnessTarget,
) -> Result<(), String> {
    target.revalidate_before_signal()?;
    verify_process_instance(&instance)?;
    if unsafe { libc::kill(instance.pid, signal) } == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if process_signal_target_gone(&error) {
        return Ok(());
    }
    Err(format!(
        "process {} could not be signalled: {error}",
        instance.pid
    ))
}

/// A group with no live members to signal — linux says ESRCH, darwin often EPERM.
fn group_signal_target_gone(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH)
        || (cfg!(target_os = "macos") && error.raw_os_error() == Some(libc::EPERM))
}

/// An individual pid that is already gone. Darwin EPERM is NOT absence here — unlike
/// killpg, kill(pid) has no leader-exited proof path on this floor.
fn process_signal_target_gone(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH)
}

/// SIGKILL everything the freeze proved was ours, then the recorded group last.
///
/// SIGKILL reaches a stopped process — neither signal can be caught or blocked, and the
/// kernel wakes a stopped task to die — so a successful kill needs no SIGCONT to undo.
///
/// Every stopped process is disposed of through its own birth-verified `ProcessInstance`
/// token, never a bare pgid whose identity is in doubt. The freeze captured each recorded-group
/// member under the identity that authorized the stop, so the per-member pass below SIGKILLs
/// them under authority that stays valid even when the recorded group identity later fails to
/// revalidate. A bare-pgid killpg is issued ONLY when that final revalidation still succeeds;
/// when it does not, the group is left unsignalled (it may have been reused) and the failure is
/// recorded loudly — terminal cleanup has already happened member by member.
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
    // Post-stop failures the freeze recorded rather than unwinding on: surface each so the
    // loud incomplete verdict names why, after every kill below has still run.
    cleanup_failures.extend(sweep.failures.iter().cloned());

    for group in sweep.groups.iter().filter(|group| **group != pgid) {
        if let Some(reason) = sigkill_stray(Stray::Group(*group), target, &sweep.frozen) {
            cleanup_failures.push(reason);
        }
    }

    for instance in &sweep.frozen {
        if let Some(reason) = sigkill_stray(Stray::Process(*instance), target, &sweep.frozen) {
            cleanup_failures.push(reason);
        }
    }

    // The recorded group is signalled by bare number, so its identity is revalidated one last
    // time before the killpg — a reused pgid must never be SIGKILLed. If revalidation does not
    // recover, the bare pgid must NOT be signalled at all (no kill, no resume): it may now name
    // a different group. Terminal cleanup does not depend on it — every member stopped under a
    // valid identity was captured at the freeze and has already been SIGKILLed above under its
    // own birth token — so we only record the group as unconfirmed.
    let recorded = match target.revalidate_before_signal() {
        Ok(()) => {
            if unsafe { libc::killpg(pgid, libc::SIGKILL) } == 0 {
                Ok(0)
            } else {
                classify_group_kill(pgid, std::io::Error::last_os_error())
            }
        }
        Err(reason) => {
            cleanup_failures.push(format!(
                "recorded group {pgid} identity could not be revalidated before the final kill; \
                 members disposed by birth token, bare group left unsignalled: {reason}"
            ));
            Ok(0)
        }
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
    Process(ProcessInstance),
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
fn sigkill_stray(
    stray: Stray,
    target: &HarnessTarget,
    frozen: &BTreeSet<ProcessInstance>,
) -> Option<String> {
    match stray {
        // A group is signalled by bare number, so the recorded target identity is reconfirmed
        // before the killpg — a reused pgid must not be SIGKILLed.
        Stray::Group(pgid) => {
            if let Err(error) = target.revalidate_before_signal() {
                return Some(error);
            }
            match authorize_escapee_group(pgid, frozen) {
                Ok(EscapeeGroupAuthority::Gone) => None,
                Ok(EscapeeGroupAuthority::Live) => report_sigkill_result(
                    unsafe { libc::killpg(pgid, libc::SIGKILL) },
                    format!("process group {pgid}"),
                    group_signal_target_gone,
                ),
                Err(reason) => Some(reason),
            }
        }
        // A frozen instance is authorized by its own captured birth token (pid + start time +
        // group), which is sufficient and stronger than the group-identity path and stays
        // valid even when the recorded group identity no longer resolves. So a stopped member
        // is SIGKILLed here rather than stranded when group authority is lost. A token that no
        // longer matches means our process already exited (pid reuse/gone) — nothing of ours
        // is left stopped, so there is nothing to resume.
        Stray::Process(instance) => match verify_process_instance(&instance) {
            Ok(()) => report_sigkill_result(
                unsafe { libc::kill(instance.pid, libc::SIGKILL) },
                format!("process {}", instance.pid),
                process_signal_target_gone,
            ),
            Err(reason) => Some(reason),
        },
    }
}

fn report_sigkill_result(
    result: libc::c_int,
    target_label: String,
    gone: fn(&std::io::Error) -> bool,
) -> Option<String> {
    if result == 0 {
        return None;
    }

    let error = std::io::Error::last_os_error();

    if gone(&error) {
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

#[cfg(test)]
mod signal_target_gone_tests {
    use super::{group_signal_target_gone, process_signal_target_gone};
    use std::io::Error;

    #[test]
    fn esrch_means_gone_for_individual_process_signals() {
        assert!(process_signal_target_gone(&Error::from_raw_os_error(
            libc::ESRCH
        )));
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn eperm_is_not_gone_for_individual_process_signals_on_darwin() {
        assert!(!process_signal_target_gone(&Error::from_raw_os_error(
            libc::EPERM
        )));
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn eperm_is_gone_for_group_signals_on_darwin() {
        assert!(group_signal_target_gone(&Error::from_raw_os_error(
            libc::EPERM
        )));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn eperm_is_not_gone_for_group_signals_on_linux() {
        assert!(!group_signal_target_gone(&Error::from_raw_os_error(
            libc::EPERM
        )));
    }
}

#[cfg(test)]
mod instance_authority_tests {
    use super::{
        ProcessInstance, ProcessStartTime, parse_proc_starttime, read_process_start_time,
        verify_process_instance,
    };

    #[test]
    fn linux_starttime_is_read_from_proc_stat() {
        let stat = b"4242 (sleep) S 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0 31415926";
        assert_eq!(parse_proc_starttime(stat), Some(31415926));
    }

    #[test]
    fn pgid_reuse_is_refused_when_a_captured_member_moved_groups() {
        let pid = unsafe { libc::getpid() };
        let actual_pgid = unsafe { libc::getpgid(pid) };
        assert_ne!(
            actual_pgid, -1,
            "live pid must have a readable process group"
        );
        let wrong_pgid = if actual_pgid != 1 { 1 } else { 2 };
        let start_time = read_process_start_time(pid).expect("live pid start time readable");
        let instance = ProcessInstance {
            pid,
            pgid: wrong_pgid,
            start_time,
        };
        let error = verify_process_instance(&instance).unwrap_err();
        assert!(
            error.contains("group reuse"),
            "expected group-reuse refusal, got: {error}"
        );
        assert!(
            !error.contains("pid reuse"),
            "must not pass via pid-reuse branch: {error}"
        );
    }

    /// PID reuse must be refused by the captured start-time birth token alone. The instance
    /// carries the LIVE pid and its true process group, so the group-reuse branch cannot fire;
    /// only the captured start time differs, exactly as when a reaped pid number is handed to a
    /// new process. Removing the start-time authority in `verify_process_instance` lets this
    /// reused pid pass verification, turning this control red. Boot identity is not consulted
    /// here, so a boot-id mismatch alone could never stand in for this proof.
    #[test]
    fn pid_reuse_is_refused_when_only_the_start_time_differs() {
        let pid = unsafe { libc::getpid() };
        let actual_pgid = unsafe { libc::getpgid(pid) };
        assert_ne!(
            actual_pgid, -1,
            "live pid must have a readable process group"
        );
        let live = read_process_start_time(pid).expect("live pid start time readable");
        // A birth token from a DIFFERENT process at the same pid number: same pid, same group,
        // stale start time. Only the start-time check can tell it apart from the live process.
        let stale = ProcessStartTime {
            seconds: live.seconds ^ 0x5a5a,
            microseconds: live.microseconds,
        };
        assert_ne!(
            stale, live,
            "the stale start time must differ from the live one"
        );
        let instance = ProcessInstance {
            pid,
            pgid: actual_pgid,
            start_time: stale,
        };
        let error = verify_process_instance(&instance).unwrap_err();
        assert!(
            error.contains("pid reuse"),
            "expected pid-reuse refusal from the start-time check, got: {error}"
        );
        assert!(
            !error.contains("group reuse"),
            "must be refused by the start-time token, not the group branch: {error}"
        );
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
    fn an_incomplete_sweep_is_a_loud_failure_even_when_the_recorded_kill_succeeds() {
        // Blocker 3 negative control: a recorded-group SIGKILL that succeeds must NOT read
        // as success while the freeze never proved it saw the whole tree. We drive the real
        // kill_harness_tree with an owned session-leader child (killing it is safe) and an
        // injected `incomplete: true` sweep, then assert the loud "harness cleanup
        // incomplete" refusal. Reverting the fail-loud fence turns this red.
        let mut fds = [0 as libc::c_int; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0, "pipe failed");
        let (read_fd, write_fd) = (fds[0], fds[1]);

        let child = unsafe { libc::fork() };
        assert!(child >= 0, "fork failed");
        if child == 0 {
            // Own session + group, announce readiness, then hold still to be killed. The
            // bounded sleep is a safety net so a bug here cannot wedge the suite.
            unsafe {
                libc::setsid();
                libc::write(write_fd, b"x".as_ptr() as *const libc::c_void, 1);
                libc::sleep(30);
                libc::_exit(0);
            }
        }

        // Parent: wait for the child to finish setsid before trusting its pgid.
        unsafe { libc::close(write_fd) };
        let mut ready = [0u8; 1];
        assert_eq!(
            unsafe { libc::read(read_fd, ready.as_mut_ptr() as *mut libc::c_void, 1) },
            1,
            "child never signalled readiness"
        );
        unsafe { libc::close(read_fd) };

        // After setsid the child leads its own group: pgid == pid == child.
        let pgid = child;
        let boot = boot_identity().unwrap();
        let launch = "incomplete-sweep-launch";
        let path = test_path("incomplete-sweep");
        fs::write(&path, format!("{pgid}\t{pgid}\t{boot}\t{launch}")).unwrap();

        let target = HarnessTarget {
            pgid,
            identity_path: path.to_string_lossy().into_owned(),
            boot_identity: boot,
            launch_id: launch.into(),
        };
        let sweep = Sweep {
            frozen: BTreeSet::new(),
            groups: BTreeSet::new(),
            incomplete: true,
            failures: Vec::new(),
        };

        let verdict = kill_harness_tree(&target, sweep);

        // The child's group was SIGKILLed by the call above; reap it.
        let mut status = 0;
        unsafe { libc::waitpid(child, &mut status, 0) };
        fs::remove_file(&path).ok();

        assert!(
            matches!(verdict, Err(ref reason) if reason.contains("harness cleanup incomplete")),
            "incomplete cleanup must be a loud failure, got {verdict:?}"
        );
    }

    /// Fork an owned session-leader child that announces readiness then holds still. It leads
    /// its own group (pgid == pid == child) and is safe to SIGSTOP/SIGKILL. The bounded sleep
    /// is a safety net so a bug in a caller cannot wedge the suite.
    fn fork_owned_session_child() -> libc::pid_t {
        let mut fds = [0 as libc::c_int; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0, "pipe failed");
        let (read_fd, write_fd) = (fds[0], fds[1]);

        let child = unsafe { libc::fork() };
        assert!(child >= 0, "fork failed");
        if child == 0 {
            unsafe {
                libc::setsid();
                libc::write(write_fd, b"x".as_ptr() as *const libc::c_void, 1);
                libc::sleep(30);
                libc::_exit(0);
            }
        }

        unsafe { libc::close(write_fd) };
        let mut ready = [0u8; 1];
        assert_eq!(
            unsafe { libc::read(read_fd, ready.as_mut_ptr() as *mut libc::c_void, 1) },
            1,
            "child never signalled readiness"
        );
        unsafe { libc::close(read_fd) };
        child
    }

    /// Unconditional teardown for a test that owns a stopped child. Whatever the assertions do
    /// — pass, panic, or early return — the child is SIGKILLed and reaped and its identity file
    /// removed on drop. The card requires terminal cleanup even when the negative control fails
    /// its assertions; a `disarm()` call after the test has already reaped the child keeps drop
    /// from touching a since-reused pid.
    struct StoppedChildGuard {
        pid: libc::pid_t,
        path: std::path::PathBuf,
        armed: bool,
    }
    impl StoppedChildGuard {
        fn disarm(&mut self) {
            self.armed = false;
        }
    }
    impl Drop for StoppedChildGuard {
        fn drop(&mut self) {
            if self.armed {
                unsafe { libc::kill(self.pid, libc::SIGKILL) };
                let mut status = 0;
                unsafe { libc::waitpid(self.pid, &mut status, 0) };
            }
            let _ = fs::remove_file(&self.path);
        }
    }

    #[test]
    fn a_post_stop_freeze_failure_records_and_still_kills_the_frozen_tree() {
        // F1 control (transient failure): once freeze has SIGSTOPped the recorded group, NO
        // error path may unwind out of the freeze. A ONE-SHOT post-stop fault fires at the first
        // post-stop revalidation and then clears, so authority recovers by the kill phase:
        // freeze returns Ok with the failure recorded and the kill phase SIGKILLs the child.
        // Reverting any post-stop `?` turns freeze into an early Err, the kill never runs, and
        // the child is left stopped — red.
        let child = fork_owned_session_child();
        let pgid = child;
        let boot = boot_identity().unwrap();
        let launch = "post-stop-freeze-once-launch";
        let path = test_path("post-stop-freeze-once");
        fs::write(&path, format!("{pgid}\t{pgid}\t{boot}\t{launch}")).unwrap();
        let mut guard = StoppedChildGuard {
            pid: child,
            path: path.clone(),
            armed: true,
        };

        let target = HarnessTarget {
            pgid,
            identity_path: path.to_string_lossy().into_owned(),
            boot_identity: boot,
            launch_id: launch.into(),
        };

        POST_STOP_FAULT.with(|fault| fault.set(PostStopFault::ArmedOnce));
        let freeze = freeze_harness_tree(&target);
        // Never let the injected fault leak into another test that reuses this thread.
        POST_STOP_FAULT.with(|fault| fault.set(PostStopFault::Disarmed));

        // The fix keeps the freeze from unwinding after the stop: it returns the recorded sweep.
        // On the reverted build this Err panics with the guard still armed, so drop cleans up.
        let sweep = freeze.expect("freeze must record the transient post-stop fault and return Ok");
        assert!(
            sweep.incomplete,
            "a recorded post-stop fault must mark the sweep incomplete"
        );
        assert!(
            sweep
                .failures
                .iter()
                .any(|reason| reason.contains("injected post-stop revalidation fault")),
            "the sweep must carry the post-stop failure, got {:?}",
            sweep.failures
        );

        // The kill phase still runs and reaches the frozen tree.
        let verdict = kill_harness_tree(&target, sweep);

        // Bounded reap; the guard is the unconditional safety net if anything above panicked.
        let mut status = 0;
        let mut reaped = false;
        for _ in 0..200 {
            if unsafe { libc::waitpid(child, &mut status, libc::WNOHANG) } == child {
                reaped = true;
                break;
            }
            unsafe { libc::usleep(25_000) };
        }
        if reaped {
            guard.disarm();
        }

        assert!(
            reaped && libc::WIFSIGNALED(status) && libc::WTERMSIG(status) == libc::SIGKILL,
            "the frozen child must be SIGKILLed by the kill phase, not left stopped"
        );
        assert!(
            matches!(verdict, Err(ref reason) if reason.contains("harness cleanup incomplete")),
            "a recorded freeze failure must surface as a loud incomplete cleanup, got {verdict:?}"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn a_persistent_post_stop_failure_kills_the_captured_group_by_birth_token_not_the_bare_pgid() {
        // F1 round-two control (persistent failure): when post-stop identity authority NEVER
        // recovers, the recorded group must not be left in state T — and must NOT be signalled by
        // its bare pgid (which may have been reused). A PERSISTENT fault fires on every post-stop
        // revalidation, so no fresh authority is available after the initial stop. Terminal
        // cleanup therefore rests entirely on the members captured at the validated initial stop:
        // each is SIGKILLed under its own birth token, and the bare pgid is left unsignalled. The
        // child is reaped as SIGKILLed and the verdict is a loud incomplete cleanup. Reverting the
        // freeze's member capture (or the birth-token authorization) strands the child in 'T' —
        // red.
        let child = fork_owned_session_child();
        let pgid = child;
        let boot = boot_identity().unwrap();
        let launch = "post-stop-persistent-launch";
        let path = test_path("post-stop-persistent");
        fs::write(&path, format!("{pgid}\t{pgid}\t{boot}\t{launch}")).unwrap();
        let mut guard = StoppedChildGuard {
            pid: child,
            path: path.clone(),
            armed: true,
        };

        let target = HarnessTarget {
            pgid,
            identity_path: path.to_string_lossy().into_owned(),
            boot_identity: boot,
            launch_id: launch.into(),
        };

        POST_STOP_FAULT.with(|fault| fault.set(PostStopFault::ArmedPersistent));
        let freeze = freeze_harness_tree(&target);
        let sweep = match freeze {
            Ok(sweep) => sweep,
            Err(reason) => {
                POST_STOP_FAULT.with(|fault| fault.set(PostStopFault::Disarmed));
                panic!(
                    "freeze must record the persistent post-stop fault and return Ok, got Err: {reason}"
                );
            }
        };
        // The member was captured at the validated initial stop, so it is authority-bound even
        // though every later revalidation fails.
        assert!(
            sweep.frozen.iter().any(|instance| instance.pid == child),
            "the stopped member must be captured under the validated stop, got {:?}",
            sweep.frozen
        );
        assert!(sweep.incomplete);

        let verdict = kill_harness_tree(&target, sweep);
        // The persistent fault is still firing; clear it now that the SUT has run.
        POST_STOP_FAULT.with(|fault| fault.set(PostStopFault::Disarmed));

        // The captured member must be SIGKILLed under its birth token — terminal cleanup with no
        // bare-pgid signal — not left stranded stopped.
        let mut status = 0;
        let mut reaped = false;
        for _ in 0..200 {
            if unsafe { libc::waitpid(child, &mut status, libc::WNOHANG) } == child {
                reaped = true;
                break;
            }
            unsafe { libc::usleep(25_000) };
        }
        if reaped {
            guard.disarm();
        }

        assert!(
            reaped && libc::WIFSIGNALED(status) && libc::WTERMSIG(status) == libc::SIGKILL,
            "the captured member must be SIGKILLed by its birth token, not left stopped"
        );
        assert!(
            matches!(verdict, Err(ref reason)
                if reason.contains("harness cleanup incomplete")
                    && reason.contains("bare group left unsignalled")),
            "verdict must be a loud incomplete cleanup that left the bare pgid unsignalled, got {verdict:?}"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn a_frozen_member_is_killed_by_its_birth_token_when_group_identity_is_lost() {
        // F1 round-two control (members): a frozen member must be SIGKILLed under its own birth
        // token even when the recorded group identity no longer resolves, so an escapee member
        // is never stranded stopped. We SIGSTOP an owned child in its OWN group (an escapee
        // relative to the recorded target) and drive kill_harness_tree with a target whose
        // identity file does NOT match — group revalidation fails. The member is killed by its
        // token; the recorded group's SIGCONT resume signals a different group and cannot reach
        // the escapee. Reverting the birth-token authorization leaves the member in 'T' — red.
        let child = fork_owned_session_child();
        assert_eq!(
            unsafe { libc::kill(child, libc::SIGSTOP) },
            0,
            "SIGSTOP the owned child failed"
        );
        // Wait until it has actually reached the stopped state.
        let mut wstatus = 0;
        unsafe { libc::waitpid(child, &mut wstatus, libc::WUNTRACED) };

        let start_time = read_process_start_time(child).expect("child start time readable");
        let member = ProcessInstance {
            pid: child,
            pgid: child,
            start_time,
        };

        // Recorded target: a DIFFERENT, harmless existing group (our own), with a deliberately
        // wrong identity file so group revalidation fails. The escapee child leads group
        // `child`, not this one, so the recorded-group SIGCONT resume cannot reach it.
        let recorded_pgid = unsafe { libc::getpgrp() };
        let path = test_path("member-birth-token");
        fs::write(&path, "wrong\twrong\twrong-boot\twrong-launch").unwrap();
        let mut guard = StoppedChildGuard {
            pid: child,
            path: path.clone(),
            armed: true,
        };

        let target = HarnessTarget {
            pgid: recorded_pgid,
            identity_path: path.to_string_lossy().into_owned(),
            boot_identity: "wrong-boot".into(),
            launch_id: "wrong-launch".into(),
        };
        assert!(
            target.revalidate_before_signal().is_err(),
            "the recorded group identity must be unauthorized for this control"
        );

        let mut frozen = BTreeSet::new();
        frozen.insert(member);
        let sweep = Sweep {
            frozen,
            groups: BTreeSet::new(),
            incomplete: false,
            failures: Vec::new(),
        };

        let verdict = kill_harness_tree(&target, sweep);

        // The member must be SIGKILLed by its birth token despite the failed group identity.
        let mut status = 0;
        let mut reaped = false;
        for _ in 0..200 {
            if unsafe { libc::waitpid(child, &mut status, libc::WNOHANG) } == child {
                reaped = true;
                break;
            }
            unsafe { libc::usleep(25_000) };
        }
        if reaped {
            guard.disarm();
        }

        assert!(
            reaped && libc::WIFSIGNALED(status) && libc::WTERMSIG(status) == libc::SIGKILL,
            "the frozen member must be SIGKILLed under its birth token, not left stopped"
        );
        // Group identity failed, so the verdict is still a loud incomplete cleanup for the group.
        assert!(
            matches!(verdict, Err(ref reason) if reason.contains("harness cleanup incomplete")),
            "group-identity failure must still surface loudly, got {verdict:?}"
        );
    }

    #[test]
    fn stopped_child_guard_tears_down_even_when_a_control_panics() {
        // F2: the F1 controls stop an owned child before their assertions run, so an assertion
        // panic must still reach terminal cleanup. StoppedChildGuard provides that via Drop. We
        // stop an owned child, then panic inside a scope holding the guard, and prove the guard
        // ran during unwinding: the child was SIGKILLed and reaped, so waiting for it now
        // returns ECHILD instead of a still-live stopped process. Removing the guard's kill/reap
        // leaves the child alive and this control goes red.
        let child = fork_owned_session_child();
        assert_eq!(
            unsafe { libc::kill(child, libc::SIGSTOP) },
            0,
            "SIGSTOP failed"
        );
        let mut wstatus = 0;
        unsafe { libc::waitpid(child, &mut wstatus, libc::WUNTRACED) };

        let path = test_path("guard-panic");
        fs::write(&path, "x").unwrap();

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = StoppedChildGuard {
                pid: child,
                path: path.clone(),
                armed: true,
            };
            panic!("simulated assertion failure before cleanup");
        }));
        assert!(result.is_err(), "the guarded scope must have panicked");

        // The guard reaped the child during unwinding; there is nothing left to wait for.
        let waited = unsafe { libc::waitpid(child, &mut wstatus, libc::WNOHANG) };
        assert_eq!(
            waited, -1,
            "guard must have SIGKILLed and reaped the child during unwinding, got {waited}"
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD),
            "child must already be reaped by the guard"
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
