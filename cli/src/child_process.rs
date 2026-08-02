use std::io;
use std::process::{Child, Command, ExitStatus};
use std::sync::Mutex;
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};
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

    // Retried on EINTR because POSIX explicitly permits `waitid` to be interrupted, and
    // this process installs handlers for exactly the signals that would do it. An
    // interrupted probe is not an answer about the child; callers that treat it as one
    // decide something false about a live process. Bounded because a probe that cannot
    // answer must eventually say so rather than spin.
    for _ in 0..16 {
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                child.id() as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };

        if result == 0 {
            return Ok(info.si_signo != 0);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }

    Err(io::Error::new(
        io::ErrorKind::Interrupted,
        "waitid was interrupted repeatedly and never reported the child's state",
    ))
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

/// ONE atomic per slot, holding the slot's whole state: free, listening, done, or the
/// signal it caught.
///
/// Two atomics could not express this no matter how they were ordered, and three rounds of
/// review went into learning that. Recording a signal and being entitled to record it are
/// the same decision, so they have to be the same instruction: a handler already executing
/// on another thread can be descheduled between reading a separate "am I listening" flag
/// and storing into a separate record, and teardown fits entirely inside that gap. With one
/// atomic the handler's compare-exchange either happens before the owner's swap or after
/// it, and there is no third possibility to reason about.
///
/// Negative values are states and positive values are signal numbers, which is safe
/// because there is no signal 0 (`kill(pid, 0)` is the existence probe, never delivered).
const SLOT_FREE: libc::c_int = 0;
const SLOT_LISTENING: libc::c_int = -1;
const SLOT_FINISHED: libc::c_int = -2;

const SIGNAL_SLOT_COUNT: usize = 64;
static ACTIVE_PROCESS_GROUPS: [AtomicI32; SIGNAL_SLOT_COUNT] =
    [const { AtomicI32::new(0) }; SIGNAL_SLOT_COUNT];
static SIGNAL_SLOTS: [AtomicI32; SIGNAL_SLOT_COUNT] =
    [const { AtomicI32::new(SLOT_FREE) }; SIGNAL_SLOT_COUNT];

/// The signals this process forwards, and what its disposition for each was BEFORE the
/// first ceremony installed anything.
///
/// Kept lock-free and beside the `Mutex`-held copy on purpose: the orderly restore in
/// `finish` can take a lock, and the handler cannot. A handler that must hand a signal
/// back needs the prior disposition immediately and without allocating.
const FORWARDED: [libc::c_int; 3] = [libc::SIGINT, libc::SIGTERM, libc::SIGHUP];
static PRIOR_DISPOSITIONS: [AtomicUsize; 3] = [const { AtomicUsize::new(0) }; 3];

fn forwarded_index(signal: libc::c_int) -> Option<usize> {
    FORWARDED.iter().position(|forwarded| *forwarded == signal)
}

struct HandlerState {
    users: usize,
    previous: Vec<(libc::c_int, libc::sigaction)>,
}

static SIGNAL_HANDLER_STATE: Mutex<HandlerState> = Mutex::new(HandlerState {
    users: 0,
    previous: Vec::new(),
});

