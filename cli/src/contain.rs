use std::fs;
use std::io::{self, BufRead, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[allow(dead_code)]
const CONTAIN_INCOMPLETE: i32 = 199;
#[allow(dead_code)]
const CONTAIN_FORCED_TERM: i32 = 200 + libc::SIGTERM;
#[allow(dead_code)]
const CONTAIN_FORCED_KILL: i32 = 200 + libc::SIGKILL;

const PASS: i32 = 0;
const SCRIPT_ERROR: i32 = 10;
const SCRIPT_TIMEOUT: i32 = 20;
const CONTAINED_REFUSED: i32 = 30;

#[allow(dead_code)]
enum ContainArgs {
    Check,
    Profile { profile: String, argv: Vec<String> },
}

#[derive(Clone, Copy)]
#[allow(dead_code)]
enum Trigger {
    Natural,
    StdinEof,
    Signal(i32),
    Error,
}

#[allow(dead_code)]
impl Trigger {
    fn name(self) -> &'static str {
        match self {
            Self::Natural => "note-exit",
            Self::StdinEof => "stdin-eof",
            Self::Signal(libc::SIGTERM) => "sigterm",
            Self::Signal(libc::SIGINT) => "sigint",
            Self::Signal(_) => "signal",
            Self::Error => "error",
        }
    }
}

