use crate::process_tree::{Process, ProcessStartTime, Snapshot, read_process};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

mod signal;
use signal::BoundProcess;

#[cfg(test)]
mod identity_tests;
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
use std::path::{Path, PathBuf};
use std::process::Command;

const IDENTITY_AUTHORITY_VERSION: &str = "tightbeam-harness-identity-v2";
const IDENTITY_AUTHORITY_SUFFIX: &str = ".authority";

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
    let leader_start_time = read_process_start_time(pid)
        .map_err(|error| format!("harness session leader start time could not be read: {error}"))?;

    write_identity_authority(
        identity_path,
        pid,
        pgid,
        leader_start_time,
        &boot_identity,
        launch_id,
    )?;
    writeln!(identity, "{pid}\t{pgid}\t{boot_identity}\t{launch_id}")
        .and_then(|_| identity.sync_all())
        .map_err(|error| format!("harness identity could not be written: {error}"))?;

    let error = Command::new(&args[separator + 1])
        .args(&args[separator + 2..])
        .exec();

    Err(format!("harness command could not be executed: {error}"))
}

fn identity_authority_path(identity_path: &Path) -> PathBuf {
    let mut path = identity_path.as_os_str().to_owned();
    path.push(IDENTITY_AUTHORITY_SUFFIX);
    PathBuf::from(path)
}

