//! Interactive `setup` and `assimilate` ceremonies.

use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command as ProcessCommand, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::args::{AssimilateArgs, Identity};
use crate::child_process::{
    NonblockingFd, RunError, Supervised, exited_without_reaping, nonblocking,
    reset_sigchld_before_spawn, supervise,
};
use crate::dispatch::{self, Endpoint, RequestSpec};
use crate::harnesses::HarnessCatalog;
use crate::preflight;

/// Read the staging path out of a `begin` phase response.
///
/// The wire is camelCase in BOTH directions: `router.ex`'s `wire_value/1` lower-camelizes
/// every atom key on the way out, so the gateway's `staging_path` (gateway.ex, onboard
/// begin) ships as `stagingPath`. This read used `"staging_path"` and therefore could
/// never match — `onboard` failed with "onboarding did not return a staging path" on
/// every machine, for every provider, before any network call to the provider. The
/// request side was camelCase all along (`asUser`), so only the response read was wrong.
///
/// Split out as a pure function purely so the wire shape can be pinned by a test;
/// `dispatch::send` does its own I/O and cannot be exercised from a unit test.
fn staging_path(ready: &serde_json::Value) -> Result<&str, String> {
    ready
        .get("stagingPath")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "onboarding did not return a staging path".to_owned())
}

fn lease_id(ready: &serde_json::Value) -> Result<&str, String> {
    ready
        .get("leaseId")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "onboarding did not return a lease identity".to_owned())
}

/// How long the gateway's lease on this ceremony runs, read off the same `begin` reply as
/// the staging path (and camelCase for the same reason).
///
/// The ceremony watchdog and the server-side lease must expire together, so the TTL is one
/// fact owned by `production_config` and carried on the wire. A gateway too old to send it
/// falls back to the CLI's own bound rather than running unbounded.
fn lease_timeout(ready: &serde_json::Value) -> Duration {
    ready
        .get("leaseTtlMs")
        .and_then(serde_json::Value::as_u64)
        .map_or(CEREMONY_FALLBACK_TIMEOUT, Duration::from_millis)
}

fn lease_deadline(ready: &serde_json::Value, now: Instant) -> Instant {
    now + lease_timeout(ready)
}

type HarnessLoader<'a> = dyn Fn(&Endpoint, Instant) -> Result<Option<HarnessCatalog>, String> + 'a;

struct Ceremony<'a> {
    endpoint: &'a Endpoint,
    deadline: Instant,
    load_harnesses: &'a HarnessLoader<'a>,
}

#[derive(Debug, PartialEq, Eq)]
struct StageFailure {
    reason: String,
    interrupted: bool,
}

impl From<String> for StageFailure {
    fn from(reason: String) -> Self {
        Self {
            reason,
            interrupted: false,
        }
    }
}

impl From<RunError> for StageFailure {
    fn from(error: RunError) -> Self {
        Self {
            interrupted: error.is_interrupted(),
            reason: error.to_string(),
        }
    }
}

pub fn onboard<S, H>(
    identity: &Identity,
    provider: &str,
    api_key: bool,
    endpoint: &Endpoint,
    send_request: S,
    load_harnesses: H,
) -> Result<(), String>
where
    S: Fn(&Endpoint, &RequestSpec, Option<Instant>) -> Result<Option<serde_json::Value>, String>,
    H: Fn(&Endpoint, Instant) -> Result<Option<HarnessCatalog>, String>,
{
    let kind = if api_key { "apiKey" } else { "subscription" };
    let machine = onboard_machine(
        std::env::var("TIGHTBEAM_MACHINE")
            .ok()
            .filter(|name| !name.is_empty()),
        dispatch::provisioned(),
    )?;
    let begin = dispatch::build_onboard_phase_request(
        identity,
        provider,
        "begin",
        kind,
        machine.as_deref(),
        None,
        None,
    );
    let ready = send_request(endpoint, &begin, None)?;
    let deadline = ready.as_ref().map_or_else(
        || Instant::now() + CEREMONY_FALLBACK_TIMEOUT,
        |ready| lease_deadline(ready, Instant::now()),
    );
    let ceremony = Ceremony {
        endpoint,
        deadline,
        load_harnesses: &load_harnesses,
    };
    let ready = match ready {
        Some(ready) => ready,
        None => {
            let reason = "onboarding did not return a staging path";
            return Err(cancel_after_begin(
                identity,
                provider,
                kind,
                machine.as_deref(),
                None,
                None,
                reason,
                &ceremony,
                &send_request,
            ));
        }
    };
    let lease_id = match lease_id(&ready) {
        Ok(lease_id) => lease_id,
        Err(reason) => {
            return Err(cancel_after_begin(
                identity,
                provider,
                kind,
                machine.as_deref(),
                None,
                None,
                &reason,
                &ceremony,
                &send_request,
            ));
        }
    };
    let staging = match staging_path(&ready) {
        Ok(staging) => staging,
        Err(reason) => {
            return Err(cancel_after_begin(
                identity,
                provider,
                kind,
                machine.as_deref(),
                Some(lease_id),
                None,
                &reason,
                &ceremony,
                &send_request,
            ));
        }
    };

    let staged: Result<(), StageFailure> = if api_key {
        run_api_key_onboarding(provider, staging, machine.as_deref(), &ceremony)
            .map_err(StageFailure::from)
    } else {
        run_provider_onboarding(provider, staging, machine.as_deref(), &ceremony)
    };

    if let Err(failure) = staged {
        let _ = fs::remove_dir_all(staging);
        if failure.interrupted {
            return Err(failure.reason);
        }
        let reason = failure.reason;
        let classified = if reason.contains("unsupported (no subscription)") {
            Some("unsupported_no_subscription")
        } else {
            None
        };
        return Err(cancel_after_begin(
            identity,
            provider,
            kind,
            machine.as_deref(),
            Some(lease_id),
            classified,
            &reason,
            &ceremony,
            &send_request,
        ));
    }

    let finish = dispatch::build_onboard_phase_request(
        identity,
        provider,
        "finish",
        kind,
        machine.as_deref(),
        Some(lease_id),
        None,
    );
    let outcome = match send_request(ceremony.endpoint, &finish, Some(ceremony.deadline)) {
        Ok(reply) => onboarded_outcome(reply),
        Err(reason) => Err(reason),
    };
    match outcome {
        Ok(result) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&result).expect("JSON value serializes")
            );
        }
        Err(reason) => {
            let _ = fs::remove_dir_all(staging);
            return Err(cancel_after_begin(
                identity,
                provider,
                kind,
                machine.as_deref(),
                Some(lease_id),
                None,
                &reason,
                &ceremony,
                &send_request,
            ));
        }
    }
    Ok(())
}

/// The gateway has to SAY it onboarded. A 2xx only says the request arrived.
///
/// This is the artifact check one layer out, and the same mistake it was: an exit code was
/// read as "codex produced a credential", and here a transport success was read as "the
/// gateway installed one". Every 2xx reached `Ok(())`, including a body with no `result`
/// at all -- `dispatch::parse_response` answers `Ok(None)` for that -- so a gateway that
/// returned `{}` would have the CLI report a completed onboarding it had never been told
/// about.
///
/// The current gateway cannot emit that shape; it answers `status: "onboarded"`
/// (gateway.ex:2495) or an error envelope. That is not a reason to skip the check. The CLI
/// and the gateway are versioned and deployed separately -- there is a fleet updater
/// because they drift -- so "the peer would never send that" is a statement about one
/// version of the peer, and the CLI is the half that has to survive meeting another.
///
/// One condition only. No retry, no negotiation, no version sniffing: the CLI either was
/// told the credential is installed, or it was not.
pub(crate) fn onboarded_outcome(reply: Option<serde_json::Value>) -> Result<serde_json::Value, String> {
    let Some(result) = reply else {
        return Err(FINISH_UNCONFIRMED.to_owned());
    };
    match result.get("status").and_then(serde_json::Value::as_str) {
        Some("onboarded") => Ok(result),
        _ => Err(FINISH_UNCONFIRMED.to_owned()),
    }
}

/// Deliberately silent about what the gateway DID send. The reply is unrecognised, so any
/// reading of it here would be a guess printed with the authority of a diagnosis.
const FINISH_UNCONFIRMED: &str =
    "the gateway accepted the finish request but did not confirm the credential was \
     installed: its reply did not say `status: \"onboarded\"`. Nothing about this host's \
     credential can be assumed either way -- run `tightbeam doctor` to see what is \
     actually installed, and re-run the ceremony if it is not there.";

fn cancel_after_begin<S>(
    identity: &Identity,
    provider: &str,
    kind: &str,
    machine: Option<&str>,
    lease_id: Option<&str>,
    classified: Option<&str>,
    reason: &str,
    ceremony: &Ceremony<'_>,
    send_request: &S,
) -> String
where
    S: Fn(&Endpoint, &RequestSpec, Option<Instant>) -> Result<Option<serde_json::Value>, String>,
{
    let cancel = dispatch::build_onboard_phase_request(
        identity, provider, "cancel", kind, machine, lease_id, classified,
    );
    match send_request(ceremony.endpoint, &cancel, Some(ceremony.deadline)) {
        // Matching on a SENTENCE, which makes `dispatch::ceremony_expired`'s wording part
        // of this behaviour rather than part of its presentation. If that string is ever
        // improved, this arm stops matching and the fall-through below drops the cancel
        // failure from the operator's message without failing anything. Both ends are
        // commented; neither is enforced.
        Err(cancel_reason) if cancel_reason.contains("onboarding lease expired") => {
            format!("{reason}; {cancel_reason}")
        }
        _ => reason.to_owned(),
    }
}

/// Which machine this ceremony acts on.
///
/// The gateway defaults an unnamed onboarding machine to its OWN hostname
/// (`gateway.ex`, `params[:machine] || Placement.local_host_name()`). On the gateway host
/// that is right. On a satellite it is a trap: the gateway stages the credential into its
/// own directories while the provider CLI writes into the satellite's, and `finish` then
/// reads an absent file and reports a TOKEN failure -- blaming the credential for what is
/// really a wrong-host error.
///
/// So an unnamed machine is only allowed where it is correct. Everywhere else this
/// REFUSES rather than deriving a name, because the value must match the name
/// `assimilate` registered (`default_assimilate_name`, i.e. the ssh destination minus any
/// user) and that is not necessarily this host's `uname -n`. A guess that misses produces
/// `unknown_host` from the gateway, which tells the operator less than naming the
/// variable does.
fn onboard_machine(
    from_env: Option<String>,
    provisioned: dispatch::Provisioned,
) -> Result<Option<String>, String> {
    if let Some(name) = from_env {
        return Ok(Some(name));
    }
    match provisioned {
        dispatch::Provisioned::GatewayHost => Ok(None),
        dispatch::Provisioned::Satellite {
            machine: Some(name),
        } => Ok(Some(name)),
        dispatch::Provisioned::Satellite { machine: None } => Err(unnamed_machine(
            "this satellite's gateway.json has a URL but does not name this machine; restarting \
             the gateway rewrites it for every registered host",
        )),
        dispatch::Provisioned::Absent => Err(unnamed_machine(
            "there is no gateway.json here, so this machine cannot say what it is \
             registered as",
        )),
    }
}

fn unnamed_machine(because: &str) -> String {
    format!(
        "cannot tell which machine to onboard: {because}. Set TIGHTBEAM_MACHINE to this \
         host's REGISTERED name -- the name given to `tightbeam assimilate`, which \
         defaults to the ssh destination without any user@ prefix -- and re-run. Without \
         it the gateway would onboard ITSELF instead of this machine."
    )
}

/// How long a ceremony may hold the terminal before the watchdog reaps it.
///
/// The gateway's `begin` reply carries the lease TTL it just started, so the CLI bound and
/// the server bound are one fact with one home. This fallback covers only a gateway too old
/// to send the field; a permanent second constant here would drift from `production_config`
/// the first time either side is tuned.
const CEREMONY_FALLBACK_TIMEOUT: Duration = Duration::from_secs(1_800);

/// Hands the controlling terminal to a child's process group, and takes it back on drop.
///
/// A ceremony child must lead its OWN process group so the watchdog can signal the whole
/// tree (`script` -> `claude` -> node) without ever signalling the CLI itself. But a new
/// process group is a BACKGROUND group, and a background process that reads the controlling
/// terminal is stopped with SIGTTIN. Measured under a pty before this was written:
///
///     NEW-PGRP CHILD:   60878 TN   sh -c read x; echo GOT-INPUT
///     SAME-PGRP CHILD:  read succeeded, GOT-INPUT printed
///
/// State T. A watchdog built the obvious way parks the ceremony against the terminal --
/// manufacturing exactly the orphan it exists to reap. Handing the terminal over is what
/// keeps an interactive ceremony interactive.
struct TerminalHandoff {
    fd: libc::c_int,
    previous: libc::pid_t,
}

impl TerminalHandoff {
    fn to(pgid: libc::pid_t) -> Option<Self> {
        let fd = libc::STDIN_FILENO;
        // Not a tty (piped, or a test): there is no terminal to hand over, and
        // tcsetpgrp would fail. The watchdog still works; nothing can SIGTTIN.
        if unsafe { libc::isatty(fd) } != 1 {
            return None;
        }
        let previous = unsafe { libc::tcgetpgrp(fd) };
        if previous < 0 {
            return None;
        }
        set_terminal_group(fd, pgid).then_some(Self { fd, previous })
    }
}

impl Drop for TerminalHandoff {
    fn drop(&mut self) {
        set_terminal_group(self.fd, self.previous);
    }
}

/// SIGTTOU is ignored across the call because the RESTORE is issued by this process after
/// it has become a background process -- and tcsetpgrp from a background process raises
/// SIGTTOU at itself, whose default action stops it. Without this the CLI is stopped by its
/// own cleanup.
fn set_terminal_group(fd: libc::c_int, pgid: libc::pid_t) -> bool {
    unsafe {
        let saved = libc::signal(libc::SIGTTOU, libc::SIG_IGN);
        let moved = libc::tcsetpgrp(fd, pgid) == 0;
        libc::signal(libc::SIGTTOU, saved);
        moved
    }
}

/// Run an interactive ceremony bounded by `deadline`, terminating its whole process group if
/// it outlives that. `what` names the ceremony in the expiry error: "lease expired" alone does
/// not tell an operator which process was killed on their terminal.
///
/// codex self-limits its device-auth at 15 minutes. `claude setup-token` does not, and an
/// abandoned one was found alive after two days against a deleted binary -- that asymmetry
/// is why this wrapper exists rather than trusting the vendor CLIs.
/// `stdin` is written to the child and the pipe closed immediately: a ceremony
/// that consumes a secret must read it from a pipe, never from argv, and a child
/// that reads to EOF deadlocks against a pipe left open. `None` leaves stdin
/// exactly as the caller configured it -- the interactive ceremonies inherit the
/// terminal and must keep doing so.
fn run_bounded(
    command: ProcessCommand,
    what: &str,
    deadline: Instant,
    stdin: Option<&[u8]>,
) -> Result<ExitStatus, String> {
    run_bounded_inner(command, what, deadline, stdin, None).map_err(|error| error.to_string())
}

/// Run a ceremony that reports a URL, MIRRORING its output to the operator.
///
/// The mirror is only ever pointed at a stream this process does not read a credential
/// out of. `codex login --device-auth` delivers its credential into `CODEX_HOME`, and
/// nothing here parses its output for one; what the operator needs from it -- the device
/// code and the verification URL -- is only visible if it is shown. Where the credential
/// DOES travel over the child's own output, capture and mirror are mutually exclusive and
/// the mirror loses: see [`crate::pty::run`], which returns a transcript and writes not
/// one child byte to the terminal.
fn run_bounded_reporting_url(
    command: ProcessCommand,
    what: &str,
    deadline: Instant,
) -> Result<ExitStatus, RunError> {
    run_bounded_inner(command, what, deadline, None, Some(libc::STDOUT_FILENO))
}