/// Record the signal against every ceremony that can answer for it -- and if none can,
/// give it back to the process rather than eating it.
///
/// The compare-exchange is the design. It succeeds only against `SLOT_LISTENING`, so a
/// slot whose owner has already taken the record cannot be written to afterwards; the
/// handler and the teardown cannot both believe they own this signal.
///
/// The hand-back is what makes that safe rather than merely tidy. A handler that consumed
/// a signal it could not record used to be the end of the signal: not reported, not
/// forwarded, not acted on. Restoring the disposition this process had before any ceremony
/// existed and re-raising means the outcome set is exactly two -- some ceremony reports it,
/// or it meets the disposition the operator's own process would have met. `signal` and
/// `raise` are both on POSIX's async-signal-safe list. Note the restored disposition may be
/// `SIG_IGN`, in which case the signal is ignored, which is precisely what would have
/// happened without us; this deliberately does not force `SIG_DFL` and kill a process that
/// was launched under an ignore.
extern "C" fn forward_to_active_group(signal: libc::c_int) {
    let mut answered = false;

    for (slot, state) in SIGNAL_SLOTS.iter().enumerate() {
        let held = match state.compare_exchange(
            SLOT_LISTENING,
            signal,
            Ordering::SeqCst,
            Ordering::SeqCst,
        ) {
            Ok(_) => signal,
            Err(current) => current,
        };
        // Positive means this slot now holds a signal -- either the one just recorded, or
        // one an owner has yet to report. Either way somebody will account for it.
        if held <= 0 {
            continue;
        }
        answered = true;

        let pgid = ACTIVE_PROCESS_GROUPS[slot].load(Ordering::SeqCst);
        if pgid > 0 {
            unsafe {
                libc::killpg(pgid, signal);
            }
        }
    }

    if !answered && let Some(index) = forwarded_index(signal) {
        unsafe {
            libc::signal(signal, PRIOR_DISPOSITIONS[index].load(Ordering::SeqCst));
            libc::raise(signal);
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
    torn_down: bool,
}

impl SignalForwarding {
    pub(crate) fn install() -> io::Result<Self> {
        let mut state = SIGNAL_HANDLER_STATE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // Claiming the slot IS clearing it: one atomic cannot be published as listening
        // and still hold a previous owner's signal, because the same store does both.
        let slot = SIGNAL_SLOTS
            .iter()
            .position(|state| {
                state
                    .compare_exchange(
                        SLOT_FREE,
                        SLOT_LISTENING,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    )
                    .is_ok()
            })
            .ok_or_else(|| io::Error::other("too many simultaneous child process groups"))?;

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
                    SIGNAL_SLOTS[slot].store(SLOT_FREE, Ordering::SeqCst);
                    return Err(error);
                }
                // The handler's copy, readable without a lock. Captured here because
                // this is the only moment the pre-ceremony disposition is knowable.
                if let Some(index) = forwarded_index(signal) {
                    PRIOR_DISPOSITIONS[index].store(old.sa_sigaction, Ordering::SeqCst);
                }
                previous.push((signal, old));
            }
            state.previous = previous;
        }
        state.users += 1;

        Ok(Self {
            slot,
            torn_down: false,
        })
    }

    pub(crate) fn arm(&self, child: &std::process::Child) -> io::Result<()> {
        exited_without_reaping(child)?;
        let pgid = child.id() as libc::pid_t;
        ACTIVE_PROCESS_GROUPS[self.slot].store(pgid, Ordering::Relaxed);
        if let Some(signal) = self.caught() {
            let result = unsafe { libc::killpg(pgid, signal) };
            if result == -1 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }

    pub(crate) fn caught(&self) -> Option<libc::c_int> {
        match SIGNAL_SLOTS[self.slot].load(Ordering::SeqCst) {
            signal if signal > 0 => Some(signal),
            _ => None,
        }
    }

    pub(crate) fn disarm(&self) {
        ACTIVE_PROCESS_GROUPS[self.slot].store(0, Ordering::Relaxed);
    }
}

impl SignalForwarding {
    /// Stop forwarding and report, as ONE step, everything that was ever recorded.
    ///
    /// It is ONE instruction, and that is the entire point. Earlier versions tried to buy
    /// the same guarantee by ordering two atomics -- FINISHED then read, or restore then
    /// FINISHED then read -- and review picked over the order twice, correctly, because no
    /// order can work. A handler already executing on another thread lives between whatever
    /// two instructions are chosen, and teardown fits inside that gap.
    ///
    /// So a signal is either in the value returned here, or the handler's exchange lost to
    /// this swap and it hands the signal back to the process, where it meets the
    /// disposition that was in place before any ceremony existed. There is no third case.
    /// Note the second outcome is not necessarily death: the prior disposition can be
    /// `SIG_IGN`, and then the signal is ignored -- which is exactly what would have
    /// happened had this process never installed a handler at all.
    ///
    /// What that replaces: an interval where a signal was caught by a still-installed
    /// handler, recorded into a slot nobody would read again, and forwarded nowhere. The
    /// caller was then free to bank a credential the operator had interrupted -- the child
    /// had finished, but the ONBOARDING had not.
    fn finish(&mut self) -> Option<libc::c_int> {
        // Strictly once, and the worse of the two failures it prevents is the one no test
        // will show you: `users` is a `usize`, so a second decrement underflows. Debug
        // panics; release wraps to a value that can never reach zero again, and from that
        // moment this process NEVER restores its signal dispositions -- the ceremony's
        // handler stands over the operator's shell for the life of the run.
        //
        // The lesser one, which the test does cover: a second pass stamps FINISHED and
        // then FREE onto a slot another ceremony may already have claimed, wiping ITS
        // record.
        if self.torn_down {
            return None;
        }
        self.torn_down = true;
        self.disarm();

        // ONE instruction ends the run: it stops the recording and takes the record
        // together. Everything after it is bookkeeping.
        //
        // Two earlier versions of this tried to get the same guarantee by ordering two
        // separate atomics, and the order was picked over twice by review -- correctly
        // both times, because no order can work. A handler already running on another
        // thread sits between whatever two instructions are chosen. Here it does not
        // matter where the handler is: its compare-exchange either lands before this swap,
        // in which case the signal is in the value returned, or after it, in which case
        // the swap has already published FINISHED, the exchange fails, and the handler
        // gives the signal back to the process instead of eating it.
        //
        // That is also why the disposition restore below no longer has to be ordered
        // against this. A signal arriving between them finds no slot able to answer and
        // takes its natural course.
        let caught = match SIGNAL_SLOTS[self.slot].swap(SLOT_FINISHED, Ordering::SeqCst) {
            signal if signal > 0 => Some(signal),
            _ => None,
        };

        {
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
        }

        // Released only now. FINISHED held the identity across the read so no successor
        // could claim the slot while its record was still being taken.
        SIGNAL_SLOTS[self.slot].store(SLOT_FREE, Ordering::SeqCst);
        caught
    }
}