fn write_identity_authority(
    identity_path: &Path,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    start_time: ProcessStartTime,
    boot_identity: &str,
    launch_id: &str,
) -> Result<(), String> {
    let path = identity_authority_path(identity_path);
    let mut authority = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .map_err(|error| format!("harness identity authority could not be opened: {error}"))?;
    writeln!(
        authority,
        "{IDENTITY_AUTHORITY_VERSION}\t{pid}\t{pgid}\t{}\t{}\t{boot_identity}\t{launch_id}",
        start_time.seconds, start_time.microseconds
    )
    .and_then(|_| authority.sync_all())
    .map_err(|error| format!("harness identity authority could not be written: {error}"))
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

    let target = HarnessTarget::load(pgid, &args[1], &args[2], &args[3])?;
    if target.revalidate_authority()? == HarnessAuthority::Gone {
        return Ok(0);
    }

    match freeze_harness_tree(&target)? {
        Some(sweep) => kill_harness_tree(&target, sweep),
        None => Ok(0),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HarnessAuthority {
    Live,
    Gone,
}

/// The authorized harness instance every signal in a sweep must still be killing.
struct HarnessTarget {
    pgid: libc::pid_t,
    identity_path: String,
    boot_identity: String,
    launch_id: String,
    leader_start_time: ProcessStartTime,
}

impl HarnessTarget {
    fn load(
        pgid: libc::pid_t,
        identity_path: &str,
        boot_identity: &str,
        launch_id: &str,
    ) -> Result<Self, String> {
        let leader_start_time =
            authorize_group_signal(Path::new(identity_path), pgid, boot_identity, launch_id)?;
        let target = Self {
            pgid,
            identity_path: identity_path.to_owned(),
            boot_identity: boot_identity.to_owned(),
            launch_id: launch_id.to_owned(),
            leader_start_time,
        };
        Ok(target)
    }

    /// Re-read boot identity, the identity file, and the live session leader before a signal.
    ///
    /// A pgid can be reused once the leader is gone; signalling the number alone is not enough
    /// to know the process group still belongs to this launch.
    fn revalidate_authority(&self) -> Result<HarnessAuthority, String> {
        let recorded_start_time = authorize_group_signal(
            Path::new(&self.identity_path),
            self.pgid,
            &self.boot_identity,
            &self.launch_id,
        )?;
        if recorded_start_time != self.leader_start_time {
            return Err("harness identity leader instance changed during cleanup".into());
        }
        verify_session_leader_instance(self.pgid, self.leader_start_time)
    }

    fn require_live_before_signal(&self) -> Result<(), String> {
        match self.revalidate_authority()? {
            HarnessAuthority::Live => Ok(()),
            HarnessAuthority::Gone => Err(format!(
                "harness session leader {} disappeared during cleanup",
                self.pgid
            )),
        }
    }
}

/// The recorded session leader must still be the same process and lead `pgid`.
fn verify_session_leader_instance(
    pgid: libc::pid_t,
    expected_start_time: ProcessStartTime,
) -> Result<HarnessAuthority, String> {
    match read_process(pgid) {
        Ok(current) if current.start_time == expected_start_time => {
            if current.zombie {
                return leader_disappeared_authority(pgid);
            }
        }
        Ok(_) => {
            return Err(format!(
                "process group {pgid} no longer matches its session leader (pid/pgid reuse)"
            ));
        }
        Err(error) if process_read_target_gone(&error) => {
            return leader_disappeared_authority(pgid);
        }
        Err(error) => {
            return Err(format!(
                "harness session leader {pgid} start time could not be read: {error}"
            ));
        }
    }

    let actual_pgid = match read_process_group(pgid) {
        Ok(actual_pgid) => actual_pgid,
        Err(error) => {
            if error.raw_os_error() == Some(libc::ESRCH) {
                return leader_disappeared_authority(pgid);
            }
            return Err(format!(
                "harness session leader {pgid} process group could not be read: {error}"
            ));
        }
    };
    if actual_pgid != pgid {
        return Err(format!(
            "process group {pgid} no longer matches its session leader \
             (now in group {actual_pgid})"
        ));
    }

    Ok(HarnessAuthority::Live)
}

fn leader_disappeared_authority(pgid: libc::pid_t) -> Result<HarnessAuthority, String> {
    let snapshot = Snapshot::capture()
        .map_err(|reason| format!("harness session leader {pgid} disappeared; {reason}"))?;
    if snapshot
        .group_tree(pgid)
        .iter()
        .all(|pid| snapshot.process(*pid).is_some_and(|process| process.zombie))
    {
        Ok(HarnessAuthority::Gone)
    } else {
        Err(format!(
            "harness session leader {pgid} disappeared while process group still has members; group left unsignalled"
        ))
    }
}

/// One process the freeze proved was ours, bound to the start time read at capture.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ProcessInstance {
    pid: libc::pid_t,
    pgid: libc::pid_t,
    start_time: ProcessStartTime,
}

fn read_process_start_time(pid: libc::pid_t) -> io::Result<ProcessStartTime> {
    read_process(pid).map(|process| process.start_time)
}

/// Field 22 of `/proc/<pid>/stat` after the closing paren — starttime in clock ticks.
#[cfg(test)]
fn parse_proc_starttime(stat: &[u8]) -> Option<u64> {
    crate::process_tree::parse_proc_stat(4242, std::str::from_utf8(stat).ok()?)
        .map(|process| process.start_time.seconds as u64)
}

/// The captured instance must still be the same process before a pid signal is sent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProcessAuthority {
    Live,
    Gone,
}

fn verify_process_instance(instance: &ProcessInstance) -> Result<ProcessAuthority, String> {
    match read_process_start_time(instance.pid) {
        Ok(current) if current == instance.start_time => {
            let actual_pgid = match read_process_group(instance.pid) {
                Ok(actual_pgid) => actual_pgid,
                Err(error) => {
                    if error.raw_os_error() == Some(libc::ESRCH) {
                        return Ok(ProcessAuthority::Gone);
                    }
                    return Err(format!(
                        "process {} process group could not be read: {error}",
                        instance.pid
                    ));
                }
            };
            if actual_pgid != instance.pgid {
                return Err(format!(
                    "process {} moved from group {} to {actual_pgid} (group reuse)",
                    instance.pid, instance.pgid
                ));
            }
            Ok(ProcessAuthority::Live)
        }
        Ok(_) => Err(format!(
            "process {} no longer matches its captured instance (pid reuse)",
            instance.pid
        )),
        Err(error) if process_read_target_gone(&error) => Ok(ProcessAuthority::Gone),
        Err(error) => Err(format!(
            "process {} start time could not be read: {error}",
            instance.pid
        )),
    }
}

/// Revisit the frozen tree until its membership stops growing. Every signal is delivered
/// through a retained process capability; group numbers are only discovery metadata.
const FREEZE_ROUNDS: usize = 8;

