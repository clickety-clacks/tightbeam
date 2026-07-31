use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Instant;

const MAX_ABANDONED_WORKERS: usize = 1;

static ABANDONED_WORKERS: AbandonmentLimiter = AbandonmentLimiter::new(MAX_ABANDONED_WORKERS);

struct AbandonmentLimiter {
    active: AtomicUsize,
    limit: usize,
}

impl AbandonmentLimiter {
    const fn new(limit: usize) -> Self {
        Self {
            active: AtomicUsize::new(0),
            limit,
        }
    }

    fn reserve(&self) -> bool {
        self.active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < self.limit).then_some(active + 1)
            })
            .is_ok()
    }

    fn release(&self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Default)]
struct WorkerState {
    finished: bool,
    abandoned: bool,
}

struct WorkerCompletion {
    state: Arc<Mutex<WorkerState>>,
    limiter: &'static AbandonmentLimiter,
}

impl Drop for WorkerCompletion {
    fn drop(&mut self) {
        let mut state = self.state.lock().expect("lease worker state poisoned");
        state.finished = true;
        if state.abandoned {
            self.limiter.release();
        }
    }
}

/// Wait for one synchronous operation until the gateway's absolute lease deadline.
///
/// Rust threads cannot be interrupted. At the deadline this may therefore abandon
/// the caller's wait, not the work: one process-wide worker may remain detached.
/// If that slot is already occupied, this waiter joins its worker and can outlive
/// the lease rather than accumulating another stuck thread. ureq 2.12.1's DNS
/// lookup has no timeout, so that one detached worker can remain indefinitely;
/// terminating it would require a killable child-process boundary.
pub(crate) fn until<T, F>(deadline: Instant, work: F) -> Result<T, ()>
where
    T: Send + 'static,
    F: FnOnce(std::time::Duration) -> T + Send + 'static,
{
    until_with_limiter(deadline, work, &ABANDONED_WORKERS)
}

fn until_with_limiter<T, F>(
    deadline: Instant,
    work: F,
    limiter: &'static AbandonmentLimiter,
) -> Result<T, ()>
where
    T: Send + 'static,
    F: FnOnce(std::time::Duration) -> T + Send + 'static,
{
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(());
    }

    let (sender, receiver) = mpsc::sync_channel(1);
    let state = Arc::new(Mutex::new(WorkerState::default()));
    let worker_state = Arc::clone(&state);
    let worker = thread::spawn(move || {
        let _completion = WorkerCompletion {
            state: worker_state,
            limiter,
        };
        let _ = sender.send(work(remaining));
    });

    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return finish_at_deadline(worker, state, limiter);
    }

    match receiver.recv_timeout(remaining) {
        Ok(result) => {
            worker
                .join()
                .expect("lease-bounded worker panicked after returning its result");
            if Instant::now() < deadline {
                Ok(result)
            } else {
                Err(())
            }
        }
        Err(mpsc::RecvTimeoutError::Timeout) => finish_at_deadline(worker, state, limiter),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            let _ = worker.join();
            panic!("lease-bounded worker exited without returning its result")
        }
    }
}

fn finish_at_deadline<T>(
    worker: thread::JoinHandle<()>,
    state: Arc<Mutex<WorkerState>>,
    limiter: &'static AbandonmentLimiter,
) -> Result<T, ()> {
    let mut state = state.lock().expect("lease worker state poisoned");
    if !state.finished && limiter.reserve() {
        state.abandoned = true;
        return Err(());
    }
    drop(state);

    worker
        .join()
        .expect("lease-bounded worker panicked after its deadline");
    Err(())
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

    #[test]
    fn a_second_expired_worker_is_joined_instead_of_detached() {
        static LIMITER: AbandonmentLimiter = AbandonmentLimiter::new(1);

        let (release_first, first_released) = mpsc::channel();
        let first = until_with_limiter(
            Instant::now() + Duration::from_millis(20),
            move |_| first_released.recv().unwrap(),
            &LIMITER,
        );
        assert!(first.is_err());

        let (release_second, second_released) = mpsc::channel();
        let (returned, return_seen) = mpsc::channel();
        let second = thread::spawn(move || {
            let result = until_with_limiter(
                Instant::now() + Duration::from_millis(20),
                move |_| second_released.recv().unwrap(),
                &LIMITER,
            );
            returned.send(result).unwrap();
        });

        thread::sleep(Duration::from_millis(60));
        assert!(
            return_seen.try_recv().is_err(),
            "the second worker was detached after the abandonment slot was occupied"
        );
        release_second.send(()).unwrap();
        assert!(return_seen.recv().unwrap().is_err());
        second.join().unwrap();
        release_first.send(()).unwrap();
    }
}
