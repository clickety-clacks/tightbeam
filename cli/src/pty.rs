//! Direct pseudo-terminal ownership for interactive provider ceremonies.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use crate::child_process::{
    SignalForwarding, exited_without_reaping, reset_sigchld_before_spawn, terminate_process_group,
};

/// The current provider token's observed width. At 109 columns it arrives whole and its
/// repaint reaches the row edge, so an older frame cannot leave a suffix beside it. This
/// is presentation geometry, not a capture rule: screen reconstruction still handles a
/// future token that wraps, and provider shape plus live validation decide the bytes.
pub(crate) const CEREMONY_COLUMNS: libc::c_ushort = 109;
pub(crate) const CEREMONY_ROWS: libc::c_ushort = 50;

#[derive(Debug)]
pub(crate) struct Output {
    pub(crate) status: ExitStatus,
    pub(crate) transcript: Vec<u8>,
}

pub(crate) fn run(command: Command, what: &str, deadline: Instant) -> Result<Output, String> {
    run_with_fds(
        command,
        what,
        deadline,
        libc::STDIN_FILENO,
        libc::STDOUT_FILENO,
    )
}

fn run_with_fds(
    mut command: Command,
    what: &str,
    deadline: Instant,
    input_fd: libc::c_int,
    output_fd: libc::c_int,
) -> Result<Output, String> {
    if Instant::now() >= deadline {
        return Err(format!(
            "{what} refused to start because its onboarding lease already expired"
        ));
    }

    let forwarding = SignalForwarding::install().map_err(|error| error.to_string())?;
    let (master, slave) = open_pty()?;
    configure_command(&mut command, &slave)?;

    reset_sigchld_before_spawn();
    let mut child = command.spawn().map_err(|error| error.to_string())?;
    drop(slave);
    forwarding.arm(&child).map_err(|error| error.to_string())?;
    if let Err(error) = nonblocking(master.as_raw_fd()) {
        return abort_group(&mut child, what, &forwarding, error);
    }

    let mut transcript = Vec::new();
    let mut pending_input = Vec::new();
    let mut input_eof = false;
    let mut sent_eof = false;
    let mut master_eof = false;
    let mut printed_url = None;
    let mut secret_screen = false;

    loop {
        let leader_exited = exited_without_reaping(&child).map_err(|error| {
            format!("wait for {what} failed: {error}; process group left unsignalled")
        })?;

        if leader_exited && master_eof {
            forwarding.disarm();
            let status = child.wait().map_err(|error| error.to_string())?;
            return Ok(Output { status, transcript });
        }

        if let Some(signal) = forwarding.caught() {
            terminate_group(&mut child, what, &forwarding)?;
            return Err(format!(
                "{what} was interrupted by signal {signal}; terminated it and its process group"
            ));
        }

        if Instant::now() >= deadline {
            terminate_group(&mut child, what, &forwarding)?;
            return Err(format!(
                "{what} did not finish before its onboarding lease expired; terminated it and \
                 its process group ({})",
                child.id()
            ));
        }

        if input_eof && !sent_eof && pending_input.is_empty() && !master_eof {
            pending_input.push(0x04);
            sent_eof = true;
        }

        let mut polls = [
            libc::pollfd {
                fd: master.as_raw_fd(),
                events: if pending_input.is_empty() {
                    libc::POLLIN
                } else {
                    libc::POLLIN | libc::POLLOUT
                },
                revents: 0,
            },
            libc::pollfd {
                fd: input_fd,
                events: if input_eof { 0 } else { libc::POLLIN },
                revents: 0,
            },
        ];
        let timeout_ms = deadline
            .saturating_duration_since(Instant::now())
            .min(Duration::from_millis(50))
            .as_millis() as libc::c_int;
        let polled = unsafe { libc::poll(polls.as_mut_ptr(), polls.len() as _, timeout_ms) };
        if polled == -1 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return abort_group(&mut child, what, &forwarding, error.to_string());
            }
            continue;
        }

        if !input_eof && polls[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let mut input = [0u8; 4096];
            let count = unsafe { libc::read(input_fd, input.as_mut_ptr().cast(), input.len()) };
            if count > 0 {
                pending_input.extend_from_slice(&input[..count as usize]);
            } else if count == 0 {
                input_eof = true;
            } else {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return abort_group(&mut child, what, &forwarding, error.to_string());
                }
            }
        }

        if !pending_input.is_empty() && polls[0].revents & libc::POLLOUT != 0 {
            let count = unsafe {
                libc::write(
                    master.as_raw_fd(),
                    pending_input.as_ptr().cast(),
                    pending_input.len(),
                )
            };
            if count > 0 {
                pending_input.drain(..count as usize);
            } else if count == -1 {
                let error = io::Error::last_os_error();
                if !matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) {
                    return abort_group(&mut child, what, &forwarding, error.to_string());
                }
            }
        }

        if !master_eof && polls[0].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let mut output = [0u8; 8192];
            let count =
                unsafe { libc::read(master.as_raw_fd(), output.as_mut_ptr().cast(), output.len()) };
            if count > 0 {
                let bytes = &output[..count as usize];
                transcript.extend_from_slice(bytes);
                if crate::screen::displayed_lines(&transcript)
                    .join("\n")
                    .to_ascii_lowercase()
                    .contains("your oauth token")
                    || crate::screen::capture_setup_token(&transcript).is_some()
                {
                    secret_screen = true;
                }
                if !secret_screen {
                    if let Err(error) = write_all(output_fd, bytes) {
                        return abort_group(&mut child, what, &forwarding, error);
                    }
                }
                if let Some(url) = crate::screen::authorization_url(&transcript)
                    && printed_url.as_deref() != Some(url.as_str())
                {
                    if let Err(error) = write_all(
                        output_fd,
                        format!("\r\nAuthorization URL: {url}\r\n").as_bytes(),
                    ) {
                        return abort_group(&mut child, what, &forwarding, error);
                    }
                    printed_url = Some(url);
                }
            } else if count == 0 {
                master_eof = true;
            } else {
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(libc::EIO) {
                    master_eof = true;
                } else if !matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) {
                    return abort_group(&mut child, what, &forwarding, error.to_string());
                }
            }
        }
    }
}