struct Sweep {
    leader: BoundProcess,
    frozen: BTreeMap<libc::pid_t, BoundProcess>,
    failures: Vec<String>,
    caller: libc::pid_t,
}

fn freeze_harness_tree(target: &HarnessTarget) -> Result<Option<Sweep>, String> {
    let Some(leader) = capture_sweep_leader(target)? else {
        return Ok(None);
    };
    let mut sweep = Sweep {
        leader,
        frozen: BTreeMap::new(),
        failures: Vec::new(),
        caller: unsafe { libc::getpid() },
    };
    let deadline = Instant::now() + Duration::from_secs(2);

    match freeze_sweep_leader(target, &mut sweep, deadline)? {
        LeaderFreeze::Gone => return Ok(None),
        LeaderFreeze::Failed => return Ok(Some(sweep)),
        LeaderFreeze::Ready => {}
    }

    for _ in 0..FREEZE_ROUNDS {
        if !freeze_tree_round(target, &mut sweep, deadline)? {
            return Ok(Some(sweep));
        }
        if Instant::now() >= deadline {
            break;
        }
    }
    sweep
        .failures
        .push("harness tree freeze did not prove complete before kill".into());
    Ok(Some(sweep))
}

fn capture_sweep_leader(target: &HarnessTarget) -> Result<Option<BoundProcess>, String> {
    if target.revalidate_authority()? == HarnessAuthority::Gone {
        return Ok(None);
    }
    match BoundProcess::capture(ProcessInstance {
        pid: target.pgid,
        pgid: target.pgid,
        start_time: target.leader_start_time,
    })? {
        Some(leader) => Ok(Some(leader)),
        None if target.revalidate_authority()? == HarnessAuthority::Gone => Ok(None),
        None => Err(format!(
            "harness session leader {} disappeared before freeze",
            target.pgid
        )),
    }
}

enum LeaderFreeze {
    Gone,
    Failed,
    Ready,
}

fn freeze_sweep_leader(
    target: &HarnessTarget,
    sweep: &mut Sweep,
    deadline: Instant,
) -> Result<LeaderFreeze, String> {
    // Caller exclusion is decided before STOP. There is no group broadcast capable of
    // stopping the caller, even when it is the recorded leader or shares its group.
    if sweep.leader.instance.pid == sweep.caller {
        return Ok(LeaderFreeze::Ready);
    }
    if target.revalidate_authority()? == HarnessAuthority::Gone {
        return Ok(LeaderFreeze::Gone);
    }
    match sweep.leader.signal(libc::SIGSTOP)? {
        ProcessSignalResult::Gone => return record_gone_leader_freeze(target, sweep),
        ProcessSignalResult::Failed(error) => sweep.failures.push(format!(
            "process {} could not be stopped: {error}",
            target.pgid
        )),
        ProcessSignalResult::Delivered => {
            if matches!(
                wait_for_leader_freeze(target, sweep, deadline)?,
                LeaderFreeze::Gone
            ) {
                return Ok(LeaderFreeze::Gone);
            }
        }
    }
    if sweep.failures.is_empty() {
        Ok(LeaderFreeze::Ready)
    } else {
        Ok(LeaderFreeze::Failed)
    }
}

fn record_gone_leader_freeze(
    target: &HarnessTarget,
    sweep: &mut Sweep,
) -> Result<LeaderFreeze, String> {
    if target.revalidate_authority()? == HarnessAuthority::Gone {
        Ok(LeaderFreeze::Gone)
    } else {
        sweep
            .failures
            .push("leader disappeared before freeze while its group remains".into());
        Ok(LeaderFreeze::Failed)
    }
}

fn wait_for_leader_freeze(
    target: &HarnessTarget,
    sweep: &mut Sweep,
    deadline: Instant,
) -> Result<LeaderFreeze, String> {
    match wait_for_stopped(&sweep.leader, deadline) {
        Ok(true) => {}
        Ok(false) if target.revalidate_authority()? == HarnessAuthority::Gone => {
            return Ok(LeaderFreeze::Gone);
        }
        Ok(false) => sweep
            .failures
            .push("leader exited before entering the frozen state".into()),
        Err(reason) => sweep.failures.push(reason),
    }
    Ok(LeaderFreeze::Ready)
}