fn run_bounded_inner(
    mut command: ProcessCommand,
    what: &str,
    deadline: Instant,
    stdin: Option<&[u8]>,
    url_output_fd: Option<libc::c_int>,
) -> Result<ExitStatus, RunError> {
    if url_output_fd.is_some() {
        command.stdout(Stdio::piped());
    }

    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let (_, status) = supervise(command, what, deadline, |supervised| {
        attend(supervised, stdin, url_output_fd)
    })?;
    Ok(status)
}

/// Feed the child its input, show the operator its output, and wait for it to finish.
///
/// Every way out of here is a returned value, including the setup steps at the top: a
/// child whose stdout cannot be made non-blocking, or whose stdin will not take the key,
/// is terminated by `supervise` rather than left running behind a `?`.
fn attend(
    supervised: &mut Supervised,
    stdin: Option<&[u8]>,
    url_output_fd: Option<libc::c_int>,
) -> Result<(), RunError> {
    let _output_flags = url_output_fd.map(NonblockingFd::new).transpose()?;
    let mut captured_stdout = supervised.child().stdout.take();
    if let Some(stdout) = &captured_stdout {
        nonblocking(stdout.as_raw_fd())?;
    }
    let stdout_fd = captured_stdout.as_ref().map(AsRawFd::as_raw_fd);
    let mut output_eof = captured_stdout.is_none();

    // Set the group on this side too: the child may not have reached its own setpgid yet,
    // and the terminal handoff below needs the group to exist. Both sides racing to set the
    // same value is the standard job-control fix; the redundant call is harmless.
    let pgid = supervised.pgid();
    unsafe {
        libc::setpgid(pgid, pgid);
    }

    let _terminal = TerminalHandoff::to(pgid);

    // The child is in its new (background) group from the instant it execs, but the handoff
    // above cannot happen until after spawn returns. A child that reaches a terminal read
    // inside that window takes SIGTTIN and STOPS -- and once the terminal is its own,
    // nothing would ever CONT it: the ceremony would hang forever holding a lease. One
    // SIGCONT after the handoff closes the window. It is a no-op for a child that never
    // stopped, which is the overwhelmingly common case.
    unsafe {
        libc::killpg(pgid, libc::SIGCONT);
    }

    // AFTER the handoff, so a child stopped against the terminal is running again before
    // anything waits on it to drain a pipe.
    if let Some(bytes) = stdin {
        deliver(supervised, bytes)?;
    }

    let mut output = Vec::new();
    let mut printed_url = None;

    loop {
        if let Some(stdout) = &mut captured_stdout {
            let mut bytes = [0u8; 8192];
            loop {
                if let Some(error) = supervised.interrupted() {
                    return Err(error);
                }
                if let Some(error) = supervised.expired() {
                    return Err(error);
                }
                match stdout.read(&mut bytes) {
                    Ok(0) => {
                        output_eof = true;
                        break;
                    }
                    Ok(count) => {
                        let bytes = &bytes[..count];
                        output.extend_from_slice(bytes);
                        let fd = url_output_fd.expect("a mirrored run has an output fd");
                        supervised.write_all(fd, bytes)?;
                        if let Some(url) = crate::screen::authorization_url(&output)
                            && printed_url.as_deref() != Some(url.as_str())
                        {
                            supervised.write_all(
                                fd,
                                format!("\nAuthorization URL: {url}\n").as_bytes(),
                            )?;
                            printed_url = Some(url);
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error.to_string().into()),
                }
            }
        }

        // Asked before the signal is read, so that a child which exited and a TERM which
        // arrived in the same instant are both known to the same iteration.
        let leader_exited = supervised.exited()?;

        if let Some(error) = supervised.interrupted() {
            return Err(error);
        }

        if leader_exited && output_eof {
            return Ok(());
        }

        if let Some(error) = supervised.expired() {
            return Err(error);
        }

        supervised.wait(stdout_fd.map(|fd| libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        }));
    }
}

/// Hand the child its secret on a pipe, then close it.
///
/// The write is bounded by the lease for the same reason the loop is. A child that never
/// reads -- stopped, wedged, or simply slower than the key is long -- fills the pipe
/// buffer, and a blocking `write_all` there hands it the power to keep this ceremony
/// running for as long as it likes. The pipe closes as this returns: a child reading to
/// EOF deadlocks against one left open.
fn deliver(supervised: &mut Supervised, bytes: &[u8]) -> Result<(), RunError> {
    let what = supervised.what().to_owned();
    let Some(pipe) = supervised.child().stdin.take() else {
        return Err(format!("{what} did not accept stdin").into());
    };
    nonblocking(pipe.as_raw_fd())?;
    supervised.write_all(pipe.as_raw_fd(), bytes)
}

fn run_provider_onboarding(
    provider: &str,
    staging: &str,
    machine: Option<&str>,
    ceremony: &Ceremony<'_>,
) -> Result<(), StageFailure> {
    match provider {
        "openai" => run_openai_onboarding(staging, ceremony),
        "anthropic" => run_anthropic_onboarding(staging, machine, ceremony),
        #[cfg(test)]
        "fixture-provider" => std::fs::write(
            std::path::Path::new(staging).join("fixture.json"),
            "fixture-provider-credential",
        )
        .map_err(|error| StageFailure::from(error.to_string())),
        _ => Err(format!("unsupported provider: {provider}").into()),
    }
}

/// The non-interactive credential ceremony: a key on stdin, one live validation
/// call, then the same staged install the subscription flows use.
///
/// The ORDER is the requirement, not an implementation detail -- validate, then
/// bank. Banking first would leave a host holding a credential nothing has shown
/// to work, and the next thing to discover it would be a turn failing as a model
/// error, which is exactly the masquerade the preflight exists to end.
fn run_api_key_onboarding(
    provider: &str,
    staging: &str,
    machine: Option<&str>,
    ceremony: &Ceremony<'_>,
) -> Result<(), String> {
    let key = read_api_key()?;
    validate_api_key(provider, &key, machine, ceremony.deadline)?;
    match provider {
        "openai" => bank_openai_api_key(staging, &key, ceremony),
        "anthropic" => bank_anthropic_api_key(staging, &key),
        #[cfg(test)]
        "fixture-provider" => fs::write(std::path::Path::new(staging).join("fixture.json"), &key)
            .map_err(|error| error.to_string()),
        _ => Err(format!("unsupported provider: {provider}")),
    }
}

/// Read the key from stdin, and REFUSE a terminal.
///
/// Not a usability choice. A secret typed at a terminal is echoed into that
/// terminal's scrollback and, on most setups, into a scrollback file on disk --
/// a leak this ceremony would be CREATING, not merely permitting. Suppressing
/// the echo is possible but is a second, subtler thing to get right, and this
/// path is non-interactive by design anyway. So the terminal case is refused
/// with the exact command that works, which is also the form codex's own
/// `login --with-api-key` documents.
fn read_api_key() -> Result<String, String> {
    if unsafe { libc::isatty(libc::STDIN_FILENO) } == 1 {
        return Err(api_key_needs_a_pipe());
    }
    read_api_key_from(&mut io::stdin())
}

fn read_api_key_from(reader: &mut impl io::Read) -> Result<String, String> {
    let mut raw = String::new();
    io::Read::read_to_string(reader, &mut raw)
        .map_err(|error| format!("could not read the API key from stdin: {error}"))?;
    let key = raw.trim().to_owned();
    if key.is_empty() {
        return Err("no API key arrived on stdin".to_owned());
    }
    Ok(key)
}

/// Split out so the sentence can be pinned by a test: `read_api_key` calls
/// `isatty` directly and a unit test cannot stub that, but the remedy it prints
/// is the whole value of the refusal. Same shape, and same reason, as
/// `unnamed_machine`.
fn api_key_needs_a_pipe() -> String {
    "--api-key reads the key from stdin and will not read from a terminal, because a key \
     typed at a prompt ends up in your shell scrollback. Pipe it in instead, e.g.\n  \
     printenv ANTHROPIC_API_KEY | tightbeam onboard anthropic --api-key"
        .to_owned()
}

/// One authenticated models call, made from THIS host, before anything is banked.
///
/// Made in-process with the HTTP client the CLI already carries, so the key never
/// reaches a command line -- not even a `curl` invocation this process would
/// spawn, which would put a billing credential in the process table.
///
/// Recorded 2026-07-28 against both routes with deliberately invalid keys:
/// anthropic answers `x-api-key` with 401 "API key is invalid.", and openai
/// answers a bearer key with 401 `invalid_api_key`. The openai result is the
/// load-bearing one: a ChatGPT subscription token is refused from that same route
/// with 403 naming the missing scope `api.model.read`, so the route does
/// distinguish the two kinds. A VALID key has not been exercised against either
/// route from this fleet -- see credential-kinds-v1.
fn validate_api_key(
    provider: &str,
    key: &str,
    machine: Option<&str>,
    deadline: Instant,
) -> Result<(), String> {
    let host = machine.map(str::to_owned).unwrap_or_else(this_host);
    let provider = provider.to_owned();
    let key = key.to_owned();
    validation_before_deadline(deadline, "API-key validation", move |remaining| {
        validate_api_key_with_timeout(&provider, &key, &host, remaining)
    })
}

fn validate_api_key_with_timeout(
    provider: &str,
    key: &str,
    host: &str,
    timeout: Duration,
) -> Result<(), String> {
    let agent = validation_agent(timeout);
    let request = match provider {
        "anthropic" => agent
            .get("https://api.anthropic.com/v1/models?limit=1")
            .set("x-api-key", key)
            .set("anthropic-version", "2023-06-01"),
        "openai" => agent
            .get("https://api.openai.com/v1/models")
            .set("authorization", &format!("Bearer {key}")),
        #[cfg(test)]
        "fixture-provider" => return Ok(()),
        _ => return Err(format!("unsupported provider: {provider}")),
    };

    match request.call() {
        Ok(_response) => Ok(()),
        Err(ureq::Error::Status(status, response)) => {
            let body = match response.into_string() {
                Ok(body) => body,
                Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                    return Err(unvalidated_api_key(provider, &error.to_string(), host));
                }
                Err(_) => "<unreadable response body>".to_owned(),
            };
            Err(format!(
                "the {provider} API key was rejected on {host}: HTTP {status} {}. Nothing was \
                 banked -- the {provider} credential on {host} is unchanged.",
                body.trim()
            ))
        }
        Err(ureq::Error::Transport(error)) => {
            Err(unvalidated_api_key(provider, &error.to_string(), host))
        }
    }
}

/// Let codex write its own `auth.json`.
///
/// `codex login --with-api-key` reads the key from stdin (verified present in
/// codex-cli 0.145.0) and banks it in `CODEX_HOME` in whatever shape that version
/// of codex reads back. Writing that file ourselves would mean guessing at
/// `auth_mode`'s api-key spelling and at which fields codex requires -- a guess
/// that would rot the next time codex ships. The subscription leg already defers
/// to `codex login --device-auth` for exactly this reason.
///
/// Bounded by the same watchdog as every other ceremony child: a new path that
/// spawned an unbounded child would reopen the orphan leak the watchdog closed.
fn bank_openai_api_key(staging: &str, key: &str, ceremony: &Ceremony<'_>) -> Result<(), String> {
    let codex = harness_cli("openai", ceremony)?;
    let mut command = ProcessCommand::new(&codex);
    command
        .args(["login", "--with-api-key"])
        .env("CODEX_HOME", staging)
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    let status = run_bounded(
        command,
        "codex login --with-api-key",
        ceremony.deadline,
        Some(key.as_bytes()),
    )?;

    codex_staged_a_credential(status, staging, "`codex login --with-api-key`")
}

/// The verdict on a codex leg: its exit status AND the file it was supposed to leave
/// behind, because for codex the first does not imply the second.
///
/// Measured against codex-cli 0.146.0: ctrl-c at the device-code prompt exits ZERO and
/// writes nothing. Cancelling is a normal exit for codex -- its own screen offers cancel
/// as the expected move -- so an exit code cannot distinguish "logged in" from "the
/// operator changed their mind". Trusting it staged an empty home, ran on to `finish`, and
/// let the GATEWAY be the first thing to notice: the operator's ctrl-c came back as
/// `device_auth_failed`, a message blaming the device authorization for something they
/// did deliberately. The same misattribution "not captured" used to make on the anthropic
/// side, which is what that leg's refusal reasons exist to prevent.
///
/// The anthropic leg has never had this hole because it validates what it captured before
/// staging it. This is the same check on the same axis. It reads a file rather than making
/// a live call because for openai the credential is codex's to write and ours only to hand
/// on -- so the question here is not "does this credential work" but "is there one".
///
/// The filename is DUPLICATED, not shared, and that is worth knowing before someone
/// changes it. The gateway installs from `auth.json` in the staging directory by writing
/// that literal out twice -- credentials.ex:734 for a local install and :796, reached from
/// :762, for an ssh one -- and neither is reachable from here: `staged_path/2` is `defp`.
/// So this is a third copy of a name three places already hardcode, and the only thing
/// keeping them honest is that they agree. Making it one fact is a real change with its
/// own review, not a comment.
fn codex_staged_a_credential(status: ExitStatus, staging: &str, what: &str) -> Result<(), String> {
    if !status.success() {
        return Err(format!("{what} failed: {status}"));
    }

    let path = std::path::Path::new(staging).join("auth.json");
    let staged = match fs::metadata(&path) {
        Ok(metadata) if metadata.len() > 0 => return Ok(()),
        Ok(_) => "left an empty credential file".to_owned(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => "wrote no credential".to_owned(),
        Err(error) => format!("left a credential this host cannot read ({error})"),
    };

    // Named as the LIKELY cause, not the cause. A cancelled login and a codex that failed
    // while exiting zero are indistinguishable from here, and inventing a way to tell them
    // apart would mean guessing at codex's exit codes -- the thing that produced this bug.
    Err(format!(
        "{what} reported success but {staged} at {}. codex exits zero when a device-code \
         login is cancelled, so the likely cause is that the login was interrupted or \
         declined; a codex failure that also exits zero looks the same from here. Nothing \
         was banked -- the openai credential on this host is unchanged. Re-run the ceremony.",
        path.display()
    ))
}

/// Claude has no equivalent CLI affordance -- it takes its credential from the
/// environment -- so the key is staged directly, under the same filename the
/// subscription ceremony stages, at the same 0600. Everything downstream (the
/// install, the metadata, the home reconcile) is then identical between the two
/// kinds; only the recorded kind differs.
fn bank_anthropic_api_key(staging: &str, key: &str) -> Result<(), String> {
    let path = std::path::Path::new(staging).join("oauth-token");
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .map_err(|error| format!("could not stage the API key at {}: {error}", path.display()))?;
    file.write_all(key.as_bytes())
        .map_err(|error| format!("could not stage the API key at {}: {error}", path.display()))
}

/// The vendor binary a provider's ceremony invokes, checked to be reachable first.
///
/// Both legs used to discover this the hard way. openai exec'd `codex` and surfaced the
/// raw `No such file or directory (os error 2)`, naming nothing. anthropic ran `claude`
/// under script(1), which on linux exits 0 regardless of its child, so a missing claude
/// produced an empty transcript and the message blamed token parsing for a
/// `command not found` that had leaked past incidentally.
///
/// The NAME comes from the harness projection's `cli_binary`, the same field
/// assimilate's probe uses, so a renamed vendor binary follows the catalog rather than
/// this file -- and the name checked here is the name exec'd below, so the two cannot
/// drift apart. The provider-to-harness pairing is not in the projection, so it lives
/// here; it is the pairing `Harness.credential_provider/0` states on the Elixir side.
/// When the catalog cannot be reached the harness's own name is used, which is what both
/// binaries are called today.
fn harness_cli(provider: &str, ceremony: &Ceremony<'_>) -> Result<String, String> {
    let harness = match provider {
        "openai" => "codex",
        "anthropic" => "claude",
        _ => return Err(format!("unsupported provider: {provider}")),
    };
    let binary = (ceremony.load_harnesses)(ceremony.endpoint, ceremony.deadline)?
        .and_then(|catalog| {
            catalog
                .harnesses
                .iter()
                .find(|projection| projection.wire_name == harness)
                .map(|projection| projection.cli_binary.clone())
        })
        .unwrap_or_else(|| harness.to_owned());

    let search_path = search_path();
    require_on_path(
        &binary,
        &search_path,
        &preflight::missing_harness_cli(&binary, harness, &this_host(), &search_path),
    )?;
    Ok(binary)
}

/// The search path is passed in rather than read here, so the check is exercisable
/// without mutating the process environment -- and so a test cannot pass merely because
/// the developer's own machine happens to have the vendor CLI installed.
fn require_on_path(binary: &str, search_path: &str, absent: &str) -> Result<(), String> {
    match preflight::on_path(binary, search_path) {
        Some(_) => Ok(()),
        None => Err(absent.to_owned()),
    }
}

fn search_path() -> String {
    std::env::var("PATH").unwrap_or_default()
}

/// This machine, for a message an operator reads. Not the registered host name -- the
/// refusal is about a PATH on the box in front of them, so its own idea of its name is
/// the useful one.
fn this_host() -> String {
    ProcessCommand::new("uname")
        .arg("-n")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "this machine".to_owned())
}