impl Drop for SignalForwarding {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

/// Take a descriptor off the blocking path for good.
pub(crate) fn nonblocking(fd: libc::c_int) -> Result<(), String> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error().to_string());
    }
    Ok(())
}

/// A descriptor we did not open, made non-blocking for as long as we hold it.
///
/// The operator's terminal outlives this process, so the flag it arrives with is the flag
/// it leaves with; only the writes this ceremony makes are non-blocking.
pub(crate) struct NonblockingFd {
    fd: libc::c_int,
    flags: libc::c_int,
}

impl NonblockingFd {
    pub(crate) fn new(fd: libc::c_int) -> Result<Self, String> {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1
        {
            return Err(io::Error::last_os_error().to_string());
        }
        Ok(Self { fd, flags })
    }
}

impl Drop for NonblockingFd {
    fn drop(&mut self) {
        unsafe {
            libc::fcntl(self.fd, libc::F_SETFL, self.flags);
        }
    }
}

/// How a supervised run ended other than by the child finishing on its own.
///
/// `Interrupted` is not a flavour of failure: the operator asked for the ceremony to
/// stop, and a caller that banks a credential on the way out of one is doing the thing
/// the interrupt forbade.
#[derive(Debug)]
pub(crate) enum RunError {
    Failed(String),
    Interrupted {
        signal: libc::c_int,
        message: String,
    },
}

impl RunError {
    fn interrupted(signal: libc::c_int, what: &str) -> Self {
        Self::Interrupted {
            signal,
            message: format!("{what} was interrupted by signal {signal}"),
        }
    }

    fn with_cleanup_failure(self, cleanup: String) -> Self {
        match self {
            Self::Failed(message) => {
                Self::Failed(format!("{message}; cleanup also failed: {cleanup}"))
            }
            Self::Interrupted { signal, message } => Self::Interrupted {
                signal,
                message: format!("{message}; cleanup also failed: {cleanup}"),
            },
        }
    }

    pub(crate) fn is_interrupted(&self) -> bool {
        matches!(self, Self::Interrupted { .. })
    }
}

impl From<String> for RunError {
    fn from(message: String) -> Self {
        Self::Failed(message)
    }
}

impl std::fmt::Display for RunError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed(message) | Self::Interrupted { message, .. } => {
                formatter.write_str(message)
            }
        }
    }
}