#[allow(dead_code)]
pub fn contain_exec(args: &[String]) -> i32 {
    match parse_contain(args) {
        Ok(ContainArgs::Check) => contain_check(),
        Ok(ContainArgs::Profile { profile, argv }) => contain_profile(profile, argv),
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}

#[allow(dead_code)]
fn parse_contain(args: &[String]) -> Result<ContainArgs, String> {
    if args == ["--check"] {
        return Ok(ContainArgs::Check);
    }

    if args.first().map(String::as_str) != Some("--profile") {
        return Err(
            "usage: tightbeam contain-exec --check | --profile <SBPL> -- <argv...>".to_owned(),
        );
    }

    let profile = args
        .get(1)
        .filter(|profile| !profile.is_empty())
        .ok_or_else(|| "contain-exec: missing profile".to_owned())?
        .clone();
    let sentinel = args
        .iter()
        .position(|arg| arg == "--")
        .ok_or_else(|| "contain-exec: missing -- sentinel".to_owned())?;

    if sentinel != 2 {
        return Err("contain-exec: expected -- immediately after profile".to_owned());
    }

    let argv = args[(sentinel + 1)..].to_vec();
    if argv.is_empty() || argv[0].is_empty() {
        return Err("contain-exec: missing payload argv".to_owned());
    }

    Ok(ContainArgs::Profile { profile, argv })
}

#[allow(dead_code)]
fn contain_check() -> i32 {
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("contain-exec: macOS is required");
        1
    }

    #[cfg(target_os = "macos")]
    {
        match fs::metadata("/usr/bin/sandbox-exec") {
            Ok(metadata) if metadata.is_file() && metadata.permissions().mode() & 0o111 != 0 => 0,
            Ok(_) => {
                eprintln!("contain-exec: /usr/bin/sandbox-exec is not executable");
                1
            }
            Err(error) => {
                eprintln!("contain-exec: /usr/bin/sandbox-exec is unavailable: {error}");
                1
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
#[allow(dead_code)]
fn contain_profile(_profile: String, _argv: Vec<String>) -> i32 {
    eprintln!("contain-exec: macOS is required");
    1
}

#[cfg(target_os = "macos")]
#[allow(dead_code)]
fn contain_profile(profile: String, argv: Vec<String>) -> i32 {
    match macos_custody::run(profile, argv) {
        Ok(status) => status,
        Err(error) => {
            eprintln!("contain-exec: {error}");
            1
        }
    }
}

#[cfg(target_os = "macos")]
#[allow(dead_code)]
mod macos_custody {
    use super::*;
    use std::mem;
    use std::ptr;

    const TERM_GRACE: Duration = Duration::from_millis(2_000);
    const KILL_GRACE: Duration = Duration::from_millis(5_000);
    const POLL: Duration = Duration::from_millis(100);
    const EOF_TIMER_IDENT: usize = 1;

    pub(super) fn run(profile: String, argv: Vec<String>) -> Result<i32, String> {
        install_handlers_and_block().map_err(|error| format!("signal setup failed: {error}"))?;

        let mut command = Command::new("/usr/bin/sandbox-exec");
        command.arg("-p").arg(profile).args(argv);

        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }

                libc::signal(libc::SIGTERM, libc::SIG_DFL);
                libc::signal(libc::SIGINT, libc::SIG_DFL);
                let mut empty: libc::sigset_t = mem::zeroed();
                if libc::sigemptyset(&mut empty) == -1
                    || libc::sigprocmask(libc::SIG_SETMASK, &empty, ptr::null_mut()) == -1
                {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }

        let child = command
            .spawn()
            .map_err(|error| format!("sandbox-exec spawn failed: {error}"))?;
        let pid = child.id() as libc::pid_t;

        let kq = unsafe { libc::kqueue() };
        if kq == -1 {
            unblock_signals();
            return Ok(teardown(pid, Trigger::Error));
        }
        let _kqueue = Kqueue(kq);

        let changes = [
            event(
                pid as usize,
                libc::EVFILT_PROC,
                libc::EV_ADD,
                libc::NOTE_EXIT,
            ),
            event(
                libc::STDIN_FILENO as usize,
                libc::EVFILT_READ,
                libc::EV_ADD | libc::EV_CLEAR,
                0,
            ),
            event(libc::SIGTERM as usize, libc::EVFILT_SIGNAL, libc::EV_ADD, 0),
            event(libc::SIGINT as usize, libc::EVFILT_SIGNAL, libc::EV_ADD, 0),
        ];

        let registered = retry_kevent(kq, &changes, &mut [], ptr::null());
        unblock_signals();

        if registered.is_err() {
            return Ok(teardown(pid, Trigger::Error));
        }

        let mut eof_grace = false;
        loop {
            let mut events = [empty_event(); 8];
            let count = match retry_kevent(kq, &[], &mut events, ptr::null()) {
                Ok(count) => count,
                Err(_) => return Ok(teardown(pid, Trigger::Error)),
            };
            let batch = &events[..count];

            if batch.iter().any(|event| {
                event.filter == libc::EVFILT_PROC && event.fflags & libc::NOTE_EXIT != 0
            }) {
                return Ok(teardown(pid, Trigger::Natural));
            }

            if let Some(signal) = batch.iter().find_map(|event| {
                if event.filter == libc::EVFILT_SIGNAL {
                    Some(event.ident as i32)
                } else {
                    None
                }
            }) {
                return Ok(teardown(pid, Trigger::Signal(signal)));
            }

            if batch.iter().any(|event| event.flags & libc::EV_ERROR != 0) {
                return Ok(teardown(pid, Trigger::Error));
            }

            if batch
                .iter()
                .any(|event| event.filter == libc::EVFILT_TIMER && event.ident == EOF_TIMER_IDENT)
            {
                return Ok(teardown(pid, Trigger::StdinEof));
            }

            if !eof_grace
                && batch.iter().any(|event| {
                    event.filter == libc::EVFILT_READ
                        && event.ident == libc::STDIN_FILENO as usize
                        && event.flags & libc::EV_EOF != 0
                })
            {
                let timer = [libc::kevent {
                    ident: EOF_TIMER_IDENT,
                    filter: libc::EVFILT_TIMER,
                    flags: libc::EV_ADD | libc::EV_ONESHOT,
                    fflags: 0,
                    data: 5_000,
                    udata: ptr::null_mut(),
                }];
                if retry_kevent(kq, &timer, &mut [], ptr::null()).is_err() {
                    return Ok(teardown(pid, Trigger::Error));
                }
                eof_grace = true;
            }
        }
    }

    unsafe extern "C" fn noop_handler(_signal: libc::c_int) {}

    fn install_handlers_and_block() -> io::Result<()> {
        unsafe {
            let mut action: libc::sigaction = mem::zeroed();
            action.sa_sigaction = noop_handler as *const () as usize;
            if libc::sigemptyset(&mut action.sa_mask) == -1
                || libc::sigaction(libc::SIGTERM, &action, ptr::null_mut()) == -1
                || libc::sigaction(libc::SIGINT, &action, ptr::null_mut()) == -1
            {
                return Err(io::Error::last_os_error());
            }

            let mut blocked: libc::sigset_t = mem::zeroed();
            if libc::sigemptyset(&mut blocked) == -1
                || libc::sigaddset(&mut blocked, libc::SIGTERM) == -1
                || libc::sigaddset(&mut blocked, libc::SIGINT) == -1
                || libc::sigprocmask(libc::SIG_BLOCK, &blocked, ptr::null_mut()) == -1
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }

    fn unblock_signals() {
        unsafe {
            let mut blocked: libc::sigset_t = mem::zeroed();
            libc::sigemptyset(&mut blocked);
            libc::sigaddset(&mut blocked, libc::SIGTERM);
            libc::sigaddset(&mut blocked, libc::SIGINT);
            libc::sigprocmask(libc::SIG_UNBLOCK, &blocked, ptr::null_mut());
        }
    }

    fn teardown(pid: libc::pid_t, trigger: Trigger) -> i32 {
        let mut collected = None;
        let natural = match waitpid_nohang(pid) {
            Ok(status) => {
                collected = status;
                status
            }
            Err(_) => None,
        };

        if group_absent(pid) {
            let status = natural.map(natural_status).unwrap_or(1);
            report(trigger, &format!("natural:{status}"));
            return status;
        }

        let _ = kill_group(pid, libc::SIGTERM);
        let term_absent = poll_absence(pid, TERM_GRACE, &mut collected);
        let kill_absent = if term_absent {
            false
        } else {
            let _ = kill_group(pid, libc::SIGKILL);
            poll_absence(pid, KILL_GRACE, &mut collected)
        };

        let (status, outcome) =
            classify_after_polls(natural.map(natural_status), term_absent, kill_absent);
        if status == CONTAIN_INCOMPLETE {
            eprintln!("{}", incomplete_marker(pid));
        }
        report(trigger, outcome);
        status
    }

    pub(super) fn classify_after_polls(
        natural: Option<i32>,
        term_absent: bool,
        kill_absent: bool,
    ) -> (i32, &'static str) {
        if !term_absent && !kill_absent {
            (CONTAIN_INCOMPLETE, "incomplete")
        } else if let Some(status) = natural {
            (status, "natural")
        } else if term_absent {
            (CONTAIN_FORCED_TERM, "forced-term")
        } else {
            (CONTAIN_FORCED_KILL, "forced-kill")
        }
    }

    pub(super) fn incomplete_marker(pgid: libc::pid_t) -> String {
        format!("contain-exec: contained_teardown_incomplete pgid={pgid}")
    }

    pub(super) fn report_line(trigger: Trigger, outcome: &str) -> String {
        format!(
            "contain-exec: teardown trigger={} outcome={outcome}",
            trigger.name()
        )
    }

    fn poll_absence(
        pid: libc::pid_t,
        timeout: Duration,
        collected: &mut Option<libc::c_int>,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if collected.is_none() {
                if let Ok(Some(status)) = waitpid_nohang(pid) {
                    *collected = Some(status);
                }
            }
            if group_absent(pid) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            sleep_retry(POLL);
        }
    }

    fn waitpid_nohang(pid: libc::pid_t) -> io::Result<Option<libc::c_int>> {
        loop {
            let mut status = 0;
            let result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
            if result == pid {
                return Ok(Some(status));
            }
            if result == 0 {
                return Ok(None);
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            if error.raw_os_error() == Some(libc::ECHILD) {
                return Ok(None);
            }
            return Err(error);
        }
    }

    fn group_absent(pgid: libc::pid_t) -> bool {
        let result = unsafe { libc::kill(-pgid, 0) };
        result == -1 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    }

    fn kill_group(pgid: libc::pid_t, signal: libc::c_int) -> io::Result<()> {
        let result = unsafe { libc::killpg(pgid, signal) };
        if result == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(error)
        }
    }

    fn natural_status(status: libc::c_int) -> i32 {
        if libc::WIFEXITED(status) {
            libc::WEXITSTATUS(status)
        } else if libc::WIFSIGNALED(status) {
            128 + libc::WTERMSIG(status)
        } else {
            1
        }
    }

    fn sleep_retry(duration: Duration) {
        let mut remaining = libc::timespec {
            tv_sec: duration.as_secs() as libc::time_t,
            tv_nsec: duration.subsec_nanos() as libc::c_long,
        };
        loop {
            let mut next = libc::timespec {
                tv_sec: 0,
                tv_nsec: 0,
            };
            let result = unsafe { libc::nanosleep(&remaining, &mut next) };
            if result == 0 {
                return;
            }
            if io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                return;
            }
            remaining = next;
        }
    }

    fn retry_kevent(
        kq: libc::c_int,
        changes: &[libc::kevent],
        events: &mut [libc::kevent],
        timeout: *const libc::timespec,
    ) -> io::Result<usize> {
        loop {
            let result = unsafe {
                libc::kevent(
                    kq,
                    changes.as_ptr(),
                    changes.len() as libc::c_int,
                    events.as_mut_ptr(),
                    events.len() as libc::c_int,
                    timeout,
                )
            };
            if result >= 0 {
                return Ok(result as usize);
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EINTR) {
                return Err(error);
            }
        }
    }

    fn event(ident: usize, filter: i16, flags: u16, fflags: u32) -> libc::kevent {
        libc::kevent {
            ident,
            filter,
            flags,
            fflags,
            data: 0,
            udata: ptr::null_mut(),
        }
    }

    fn empty_event() -> libc::kevent {
        event(0, 0, 0, 0)
    }

    fn report(trigger: Trigger, outcome: &str) {
        eprintln!("{}", report_line(trigger, outcome));
    }

    struct Kqueue(libc::c_int);

    impl Drop for Kqueue {
        fn drop(&mut self) {
            unsafe {
                libc::close(self.0);
            }
        }
    }
}

struct RailExecArgs {
    profile: String,
    timeout: Duration,
    script: String,
}

pub fn rail_exec(args: &[String]) -> Result<i32, String> {
    let args = parse(args)?;
    Ok(run(args))
}

fn parse(args: &[String]) -> Result<RailExecArgs, String> {
    if args.len() != 6 || args[0] != "--profile" || args[2] != "--timeout-ms" || args[4] != "--" {
        return Err(
            "usage: tightbeam rail-exec --profile <SBPL> --timeout-ms <N> -- <script-path>"
                .to_owned(),
        );
    }

    let timeout_ms = args[3]
        .parse::<u64>()
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| "--timeout-ms must be a positive integer".to_owned())?;

    if args[1].is_empty() || args[5].is_empty() {
        return Err("--profile and script-path must be non-empty".to_owned());
    }

    Ok(RailExecArgs {
        profile: args[1].clone(),
        timeout: Duration::from_millis(timeout_ms),
        script: args[5].clone(),
    })
}

fn run(args: RailExecArgs) -> i32 {
    let mut input = Vec::new();
    if io::stdin().lock().read_until(b'\n', &mut input).is_err() {
        return SCRIPT_ERROR;
    }

    run_with_input(args, input)
}

fn run_with_input(args: RailExecArgs, input: Vec<u8>) -> i32 {
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .arg("-p")
        .arg(&args.profile)
        .arg("--")
        .arg(&args.script)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }

            libc::signal(libc::SIGPIPE, libc::SIG_DFL);
            libc::signal(libc::SIGINT, libc::SIG_DFL);
            libc::signal(libc::SIGTERM, libc::SIG_DFL);
            Ok(())
        });
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!("sandbox-exec: {error}");
            return CONTAINED_REFUSED;
        }
    };

    let mut child_stdin = child.stdin.take().expect("piped child stdin");
    let stdin_writer = thread::spawn(move || {
        let result = child_stdin.write_all(&input);
        drop(child_stdin);
        result
    });

    let mut child_stdout = child.stdout.take().expect("piped child stdout");
    let stdout_reader = thread::spawn(move || {
        let mut output = Vec::new();
        child_stdout.read_to_end(&mut output).map(|_| output)
    });

    let mut child_stderr = child.stderr.take().expect("piped child stderr");
    let stderr_reader = thread::spawn(move || {
        let mut output = Vec::new();
        child_stderr.read_to_end(&mut output).map(|_| output)
    });

    let started = Instant::now();
    let mut status = None;
    let timed_out = loop {
        if status.is_none() {
            match child.try_wait() {
                Ok(Some(child_status)) => status = Some(child_status),
                Ok(None) => {}
                Err(error) => {
                    eprintln!("rail-exec wait failed: {error}");
                    let pgid = child.id() as libc::pid_t;
                    unsafe {
                        libc::killpg(pgid, libc::SIGKILL);
                    }
                    let _ = child.wait();
                    return SCRIPT_ERROR;
                }
            }
        }

        if status.is_some()
            && stdin_writer.is_finished()
            && stdout_reader.is_finished()
            && stderr_reader.is_finished()
        {
            break false;
        }

        if started.elapsed() >= args.timeout {
            let pgid = child.id() as libc::pid_t;
            unsafe {
                // killpg sends SIGKILL to every process in the child's process group.
                libc::killpg(pgid, libc::SIGKILL);
            }

            if status.is_none() {
                let _ = child.wait();
            }

            break true;
        }

        thread::sleep(Duration::from_millis(2));
    };

    if timed_out {
        drop(stdin_writer);
        drop(stdout_reader);
        drop(stderr_reader);
        return SCRIPT_TIMEOUT;
    }

    let stdin_delivered = matches!(stdin_writer.join(), Ok(Ok(())));
    let stdout = stdout_reader
        .join()
        .ok()
        .and_then(Result::ok)
        .unwrap_or_default();
    let stderr = stderr_reader
        .join()
        .ok()
        .and_then(Result::ok)
        .unwrap_or_default();

    let _ = io::stderr().write_all(&stderr);

    if !stdin_delivered {
        eprintln!("tightbeam rail-exec child exit: 1");
        return SCRIPT_ERROR;
    }

    let status = status.expect("child status present when pipe workers finish");

    if status.success() {
        let _ = io::stdout().write_all(&stdout);
        return PASS;
    }

    if profile_apply_failed(status.code(), &stdout, &stderr) {
        return CONTAINED_REFUSED;
    }

    let child_code = status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(1);
    eprintln!("tightbeam rail-exec child exit: {child_code}");
    SCRIPT_ERROR
}