fn freeze_tree_round(
    target: &HarnessTarget,
    sweep: &mut Sweep,
    deadline: Instant,
) -> Result<bool, String> {
    if let Err(reason) = require_sweep_authority(target, &sweep.leader) {
        sweep.failures.push(reason);
        return Ok(false);
    }
    let snapshot = match Snapshot::capture() {
        Ok(snapshot) => snapshot,
        Err(reason) => {
            sweep
                .failures
                .push(format!("harness process table unreadable: {reason}"));
            return Ok(false);
        }
    };
    let pending = pending_tree_members(target, sweep, &snapshot);
    capture_pending_members(target, sweep, &snapshot, pending, deadline)
}

fn pending_tree_members(
    target: &HarnessTarget,
    sweep: &mut Sweep,
    snapshot: &Snapshot,
) -> Vec<libc::pid_t> {
    let mut tree = snapshot.group_tree(target.pgid);
    // A captured escapee can have peers, children, and children reparented inside its
    // group. Extend the walk only while a captured member still proves that group.
    for process in sweep.frozen.values() {
        match verify_process_instance(&process.instance) {
            Ok(ProcessAuthority::Live) => tree.extend(snapshot.group_tree(process.instance.pgid)),
            Ok(ProcessAuthority::Gone) => {}
            Err(reason) => sweep.failures.push(reason),
        }
    }
    tree.into_iter()
        .filter(|pid| {
            *pid != sweep.caller && *pid != target.pgid && !sweep.frozen.contains_key(pid)
        })
        .collect()
}

fn capture_pending_members(
    target: &HarnessTarget,
    sweep: &mut Sweep,
    snapshot: &Snapshot,
    mut pending: Vec<libc::pid_t>,
    deadline: Instant,
) -> Result<bool, String> {
    let mut added = false;
    // Discover parent before child even when numeric PID order has wrapped. A whole
    // snapshot can contain many generations; FREEZE_ROUNDS does not limit tree depth.
    loop {
        let (remaining, advanced, captured) =
            capture_pending_pass(target, sweep, snapshot, pending, deadline);
        added |= captured;
        if remaining.is_empty() {
            return Ok(added);
        }
        if !advanced {
            sweep.failures.push(format!(
                "harness ancestry no longer provable for captured table entries {remaining:?}"
            ));
            return Ok(added);
        }
        pending = remaining;
    }
}

fn capture_pending_pass(
    target: &HarnessTarget,
    sweep: &mut Sweep,
    snapshot: &Snapshot,
    pending: Vec<libc::pid_t>,
    deadline: Instant,
) -> (Vec<libc::pid_t>, bool, bool) {
    let mut remaining = Vec::new();
    let mut advanced = false;
    let mut added = false;
    for pid in pending {
        let Some(observed) = snapshot.process(pid) else {
            continue;
        };
        if observed.zombie {
            continue;
        }
        let Some(anchor) = find_capture_anchor(sweep, observed) else {
            remaining.push(pid);
            continue;
        };
        let captured = capture_member(observed, anchor);
        advanced = true;
        if record_captured_member(target, sweep, observed.pid, captured, deadline) {
            added = true;
        }
    }
    (remaining, advanced, added)
}

fn find_capture_anchor<'a>(sweep: &'a Sweep, observed: &Process) -> Option<&'a BoundProcess> {
    std::iter::once(&sweep.leader)
        .chain(sweep.frozen.values())
        .find(|parent| {
            parent.instance.pid == observed.ppid || parent.instance.pgid == observed.pgid
        })
}

fn record_captured_member(
    target: &HarnessTarget,
    sweep: &mut Sweep,
    pid: libc::pid_t,
    captured: Result<Option<BoundProcess>, String>,
    deadline: Instant,
) -> bool {
    match captured {
        Ok(Some(process)) => {
            sweep.frozen.insert(pid, process);
            if let Err(reason) = stop_process(&sweep.frozen[&pid], target, &sweep.leader, deadline)
            {
                sweep.failures.push(reason);
            }
            true
        }
        Ok(None) => false,
        Err(reason) => {
            sweep.failures.push(reason);
            false
        }
    }
}

