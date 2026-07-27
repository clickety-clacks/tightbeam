//! Interactive `setup` and `assimilate` ceremonies.

use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::{Command as ProcessCommand, Stdio};

use crate::args::{AssimilateArgs, Identity};
use crate::dispatch::{self, RequestSpec};
use crate::harnesses::HarnessCatalog;

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

fn run_anthropic_onboarding(staging: &str) -> Result<(), String> {
    let transcript = PathBuf::from(staging).join("setup-token.log");
    let status = ProcessCommand::new("script")
        .args([
            "-q",
            transcript
                .to_str()
                .ok_or_else(|| "invalid onboarding staging path".to_owned())?,
            "claude",
            "setup-token",
        ])
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| error.to_string())?;
    let output = fs::read_to_string(&transcript).unwrap_or_default();

    if !status.success() {
        if output.to_ascii_lowercase().contains("subscription") {
            return Err("needs_onboarding: unsupported (no subscription)".to_owned());
        }
        return Err(format!("Anthropic setup-token onboarding failed: {status}"));
    }

    let token = capture_setup_token(&output)
        .ok_or_else(|| "Anthropic setup-token was not captured".to_owned())?;
    let path = PathBuf::from(staging).join("oauth-token");
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| error.to_string())?;
    writeln!(file, "{token}").map_err(|error| error.to_string())
}

fn capture_setup_token(output: &str) -> Option<String> {
    output.split_whitespace().rev().find_map(|word| {
        let token = word
            .trim_matches(|character: char| {
                !(character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
            })
            .to_owned();
        token.starts_with("sk-ant-oat").then_some(token)
    })
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

    let probe_output = step(io, "PROBE", probe_failure, |io| {
        ssh(
            io,
            dry_run,
            &args.ssh_dest,
            "uname -sm && command -v node && command -v rsync",
        )
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
        let resolved = ssh(
            io,
            dry_run,
            &args.ssh_dest,
            &format!("cd {} && pwd", remote_path(&args.base_dir)),
        )?;
        Ok(if dry_run {
            args.base_dir.clone()
        } else {
            resolved.trim().to_owned()
        })
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
    let remote_target = target_from_probe(&probe_output);
    let cli_compatible = dry_run || remote_target.as_deref() == Some(local_target_triple());
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

fn probe_failure(error: &ExecFailure) -> String {
    let reason = command_failure(error);
    let lower = reason.to_ascii_lowercase();
    if lower.contains("permission denied")
        || lower.contains("publickey")
        || lower.contains("authentication")
    {
        return "ssh authentication failed; set up ssh keys for non-interactive access".to_owned();
    }
    let lines = error
        .stdout
        .trim()
        .lines()
        .filter(|line| !line.is_empty())
        .count();
    if lines < 2 {
        "node is missing on the satellite; install node and retry".to_owned()
    } else if lines < 3 {
        "rsync is missing on the satellite; install rsync and retry".to_owned()
    } else {
        reason
    }
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
        let mut io = FakeIo::default();
        let mut fixture_args = args();
        fixture_args.dry_run = true;
        fixture_args.harnesses = vec!["fixture".to_owned()];
        fixture_args.catalog = HarnessCatalog {
            harnesses: vec![crate::harnesses::HarnessProjection {
                id: "fixture".to_owned(),
                wire_name: "fixture".to_owned(),
                install_package: "fixture-package".to_owned(),
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
    fn captures_the_non_rotating_claude_setup_token() {
        assert_eq!(
            capture_setup_token("browser output\nsk-ant-oat01-example\r\n"),
            Some("sk-ant-oat01-example".to_owned())
        );
        assert_eq!(capture_setup_token("no token here"), None);
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
                Ok(format!(
                    "{}\n/node\n/rsync\n",
                    match local_target_triple() {
                        "aarch64-apple-darwin" => "Darwin arm64",
                        "x86_64-apple-darwin" => "Darwin x86_64",
                        "aarch64-unknown-linux-gnu" => "Linux aarch64",
                        _ => "Linux x86_64",
                    }
                )),
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
        assert_eq!(
            io.commands[0].1,
            vec![
                "-o",
                "BatchMode=yes",
                "flynn@work-1.local",
                "uname -sm && command -v node && command -v rsync"
            ]
        );
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
        let mut io = FakeIo::default();
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
                    process_markers: Vec::new(),
                },
            )
            .collect(),
        };

        let mut codex_io = FakeIo::default();
        let mut codex_args = args();
        codex_args.dry_run = true;
        codex_args.harnesses = vec!["codex".to_owned()];
        codex_args.catalog = catalog.clone();
        assimilate_with(&mut codex_io, codex_args).unwrap();
        let codex_plan = codex_io.logs.join("\n");
        assert!(codex_plan.contains("codex-acp"));
        assert!(!codex_plan.contains("claude-agent-acp"));

        let mut all_io = FakeIo::default();
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
                Ok(format!("{remote}\n/node\n/rsync\n")),
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
        let missing = ExecFailure {
            message: "probe failed".to_owned(),
            stdout: "Linux x86_64\n".to_owned(),
            stderr: String::new(),
        };
        assert_eq!(
            probe_failure(&missing),
            "node is missing on the satellite; install node and retry"
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