fn profile_apply_failed(code: Option<i32>, stdout: &[u8], stderr: &[u8]) -> bool {
    code == Some(65) && stdout.is_empty() && stderr.starts_with(b"sandbox-exec:")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::Child;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(1);

    fn temp_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-rail-exec-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn script(dir: &Path, name: &str, body: &str) -> String {
        let path = dir.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn permissive_profile() -> String {
        "(version 1)\n(allow default)".to_owned()
    }

    #[test]
    fn contain_parser_accepts_check_and_profile_forms() {
        assert!(matches!(
            parse_contain(&["--check".into()]),
            Ok(ContainArgs::Check)
        ));

        match parse_contain(&[
            "--profile".into(),
            "profile".into(),
            "--".into(),
            "/bin/echo".into(),
            "ok".into(),
        ])
        .unwrap()
        {
            ContainArgs::Profile { profile, argv } => {
                assert_eq!(profile, "profile");
                assert_eq!(argv, ["/bin/echo", "ok"]);
            }
            ContainArgs::Check => panic!("expected profile form"),
        }
    }

    #[test]
    fn contain_parser_rejects_missing_profile_sentinel_and_payload() {
        for args in [
            vec!["--profile".into()],
            vec!["--profile".into(), "profile".into()],
            vec!["--profile".into(), "profile".into(), "--".into()],
        ] {
            assert!(parse_contain(&args).is_err());
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn contain_check_is_silent_success_on_the_supported_host() {
        assert_eq!(contain_check(), 0);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_status_classification_pins_every_band() {
        assert_eq!(
            macos_custody::classify_after_polls(Some(7), true, false),
            (7, "natural")
        );
        assert_eq!(
            macos_custody::classify_after_polls(None, true, false),
            (CONTAIN_FORCED_TERM, "forced-term")
        );
        assert_eq!(
            macos_custody::classify_after_polls(None, false, true),
            (CONTAIN_FORCED_KILL, "forced-kill")
        );
        assert_eq!(
            macos_custody::classify_after_polls(None, false, false),
            (CONTAIN_INCOMPLETE, "incomplete")
        );
        assert_eq!(
            macos_custody::incomplete_marker(42),
            "contain-exec: contained_teardown_incomplete pgid=42"
        );
        assert_eq!(
            macos_custody::report_line(Trigger::Signal(libc::SIGTERM), "forced-term"),
            "contain-exec: teardown trigger=sigterm outcome=forced-term"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_subprocess() {
        let Ok(script) = std::env::var("TIGHTBEAM_CONTAIN_TEST_SCRIPT") else {
            return;
        };
        let profile = std::env::var("TIGHTBEAM_CONTAIN_TEST_PROFILE")
            .unwrap_or_else(|_| permissive_profile());
        let status = contain_profile(
            profile,
            vec![
                "/bin/sh".into(),
                "-c".into(),
                script,
                "tightbeam-contain-test".into(),
                unsafe { libc::getpgrp() }.to_string(),
            ],
        );
        std::process::exit(status);
    }

    #[cfg(target_os = "macos")]
    fn spawn_custody(script: &str) -> Child {
        spawn_custody_with_profile(script, &permissive_profile())
    }

    #[cfg(target_os = "macos")]
    fn spawn_custody_with_profile(script: &str, profile: &str) -> Child {
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "contain::tests::custody_subprocess",
                "--nocapture",
            ])
            .env("TIGHTBEAM_CONTAIN_TEST_SCRIPT", script)
            .env("TIGHTBEAM_CONTAIN_TEST_PROFILE", profile)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_propagates_natural_exit_and_signal_statuses() {
        let output = spawn_custody("exit 7").wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(7));
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("teardown trigger=note-exit outcome=natural:7")
        );

        let output = spawn_custody("kill -TERM $$").wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(128 + libc::SIGTERM));
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("teardown trigger=note-exit outcome=natural:143")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_fast_exit_always_remains_natural() {
        for _ in 0..20 {
            let output = spawn_custody("exit 7").wait_with_output().unwrap();
            assert_eq!(output.status.code(), Some(7));
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_payload_leads_a_new_process_group() {
        let output = spawn_custody(
            r#"/usr/bin/perl -MPOSIX -e 'exit(POSIX::getpgrp() == $ARGV[0] ? 41 : 0)' "$1""#,
        )
        .wait_with_output()
        .unwrap();
        assert_eq!(
            output.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_removes_group_descendants_after_natural_leader_exit() {
        let output = spawn_custody("sleep 300 & exit 7")
            .wait_with_output()
            .unwrap();
        assert_eq!(output.status.code(), Some(7));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn setsid_escapee_remains_gated_by_the_inherited_profile() {
        let marker = std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap()
            .join(format!(
                ".tightbeam-contain-escape-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        let profile = r#"(version 1)
(deny default)
(allow file-read*)
(allow file-write* (subpath "/private/tmp") (subpath "/dev"))
(allow process-fork)
(allow process-exec)
(allow signal (target self))
(allow mach-lookup)
(allow sysctl-read)
(allow network-outbound)"#;
        let script = format!(
            "/usr/bin/perl -MPOSIX -e 'if (fork) {{ exit 0 }}; setsid(); select(undef, undef, undef, 0.2); open my $fh, q(>), q({}) or exit 0; print $fh qq(escaped\\n)'",
            marker.display()
        );

        let output = spawn_custody_with_profile(&script, profile)
            .wait_with_output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0));
        thread::sleep(Duration::from_millis(500));
        assert!(!marker.exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_stdin_eof_forces_term_after_grace() {
        let mut child = spawn_custody("while :; do sleep 1; done");
        drop(child.stdin.take());
        let started = Instant::now();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(CONTAIN_FORCED_TERM));
        assert!(started.elapsed() >= Duration::from_secs(5));
        assert!(started.elapsed() < Duration::from_secs(8));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn custody_wrapper_signal_forces_term_and_kill_bands() {
        let term_child = spawn_custody("while :; do sleep 1; done");
        thread::sleep(Duration::from_millis(200));
        assert_eq!(
            unsafe { libc::kill(term_child.id() as i32, libc::SIGTERM) },
            0
        );
        let term_output = term_child.wait_with_output().unwrap();
        assert_eq!(term_output.status.code(), Some(CONTAIN_FORCED_TERM));
        assert!(
            String::from_utf8_lossy(&term_output.stderr)
                .contains("teardown trigger=sigterm outcome=forced-term")
        );

        let kill_child = spawn_custody("trap '' TERM; while :; do sleep 1; done");
        thread::sleep(Duration::from_millis(200));
        assert_eq!(
            unsafe { libc::kill(kill_child.id() as i32, libc::SIGINT) },
            0
        );
        let kill_output = kill_child.wait_with_output().unwrap();
        assert_eq!(kill_output.status.code(), Some(CONTAIN_FORCED_KILL));
        assert!(
            String::from_utf8_lossy(&kill_output.stderr)
                .contains("teardown trigger=sigint outcome=forced-kill")
        );
    }

    #[test]
    fn parses_the_pinned_form() {
        let parsed = parse(&[
            "--profile".into(),
            "profile".into(),
            "--timeout-ms".into(),
            "25".into(),
            "--".into(),
            "/tmp/check".into(),
        ])
        .unwrap();
        assert_eq!(parsed.timeout, Duration::from_millis(25));
        assert_eq!(parsed.script, "/tmp/check");
    }

    #[test]
    fn successful_child_preserves_stdout_and_has_the_pass_band() {
        let dir = temp_dir();
        let check = script(&dir, "passes", "echo pass");
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_secs(1),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, PASS);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn profile_apply_failure_has_its_own_band() {
        let dir = temp_dir();
        let check = script(&dir, "never-runs", "exit 0");
        let status = run_with_input(
            RailExecArgs {
                profile: "(version 1) (this-is-invalid)".into(),
                timeout: Duration::from_secs(1),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, CONTAINED_REFUSED);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn child_nonzero_has_the_script_error_band() {
        let dir = temp_dir();
        let check = script(&dir, "fails", "exit 7");
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_secs(1),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_ERROR);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn timeout_kills_the_whole_process_group() {
        let dir = temp_dir();
        let marker = dir.join("descendant-survived");
        let check = script(
            &dir,
            "hangs",
            &format!(
                "(sleep 1; echo survived > '{}') &\nsleep 5",
                marker.display()
            ),
        );
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_millis(40),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        thread::sleep(Duration::from_millis(1_100));
        assert!(!marker.exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn timeout_stays_armed_when_the_leader_exits_before_a_descendant() {
        let dir = temp_dir();
        let marker = dir.join("descendant-survived");
        let check = script(
            &dir,
            "leader-exits",
            &format!(
                "(sleep 1; echo survived > '{}') &\nexit 0",
                marker.display()
            ),
        );
        let started = Instant::now();
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_millis(40),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        assert!(started.elapsed() < Duration::from_millis(500));
        thread::sleep(Duration::from_millis(1_100));
        assert!(!marker.exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn timeout_does_not_join_a_reader_held_open_by_an_escaped_descendant() {
        let dir = temp_dir();
        let check = script(
            &dir,
            "daemonizes",
            "/usr/bin/perl -MPOSIX=setsid -e 'if (fork) { sleep 30 } else { setsid(); sleep 1 }'",
        );
        let started = Instant::now();
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_millis(40),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        assert!(started.elapsed() < Duration::from_millis(500));
        thread::sleep(Duration::from_millis(1_100));
        fs::remove_dir_all(dir).unwrap();
    }
}
