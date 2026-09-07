//! The process table, read through each platform's own API.
//!
//! Read through a syscall rather than shelled out to on purpose. The gateway runs as a
//! LaunchDaemon whose PATH does not carry `/usr/sbin`, and a bare command name in this
//! layer has already cost this org three rounds (`lsof`, `security`). `ps` would be a
//! fourth: parsing its columns is a second guess on top of the first.

use std::collections::{BTreeSet, HashMap};

/// The three fields a kill floor needs: who this is, who it came from, which group it is in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Process {
    pub(crate) pid: libc::pid_t,
    pub(crate) ppid: libc::pid_t,
    pub(crate) pgid: libc::pid_t,
}

/// One reading of the process table. Never refreshed in place: a sweep that needs a newer
/// answer captures a new one, so no caller can reason over a mix of two moments.
pub(crate) struct Snapshot {
    processes: Vec<Process>,
}

impl Snapshot {
    pub(crate) fn capture() -> Result<Self, String> {
        Ok(Self {
            processes: read_process_table()?,
        })
    }

    #[cfg(test)]
    pub(crate) fn of(processes: Vec<Process>) -> Self {
        Self { processes }
    }

    /// Every live process in `pgid`, plus everything descended from one of them.
    ///
    /// The group is the authorized root because it is the identity the caller already
    /// proved; parentage is the extension, because a process that took itself out of the
    /// group with `setsid` leaves no other evidence that it is ours.
    ///
    /// Group 1 is refused outright, and `pid <= 1` is never entered or returned. init leads
    /// group 1 and every daemon the kernel reparented sits in it, so a walk that accepted it
    /// would return most of the machine — the one mistake here that cannot be apologised
    /// for. No harness can ask for it: a launch's recorded group is the pid of a `setsid`
    /// leader, and that is never 1.
    pub(crate) fn group_tree(&self, pgid: libc::pid_t) -> BTreeSet<libc::pid_t> {
        if pgid <= 1 {
            return BTreeSet::new();
        }

        let mut children: HashMap<libc::pid_t, Vec<libc::pid_t>> = HashMap::new();
        for process in &self.processes {
            if process.pid > 1 {
                children.entry(process.ppid).or_default().push(process.pid);
            }
        }

        let mut tree: BTreeSet<libc::pid_t> = self
            .processes
            .iter()
            .filter(|process| process.pgid == pgid && process.pid > 1)
            .map(|process| process.pid)
            .collect();

        // Insert-then-push is what makes this terminate whatever the table says. A process
        // table can name a cycle (its own reading raced a reparent); a pid already in the
        // set is never queued again, so a cycle is walked once and not forever.
        let mut queue: Vec<libc::pid_t> = tree.iter().copied().collect();
        while let Some(pid) = queue.pop() {
            for child in children.get(&pid).into_iter().flatten() {
                if tree.insert(*child) {
                    queue.push(*child);
                }
            }
        }

        tree
    }

    pub(crate) fn pgid_of(&self, pid: libc::pid_t) -> Option<libc::pid_t> {
        self.processes
            .iter()
            .find(|process| process.pid == pid)
            .map(|process| process.pgid)
    }

    /// The distinct process groups those pids sit in — the groups a sweep has to signal.
    pub(crate) fn process_groups(&self, pids: &BTreeSet<libc::pid_t>) -> BTreeSet<libc::pid_t> {
        self.processes
            .iter()
            .filter(|process| pids.contains(&process.pid))
            .map(|process| process.pgid)
            .filter(|pgid| *pgid > 1)
            .collect()
    }
}

/// Every pid the kernel will name, into a buffer big enough to have held one more.
///
/// The kernel quotes a size and then the table grows underneath the answer, so a buffer
/// that comes back EXACTLY full may have been truncated — and a truncated table silently
/// loses the escapee this whole sweep exists to find. Room to spare is the proof it was
/// not truncated, so the buffer is grown until the answer does not fill it.
///
/// BOUNDED, and the bound is load-bearing rather than a formality: this runs inside the
/// kill floor, where a loop that never settled would let the gateway's 5s call expire as
/// `sigkill_delivery_unconfirmed` — a kill_failed row, and a fence on the adapter key —
/// over a process table. Giving up SAYS SO and lets the floor degrade to the recorded
/// group, which is what it signalled before this walk existed.
///
/// `proc_listallpids` answers in PIDS, not bytes. It is a wrapper over `proc_listpids`,
/// which answers in bytes, and it has already divided by `sizeof(int)` before it returns.
/// Dividing again is the defect review caught at 9e8245c: it kept the first quarter of the
/// table (1635 pids read, 408 kept) and dropped the rest. That failure is invisible to any
/// test that spawns its own tree, because a newly forked process is at the FRONT of the
/// list and survives the truncation — the leak only appears for a harness whose group has
/// since been pushed past the cut by newer processes. `the_live_process_table_reaches_the_oldest_process`
/// is the assertion that now fails instead of passing quietly.
#[cfg(target_os = "macos")]
fn list_all_pids() -> Result<Vec<i32>, String> {
    let mut capacity = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if capacity <= 0 {
        return Err(format!(
            "process table size unavailable: {}",
            std::io::Error::last_os_error()
        ));
    }

    for _ in 0..8 {
        let mut pids = vec![0i32; capacity as usize + 64];
        let listed = unsafe {
            libc::proc_listallpids(
                pids.as_mut_ptr().cast(),
                (pids.len() * size_of::<i32>()) as libc::c_int,
            )
        };
        if listed <= 0 {
            return Err(format!(
                "process table unavailable: {}",
                std::io::Error::last_os_error()
            ));
        }

        let listed = listed as usize;
        if listed < pids.len() {
            pids.truncate(listed);
            return Ok(pids);
        }
        capacity = pids.len() as libc::c_int * 2;
    }

    Err("process table still filled a buffer doubled eight times".to_string())
}