/// Spawn a child, drive it, and end it — in one place that every exit path goes through.
///
/// The three defects this shape exists to make unrepresentable, each of which was fixed
/// individually twice and came back somewhere else:
///
///   1. A post-spawn setup step that fails with `?` and abandons a live child. There is
///      no `?` between the spawn and [`Supervised::settle`]: everything the caller does
///      after the fork happens inside `drive`, whose error becomes a VALUE that settle
///      terminates on. Arming is inside the funnel for the same reason.
///   2. A late TERM observed just before a normal return and then discarded. Only settle
///      decides a run completed, and it disarms BEFORE it reads the signal for the last
///      time — after that store no signal can reach this group, so the read that follows
///      it is final rather than a sample with a window behind it.
///   3. A blocking write that outlives the lease. Every write a driver makes goes through
///      [`Supervised::write_all`], which is bounded by the same deadline and the same
///      signal as the loop around it.
///
/// `command` must put the child at the head of its own process group -- `setpgid` in a
/// `pre_exec`, or the `setsid` a pty ceremony needs anyway. Ending a ceremony means ending
/// the tree it spawned, and the leader's pid is the only safe handle on that tree.
pub(crate) fn supervise<T>(
    mut command: Command,
    what: &str,
    deadline: Instant,
    drive: impl FnOnce(&mut Supervised) -> Result<T, RunError>,
) -> Result<(T, ExitStatus), RunError> {
    if Instant::now() >= deadline {
        return Err(RunError::Failed(format!(
            "{what} refused to start because its onboarding lease already expired"
        )));
    }

    let forwarding = SignalForwarding::install().map_err(|error| error.to_string())?;
    reset_sigchld_before_spawn();
    let child = command.spawn().map_err(|error| error.to_string())?;
    // The parent's copies of whatever stdio the caller configured close here, before the
    // driver waits for the child's end of them to report EOF.
    drop(command);

    let mut supervised = Supervised {
        child,
        forwarding,
        what: what.to_owned(),
        deadline,
        settled: false,
    };
    let outcome = supervised
        .forwarding
        .arm(&supervised.child)
        .map_err(|error| RunError::Failed(error.to_string()))
        .and_then(|()| drive(&mut supervised));
    supervised.settle(outcome)
}

/// A spawned child and the signal registry entry that owns its group.
pub(crate) struct Supervised {
    child: Child,
    forwarding: SignalForwarding,
    what: String,
    deadline: Instant,
    settled: bool,
}

impl Supervised {
    pub(crate) fn child(&mut self) -> &mut Child {
        &mut self.child
    }

    /// The child leads its own group, so its pid IS the group id. Valid only while the
    /// leader is unreaped, which every caller of this is.
    pub(crate) fn pgid(&self) -> libc::pid_t {
        self.child.id() as libc::pid_t
    }

    pub(crate) fn deadline(&self) -> Instant {
        self.deadline
    }

    pub(crate) fn what(&self) -> &str {
        &self.what
    }

    /// Has the leader exited? Asked without reaping — see [`exited_without_reaping`].
    pub(crate) fn exited(&self) -> Result<bool, RunError> {
        exited_without_reaping(&self.child)
            .map_err(|error| RunError::Failed(format!("wait for {} failed: {error}", self.what)))
    }

    /// The signal an operator sent us, if one has arrived. The handler has already
    /// forwarded it to the group; this is how the driver learns to stop.
    pub(crate) fn interrupted(&self) -> Option<RunError> {
        self.forwarding
            .caught()
            .map(|signal| RunError::interrupted(signal, &self.what))
    }

    pub(crate) fn expired(&self) -> Option<RunError> {
        (Instant::now() >= self.deadline).then(|| self.deadline_failure())
    }

    fn deadline_failure(&self) -> RunError {
        RunError::Failed(format!(
            "{} did not finish before its onboarding lease expired; terminated it and its \
             process group ({})",
            self.what,
            self.pgid()
        ))
    }

