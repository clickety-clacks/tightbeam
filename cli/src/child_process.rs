use std::io;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::thread;
use std::time::{Duration, Instant};

/// Restore the parent disposition that keeps an exited child waitable.
///
/// Whether a dead child becomes a zombie is decided by THIS process's SIGCHLD
/// disposition, not the child's: with SIGCHLD ignored, the kernel reaps on our behalf
/// the instant the child dies, there is nothing left to wait for, and the pid is
/// released with no wait of ours involved. Process-group deadline code depends on the
/// opposite — the leader's pid stays ours until we reap it, which is what makes the
/// group id safe to signal at the deadline. `SIG_IGN` is inherited across `exec`, so a
/// CLI can arrive already holding a disposition some ancestor chose. Reset it before
/// the fork, so what we inherit cannot decide it.
///
/// Measured on both platforms — linux auto-reaps under the inherited ignore, darwin
/// does not — by the inherited-SIGCHLD regression tests.
pub(crate) fn reset_sigchld_before_spawn() {
    unsafe {
        libc::signal(libc::SIGCHLD, libc::SIG_DFL);
    }
}

/// Has the leader exited? Asked WITHOUT reaping it.
///
/// A pid is a valid signal target only until it is reaped — that is a state transition,
/// not a window, and no delay makes signalling a reaped pid safer. `try_wait` here would
/// reap: `waitpid(WNOHANG)` returns the status and frees the pid in the same call.
/// Process-group deadline loops deliberately stay armed past the leader's exit because a
/// descendant may still hold a pipe, so the leader must remain a zombie until after the
/// group is signalled or all pipe readers finish.
///
/// `WNOWAIT` is the one flag that separates the two things `waitpid` does at once: it
/// reports the exit and leaves the child a zombie. A zombie still occupies its pid, and
/// the pid is the group id, so the group being held cannot be reissued underneath it.
///
/// `waitid` rather than `waitpid` because `WNOWAIT` is documented as a `waitid`-only
/// option on both platforms. The struct is zeroed first and read back through `si_signo`,
/// which POSIX.1-2008 TC1 requires to be cleared when `WNOHANG` finds nothing and which
/// is a plain field on both linux and darwin.
pub(crate) fn exited_without_reaping(child: &std::process::Child) -> io::Result<bool> {
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };

    let result = unsafe {
        libc::waitid(
            libc::P_PID,
            child.id() as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };

    if result == -1 {
        return Err(io::Error::last_os_error());
    }

    Ok(info.si_signo != 0)
}

