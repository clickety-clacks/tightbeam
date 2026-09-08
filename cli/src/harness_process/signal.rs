//! Signal delivery holds a kernel process identity, never a reusable PID/PGID operand.

use super::{
    ProcessAuthority, ProcessInstance, ProcessSignalResult, process_read_target_gone,
    process_signal_target_gone, verify_process_instance,
};
use std::io;

pub(super) struct BoundProcess {
    pub(super) instance: ProcessInstance,
    handle: platform::Handle,
}

impl BoundProcess {
    pub(super) fn capture(instance: ProcessInstance) -> Result<Option<Self>, String> {
        // Acquire first, validate second, and retain the capability through delivery.
        let handle = match platform::Handle::open(&instance) {
            Ok(handle) => handle,
            Err(error) if process_read_target_gone(&error) => return Ok(None),
            Err(error) => {
                return Err(format!(
                    "process {} identity-bound signal capability unavailable: {error}",
                    instance.pid
                ));
            }
        };
        if verify_process_instance(&instance)? == ProcessAuthority::Gone {
            return Ok(None);
        }
        if !handle.alive().map_err(|error| {
            format!(
                "process {} capability state unreadable: {error}",
                instance.pid
            )
        })? {
            return Ok(None);
        }
        Ok(Some(Self { instance, handle }))
    }

    pub(super) fn alive(&self) -> Result<bool, String> {
        self.handle.alive().map_err(|error| {
            format!(
                "process {} capability state unreadable: {error}",
                self.instance.pid
            )
        })
    }

    pub(super) fn signal(&self, signal: libc::c_int) -> Result<ProcessSignalResult, String> {
        if verify_process_instance(&self.instance)? == ProcessAuthority::Gone {
            return Ok(ProcessSignalResult::Gone);
        }
        #[cfg(test)]
        SIGNAL_BOUNDARY.with(|hook| {
            if let Some(hook) = hook.take() {
                hook();
            }
        });

        // No PID is supplied here. Even a reap after the validation above cannot redirect
        // this operation: the descriptor/token still names the captured process.
        self.deliver(signal)
    }

    fn deliver(&self, signal: libc::c_int) -> Result<ProcessSignalResult, String> {
        #[cfg(test)]
        super::PROCESS_SIGNAL_CALLS.with(|calls| calls.set(calls.get() + 1));
        match self.handle.send(signal) {
            Ok(()) => Ok(ProcessSignalResult::Delivered),
            Err(error) if process_signal_target_gone(&error) => {
                // On Darwin exec invalidates an audit token too. It must not turn a
                // surviving process into a successful disappearance receipt.
                if self.handle.changed_image()? {
                    return Err(format!(
                        "process {} changed executable identity during cleanup",
                        self.instance.pid
                    ));
                }
                Ok(ProcessSignalResult::Gone)
            }
            Err(error) => Ok(ProcessSignalResult::Failed(error)),
        }
    }
}