/// `proc_listallpids` + `proc_pidinfo`: the documented libproc reading of the table.
///
/// A pid that fails `proc_pidinfo` is DROPPED rather than guessed at. Between the listing
/// and the query it may have exited, and a kernel process was never ours to begin with —
/// either way an entry we cannot read is one we cannot show is a harness descendant, and
/// this sweep signals nothing it cannot show.
#[cfg(target_os = "macos")]
fn read_process_table() -> Result<Vec<Process>, String> {
    let pids = list_all_pids()?;

    let mut processes = Vec::with_capacity(pids.len());
    for pid in pids {
        if pid <= 0 {
            continue;
        }
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
        let read = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                std::ptr::addr_of_mut!(info).cast(),
                size,
            )
        };
        if read == size {
            processes.push(Process {
                pid: info.pbi_pid as libc::pid_t,
                ppid: info.pbi_ppid as libc::pid_t,
                pgid: info.pbi_pgid as libc::pid_t,
            });
        }
    }

    Ok(processes)
}

/// `/proc` IS linux's process-table API; there is nothing lower to call.
///
/// An entry that cannot be read or parsed is dropped for the same reason as darwin's:
/// a process that exited under the walk is not evidence of anything.
#[cfg(target_os = "linux")]
fn read_process_table() -> Result<Vec<Process>, String> {
    let entries = std::fs::read_dir("/proc")
        .map_err(|error| format!("process table unavailable: {error}"))?;

    let mut processes = Vec::new();
    for entry in entries.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<libc::pid_t>() else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
            continue;
        };
        if let Some(process) = parse_proc_stat(pid, &stat) {
            processes.push(process);
        }
    }

    Ok(processes)
}

