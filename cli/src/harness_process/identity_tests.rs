use super::*;
use std::os::fd::FromRawFd;
use std::path::PathBuf;

/// An actual session leader and its detached child. Children use only async-signal-safe
/// libc calls after fork, since the Rust test runner has other threads.
struct OwnedTree {
    leader: BoundProcess,
    escapee: BoundProcess,
    target: HarnessTarget,
    path: PathBuf,
    reaped: bool,
}

impl OwnedTree {
    fn spawn() -> Self {
        let mut pipe = [0; 2];
        assert_eq!(unsafe { libc::pipe(pipe.as_mut_ptr()) }, 0);
        let leader = unsafe { libc::fork() };
        assert!(leader >= 0);
        if leader == 0 {
            unsafe {
                libc::close(pipe[0]);
                if libc::setsid() == -1 {
                    libc::_exit(101);
                }
                match libc::fork() {
                    -1 => libc::_exit(102),
                    0 => {
                        if libc::setsid() == -1 {
                            libc::_exit(103);
                        }
                        let pid = libc::getpid();
                        libc::write(
                            pipe[1],
                            std::ptr::addr_of!(pid).cast(),
                            size_of::<libc::pid_t>(),
                        );
                    }
                    _ => {}
                }
                libc::close(pipe[1]);
                loop {
                    libc::pause();
                }
            }
        }
        unsafe {
            libc::close(pipe[1]);
        }
        let mut reader = unsafe { fs::File::from_raw_fd(pipe[0]) };
        let mut bytes = [0; size_of::<libc::pid_t>()];
        reader.read_exact(&mut bytes).unwrap();
        let escapee = libc::pid_t::from_ne_bytes(bytes);
        let capture = |pid| {
            let process = read_process(pid).unwrap();
            BoundProcess::capture(ProcessInstance {
                pid,
                pgid: process.pgid,
                start_time: process.start_time,
            })
            .unwrap()
            .unwrap()
        };
        let leader = capture(leader);
        let escapee = capture(escapee);
        assert_ne!(leader.instance.pgid, escapee.instance.pgid);
        let path = std::env::temp_dir().join(format!(
            "pr30-identity-tree-{}-{}",
            std::process::id(),
            leader.instance.pid
        ));
        let boot = boot_identity().unwrap();
        fs::write(
            &path,
            format!(
                "{0}\t{0}\t{1}\t{2}\t{boot}\tidentity-test\n",
                leader.instance.pid,
                leader.instance.start_time.seconds,
                leader.instance.start_time.microseconds
            ),
        )
        .unwrap();
        let target = HarnessTarget::load(
            leader.instance.pid,
            path.to_str().unwrap(),
            &boot,
            "identity-test",
        )
        .unwrap();
        Self {
            leader,
            escapee,
            target,
            path,
            reaped: false,
        }
    }

    fn reap_leader(&mut self) {
        assert!(matches!(
            self.leader.signal(libc::SIGKILL),
            Ok(ProcessSignalResult::Delivered)
        ));
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(self.leader.instance.pid, &mut status, 0) },
            self.leader.instance.pid
        );
        self.reaped = true;
    }
}

impl Drop for OwnedTree {
    fn drop(&mut self) {
        let _ = self.escapee.signal(libc::SIGKILL);
        if !self.reaped {
            let _ = self.leader.signal(libc::SIGKILL);
            unsafe {
                libc::waitpid(self.leader.instance.pid, std::ptr::null_mut(), 0);
            }
        }
        let _ = fs::remove_file(&self.path);
    }
}

