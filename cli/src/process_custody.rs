//! The physical half of durable process custody (spec art_6817803a rev6 §B4/§B5, owner
//! ruling att_9b99f366).
//!
//! An internal, closed-purpose helper. The gateway's stop and reconcile workers invoke it
//! for a managed row whose recorded host IS the executing gateway host; it never appears in
//! the CLI's help or its surface contract, and it takes no command to run — it takes an
//! identity to prove and one of two fixed actions.
//!
//! WHY IT EXISTS AT ALL. Elixir cannot `killpg`, and the durable record on its own cannot
//! tell a running ceremony from one that died an hour ago. Something has to look. The
//! danger in looking is that every cheap way to identify a process is a lie waiting to
//! happen: a pid is reused within minutes on a busy host, a process group id is reused with
//! it, and argv is whatever the process says it is. Signalling on any of those means
//! eventually signalling somebody else's process with this row's authority.
//!
//! So the helper proves ownership before it acts, from an artifact the broker wrote at
//! launch, and the proof is all-or-nothing: process id, pid, process group, boot identity
//! and launch token must ALL match the row, and the machine's CURRENT boot identity must
//! match the recorded one. A partial match is `identity_unknown` — never a near-enough,
//! never a signal.

use std::fs;
use std::path::Path;

use crate::harness_process;

/// What the helper is being asked to do. There is no third option and no free-form
/// argument: this is the whole closed set of physical actions custody has (§B4).
enum Action {
    /// Look, and do not touch. Reconcile's evidence.
    Probe,
    /// The bounded TERM-then-KILL the ceremony runner already uses.
    Stop,
}

/// Everything the row claims about the process, which the artifact must corroborate.
struct Expected {
    process_id: String,
    os_pid: libc::pid_t,
    process_group_id: libc::pid_t,
    boot_identity: String,
    launch_token: String,
}

const USAGE: &str = "usage: tightbeam process-custody (probe|stop) <identity-path> \
                     <processId> <osPid> <processGroupId> <bootIdentity> <launchToken>";

/// Verdicts, spelled exactly as the gateway's stop-outcome vocabulary spells them.
///
/// They are printed on stdout and nothing else is, so the caller parses one line rather
/// than scraping. `identity_unknown` deliberately reads the same for an absent artifact, a
/// mismatched one, and a rebooted host: from the row's side those are one fact — this
/// helper could not prove the process is ours — and collapsing them here keeps the caller
/// from inventing a distinction it cannot act on differently.
const GONE: &str = "gone";
const PRESENT: &str = "present";
const IDENTITY_UNKNOWN: &str = "identity_unknown";

/// Stop's verdicts. The ruling names these `gone`, `signaled`, `failed` and
/// `identity_unknown`; `gone` is reported here as either `exited` or `killed` because the
/// durable state set it feeds already draws that line, and collapsing it would make the
/// gateway guess which of two reviewed states to write. Everything else is one-to-one.
const EXITED: &str = "exited";
const KILLED: &str = "killed";
const FAILED: &str = "failed";

pub fn run(args: &[String]) -> Result<i32, String> {
    if args.len() != 7 {
        return Err(USAGE.to_owned());
    }

    let action = match args[0].as_str() {
        "probe" => Action::Probe,
        "stop" => Action::Stop,
        _ => return Err(USAGE.to_owned()),
    };

    let expected = Expected {
        process_id: args[2].clone(),
        os_pid: parse_id(&args[3], "osPid")?,
        process_group_id: parse_id(&args[4], "processGroupId")?,
        boot_identity: args[5].clone(),
        launch_token: args[6].clone(),
    };

    println!("{}", decide(action, Path::new(&args[1]), &expected)?);
    Ok(0)
}

/// The whole decision, separated from printing it.
///
/// Split out so a test can assert BOTH the verdict and what happened to a real process --
/// the pair is the actual contract. "Answered identity_unknown" is worth little on its own;
/// "answered identity_unknown AND the process is still running" is the guarantee.
fn decide(action: Action, path: &Path, expected: &Expected) -> Result<&'static str, String> {
    // The proof comes first, unconditionally, for both actions. There is no path through
    // this function that touches the process before this check has passed.
    if !identity_proven(path, expected)? {
        return Ok(IDENTITY_UNKNOWN);
    }

    match action {
        Action::Probe => Ok(if alive(expected.os_pid) {
            PRESENT
        } else {
            GONE
        }),
        Action::Stop => stop_group(expected.process_group_id, expected.os_pid),
    }
}