/// Field 2 of `/proc/<pid>/stat` is the executable name IN PARENTHESES, and it is the
/// process's own to choose: `sh -c 'exec -a ") 1 2 3 (" sleep 60'` puts spaces and both
/// parentheses inside it. Splitting on whitespace from the left reads that name as the
/// ppid and pgrp columns — a process could then NAME ITSELF out of this sweep. The last
/// `)` in the line is the one unambiguous landmark, so everything is read relative to it.
#[cfg(any(target_os = "linux", test))]
fn parse_proc_stat(pid: libc::pid_t, stat: &str) -> Option<Process> {
    let tail = &stat[stat.rfind(')')? + 1..];
    let mut fields = tail.split_ascii_whitespace();
    let _state = fields.next()?;
    let ppid = fields.next()?.parse::<libc::pid_t>().ok()?;
    let pgid = fields.next()?.parse::<libc::pid_t>().ok()?;
    Some(Process { pid, ppid, pgid })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: libc::pid_t, ppid: libc::pid_t, pgid: libc::pid_t) -> Process {
        Process { pid, ppid, pgid }
    }

    /// The measured pi 0.84.2 tree, which one `killpg` could not clear:
    /// leader 10421 in its own group, worker 10423 in the leader's group, and
    /// `sleep 400` at 10957 in a group of its OWN, reachable only as a grandchild.
    #[test]
    fn a_detached_grandchild_is_in_the_tree_and_its_own_group_is_collected() {
        let snapshot = Snapshot::of(vec![
            process(10421, 1, 10421),
            process(10423, 10421, 10421),
            process(10957, 10423, 10957),
            process(11000, 1, 11000),
        ]);

        let tree = snapshot.group_tree(10421);

        assert!(
            tree.contains(&10957),
            "the detached grandchild the floor orphans was not in the tree: {tree:?}"
        );
        assert!(
            !tree.contains(&11000),
            "an unrelated process was swept in: {tree:?}"
        );
        assert_eq!(
            snapshot.process_groups(&tree),
            BTreeSet::from([10421, 10957]),
            "the grandchild's own group is the one a single killpg never signals"
        );
    }

    /// Reparenting to init is what the capture recorded AFTER the kill, and it is also how
    /// a descendant can look mid-sweep. Ancestry to init is not ancestry to the harness.
    #[test]
    fn a_process_reparented_to_init_is_not_reachable_through_init() {
        let snapshot = Snapshot::of(vec![
            process(1, 0, 1),
            process(500, 1, 500),
            process(600, 1, 600),
        ]);

        let tree = snapshot.group_tree(500);

        assert_eq!(
            tree,
            BTreeSet::from([500]),
            "the walk went up through init and swept the machine: {tree:?}"
        );
    }

    /// init leads process group 1. A sweep that entered it would kill the box.
    #[test]
    fn group_one_is_never_walked() {
        let snapshot = Snapshot::of(vec![
            process(1, 0, 1),
            process(500, 1, 1),
            process(600, 500, 1),
        ]);

        assert!(
            snapshot.group_tree(1).is_empty(),
            "the sweep entered init's own process group"
        );
    }

    /// A table that names a cycle is a table read while the kernel was reparenting. It must
    /// not hang the floor: the sweep is what stands between a SIGKILLed harness and an
    /// orphan, and it does not get to spin instead.
    #[test]
    fn a_cycle_in_the_table_terminates() {
        let snapshot = Snapshot::of(vec![
            process(500, 600, 500),
            process(600, 500, 500),
            process(700, 600, 700),
        ]);

        assert_eq!(snapshot.group_tree(500), BTreeSet::from([500, 600, 700]));
    }

    /// The `comm` field is attacker-controlled text that contains the delimiter.
    #[test]
    fn a_command_name_full_of_parentheses_does_not_move_the_columns() {
        let stat = "4242 () 1 2 3 (evil)) S 4200 4100 4100 0 -1 4194304";

        assert_eq!(
            parse_proc_stat(4242, stat),
            Some(Process {
                pid: 4242,
                ppid: 4200,
                pgid: 4100
            }),
            "a process renamed itself out of the sweep"
        );
    }

    #[test]
    fn an_ordinary_proc_stat_line_reads_its_parent_and_group() {
        let stat = "4242 (sleep) S 4200 4100 4100 0 -1 4194304 123 0 0 0";

        assert_eq!(
            parse_proc_stat(4242, stat),
            Some(Process {
                pid: 4242,
                ppid: 4200,
                pgid: 4100
            })
        );
    }

    /// The floor runs on the machine the tests run on, so the real table has to be
    /// readable here — and this process has to be in it, with the parent and group it
    /// knows it has. A platform reader that silently returned nothing would make every
    /// sweep above vacuous.
    #[test]
    fn the_live_process_table_names_this_process_correctly() {
        let snapshot = Snapshot::capture().expect("the process table must be readable");
        let me = unsafe { libc::getpid() };

        let mine = snapshot
            .processes
            .iter()
            .find(|process| process.pid == me)
            .unwrap_or_else(|| panic!("the live table did not contain this process ({me})"));

        assert_eq!(mine.ppid, unsafe { libc::getppid() });
        assert_eq!(mine.pgid, unsafe { libc::getpgrp() });
    }

    /// The table must reach the OLDEST process, not merely the newest ones.
    ///
    /// This is the assertion that was missing at 9e8245c, and its absence is why a real
    /// truncation bug shipped through a green suite. `list_all_pids` divided
    /// `proc_listallpids`' answer by `sizeof(int)` — but that function already divides, so
    /// only the first quarter of the table survived. Every test in this file spawned its own
    /// processes and then looked for them, and `proc_listallpids` answers NEWEST FIRST
    /// (MEASURED on this host: 1618 pids, pid 1 at index 1616), so a freshly forked process
    /// is at the very front and rides out any truncation. The suite was green and the floor
    /// leaked an aged harness tree, which is exactly what review reproduced.
    ///
    /// launchd is the fixed point that cannot be gamed: always pid 1, always the oldest, and
    /// therefore always the LAST thing a truncated read would keep.
    #[test]
    #[cfg(target_os = "macos")]
    fn the_live_process_table_reaches_the_oldest_process() {
        let pids = list_all_pids().expect("the process table must be listable");

        assert!(
            pids.contains(&1),
            "the listing stopped before launchd: {} pids, ending {:?} — the table is \
             truncated and an aged harness tree would be invisible to the floor",
            pids.len(),
            &pids[pids.len().saturating_sub(3)..]
        );

        // The magnitude, alongside the mechanism above: a quartered table is the specific
        // shape of the shipped defect, and halving is comfortably inside a real reading's
        // drift between the sizing call and the fetch.
        let quoted = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
        assert!(
            pids.len() as i32 >= quoted / 2,
            "the kernel quoted {quoted} pids and the listing kept {} — most of the table \
             was dropped",
            pids.len()
        );
    }
}
