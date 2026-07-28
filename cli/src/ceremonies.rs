//! Interactive `setup` and `assimilate` ceremonies.

use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::{Command as ProcessCommand, Stdio};

use crate::args::{AssimilateArgs, Identity};
use crate::dispatch::{self, RequestSpec};
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

pub fn onboard(identity: &Identity, provider: &str) -> Result<(), String> {
    let machine = std::env::var("TIGHTBEAM_MACHINE").ok();
    let begin = dispatch::build_onboard_phase_request(
        identity,
        provider,
        "begin",
        machine.as_deref(),
        None,
    );
    let ready = dispatch::send(&begin)?
        .ok_or_else(|| "onboarding did not return a staging path".to_owned())?;
    let staging = staging_path(&ready)?;

    let interactive = run_provider_onboarding(provider, staging);

    if let Err(reason) = interactive {
        let _ = fs::remove_dir_all(staging);
        let classified = if reason.contains("unsupported (no subscription)") {
            Some("unsupported_no_subscription")
        } else {
            None
        };
        let cancel = dispatch::build_onboard_phase_request(
            identity,
            provider,
            "cancel",
            machine.as_deref(),
            classified,
        );
        let _ = dispatch::send(&cancel);
        return Err(reason);
    }

    let finish = dispatch::build_onboard_phase_request(
        identity,
        provider,
        "finish",
        machine.as_deref(),
        None,
    );
    match dispatch::send(&finish) {
        Ok(Some(result)) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&result).expect("JSON value serializes")
            );
        }
        Ok(None) => {}
        Err(reason) => {
            let _ = fs::remove_dir_all(staging);
            let cancel = dispatch::build_onboard_phase_request(
                identity,
                provider,
                "cancel",
                machine.as_deref(),
                None,
            );
            let _ = dispatch::send(&cancel);
            return Err(reason);
        }
    }
    Ok(())
}

fn run_provider_onboarding(provider: &str, staging: &str) -> Result<(), String> {
    match provider {
        "openai" => run_openai_onboarding(staging),
        "anthropic" => run_anthropic_onboarding(staging),
        #[cfg(test)]
        "fixture-provider" => std::fs::write(
            std::path::Path::new(staging).join("fixture.json"),
            "fixture-provider-credential",
        )
        .map_err(|error| error.to_string()),
        _ => Err(format!("unsupported provider: {provider}")),
    }
}

fn run_openai_onboarding(staging: &str) -> Result<(), String> {
    let status = ProcessCommand::new("codex")
        .args(["login", "--device-auth"])
        .env("CODEX_HOME", staging)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| error.to_string())?;

    if status.success() {
        Ok(())
    } else {
        Err(format!("OpenAI device-code onboarding failed: {status}"))
    }
}

/// `script(1)` argument order, which is NOT portable.
///
/// The wrapper exists only to give `claude setup-token` a TTY (it refuses to run
/// without one) and to capture the transcript `capture_setup_token` parses. The two
/// implementations take the command in incompatible ways:
///
/// - BSD/macOS: `script [-q] <file> <command> [args...]`
/// - util-linux: `script [-q] -c "<command>" <file>` — extra trailing args are an
///   error, so the BSD form fails with "unexpected number of arguments"
///
/// Shipping only the BSD form made the entire Anthropic credential path unreachable
/// on every Linux host: it failed before contacting Anthropic, so no credential or
/// network fix could help, and the openai path worked because it execs `codex`
/// directly with no wrapper. Found on shrdlu during the production-install smoke.
///
/// Dispatched at COMPILE time, like the containment seam: a platform with no named
/// form fails to build rather than failing at a customer's terminal.
#[cfg(target_os = "macos")]
fn script_args(transcript: &str) -> Vec<String> {
    vec![
        "-q".to_owned(),
        transcript.to_owned(),
        "claude".to_owned(),
        "setup-token".to_owned(),
    ]
}

#[cfg(target_os = "linux")]
fn script_args(transcript: &str) -> Vec<String> {
    vec![
        "-q".to_owned(),
        "-c".to_owned(),
        "claude setup-token".to_owned(),
        transcript.to_owned(),
    ]
}