fn open_pty() -> Result<(OwnedFd, OwnedFd), String> {
    let mut master = -1;
    let mut slave = -1;
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if opened == -1 {
        return Err(io::Error::last_os_error().to_string());
    }

    let master = unsafe { OwnedFd::from_raw_fd(master) };
    let slave = unsafe { OwnedFd::from_raw_fd(slave) };
    let geometry = libc::winsize {
        ws_row: CEREMONY_ROWS,
        ws_col: CEREMONY_COLUMNS,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe { libc::ioctl(slave.as_raw_fd(), libc::TIOCSWINSZ, &geometry) } == -1 {
        return Err(format!(
            "could not set ceremony pty to {CEREMONY_ROWS}x{CEREMONY_COLUMNS}: {}",
            io::Error::last_os_error()
        ));
    }
    Ok((master, slave))
}

fn configure_command(command: &mut Command, slave: &OwnedFd) -> Result<(), String> {
    let stdin = duplicate(slave)?;
    let stdout = duplicate(slave)?;
    let stderr = duplicate(slave)?;
    command
        .stdin(Stdio::from(stdin))
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY as libc::c_ulong, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(())
}

fn duplicate(fd: &OwnedFd) -> Result<OwnedFd, String> {
    let duplicated = unsafe { libc::dup(fd.as_raw_fd()) };
    if duplicated == -1 {
        return Err(io::Error::last_os_error().to_string());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(duplicated) })
}

fn nonblocking(fd: libc::c_int) -> Result<(), String> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error().to_string());
    }
    Ok(())
}

fn write_all(fd: libc::c_int, mut bytes: &[u8]) -> Result<(), String> {
    while !bytes.is_empty() {
        let count = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if count > 0 {
            bytes = &bytes[count as usize..];
        } else {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error.to_string());
            }
        }
    }
    Ok(())
}

fn terminate_group(
    child: &mut std::process::Child,
    what: &str,
    forwarding: &SignalForwarding,
) -> Result<(), String> {
    terminate_process_group(child, Duration::from_secs(2)).map_err(|error| {
        format!("could not terminate {what}: {error}; process group left unsignalled")
    })?;
    forwarding.disarm();
    child.wait().map_err(|error| error.to_string())?;
    Ok(())
}