fn run_openai_onboarding(staging: &str, ceremony: &Ceremony<'_>) -> Result<(), StageFailure> {
    let codex = harness_cli("openai", ceremony).map_err(StageFailure::from)?;
    let mut command = ProcessCommand::new(&codex);
    command
        .args(["login", "--device-auth"])
        .env("CODEX_HOME", staging)
        .stdin(Stdio::inherit())
        .stderr(Stdio::inherit());

    let status = run_bounded_reporting_url(command, "codex device-code login", ceremony.deadline)
        .map_err(StageFailure::from)?;

    codex_staged_a_credential(status, staging, "OpenAI device-code onboarding")
        .map_err(StageFailure::from)
}

fn anthropic_setup_token_command(claude: &str) -> ProcessCommand {
    let mut command = ProcessCommand::new(claude);
    command.arg("setup-token");
    command
}

/// The subscription ceremony: `claude setup-token` under a pty, the token read off the
/// replayed screen, one live validation call, then the staged install.
///
/// The ORDER is the requirement, not an implementation detail -- validate, then bank.
/// This path banked first for as long as it existed, and the capture it banks is the
/// one that can silently lose characters (#80): a truncated token has the right prefix
/// and the right alphabet, so it stages, reports `onboarded: true` with a year's expiry,
/// and is discovered a month later as a turn failing with an auth error nobody traces
/// back to onboarding. One authenticated call with the captured bytes is the only thing
/// that can tell a captured token from a captured fragment.
fn run_anthropic_onboarding(
    staging: &str,
    machine: Option<&str>,
    ceremony: &Ceremony<'_>,
) -> Result<(), StageFailure> {
    let claude = harness_cli("anthropic", ceremony).map_err(StageFailure::from)?;
    let output = crate::pty::run(
        anthropic_setup_token_command(&claude),
        "claude setup-token",
        ceremony.deadline,
    )
    .map_err(StageFailure::from)?;
    let status = output.status;
    let raw = output.transcript;

    if !status.success() {
        // Read the SCREEN, not the byte stream. The TUI positions each word with a
        // cursor jump instead of writing the spaces between them, so a phrase is only
        // reliably contiguous once the transcript has been replayed.
        let screen = crate::screen::displayed_lines(&raw).join("\n");
        if screen.to_ascii_lowercase().contains("subscription") {
            return Err("needs_onboarding: unsupported (no subscription)"
                .to_owned()
                .into());
        }
        return Err(format!("Anthropic setup-token onboarding failed: {status}").into());
    }

    let token = match crate::screen::capture_setup_token(&raw) {
        Some(token) => token,
        None => return Err(capture_failed(&raw).into()),
    };
    // A screen that needed interpreting is never interpreted silently: when capture
    // discarded stale repaint cells to reach the token, the operator is told which.
    if let Some(note) = crate::screen::capture_note(&raw) {
        println!("{note}");
    }

    validate_setup_token(&token, machine, ceremony.deadline).map_err(StageFailure::from)?;

    let path = PathBuf::from(staging).join("oauth-token");
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| StageFailure::from(error.to_string()))?;
    writeln!(file, "{token}").map_err(|error| StageFailure::from(error.to_string()))?;

    Ok(())
}

/// The route and headers a SUBSCRIPTION credential is authenticated with.
///
/// Not the api-key path's header. `validate_api_key` sends anthropic `x-api-key`, which
/// a setup-token is not: sending one as the other refuses a perfectly good credential
/// and blames the operator's capture for it. The pairing here is the live one --
/// `Tightbeam.Harness.Claude` routes a subscription credential as `Authorization: Bearer`
/// and an api key as `x-api-key`, against this same models route, on every catalog
/// derivation in production. Recorded rather than reasoned: the two kinds answer with
/// distinguishable 401 bodies, "Invalid bearer token" against a bearer and "API key is
/// invalid." against an x-api-key.
fn subscription_probe(token: &str) -> (&'static str, [(&'static str, String); 2]) {
    (
        "https://api.anthropic.com/v1/models?limit=1",
        [
            ("authorization", format!("Bearer {token}")),
            ("anthropic-version", "2023-06-01".to_owned()),
        ],
    )
}

/// One authenticated call with the CAPTURED bytes, before anything is staged.
///
/// Made in-process, and made exactly once: a 401 on this route is deterministic, so a
/// retry would only spend the operator's time, and a network failure is a different
/// refusal that must not be reported as either a bad capture or a missing subscription.
fn validate_setup_token(
    token: &str,
    machine: Option<&str>,
    deadline: Instant,
) -> Result<(), String> {
    let host = machine.map(str::to_owned).unwrap_or_else(this_host);
    let token = token.to_owned();
    validation_before_deadline(deadline, "setup-token validation", move |remaining| {
        validate_setup_token_with_timeout(&token, &host, remaining)
    })
}

fn validate_setup_token_with_timeout(
    token: &str,
    host: &str,
    timeout: Duration,
) -> Result<(), String> {
    let (url, headers) = subscription_probe(token);
    let agent = validation_agent(timeout);
    let mut request = agent.get(url);
    for (name, value) in &headers {
        request = request.set(name, value);
    }

    match request.call() {
        Ok(_response) => Ok(()),
        Err(ureq::Error::Status(status, response)) => {
            let body = match response.into_string() {
                Ok(body) => body,
                Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                    return Err(unvalidated_setup_token(&error.to_string(), host));
                }
                Err(_) => "<unreadable response body>".to_owned(),
            };
            Err(rejected_setup_token(status, body.trim(), host))
        }
        Err(ureq::Error::Transport(error)) => {
            Err(unvalidated_setup_token(&error.to_string(), host))
        }
    }
}

fn validation_agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(timeout)
        .timeout_connect(timeout)
        .build()
}

fn validation_before_deadline<F>(deadline: Instant, what: &str, work: F) -> Result<(), String>
where
    F: FnOnce(Duration) -> Result<(), String> + Send + 'static,
{
    crate::lease::until(deadline, work).map_err(|()| validation_expired(what))?
}

fn validation_expired(what: &str) -> String {
    format!("{what} refused because the onboarding lease expired; nothing was banked")
}

fn unvalidated_api_key(provider: &str, error: &str, host: &str) -> String {
    format!(
        "could not reach {provider} from {host} to validate the API key: {error}. Nothing \
         was banked -- the {provider} credential on {host} is unchanged."
    )
}

/// The captured token does not work, and CAPTURE is the suspect.
///
/// Deliberately not phrased as a subscription problem: `claude setup-token` only
/// prints a token to an account that has one, so a token that reached this point and
/// was refused is far more likely to be the wrong bytes than the wrong account. It
/// must also not read as `unsupported (no subscription)` -- `onboard` classifies the
/// cancel phase off that exact phrase, and this is not that.
fn rejected_setup_token(status: u16, body: &str, host: &str) -> String {
    format!(
        "the captured Anthropic setup token was rejected on {host}: HTTP {status} {body}. \
         claude prints a token only to an account that has a subscription, so the likely \
         fault is the CAPTURE rather than the account: the token is read off a replayed \
         terminal screen and a truncated read is well-formed. Nothing was banked -- the \
         anthropic credential on {host} is unchanged. Re-run the ceremony."
    )
}

/// Unreachable is not invalid. Neither the capture nor the subscription is implicated,
/// and saying so is the difference between an operator re-running a ceremony and an
/// operator re-authorizing an account that was never the problem.
fn unvalidated_setup_token(error: &str, host: &str) -> String {
    format!(
        "could not reach anthropic from {host} to validate the captured setup token: \
         {error}. The token was NOT validated. Nothing was banked -- the anthropic \
         credential on {host} is unchanged. This is a network failure on {host}, not a \
         verdict on the token or the subscription."
    )
}

/// Say what was looked for without serializing the capture.
///
/// A failed setup-token capture can still contain a valid year-long credential. The old
/// path copied those bytes to `setup-token-failure.log`, turning the most sensitive
/// output of the ceremony into a durable diagnostic. The screen reader explains the
/// shape it found; the bytes themselves stay only in memory and are dropped on refusal.
fn capture_failed(raw: &[u8]) -> String {
    format!(
        "Anthropic setup-token was not captured: claude ran and exited successfully, but \
         {}. Nothing was banked, and the capture was not written to a log because it may \
         contain a live credential.",
        crate::screen::refusal_reason(raw)
    )
}

fn validate_harnesses(harnesses: &[String], catalog: &HarnessCatalog) -> Result<(), String> {
    for harness in harnesses {
        if !catalog.contains(harness) {
            return Err(format!("unsupported harness: {harness}"));
        }
    }
    Ok(())
}

#[derive(Debug)]
struct ExecFailure {
    message: String,
    stdout: String,
    stderr: String,
    status: Option<i32>,
    timed_out: bool,
}

const REMOTE_COMMAND_TIMEOUT: Duration = Duration::from_secs(120);

trait CeremonyIo {
    fn log(&mut self, message: &str);
    fn warn(&mut self, message: &str);
    fn exec(
        &mut self,
        file: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<String, ExecFailure>;
    fn dispatch(&mut self, request: &RequestSpec) -> Result<Option<serde_json::Value>, String>;
    fn current_exe(&self) -> Result<PathBuf, String>;
}

struct SystemIo;

impl CeremonyIo for SystemIo {
    fn log(&mut self, message: &str) {
        println!("{message}");
    }

    fn warn(&mut self, message: &str) {
        eprintln!("{message}");
    }

    fn exec(
        &mut self,
        file: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<String, ExecFailure> {
        let mut command = ProcessCommand::new(file);
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        reset_sigchld_before_spawn();
        let mut child = command.spawn().map_err(|error| ExecFailure {
            message: error.to_string(),
            stdout: String::new(),
            stderr: String::new(),
            status: None,
            timed_out: false,
        })?;
        let pgid = child.id() as libc::pid_t;
        unsafe {
            // Close the post-spawn race before the child reaches its own `setpgid`.
            // Either side may win; setting the same group twice is harmless.
            libc::setpgid(pgid, pgid);
        }
        let mut stdout = child.stdout.take().expect("stdout was piped");
        let mut stderr = child.stderr.take().expect("stderr was piped");
        let stdout_reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stdout.read_to_end(&mut bytes);
            bytes
        });
        let stderr_reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stderr.read_to_end(&mut bytes);
            bytes
        });
        let started = Instant::now();
        let status = loop {
            match exited_without_reaping(&child) {
                Ok(true) if stdout_reader.is_finished() && stderr_reader.is_finished() => {
                    break child.wait().expect("observed child must still be waitable");
                }
                Ok(_) if started.elapsed() < timeout => {
                    thread::sleep(Duration::from_millis(10));
                }
                Ok(_) => {
                    unsafe {
                        libc::killpg(pgid, libc::SIGKILL);
                    }
                    let _ = child.wait();
                    let stdout = stdout_reader.join().unwrap_or_default();
                    let stderr = stderr_reader.join().unwrap_or_default();
                    return Err(ExecFailure {
                        message: format!("command timed out after {} seconds", timeout.as_secs()),
                        stdout: String::from_utf8_lossy(&stdout).into_owned(),
                        stderr: String::from_utf8_lossy(&stderr).into_owned(),
                        status: None,
                        timed_out: true,
                    });
                }
                Err(error) => {
                    // An error says the child's identity could not be confirmed; ECHILD
                    // says outright that it is no longer ours. That is not permission to
                    // SIGKILL the number it used to have. Signal nothing and wait for
                    // nothing: the child may still be live, so waiting or joining a pipe
                    // it holds could hang this host operation indefinitely.
                    return Err(ExecFailure {
                        message: format!(
                            "wait for {} failed: {error}; process group left unsignalled",
                            display_command(file, args)
                        ),
                        stdout: String::new(),
                        stderr: String::new(),
                        status: None,
                        timed_out: false,
                    });
                }
            }
        };
        let stdout = stdout_reader.join().unwrap_or_default();
        let stderr = stderr_reader.join().unwrap_or_default();
        if status.success() {
            Ok(String::from_utf8_lossy(&stdout).into_owned())
        } else {
            Err(ExecFailure {
                message: format!("process exited with status {status}"),
                stdout: String::from_utf8_lossy(&stdout).into_owned(),
                stderr: String::from_utf8_lossy(&stderr).into_owned(),
                status: status.code(),
                timed_out: false,
            })
        }
    }

    fn dispatch(&mut self, request: &RequestSpec) -> Result<Option<serde_json::Value>, String> {
        dispatch::send(request)
    }

    fn current_exe(&self) -> Result<PathBuf, String> {
        std::env::current_exe().map_err(|error| error.to_string())
    }
}

pub fn assimilate(args: AssimilateArgs) -> Result<(), String> {
    let mut io = SystemIo;
    assimilate_with(&mut io, args)
}

#[derive(Debug, PartialEq, Eq)]
struct ClientUpdateHost {
    name: String,
    ssh: String,
    cli_bin: Option<String>,
}

pub fn update_clients(as_user: &str) -> Result<(), String> {
    let mut io = SystemIo;
    update_clients_with(&mut io, as_user)
}