fn require_sweep_authority(target: &HarnessTarget, leader: &BoundProcess) -> Result<(), String> {
    target.require_live_before_signal()?;
    if !leader.alive()? {
        return Err(format!(
            "harness session leader {} disappeared during cleanup",
            target.pgid
        ));
    }
    Ok(())
}

fn capture_member(
    observed: &Process,
    anchor: &BoundProcess,
) -> Result<Option<BoundProcess>, String> {
    let require_anchor = || -> Result<(), String> {
        if !anchor.alive()? || verify_process_instance(&anchor.instance)? != ProcessAuthority::Live
        {
            return Err(format!(
                "process {} lost its captured ancestry/group anchor {}",
                observed.pid, anchor.instance.pid
            ));
        }
        Ok(())
    };
    require_anchor()?;
    let Some(process) = BoundProcess::capture(ProcessInstance {
        pid: observed.pid,
        pgid: observed.pgid,
        start_time: observed.start_time,
    })?
    else {
        return Ok(None);
    };
    let current = match read_process(observed.pid) {
        Ok(current) => current,
        Err(error) if process_read_target_gone(&error) => return Ok(None),
        Err(error) => {
            return Err(format!(
                "process {} ancestry unreadable: {error}",
                observed.pid
            ));
        }
    };
    if current.ppid != observed.ppid
        || current.pgid != observed.pgid
        || current.start_time != observed.start_time
    {
        return Err(format!(
            "process {} ancestry or instance changed during capture",
            observed.pid
        ));
    }
    require_anchor()?;
    Ok(Some(process))
}

fn stop_process(
    process: &BoundProcess,
    target: &HarnessTarget,
    leader: &BoundProcess,
    deadline: Instant,
) -> Result<(), String> {
    require_sweep_authority(target, leader)?;
    match process.signal(libc::SIGSTOP)? {
        ProcessSignalResult::Gone => return Ok(()),
        ProcessSignalResult::Failed(error) => {
            return Err(format!(
                "process {} could not be stopped: {error}",
                process.instance.pid
            ));
        }
        ProcessSignalResult::Delivered => {}
    }
    wait_for_stopped(process, deadline).map(|_| ())
}

fn wait_for_stopped(process: &BoundProcess, deadline: Instant) -> Result<bool, String> {
    loop {
        let current = match read_process(process.instance.pid) {
            Ok(current) => current,
            Err(error) if process_read_target_gone(&error) => return Ok(false),
            Err(error) => {
                return Err(format!(
                    "process {} stop state unreadable: {error}",
                    process.instance.pid
                ));
            }
        };
        if current.start_time != process.instance.start_time
            || current.pgid != process.instance.pgid
        {
            return Err(format!(
                "process {} instance changed while awaiting STOP",
                process.instance.pid
            ));
        }
        if current.zombie {
            return Ok(false);
        }
        if current.stopped {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "process {} did not enter the frozen state",
                process.instance.pid
            ));
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// Captured escapees die first, then the recorded group's members, then its leader.
/// A missing leader during an established sweep is a failure for every captured survivor;
/// a later empty-group observation never erases that failure (PR30 F1).
fn kill_harness_tree(target: &HarnessTarget, mut sweep: Sweep) -> Result<i32, String> {
    for escaped in [true, false] {
        for process in sweep
            .frozen
            .values()
            .filter(|process| (process.instance.pgid != target.pgid) == escaped)
        {
            if let Err(reason) = kill_captured(process, target, &sweep.leader) {
                sweep.failures.push(reason);
            }
        }
    }
    if sweep.leader.instance.pid != sweep.caller {
        if let Err(reason) = kill_captured(&sweep.leader, target, &sweep.leader) {
            sweep.failures.push(reason);
        }
    }
    if sweep.failures.is_empty() {
        Ok(0)
    } else {
        Err(format!(
            "harness cleanup incomplete: {}",
            sweep.failures.join("; ")
        ))
    }
}

fn kill_captured(
    process: &BoundProcess,
    target: &HarnessTarget,
    leader: &BoundProcess,
) -> Result<(), String> {
    // Unlike pre-sweep empty-group success, losing the leader cannot settle a capture.
    require_sweep_authority(target, leader)?;
    match process.signal(libc::SIGKILL)? {
        ProcessSignalResult::Delivered | ProcessSignalResult::Gone => Ok(()),
        ProcessSignalResult::Failed(error) => Err(format!(
            "captured process {} outlived SIGKILL: {error}",
            process.instance.pid
        )),
    }
}

enum ProcessSignalResult {
    Delivered,
    Gone,
    Failed(io::Error),
}

#[cfg(test)]
fn signal_process_instance(
    instance: &ProcessInstance,
    signal: libc::c_int,
) -> Result<ProcessSignalResult, String> {
    match BoundProcess::capture(*instance)? {
        Some(process) => process.signal(signal),
        None => Ok(ProcessSignalResult::Gone),
    }
}

fn read_process_group(pid: libc::pid_t) -> io::Result<libc::pid_t> {
    #[cfg(test)]
    if let Some(errno) = PROCESS_GROUP_ERRNO.with(|value| value.take()) {
        return Err(io::Error::from_raw_os_error(errno));
    }
    let pgid = unsafe { libc::getpgid(pid) };
    if pgid == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(pgid)
    }
}