/// Signal the process group whose leader is still this waitable child.
///
/// The non-reaping identity check is not optional: once the leader has been reaped, its
/// pid (and therefore the numeric process-group id) can be reused. Every caller keeps the
/// leader waitable until it no longer needs to signal the group.
pub(crate) fn signal_process_group(
    child: &std::process::Child,
    signal: libc::c_int,
) -> io::Result<()> {
    exited_without_reaping(child)?;
    let result = unsafe { libc::killpg(child.id() as libc::pid_t, signal) };
    if result == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Give an owned process group a bounded graceful shutdown without reaping its leader.
///
/// The caller disarms any signal-forwarding handler before it performs the first reap,
/// so no handler can target the numeric group id after the kernel is free to reuse it.
pub(crate) fn terminate_process_group(
    child: &mut std::process::Child,
    grace: Duration,
) -> io::Result<()> {
    signal_process_group(child, libc::SIGTERM)?;
    let deadline = Instant::now() + grace;
    let mut leader_exited = false;
    while Instant::now() < deadline {
        if exited_without_reaping(child)? {
            leader_exited = true;
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }

    match signal_process_group(child, libc::SIGKILL) {
        Ok(()) => {}
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {}
        // Darwin reports EPERM when a group contains only exited processes. TERM
        // succeeded before the grace period, and the still-waitable leader proves this
        // numeric group identity has not been reused. A live descendant with the
        // ceremony's unchanged credentials remains signalable and makes killpg succeed.
        #[cfg(target_os = "macos")]
        Err(error) if leader_exited && error.raw_os_error() == Some(libc::EPERM) => {}
        Err(error) => return Err(error),
    }
    Ok(())
}

const SIGNAL_SLOT_COUNT: usize = 64;
static ACTIVE_PROCESS_GROUPS: [AtomicI32; SIGNAL_SLOT_COUNT] =
    [const { AtomicI32::new(0) }; SIGNAL_SLOT_COUNT];
static FORWARDED_SIGNALS: [AtomicI32; SIGNAL_SLOT_COUNT] =
    [const { AtomicI32::new(0) }; SIGNAL_SLOT_COUNT];
static CLAIMED_SIGNAL_SLOTS: [AtomicBool; SIGNAL_SLOT_COUNT] =
    [const { AtomicBool::new(false) }; SIGNAL_SLOT_COUNT];

struct HandlerState {
    users: usize,
    previous: Vec<(libc::c_int, libc::sigaction)>,
}

static SIGNAL_HANDLER_STATE: Mutex<HandlerState> = Mutex::new(HandlerState {
    users: 0,
    previous: Vec::new(),
});

extern "C" fn forward_to_active_group(signal: libc::c_int) {
    for (slot, active) in ACTIVE_PROCESS_GROUPS.iter().enumerate() {
        let pgid = active.load(Ordering::Relaxed);
        if pgid > 0 {
            unsafe {
                libc::killpg(pgid, signal);
            }
            FORWARDED_SIGNALS[slot].store(signal, Ordering::Relaxed);
        }
    }
}

/// Forward terminal/session termination to one owned child group.
///
/// A CLI process has only one foreground ceremony, while the test process can run many.
/// The fixed registry keeps the signal handler allocation-free and lets every confirmed
/// test child remain independently armed. Handlers are installed before spawn and a slot
/// is populated only after its child has been confirmed waitable, closing the parent-death
/// orphan path without ever putting an unconfirmed numeric identity in the handler.
pub(crate) struct SignalForwarding {
    slot: usize,
}

impl SignalForwarding {
    pub(crate) fn install() -> io::Result<Self> {
        let mut state = SIGNAL_HANDLER_STATE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let slot = CLAIMED_SIGNAL_SLOTS
            .iter()
            .position(|claimed| {
                claimed
                    .compare_exchange(false, true, Ordering::Relaxed, Ordering::Relaxed)
                    .is_ok()
            })
            .ok_or_else(|| io::Error::other("too many simultaneous child process groups"))?;
        FORWARDED_SIGNALS[slot].store(0, Ordering::Relaxed);

        if state.users == 0 {
            let mut previous = Vec::new();
            for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
                let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
                action.sa_sigaction = forward_to_active_group as *const () as usize;
                unsafe {
                    libc::sigemptyset(&mut action.sa_mask);
                }
                action.sa_flags = 0;

                let mut old: libc::sigaction = unsafe { std::mem::zeroed() };
                if unsafe { libc::sigaction(signal, &action, &mut old) } == -1 {
                    let error = io::Error::last_os_error();
                    for (installed, prior) in previous.iter().rev() {
                        unsafe {
                            libc::sigaction(*installed, prior, std::ptr::null_mut());
                        }
                    }
                    CLAIMED_SIGNAL_SLOTS[slot].store(false, Ordering::Relaxed);
                    return Err(error);
                }
                previous.push((signal, old));
            }
            state.previous = previous;
        }
        state.users += 1;

        Ok(Self { slot })
    }

    pub(crate) fn arm(&self, child: &std::process::Child) -> io::Result<()> {
        exited_without_reaping(child)?;
        ACTIVE_PROCESS_GROUPS[self.slot].store(child.id() as libc::pid_t, Ordering::Relaxed);
        Ok(())
    }

    pub(crate) fn caught(&self) -> Option<libc::c_int> {
        match FORWARDED_SIGNALS[self.slot].load(Ordering::Relaxed) {
            0 => None,
            signal => Some(signal),
        }
    }

    pub(crate) fn disarm(&self) {
        ACTIVE_PROCESS_GROUPS[self.slot].store(0, Ordering::Relaxed);
    }
}

impl Drop for SignalForwarding {
    fn drop(&mut self) {
        self.disarm();
        FORWARDED_SIGNALS[self.slot].store(0, Ordering::Relaxed);

        let mut state = SIGNAL_HANDLER_STATE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.users -= 1;
        if state.users == 0 {
            for (signal, previous) in state.previous.iter().rev() {
                unsafe {
                    libc::sigaction(*signal, previous, std::ptr::null_mut());
                }
            }
            state.previous.clear();
        }
        CLAIMED_SIGNAL_SLOTS[self.slot].store(false, Ordering::Relaxed);
    }
}
