//! Direct pseudo-terminal ownership for interactive provider ceremonies.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use crate::child_process::{NonblockingFd, Supervised, nonblocking, supervise};

pub(crate) use crate::child_process::RunError;

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

/// Run a ceremony under a pty and READ a credential off it.
///
/// This is a capture stream, and a capture stream is never mirrored. The bytes come back
/// in `Output::transcript` for the screen reader and go nowhere else: not one child byte
/// is written to the operator's terminal, whatever the child prints.
///
/// That is a property of the STREAM, not a rule about its content, and it replaces one
/// that could not hold. The previous shape forwarded everything until it recognised the
/// heading `claude` prints above the token — so a reworded heading, which the provider
/// is free to ship at any time, put a year-long credential on stdout and into whatever
/// was capturing it. Any rule of the form "forward until it looks secret" has that
/// failure mode, because the parent cannot know a credential by looking at it. What the
/// parent does know is which stream it is about to read a credential OUT of; on that
/// stream, silence is the only safe default.
///
/// The operator is not left blind: what they need — the authorization URL — is extracted
/// from the replayed screen and printed by the parent in its own words. Their keystrokes
/// still reach the child, so pasting an authorization code works exactly as before.
pub(crate) fn run(command: Command, what: &str, deadline: Instant) -> Result<Output, RunError> {
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
) -> Result<Output, RunError> {
    let (master, slave) = open_pty()?;
    configure_command(&mut command, &slave)?;

    let mut transcript = Vec::new();
    let (_, status) = supervise(command, what, deadline, |supervised| {
        // The parent's copies of the pty slave close HERE, before anything waits on the
        // master. While any copy of the slave is still open in this process the master
        // never reports EOF, and the loop below waits for an end that cannot arrive --
        // which is what hung four tests on linux, where the timing exposes it.
        drop(slave);
        nonblocking(master.as_raw_fd())?;
        let _output_flags = NonblockingFd::new(output_fd)?;
        relay(supervised, &master, input_fd, output_fd, &mut transcript)
    })?;

    Ok(Output { status, transcript })
}

/// Carry the operator's keystrokes to the child and its bytes into the transcript.
///
/// It writes to `output_fd` only in its own words. Every way this returns -- completion,
/// the lease, a signal, an I/O failure -- is a value handed back to `supervise`, which
/// owns ending the child.
fn relay(
    supervised: &mut Supervised,
    master: &OwnedFd,
    input_fd: libc::c_int,
    output_fd: libc::c_int,
    transcript: &mut Vec<u8>,
) -> Result<(), RunError> {
    let mut pending_input = Vec::new();
    let mut input_eof = false;
    let mut sent_eof = false;
    let mut master_eof = false;
    let mut printed_url = None;

    // Said BEFORE the child can print anything, because the case that needs it most is the
    // one where nothing ever arrives. If claude asks something first -- consent, an account
    // to use, an update prompt -- the operator sees an unexplained empty screen, and the
    // url announcement below would never fire to explain it. Do not be tempted to solve
    // that by showing the child's pre-url bytes: "the credential cannot appear before the
    // url" is an assumption about provider behaviour, and assuming provider behaviour is
    // what cost a real operator a real credential.
    supervised.write_all(output_fd, PREFACE.as_bytes())?;

    loop {
        // Asked before the signal is read, so that a child which exited and a TERM which
        // arrived in the same instant are both known to the same iteration.
        let leader_exited = supervised.exited()?;

        if let Some(error) = supervised.interrupted() {
            return Err(error);
        }

        if leader_exited && master_eof {
            return Ok(());
        }

        if let Some(error) = supervised.expired() {
            return Err(format!("{error}. {}", expiry_advice()).into());
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
        let timeout_ms = supervised
            .deadline()
            .saturating_duration_since(Instant::now())
            .min(Duration::from_millis(50))
            .as_millis() as libc::c_int;
        let polled = unsafe { libc::poll(polls.as_mut_ptr(), polls.len() as _, timeout_ms) };
        if polled == -1 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error.to_string().into());
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
                    return Err(error.to_string().into());
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
                    return Err(error.to_string().into());
                }
            }
        }

        if !master_eof && polls[0].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let mut output = [0u8; 8192];
            let count =
                unsafe { libc::read(master.as_raw_fd(), output.as_mut_ptr().cast(), output.len()) };
            if count > 0 {
                transcript.extend_from_slice(&output[..count as usize]);
                if let Some(url) = crate::screen::authorization_url(transcript)
                    && printed_url.as_deref() != Some(url.as_str())
                {
                    supervised.write_all(output_fd, announcement(&url).as_bytes())?;
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
                    return Err(error.to_string().into());
                }
            }
        }
    }
}

/// Everything the operator is told, in the parent's words.
///
/// The claim these make is "no UNEXAMINED child byte reaches the terminal", not "no child
/// byte" -- the url below is child-derived, extracted from the transcript and validated as
/// a url before it is repeated. That distinction is the whole safety argument, so state it
/// accurately: a rule defended by an overstatement is a rule someone later relaxes.
const PREFACE: &str = "\r\nWaiting for claude to produce an authorization URL. What claude \
     prints is not shown, because the credential appears in it -- so this may look idle for \
     a few seconds.\r\n";

/// Named in the lease-expiry message so a silent wait ends with something to DO.
pub(crate) const MANUAL_FALLBACK: &str = "claude setup-token";