fn run_anthropic_onboarding(staging: &str) -> Result<(), String> {
    let transcript = PathBuf::from(staging).join("setup-token.log");
    let transcript_path = transcript
        .to_str()
        .ok_or_else(|| "invalid onboarding staging path".to_owned())?;

    // Create the transcript owner-only BEFORE `script` does. It opens the file
    // O_WRONLY|O_CREAT|O_TRUNC and leaves the mode of a file that already exists
    // alone, so this is the only place 0600 can be established -- and on a successful
    // run this file holds a live year-long credential in cleartext.
    fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&transcript)
        .map_err(|error| error.to_string())?;

    let status = ProcessCommand::new("script")
        .args(script_args(transcript_path))
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| error.to_string())?;

    // Bytes, not `read_to_string`: one invalid UTF-8 byte anywhere in a pty transcript
    // made that call fail, and `unwrap_or_default` turned the failure into an empty
    // string -- indistinguishable from claude having printed nothing at all.
    let raw = fs::read(&transcript).unwrap_or_default();

    if !status.success() {
        // Read the SCREEN, not the byte stream. The TUI positions each word with a
        // cursor jump instead of writing the spaces between them, so a phrase is only
        // reliably contiguous once the transcript has been replayed.
        let screen = crate::screen::displayed_lines(&raw).join("\n");
        if screen.to_ascii_lowercase().contains("subscription") {
            return Err("needs_onboarding: unsupported (no subscription)".to_owned());
        }
        return Err(format!("Anthropic setup-token onboarding failed: {status}"));
    }

    let token = match crate::screen::capture_setup_token(&raw) {
        Some(token) => token,
        None => return Err(capture_failed(&raw)),
    };
    let path = PathBuf::from(staging).join("oauth-token");
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| error.to_string())?;
    writeln!(file, "{token}").map_err(|error| error.to_string())?;

    // The preserved evidence is only worth keeping while a failure is unexplained.
    let _ = fs::remove_file(preserved_transcript());
    Ok(())
}

/// Where a transcript is kept when the token could not be read out of it.
///
/// One fixed path, so at most one such file exists: the next attempt overwrites it and
/// a successful capture deletes it. It is not a log to accumulate -- it can contain a
/// live credential, which is why it is written 0600 and why it does not linger.
fn preserved_transcript() -> PathBuf {
    crate::base_dir::resolve().join("setup-token-failure.log")
}

/// Say what was looked for, and keep the evidence needed to work out why it was absent.
///
/// The transcript used to be destroyed on this path by BOTH sides: `onboard` removes
/// the staging directory before cancelling, and the gateway's `cancel_onboard` does its
/// own `File.rm_rf!` on it (`Tightbeam.Credentials`). So merely declining to delete it
/// here would not have been enough -- it has to be copied out before the cancel. Two of
/// the operator's single-use authorization codes were spent with nothing left to
/// diagnose from, and the message blamed token parsing without saying what it parsed.
fn capture_failed(raw: &[u8]) -> String {
    let destination = preserved_transcript();
    let kept = fs::create_dir_all(destination.parent().unwrap_or(&destination))
        .and_then(|()| {
            fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .open(&destination)
        })
        .and_then(|mut file| file.write_all(raw));

    let evidence = match kept {
        Ok(()) => format!(
            "The transcript is preserved at {} (mode 0600, replaced by the next attempt \
             and removed after a successful capture). Treat it as a credential: if claude \
             displayed a token, it is in there.",
            destination.display()
        ),
        Err(error) => format!(
            "The transcript could NOT be preserved ({}), and the staging directory is \
             about to be removed, so this attempt leaves nothing to diagnose from.",
            error
        ),
    };

    format!(
        "Anthropic setup-token was not captured: claude ran and exited successfully, but \
         {}. {evidence}",
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
}

trait CeremonyIo {
    fn log(&mut self, message: &str);
    fn warn(&mut self, message: &str);
    fn exec(&mut self, file: &str, args: &[String]) -> Result<String, ExecFailure>;
    fn dispatch(&mut self, request: &RequestSpec) -> Result<(), String>;
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

    fn exec(&mut self, file: &str, args: &[String]) -> Result<String, ExecFailure> {
        let result = ProcessCommand::new(file)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|error| ExecFailure {
                message: error.to_string(),
                stdout: String::new(),
                stderr: String::new(),
            })?;
        if result.status.success() {
            Ok(String::from_utf8_lossy(&result.stdout).into_owned())
        } else {
            Err(ExecFailure {
                message: format!("process exited with status {}", result.status),
                stdout: String::from_utf8_lossy(&result.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&result.stderr).into_owned(),
            })
        }
    }

    fn dispatch(&mut self, request: &RequestSpec) -> Result<(), String> {
        dispatch::send(request).map(|_| ())
    }

    fn current_exe(&self) -> Result<PathBuf, String> {
        std::env::current_exe().map_err(|error| error.to_string())
    }
}