#[test]
fn reaped_leader_with_a_frozen_captured_escapee_fails_without_a_signal() {
    let mut tree = OwnedTree::spawn();
    let sweep = freeze_harness_tree(&tree.target).unwrap().unwrap();
    assert!(sweep.failures.is_empty(), "{:?}", sweep.failures);
    assert!(
        sweep.frozen.contains_key(&tree.escapee.instance.pid),
        "real detached child was not captured"
    );
    let stopped = read_process(tree.escapee.instance.pid).unwrap();
    assert!(stopped.stopped && !stopped.zombie);
    assert_eq!(stopped.start_time, tree.escapee.instance.start_time);

    tree.reap_leader();
    PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
    let error = kill_harness_tree(&tree.target, sweep).unwrap_err();
    assert!(error.contains("harness cleanup incomplete"), "{error}");
    assert!(error.contains("disappeared during cleanup"), "{error}");
    PROCESS_SIGNAL_CALLS
        .with(|calls| assert_eq!(calls.get(), 0, "leader loss authorized a signal"));
    let survivor = read_process(tree.escapee.instance.pid).unwrap();
    assert_eq!(survivor.start_time, tree.escapee.instance.start_time);
    assert!(
        survivor.stopped && !survivor.zombie,
        "captured survivor must remain unresolved"
    );
}

#[test]
fn a_real_presweep_reap_with_an_empty_group_remains_successful() {
    let mut tree = OwnedTree::spawn();
    tree.escapee.signal(libc::SIGKILL).unwrap();
    tree.reap_leader();
    PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
    assert_eq!(
        group(&[
            tree.target.pgid.to_string(),
            tree.path.to_string_lossy().into_owned(),
            tree.target.boot_identity.clone(),
            tree.target.launch_id.clone()
        ]),
        Ok(0)
    );
    PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 0));
}

#[test]
fn an_unreaped_dead_leader_with_no_live_members_needs_no_signal() {
    let tree = OwnedTree::spawn();
    tree.escapee.signal(libc::SIGKILL).unwrap();
    tree.leader.signal(libc::SIGKILL).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match read_process(tree.leader.instance.pid) {
            Ok(process) if process.zombie => break,
            Ok(_) => {
                assert!(Instant::now() < deadline);
                std::thread::sleep(Duration::from_millis(1));
            }
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => break,
            Err(error) => panic!("dead leader could not be inspected: {error}"),
        }
    }
    PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
    assert_eq!(
        group(&[
            tree.target.pgid.to_string(),
            tree.path.to_string_lossy().into_owned(),
            tree.target.boot_identity.clone(),
            tree.target.launch_id.clone()
        ]),
        Ok(0)
    );
    PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 0));
}

#[test]
fn a_reused_ancestry_number_cannot_authorize_a_new_capture() {
    let mut tree = OwnedTree::spawn();
    let observed = read_process(tree.escapee.instance.pid).unwrap();
    tree.reap_leader();
    // Replace scalar lookup metadata with a live process, retaining the dead anchor's
    // capability. Only the live capability can confer ancestry/group authority.
    tree.leader.instance = tree.escapee.instance;
    PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
    let error = capture_member(&observed, &tree.leader).err().unwrap();
    assert!(error.contains("ancestry/group anchor"), "{error}");
    PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 0));
    assert!(!read_process(tree.escapee.instance.pid).unwrap().zombie);
}

#[test]
fn an_unreadable_table_after_stop_keeps_captured_cleanup_and_failure() {
    let mut tree = OwnedTree::spawn();
    crate::process_tree::CAPTURE_FAILURE
        .with(|failure| failure.set(Some("injected table failure".into())));
    let sweep = freeze_harness_tree(&tree.target).unwrap().unwrap();
    assert!(read_process(tree.leader.instance.pid).unwrap().stopped);
    let error = kill_harness_tree(&tree.target, sweep).unwrap_err();
    assert!(error.contains("injected table failure"), "{error}");
    let mut status = 0;
    assert_eq!(
        unsafe { libc::waitpid(tree.leader.instance.pid, &mut status, 0) },
        tree.leader.instance.pid
    );
    tree.reaped = true;
    assert!(libc::WIFSIGNALED(status) && libc::WTERMSIG(status) == libc::SIGKILL);
    // The unreadable table never authorized this unseen descendant. It remains live,
    // so a success receipt here would be false; OwnedTree tears it down explicitly.
    assert!(!read_process(tree.escapee.instance.pid).unwrap().zombie);
}