fn announcement(url: &str) -> String {
    format!(
        "\r\nAuthorization URL: {url}\r\nSign in there, then paste the authorization code here \
         if you are asked for one. What claude prints is not shown, because the credential \
         appears in it.\r\n"
    )
}

/// What a lease expiry means to the operator, as opposed to what it means to the code.
///
/// The ceremony hides the child's output, so an expiry has a cause the operator cannot see:
/// claude may be sitting on a prompt. The deadline error says what happened; this says what
/// to DO about it, and is APPENDED to that error rather than replacing it -- the lease
/// wording is what callers and tests recognise an expiry by, and an operator-friendly
/// rewrite that quietly changes an error's identity is a different bug.
fn expiry_advice() -> String {
    format!(
        "Because the harness's output is deliberately not shown, it may have been waiting \
         on a prompt. Run `{MANUAL_FALLBACK}` yourself to see what it is asking."
    )
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

    /// The operator has to be told about the silence BEFORE the silence.
    ///
    /// A child that prompts for something and waits prints no url, so the announcement
    /// keyed on a url never fires -- and the one case where the explanation is load-bearing
    /// was the one case that had none. What the operator saw was an empty screen for the
    /// length of the lease, with nothing to distinguish it from a hang.
    #[test]
    fn a_child_that_prompts_before_any_url_still_explains_the_silence() {
        let input = pipe_with(b"");
        let (path, file) = output_file("prompt-before-url");
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf 'Select an account to use:\\n'; sleep 0.3"]);

        let _ = run_with_fds(
            command,
            "prompting fixture",
            Instant::now() + Duration::from_secs(5),
            input.as_raw_fd(),
            file.as_raw_fd(),
        )
        .unwrap();
        drop(file);

        let rendered = fs::read_to_string(&path).unwrap();
        let _ = fs::remove_file(path);
        assert!(
            rendered.contains("not shown, because the credential appears in it"),
            "the operator was left with unexplained silence: {rendered:?}"
        );
        assert!(
            !rendered.contains("Select an account"),
            "explaining the silence must not start forwarding the child: {rendered:?}"
        );
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

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut fds = [-1, -1];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        (unsafe { OwnedFd::from_raw_fd(fds[0]) }, unsafe {
            OwnedFd::from_raw_fd(fds[1])
        })
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
        assert!(
            !rendered.contains("Opening browser"),
            "the child's own output reached the terminal: {rendered:?}"
        );
    }

    /// The failure that made "forward until it looks secret" untenable.
    ///
    /// `claude` renames the heading above its token -- a thing it is free to do in any
    /// release -- and the recognition rule never fires: capture correctly refuses, and the
    /// credential is on stdout anyway, because the parent forwarded the panel while
    /// deciding it was not one. The assertion is on the BYTES the parent wrote, not on
    /// what it returned; the return value was already right when this leaked.
    #[test]
    fn an_unreadable_credential_panel_reaches_neither_stdout_nor_capture() {
        const TOKEN: &str = "sk-ant-oat01-SYNTHETIC-NOT-A-CREDENTIAL-0123456789";
        let input = pipe_with(b"");
        let (path, file) = output_file("unreadable-panel");
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            &format!(
                "printf 'Your API credential (valid for 1 year):\\n\\n{TOKEN}\\n\\nStore it somewhere safe.\\n'"
            ),
        ]);

        let result = run_with_fds(
            command,
            "unreadable panel fixture",
            Instant::now() + Duration::from_secs(5),
            input.as_raw_fd(),
            file.as_raw_fd(),
        )
        .unwrap();
        assert!(
            crate::screen::capture_setup_token(&result.transcript).is_none(),
            "the fixture has to be a panel capture cannot read, or it proves nothing"
        );
        drop(file);

        let rendered = fs::read_to_string(&path).unwrap();
        let _ = fs::remove_file(path);
        assert!(
            !rendered.contains(TOKEN),
            "parent stdout leaked the credential: {rendered:?}"
        );
        assert!(
            !rendered.contains("API credential"),
            "parent stdout mirrored the child: {rendered:?}"
        );
    }

    #[test]
    fn setup_token_stays_in_memory_instead_of_parent_stdout() {
        const TOKEN: &str = "sk-ant-oat01-SYNTHETIC-NOT-A-CREDENTIAL-0123456789";
        let input = pipe_with(b"");
        let (path, file) = output_file("token-redaction");
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            &format!(
                "printf 'Your OAuth token (valid for 1 year):\\n\\n{TOKEN}\\n\\nStore this token securely.\\n'"
            ),
        ]);

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

    #[test]
    fn a_blocked_output_consumer_cannot_hold_the_pty_past_its_deadline() {
        let input = pipe_with(b"");
        let (_output_reader, output_writer) = pipe();
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "while :; do printf 'continuous child output\\n'; done",
        ]);
        let started = Instant::now();

        let error = run_with_fds(
            command,
            "blocked pty output fixture",
            Instant::now() + Duration::from_millis(100),
            input.as_raw_fd(),
            output_writer.as_raw_fd(),
        )
        .unwrap_err();

        assert!(
            error.to_string().contains("onboarding lease expired"),
            "{error}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(4),
            "blocked output held the pty loop for {:?}",
            started.elapsed()
        );
    }
}