#[cfg(test)]
thread_local! {
    static PROCESS_SIGNAL_CALLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static PROCESS_GROUP_ERRNO: std::cell::Cell<Option<i32>> = const { std::cell::Cell::new(None) };
}

// Every captured member uses the stricter process errno classification on both
// platforms. Empty-group success is established by observation, never a member EPERM.
fn process_signal_target_gone(error: &io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH)
}

fn process_read_target_gone(error: &io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH) || error.kind() == io::ErrorKind::NotFound
}

// Preserve group-cleanup error coverage against the delivery predicate actually used
// by retained capabilities. Darwin's former numeric-killpg EPERM exception no longer
// applies; its empty-group success is covered by the real pre-sweep reap regression.
#[cfg(test)]
fn classify_group_kill(pgid: libc::pid_t, error: std::io::Error) -> Result<i32, String> {
    if process_signal_target_gone(&error) {
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
    fn eperm_is_refused_for_captured_group_members_on_darwin() {
        assert!(classify_group_kill(1234, Error::from_raw_os_error(libc::EPERM)).is_err());
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
    use super::process_signal_target_gone;
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
    fn eperm_is_not_gone_for_group_members_on_darwin() {
        assert!(!process_signal_target_gone(&Error::from_raw_os_error(
            libc::EPERM
        )));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn eperm_is_not_gone_for_group_signals_on_linux() {
        assert!(!process_signal_target_gone(&Error::from_raw_os_error(
            libc::EPERM
        )));
    }
}

#[cfg(test)]
mod instance_authority_tests {
    use super::{
        HarnessTarget, PROCESS_GROUP_ERRNO, PROCESS_SIGNAL_CALLS, ProcessInstance,
        ProcessSignalResult, ProcessStartTime, boot_identity, freeze_harness_tree, group,
        parse_proc_starttime, read_process_start_time, signal_process_instance,
        verify_process_instance,
    };
    use std::fs;

    fn stale(time: ProcessStartTime) -> ProcessStartTime {
        ProcessStartTime {
            seconds: time.seconds.saturating_add(1),
            microseconds: time.microseconds,
        }
    }

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

    #[test]
    fn signal_time_pid_reuse_never_reaches_numeric_kill() {
        PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
        let pid = unsafe { libc::getpid() };
        let pgid = unsafe { libc::getpgid(pid) };
        let current = read_process_start_time(pid).expect("live pid start time readable");
        let reused = ProcessInstance {
            pid,
            pgid,
            start_time: stale(current),
        };

        let error = signal_process_instance(&reused, 0)
            .err()
            .expect("a pid now occupied by another instance must be refused");

        assert!(error.contains("pid reuse"), "{error}");
        PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 0));
    }

    #[test]
    fn signal_time_esrch_never_reaches_numeric_kill() {
        PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
        let pid = unsafe { libc::getpid() };
        let gone = ProcessInstance {
            pid,
            pgid: unsafe { libc::getpgid(pid) },
            start_time: read_process_start_time(pid).expect("live pid start time readable"),
        };
        PROCESS_GROUP_ERRNO.with(|errno| errno.set(Some(libc::ESRCH)));

        assert!(matches!(
            signal_process_instance(&gone, 0),
            Ok(ProcessSignalResult::Gone)
        ));
        PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 0));
    }

    #[test]
    fn signal_time_pgid_reuse_never_reaches_numeric_killpg() {
        PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
        let pgid = unsafe { libc::getpgrp() };
        let current = read_process_start_time(pgid).expect("live group leader start time readable");
        let captured = stale(current);
        let boot = boot_identity().expect("boot identity readable");
        let launch = "signal-time-pgid-reuse";
        let path = std::env::temp_dir().join(format!(
            "tightbeam-pgid-reuse-{}-{}",
            std::process::id(),
            current.seconds
        ));
        fs::write(
            &path,
            format!(
                "{pgid}\t{pgid}\t{}\t{}\t{boot}\t{launch}\n",
                captured.seconds, captured.microseconds
            ),
        )
        .unwrap();
        let target = HarnessTarget {
            pgid,
            identity_path: path.to_string_lossy().into_owned(),
            boot_identity: boot,
            launch_id: launch.into(),
            leader_start_time: captured,
        };

        let error = freeze_harness_tree(&target)
            .err()
            .expect("a pgid now led by another instance must be refused");

        assert!(error.contains("pid/pgid reuse"), "{error}");
        PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 0));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn disappeared_leader_with_an_empty_group_never_reaches_numeric_killpg() {
        PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
        let pgid = 999_999_123;
        let captured = ProcessStartTime {
            seconds: 1,
            microseconds: 0,
        };
        let boot = boot_identity().expect("boot identity readable");
        let launch = "disappeared-leader";
        let path = std::env::temp_dir().join(format!(
            "tightbeam-disappeared-leader-{}",
            std::process::id()
        ));
        fs::write(&path, format!("{pgid}\t{pgid}\t1\t0\t{boot}\t{launch}\n")).unwrap();
        let target = HarnessTarget {
            pgid,
            identity_path: path.to_string_lossy().into_owned(),
            boot_identity: boot,
            launch_id: launch.into(),
            leader_start_time: captured,
        };

        group(&[
            pgid.to_string(),
            target.identity_path.clone(),
            target.boot_identity.clone(),
            target.launch_id.clone(),
        ])
        .expect("an observed-empty group needs no signal delivery");

        PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 0));
        fs::remove_file(path).unwrap();
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
) -> Result<ProcessStartTime, String> {
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
    let fields = recorded.trim_end().split('\t').collect::<Vec<_>>();
    match fields.as_slice() {
        [pid, group, seconds, microseconds, boot, launch]
            if identity_matches(
                pid,
                group,
                boot,
                launch,
                pgid,
                expected_boot_identity,
                launch_id,
            ) =>
        {
            parse_start_time(seconds, microseconds)
        }
        [pid, group, boot, launch]
            if identity_matches(
                pid,
                group,
                boot,
                launch,
                pgid,
                expected_boot_identity,
                launch_id,
            ) =>
        {
            read_identity_authority(path, pgid, expected_boot_identity, launch_id)
        }
        _ => Err("harness identity does not match the requested process group".into()),
    }
}