    /// Write every byte, or stop — bounded by the lease and by the operator's signal.
    ///
    /// The consumer on the other side of `fd` belongs to somebody else: a terminal
    /// nobody is reading, a pipe whose reader has stalled. A blocking write to it hands
    /// that party control of when this ceremony ends. Waiting on the fd rather than on a
    /// fixed sleep is what keeps the alternative from being a spin, and no byte is
    /// dropped on the way: a short write resumes where it stopped.
    pub(crate) fn write_all(&self, fd: libc::c_int, mut bytes: &[u8]) -> Result<(), RunError> {
        while !bytes.is_empty() {
            if let Some(error) = self.interrupted() {
                return Err(error);
            }
            if let Some(error) = self.expired() {
                return Err(error);
            }

            let count = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
            if count > 0 {
                bytes = &bytes[count as usize..];
                continue;
            }
            if count == 0 {
                return Err(RunError::Failed(format!(
                    "{} could not write to fd {fd}: the write made no progress",
                    self.what
                )));
            }

            let error = io::Error::last_os_error();
            match error.kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::WouldBlock => self.wait(Some(libc::pollfd {
                    fd,
                    events: libc::POLLOUT,
                    revents: 0,
                })),
                _ => return Err(RunError::Failed(error.to_string())),
            }
        }
        Ok(())
    }

    /// Block until the fd is ready, the lease is nearly up, or a signal lands.
    ///
    /// `None` waits on nothing at all, which is how a driver with no fd to watch idles:
    /// unlike a sleep, `poll` returns on EINTR, so a TERM is acted on when it arrives
    /// rather than at the end of the current nap.
    pub(crate) fn wait(&self, watched: Option<libc::pollfd>) {
        let mut polls = watched.into_iter().collect::<Vec<_>>();
        let timeout = self
            .deadline
            .saturating_duration_since(Instant::now())
            .min(Duration::from_millis(50))
            .as_millis() as libc::c_int;
        unsafe {
            libc::poll(polls.as_mut_ptr(), polls.len() as _, timeout);
        }
    }

    /// The ONLY code that ends a supervised child.
    ///
    /// A driver that returns `Ok` is claiming the child finished on its own; everything
    /// else — its own failure, the deadline, a signal — arrives here as an error and is
    /// terminated identically. The success path disarms, reads, reaps, then reads ONCE
    /// MORE. Disarming stops the handler reaching the group but does not uninstall it, so
    /// a single read proves only that no signal had arrived by that instant -- one landing
    /// during the reap would be swallowed. The second read is what makes "no signal" a
    /// statement about the whole run, and it is placed after the reap because the reap is
    /// the only thing between the two that can block.
    fn settle<T>(mut self, outcome: Result<T, RunError>) -> Result<(T, ExitStatus), RunError> {
        let cause = match outcome {
            Ok(value) => {
                self.forwarding.disarm();
                match self.forwarding.caught() {
                    None => {
                        self.settled = true;
                        let status = self.child.wait().map_err(|error| error.to_string())?;
                        // The verdict comes from `finish`, not from a second `caught`.
                        // `disarm` stops the handler reaching the group but leaves it
                        // installed and recording, so a signal landing during the `wait`
                        // above is absorbed by this process and forwarded to nothing. A
                        // plain read here would be one more sample with an interval behind
                        // it; `finish` instead stops the recording and reports what was
                        // recorded as one step, so "no signal" becomes a statement about
                        // the whole run rather than about the instant it was asked.
                        //
                        // This was first declined as a post-completion instant not worth
                        // buying. That pricing was wrong: only the CHILD is done here.
                        // `onboard` goes on to validate, stage and finish, so an interrupt
                        // dropped at this point is followed by banking the very credential
                        // the operator tried to stop.
                        return match self.forwarding.finish() {
                            None => Ok((value, status)),
                            Some(signal) => Err(RunError::interrupted(signal, &self.what)),
                        };
                    }
                    Some(signal) => RunError::interrupted(signal, &self.what),
                }
            }
            Err(cause) => cause,
        };

        self.settled = true;
        match terminate_process_group(&mut self.child, Duration::from_secs(2)) {
            Ok(()) => {
                self.forwarding.disarm();
                match self.child.wait() {
                    Ok(_) => Err(cause),
                    Err(error) => Err(cause
                        .with_cleanup_failure(format!("could not reap {}: {error}", self.what))),
                }
            }
            Err(error) => {
                self.forwarding.disarm();
                // Reap ONLY an already-exited leader. The commonest way to arrive here is
                // an ESRCH from the first killpg -- the leader had already exited and its
                // group is empty -- leaving a zombie that holds its pid, and the pid IS the
                // group id, so that identity stays occupied for the life of the process.
                // But the other way to arrive here is a child we just FAILED to stop, and
                // an unconditional wait on that one blocks forever: it turns a reported
                // cleanup failure into a hang. The exit check is what separates them.
                // `unwrap_or(false)` is safe here only because the probe now retries
                // EINTR itself. That was the reachable hole: an exited leader gives
                // killpg ESRCH, a caught signal interrupts the probe, the error reads as
                // "still running", the reap is skipped, and `settled` is already true so
                // Drop offers no second chance. What remains is ECHILD and EINVAL, where
                // there is either nothing left to reap or nothing we could reap, and
                // `false` is the answer rather than a guess.
                if exited_without_reaping(&self.child).unwrap_or(false) {
                    let _ = self.child.wait();
                }
                Err(cause.with_cleanup_failure(format!(
                    "could not terminate {}: {error}; process group left unsignalled",
                    self.what
                )))
            }
        }
    }
}