fn update_clients_with(io: &mut dyn CeremonyIo, as_user: &str) -> Result<(), String> {
    let request = dispatch::build_update_clients_request(as_user);
    let response = io.dispatch(&request)?;
    let hosts = client_update_hosts(response)?;
    let current_version = env!("CARGO_PKG_VERSION");
    let mut failed = 0;

    for host in hosts {
        let Some(cli_bin) = host.cli_bin else {
            failed += 1;
            io.log(&format!(
                "[update-clients] {}: refused — no CLI path registered",
                host.name
            ));
            continue;
        };
        let remote_cli = format!("{cli_bin}/tightbeam");
        let asked = ssh(
            io,
            false,
            &host.ssh,
            &format!("{} version", remote_path(&remote_cli)),
        );

        match asked {
            Err(error) => {
                failed += 1;
                let outcome = if error.timed_out {
                    "timed out"
                } else if error.status == Some(255) {
                    "unreachable"
                } else {
                    "question failed"
                };
                io.log(&format!(
                    "[update-clients] {}: {outcome} — {}",
                    host.name,
                    command_failure(&error)
                ));
            }
            Ok(answer) => match version_answer(&answer) {
                None => {
                    failed += 1;
                    io.log(&format!(
                        "[update-clients] {}: question failed — no unambiguous version answer",
                        host.name
                    ));
                }
                Some(version) if version == current_version => io.log(&format!(
                    "[update-clients] {}: already current ({current_version})",
                    host.name
                )),
                Some(version) => {
                    let asked_target = ssh(io, false, &host.ssh, "uname -sm");
                    let remote_target = match asked_target {
                        Ok(answer) => target_answer(&answer),
                        Err(error) => {
                            failed += 1;
                            io.log(&format!(
                                "[update-clients] {}: target check failed — {}",
                                host.name,
                                command_failure(&error)
                            ));
                            continue;
                        }
                    };
                    let Some(remote_target) = remote_target else {
                        failed += 1;
                        io.log(&format!(
                            "[update-clients] {}: target check failed — no unambiguous target answer",
                            host.name
                        ));
                        continue;
                    };
                    if remote_target != local_target_triple() {
                        failed += 1;
                        io.log(&format!(
                            "[update-clients] {}: incompatible — local target {} differs from satellite target {remote_target}",
                            host.name,
                            local_target_triple()
                        ));
                        continue;
                    }
                    match ship_current_cli(io, false, &host.ssh, &cli_bin) {
                        Ok(()) => io.log(&format!(
                            "[update-clients] {}: updated ({version} -> {current_version})",
                            host.name
                        )),
                        Err(error) => {
                            failed += 1;
                            io.log(&format!(
                                "[update-clients] {}: refused — {}",
                                host.name,
                                command_failure(&error)
                            ));
                        }
                    }
                }
            },
        }
    }

    if failed == 0 {
        Ok(())
    } else {
        Err(format!(
            "update-clients failed for {failed} host(s); see per-host outcomes above"
        ))
    }
}

fn version_answer(output: &str) -> Option<&str> {
    let answer = output.strip_suffix('\n').unwrap_or(output);
    let answer = answer.strip_suffix('\r').unwrap_or(answer);
    (!answer.is_empty() && !answer.contains(['\r', '\n']) && is_version(answer)).then_some(answer)
}

fn is_version(value: &str) -> bool {
    let (without_build, build) = value
        .split_once('+')
        .map_or((value, None), |(core, suffix)| (core, Some(suffix)));
    if build.is_some_and(|suffix| !valid_version_identifiers(suffix, false)) {
        return false;
    }
    let (core, pre_release) = without_build
        .split_once('-')
        .map_or((without_build, None), |(core, suffix)| (core, Some(suffix)));
    if pre_release.is_some_and(|suffix| !valid_version_identifiers(suffix, true)) {
        return false;
    }
    let mut parts = core.split('.');
    let valid = (0..3).all(|_| {
        parts
            .next()
            .is_some_and(|part| valid_numeric_identifier(part))
    });
    valid && parts.next().is_none()
}

fn valid_numeric_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && (value == "0" || !value.starts_with('0'))
}

fn valid_version_identifiers(value: &str, reject_numeric_leading_zero: bool) -> bool {
    !value.is_empty()
        && value.split('.').all(|identifier| {
            !identifier.is_empty()
                && identifier
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                && (!reject_numeric_leading_zero
                    || !identifier.bytes().all(|byte| byte.is_ascii_digit())
                    || valid_numeric_identifier(identifier))
        })
}

fn target_answer(output: &str) -> Option<String> {
    let mut targets = output.lines().filter_map(|line| {
        matches!(line.split_whitespace().next(), Some("Darwin" | "Linux"))
            .then(|| target_from_probe(line))
            .flatten()
    });
    let target = targets.next()?;
    targets
        .all(|candidate| candidate == target)
        .then_some(target)
}

fn client_update_hosts(
    response: Option<serde_json::Value>,
) -> Result<Vec<ClientUpdateHost>, String> {
    let hosts = response
        .as_ref()
        .and_then(|result| result.get("hosts"))
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "update-clients did not return a host registry".to_owned())?;

    hosts
        .iter()
        .map(|host| {
            Ok(ClientUpdateHost {
                name: host
                    .get("name")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| "update-clients returned a host without a name".to_owned())?
                    .to_owned(),
                ssh: host
                    .get("ssh")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| "update-clients returned a satellite without ssh".to_owned())?
                    .to_owned(),
                cli_bin: host
                    .get("cliBin")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
            })
        })
        .collect()
}