fn parse_id(value: &str, field: &str) -> Result<libc::pid_t, String> {
    value
        .parse::<i32>()
        .ok()
        .filter(|id| *id > 0)
        .ok_or_else(|| format!("{field} must be a positive integer"))
}

/// Does the artifact corroborate everything the row claims, on this boot?
///
/// Every failure answers `false` rather than an error, because they are the same fact to
/// the caller: not proven. An unreadable file, a truncated one, a mismatched field and a
/// rebooted machine all mean the helper must not touch anything.
fn identity_proven(path: &Path, expected: &Expected) -> Result<bool, String> {
    let Ok(recorded) = fs::read_to_string(path) else {
        return Ok(false);
    };

    let fields = recorded.trim_end().split('\t').collect::<Vec<_>>();
    if fields.len() != 5 {
        return Ok(false);
    }

    // A pid cannot survive a reboot, so a recorded boot identity that is not this boot's
    // means the number in the row now belongs to whatever the kernel handed it out to
    // next. Asked from the same implementation that wrote it, never a reimplementation
    // that could drift by a field.
    if harness_process::boot_identity()? != expected.boot_identity {
        return Ok(false);
    }

    Ok(fields[0] == expected.process_id
        && fields[1] == expected.os_pid.to_string()
        && fields[2] == expected.process_group_id.to_string()
        && fields[3] == expected.boot_identity
        && fields[4] == expected.launch_token)
}