/// The backstop for the one exit `settle` cannot be on: an unwinding panic in a driver.
impl Drop for Supervised {
    fn drop(&mut self) {
        if self.settled {
            return;
        }
        let terminated = terminate_process_group(&mut self.child, Duration::from_secs(2));
        self.forwarding.disarm();
        if terminated.is_ok() {
            let _ = self.child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;
    use std::process::Stdio;

    /// Run `body` in a test process of its own, and answer whether it passed.
    ///
    /// `forward_to_active_group` is the only way to exercise the handler deterministically,
    /// and it fires at EVERY armed slot -- including the groups of whatever other tests are
    /// running in parallel. Isolation is what keeps a signal regression from terminating
    /// its neighbours.
    fn alone(test: &str) -> bool {
        let variable = format!("TIGHTBEAM_ISOLATED_{}", test.to_ascii_uppercase());
        if std::env::var_os(&variable).is_some() {
            return true;
        }
        let status = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                &format!("child_process::tests::{test}"),
                "--nocapture",
            ])
            .env(&variable, "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "isolated regression {test} failed");
        false
    }

    #[test]
    fn a_signal_caught_before_arming_is_forwarded_when_the_group_becomes_known() {
        if !alone("a_signal_caught_before_arming_is_forwarded_when_the_group_becomes_known") {
            return;
        }

        let forwarding = SignalForwarding::install().unwrap();

        // Exercise the handler deterministically without delivering TERM to the cargo
        // test process. Before the fix this call saw no active pgid and discarded TERM.
        forward_to_active_group(libc::SIGTERM);
        assert_eq!(forwarding.caught(), Some(libc::SIGTERM));

        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "while :; do sleep 1; done"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        reset_sigchld_before_spawn();
        let mut child = command.spawn().unwrap();
        forwarding.arm(&child).unwrap();

        let deadline = Instant::now() + Duration::from_secs(2);
        while !exited_without_reaping(&child).unwrap() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(
            exited_without_reaping(&child).unwrap(),
            "the early TERM was recorded but never delivered after arming"
        );
        forwarding.disarm();
        child.wait().unwrap();
    }

    /// The window a TERM used to vanish into: it lands after the loop's last look at the
    /// signal and before the run is called a success.
    ///
    /// What made it worth a regression rather than a shrug is what the caller does next.
    /// The ceremony above this reads a year-long credential out of a successful run and
    /// banks it -- so a discarded TERM does not merely lose an exit code, it completes an
    /// operation the operator interrupted.
    #[test]
    fn a_term_arriving_as_the_child_finishes_is_not_reported_as_success() {
        if !alone("a_term_arriving_as_the_child_finishes_is_not_reported_as_success") {
            return;
        }

        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "exit 0"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let error = supervise(
            command,
            "a finishing ceremony",
            Instant::now() + Duration::from_secs(5),
            |supervised| {
                while !supervised.exited()? {
                    thread::sleep(Duration::from_millis(10));
                }
                // The child is done and the driver is one statement away from saying so.
                forward_to_active_group(libc::SIGTERM);
                Ok(())
            },
        )
        .unwrap_err();

        assert!(
            error.is_interrupted(),
            "a run interrupted at the finish reported: {error}"
        );
        assert!(
            error.to_string().contains("a finishing ceremony"),
            "{error}"
        );
    }

    /// The window the test above does NOT cover: a signal landing during the reap.
    ///
    /// That test fires before the driver returns, so it is caught by settle's FIRST read
    /// and passed even while the defect was live. This one fires after that read, while
    /// `wait` is blocking -- where `disarm` has already stopped the signal reaching the
    /// group, so nothing kills the child and nothing re-reads the record. The interrupt
    /// simply ceased to exist, and the run it was trying to stop reported success.
    ///
    /// The driver returns before the child does, which is what makes the reap slow enough
    /// to aim at: a already-exited child is reaped instantly and there is no window to hit.
    ///
    /// The child outlives the shot by a wide margin ON PURPOSE. If the signal lands after
    /// the child has already exited, this test passes for the wrong reason -- a false PASS,
    /// not a flake, which is the worse failure because it is silent. eezo runs near load 44
    /// with parallel lanes going, so a scheduler delay of a second is ordinary; five seconds
    /// of headroom in a test that already re-execs in isolation costs nothing worth having.
    #[test]
    fn a_term_arriving_during_the_reap_is_not_reported_as_success() {
        if !alone("a_term_arriving_during_the_reap_is_not_reported_as_success") {
            return;
        }

        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "sleep 5"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let error = supervise(
            command,
            "a ceremony being reaped",
            Instant::now() + Duration::from_secs(10),
            |_supervised| {
                // Fired from a thread because the driver has to RETURN for the reap to
                // start; 250ms into a child that lives five seconds lands inside `wait`
                // with margin no plausible scheduler delay on a loaded box eats.
                thread::spawn(|| {
                    thread::sleep(Duration::from_millis(250));
                    forward_to_active_group(libc::SIGTERM);
                });
                Ok(())
            },
        )
        .unwrap_err();

        assert!(
            error.is_interrupted(),
            "a TERM landing during the reap reported: {error}"
        );
    }

    /// The mechanism that closes the teardown residual, tested where it is reachable.
    ///
    /// Be honest about what this can and cannot do. The integration-level instant -- a
    /// signal landing between `settle`'s last look and the handler being uninstalled -- is
    /// a few instructions inside `settle` with no seam a test can aim at, and a test that
    /// fired earlier would pass against BOTH designs while appearing to prove one. (One
    /// did, before this replaced it.) So this tests the property the fix actually rests
    /// on: `finish` stops the slot listening and reports what was recorded as one step,
    /// and is safe against being run twice.
    ///
    /// Why that is the whole of it: after `finish` returns, this slot records nothing more
    /// under our identity, and the process's own dispositions are back, so a later signal
    /// terminates us instead of being swallowed. Recorded-and-reported, or fatal. There is
    /// Teardown reports what it recorded, releases the slot, and cannot reach back into it.
    #[test]
    fn finishing_forwarding_reports_what_it_recorded_and_then_records_nothing() {
        if !alone("finishing_forwarding_reports_what_it_recorded_and_then_records_nothing") {
            return;
        }

        let mut forwarding = SignalForwarding::install().unwrap();
        let slot = forwarding.slot;

        SIGNAL_SLOTS[slot].store(libc::SIGTERM, Ordering::SeqCst);
        assert_eq!(
            forwarding.finish(),
            Some(libc::SIGTERM),
            "teardown dropped a signal that was recorded while it was listening"
        );
        assert_eq!(
            SIGNAL_SLOTS[slot].load(Ordering::SeqCst),
            SLOT_FREE,
            "a finished slot must be released for reuse"
        );

        // Claiming a slot must clear it -- the round 3 defect, where the record was
        // cleared AFTER the slot was published as listening. Stated plainly: with one
        // atomic this assertion CANNOT fail, because the claim and the clear are the same
        // store. It is here as a guard against a future refactor splitting them apart
        // again, not as a test of the current logic, and it should be read that way rather
        // than counted as evidence the current code was checked.
        let successor = SignalForwarding::install().unwrap();
        assert_eq!(
            successor.slot, slot,
            "the released slot must be the one reissued, or this proves nothing"
        );
        assert_eq!(
            successor.caught(),
            None,
            "a claimed slot still held its predecessor's signal"
        );

        // The handler now answers for the successor, and only the successor.
        forward_to_active_group(libc::SIGINT);
        assert_eq!(successor.caught(), Some(libc::SIGINT));

        // Run the departed owner's teardown again: `Drop` does exactly this after `settle`
        // already has. The claim is that it must not disturb whoever holds the slot NOW,
        // so the successor has to exist for the assertion to mean anything.
        assert_eq!(
            forwarding.finish(),
            None,
            "teardown ran twice and reported a signal the second time"
        );
        assert_eq!(
            successor.caught(),
            Some(libc::SIGINT),
            "a stale teardown wiped the record of the ceremony now holding its slot"
        );
    }

    static HANDED_BACK: AtomicI32 = AtomicI32::new(0);

    extern "C" fn record_hand_back(signal: libc::c_int) {
        HANDED_BACK.store(signal, Ordering::SeqCst);
    }

    /// A signal no ceremony can answer for is handed back, not eaten.
    ///
    /// This is the half of the design that makes the compare-exchange safe rather than
    /// merely narrow. When a handler already executing on another thread loses the race to
    /// teardown, its exchange fails and it holds a signal it cannot record. Before the hand
    /// back that was the end of it: not reported, not forwarded, not acted on -- the
    /// operator's interrupt ceased to exist and onboarding banked the credential it was
    /// meant to stop.
    ///
    /// No barrier is needed to observe it. The state an in-flight handler LOSES the race
    /// into is just "the slot no longer answers", which teardown reaches on its own, so the
    /// property is reachable deterministically by finishing first and calling the handler
    /// after. The prior disposition is set to a recording handler because the real one is
    /// `SIG_DFL`, and a correct hand-back would then kill the test -- which is the point,
    /// and unobservable.
    #[test]
    fn a_signal_no_ceremony_can_answer_for_is_handed_back_not_eaten() {
        if !alone("a_signal_no_ceremony_can_answer_for_is_handed_back_not_eaten") {
            return;
        }

        HANDED_BACK.store(0, Ordering::SeqCst);
        let mut prior: libc::sigaction = unsafe { std::mem::zeroed() };
        prior.sa_sigaction = record_hand_back as *const () as usize;
        unsafe {
            libc::sigemptyset(&mut prior.sa_mask);
            libc::sigaction(libc::SIGTERM, &prior, std::ptr::null_mut());
        }

        let mut forwarding = SignalForwarding::install().unwrap();
        // The ceremony is over. This is exactly the state a descheduled handler wakes up
        // into when teardown got there first.
        forwarding.finish();

        forward_to_active_group(libc::SIGTERM);

        assert_eq!(
            HANDED_BACK.load(Ordering::SeqCst),
            libc::SIGTERM,
            "a signal no slot could answer for was swallowed instead of handed back"
        );
    }

    /// What the process's own SIGTERM disposition is right now.
    fn installed_handler(signal: libc::c_int) -> usize {
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        assert_eq!(
            unsafe { libc::sigaction(signal, std::ptr::null(), &mut action) },
            0
        );
        action.sa_sigaction
    }

    /// Teardown hands the process's signals back, and does it before it stops listening.
    ///
    /// The ORDER is not directly observable -- the difference between restoring before and
    /// after the slot leaves LISTENING is an interval between two statements, and a test
    /// that claimed to aim at it would be decoration. What IS observable is that the
    /// restore happens at all, and this pins it, because the reorder that put it in the
    /// right place also made it the easiest thing in the file to lose silently: nothing
    /// else fails if a ceremony leaves its own handler installed over the operator's
    /// process for the rest of its life.
    #[test]
    fn the_last_teardown_gives_the_process_its_dispositions_back() {
        if !alone("the_last_teardown_gives_the_process_its_dispositions_back") {
            return;
        }

        let ours = forward_to_active_group as *const () as usize;
        let before = installed_handler(libc::SIGTERM);
        assert_ne!(before, ours, "a previous test left the ceremony handler behind");

        let mut forwarding = SignalForwarding::install().unwrap();
        assert_eq!(
            installed_handler(libc::SIGTERM),
            ours,
            "install did not take SIGTERM, so this test would prove nothing"
        );

        forwarding.finish();
        assert_eq!(
            installed_handler(libc::SIGTERM),
            before,
            "teardown left the ceremony's handler standing over the operator's process"
        );
    }

    /// A setup step that fails after the fork -- the flag on a descriptor, the pipe the
    /// key goes down -- used to `?` its way out and leave the child running against a
    /// ceremony nobody was watching any more.
    ///
    /// The driver here waits for the child to record its own identity before failing, so
    /// the assertion below names a process that certainly existed. That wait is also why
    /// this cannot pass by accident: a child killed before it ever ran would leave no
    /// marker to check.
    #[test]
    fn a_post_spawn_setup_failure_leaves_no_running_child() {
        let marker = std::env::temp_dir().join(format!(
            "tightbeam-post-spawn-failure-{}-{:?}",
            std::process::id(),
            thread::current().id()
        ));
        let _ = std::fs::remove_file(&marker);

        let mut command = Command::new("/bin/sh");
        command
            .args([
                "-c",
                &format!(
                    "printf '%s' \"$$\" > '{}'; while :; do sleep 1; done",
                    marker.display()
                ),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }

        let deadline = Instant::now() + Duration::from_secs(10);
        let error = supervise(
            command,
            "a stub ceremony",
            deadline,
            |_| -> Result<(), RunError> {
                while std::fs::read_to_string(&marker)
                    .unwrap_or_default()
                    .is_empty()
                {
                    assert!(Instant::now() < deadline, "the stub never recorded its pid");
                    thread::sleep(Duration::from_millis(10));
                }
                Err(RunError::Failed(
                    "a post-spawn setup step failed".to_owned(),
                ))
            },
        )
        .unwrap_err();

        assert!(error.to_string().contains("a post-spawn setup step failed"));
        assert!(!error.to_string().contains("cleanup"), "{error}");

        let child = std::fs::read_to_string(&marker).unwrap_or_default();
        let _ = std::fs::remove_file(&marker);
        // Absence from the process table, not elapsed time -- the same reason as the
        // watchdog's grandchild check.
        let listed = Command::new("ps")
            .args(["-o", "pid=", "-p", child.trim()])
            .output()
            .expect("ps must run, or this test learned nothing");
        assert!(
            String::from_utf8_lossy(&listed.stdout).trim().is_empty(),
            "the abandoned child {child} is still running"
        );
    }
}