fn identity_matches(
    pid: &str,
    group: &str,
    boot_identity: &str,
    launch: &str,
    pgid: libc::pid_t,
    expected_boot_identity: &str,
    launch_id: &str,
) -> bool {
    pid == pgid.to_string()
        && group == pgid.to_string()
        && boot_identity == expected_boot_identity
        && launch == launch_id
}

fn parse_start_time(seconds: &str, microseconds: &str) -> Result<ProcessStartTime, String> {
    let seconds = seconds
        .parse::<libc::time_t>()
        .map_err(|_| "harness identity carries an invalid leader start time".to_string())?;
    let microseconds = microseconds
        .parse::<i32>()
        .map_err(|_| "harness identity carries an invalid leader start time".to_string())?;
    Ok(ProcessStartTime {
        seconds,
        microseconds,
    })
}

fn read_identity_authority(
    identity_path: &Path,
    pgid: libc::pid_t,
    expected_boot_identity: &str,
    launch_id: &str,
) -> Result<ProcessStartTime, String> {
    let path = identity_authority_path(identity_path);
    let mut authority = OpenOptions::new()
        .read(true)
        .open(&path)
        .map_err(|error| format!("harness identity authority could not be opened: {error}"))?;
    let mut recorded = String::new();
    authority
        .read_to_string(&mut recorded)
        .map_err(|error| format!("harness identity authority could not be read: {error}"))?;
    let fields = recorded.trim_end().split('\t').collect::<Vec<_>>();
    match fields.as_slice() {
        [version, pid, group, seconds, microseconds, boot, launch]
            if *version == IDENTITY_AUTHORITY_VERSION
                && identity_matches(
                    pid,
                    group,
                    boot,
                    launch,
                    pgid,
                    expected_boot_identity,
                    launch_id,
                ) =>
        {
            parse_start_time(seconds, microseconds)
        }
        _ => Err("harness identity authority does not match the requested process group".into()),
    }
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

    #[test]
    fn session_exec_publishes_a_legacy_body_with_versioned_authority() {
        let path = test_path("compatible-identity");
        let launch = "compatible-launch";

        assert_eq!(
            session_exec(&[
                path.to_string_lossy().into_owned(),
                launch.into(),
                "--".into(),
                "/bin/true".into(),
            ]),
            Ok(0)
        );

        let body = fs::read_to_string(&path).unwrap();
        let fields = body.trim_end().split('\t').collect::<Vec<_>>();
        assert_eq!(fields.len(), 4, "old coordinators require four fields");
        assert_eq!(fields[0], fields[1]);
        assert_eq!(fields[3], launch);

        let authority_path = identity_authority_path(&path);
        let authority = fs::read_to_string(&authority_path).unwrap();
        let authority_fields = authority.trim_end().split('\t').collect::<Vec<_>>();
        assert_eq!(authority_fields.len(), 7);
        assert_eq!(authority_fields[0], IDENTITY_AUTHORITY_VERSION);
        assert_eq!(authority_fields[1], fields[0]);
        assert_eq!(authority_fields[2], fields[1]);
        assert_eq!(authority_fields[5], fields[2]);
        assert_eq!(authority_fields[6], fields[3]);

        fs::remove_file(authority_path).unwrap();
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn four_field_identity_without_versioned_authority_refuses() {
        let path = test_path("legacy-without-authority");
        let pgid = unsafe { libc::getpgrp() };
        let boot = boot_identity().unwrap();
        let launch = "legacy-without-authority";
        fs::write(&path, format!("{pgid}\t{pgid}\t{boot}\t{launch}\n")).unwrap();

        let error = authorize_group_signal(&path, pgid, &boot, launch).unwrap_err();
        assert!(
            error.starts_with("harness identity authority could not be opened:"),
            "{error}"
        );

        fs::remove_file(path).unwrap();
    }

    #[test]
    fn historical_six_field_identity_still_authorizes() {
        let path = test_path("historical-six-field");
        let pgid = unsafe { libc::getpgrp() };
        let start = read_process_start_time(pgid).unwrap();
        let boot = boot_identity().unwrap();
        let launch = "historical-six-field";
        fs::write(
            &path,
            format!(
                "{pgid}\t{pgid}\t{}\t{}\t{boot}\t{launch}\n",
                start.seconds, start.microseconds
            ),
        )
        .unwrap();

        assert_eq!(
            authorize_group_signal(&path, pgid, &boot, launch),
            Ok(start)
        );

        fs::remove_file(path).unwrap();
    }
}