/// `kill -0`: is there still a process wearing this pid?
///
/// Only ever asked AFTER the identity is proven. On its own this question is worthless —
/// it answers yes for a recycled pid belonging to somebody else entirely — which is why
/// the ruling names it as the last step and not the test.
///
/// A ZOMBIE answers yes. A child that has died but whose parent has not yet reaped it is
/// still a pid the kernel will accept a signal for, so a stop that lands in that window
/// reports `failed` for a process that is in every practical sense gone. That is the safe
/// direction and is left as it is: the wrong answer here is unresolved, which a later
/// reconcile repairs once the entry is reaped, whereas the opposite error would be a
/// terminal `gone` for something still running. Never trade a false unresolved for a
/// false terminal.
fn alive(pid: libc::pid_t) -> bool {
    // SAFETY: signal 0 performs the permission and existence check without delivering.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// TERM the proven group, give it the same grace the ceremony runner gives, then KILL.
///
/// Reports what it OBSERVED, not what it attempted: `gone` only when the leader stopped
/// answering `kill -0`, and `signaled` when the signals were delivered but something is
/// still there. A stop that says `gone` without looking is the false terminal liveness this
/// whole design exists to refuse.
fn stop_group(pgid: libc::pid_t, pid: libc::pid_t) -> Result<&'static str, String> {
    // Nothing to signal and nothing alive: it ended on its own before we asked. Reported
    // as `exited` rather than `killed` because this stop did not end it, and a record
    // saying otherwise would credit us with a death we did not cause.
    let term = signal_group(pgid, libc::SIGTERM)?;
    if !term && !alive(pid) {
        return Ok(EXITED);
    }

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while std::time::Instant::now() < deadline {
        if !alive(pid) {
            return Ok(KILLED);
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }

    signal_group(pgid, libc::SIGKILL)?;

    // One last look. The group had its grace and then a KILL; whether that worked is a
    // question for the kernel, not an assumption.
    if alive(pid) { Ok(FAILED) } else { Ok(KILLED) }
}

/// Deliver a signal to the proven group. `false` means the group was already empty.
///
/// ESRCH is "nothing there to signal", which is success for a stop. Darwin additionally
/// answers EPERM once every member has exited — read that way ONLY here, after ownership is
/// proven, because on linux EPERM means somebody else's group and must stay an error. The
/// same asymmetry is carried in `child_process.rs` and `harness_process.rs` for the same
/// reason.
fn signal_group(pgid: libc::pid_t, signal: libc::c_int) -> Result<bool, String> {
    // SAFETY: signalling a process group this helper has proven belongs to its row.
    if unsafe { libc::killpg(pgid, signal) } == 0 {
        return Ok(true);
    }

    let error = std::io::Error::last_os_error();
    let already_gone = error.raw_os_error() == Some(libc::ESRCH)
        || (cfg!(target_os = "macos") && error.raw_os_error() == Some(libc::EPERM));

    if already_gone {
        Ok(false)
    } else {
        Err(format!(
            "process group {pgid} could not be signalled: {error}"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn artifact(dir: &Path, fields: &str) -> std::path::PathBuf {
        fs::create_dir_all(dir).unwrap();
        let path = dir.join("identity");
        let mut file = fs::File::create(&path).unwrap();
        file.write_all(fields.as_bytes()).unwrap();
        path
    }

    fn temp(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "tightbeam-custody-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ))
    }

    fn expected(boot: &str) -> Expected {
        Expected {
            process_id: "mp_1".to_owned(),
            os_pid: 4242,
            process_group_id: 4242,
            boot_identity: boot.to_owned(),
            launch_token: "tok_1".to_owned(),
        }
    }

    fn this_boot() -> String {
        harness_process::boot_identity().unwrap()
    }

    /// Real children, because the guarantee is about processes and not about strings.
    ///
    /// A group leader of its own, exactly as a custodied ceremony child is: `stop_group`
    /// signals the GROUP, so a test whose child shared the runner's group would either
    /// prove nothing or kill the test binary.
    fn spawn_leader() -> std::process::Child {
        use std::os::unix::process::CommandExt;
        let mut command = std::process::Command::new("sleep");
        command.arg("30");
        // SAFETY: setpgid in the child between fork and exec; touches nothing else.
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        command.spawn().expect("sleep spawns")
    }

    fn expected_for(child: &std::process::Child, boot: &str) -> Expected {
        Expected {
            process_id: "mp_live".to_owned(),
            os_pid: child.id() as libc::pid_t,
            process_group_id: child.id() as libc::pid_t,
            boot_identity: boot.to_owned(),
            launch_token: "tok_live".to_owned(),
        }
    }

    fn identity_for(dir: &Path, e: &Expected) -> std::path::PathBuf {
        artifact(
            dir,
            &format!(
                "{}\t{}\t{}\t{}\t{}",
                e.process_id, e.os_pid, e.process_group_id, e.boot_identity, e.launch_token
            ),
        )
    }

    #[test]
    fn a_proven_live_process_probes_present_and_stops_killed() {
        let boot = this_boot();
        let dir = temp("live");
        let mut child = spawn_leader();
        let e = expected_for(&child, &boot);
        let path = identity_for(&dir, &e);

        assert_eq!(decide(Action::Probe, &path, &e).unwrap(), PRESENT);

        // Reap from another thread while the stop runs, because in production SOMETHING
        // reaps: the broker if it is alive, init if it is not. Without a reaper the child
        // lingers as a zombie that `kill -0` still answers for, and the helper correctly
        // reports `failed` -- see `alive`. This test is about the ordinary case.
        let pid = e.os_pid;
        let reaper = std::thread::spawn(move || {
            let mut status = 0;
            // SAFETY: waiting on this test's own child.
            unsafe { libc::waitpid(pid, &mut status, 0) };
        });

        assert_eq!(decide(Action::Stop, &path, &e).unwrap(), KILLED);
        reaper.join().expect("reaper joins");

        // The verdict is only half of it: the process must actually be gone.
        assert_eq!(decide(Action::Probe, &path, &e).unwrap(), GONE);
        let _ = child.try_wait();
        let _ = fs::remove_dir_all(&dir);
    }

    /// THE assertion this helper exists for. The artifact does not corroborate the row, so
    /// the answer is identity_unknown -- AND the live process is untouched. A version that
    /// signalled first and checked afterwards would pass every string-only test and would
    /// kill somebody else's process the first time a pid was reused.
    #[test]
    fn an_unproven_identity_is_never_signalled() {
        let boot = this_boot();
        let dir = temp("unproven");
        let mut child = spawn_leader();
        let e = expected_for(&child, &boot);

        // Everything matches except the launch token, which never leaves the broker.
        let path = artifact(
            &dir,
            &format!(
                "mp_live\t{}\t{}\t{boot}\ttok_SOMEONE_ELSE",
                e.os_pid, e.process_group_id
            ),
        );

        assert_eq!(decide(Action::Stop, &path, &e).unwrap(), IDENTITY_UNKNOWN);
        assert!(
            alive(e.os_pid),
            "an unproven identity must not be signalled"
        );

        assert_eq!(decide(Action::Probe, &path, &e).unwrap(), IDENTITY_UNKNOWN);
        assert!(
            alive(e.os_pid),
            "an unproven identity must not even be probed"
        );

        // SAFETY: cleaning up the test's own child.
        unsafe { libc::kill(e.os_pid, libc::SIGKILL) };
        let _ = child.wait();
        let _ = fs::remove_dir_all(&dir);
    }

    /// A ceremony that ended on its own before anyone asked. `exited`, not `killed`: the
    /// record must not credit this stop with a death it did not cause.
    #[test]
    fn a_process_that_already_ended_stops_exited() {
        let boot = this_boot();
        let dir = temp("already");
        let mut child = spawn_leader();
        let e = expected_for(&child, &boot);
        let path = identity_for(&dir, &e);

        // SAFETY: ending the test's own child before the helper looks.
        unsafe { libc::kill(e.os_pid, libc::SIGKILL) };
        let _ = child.wait();

        assert_eq!(decide(Action::Stop, &path, &e).unwrap(), EXITED);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_matching_artifact_on_this_boot_is_proof() {
        let boot = this_boot();
        let dir = temp("match");
        let path = artifact(&dir, &format!("mp_1\t4242\t4242\t{boot}\ttok_1"));
        assert!(identity_proven(&path, &expected(&boot)).unwrap());
        let _ = fs::remove_dir_all(&dir);
    }

    /// The case the whole helper exists for. Everything the row can see is right; only the
    /// token — which never leaves the broker — says this is not our launch.
    #[test]
    fn a_wrong_launch_token_is_not_proof_even_when_every_number_matches() {
        let boot = this_boot();
        let dir = temp("token");
        let path = artifact(&dir, &format!("mp_1\t4242\t4242\t{boot}\ttok_OTHER"));
        assert!(!identity_proven(&path, &expected(&boot)).unwrap());
        let _ = fs::remove_dir_all(&dir);
    }

    /// A reboot hands the same pid to something else, so a recorded boot identity that is
    /// not this boot's can never authorise a signal — however well the numbers line up.
    #[test]
    fn a_different_boot_is_not_proof() {
        let dir = temp("boot");
        let path = artifact(&dir, "mp_1\t4242\t4242\tboot-from-last-week\ttok_1");
        assert!(!identity_proven(&path, &expected("boot-from-last-week")).unwrap());
        let _ = fs::remove_dir_all(&dir);
    }

    /// PID reuse: the artifact is ours and this boot is right, but the row now names a
    /// different number than the one we recorded.
    #[test]
    fn a_pid_that_does_not_match_the_artifact_is_not_proof() {
        let boot = this_boot();
        let dir = temp("pid");
        let path = artifact(&dir, &format!("mp_1\t9999\t9999\t{boot}\ttok_1"));
        assert!(!identity_proven(&path, &expected(&boot)).unwrap());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_absent_artifact_is_not_proof() {
        let boot = this_boot();
        assert!(!identity_proven(Path::new("/nonexistent/identity"), &expected(&boot)).unwrap());
    }

    /// A truncated or garbled file must not be read field-by-field into a partial match.
    #[test]
    fn a_malformed_artifact_is_not_proof() {
        let boot = this_boot();
        let dir = temp("short");
        let path = artifact(&dir, "mp_1\t4242\t4242");
        assert!(!identity_proven(&path, &expected(&boot)).unwrap());
        let _ = fs::remove_dir_all(&dir);
    }

    /// The helper takes no command and never will: neither the verb nor the arity leaves
    /// room for one (§B4 acceptance 18).
    #[test]
    fn there_is_no_action_but_probe_and_stop() {
        let args = |action: &str| {
            [action, "/tmp/x", "mp_1", "1", "1", "boot", "tok"]
                .iter()
                .map(|s| (*s).to_owned())
                .collect::<Vec<_>>()
        };
        assert!(run(&args("exec")).is_err());
        assert!(run(&args("start")).is_err());
        assert!(run(&args("run")).is_err());
    }

    #[test]
    fn a_bad_arity_is_a_usage_refusal_not_a_default() {
        assert!(run(&["probe".to_owned()]).is_err());
    }
}
