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

// WHAT CONTAINMENT IS FOR: keeping agents ON THE RAILS. It is not a defence against a
// malicious agent and it is not a security boundary. A circumvention that requires an
// agent to be deliberately hostile is explicitly out of scope — a standing product
// ruling, not a per-change default. Weigh a hardening by whether it keeps honest work
// inside its lines (parity, correctness, legibility) and decline it when the only story
// that reaches it is malice. Reviewers do not hold this frame and will raise
// security-shaped findings by default; that alone does not make them work.
//
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

/// A human-readable report of what this host's containment mechanism can actually do.
pub fn contain_probe() -> String {
    platform::probe_report()
}

/// Stage an exact profile and report per-root, in this process — so a refusal seen by
/// `rail-exec` can be reproduced against the very profile string it was handed.
pub fn contain_stage(profile: &str) -> String {
    platform::stage_report(profile)
}

/// The OS release string, shared by both platform reports.
fn os_release() -> String {
    let mut uts = unsafe { std::mem::zeroed::<libc::utsname>() };

    if unsafe { libc::uname(&mut uts) } != 0 {
        return format!("uname failed ({})", io::Error::last_os_error());
    }

    let bytes: Vec<u8> = uts
        .release
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();

    String::from_utf8_lossy(&bytes).into_owned()
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

/// Spawn the contained child, retrying only on `ETXTBSY`.
///
/// `execve` returns `ETXTBSY` when the file being executed is open for writing by someone
/// else. It is always transient: it clears the instant the interfering writer closes its
/// fd or execs. The window is real here because a rail script is written and then run —
/// and in a multithreaded parent (cargo's test harness spawns tests across threads) one
/// thread's `fork` inherits the write fd another thread holds on a just-created script,
/// so the exec sees it busy. The production wrapper is single-threaded when it forks, so
/// it does not hit this; retrying is cheap insurance that also covers a substrate that
/// wrote the script from a threaded process. A permanently-busy file exhausts the budget
/// and still refuses — nothing real is masked.
fn spawn_contained(command: &mut std::process::Command) -> io::Result<std::process::Child> {
    const ATTEMPTS: u32 = 40;

    for attempt in 0..ATTEMPTS {
        match command.spawn() {
            Err(error) if error.raw_os_error() == Some(libc::ETXTBSY) && attempt + 1 < ATTEMPTS => {
                thread::sleep(Duration::from_millis(5));
            }
            other => return other,
        }
    }

    unreachable!("the loop returns on the final attempt")
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
    let mut child = match spawn_contained(&mut command) {
        Ok(child) => child,
        Err(error) => {
            // Distinct from the stage-time message above: this is a SPAWN failure with the
            // ruleset already built, so its causes are the OS's (an unexecutable script, a
            // transient resource limit) rather than a containment that could not be
            // constructed. Same band — a dispatch that cannot run its contained check is
            // denied either way — but the two read differently in the log.
            eprintln!("rail-exec: contained child could not be spawned: {error}");
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

    // No band-30 path exists here, on either platform, and that is the invariant: once a
    // child has run, nothing it writes or exits with can mean "the containment refused".
    // Refusal is decided BEFORE the fork — by the linux ruleset build, or by the macOS
    // profile preflight — so it is never inferred from output the judged party controls.
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
    use std::process::{Command, Stdio};

    /// Seatbelt is applied by a helper binary, so there is nothing for this process to
    /// hold between staging and exec.
    pub type Token = ();

    pub struct Staged;

    impl Staged {
        pub fn token(&self) -> Token {}
    }

    /// Judge the profile HERE, before any script exists, by applying it to `/usr/bin/true`.
    ///
    /// `sandbox-exec` announces a refusal with exit 65 plus a `sandbox-exec:` stderr
    /// prefix, and the wrapper used to infer "contained" from that pair. Both halves are
    /// CHILD output, so a rail script could forge them:
    ///
    ///     echo "sandbox-exec: authored" >&2 ; exit 65
    ///
    /// produced band 30 on macOS and band 10 on linux — rail-AUTHORED input deciding the
    /// verdict, and the OS legible from it. Same family as the fabricated child-exit line
    /// (#43): a fact was read off a channel the subject of the judgement controls.
    ///
    /// An SBPL profile's validity does not depend on the command it wraps, so applying it
    /// to `/usr/bin/true` is a faithful test of exactly the thing that can fail — and it is
    /// the same preflight `placement.ex` already runs for adapters. Once it passes, nothing
    /// the child emits can mean "contained", which is precisely the linux posture: refusal
    /// is a fact the wrapper observed before the fork, never one parsed afterwards.
    pub fn stage(profile: &str) -> Result<Staged, String> {
        let preflight = Command::new("/usr/bin/sandbox-exec")
            .arg("-p")
            .arg(profile)
            .arg("--")
            .arg("/usr/bin/true")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output();

        match preflight {
            Ok(output) if output.status.success() => Ok(Staged),
            Ok(output) => Err(format!(
                "sandbox profile was refused: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )),
            Err(error) => Err(format!("sandbox-exec could not be run: {error}")),
        }
    }

    pub fn command(profile: &str, script: &str) -> Command {
        let mut command = Command::new("/usr/bin/sandbox-exec");
        command.arg("-p").arg(profile).arg("--").arg(script);
        command
    }

    pub fn impose(_token: Token) -> io::Result<()> {
        Ok(())
    }

    pub fn probe_report() -> String {
        format!(
            "containment probe\n  os.release: {}\n  mechanism : seatbelt (sandbox-exec)\n  \
             note      : macOS applies SBPL via the helper binary; there is no ABI to report.\n",
            super::os_release()
        )
    }

    pub fn stage_report(_profile: &str) -> String {
        "stage-report is linux-only; macOS applies SBPL via sandbox-exec\n".to_owned()
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

    // openat2(2), and the resolve flag that refuses a symlink ANYWHERE in the path.
    // Landed in 5.6 — well below the ABI-3 (kernel 6.2) floor this seam already demands —
    // so there is no fallback path to audit: a kernel without it cannot pass the floor.
    const OPENAT2: libc::c_long = 437;
    const RESOLVE_NO_SYMLINKS: u64 = 0x04;

    #[repr(C)]
    struct OpenHow {
        flags: u64,
        mode: u64,
        resolve: u64,
    }

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

    /// Landlock validates a rule's rights against the TYPE of the inode it attaches to and
    /// rejects a right the type cannot express with EINVAL, so the mask is per type.
    /// Getting it wrong is not a weakened wall — it is CONTAINED_REFUSED for the whole
    /// seam, which is how rails went dark on linux once `/dev/null` became a rail grant.
    ///
    /// - Directory: everything.
    /// - Regular file: `WRITE_FILE | TRUNCATE` — a regular file can be written and
    ///   truncated.
    /// - Anything else (character/block device, fifo, socket): `WRITE_FILE` only, because
    ///   `TRUNCATE` is MEANINGLESS on them — the VFS never truncates a device, so no
    ///   truncate hook fires and the right cannot affect the wall. `/dev/null` is a
    ///   character device, so this is THE production arm.
    ///
    /// The rejected set is the directory-only `MAKE_*`/`REMOVE_*`/`REFER` family: that, and
    /// only that, is what EINVAL'd on `/dev/null`. `WRITE_FILE | TRUNCATE` is in fact
    /// ACCEPTED on a device by every kernel measured, ABI 4 and ABI 7 alike — an earlier
    /// note here blamed a "strict kernel rejecting TRUNCATE", which the CI probe disproves
    /// (`WRITE_FILE|TRUNCATE -> ok`). Dropping `TRUNCATE` for devices is narrowest-
    /// appropriate, not a compatibility workaround; do not reintroduce it looking for one.
    ///
    /// This masks by the target's TYPE, a property of the path, not by ABI. Two accepted
    /// kernels still get the same wall for the same path; it is not the by-ABI masking
    /// `HANDLED_WRITE_RIGHTS` forbids.
    const REGULAR_FILE_WRITE_RIGHTS: u64 = WRITE_FILE | TRUNCATE;
    const SPECIAL_FILE_WRITE_RIGHTS: u64 = WRITE_FILE;

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

    /// Print exactly what this kernel does, right down to which individual right a device
    /// grant accepts — so a CI runner's EINVAL is diagnosed from its own output rather than
    /// inferred from a kernel version. Every line is evidence; nothing here enforces.
    pub fn probe_report() -> String {
        use std::fmt::Write;

        let mut out = String::new();
        let _ = writeln!(out, "containment probe");
        let _ = writeln!(out, "  os.release: {}", super::os_release());
        let _ = writeln!(out, "  mechanism : landlock");

        let abi = match probe_abi() {
            Ok(abi) => {
                let _ = writeln!(out, "  landlock.abi: {abi}");
                abi
            }
            Err(reason) => {
                let _ = writeln!(out, "  landlock.abi: UNAVAILABLE ({reason})");
                return out;
            }
        };

        let _ = match rights_for_abi(abi) {
            Ok(_) => writeln!(out, "  floor      : ABI {MIN_ABI} met"),
            Err(reason) => writeln!(out, "  floor      : REFUSED ({reason})"),
        };

        // KERNEL-CAPABILITY view: which explicit right sets does add_rule accept, by hand,
        // opening WITHOUT O_NOFOLLOW. This says what the kernel can do; it does NOT run the
        // enforcement path's own rights computation.
        for (label, path) in [("directory", "/tmp"), ("device-node", "/dev/null")] {
            let _ = writeln!(out, "  grant[{label}] {path}:");

            let combos: &[(&str, u64)] = &[
                ("HANDLED_WRITE_RIGHTS", HANDLED_WRITE_RIGHTS),
                ("WRITE_FILE|TRUNCATE", REGULAR_FILE_WRITE_RIGHTS),
                ("WRITE_FILE", SPECIAL_FILE_WRITE_RIGHTS),
            ];

            for (name, rights) in combos {
                let result = trace_grant(path, *rights);
                let _ = writeln!(out, "    {name:>22} -> {result}");
            }
        }

        // ENFORCEMENT-PATH view: exactly what `grant` does — open WITH O_NOFOLLOW, fstat,
        // run `allowed_rights_for`, add_rule with the COMPUTED set. If this disagrees with
        // the kernel-capability view above, the bug is in the enforcement computation, not
        // the kernel. This is the line the coordinator asked to make the stage path prove.
        let _ = writeln!(out, "  enforcement-path (what stage actually grants):");
        for path in ["/tmp", "/dev/null"] {
            let _ = writeln!(out, "    {path}: {}", enforcement_trace(path));
        }

        // stage() END-TO-END: the wrapper's actual entry, on multi-root profiles that
        // mirror a real rail profile (a fresh scratch dir + the fixed /dev/null grant). If
        // the single-root trace above succeeds but a multi-root stage refuses, the bug is
        // in accumulating rules on one ruleset, not in any single grant.
        let _ = writeln!(out, "  stage() end-to-end:");
        let scratch = std::env::temp_dir().join(format!("tb-probe-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&scratch);
        let scratch = scratch.display().to_string();

        let profiles: &[(&str, String)] = &[
            ("[/dev/null]", r#"["/dev/null"]"#.to_owned()),
            ("[/tmp,/dev/null]", r#"["/tmp","/dev/null"]"#.to_owned()),
            (
                "[scratch,/dev/null]",
                format!(r#"["{scratch}","/dev/null"]"#),
            ),
        ];
        for (label, roots) in profiles {
            let profile = format!(r#"{{"tightbeam_containment":1,"write_roots":{roots}}}"#);
            let verdict = match stage(&profile) {
                Ok(_) => "ok".to_owned(),
                Err(reason) => format!("REFUSED: {reason}"),
            };
            let _ = writeln!(out, "    {label} -> {verdict}");
        }
        let _ = std::fs::remove_dir_all(&scratch);

        out
    }

    /// Mirror `stage` on an exact profile, reporting each root on the SHARED ruleset the
    /// real path uses — so a `rail-exec` refusal can be reproduced against the very profile
    /// string and root order it was handed. Diagnostic only.
    pub fn stage_report(profile: &str) -> String {
        use std::fmt::Write;

        let mut out = String::new();
        let _ = writeln!(out, "stage-report for: {profile}");

        let roots = match parse_profile(profile) {
            Ok(roots) => roots,
            Err(reason) => {
                let _ = writeln!(out, "  parse failed: {reason}");
                return out;
            }
        };

        let abi = match probe_abi() {
            Ok(abi) => abi,
            Err(reason) => {
                let _ = writeln!(out, "  probe_abi failed: {reason}");
                return out;
            }
        };
        let handled = match rights_for_abi(abi) {
            Ok(handled) => handled,
            Err(reason) => {
                let _ = writeln!(out, "  rights_for_abi failed: {reason}");
                return out;
            }
        };
        let ruleset = match create_ruleset(handled) {
            Ok(ruleset) => ruleset,
            Err(reason) => {
                let _ = writeln!(out, "  create_ruleset failed: {reason}");
                return out;
            }
        };

        // Add each root to the SAME ruleset, in order, exactly as `stage` does.
        for root in &roots {
            let verdict = match grant(&ruleset, root, handled) {
                Ok(()) => "ok".to_owned(),
                Err(reason) => format!("REFUSED: {reason}"),
            };
            let _ = writeln!(out, "  grant {root} -> {verdict}");
        }

        out
    }

    /// Mirror `grant` precisely, reporting the intermediate facts: the symlink-free
    /// resolution, the fstat type, the rights `allowed_rights_for` computes, and the
    /// add_rule verdict for that computed set. Diagnostic only — but it must use the same
    /// resolver as the enforcement path, or it stops being evidence about it.
    fn enforcement_trace(root: &str) -> String {
        let cpath = match CString::new(root) {
            Ok(cpath) => cpath,
            Err(_) => return "path has interior NUL".to_owned(),
        };

        let parent = match open_root_no_symlinks(&cpath) {
            Ok(parent) => parent,
            Err(error) => return format!("openat2(RESOLVE_NO_SYMLINKS) failed: {error}"),
        };

        let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
        if unsafe { libc::fstat(parent.as_raw_fd(), &mut stat) } != 0 {
            return format!("fstat failed: {}", io::Error::last_os_error());
        }
        let ifmt = stat.st_mode & libc::S_IFMT;
        let typename = match ifmt {
            libc::S_IFDIR => "dir",
            libc::S_IFREG => "reg",
            libc::S_IFCHR => "chr",
            libc::S_IFBLK => "blk",
            libc::S_IFLNK => "lnk",
            libc::S_IFIFO => "fifo",
            libc::S_IFSOCK => "sock",
            _ => "other",
        };

        let computed = match allowed_rights_for(&parent, HANDLED_WRITE_RIGHTS, root) {
            Ok(rights) => rights,
            Err(reason) => return format!("st_mode={ifmt:#o}({typename}) rights failed: {reason}"),
        };

        let ruleset = match create_ruleset(HANDLED_WRITE_RIGHTS) {
            Ok(ruleset) => ruleset,
            Err(reason) => return format!("ruleset failed: {reason}"),
        };
        let attr = PathBeneathAttr {
            allowed_access: computed,
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
        let verdict = if added == 0 {
            "ok".to_owned()
        } else {
            format!("EINVAL/err: {}", io::Error::last_os_error())
        };

        format!("st_mode={ifmt:#o}({typename}) computed_rights={computed:#x} add_rule={verdict}")
    }

    /// One isolated ruleset + one add_rule, reporting ok or the errno — the probe's unit of
    /// evidence. Never used on the enforcement path.
    fn trace_grant(path: &str, rights: u64) -> String {
        let ruleset = match create_ruleset(HANDLED_WRITE_RIGHTS) {
            Ok(ruleset) => ruleset,
            Err(reason) => return format!("ruleset failed: {reason}"),
        };

        let cpath = match CString::new(path) {
            Ok(cpath) => cpath,
            Err(_) => return "path has interior NUL".to_owned(),
        };

        let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
        if fd < 0 {
            return format!("open failed: {}", io::Error::last_os_error());
        }
        let parent = unsafe { OwnedFd::from_raw_fd(fd) };

        let attr = PathBeneathAttr {
            allowed_access: rights,
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

        if added == 0 {
            "ok".to_owned()
        } else {
            format!("EINVAL/err: {}", io::Error::last_os_error())
        }
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

    /// Mask `handled` down to the rights valid for the inode `fd` refers to. `fstat` is
    /// one of the few operations an `O_PATH` descriptor permits, so the type we mask
    /// against is the type of the very object the grant attaches to — no reopen, no TOCTOU
    /// window between deciding the type and using the fd.
    fn allowed_rights_for(fd: &OwnedFd, handled: u64, root: &str) -> Result<u64, String> {
        let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };

        if unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) } != 0 {
            return Err(format!(
                "write root {root} could not be stat'd ({})",
                io::Error::last_os_error()
            ));
        }

        let mask = match stat.st_mode & libc::S_IFMT {
            libc::S_IFDIR => handled,
            libc::S_IFREG => REGULAR_FILE_WRITE_RIGHTS,
            _ => SPECIAL_FILE_WRITE_RIGHTS,
        };

        Ok(handled & mask)
    }

    /// A granted root that does not exist is OMITTED rather than refused: Landlock rules
    /// attach to an open path, while Seatbelt `subpath` rules are prefix matches that
    /// accept a path which is not there yet. Omitting a grant is strictly more restrictive,
    /// so the guarantee is never weakened — only a write macOS would have allowed may be
    /// denied. Rail scratch roots are created before the profile is rendered.
    /// Resolve a write root with NO symlink traversal at ANY component.
    ///
    /// `O_NOFOLLOW` was not enough, and the comment that claimed it was is gone with it: it
    /// refuses only a TRAILING symlink, and combined with `O_PATH` it does not even do
    /// that — it hands back a descriptor to the symlink itself. Every INTERMEDIATE
    /// component was still followed, so a directory swapped for a symlink between Elixir's
    /// `validate_components!/1` and this open would attach the wall to a path nobody
    /// authorized, and the contained process would write through it.
    ///
    /// `RESOLVE_NO_SYMLINKS` is the flag that exists for exactly this: the kernel refuses
    /// the whole resolution, atomically, if any component is a symlink. That makes the
    /// wrapper enforce at use-time precisely what Elixir asserted at validation-time,
    /// instead of trusting that nothing moved in between.
    ///
    /// SCOPE NOTE — do not read this as precedent. Reaching the window this closes needs
    /// an agent to deliberately swap a path component mid-run, and deliberate
    /// circumvention is explicitly out of scope (see the module header). It was built
    /// before that ruling was applied, and it stays only because `openat2` is kernel 5.6 —
    /// far below the ABI-3 floor this seam already demands — so it needs no fallback and
    /// carries no ongoing cost. It earns its keep on a second, in-scope ground: the
    /// wrapper now enforces exactly what Elixir validated, so the two halves cannot drift.
    /// A future hardening whose ONLY story is a hostile agent does not get built.
    fn open_root_no_symlinks(path: &CString) -> io::Result<OwnedFd> {
        let how = OpenHow {
            flags: (libc::O_PATH | libc::O_CLOEXEC) as u64,
            mode: 0,
            resolve: RESOLVE_NO_SYMLINKS,
        };

        let fd = unsafe {
            libc::syscall(
                OPENAT2,
                libc::AT_FDCWD,
                path.as_ptr(),
                &how as *const OpenHow,
                size_of::<OpenHow>(),
            )
        };

        if fd < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(unsafe { OwnedFd::from_raw_fd(fd as RawFd) })
    }

    fn grant(ruleset: &OwnedFd, root: &str, handled: u64) -> Result<(), String> {
        let path = CString::new(root)
            .map_err(|_| format!("write root contains an interior NUL: {root}"))?;

        let parent = match open_root_no_symlinks(&path) {
            Ok(parent) => parent,
            Err(error) => {
                if error.raw_os_error() == Some(libc::ENOENT) {
                    return Ok(());
                }

                // ELOOP here is a symlink that was not there at validation time. Refusing is
                // the whole point: the alternative is a wall on an unauthorized path.
                return Err(format!("write root {root} could not be opened: {error}"));
            }
        };
        let allowed = allowed_rights_for(&parent, handled, root)?;

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
    //
    // The timeouts here are a generous CEILING, not a thing under test: the scripts finish
    // in milliseconds and the assertion is the band, so the budget only has to outlast a
    // loaded CI runner scheduling the child. 5s lost that race under parallel `cargo test`.
    //
    // What the ceiling has to beat, MEASURED rather than guessed (#51): the wrapper's whole
    // turnaround on `echo pass` — fork, exec, sandbox-exec, reap, drain three pipes — is
    // 64ms mean idle, and 132ms mean / 308ms worst at 32 spinning hogs on 16 cores. The
    // 1s budgets this replaced were 3x that worst case, which is what produced ~2 failures
    // in 20 runs; 30s is ~100x it. That is the difference between a budget racing the
    // machine and a budget that only trips on a hang, and it is why the number is large
    // and arbitrary rather than tuned — tuning it would put it back in the racing regime.
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
            band(profile.clone(), writes_inside, Duration::from_secs(30)),
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
            band(profile.clone(), writes_outside, Duration::from_secs(30)),
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
            band(profile, writes_through_link, Duration::from_secs(30)),
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
            band(profile, check, Duration::from_secs(30)),
            PASS,
            "granting a non-directory must not refuse the containment"
        );

        fs::remove_dir_all(granted).unwrap();
    }

    // A rail author must not be able to manufacture a containment verdict, nor read the OS
    // off one. This script forges BOTH halves of the signal macOS used to infer refusal
    // from — exit 65 and a `sandbox-exec:` stderr prefix, with empty stdout — and it used
    // to yield band 30 on macOS against band 10 on linux. Same body, same expectation, both
    // platforms: the child ran, so the verdict is the child's, and CONTAINED_REFUSED is not
    // available to it. Refusal is decided before the fork or not at all.
    #[test]
    fn a_child_cannot_forge_a_containment_refusal() {
        let dir = temp_dir();
        let check = script(
            &dir,
            "forges-a-refusal",
            "echo \"sandbox-exec: authored\" >&2\nexit 65",
        );

        let status = band(profile_granting(&[&dir]), check, Duration::from_secs(30));

        assert_eq!(
            status, SCRIPT_ERROR,
            "a child that ran must not be able to claim the containment refused"
        );
        assert_ne!(
            status, CONTAINED_REFUSED,
            "band 30 is the wrapper's to give, never the script's to take"
        );

        fs::remove_dir_all(dir).unwrap();
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
                timeout: Duration::from_secs(30),
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
        let gate = dir.join("gate");
        let forked = dir.join("descendant-forked");
        // `sleep 300`, not `sleep 5`: the leader has to still be hanging when the budget
        // below expires, and that budget is now 8s rather than 40ms.
        let check = script(
            &dir,
            "hangs",
            &format!("{}\nsleep 300", escaped_writer(&marker, &gate, &forked)),
        );
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: DESCENDANT_BUDGET,
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        assert_never_written(&marker, &gate, &forked);
        fs::remove_dir_all(dir).unwrap();
    }

    /// How long the wrapper is given before it times out and kills the group, in the two
    /// tests that need a DESCENDANT to exist by then.
    ///
    /// This is a budget, and it is a budget because there is no way to tell the wrapper
    /// "time out once the descendant is up" — its deadline is fixed at spawn, before the
    /// thing it has to outlast exists. So it is placed outside the racing regime instead
    /// of tuned: /bin/sh reaches the fork at 235ms min / 1214ms median / 1668ms worst,
    /// measured over 20 samples at load1≈55 on 16 cores, and 8s is ~4.8x that worst case.
    /// The 40ms it replaces was 0.03x it, which made both tests vacuous 20 times in 20.
    ///
    /// If this is ever wrong again it can no longer be silent: `assert_never_written`
    /// refuses a run in which the descendant was not forked.
    const DESCENDANT_BUDGET: Duration = Duration::from_secs(8);

    #[test]
    fn timeout_stays_armed_when_the_leader_exits_before_a_descendant() {
        let dir = temp_dir();
        let marker = dir.join("descendant-survived");
        let gate = dir.join("gate");
        let forked = dir.join("descendant-forked");
        let check = script(
            &dir,
            "leader-exits",
            &format!("{}\nexit 0", escaped_writer(&marker, &gate, &forked)),
        );
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: DESCENDANT_BUDGET,
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);
        // The marker carries BOTH claims, which is why no stopwatch appears here. A
        // wrapper that waited for the descendant instead of timing out could only have
        // returned after the descendant began writing — so the absence of any write, right
        // through the window, is the proof that the timeout stayed armed. Timing the return
        // against a fixed 500ms budget proved the same thing by racing a fork and an exec
        // on a loaded runner, and lost (#51).
        assert_never_written(&marker, &gate, &forked);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn timeout_does_not_join_a_reader_held_open_by_an_escaped_descendant() {
        let dir = temp_dir();
        let escaped_pid_path = dir.join("escaped.pid");
        // setsid() takes the child out of the process group, so the wrapper's group kill
        // cannot reach it and it holds the inherited stdout open for far longer than a
        // loaded runner needs to fork, exec and time out. It records its own pid, which is
        // what makes its survival checkable instead of inferred from a stopwatch.
        let check = script(
            &dir,
            "daemonizes",
            &format!(
                "/usr/bin/perl -MPOSIX=setsid -e 'if (fork) {{ sleep 30 }} else {{ setsid(); open(F, \">\", \"{}\") or die; print F POSIX::getpid(); close F; sleep 30 }}'",
                escaped_pid_path.display()
            ),
        );
        // Three quantities have to stay ordered here, and this budget sits in the middle:
        //
        //     escape latency  <  BUDGET  <  descendant lifetime (30s)
        //
        // The left side is why the siblings' 40ms will not do — at 40ms the group kill
        // lands before perl reaches setsid(), nothing escapes to hold the reader open, and
        // the test passes without exercising the seam. The right side is what makes the
        // wrapper time out at all rather than returning when the pipe closes.
        //
        // MEASURED, through this binary with this script (#51): the escape — wrapper spawn,
        // sandbox-exec, perl start, fork, setsid, pid write — is 84ms mean / 320ms worst
        // idle, and 205ms mean / 1219ms WORST while the rest of the suite runs. The 2s this
        // replaces was 1.6x that worst case, and it failed 2 runs in 20 of the full release
        // suite: the kill beat setsid, no descendant escaped, and the pid never arrived.
        // A budget that close to the thing it is racing is the defect #51 filed, which the
        // band tests above escaped by moving to a ceiling three orders of magnitude clear.
        // This one cannot go that far — it is paid in wall time, since the wrapper returns
        // when the budget expires — so 8s buys ~6.5x over the worst observed escape while
        // staying ~4x clear of the descendant's life.
        let status = run_with_input(
            RailExecArgs {
                profile: permissive_profile(),
                timeout: Duration::from_secs(8),
                script: check,
            },
            b"{}\n".to_vec(),
        );
        assert_eq!(status, SCRIPT_TIMEOUT);

        // A wrapper that JOINED the reader thread could only return once the descendant
        // holding it released the pipe — that is, after it exited. The descendant outlives
        // the wrapper's whole budget by 28s, so finding it still alive is that proof, as a
        // state rather than as a deadline: the 500ms budget this replaced was timing a fork
        // and an exec, and lost the race under parallel `cargo test` (#51).
        let escaped = escaped_descendant_pid(&escaped_pid_path);
        assert!(
            alive(escaped),
            "the wrapper waited for the escaped descendant instead of returning"
        );

        unsafe { libc::kill(escaped, libc::SIGKILL) };
        fs::remove_dir_all(dir).unwrap();
    }

    /// A descendant that outlives the wrapper and then writes CONTINUOUSLY — but only
    /// once the test says go.
    ///
    /// The gate replaces a `sleep 1`, and it replaces it because that sleep was TWO fixed
    /// budgets wearing one number. It had to be long enough that a working group kill
    /// landed before the first write (or a correct wrapper fails), and short enough that a
    /// SURVIVOR's first write landed inside whatever window was watching (or a broken
    /// wrapper passes). Both sides were racing the machine, and the second side lost:
    /// MEASURED at 20 samples of this exact shape, spawn-to-first-write is 1118ms mean
    /// 2010ms / WORST 3228ms under load1≈84 on 16 cores (24 spinners plus a from-scratch
    /// `cargo build --release`) — against the 3000ms window below. One sample in 20 wrote
    /// AFTER the window closed, which is a containment failure recorded green.
    ///
    /// Waiting on the gate is not a budget at all, it is a happens-before edge. The test
    /// creates the gate only after the wrapper has RETURNED — that is, after the kill has
    /// been issued and the child reaped — so the kill has unbounded time to land and can
    /// no longer be beaten by a slow one. What the window has to outlast afterwards is not
    /// a sleep but a survivor NOTICING the gate: one 50ms poll plus a fork and a write.
    ///
    /// Bounded rather than infinite on both loops: a survivor is a bug, and a bug should
    /// not leave a shell looping on a shared box forever (#87). The gate wait gives up
    /// after 200 polls, and the write loop after 200 iterations.
    ///
    /// The write loop counts in shell arithmetic rather than `for _ in $(seq 1 200)`
    /// because that command substitution is a fork and an exec standing between the gate
    /// and the first write — the very quantity the window downstream has to beat. Dropping
    /// it moved the measured gate-to-first-write median from 1013ms to 561ms at load1≈80.
    ///
    /// The `forked` marker is written FIRST, before the descendant waits on anything, and
    /// it is what makes the whole test non-vacuous — see `assert_never_written`.
    fn escaped_writer(marker: &Path, gate: &Path, forked: &Path) -> String {
        format!(
            "(echo up > '{}'; n=0; while [ ! -e '{}' ] && [ $n -lt 200 ]; do n=$((n+1)); sleep 0.05; done; \
             w=0; while [ $w -lt 200 ]; do w=$((w+1)); echo survived > '{}'; sleep 0.05; done) &",
            forked.display(),
            gate.display(),
            marker.display()
        )
    }

    /// Assert a write NEVER appears, across a bounded window, rather than looking once
    /// after a fixed nap.
    ///
    /// The nap this replaces slept 1.1s and looked once. Its failure mode was a FALSE
    /// PASS: under parallel `cargo test` the descendant's own sleep landed late, so the
    /// single look happened before the write, the marker was absent, and a containment
    /// failure was recorded green (#86). Polling inverts that — a survivor writes every
    /// 50ms, so any survivor is caught within one interval.
    ///
    /// Three quantities have to stay ordered here, and this window sits on the right:
    ///
    ///     kill latency  <  [gate opens]  <  survivor's notice+write  <  WINDOW
    ///
    /// The left side is no longer timed at all: the gate is written below, after the
    /// wrapper has RETURNED, so the kill has unbounded time to land and a slow kill can no
    /// longer fail a correct wrapper. Only the right side is still a budget.
    ///
    /// What it has to beat, MEASURED rather than guessed (#51), 20 samples of this exact
    /// shape at load1≈80 on 16 cores: gate-to-first-write is 120ms min / 561ms median /
    /// 1620ms WORST. That tail is not the 50ms poll, it is fork-and-exec of `sleep` under
    /// 5x oversubscription, and it is why this number is 10s and not 2s: 10s is 6.2x the
    /// worst observed, where 3s would be 1.9x — still inside the racing regime.
    ///
    /// For contrast, the shape this replaces made the window race a `sleep 1` in the
    /// descendant, whose spawn-to-first-write measured 1118ms min / 2010ms mean / 3228ms
    /// WORST at load1≈84 against a 3000ms window — 0.93x, and one sample in 20 landed
    /// outside it. A survivor missed is a containment failure recorded GREEN, so that
    /// budget never showed as a red run; `cargo test --release` passed 5 of 5 while it was
    /// live. Widening alone would not have been enough — the quantity being raced had to
    /// become a small bounded one first.
    fn assert_never_written(marker: &Path, gate: &Path, forked: &Path) {
        // The scenario has to EXIST before its absence means anything. This test spent its
        // life vacuous: with the wrapper's budget at 40ms, the group kill landed before
        // /bin/sh ever reached the `( ... ) &`, so there was no descendant to kill and the
        // test passed on the strength of a descendant that was never born.
        //
        // MEASURED, spawn to the fork actually happening, 20 samples at load1≈55 on 16
        // cores: 235ms min / 1214ms median / 1668ms worst — 20 of 20 samples later than
        // the 40ms budget. Proof that this mattered rather than an inference: regressing
        // the wrapper's `killpg` to a single-child `kill` — the exact defect these two
        // tests exist to catch — left BOTH of them green at 40ms, and at 200ms, and at
        // 500ms. The regression was only caught once the budget reached 800ms idle and
        // 2000ms under load. A test that cannot fail on its own regression is not a
        // budget problem, it is an absent test, so the budget below is now 8s and this
        // assertion refuses to let the vacuous case be silent ever again.
        assert!(
            forked.exists(),
            "the descendant was never forked before the wrapper's kill landed, so this \
             run proved NOTHING about group killing — it is the vacuous pass, not a pass"
        );

        fs::write(gate, b"go").unwrap();

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            assert!(
                !marker.exists(),
                "a descendant survived the group kill and wrote {}",
                marker.display()
            );
            thread::sleep(Duration::from_millis(25));
        }
    }

    // The escaped descendant is beyond the group kill, so its pid file is an event that
    // WILL arrive; wait for the event, and say so plainly if it never does.
    fn escaped_descendant_pid(path: &Path) -> libc::pid_t {
        for _ in 0..2_000 {
            if let Ok(text) = fs::read_to_string(path) {
                if let Ok(pid) = text.trim().parse::<libc::pid_t>() {
                    return pid;
                }
            }
            thread::sleep(Duration::from_millis(5));
        }

        panic!(
            "the escaped descendant never recorded its pid at {}",
            path.display()
        );
    }

    fn alive(pid: libc::pid_t) -> bool {
        unsafe { libc::kill(pid, 0) == 0 }
    }
}
