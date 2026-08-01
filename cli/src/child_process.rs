use std::io;

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
