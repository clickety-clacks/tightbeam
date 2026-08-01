use std::sync::mpsc;
use std::thread;
use std::time::Instant;

/// Run one synchronous operation behind the gateway's absolute lease deadline.
///
/// ureq 2.12.1 applies connect timeouts per connection, so redirects can spend a
/// fresh relative allowance. Its synchronous DNS lookup is not interruptible at
/// all. The caller therefore waits on the whole exchange only until the absolute
/// deadline; a DNS lookup already running may finish in this detached worker
/// afterward. Terminating the lookup itself would require the narrower hard
/// isolation boundary of a child process that can be killed at the deadline.
///
/// Ceremony calls are serial and share one absolute deadline. If a worker reaches
/// that deadline, its caller returns the ceremony failure; another call in that
/// ceremony cannot start with time remaining. Concurrent CLI invocations live in
/// separate processes, where an in-process abandonment counter could not coordinate
/// them. A process-wide limiter therefore cannot guard a reachable second worker.
pub(crate) fn until<T, F>(deadline: Instant, work: F) -> Result<T, ()>
where
    T: Send + 'static,
    F: FnOnce(std::time::Duration) -> T + Send + 'static,
{
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(());
    }

    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let _ = sender.send(work(remaining));
    });

    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(());
    }

    match receiver.recv_timeout(remaining) {
        Ok(result) if Instant::now() < deadline => Ok(result),
        Ok(_) | Err(mpsc::RecvTimeoutError::Timeout) => Err(()),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            panic!("lease-bounded worker exited without returning its result")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn an_absolute_deadline_bounds_multi_phase_relative_work() {
        let deadline = Instant::now() + Duration::from_millis(70);
        let result = until(deadline, move |relative_allowance| {
            for _ in 0..3 {
                assert!(!relative_allowance.is_zero());
                thread::sleep(Duration::from_millis(40));
            }
            "finished"
        });

        assert!(
            result.is_err(),
            "fresh per-phase allowances crossed the absolute deadline"
        );
    }
}