pub fn assimilate(args: AssimilateArgs) -> Result<(), String> {
    let mut io = SystemIo;
    assimilate_with(&mut io, args)
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
                args.ssh_dest.clone(),
                preflight::script(&requirements, &remote_path(&args.base_dir)),
            ],
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
            ssh(
                io,
                dry_run,
                &args.ssh_dest,
                &format!("mkdir -p {}", remote_path(&cli_bin)),
            )?;
            let executable = io.current_exe().map_err(|message| ExecFailure {
                message,
                stdout: String::new(),
                stderr: String::new(),
            })?;
            run_command(
                io,
                dry_run,
                "scp",
                &[
                    "-o".to_owned(),
                    "BatchMode=yes".to_owned(),
                    executable.display().to_string(),
                    format!("{}:{cli_bin}/tightbeam", args.ssh_dest),
                ],
            )?;
            ssh(
                io,
                dry_run,
                &args.ssh_dest,
                &format!("chmod +x {}", remote_path(&format!("{cli_bin}/tightbeam"))),
            )?;
            Ok(())
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
        match io.dispatch(&request) {
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
        io.exec(file, args)
    }
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

    #[test]
    fn fixture_provider_materializes_its_staged_credential() {
        let staging =
            std::env::temp_dir().join(format!("tightbeam-fixture-provider-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).unwrap();

        assert_eq!(
            run_provider_onboarding("fixture-provider", staging.to_str().unwrap()),
            Ok(())
        );
        assert_eq!(
            std::fs::read_to_string(staging.join("fixture.json")).unwrap(),
            "fixture-provider-credential"
        );

        std::fs::remove_dir_all(staging).unwrap();
    }

    #[derive(Default)]
    struct FakeIo {
        logs: Vec<String>,
        warnings: Vec<String>,
        commands: Vec<(String, Vec<String>)>,
        responses: Vec<Result<String, ExecFailure>>,
        dispatched: Vec<String>,
    }

    impl CeremonyIo for FakeIo {
        fn log(&mut self, message: &str) {
            self.logs.push(message.to_owned());
        }

        fn warn(&mut self, message: &str) {
            self.warnings.push(message.to_owned());
        }

        fn exec(&mut self, file: &str, args: &[String]) -> Result<String, ExecFailure> {
            self.commands.push((file.to_owned(), args.to_vec()));
            if self.responses.is_empty() {
                Ok(String::new())
            } else {
                self.responses.remove(0)
            }
        }

        fn dispatch(&mut self, request: &RequestSpec) -> Result<(), String> {
            self.dispatched.push(request.body_json.clone());
            Ok(())
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
                id: "fixture".to_owned(),
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
                Ok(String::new()),
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
            vec!["ssh", "ssh", "ssh", "ssh", "ssh", "scp", "ssh"]
        );
        let probe = io.commands[0].1.last().unwrap();
        assert_eq!(
            io.commands[0].1[..3],
            ["-o", "BatchMode=yes", "flynn@work-1.local"]
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
                .ends_with(":/Users/remote/.tightbeam/bin/tightbeam")
        );
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
            5
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
                    id: name.to_owned(),
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
        };
        assert_eq!(
            probe_failure(&verdict),
            "npm is missing on satellite work-1.local"
        );
        let auth = ExecFailure {
            message: "probe failed".to_owned(),
            stdout: String::new(),
            stderr: "Permission denied (publickey).".to_owned(),
        };
        assert_eq!(
            probe_failure(&auth),
            "ssh authentication failed; set up ssh keys for non-interactive access"
        );
    }

    /// The BSD and util-linux forms are mutually incompatible, and shipping only the
    /// BSD one made Anthropic onboarding impossible on every Linux host. Each arm is
    /// asserted on its own platform, so the CI matrix proves both rather than proving
    /// whichever one the developer happens to be sitting on.
    #[test]
    #[cfg(target_os = "macos")]
    fn script_args_use_the_bsd_form_on_macos() {
        assert_eq!(
            script_args("/tmp/t.log"),
            vec!["-q", "/tmp/t.log", "claude", "setup-token"]
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn script_args_use_the_util_linux_form_on_linux() {
        // util-linux takes the command via -c and allows at most one file argument;
        // trailing args are "unexpected number of arguments" and exit 1.
        assert_eq!(
            script_args("/tmp/t.log"),
            vec!["-q", "-c", "claude setup-token", "/tmp/t.log"]
        );
    }

    #[test]
    fn staging_path_reads_the_wire_shape_the_gateway_actually_sends() {
        // Verbatim from a live gateway on shrdlu (2026-07-27), captured off the wire
        // during the production-install smoke. Every response key is lower-camelCase
        // because router.ex camelizes atom keys on the way out.
        let ready: serde_json::Value = serde_json::from_str(
            r#"{"provider":"anthropic","stagingPath":"/tmp/tightbeam-anthropic-onboard-7","status":"ready"}"#,
        )
        .unwrap();

        assert_eq!(
            staging_path(&ready).unwrap(),
            "/tmp/tightbeam-anthropic-onboard-7"
        );
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
}
