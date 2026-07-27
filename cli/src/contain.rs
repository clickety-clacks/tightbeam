use std::fs::File;
use std::io::{self, BufRead, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::Stdio;
use std::thread;
use std::time::{Duration, Instant};

const PASS: i32 = 0;
const SCRIPT_ERROR: i32 = 10;
const SCRIPT_TIMEOUT: i32 = 20;
const CONTAINED_REFUSED: i32 = 30;

// Containment is per-OS; the bands above are not. `probe.rs` puts its per-OS collectors
// behind one seam (`collect_linux` / `collect_darwin`) and this follows that shape, at
// compile time rather than runtime because the mechanisms are syscalls rather than data.
// Every arm applies real containment or refuses — there is no unconfined arm, and a
// platform with no named mechanism fails to compile rather than running a script loose.
// See shared specs tightbeam-containment.md.

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
    // Staging happens before the fork so a containment that cannot be built is a fact
    // this process observes directly, rather than an exit code to be inferred from a
    // helper. No script has been spawned at this point, so the refusal is exact.
    let staged = match platform::stage(&args.profile) {
        Ok(staged) => staged,
        Err(reason) => {
            eprintln!("rail-exec: containment not applied: {reason}");
            return CONTAINED_REFUSED;
        }
    };

    // Load the child's stdin before the child can run. The input is the call the check
    // exists to judge, and a check that legitimately ignores it — a constant deny, an
    // error-path fixture — must not be told it judged nothing. Handing over a live pipe
    // instead made that a RACE against the child's exit: macOS happened to win it,
    // because sandbox-exec's own startup delayed the script, and linux loses it, because
    // there is no helper and the script IS the child. Preloading whatever fits settles it
    // the same way on both, and leaves genuinely undeliverable input still undelivered.
    let (child_stdin, remainder) = match preload_stdin(&input) {
        Ok(loaded) => loaded,
        Err(error) => {
            eprintln!("rail-exec: script input could not be staged: {error}");
            return SCRIPT_ERROR;
        }
    };

    let token = staged.token();
    let mut command = platform::command(&args.profile, &args.script);
    command
        .stdin(Stdio::from(child_stdin))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    unsafe {
        command.pre_exec(move || {
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }

            libc::signal(libc::SIGPIPE, libc::SIG_DFL);
            libc::signal(libc::SIGINT, libc::SIG_DFL);
            libc::signal(libc::SIGTERM, libc::SIG_DFL);

            // Last, in the forked child, so it binds this process and everything it
            // execs. A failure here fails the spawn, which is CONTAINED_REFUSED below.
            platform::impose(token)
        });
    }

    // A failed spawn is read as a refusal on both platforms. On macOS that is exactly what
    // it means; on linux the script is the command, so an unexecutable script would land
    // here too — `rules.ex` refuses a statute whose check script is not an existing
    // executable, so it cannot. Both bands deny the dispatch either way; this errs toward
    // the one that claims less about the script.
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!("rail-exec: containment not applied: {error}");
            return CONTAINED_REFUSED;
        }
    };

    // `spawn` borrows the Command, so it still owns the read end we handed it. Holding
    // that open here would keep the pipe alive after the script exits, and a write to the
    // tail would hang instead of failing — an undeliverable payload has to be observable.
    drop(command);

    // Only a payload too big for the pipe needs a writer at all; anything that fit is
    // already in the child's hands and cannot come undone.
    let stdin_writer = remainder.map(|(mut pipe, rest)| {
        thread::spawn(move || {
            let result = pipe.write_all(&rest);
            drop(pipe);
            result
        })
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
            && stdin_writer
                .as_ref()
                .is_none_or(thread::JoinHandle::is_finished)
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

    let stdin_delivered = match stdin_writer {
        None => true,
        Some(writer) => matches!(writer.join(), Ok(Ok(()))),
    };
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
        // The script never received the call it was supposed to judge, so whatever it
        // exited with is not a verdict on anything. This used to print the child-exit
        // line the substrate parses, with a made-up `1` in it — on this side of the
        // seam, where the substrate has no way to disagree. Say what happened instead;
        // the line the substrate parses is now only ever written when a child exit was
        // actually observed, and its absence classifies as unreported.
        eprintln!("rail-exec: script input undelivered; no child verdict");
        return SCRIPT_ERROR;
    }

    let status = status.expect("child status present when pipe workers finish");

    if status.success() {
        let _ = io::stdout().write_all(&stdout);
        return PASS;
    }

    if platform::refused_after_spawn(status.code(), &stdout, &stderr) {
        return CONTAINED_REFUSED;
    }

    let child_code = status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(1);
    eprintln!("tightbeam rail-exec child exit: {child_code}");
    SCRIPT_ERROR
}