#[cfg(test)]
thread_local! {
    pub(super) static SIGNAL_BOUNDARY: std::cell::RefCell<Option<Box<dyn FnOnce()>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    pub(super) struct Handle(OwnedFd);

    impl Handle {
        pub(super) fn open(instance: &ProcessInstance) -> io::Result<Self> {
            let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, instance.pid, 0) };
            if fd == -1 {
                Err(io::Error::last_os_error())
            } else {
                Ok(Self(unsafe { OwnedFd::from_raw_fd(fd as libc::c_int) }))
            }
        }

        pub(super) fn send(&self, signal: libc::c_int) -> io::Result<()> {
            let result = unsafe {
                libc::syscall(
                    libc::SYS_pidfd_send_signal,
                    self.0.as_raw_fd(),
                    signal,
                    std::ptr::null::<libc::siginfo_t>(),
                    0,
                )
            };
            if result == -1 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        }

        pub(super) fn changed_image(&self) -> Result<bool, String> {
            Ok(false) // pidfds survive exec; ESRCH means this process has exited.
        }

        pub(super) fn alive(&self) -> io::Result<bool> {
            let mut poll = libc::pollfd {
                fd: self.0.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            if unsafe { libc::poll(&mut poll, 1, 0) } == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(poll.revents == 0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::process_tree::read_process;
    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command, Stdio};

    struct OwnedChild(Child);
    impl OwnedChild {
        fn spawn() -> Self {
            Self(
                Command::new("/bin/sleep")
                    .arg("30")
                    .process_group(0)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            )
        }
        fn capture(&self) -> BoundProcess {
            let process = read_process(self.0.id() as libc::pid_t).unwrap();
            BoundProcess::capture(ProcessInstance {
                pid: process.pid,
                pgid: process.pgid,
                start_time: process.start_time,
            })
            .unwrap()
            .unwrap()
        }
    }
    impl Drop for OwnedChild {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[test]
    fn reap_between_validation_and_delivery_cannot_signal_another_process() {
        let mut original = OwnedChild::spawn();
        let captured = original.capture();
        let mut unrelated = OwnedChild::spawn();
        SIGNAL_BOUNDARY.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move || {
                original.0.kill().unwrap();
                original.0.wait().unwrap();
            }))
        });
        super::super::PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
        assert!(matches!(
            captured.signal(libc::SIGKILL),
            Ok(ProcessSignalResult::Gone)
        ));
        super::super::PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 1));
        assert!(
            unrelated.0.try_wait().unwrap().is_none(),
            "unrelated process was signalled"
        );
    }

    #[test]
    fn reused_pid_and_pgid_metadata_cannot_redirect_the_retained_capability() {
        let mut original = OwnedChild::spawn();
        let mut captured = original.capture();
        original.0.kill().unwrap();
        original.0.wait().unwrap();
        let mut replacement = OwnedChild::spawn();
        let replacement_identity = replacement.capture();
        // Deterministically put a live replacement in both numeric lookup slots after
        // capability acquisition. This is stronger than a stale-token precheck: validation
        // succeeds, yet the real kernel delivery must still use the reaped original.
        captured.instance = replacement_identity.instance;
        super::super::PROCESS_SIGNAL_CALLS.with(|calls| calls.set(0));
        assert!(matches!(
            captured.signal(libc::SIGKILL),
            Ok(ProcessSignalResult::Gone)
        ));
        super::super::PROCESS_SIGNAL_CALLS.with(|calls| assert_eq!(calls.get(), 1));
        assert!(
            replacement.0.try_wait().unwrap().is_none(),
            "reused numeric target was killed"
        );
        assert!(
            !read_process(replacement.0.id() as libc::pid_t)
                .unwrap()
                .stopped
        );
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use crate::process_tree::read_process;
    use std::sync::OnceLock;

    type Signal = unsafe extern "C" fn(*mut [u32; 8], libc::c_int) -> libc::c_int;
    #[link(name = "proc")]
    unsafe extern "C" {}

    pub(super) struct Handle {
        token: [u32; 8],
        unique_id: u64,
        signal: Signal,
    }

    impl Handle {
        pub(super) fn open(instance: &ProcessInstance) -> io::Result<Self> {
            static API: OnceLock<Option<Signal>> = OnceLock::new();
            let signal = API.get_or_init(|| {
                let symbol = unsafe {
                    libc::dlsym(libc::RTLD_DEFAULT, c"proc_signal_with_audittoken".as_ptr())
                };
                if symbol.is_null() {
                    None
                } else {
                    Some(unsafe { std::mem::transmute::<*mut libc::c_void, Signal>(symbol) })
                }
            });
            let signal = signal.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::Unsupported,
                    "proc_signal_with_audittoken unavailable",
                )
            })?;
            // This single kernel read binds the version to the BSD start/group metadata.
            let process = read_process(instance.pid)?;
            if process.start_time != instance.start_time || process.pgid != instance.pgid {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "captured process instance changed",
                ));
            }
            let mut token = [0; 8];
            token[5] = instance.pid as u32;
            token[7] = process.id_version;
            Ok(Self {
                token,
                unique_id: process.unique_id,
                signal,
            })
        }

        pub(super) fn send(&self, signal: libc::c_int) -> io::Result<()> {
            let mut token = self.token;
            // libproc returns the errno value directly, unlike kill()/syscall().
            let error = unsafe { (self.signal)(&mut token, signal) };
            if error == 0 {
                Ok(())
            } else {
                Err(io::Error::from_raw_os_error(error))
            }
        }

        pub(super) fn changed_image(&self) -> Result<bool, String> {
            match read_process(self.token[5] as libc::pid_t) {
                Ok(process) => Ok(process.unique_id == self.unique_id && !process.zombie),
                Err(error) if process_read_target_gone(&error) => Ok(false),
                Err(error) => Err(format!(
                    "audit-token target state unreadable after ESRCH: {error}"
                )),
            }
        }

        pub(super) fn alive(&self) -> io::Result<bool> {
            match read_process(self.token[5] as libc::pid_t) {
                Ok(process) if process.unique_id == self.unique_id && !process.zombie => {
                    if process.id_version != self.token[7] {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "process changed executable identity during capture",
                        ));
                    }
                    Ok(true)
                }
                Ok(_) => Ok(false),
                Err(error) if process_read_target_gone(&error) => Ok(false),
                Err(error) => Err(error),
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod platform {
    use super::*;
    pub(super) struct Handle;
    impl Handle {
        pub(super) fn open(_: &ProcessInstance) -> io::Result<Self> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "identity-bound signals require Linux or macOS",
            ))
        }
        pub(super) fn send(&self, _: libc::c_int) -> io::Result<()> {
            unreachable!()
        }
        pub(super) fn changed_image(&self) -> Result<bool, String> {
            unreachable!()
        }
        pub(super) fn alive(&self) -> io::Result<bool> {
            unreachable!()
        }
    }
}