fn abort_group<T>(
    child: &mut std::process::Child,
    what: &str,
    forwarding: &SignalForwarding,
    cause: String,
) -> Result<T, String> {
    match terminate_group(child, what, forwarding) {
        Ok(()) => Err(cause),
        Err(cleanup) => Err(format!("{cause}; cleanup also failed: {cleanup}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::{Read, Write};

    fn pipe_with(bytes: &[u8]) -> OwnedFd {
        let mut fds = [-1, -1];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let reader = unsafe { OwnedFd::from_raw_fd(fds[0]) };
        let writer = unsafe { OwnedFd::from_raw_fd(fds[1]) };
        let mut writer = std::fs::File::from(writer);
        writer.write_all(bytes).unwrap();
        drop(writer);
        reader
    }

    fn output_file(name: &str) -> (std::path::PathBuf, std::fs::File) {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-pty-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_file(&path);
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        (path, file)
    }

    #[test]
    fn piped_stdin_drives_a_child_that_requires_a_tty() {
        let input = pipe_with(b"from-a-pipe\n");
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "test -t 0 || exit 91; IFS= read -r value; printf 'received:%s\\n' \"$value\"",
        ]);

        let output = run_with_fds(
            command,
            "piped pty fixture",
            Instant::now() + Duration::from_secs(5),
            input.as_raw_fd(),
            libc::STDOUT_FILENO,
        )
        .unwrap();

        assert!(output.status.success());
        assert!(
            String::from_utf8_lossy(&output.transcript).contains("received:from-a-pipe"),
            "{}",
            String::from_utf8_lossy(&output.transcript)
        );
    }

    #[test]
    fn child_pty_geometry_is_deliberate() {
        let input = pipe_with(b"");
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "stty size"]);

        let output = run_with_fds(
            command,
            "geometry fixture",
            Instant::now() + Duration::from_secs(5),
            input.as_raw_fd(),
            libc::STDOUT_FILENO,
        )
        .unwrap();

        assert!(output.status.success());
        assert!(
            String::from_utf8_lossy(&output.transcript).contains("50 109"),
            "{}",
            String::from_utf8_lossy(&output.transcript)
        );
    }

    #[test]
    fn authorization_url_is_printed_plainly_by_the_parent() {
        let input = pipe_with(b"");
        let (path, file) = output_file("url");
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "printf '\\033[32mOpening browser to sign in...\\033[0m\\nhttps://example.test/authorize?code=fixture\\n'",
        ]);

        let result = run_with_fds(
            command,
            "URL fixture",
            Instant::now() + Duration::from_secs(5),
            input.as_raw_fd(),
            file.as_raw_fd(),
        )
        .unwrap();
        assert!(result.status.success());
        drop(file);

        let mut rendered = String::new();
        fs::File::open(&path)
            .unwrap()
            .read_to_string(&mut rendered)
            .unwrap();
        let _ = fs::remove_file(path);
        assert!(
            rendered.contains("Authorization URL: https://example.test/authorize?code=fixture"),
            "{rendered:?}"
        );
    }

    #[test]
    fn setup_token_stays_in_memory_instead_of_parent_stdout() {
        const TOKEN: &str = "sk-ant-oat01-SYNTHETIC-NOT-A-CREDENTIAL-0123456789";
        let input = pipe_with(b"");
        let (path, file) = output_file("token-redaction");
        let mut command = Command::new("/bin/sh");
        command.args(["-c", &format!("printf '{TOKEN}\\n'")]);

        let result = run_with_fds(
            command,
            "token redaction fixture",
            Instant::now() + Duration::from_secs(5),
            input.as_raw_fd(),
            file.as_raw_fd(),
        )
        .unwrap();
        assert!(
            String::from_utf8_lossy(&result.transcript).contains(TOKEN),
            "the read side must retain the token for capture"
        );
        drop(file);

        let rendered = fs::read_to_string(&path).unwrap();
        let _ = fs::remove_file(path);
        assert!(
            !rendered.contains(TOKEN),
            "parent stdout leaked {rendered:?}"
        );
    }
}