fn assimilate_with(io: &mut dyn CeremonyIo, args: AssimilateArgs) -> Result<(), String> {
    let catalog = &args.catalog;
    validate_harnesses(&args.harnesses, &catalog)?;
    let host_name = args
        .name
        .clone()
        .unwrap_or_else(|| default_assimilate_name(&args.ssh_dest));
    let dry_run = args.dry_run;

    // The probe runs for real even under --dry-run. It writes nothing, and a dry run
    // that cannot observe is worse than no dry run at all: it converted "I checked"
    // into false confidence and passed a host with no node (#73).
    let requirements = preflight::requirements(catalog, &args.harnesses);
    let observation = step(io, "PROBE", probe_failure, |io| {
        let probe = io.exec(
            "ssh",
            &[
                "-o".to_owned(),
                "BatchMode=yes".to_owned(),
                "--".to_owned(),
                args.ssh_dest.clone(),
                preflight::script(&requirements, &remote_path(&args.base_dir)),
            ],
            REMOTE_COMMAND_TIMEOUT,
        )?;
        let observation = preflight::parse(&probe);
        for line in preflight::report(&observation) {
            io.log(&line);
        }
        preflight::verdict(&requirements, &observation, &args.ssh_dest).map_err(|message| {
            ExecFailure {
                message,
                stdout: String::new(),
                stderr: String::new(),
                status: None,
                timed_out: false,
            }
        })?;
        Ok(observation)
    })?;

    let resolved_base = step(io, "DIRS", command_failure, |io| {
        let auth_dirs = args
            .harnesses
            .iter()
            .map(|harness| remote_path(&format!("{}/auth/{harness}", args.base_dir)))
            .collect::<Vec<_>>();
        ssh(
            io,
            dry_run,
            &args.ssh_dest,
            &format!("mkdir -p {}", auth_dirs.join(" ")),
        )?;
        if dry_run {
            // The probe already resolved this read-only. On a host that has never been
            // assimilated there is nothing to resolve, and saying so beats reporting a
            // configured path as though it had been observed.
            return Ok(observation
                .base_dir
                .clone()
                .unwrap_or_else(|| args.base_dir.clone()));
        }
        let resolved = ssh(
            io,
            dry_run,
            &args.ssh_dest,
            &format!("cd {} && pwd", remote_path(&args.base_dir)),
        )?;
        Ok(resolved.trim().to_owned())
    })?;

    step(io, "ADAPTERS", command_failure, |io| {
        ssh(
            io,
            dry_run,
            &args.ssh_dest,
            &format!(
                "cd {} && npm install --prefix adapters {}",
                remote_path(&resolved_base),
                args.harnesses
                    .iter()
                    .map(|name| {
                        catalog
                            .harnesses
                            .iter()
                            .find(|harness| harness.wire_name == *name)
                            .expect("harnesses were validated")
                            .install_package
                            .as_str()
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            ),
        )
        .map(|_| ())
    })?;

    let cli_bin = format!("{resolved_base}/bin");
    let adapter_bin_dir = format!("{resolved_base}/adapters/node_modules/.bin");
    let remote_target = target_from_probe(&observation.platform);
    let cli_compatible = remote_target.as_deref() == Some(local_target_triple());
    if cli_compatible {
        step(io, "CLI", command_failure, |io| {
            ship_current_cli(io, dry_run, &args.ssh_dest, &cli_bin)
        })?;
    } else {
        let target = remote_target.unwrap_or_else(|| "the satellite target".to_owned());
        io.warn(&format!(
            "[assimilate] WARNING: this binary targets {} but the satellite targets {target}; build for {target} and re-run; skipping CLI",
            local_target_triple()
        ));
    }

    if dry_run {
        io.log("[assimilate] REGISTER... skipped (--dry-run)");
    } else {
        let request = dispatch::build_register_host_request(
            &args.as_user,
            &host_name,
            &args.ssh_dest,
            &resolved_base,
            &cli_bin,
            &adapter_bin_dir,
        );
        match io.dispatch(&request).map(|_| ()) {
            Ok(()) => io.log("[assimilate] REGISTER... ok"),
            Err(reason) => {
                io.log(&format!("[assimilate] REGISTER... FAILED: {reason}"));
                return Err(reason);
            }
        }
    }

    io.log("Assimilation summary:");
    io.log(&format!("  host: {host_name}"));
    io.log(&format!("  base dir: {resolved_base}"));
    io.log(&format!("  cli bin: {cli_bin}"));
    io.log(&format!("  adapter bin: {adapter_bin_dir}"));
    io.log("  credentials: not transported; onboard independently on this host");
    io.log(&format!(
        "  next: add \"{host_name}\" to an archetype's `where`"
    ));
    Ok(())
}

fn step<T>(
    io: &mut dyn CeremonyIo,
    name: &str,
    failure: fn(&ExecFailure) -> String,
    action: impl FnOnce(&mut dyn CeremonyIo) -> Result<T, ExecFailure>,
) -> Result<T, String> {
    match action(io) {
        Ok(value) => {
            io.log(&format!("[assimilate] {name}... ok"));
            Ok(value)
        }
        Err(error) => {
            let reason = failure(&error);
            io.log(&format!("[assimilate] {name}... FAILED: {reason}"));
            Err(reason)
        }
    }
}

fn run_command(
    io: &mut dyn CeremonyIo,
    dry_run: bool,
    file: &str,
    args: &[String],
) -> Result<String, ExecFailure> {
    if dry_run {
        io.log(&format!("DRY {}", display_command(file, args)));
        Ok(String::new())
    } else {
        io.exec(file, args, REMOTE_COMMAND_TIMEOUT)
    }
}

fn ship_current_cli(
    io: &mut dyn CeremonyIo,
    dry_run: bool,
    ssh_dest: &str,
    cli_bin: &str,
) -> Result<(), ExecFailure> {
    ssh(
        io,
        dry_run,
        ssh_dest,
        &format!("mkdir -p {}", remote_path(cli_bin)),
    )?;
    let executable = io.current_exe().map_err(|message| ExecFailure {
        message,
        stdout: String::new(),
        stderr: String::new(),
        status: None,
        timed_out: false,
    })?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let staged_cli = format!("{cli_bin}/.tightbeam.update-{}-{nonce}", std::process::id());
    let shipped = (|| {
        run_command(
            io,
            dry_run,
            "scp",
            &[
                "-o".to_owned(),
                "BatchMode=yes".to_owned(),
                "--".to_owned(),
                executable.display().to_string(),
                format!("{ssh_dest}:{}", shell_quote(&staged_cli)),
            ],
        )?;
        ssh(
            io,
            dry_run,
            ssh_dest,
            &format!("chmod +x {}", remote_path(&staged_cli)),
        )?;
        let answer = ssh(
            io,
            dry_run,
            ssh_dest,
            &format!("{} version", remote_path(&staged_cli)),
        )?;
        if !dry_run && version_answer(&answer) != Some(env!("CARGO_PKG_VERSION")) {
            let message = format!(
                "staged CLI failed verification: expected exact version {}, got {:?}",
                env!("CARGO_PKG_VERSION"),
                answer
            );
            return Err(ExecFailure {
                message: message.clone(),
                stdout: answer,
                stderr: message,
                status: None,
                timed_out: false,
            });
        }
        ssh(
            io,
            dry_run,
            ssh_dest,
            &format!(
                "mv -f {} {}",
                remote_path(&staged_cli),
                remote_path(&format!("{cli_bin}/tightbeam"))
            ),
        )?;
        Ok(())
    })();

    if let Err(mut error) = shipped {
        if let Err(cleanup) = ssh(
            io,
            dry_run,
            ssh_dest,
            &format!("rm -f {}", remote_path(&staged_cli)),
        ) {
            let message = format!(
                "{}; staged cleanup failed: {}",
                command_failure(&error),
                command_failure(&cleanup)
            );
            error.message = message.clone();
            error.stdout.clear();
            error.stderr = message;
        }
        return Err(error);
    }

    Ok(())
}

fn ssh(
    io: &mut dyn CeremonyIo,
    dry_run: bool,
    ssh_dest: &str,
    script: &str,
) -> Result<String, ExecFailure> {
    run_command(
        io,
        dry_run,
        "ssh",
        &[
            "-o".to_owned(),
            "BatchMode=yes".to_owned(),
            "--".to_owned(),
            ssh_dest.to_owned(),
            script.to_owned(),
        ],
    )
}

fn command_failure(error: &ExecFailure) -> String {
    let stderr = error.stderr.trim();
    if !stderr.is_empty() {
        return stderr.to_owned();
    }
    let stdout = error.stdout.trim();
    if !stdout.is_empty() {
        return stdout.to_owned();
    }
    error.message.clone()
}

/// Reachability is the only thing left to classify here: the probe script exits 0 and
/// labels its findings, so a missing binary arrives as a verdict from `preflight`
/// rather than as an exit status this has to guess at by counting stdout lines.
fn probe_failure(error: &ExecFailure) -> String {
    let reason = command_failure(error);
    let lower = reason.to_ascii_lowercase();
    if lower.contains("permission denied")
        || lower.contains("publickey")
        || lower.contains("authentication")
    {
        return "ssh authentication failed; set up ssh keys for non-interactive access".to_owned();
    }
    reason
}

pub fn default_assimilate_name(ssh_dest: &str) -> String {
    ssh_dest.rsplit('@').next().unwrap_or(ssh_dest).to_owned()
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn remote_path(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("~/") {
        if !rest.is_empty()
            && rest
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._/-".contains(&byte))
        {
            return path.to_owned();
        }
        return format!("~/{}", shell_quote(rest));
    }
    shell_quote(path)
}

fn display_command(file: &str, args: &[String]) -> String {
    std::iter::once(file)
        .chain(args.iter().map(String::as_str))
        .map(shell_quote)
        .collect::<Vec<_>>()
        .join(" ")
}

fn local_target_triple() -> &'static str {
    env!("TIGHTBEAM_BUILD_TARGET")
}

fn target_from_probe(output: &str) -> Option<String> {
    let first = output.lines().next()?;
    let mut parts = first.split_whitespace();
    let os = parts.next()?;
    let arch = parts.next()?;
    match (os, arch) {
        ("Darwin", "arm64" | "aarch64") => Some("aarch64-apple-darwin".to_owned()),
        ("Darwin", "x86_64") => Some("x86_64-apple-darwin".to_owned()),
        ("Linux", "aarch64" | "arm64") => Some("aarch64-unknown-linux-gnu".to_owned()),
        ("Linux", "x86_64" | "amd64") => Some("x86_64-unknown-linux-gnu".to_owned()),
        _ => Some(format!(
            "{}-unknown-{}",
            arch.to_ascii_lowercase(),
            os.to_ascii_lowercase()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The refusal is the whole value of not reading a key from a terminal, so
    /// the sentence is pinned rather than the `isatty` branch that produces it
    /// (which a unit test cannot stub). It must name the pipe form, because that
    /// is the remedy the operator needs -- a bare "refused" would leave them
    /// guessing at an invocation that does not exist anywhere else.
    #[test]
    fn refusing_a_terminal_names_the_pipe_form() {
        let message = api_key_needs_a_pipe();

        assert!(message.contains("printenv"));
        assert!(message.contains("--api-key"));
        assert!(message.contains("scrollback"));
    }

    /// A subscription credential is a BEARER token, and sending it as `x-api-key` would
    /// refuse a perfectly good one -- a fail-closed regression that would then be
    /// reported as a bad capture, sending the operator to re-run a ceremony that was
    /// never wrong. The pairing is asserted directly because it is the one thing here
    /// no unit test can learn from the network.
    #[test]
    fn a_setup_token_is_validated_as_a_bearer_not_an_api_key() {
        let (url, headers) = subscription_probe("sk-ant-oat01-EXAMPLE");
        let names: Vec<&str> = headers.iter().map(|(name, _)| *name).collect();

        assert_eq!(url, "https://api.anthropic.com/v1/models?limit=1");
        assert_eq!(names, vec!["authorization", "anthropic-version"]);
        assert_eq!(headers[0].1, "Bearer sk-ant-oat01-EXAMPLE");
        assert_eq!(headers[1].1, "2023-06-01");
        assert!(
            !names.contains(&"x-api-key"),
            "x-api-key is the OTHER kind's header"
        );
    }

    /// The refusal a truncated capture earns. Recorded signature: a bearer route answers
    /// an invalid token with 401 "Invalid bearer token" (the x-api-key route says "API key
    /// is invalid.", which is how the two are told apart).
    ///
    /// It has to point at CAPTURE, because that is what is actually broken when a token
    /// gets this far and fails -- claude prints one only to an account that has a
    /// subscription. And it must not collide with the `unsupported (no subscription)`
    /// phrase, which `onboard` matches to classify the cancel phase.
    #[test]
    fn a_rejected_capture_blames_capture_and_banks_nothing() {
        let message = rejected_setup_token(
            401,
            "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\
             \"message\":\"Invalid bearer token\"}}",
            "shrdlu",
        );

        assert!(message.contains("Invalid bearer token"), "{message}");
        assert!(message.contains("401"), "{message}");
        assert!(message.contains("CAPTURE"), "{message}");
        assert!(message.contains("shrdlu"), "{message}");
        assert!(
            message.contains("Nothing was banked"),
            "the api-key path's promise, verbatim: {message}"
        );
        assert!(
            !message.contains("setup-token-failure.log"),
            "a live credential must not be written to a diagnostic log: {message}"
        );
        assert!(
            !message.contains("unsupported (no subscription)"),
            "must not be classified as a missing subscription: {message}"
        );
    }

    #[test]
    fn a_capture_failure_never_prints_or_persists_the_candidate() {
        let candidate = "future:v2+SYNTHETIC/NOT-A-CREDENTIAL==";
        let transcript = format!(
            "Your OAuth token (valid for 1 year):\r\n\r\n{candidate}\r\nStore this token securely.\r\n"
        );
        let message = capture_failed(transcript.as_bytes());

        assert!(
            !message.contains(candidate),
            "candidate leaked in {message}"
        );
        assert!(
            message.contains("credential boundary cannot be trusted"),
            "{message}"
        );
        assert!(message.contains("not written to a log"), "{message}");
        assert!(!message.contains("setup-token-failure.log"), "{message}");
    }

    /// Unreachable is not invalid. A network failure during validation must implicate
    /// neither the capture nor the account, or the operator burns a single-use
    /// authorization re-authorizing something that was never broken.
    #[test]
    fn an_unreachable_provider_is_not_a_verdict_on_the_token() {
        let message = unvalidated_setup_token("dns error: failed to lookup address", "shrdlu");

        assert!(message.contains("could not reach anthropic"), "{message}");
        assert!(message.contains("NOT validated"), "{message}");
        assert!(message.contains("Nothing was banked"), "{message}");
        assert!(message.contains("not a verdict"), "{message}");
        assert!(
            !message.contains("CAPTURE"),
            "a network failure does not implicate the capture: {message}"
        );
    }

    #[test]
    fn an_api_key_network_timeout_is_not_reported_as_lease_expiry_or_rejection() {
        let message = unvalidated_api_key("openai", "network operation timed out", "shrdlu");

        assert!(message.contains("could not reach openai"), "{message}");
        assert!(message.contains("timed out"), "{message}");
        assert!(message.contains("Nothing was banked"), "{message}");
        assert!(!message.contains("lease expired"), "{message}");
        assert!(!message.contains("rejected"), "{message}");
    }

    /// An API key is staged under the SAME filename the subscription ceremony
    /// stages, at the same 0600, so everything downstream is identical between
    /// the two kinds and only the recorded kind differs.
    #[test]
    fn an_anthropic_api_key_stages_like_a_setup_token() {
        use std::os::unix::fs::PermissionsExt;

        let staging = std::env::temp_dir().join(format!(
            "tightbeam-api-key-stage-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = fs::remove_dir_all(&staging);
        fs::create_dir_all(&staging).unwrap();

        bank_anthropic_api_key(staging.to_str().unwrap(), "sk-ant-api03-test").unwrap();

        let staged = staging.join("oauth-token");
        assert_eq!(fs::read_to_string(&staged).unwrap(), "sk-ant-api03-test");
        let mode = fs::metadata(&staged).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let _ = fs::remove_dir_all(&staging);
    }

    #[test]
    fn fixture_provider_materializes_its_staged_credential() {
        let staging =
            std::env::temp_dir().join(format!("tightbeam-fixture-provider-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).unwrap();
        let endpoint = Endpoint {
            base: "https://ceremony.test".to_owned(),
            token: "tbc_test".to_owned(),
            origin: crate::dispatch::Origin::Provisioned,
        };
        let ceremony = Ceremony {
            endpoint: &endpoint,
            deadline: Instant::now() + Duration::from_secs(1_800),
            load_harnesses: &|_, _| Ok(None),
        };

        assert_eq!(
            run_provider_onboarding(
                "fixture-provider",
                staging.to_str().unwrap(),
                None,
                &ceremony
            ),
            Ok(())
        );
        assert_eq!(
            std::fs::read_to_string(staging.join("fixture.json")).unwrap(),
            "fixture-provider-credential"
        );

        std::fs::remove_dir_all(staging).unwrap();
    }

    #[test]
    fn a_ceremony_outliving_its_lease_is_killed_with_its_whole_group() {
        // The stub forks a GRANDCHILD and records its pid, so this asserts the whole group
        // died rather than just the process we spawned. A wrapper that killed only its
        // direct child would leave the grandchild behind -- which is the eurisko orphan's
        // exact shape: `script` gone, `claude setup-token` still running.
        let marker = std::env::temp_dir().join(format!(
            "tightbeam-ceremony-watchdog-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&marker);

        let mut command = ProcessCommand::new("sh");
        command
            .args([
                "-c",
                &format!(
                    "sleep 300 & printf '%s' \"$!\" > '{}'; wait",
                    marker.display()
                ),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let error = run_bounded(
            command,
            "a stub ceremony",
            Instant::now() + Duration::from_secs(1),
            None,
        )
        .unwrap_err();

        // Named, not merely "timed out": an operator has to know what was killed on their
        // terminal.
        assert!(error.contains("a stub ceremony"), "unnamed: {error}");
        assert!(error.contains("process group"), "no group named: {error}");

        // Absence from the process table, not elapsed time. A clock assertion under
        // parallel test load fails toward a false PASS, which is the shape tracked in #86.
        let grandchild = std::fs::read_to_string(&marker).unwrap_or_default();
        let _ = std::fs::remove_file(&marker);
        assert!(
            !grandchild.is_empty(),
            "the stub never recorded a grandchild"
        );

        // A failed `ps` spawn means this test learned NOTHING about the grandchild, and
        // "learned nothing" must not collapse into the answer this assertion wants. The
        // `unwrap_or(false)` here read a spawn failure as "not alive" and passed green —
        // under load, where a spawn is most likely to fail, is exactly when the swallow
        // fires. Same principle as the forged `child exit:` line in #43: a channel that
        // cannot report must not be allowed to report success.
        let alive = ProcessCommand::new("ps")
            .args(["-o", "pid=", "-p", grandchild.trim()])
            .output()
            .map(|out| !out.stdout.trim_ascii().is_empty())
            .expect("could not determine whether the grandchild is alive: `ps` did not run");
        assert!(!alive, "grandchild {grandchild} outlived the group kill");
    }

    /// Terminating the CLI itself must have the same tree semantics as expiry. This is a
    /// re-exec because installing SIGTERM in the cargo test process would affect unrelated
    /// tests running beside it.
    #[test]
    fn killing_the_ceremony_parent_leaves_no_surviving_child() {
        const INNER: &str = "TIGHTBEAM_CEREMONY_SIGNAL_INNER";
        const MARKER: &str = "TIGHTBEAM_CEREMONY_SIGNAL_MARKER";
        const SURVIVED: &str = "TIGHTBEAM_CEREMONY_SIGNAL_SURVIVED";
        const STAGING: &str = "TIGHTBEAM_CEREMONY_SIGNAL_STAGING";
        const CANCEL: &str = "TIGHTBEAM_CEREMONY_SIGNAL_CANCEL";

        if std::env::var_os(INNER).is_some() {
            let marker = std::env::var(MARKER).expect("outer supplied marker");
            let staging = std::env::var(STAGING).expect("outer supplied staging path");
            let cancel = std::env::var(CANCEL).expect("outer supplied cancel marker");
            let endpoint = Endpoint {
                base: "http://signal-fixture.invalid".to_owned(),
                token: "signal-fixture-token".to_owned(),
                origin: crate::dispatch::Origin::Provisioned,
            };
            let result = onboard(
                &Identity::User("signal-fixture".to_owned()),
                "anthropic",
                false,
                &endpoint,
                |_, request, _| {
                    let request: serde_json::Value =
                        serde_json::from_str(&request.body_json).unwrap();
                    match request
                        .pointer("/params/phase")
                        .and_then(serde_json::Value::as_str)
                    {
                        Some("begin") => Ok(Some(serde_json::json!({
                            "stagingPath": staging,
                            "leaseId": "signal-fixture-lease",
                            "leaseTtlMs": 300_000
                        }))),
                        Some("cancel") => {
                            fs::write(&cancel, "entered").unwrap();
                            thread::sleep(Duration::from_secs(300));
                            Ok(None)
                        }
                        phase => panic!("unexpected onboarding phase: {phase:?}"),
                    }
                },
                |_, _| Ok(None),
            );
            let error = result.expect_err("TERM must abort onboarding");
            assert!(error.contains("interrupted by signal"), "{error}");
            assert!(
                !std::path::Path::new(&staging).exists(),
                "interrupted onboarding left staging behind at {staging}"
            );
            assert!(
                std::path::Path::new(&marker).exists(),
                "provider fixture never started"
            );
            return;
        }

        let root = std::env::temp_dir().join(format!(
            "tightbeam-ceremony-signal-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let marker = root.join("descendant.pid");
        let survived = marker.with_extension("survived");
        let staging = root.join("staging");
        let cancel = root.join("cancel-entered");
        let bin = root.join("bin");
        fs::create_dir_all(&staging).unwrap();
        fs::create_dir_all(&bin).unwrap();
        let claude = bin.join("claude");
        fs::write(
            &claude,
            format!(
                "#!/bin/sh\n(sleep 1; printf survived > '{}') &\nprintf '%s' \"$!\" > \
                 '{}'\nwhile :; do printf '%04096d\\n' 0; done\n",
                survived.display(),
                marker.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
        let mut inner = ProcessCommand::new(std::env::current_exe().unwrap());
        inner
            .args([
                "--exact",
                "ceremonies::tests::killing_the_ceremony_parent_leaves_no_surviving_child",
                "--nocapture",
            ])
            .env(INNER, "1")
            .env(MARKER, &marker)
            .env(SURVIVED, &survived)
            .env(STAGING, &staging)
            .env(CANCEL, &cancel)
            .env("TIGHTBEAM_MACHINE", "signal-fixture-host")
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut inner = inner.spawn().unwrap();

        let ready_by = Instant::now() + Duration::from_secs(5);
        while !marker.exists() && Instant::now() < ready_by {
            thread::sleep(Duration::from_millis(10));
        }
        let grandchild = fs::read_to_string(&marker).expect("fixture recorded its descendant");

        assert_eq!(
            unsafe { libc::kill(inner.id() as libc::pid_t, libc::SIGTERM) },
            0
        );
        thread::sleep(Duration::from_millis(250));
        let mut inner_stdout = inner.stdout.take().unwrap();
        let drain = thread::spawn(move || {
            let mut discarded = Vec::new();
            let _ = inner_stdout.read_to_end(&mut discarded);
        });
        let exit_by = Instant::now() + Duration::from_secs(5);
        let mut status = None;
        while status.is_none() && Instant::now() < exit_by {
            status = inner.try_wait().unwrap();
            thread::sleep(Duration::from_millis(10));
        }
        let required_kill = status.is_none();
        if required_kill {
            assert_eq!(
                unsafe { libc::kill(inner.id() as libc::pid_t, libc::SIGKILL) },
                0
            );
            status = Some(inner.wait().unwrap());
        }
        drain.join().unwrap();
        thread::sleep(Duration::from_millis(1_200));

        let wrote_after_parent_death = survived.exists();
        let grandchild_pid: libc::pid_t = grandchild.trim().parse().unwrap();
        let alive = unsafe { libc::kill(grandchild_pid, 0) } == 0
            || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH);
        let staging_survived = staging.exists();
        let cancel_entered = cancel.exists();
        fs::remove_dir_all(&root).unwrap();
        assert!(
            !required_kill,
            "TERM left ceremony {} alive; SIGKILL was required ({:?}); cancel entered: {}",
            inner.id(),
            status.unwrap(),
            cancel_entered
        );
        assert!(
            !cancel_entered,
            "TERM entered the lease-bounded cancellation wait instead of unwinding"
        );
        assert!(
            !wrote_after_parent_death,
            "descendant {grandchild} continued running after its ceremony parent died"
        );
        assert!(!alive, "descendant {grandchild} survived TERM");
        assert!(!staging_survived, "TERM left onboarding staging behind");
    }

    /// Codex uses the pipe-backed bounded runner rather than the Anthropic pty runner.
    /// Its signal has to retain the same interrupted classification all the way through
    /// onboarding, or `onboard` mistakes TERM for a staging failure and waits on cancel.
    #[test]
    fn term_during_codex_onboarding_kills_the_tree_without_entering_cancel() {
        const INNER: &str = "TIGHTBEAM_CODEX_SIGNAL_INNER";
        const MARKER: &str = "TIGHTBEAM_CODEX_SIGNAL_MARKER";
        const STAGING: &str = "TIGHTBEAM_CODEX_SIGNAL_STAGING";
        const CANCEL: &str = "TIGHTBEAM_CODEX_SIGNAL_CANCEL";

        if std::env::var_os(INNER).is_some() {
            let marker = std::env::var(MARKER).expect("outer supplied marker");
            let staging = std::env::var(STAGING).expect("outer supplied staging path");
            let cancel = std::env::var(CANCEL).expect("outer supplied cancel marker");
            let endpoint = Endpoint {
                base: "http://signal-fixture.invalid".to_owned(),
                token: "signal-fixture-token".to_owned(),
                origin: crate::dispatch::Origin::Provisioned,
            };
            let result = onboard(
                &Identity::User("signal-fixture".to_owned()),
                "openai",
                false,
                &endpoint,
                |_, request, _| {
                    let request: serde_json::Value =
                        serde_json::from_str(&request.body_json).unwrap();
                    match request
                        .pointer("/params/phase")
                        .and_then(serde_json::Value::as_str)
                    {
                        Some("begin") => Ok(Some(serde_json::json!({
                            "stagingPath": staging,
                            "leaseId": "signal-fixture-lease",
                            "leaseTtlMs": 300_000
                        }))),
                        Some("cancel") => {
                            fs::write(&cancel, "entered").unwrap();
                            thread::sleep(Duration::from_secs(300));
                            Ok(None)
                        }
                        phase => panic!("unexpected onboarding phase: {phase:?}"),
                    }
                },
                |_, _| Ok(None),
            );
            let error = result.expect_err("TERM must abort codex onboarding");
            assert!(error.contains("interrupted by signal"), "{error}");
            assert!(!std::path::Path::new(&staging).exists());
            assert!(std::path::Path::new(&marker).exists());
            return;
        }

        let root = std::env::temp_dir().join(format!(
            "tightbeam-codex-signal-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let marker = root.join("descendant.pid");
        let staging = root.join("staging");
        let cancel = root.join("cancel-entered");
        let bin = root.join("bin");
        fs::create_dir_all(&staging).unwrap();
        fs::create_dir_all(&bin).unwrap();
        let codex = bin.join("codex");
        fs::write(
            &codex,
            format!(
                "#!/bin/sh\nsleep 300 & printf '%s' \"$!\" > '{}'\nwait\n",
                marker.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
        let mut inner = ProcessCommand::new(std::env::current_exe().unwrap());
        inner
            .args([
                "--exact",
                "ceremonies::tests::term_during_codex_onboarding_kills_the_tree_without_entering_cancel",
                "--nocapture",
            ])
            .env(INNER, "1")
            .env(MARKER, &marker)
            .env(STAGING, &staging)
            .env(CANCEL, &cancel)
            .env("TIGHTBEAM_MACHINE", "signal-fixture-host")
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut inner = inner.spawn().unwrap();

        let ready_by = Instant::now() + Duration::from_secs(5);
        while !marker.exists() && Instant::now() < ready_by {
            thread::sleep(Duration::from_millis(10));
        }
        let grandchild = fs::read_to_string(&marker).expect("codex fixture recorded descendant");
        assert_eq!(
            unsafe { libc::kill(inner.id() as libc::pid_t, libc::SIGTERM) },
            0
        );

        let mut stdout = inner.stdout.take().unwrap();
        let drain = thread::spawn(move || {
            let mut discarded = Vec::new();
            let _ = stdout.read_to_end(&mut discarded);
        });
        let exit_by = Instant::now() + Duration::from_secs(5);
        let mut status = None;
        while status.is_none() && Instant::now() < exit_by {
            status = inner.try_wait().unwrap();
            thread::sleep(Duration::from_millis(10));
        }
        let required_kill = status.is_none();
        if required_kill {
            assert_eq!(
                unsafe { libc::kill(inner.id() as libc::pid_t, libc::SIGKILL) },
                0
            );
            let _ = inner.wait();
        }
        drain.join().unwrap();

        let grandchild_pid: libc::pid_t = grandchild.trim().parse().unwrap();
        let alive = unsafe { libc::kill(grandchild_pid, 0) } == 0
            || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH);
        let cancel_entered = cancel.exists();
        let staging_survived = staging.exists();
        let _ = fs::remove_dir_all(&root);

        assert!(
            !required_kill,
            "TERM did not promptly exit codex onboarding; cancel={cancel_entered}, \
             staging={staging_survived}, descendant_alive={alive}"
        );
        assert!(!cancel_entered, "TERM entered the lease-cancellation wait");
        assert!(!alive, "codex descendant {grandchild} survived TERM");
        assert!(!staging_survived, "TERM left codex staging behind");
    }

    #[test]
    fn openai_device_flow_url_is_reprinted_by_tightbeam() {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-openai-url-{}-{:?}",
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
        let mut command = ProcessCommand::new("/bin/sh");
        command
            .args([
                "-c",
                "printf 'Open this URL: https://auth.openai.test/device?code=fixture\\n'",
            ])
            .stdin(Stdio::null())
            .stderr(Stdio::null());

        let status = run_bounded_inner(
            command,
            "openai URL fixture",
            Instant::now() + Duration::from_secs(5),
            None,
            Some(file.as_raw_fd()),
        )
        .unwrap();
        assert!(status.success());
        drop(file);

        let rendered = fs::read_to_string(&path).unwrap();
        let _ = fs::remove_file(path);
        assert!(
            rendered.contains("Authorization URL: https://auth.openai.test/device?code=fixture"),
            "{rendered:?}"
        );
    }

    #[test]
    fn a_blocked_output_consumer_cannot_hold_codex_past_its_deadline() {
        use std::os::fd::{FromRawFd, OwnedFd};

        let mut fds = [-1, -1];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let _reader = unsafe { OwnedFd::from_raw_fd(fds[0]) };
        let writer = unsafe { OwnedFd::from_raw_fd(fds[1]) };
        let mut command = ProcessCommand::new("/bin/sh");
        command
            .args([
                "-c",
                "while :; do printf 'continuous child output\\n'; done",
            ])
            .stdin(Stdio::null())
            .stderr(Stdio::null());
        let started = Instant::now();

        let error = run_bounded_inner(
            command,
            "blocked codex output fixture",
            Instant::now() + Duration::from_millis(100),
            None,
            Some(writer.as_raw_fd()),
        )
        .unwrap_err();

        assert!(
            error.to_string().contains("onboarding lease expired"),
            "{error}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(4),
            "blocked output held the codex loop for {:?}",
            started.elapsed()
        );
    }

    /// A child that never reads the key it was handed used to own the lease.
    ///
    /// `codex login --with-api-key` reads its stdin, so this never bit in production --
    /// but the write that fed it was blocking and unbounded, so a codex that stopped
    /// reading (wedged, or stopped against the terminal) held this process for as long as
    /// it liked, with the operator's key in a pipe. The payload is larger than any pipe
    /// buffer so the write CANNOT complete: the deadline is the only thing that can end it.
    #[test]
    fn a_child_that_never_reads_its_key_cannot_outlive_the_lease() {
        let mut command = ProcessCommand::new("/bin/sh");
        command
            .args(["-c", "sleep 5"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let key = vec![b'k'; 1 << 20];
        let started = Instant::now();

        let error = run_bounded(
            command,
            "a ceremony that never reads its key",
            Instant::now() + Duration::from_millis(200),
            Some(&key),
        )
        .unwrap_err();

        assert!(error.contains("onboarding lease expired"), "{error}");
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "the blocking write held the lease for {:?}",
            started.elapsed()
        );
    }

    /// codex reporting success is not codex having produced a credential.
    ///
    /// Measured, not supposed: `codex login --device-auth` (codex-cli 0.146.0) exits ZERO
    /// 0.00s after a terminal ctrl-c and writes nothing, because cancelling is a normal
    /// exit for it. The staging directory it leaves behind holds `log/` and `tmp/` and no
    /// credential, which is what this fixture reproduces. Before this check the leg
    /// returned Ok and the gateway was the first thing to notice, reporting
    /// `device_auth_failed` for an operator who had simply changed their mind.
    #[test]
    fn a_codex_leg_that_exits_zero_without_a_credential_is_a_failure() {
        let staging = std::env::temp_dir().join(format!(
            "tightbeam-codex-artifact-{}-{:?}",
            std::process::id(),
            thread::current().id()
        ));
        let _ = fs::remove_dir_all(&staging);
        // What a cancelled device-code login actually leaves behind.
        fs::create_dir_all(staging.join("log")).unwrap();
        fs::create_dir_all(staging.join("tmp")).unwrap();
        let staging_path = staging.display().to_string();

        let exited_zero = ProcessCommand::new("/bin/sh")
            .args(["-c", "exit 0"])
            .status()
            .unwrap();

        let error =
            codex_staged_a_credential(exited_zero, &staging_path, "OpenAI device-code onboarding")
                .unwrap_err();
        assert!(error.contains("wrote no credential"), "{error}");
        assert!(
            error.contains("cancelled"),
            "the likely cause is unnamed: {error}"
        );
        assert!(error.contains("Nothing was banked"), "{error}");
        assert!(
            error.contains("auth.json"),
            "the path looked for is unnamed: {error}"
        );

        // An empty file is not a credential either, and says which of the two it was.
        fs::write(staging.join("auth.json"), b"").unwrap();
        let empty =
            codex_staged_a_credential(exited_zero, &staging_path, "OpenAI device-code onboarding")
                .unwrap_err();
        assert!(empty.contains("empty credential file"), "{empty}");

        // The name is the one the gateway installs from -- credentials.ex staged_path/2.
        fs::write(staging.join("auth.json"), b"{\"tokens\":{}}").unwrap();
        assert_eq!(
            codex_staged_a_credential(exited_zero, &staging_path, "OpenAI device-code onboarding"),
            Ok(())
        );

        // A non-zero exit still reports the STATUS. The artifact check must not take over
        // the message for a failure the exit code already explained.
        let exited_three = ProcessCommand::new("/bin/sh")
            .args(["-c", "exit 3"])
            .status()
            .unwrap();
        let failed =
            codex_staged_a_credential(exited_three, &staging_path, "OpenAI device-code onboarding")
                .unwrap_err();
        assert!(failed.contains("failed: exit status: 3"), "{failed}");
        assert!(!failed.contains("cancelled"), "{failed}");

        let _ = fs::remove_dir_all(&staging);
    }

    #[test]
    fn an_expired_ceremony_gets_term_grace_before_kill() {
        let marker = std::env::temp_dir().join(format!(
            "tightbeam-ceremony-term-grace-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&marker);

        let mut command = ProcessCommand::new("sh");
        command
            .args([
                "-c",
                &format!(
                    "trap 'printf term > \"{}\"; exit 0' TERM; while :; do sleep 1; done",
                    marker.display()
                ),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let error = run_bounded(
            command,
            "a TERM-aware stub ceremony",
            Instant::now() + Duration::from_millis(500),
            None,
        )
        .unwrap_err();

        assert!(error.contains("onboarding lease expired"), "{error}");
        let handled = std::fs::read_to_string(&marker).unwrap_or_default();
        let _ = std::fs::remove_file(&marker);
        assert_eq!(
            handled, "term",
            "SIGKILL arrived before the contained process handled SIGTERM"
        );
    }

    #[test]
    fn lease_deadline_starts_from_the_begin_reply() {
        let ready = serde_json::json!({"leaseTtlMs": 12_345});
        let now = Instant::now();

        assert_eq!(
            lease_deadline(&ready, now).duration_since(now),
            Duration::from_millis(12_345)
        );
        assert_eq!(
            lease_deadline(&serde_json::json!({}), now).duration_since(now),
            CEREMONY_FALLBACK_TIMEOUT
        );
    }

    #[test]
    fn a_failure_after_begin_sends_cancel_on_the_ceremony_deadline() {
        let endpoint = Endpoint {
            base: "http://gateway.test".to_owned(),
            token: "tbc_test".to_owned(),
            origin: crate::dispatch::Origin::Provisioned,
        };
        let deadline = Instant::now() + Duration::from_secs(30);
        let ceremony = Ceremony {
            endpoint: &endpoint,
            deadline,
            load_harnesses: &|_, _| Ok(None),
        };
        let sent = std::cell::RefCell::new(Vec::new());

        let reason = cancel_after_begin(
            &Identity::User("flynn".to_owned()),
            "anthropic",
            "subscription",
            Some("worker"),
            Some("lease-7"),
            None,
            "malformed begin reply",
            &ceremony,
            &|_, request, request_deadline| {
                sent.borrow_mut()
                    .push((request.body_json.clone(), request_deadline));
                Ok(None)
            },
        );

        assert_eq!(reason, "malformed begin reply");
        let sent = sent.into_inner();
        assert_eq!(sent.len(), 1);
        assert!(sent[0].0.contains(r#""phase":"cancel""#), "{}", sent[0].0);
        assert!(
            sent[0].0.contains(r#""leaseId":"lease-7""#),
            "{}",
            sent[0].0
        );
        assert_eq!(sent[0].1, Some(deadline));
    }

    #[test]
    fn an_undecodable_successful_begin_is_an_ordinary_response_error() {
        let error = crate::dispatch::parse_response(200, "not json").unwrap_err();

        assert!(error.contains("expected ident"), "{error}");
        assert!(!error.contains("lease may be pending"), "{error}");
    }

    #[test]
    fn an_expired_lease_refuses_before_spawning_the_ceremony() {
        let marker = std::env::temp_dir().join(format!(
            "tightbeam-expired-ceremony-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_file(&marker);
        let mut command = ProcessCommand::new("sh");
        command
            .args(["-c", &format!("touch '{}'", marker.display())])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let error = run_bounded(
            command,
            "an expired stub ceremony",
            Instant::now() - Duration::from_millis(1),
            None,
        )
        .unwrap_err();

        assert!(error.contains("an expired stub ceremony"), "{error}");
        assert!(error.contains("lease already expired"), "{error}");
        assert!(
            !marker.exists(),
            "the child ran even though the lease was already expired"
        );
    }

    #[test]
    fn an_api_key_pipe_is_read_to_eof() {
        let mut reader = io::Cursor::new(b"  sk-test\n".to_vec());
        assert_eq!(read_api_key_from(&mut reader), Ok("sk-test".to_owned()));
    }

    #[test]
    fn validation_refuses_an_expired_lease_before_network_io() {
        for what in ["API-key validation", "setup-token validation"] {
            let error =
                validation_before_deadline(Instant::now() - Duration::from_millis(1), what, |_| {
                    panic!("expired validation performed network work")
                })
                .unwrap_err();
            assert!(error.contains(what), "{error}");
            assert!(error.contains("onboarding lease expired"), "{error}");
            assert!(error.contains("nothing was banked"), "{error}");
        }
    }

    #[test]
    fn a_network_failure_before_the_deadline_survives_the_lease_waiter() {
        let error = validation_before_deadline(
            Instant::now() + Duration::from_secs(1),
            "API-key validation",
            |_| Err("network operation timed out".to_owned()),
        )
        .unwrap_err();

        assert_eq!(error, "network operation timed out");
    }

    #[test]
    fn a_rejection_body_that_finishes_after_the_deadline_is_reported_as_expiry() {
        let error = validation_before_deadline(
            Instant::now() + Duration::from_millis(20),
            "API-key validation",
            |_| {
                thread::sleep(Duration::from_millis(100));
                Err("the API key was rejected".to_owned())
            },
        )
        .unwrap_err();

        assert!(error.contains("onboarding lease expired"), "{error}");
        assert!(!error.contains("rejected"), "{error}");
    }

    #[derive(Default)]
    struct FakeIo {
        logs: Vec<String>,
        warnings: Vec<String>,
        commands: Vec<(String, Vec<String>)>,
        responses: Vec<Result<String, ExecFailure>>,
        dispatched: Vec<String>,
        dispatch_responses: Vec<Result<Option<serde_json::Value>, String>>,
    }

    impl CeremonyIo for FakeIo {
        fn log(&mut self, message: &str) {
            self.logs.push(message.to_owned());
        }

        fn warn(&mut self, message: &str) {
            self.warnings.push(message.to_owned());
        }

        fn exec(
            &mut self,
            file: &str,
            args: &[String],
            _timeout: Duration,
        ) -> Result<String, ExecFailure> {
            self.commands.push((file.to_owned(), args.to_vec()));
            if self.responses.is_empty() {
                Ok(String::new())
            } else {
                self.responses.remove(0)
            }
        }

        fn dispatch(&mut self, request: &RequestSpec) -> Result<Option<serde_json::Value>, String> {
            self.dispatched.push(request.body_json.clone());
            if self.dispatch_responses.is_empty() {
                Ok(None)
            } else {
                self.dispatch_responses.remove(0)
            }
        }

        fn current_exe(&self) -> Result<PathBuf, String> {
            Ok(PathBuf::from("/tmp/tightbeam"))
        }
    }

    fn local_platform() -> &'static str {
        match local_target_triple() {
            "aarch64-apple-darwin" => "Darwin arm64",
            "x86_64-apple-darwin" => "Darwin x86_64",
            "aarch64-unknown-linux-gnu" => "Linux aarch64",
            _ => "Linux x86_64",
        }
    }

    /// What a satisfied host answers the probe with. Named binaries are found; every
    /// other requirement of the run is reported MISSING, so a test that wants a green
    /// probe has to say which prerequisites it is claiming.
    fn probe_response(platform: &str, found: &[&str]) -> String {
        let mut lines = vec![platform.to_owned()];
        for binary in found {
            lines.push(format!("{binary} /usr/bin/{binary}"));
        }
        lines.push("base-dir ABSENT".to_owned());
        lines.join("\n") + "\n"
    }

    fn healthy_probe() -> String {
        probe_response(
            local_platform(),
            &["node", "npm", "rsync", "claude", "codex"],
        )
    }

    fn exec_failure(stderr: &str) -> ExecFailure {
        ExecFailure {
            message: "process exited with status 1".to_owned(),
            stdout: String::new(),
            stderr: stderr.to_owned(),
            status: Some(1),
            timed_out: false,
        }
    }

    fn unreachable(stderr: &str) -> ExecFailure {
        ExecFailure {
            status: Some(255),
            ..exec_failure(stderr)
        }
    }

    #[test]
    fn update_clients_asks_every_satellite_and_reports_each_outcome() {
        let current = env!("CARGO_PKG_VERSION");
        let mut io = FakeIo {
            responses: vec![
                Ok(format!("{current}\n")),
                Ok("0.0.9\n".to_owned()),
                Ok(format!("{}\n", local_platform())),
                Ok(String::new()),
                Ok(String::new()),
                Ok(String::new()),
                Ok(format!("{current}\n")),
                Ok(String::new()),
                Err(unreachable("connection refused")),
                Err(exec_failure("permission denied")),
            ],
            dispatch_responses: vec![Ok(Some(serde_json::json!({
                "hosts": [
                    {"name": "a-current", "ssh": "a", "cliBin": "/srv/a/bin"},
                    {"name": "b-old", "ssh": "b", "cliBin": "/srv/b/bin"},
                    {"name": "c-down", "ssh": "c", "cliBin": "/srv/c/bin"},
                    {"name": "d-refused", "ssh": "d", "cliBin": "/srv/d/bin"},
                    {"name": "e-unregistered-path", "ssh": "e", "cliBin": null}
                ]
            })))],
            ..FakeIo::default()
        };

        let error = update_clients_with(&mut io, "flynn").unwrap_err();

        assert_eq!(
            io.dispatched,
            vec![r#"{"asUser":"flynn","verb":"update-clients","params":{}}"#]
        );
        assert_eq!(io.commands[0].0, "ssh");
        assert_eq!(
            io.commands[0].1.last().unwrap(),
            "'/srv/a/bin/tightbeam' version"
        );
        assert_eq!(
            io.commands
                .iter()
                .map(|(file, _args)| file.as_str())
                .collect::<Vec<_>>(),
            vec![
                "ssh", "ssh", "ssh", "ssh", "scp", "ssh", "ssh", "ssh", "ssh", "ssh"
            ]
        );
        let transcript = io.logs.join("\n");
        assert!(transcript.contains(&format!(
            "[update-clients] a-current: already current ({current})"
        )));
        assert!(transcript.contains(&format!(
            "[update-clients] b-old: updated (0.0.9 -> {current})"
        )));
        assert!(transcript.contains("[update-clients] c-down: unreachable — connection refused"));
        assert!(
            transcript.contains("[update-clients] d-refused: question failed — permission denied")
        );
        assert!(
            transcript
                .contains("[update-clients] e-unregistered-path: refused — no CLI path registered")
        );
        assert_eq!(
            error,
            "update-clients failed for 3 host(s); see per-host outcomes above"
        );
    }

    fn one_update_host(responses: Vec<Result<String, ExecFailure>>) -> FakeIo {
        FakeIo {
            responses,
            dispatch_responses: vec![Ok(Some(serde_json::json!({
                "hosts": [
                    {"name": "satellite", "ssh": "satellite.local", "cliBin": "/srv/tightbeam/bin"}
                ]
            })))],
            ..FakeIo::default()
        }
    }

    #[test]
    fn update_clients_preserves_option_like_destinations_and_spaced_cli_paths() {
        let current = env!("CARGO_PKG_VERSION");
        let mut io = FakeIo {
            responses: vec![
                Ok("0.0.9\n".to_owned()),
                Ok(format!("{}\n", local_platform())),
                Ok(String::new()),
                Ok(String::new()),
                Ok(String::new()),
                Ok(format!("{current}\n")),
                Ok(String::new()),
            ],
            dispatch_responses: vec![Ok(Some(serde_json::json!({
                "hosts": [
                    {"name": "mistyped", "ssh": "-mistyped-host", "cliBin": "/srv/tight beam/bin"}
                ]
            })))],
            ..FakeIo::default()
        };

        update_clients_with(&mut io, "flynn").unwrap();

        assert_eq!(
            io.commands[0].1,
            [
                "-o",
                "BatchMode=yes",
                "--",
                "-mistyped-host",
                "'/srv/tight beam/bin/tightbeam' version",
            ]
        );
        assert_eq!(io.commands[3].0, "scp");
        assert_eq!(io.commands[3].1[2], "--");
        assert_eq!(io.commands[3].1[3], "/tmp/tightbeam");
        assert!(
            io.commands[3].1[4]
                .starts_with("-mistyped-host:'/srv/tight beam/bin/.tightbeam.update-")
        );
        assert!(io.commands[3].1[4].ends_with('\''));
    }

    #[test]
    fn chatty_version_answer_is_refused_as_ambiguous() {
        let current = env!("CARGO_PKG_VERSION");
        let mut io = one_update_host(vec![Ok(format!(
            "Welcome to satellite.local\nmaintenance tonight\n{current}\n"
        ))]);

        let error = update_clients_with(&mut io, "flynn").unwrap_err();

        assert_eq!(
            io.commands
                .iter()
                .map(|(file, _)| file.as_str())
                .collect::<Vec<_>>(),
            vec!["ssh"]
        );
        assert!(io.logs[0].contains("question failed"));
        assert!(error.contains("failed for 1 host"));
    }

    #[test]
    fn malformed_or_multiple_version_answers_are_refused() {
        for answer in [
            "0.1.0-warning localized text\n",
            "0.1.0\n0.1.0\n",
            "9.9.9\n0.1.0-warning localized text\n",
        ] {
            let mut io = one_update_host(vec![Ok(answer.to_owned())]);

            let error = update_clients_with(&mut io, "flynn").unwrap_err();

            assert_eq!(io.commands.len(), 1, "answer {answer:?} must not ship");
            assert!(io.logs[0].contains("question failed"));
            assert!(error.contains("failed for 1 host"));
        }
    }

    #[test]
    fn failed_version_question_does_not_ship() {
        let mut io = one_update_host(vec![Err(exec_failure("tightbeam: version refused"))]);

        let error = update_clients_with(&mut io, "flynn").unwrap_err();

        assert_eq!(
            io.commands
                .iter()
                .map(|(file, _)| file.as_str())
                .collect::<Vec<_>>(),
            vec!["ssh"]
        );
        assert!(io.logs[0].contains("question failed"));
        assert!(error.contains("failed for 1 host"));
    }

    #[test]
    fn incompatible_target_does_not_ship() {
        let remote = if local_target_triple().contains("apple") {
            "Linux x86_64"
        } else {
            "Darwin arm64"
        };
        let mut io = one_update_host(vec![Ok("0.0.9\n".to_owned()), Ok(format!("{remote}\n"))]);

        let error = update_clients_with(&mut io, "flynn").unwrap_err();

        assert_eq!(
            io.commands
                .iter()
                .map(|(file, _)| file.as_str())
                .collect::<Vec<_>>(),
            vec!["ssh", "ssh"]
        );
        assert!(io.logs[0].contains("incompatible"));
        assert!(error.contains("failed for 1 host"));
    }

    #[test]
    fn a_staged_binary_that_cannot_execute_is_removed_without_promotion() {
        let current = env!("CARGO_PKG_VERSION");
        let mut io = one_update_host(vec![
            Ok("0.0.9\n".to_owned()),
            Ok(format!("{}\n", local_platform())),
            Ok(String::new()),
            Ok(String::new()),
            Ok(String::new()),
            Err(exec_failure("cannot execute binary file")),
            Ok(String::new()),
        ]);

        let error = update_clients_with(&mut io, "flynn").unwrap_err();
        let remote_scripts = io
            .commands
            .iter()
            .filter(|(file, _)| file == "ssh")
            .filter_map(|(_, args)| args.last())
            .cloned()
            .collect::<Vec<_>>();

        assert!(remote_scripts.iter().any(|script| {
            script.contains(".tightbeam.update-") && script.ends_with(" version")
        }));
        assert!(
            remote_scripts
                .last()
                .is_some_and(|script| script.starts_with("rm -f "))
        );
        assert!(
            !remote_scripts
                .iter()
                .any(|script| script.starts_with("mv -f "))
        );
        assert!(io.logs[0].contains("cannot execute binary file"));
        assert!(error.contains("failed for 1 host"));
        assert!(
            !io.logs
                .join("\n")
                .contains(&format!("updated (0.0.9 -> {current})"))
        );
    }

    #[test]
    fn an_interrupted_copy_attempts_to_remove_its_partial_stage() {
        let mut io = FakeIo {
            responses: vec![
                Ok(String::new()),
                Err(exec_failure("copy interrupted")),
                Ok(String::new()),
            ],
            ..FakeIo::default()
        };

        let error = ship_current_cli(&mut io, false, "satellite.local", "/srv/bin").unwrap_err();

        assert_eq!(command_failure(&error), "copy interrupted");
        assert_eq!(io.commands.last().unwrap().0, "ssh");
        assert!(
            io.commands
                .last()
                .unwrap()
                .1
                .last()
                .unwrap()
                .starts_with("rm -f ")
        );
    }

    #[test]
    fn a_timed_out_command_kills_a_descendant_that_holds_its_pipes() {
        let mut io = SystemIo;
        let started = Instant::now();

        let error = io
            .exec(
                "/bin/sh",
                &["-c".to_owned(), "sleep 5 & wait".to_owned()],
                Duration::from_millis(500),
            )
            .unwrap_err();

        assert!(error.timed_out);
        assert!(error.message.contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    /// The inherited disposition has to be installed in the process that execs this test
    /// binary. Changing it in the cargo test process would auto-reap children belonging to
    /// unrelated tests running in parallel. The outer run therefore re-execs exactly this
    /// test with SIGCHLD ignored; the inner run exercises `SystemIo` in that inherited
    /// environment.
    ///
    /// The command's leader exits after forking a pipe-holding descendant. A correct
    /// executor keeps that leader as a zombie, remains armed until the deadline, and then
    /// kills the still-identified group. On linux without the parent-side reset, the
    /// kernel auto-reaps the leader, `waitid` returns ECHILD, and the executor reports a
    /// non-timeout failure after signalling a group id whose leader it no longer owns.
    #[test]
    fn an_inherited_sigchld_ignore_keeps_timeout_group_identity_reserved() {
        const INNER: &str = "TIGHTBEAM_SIGCHLD_CEREMONY_INNER";
        const DIR: &str = "TIGHTBEAM_SIGCHLD_CEREMONY_DIR";

        if std::env::var_os(INNER).is_some() {
            let dir = PathBuf::from(std::env::var_os(DIR).expect("outer test supplied temp dir"));
            let forked = dir.join("descendant-forked");
            let survived = dir.join("descendant-survived");
            let script = format!(
                "(sleep 2; echo survived > '{}') & echo forked > '{}'; exit 0",
                survived.display(),
                forked.display()
            );
            let mut io = SystemIo;
            let error = io
                .exec(
                    "/bin/sh",
                    &["-c".to_owned(), script],
                    Duration::from_millis(500),
                )
                .unwrap_err();
            let disposition_after_exec = unsafe { libc::signal(libc::SIGCHLD, libc::SIG_DFL) };

            assert!(forked.exists(), "the pipe-holding descendant never started");
            assert_eq!(
                disposition_after_exec,
                libc::SIG_DFL,
                "the executor left its inherited SIGCHLD ignore in force"
            );
            assert!(error.timed_out, "wrong failure band: {}", error.message);
            assert!(error.message.contains("timed out"));
            return;
        }

        let dir =
            std::env::temp_dir().join(format!("tightbeam-ceremony-sigchld-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        let mut command = ProcessCommand::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "ceremonies::tests::an_inherited_sigchld_ignore_keeps_timeout_group_identity_reserved",
                "--nocapture",
            ])
            .env(INNER, "1")
            .env(DIR, &dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        unsafe {
            command.pre_exec(|| {
                if libc::signal(libc::SIGCHLD, libc::SIG_IGN) == libc::SIG_ERR {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }

        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "inherited-SIGCHLD child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );

        thread::sleep(Duration::from_millis(2_100));
        assert!(
            !dir.join("descendant-survived").exists(),
            "the timed-out command left its pipe-holding descendant alive"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    fn args() -> AssimilateArgs {
        AssimilateArgs {
            ssh_dest: "flynn@work-1.local".to_owned(),
            as_user: "flynn".to_owned(),
            name: None,
            base_dir: "~/.tightbeam".to_owned(),
            harnesses: vec!["claude".to_owned(), "codex".to_owned()],
            catalog: crate::harnesses::catalog().unwrap(),
            dry_run: false,
        }
    }

    #[test]
    fn validates_harnesses() {
        let catalog = crate::harnesses::catalog().unwrap();
        assert_eq!(
            validate_harnesses(&["fixture".to_owned()], &catalog),
            Ok(())
        );
        assert_eq!(
            validate_harnesses(&["other".to_owned()], &catalog),
            Err("unsupported harness: other".to_owned())
        );
    }

    #[test]
    fn fixture_only_projection_drives_assimilation_provisioning() {
        let mut io = FakeIo {
            responses: vec![Ok(probe_response(
                local_platform(),
                &["node", "npm", "rsync", "fixture"],
            ))],
            ..FakeIo::default()
        };
        let mut fixture_args = args();
        fixture_args.dry_run = true;
        fixture_args.harnesses = vec!["fixture".to_owned()];
        fixture_args.catalog = HarnessCatalog {
            harnesses: vec![crate::harnesses::HarnessProjection {
                wire_name: "fixture".to_owned(),
                install_package: "fixture-package".to_owned(),
                cli_binary: "fixture".to_owned(),
                process_markers: vec!["fixture-acp".to_owned()],
            }],
        };

        assimilate_with(&mut io, fixture_args).unwrap();
        let transcript = io.logs.join("\n");
        assert!(transcript.contains("fixture-package"));
        assert!(!transcript.contains("claude-package"));
        assert!(!transcript.contains("codex-package"));
    }

    #[test]
    fn empty_tilde_suffix_is_shell_quoted_like_typescript() {
        assert_eq!(remote_path("~/"), "~/''");
        assert_eq!(remote_path("~/.tightbeam"), "~/.tightbeam");
    }

    #[test]
    fn local_target_is_supported_by_assimilation() {
        assert!(matches!(
            local_target_triple(),
            "aarch64-apple-darwin"
                | "x86_64-apple-darwin"
                | "aarch64-unknown-linux-gnu"
                | "x86_64-unknown-linux-gnu"
        ));
    }

    #[test]
    fn assimilate_runs_ts_step_order_and_ships_current_binary() {
        let mut io = FakeIo {
            responses: vec![
                Ok(healthy_probe()),
                Ok(String::new()),
                Ok("/Users/remote/.tightbeam\n".to_owned()),
                Ok("harvested\n".to_owned()),
                Ok("present\n".to_owned()),
                Ok(String::new()),
                Ok(String::new()),
                Ok(format!("{}\n", env!("CARGO_PKG_VERSION"))),
                Ok(String::new()),
            ],
            ..FakeIo::default()
        };
        assimilate_with(&mut io, args()).unwrap();
        assert_eq!(
            io.commands
                .iter()
                .map(|(file, _)| file.as_str())
                .collect::<Vec<_>>(),
            vec![
                "ssh", "ssh", "ssh", "ssh", "ssh", "scp", "ssh", "ssh", "ssh"
            ]
        );
        let probe = io.commands[0].1.last().unwrap();
        assert_eq!(
            io.commands[0].1[..4],
            ["-o", "BatchMode=yes", "--", "flynn@work-1.local"]
        );
        for expected in [
            "uname -sm",
            "'node'",
            "'npm'",
            "'rsync'",
            "'claude'",
            "'codex'",
        ] {
            assert!(probe.contains(expected), "probe must observe {expected}");
        }
        assert!(
            io.commands[5]
                .1
                .last()
                .unwrap()
                .contains(":'/Users/remote/.tightbeam/bin/.tightbeam.update-")
        );
        let chmod = io.commands[6].1.last().unwrap();
        assert!(chmod.starts_with("chmod +x "));
        let verify = io.commands[7].1.last().unwrap();
        assert!(verify.ends_with(" version"));
        let install = io.commands[8].1.last().unwrap();
        assert!(install.starts_with("mv -f "));
        assert!(install.ends_with("'/Users/remote/.tightbeam/bin/tightbeam'"));
        let adapter_install = io.commands[3].1.last().unwrap();
        assert!(adapter_install.contains("claude-package"));
        assert!(adapter_install.contains("codex-package"));
        assert!(!adapter_install.contains("fixture-package"));
        assert!(!adapter_install.contains("absent-package"));
        assert_eq!(
            io.dispatched,
            vec![
                r#"{"asUser":"flynn","verb":"register-host","params":{"name":"work-1.local","ssh":"flynn@work-1.local","baseDir":"/Users/remote/.tightbeam","cliBin":"/Users/remote/.tightbeam/bin","adapterBinDir":"/Users/remote/.tightbeam/adapters/node_modules/.bin"}}"#
            ]
        );
        assert!(io.logs.contains(&"[assimilate] PROBE... ok".to_owned()));
        assert!(io.logs.contains(&"[assimilate] CLI... ok".to_owned()));
    }

    #[test]
    fn dry_run_prints_commands_and_skips_register() {
        let mut io = FakeIo {
            responses: vec![Ok(healthy_probe())],
            ..FakeIo::default()
        };
        let mut dry_args = args();
        dry_args.dry_run = true;
        assimilate_with(&mut io, dry_args).unwrap();
        assert_eq!(
            io.logs
                .iter()
                .filter(|line| line.starts_with("DRY "))
                .count(),
            7
        );
        assert!(
            io.logs
                .contains(&"[assimilate] REGISTER... skipped (--dry-run)".to_owned())
        );
        assert!(io.dispatched.is_empty());
    }

    /// #73: the probe is the one step a dry run performs rather than prints, and it
    /// is the only command it runs at all. Everything that writes stays a DRY line.
    #[test]
    fn dry_run_executes_the_probe_and_nothing_else() {
        let mut io = FakeIo {
            responses: vec![Ok(healthy_probe())],
            ..FakeIo::default()
        };
        let mut dry_args = args();
        dry_args.dry_run = true;
        assimilate_with(&mut io, dry_args).unwrap();

        assert_eq!(io.commands.len(), 1, "a dry run executes only the probe");
        assert_eq!(io.commands[0].0, "ssh");
        assert!(
            !io.logs
                .iter()
                .any(|line| line.starts_with("DRY ") && line.contains("uname")),
            "the probe must run, not be printed as a plan"
        );
        for written in ["mkdir", "npm install", "chmod"] {
            assert!(
                io.logs
                    .iter()
                    .any(|line| line.starts_with("DRY ") && line.contains(written)),
                "{written} must stay dry"
            );
        }
        assert!(
            io.logs
                .iter()
                .any(|line| line.contains("node: /usr/bin/node")),
            "a dry run reports what it observed"
        );
    }

    /// The fail-before/pass-after for #73 + #76 together: a host missing a harness CLI
    /// is rejected BY THE DRY RUN. Before the fix a dry run could not fail at all, and
    /// the probe never looked for a harness CLI in either mode -- which is how a
    /// satellite assimilated cleanly and then died on `claude: command not found`.
    #[test]
    fn dry_run_fails_on_a_host_missing_a_harness_cli() {
        let mut io = FakeIo {
            responses: vec![Ok(probe_response(
                local_platform(),
                &["node", "npm", "rsync", "codex"],
            ))],
            ..FakeIo::default()
        };
        let mut dry_args = args();
        dry_args.dry_run = true;

        let reason = assimilate_with(&mut io, dry_args).unwrap_err();

        assert!(reason.contains("claude"), "{reason}");
        assert!(reason.contains("flynn@work-1.local"), "{reason}");
        assert!(reason.contains("never the vendors' software"), "{reason}");
        assert!(
            io.logs
                .iter()
                .any(|line| line.starts_with("[assimilate] PROBE... FAILED")),
            "the probe step itself must fail"
        );
        assert!(
            !io.logs
                .iter()
                .any(|line| line.starts_with("DRY ") && line.contains("npm install")),
            "a rejected host must not proceed to the install plan"
        );
    }

    /// npm was never probed though the next step runs `npm install` (#76).
    #[test]
    fn a_host_without_npm_is_rejected_before_the_adapter_install() {
        let mut io = FakeIo {
            responses: vec![Ok(probe_response(
                local_platform(),
                &["node", "rsync", "claude", "codex"],
            ))],
            ..FakeIo::default()
        };

        let reason = assimilate_with(&mut io, args()).unwrap_err();

        assert!(reason.contains("\n  npm "), "{reason}");
        assert!(reason.contains("missing 1 prerequisite"), "{reason}");
        assert_eq!(io.commands.len(), 1, "nothing runs after a failed probe");
    }

    #[test]
    fn dry_run_installs_only_selected_harness_adapters() {
        let catalog = HarnessCatalog {
            harnesses: [
                ("claude", "@agentclientprotocol/claude-agent-acp"),
                ("codex", "codex-acp"),
            ]
            .into_iter()
            .map(
                |(name, install_package)| crate::harnesses::HarnessProjection {
                    wire_name: name.to_owned(),
                    install_package: install_package.to_owned(),
                    cli_binary: name.to_owned(),
                    process_markers: Vec::new(),
                },
            )
            .collect(),
        };

        let mut codex_io = FakeIo {
            responses: vec![Ok(healthy_probe())],
            ..FakeIo::default()
        };
        let mut codex_args = args();
        codex_args.dry_run = true;
        codex_args.harnesses = vec!["codex".to_owned()];
        codex_args.catalog = catalog.clone();
        assimilate_with(&mut codex_io, codex_args).unwrap();
        let codex_plan = codex_io.logs.join("\n");
        assert!(codex_plan.contains("codex-acp"));
        assert!(!codex_plan.contains("claude-agent-acp"));

        let mut all_io = FakeIo {
            responses: vec![Ok(healthy_probe())],
            ..FakeIo::default()
        };
        let mut all_args = args();
        all_args.dry_run = true;
        all_args.harnesses = catalog.names();
        all_args.catalog = catalog;
        assimilate_with(&mut all_io, all_args).unwrap();
        let all_plan = all_io.logs.join("\n");
        assert!(all_plan.contains("codex-acp"));
        assert!(all_plan.contains("claude-agent-acp"));
    }

    #[test]
    fn architecture_mismatch_warns_and_skips_cli_step() {
        let remote = if local_target_triple().contains("apple") {
            "Linux x86_64"
        } else {
            "Darwin arm64"
        };
        let mut io = FakeIo {
            responses: vec![
                Ok(probe_response(
                    remote,
                    &["node", "npm", "rsync", "claude", "codex"],
                )),
                Ok(String::new()),
                Ok("/remote\n".to_owned()),
                Ok("present\n".to_owned()),
                Ok("present\n".to_owned()),
                Ok(String::new()),
            ],
            ..FakeIo::default()
        };
        assimilate_with(&mut io, args()).unwrap();
        assert!(!io.logs.iter().any(|line| line == "[assimilate] CLI... ok"));
        assert!(io.warnings.iter().any(|line| {
            line.contains("build for") && line.contains("re-run") && line.contains("skipping CLI")
        }));
    }

    #[test]
    fn probe_failures_name_missing_runtime_and_batch_auth() {
        // A prerequisite verdict arrives already worded, and is passed through rather
        // than re-guessed. It used to be inferred from how many lines the probe had
        // printed, which is why it could name only node or rsync and never npm.
        let verdict = ExecFailure {
            message: "npm is missing on satellite work-1.local".to_owned(),
            stdout: String::new(),
            stderr: String::new(),
            status: None,
            timed_out: false,
        };
        assert_eq!(
            probe_failure(&verdict),
            "npm is missing on satellite work-1.local"
        );
        let auth = ExecFailure {
            message: "probe failed".to_owned(),
            stdout: String::new(),
            stderr: "Permission denied (publickey).".to_owned(),
            status: Some(255),
            timed_out: false,
        };
        assert_eq!(
            probe_failure(&auth),
            "ssh authentication failed; set up ssh keys for non-interactive access"
        );
    }

    /// The provider binary is now the direct child on both platforms. Keeping one
    /// assertion in each platform CI leg prevents `script(1)` portability machinery from
    /// creeping back into either one.
    #[test]
    #[cfg(target_os = "macos")]
    fn anthropic_is_invoked_directly_on_macos() {
        let command = anthropic_setup_token_command("renamed-claude");
        assert_eq!(command.get_program(), "renamed-claude");
        assert_eq!(command.get_args().collect::<Vec<_>>(), ["setup-token"]);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn anthropic_is_invoked_directly_on_linux() {
        let command = anthropic_setup_token_command("renamed-claude");
        assert_eq!(command.get_program(), "renamed-claude");
        assert_eq!(command.get_args().collect::<Vec<_>>(), ["setup-token"]);
    }

    /// The width deliberately fits the current 109-character token, but is not a capture
    /// gate. Capture owns provider shape; the pty owns presentation.
    #[test]
    fn the_pinned_width_keeps_the_observed_token_whole_without_encoding_its_length() {
        assert_eq!(crate::pty::CEREMONY_COLUMNS, 109);
        assert!(usize::from(crate::pty::CEREMONY_COLUMNS) >= 109);
        assert_ne!(crate::pty::CEREMONY_COLUMNS, 108);
    }

    #[test]
    fn staging_path_reads_the_wire_shape_the_gateway_actually_sends() {
        // Verbatim from a live gateway on shrdlu (2026-07-27), captured off the wire
        // during the production-install smoke. Every response key is lower-camelCase
        // because router.ex camelizes atom keys on the way out.
        let ready: serde_json::Value = serde_json::from_str(
            r#"{"provider":"anthropic","stagingPath":"/tmp/tightbeam-anthropic-onboard-7","leaseId":"lease-7","status":"ready"}"#,
        )
        .unwrap();

        assert_eq!(
            staging_path(&ready).unwrap(),
            "/tmp/tightbeam-anthropic-onboard-7"
        );
        assert_eq!(lease_id(&ready).unwrap(), "lease-7");
    }

    #[test]
    fn staging_path_rejects_the_snake_case_key_that_never_shipped() {
        // The bug this pins: reading "staging_path" matched nothing, so onboard failed
        // identically on every machine. A snake_case body must NOT satisfy the read --
        // otherwise a future "be liberal in what you accept" edit would hide a real
        // wire-contract break instead of surfacing it.
        let wrong: serde_json::Value =
            serde_json::from_str(r#"{"staging_path":"/tmp/x","status":"ready"}"#).unwrap();

        assert!(staging_path(&wrong).is_err());
    }

    #[test]
    fn default_name_strips_user_prefix() {
        assert_eq!(default_assimilate_name("worker.local"), "worker.local");
        assert_eq!(
            default_assimilate_name("flynn@worker.local"),
            "worker.local"
        );
    }

    /// The gateway substitutes its own hostname for an unnamed machine, so an unnamed
    /// machine is safe in exactly one place. Everywhere else must refuse rather than
    /// guess -- a derived name that is not the registered one comes back `unknown_host`.
    #[test]
    fn an_unnamed_machine_is_allowed_only_where_the_gateway_default_is_correct() {
        assert_eq!(
            onboard_machine(Some("work-1".to_owned()), dispatch::Provisioned::Absent),
            Ok(Some("work-1".to_owned())),
            "the environment wins outright, including for agent shells"
        );
        assert_eq!(
            onboard_machine(None, dispatch::Provisioned::GatewayHost),
            Ok(None),
            "on the gateway host its own hostname IS this machine"
        );
        assert_eq!(
            onboard_machine(
                None,
                dispatch::Provisioned::Satellite {
                    machine: Some("work-1".to_owned())
                }
            ),
            Ok(Some("work-1".to_owned())),
            "a provisioned satellite needs no operator env"
        );

        for invalid in [
            dispatch::Provisioned::Satellite { machine: None },
            dispatch::Provisioned::Absent,
        ] {
            let reason = onboard_machine(None, invalid).unwrap_err();
            assert!(reason.contains("TIGHTBEAM_MACHINE"), "{reason}");
            assert!(reason.contains("REGISTERED"), "{reason}");
            assert!(reason.contains("onboard ITSELF"), "{reason}");
        }

        let stale =
            onboard_machine(None, dispatch::Provisioned::Satellite { machine: None }).unwrap_err();
        assert!(stale.contains("gateway.json has a URL"), "{stale}");
        assert!(!stale.contains("there is no gateway.json"), "{stale}");
    }

    /// Both legs failed on a missing harness CLI and neither said so: openai surfaced a
    /// bare `No such file or directory (os error 2)`, and anthropic reported that the
    /// setup-token "was not captured" -- blaming token parsing for a `command not found`.
    /// Now each names the binary, this host, the PATH it searched, and the repair.
    #[test]
    fn both_onboarding_legs_refuse_by_name_when_the_harness_cli_is_absent() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam-absent-harness-cli-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let empty = root.display().to_string();

        for (binary, harness) in [("codex", "codex"), ("claude", "claude")] {
            let reason = require_on_path(
                binary,
                &empty,
                &preflight::missing_harness_cli(binary, harness, "eurisko", &empty),
            )
            .unwrap_err();
            assert!(reason.contains(binary), "{reason}");
            assert!(reason.contains("eurisko"), "{reason}");
            assert!(
                reason.contains(&empty),
                "the PATH searched must be shown: {reason}"
            );
            assert!(
                reason.contains(&format!("Install {binary} on eurisko and re-run")),
                "{reason}"
            );
            assert!(
                !reason.contains("os error 2") && !reason.contains("not captured"),
                "neither old message may survive: {reason}"
            );
        }

        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The binary comes from the projection, so a renamed vendor CLI follows the catalog.
    /// The test catalog names it `claude`, which is also the fallback -- so this asserts
    /// the lookup path exists rather than that the two happen to agree.
    #[test]
    fn the_harness_cli_name_comes_from_the_projection() {
        let catalog = crate::harnesses::catalog().unwrap();
        for (provider, harness) in [("openai", "codex"), ("anthropic", "claude")] {
            let projected = catalog
                .harnesses
                .iter()
                .find(|projection| projection.wire_name == harness)
                .map(|projection| projection.cli_binary.clone());
            assert_eq!(
                projected,
                Some(harness.to_owned()),
                "{provider}: the projection must state {harness}'s CLI binary"
            );
        }
        let endpoint = Endpoint {
            base: "https://ceremony.test".to_owned(),
            token: "tbc_test".to_owned(),
            origin: crate::dispatch::Origin::Provisioned,
        };
        let ceremony = Ceremony {
            endpoint: &endpoint,
            deadline: Instant::now() + Duration::from_secs(1_800),
            load_harnesses: &|_, _| Ok(None),
        };
        assert_eq!(
            harness_cli("nonesuch", &ceremony),
            Err("unsupported provider: nonesuch".to_owned())
        );
    }
}