/// Build the child's stdin pipe and push as much of `input` into it as it will hold,
/// before anything is spawned.
///
/// Returns the read end for the child, and the write end plus the unwritten tail when the
/// payload was larger than the pipe's capacity. `None` means every byte is already in the
/// pipe: the child cannot fail to receive it, whether or not it ever reads.
fn preload_stdin(input: &[u8]) -> io::Result<(OwnedFd, Option<(File, Vec<u8>)>)> {
    let mut ends = [0 as libc::c_int; 2];

    if unsafe { libc::pipe(ends.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }

    let read = unsafe { OwnedFd::from_raw_fd(ends[0]) };
    let write = unsafe { OwnedFd::from_raw_fd(ends[1]) };

    // The write end must not survive into the child: its own copy would hold the pipe
    // open and the script's read would never see EOF. The read end is dup2'd onto fd 0 by
    // the spawn, which clears the flag there.
    for end in [read.as_raw_fd(), write.as_raw_fd()] {
        if unsafe { libc::fcntl(end, libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
            return Err(io::Error::last_os_error());
        }
    }

    // Non-blocking, so a payload past the pipe's capacity stops here instead of
    // deadlocking against a child that does not exist yet.
    if unsafe { libc::fcntl(write.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }

    let mut loaded = 0;

    while loaded < input.len() {
        let wrote = unsafe {
            libc::write(
                write.as_raw_fd(),
                input[loaded..].as_ptr().cast(),
                input.len() - loaded,
            )
        };

        if wrote <= 0 {
            break;
        }

        loaded += wrote as usize;
    }

    if loaded == input.len() {
        // Dropping the write end here is what lets the child see EOF.
        return Ok((read, None));
    }

    if unsafe { libc::fcntl(write.as_raw_fd(), libc::F_SETFL, 0) } == -1 {
        return Err(io::Error::last_os_error());
    }

    Ok((read, Some((File::from(write), input[loaded..].to_vec()))))
}

#[cfg(target_os = "macos")]
mod platform {
    use std::io;
    use std::process::Command;

    /// Seatbelt is applied by a helper binary, so there is nothing for this process to
    /// hold between staging and exec.
    pub type Token = ();

    pub struct Staged;

    impl Staged {
        pub fn token(&self) -> Token {}
    }

    /// `sandbox-exec` is the only thing that can judge an SBPL profile, and it does that
    /// after it is spawned — so staging cannot fail here and refusal is detected by
    /// `refused_after_spawn`. Landlock has the better shape; this is the cost of the
    /// helper-binary one.
    pub fn stage(_profile: &str) -> Result<Staged, String> {
        Ok(Staged)
    }

    pub fn command(profile: &str, script: &str) -> Command {
        let mut command = Command::new("/usr/bin/sandbox-exec");
        command.arg("-p").arg(profile).arg("--").arg(script);
        command
    }

    pub fn impose(_token: Token) -> io::Result<()> {
        Ok(())
    }

    /// `sandbox-exec` exits 65 with a `sandbox-exec:` stderr prefix and no stdout when it
    /// cannot apply a profile. Sniffing that is indirect, and stays confined here.
    pub fn refused_after_spawn(code: Option<i32>, stdout: &[u8], stderr: &[u8]) -> bool {
        code == Some(65) && stdout.is_empty() && stderr.starts_with(b"sandbox-exec:")
    }

    #[cfg(test)]
    pub mod test_support {
        use std::path::Path;

        pub fn permissive_profile() -> String {
            "(version 1)\n(allow default)".to_owned()
        }

        /// The same shape `Tightbeam.Containment.profile/1` renders: deny writes by
        /// default, read and exec anywhere, write only beneath the granted roots.
        pub fn profile_granting(roots: &[&Path]) -> String {
            let grants = roots
                .iter()
                .map(|root| format!("  (subpath \"{}\")", root.display()))
                .collect::<Vec<_>>()
                .join("\n");

            format!(
                "(version 1)\n(deny default)\n(allow file-read*)\n(allow process-fork)\n\
                 (allow process-exec)\n(allow signal (target self))\n(allow mach-lookup)\n\
                 (allow sysctl-read)\n(allow file-write*\n{grants})\n"
            )
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::ffi::CString;
    use std::io;
    use std::mem::size_of;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
    use std::process::Command;

    const CREATE_RULESET: libc::c_long = 444;
    const ADD_RULE: libc::c_long = 445;
    const RESTRICT_SELF: libc::c_long = 446;
    const CREATE_RULESET_VERSION: usize = 1;
    const RULE_PATH_BENEATH: usize = 1;

    // The write-shaped filesystem rights, ABI 1. Read, directory-read, and execute rights
    // are deliberately NOT handled, which leaves them unrestricted everywhere — the linux
    // expression of the profile's `(allow file-read*)` and `(allow process-exec)`. Network
    // access is likewise unhandled, expressing the v1 open-egress posture.
    const WRITE_FILE: u64 = 1 << 1;
    const REMOVE_DIR: u64 = 1 << 4;
    const REMOVE_FILE: u64 = 1 << 5;
    const MAKE_CHAR: u64 = 1 << 6;
    const MAKE_DIR: u64 = 1 << 7;
    const MAKE_REG: u64 = 1 << 8;
    const MAKE_SOCK: u64 = 1 << 9;
    const MAKE_FIFO: u64 = 1 << 10;
    const MAKE_BLOCK: u64 = 1 << 11;
    const MAKE_SYM: u64 = 1 << 12;
    // ABI 2. Handled so renames and links WITHIN a granted root work; left unhandled,
    // Landlock denies every cross-directory rename, which macOS does not.
    const REFER: u64 = 1 << 13;
    // ABI 3. Without it `truncate(2)` is unrestricted, so a contained process could zero
    // any file it can reach — a write outside its write roots, which is the guarantee.
    const TRUNCATE: u64 = 1 << 14;

    /// Every write-shaped right this seam handles. It is a CONSTANT, not a function of the
    /// running ABI, and that is the invariant: the highest right here (`TRUNCATE`, ABI 3)
    /// is exactly the floor, so every accepted kernel enforces IDENTICALLY. There is no
    /// "use more when offered, mask when not" — masking a write-shaped right would mean
    /// two accepted kernels with two different write walls, which is the platform-legible
    /// difference the spec forbids, one level down.
    ///
    /// Adding a right above the floor is therefore not a local edit: it needs a decision
    /// entry and a named policy for hosts that cannot enforce it (raise the floor, or
    /// surface the gap). Do not quietly `if abi >= N` it in here.
    const HANDLED_WRITE_RIGHTS: u64 = WRITE_FILE
        | REMOVE_DIR
        | REMOVE_FILE
        | MAKE_CHAR
        | MAKE_DIR
        | MAKE_REG
        | MAKE_SOCK
        | MAKE_FIFO
        | MAKE_BLOCK
        | MAKE_SYM
        | REFER
        | TRUNCATE;

    /// The handled rights that mean anything on a NON-directory. Landlock rejects a
    /// directory-only right (the `MAKE_*`/`REMOVE_*`/`REFER` family) against a file fd with
    /// EINVAL, so granting `/dev/null` the full set refused the entire seam — every rail on
    /// linux went CONTAINED_REFUSED. Rails grant `/dev/null`, so this is the production
    /// shape and not a corner case.
    ///
    /// This masks by the TARGET'S TYPE, which is a property of the path and identical on
    /// every accepted kernel. It is not the by-ABI masking `HANDLED_WRITE_RIGHTS` exists to
    /// forbid: no two accepted kernels get different walls because of it.
    const FILE_WRITE_RIGHTS: u64 = WRITE_FILE | TRUNCATE;

    /// A kernel below this cannot restrict `truncate(2)` and therefore cannot deliver the
    /// guarantee, so it refuses rather than under-enforcing. ABI 3 is kernel 6.2.
    const MIN_ABI: libc::c_long = 3;

    #[repr(C)]
    struct RulesetAttr {
        handled_access_fs: u64,
    }

    #[repr(C, packed)]
    struct PathBeneathAttr {
        allowed_access: u64,
        parent_fd: RawFd,
    }

    /// The staged ruleset's descriptor. `fork` copies the descriptor table, so the child
    /// keeps its own reference and the parent is free to drop this afterwards.
    pub type Token = RawFd;

    pub struct Staged {
        ruleset: OwnedFd,
    }

    impl Staged {
        pub fn token(&self) -> Token {
            self.ruleset.as_raw_fd()
        }
    }

    /// Build the ruleset in the parent, before the fork: allocation and path opening do
    /// not belong in `pre_exec`, and every way this can fail is a refusal we would rather
    /// discover while nothing has been spawned.
    pub fn stage(profile: &str) -> Result<Staged, String> {
        let roots = parse_profile(profile)?;
        let handled = rights_for_abi(probe_abi()?)?;
        let ruleset = create_ruleset(handled)?;

        for root in &roots {
            grant(&ruleset, root, handled)?;
        }

        Ok(Staged { ruleset })
    }

    /// No helper binary: the script is the child, so it is also the process-group leader —
    /// the same shape macOS has under `sandbox-exec`, with one less process in it.
    pub fn command(_profile: &str, script: &str) -> Command {
        Command::new(script)
    }

    pub fn impose(token: Token) -> io::Result<()> {
        // Landlock requires no_new_privs so a restricted process cannot escape through a
        // setuid binary.
        if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
            return Err(io::Error::last_os_error());
        }

        if unsafe { libc::syscall(RESTRICT_SELF, token, 0usize) } != 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(())
    }

    /// Nothing to sniff: on this platform a containment failure is always observed before
    /// or during spawn, never inferred from the child's exit.
    pub fn refused_after_spawn(_code: Option<i32>, _stdout: &[u8], _stderr: &[u8]) -> bool {
        false
    }

    /// Elixir owns which roots are granted; only the encoding is per-OS. An envelope this
    /// cannot read is a refusal, which is why an unparseable profile has the same band on
    /// both platforms.
    fn parse_profile(profile: &str) -> Result<Vec<String>, String> {
        let envelope: serde_json::Value = serde_json::from_str(profile)
            .map_err(|error| format!("profile is not a containment envelope: {error}"))?;

        match envelope
            .get("tightbeam_containment")
            .and_then(serde_json::Value::as_u64)
        {
            Some(1) => {}
            Some(version) => return Err(format!("unknown containment envelope version {version}")),
            None => return Err("profile carries no tightbeam_containment version".to_owned()),
        }

        let roots = envelope
            .get("write_roots")
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| "profile carries no write_roots array".to_owned())?;

        if roots.is_empty() {
            return Err("profile grants no write roots".to_owned());
        }

        roots
            .iter()
            .map(|root| match root.as_str() {
                Some(path) if path.starts_with('/') => Ok(path.to_owned()),
                _ => Err(format!("write root is not an absolute path: {root}")),
            })
            .collect()
    }

    /// The syscall half: what ABI does this kernel report, if it knows Landlock at all?
    fn probe_abi() -> Result<libc::c_long, String> {
        let abi = unsafe {
            libc::syscall(
                CREATE_RULESET,
                std::ptr::null::<RulesetAttr>(),
                0usize,
                CREATE_RULESET_VERSION,
            )
        };

        if abi < 0 {
            return Err(format!(
                "landlock is unavailable on this kernel ({})",
                io::Error::last_os_error()
            ));
        }

        Ok(abi)
    }

    /// The decision half, and deliberately pure: which rights do we handle on a kernel
    /// reporting `abi`, or why is that kernel refused? Split from the syscall so the
    /// refusal can be EXECUTED by a test — nothing in the fleet is old enough to reach it,
    /// and a branch asserted by reading the source is not proof of anything.
    ///
    /// Below the floor there is no set of rights that delivers the guarantee, so there is
    /// no value to return, only a refusal.
    fn rights_for_abi(abi: libc::c_long) -> Result<u64, String> {
        if abi < MIN_ABI {
            return Err(format!(
                "landlock ABI {abi} cannot restrict truncate; ABI {MIN_ABI} (kernel 6.2) is the floor"
            ));
        }

        Ok(HANDLED_WRITE_RIGHTS)
    }

    #[cfg(test)]
    mod floor_tests {
        use super::*;

        // The refusal branch, executed. Until this existed the only band-30 path any test
        // ran was an unreadable profile; a kernel below the floor was asserted by reading
        // the source, which the spec's own standard says is not proof.
        #[test]
        fn a_kernel_below_the_floor_is_refused_and_says_why() {
            for abi in 0..MIN_ABI {
                let refusal = rights_for_abi(abi).expect_err("below the floor must refuse");

                assert!(
                    refusal.contains("floor"),
                    "a refusal has to name the floor: {refusal}"
                );
                assert!(
                    refusal.contains("truncate"),
                    "a refusal has to name what it cannot restrict: {refusal}"
                );
            }
        }

        // Every accepted kernel gets the SAME write wall. Two accepted kernels enforcing
        // differently would be the platform-legible difference the spec forbids, one level
        // down from the OS.
        #[test]
        fn every_accepted_kernel_handles_exactly_the_same_rights() {
            for abi in MIN_ABI..=(MIN_ABI + 8) {
                assert_eq!(rights_for_abi(abi), Ok(HANDLED_WRITE_RIGHTS));
            }

            assert_eq!(
                HANDLED_WRITE_RIGHTS & TRUNCATE,
                TRUNCATE,
                "the floor exists FOR truncate, so truncate must be handled"
            );
        }
    }

    fn create_ruleset(handled: u64) -> Result<OwnedFd, String> {
        let attr = RulesetAttr {
            handled_access_fs: handled,
        };

        let fd = unsafe {
            libc::syscall(
                CREATE_RULESET,
                &attr as *const RulesetAttr,
                size_of::<RulesetAttr>(),
                0usize,
            )
        };

        if fd < 0 {
            return Err(format!(
                "landlock ruleset could not be created ({})",
                io::Error::last_os_error()
            ));
        }

        Ok(unsafe { OwnedFd::from_raw_fd(fd as RawFd) })
    }

    /// A granted root that does not exist is OMITTED rather than refused: Landlock rules
    /// attach to an open directory, while Seatbelt `subpath` rules are prefix matches that
    /// accept a path which is not there yet. Omitting a grant is strictly more restrictive,
    /// so the guarantee is never weakened — only a write macOS would have allowed may be
    /// denied. Rail scratch roots are created before the profile is rendered.
    /// `fstat` is one of the few operations an `O_PATH` descriptor permits, and it answers
    /// the question without reopening the path — so the type we mask against is the type of
    /// the very object the grant attaches to.
    fn is_directory(fd: &OwnedFd, root: &str) -> Result<bool, String> {
        let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };

        if unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) } != 0 {
            return Err(format!(
                "write root {root} could not be stat'd ({})",
                io::Error::last_os_error()
            ));
        }

        Ok(stat.st_mode & libc::S_IFMT == libc::S_IFDIR)
    }

    fn grant(ruleset: &OwnedFd, root: &str, handled: u64) -> Result<(), String> {
        let path = CString::new(root)
            .map_err(|_| format!("write root contains an interior NUL: {root}"))?;

        // O_NOFOLLOW because `validate_roots!/1` proved this path had no symlink component
        // at validation time, and this is the moment the grant is actually attached. If the
        // final component became a symlink in between, ELOOP lands in the error arm below
        // and the run refuses — rather than attaching the wall to whatever it now points at.
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_PATH | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };

        if fd < 0 {
            let error = io::Error::last_os_error();

            if error.raw_os_error() == Some(libc::ENOENT) {
                return Ok(());
            }

            return Err(format!("write root {root} could not be opened: {error}"));
        }

        let parent = unsafe { OwnedFd::from_raw_fd(fd) };

        let allowed = if is_directory(&parent, root)? {
            handled
        } else {
            handled & FILE_WRITE_RIGHTS
        };

        let attr = PathBeneathAttr {
            allowed_access: allowed,
            parent_fd: parent.as_raw_fd(),
        };

        let added = unsafe {
            libc::syscall(
                ADD_RULE,
                ruleset.as_raw_fd(),
                RULE_PATH_BENEATH,
                &attr as *const PathBeneathAttr,
                0usize,
            )
        };

        if added != 0 {
            return Err(format!(
                "write root {root} could not be granted ({})",
                io::Error::last_os_error()
            ));
        }

        Ok(())
    }

    #[cfg(test)]
    pub mod test_support {
        use std::path::Path;

        /// Landlock cannot express "allow everything" other than by granting the write
        /// rights on `/`, so the permissive case still builds and imposes a real ruleset
        /// rather than skipping containment.
        pub fn permissive_profile() -> String {
            profile_granting(&[Path::new("/")])
        }

        pub fn profile_granting(roots: &[&Path]) -> String {
            let grants = roots
                .iter()
                .map(|root| serde_json::Value::from(root.display().to_string()).to_string())
                .collect::<Vec<_>>()
                .join(",");

            format!("{{\"tightbeam_containment\":1,\"write_roots\":[{grants}]}}")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(1);

    // Canonical, because a write root reached through a symlinked ancestor (Darwin's
    // /var -> /private/var) is not the path the kernel checks against on either platform.
    fn temp_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-rail-exec-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        fs::canonicalize(&path).unwrap()
    }

    fn script(dir: &Path, name: &str, body: &str) -> String {
        let path = dir.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions).unwrap();
        path.to_string_lossy().into_owned()
    }

    use platform::test_support::{permissive_profile, profile_granting};

    fn band(profile: String, script_path: String, timeout: Duration) -> i32 {
        run_with_input(
            RailExecArgs {
                profile,
                timeout,
                script: script_path,
            },
            b"{}\n".to_vec(),
        )
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
                timeout: Duration::from_secs(30),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, PASS);
        fs::remove_dir_all(dir).unwrap();
    }

    // The proof obligation this platform owes, executed on this platform: containment is
    // APPLIED and a write outside the granted roots is DENIED. One body, both mechanisms,
    // identical assertions — a rail author cannot tell from a verdict which OS ran it.
    // Asserting that a profile string renders is not proof of anything and never was.
    #[test]
    fn a_write_outside_the_granted_roots_is_denied_and_leaves_nothing_behind() {
        let granted = temp_dir();
        let outside = temp_dir();
        let profile = profile_granting(&[&granted]);

        let inside = granted.join("inside");
        let writes_inside = script(
            &granted,
            "writes-inside",
            &format!("printf ok > '{}'", inside.display()),
        );
        assert_eq!(
            band(profile.clone(), writes_inside, Duration::from_secs(5)),
            PASS
        );
        assert_eq!(fs::read_to_string(&inside).unwrap(), "ok");

        let denied = outside.join("denied");
        let writes_outside = script(
            &granted,
            "writes-outside",
            &format!("printf no > '{}'", denied.display()),
        );
        assert_eq!(
            band(profile.clone(), writes_outside, Duration::from_secs(5)),
            SCRIPT_ERROR
        );
        assert!(!denied.exists(), "a write outside the granted roots landed");

        // A symlink inside a granted root is not a way out of it: both mechanisms check
        // the resolved path, so the escape is denied and the target never appears.
        let escape = granted.join("escape");
        let target = outside.join("through-link");
        std::os::unix::fs::symlink(&target, &escape).unwrap();
        let writes_through_link = script(
            &granted,
            "writes-through-link",
            &format!("printf no > '{}'", escape.display()),
        );
        assert_eq!(
            band(profile, writes_through_link, Duration::from_secs(5)),
            SCRIPT_ERROR
        );
        assert!(!target.exists(), "a symlink escaped the granted roots");

        fs::remove_dir_all(granted).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }

    // Rails grant `/dev/null` — a character device, not a directory — so a non-directory
    // grant is the PRODUCTION shape here, not a corner. Landlock rejects directory-only
    // rights against a file fd with EINVAL, which took every rail on linux to
    // CONTAINED_REFUSED until the rights were masked by target type. A refusal is the safe
    // direction and it still made the seam useless, so it gets a test.
    #[test]
    fn a_grant_on_a_non_directory_is_staged_rather_than_refused() {
        let granted = temp_dir();
        let profile = profile_granting(&[&granted, Path::new("/dev/null")]);
        let check = script(&granted, "writes-to-the-sink", "echo noise >/dev/null");

        assert_eq!(
            band(profile, check, Duration::from_secs(5)),
            PASS,
            "granting a non-directory must not refuse the containment"
        );

        fs::remove_dir_all(granted).unwrap();
    }

    #[test]
    fn profile_apply_failure_has_its_own_band() {
        let dir = temp_dir();
        let check = script(&dir, "never-runs", "exit 0");
        let status = run_with_input(
            RailExecArgs {
                profile: "(version 1) (this-is-invalid)".into(),
                timeout: Duration::from_secs(30),
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
                timeout: Duration::from_secs(30),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_ERROR);
        fs::remove_dir_all(dir).unwrap();
    }

    // A script that exits without reading makes the stdin write fail once the pipe
    // buffer fills, so the check judged nothing. The band is right and always was; what
    // this pins is that the path is reachable at all, since the stderr half of the same
    // fix — no fabricated child-exit line — is asserted end to end in
    // `rail_exec_undelivered_stdin.rs`, where the real binary's real bytes cross the
    // seam the substrate parses.
    #[test]
    fn undelivered_stdin_has_the_script_error_band() {
        let dir = temp_dir();
        let check = script(&dir, "ignores-stdin", "exit 0");
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_secs(5),
                script: check,
            },
            vec![b'x'; 512 * 1024],
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
