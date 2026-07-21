//! Interactive `setup` and `assimilate` ceremonies.

use std::fs;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::{Command as ProcessCommand, Stdio};

use crate::args::{AssimilateArgs, InitArgs, SetupArgs};
use crate::dispatch::{self, RequestSpec};

#[derive(Clone, Copy)]
struct LoginFlow {
    env_var: &'static str,
    executable: &'static str,
    args: &'static [&'static str],
    credential_file: &'static str,
}

fn login_flow(harness: &str) -> Option<LoginFlow> {
    match harness {
        "claude" => Some(LoginFlow {
            env_var: "CLAUDE_CONFIG_DIR",
            executable: "claude",
            args: &["setup-token"],
            credential_file: ".claude/.credentials.json",
        }),
        "codex" => Some(LoginFlow {
            env_var: "CODEX_HOME",
            executable: "codex",
            args: &["login"],
            credential_file: ".codex/auth.json",
        }),
        _ => None,
    }
}

fn validate_harnesses(harnesses: &[String]) -> Result<(), String> {
    for harness in harnesses {
        if login_flow(harness).is_none() {
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
    fn terminal(&self) -> bool;
    fn exec(&mut self, file: &str, args: &[String]) -> Result<String, ExecFailure>;
    fn exec_at(
        &mut self,
        directory: &Path,
        file: &str,
        args: &[String],
    ) -> Result<String, ExecFailure> {
        let _ = directory;
        self.exec(file, args)
    }
    fn exec_interactive(
        &mut self,
        file: &str,
        args: &[String],
        env: &[(String, String)],
    ) -> Result<(), ExecFailure>;
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

    fn terminal(&self) -> bool {
        std::io::stdin().is_terminal() && std::io::stdout().is_terminal()
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

    fn exec_at(
        &mut self,
        directory: &Path,
        file: &str,
        args: &[String],
    ) -> Result<String, ExecFailure> {
        let result = ProcessCommand::new(file)
            .args(args)
            .current_dir(directory)
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

    fn exec_interactive(
        &mut self,
        file: &str,
        args: &[String],
        env: &[(String, String)],
    ) -> Result<(), ExecFailure> {
        let status = ProcessCommand::new(file)
            .args(args)
            .envs(env.iter().cloned())
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .map_err(|error| ExecFailure {
                message: error.to_string(),
                stdout: String::new(),
                stderr: String::new(),
            })?;
        if status.success() {
            Ok(())
        } else {
            Err(ExecFailure {
                message: format!("process exited with status {status}"),
                stdout: String::new(),
                stderr: String::new(),
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

pub fn setup(args: SetupArgs) -> Result<(), String> {
    let mut io = SystemIo;
    setup_with(&mut io, args)
}

pub fn init(args: InitArgs) -> Result<(), String> {
    let mut io = SystemIo;
    init_with(&mut io, args)
}

fn init_with(io: &mut dyn CeremonyIo, args: InitArgs) -> Result<(), String> {
    let base_dir = args.base_dir.unwrap_or_else(default_base_dir);
    let project_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the CLI crate lives inside the Tightbeam project");
    let command_args = vec![
        "tightbeam.init".to_owned(),
        "--base-dir".to_owned(),
        base_dir,
    ];
    let output = io
        .exec_at(project_dir, "mix", &command_args)
        .map_err(|error| command_failure(&error))?;

    if !output.trim().is_empty() {
        io.log(output.trim());
    }
    Ok(())
}

fn setup_with(io: &mut dyn CeremonyIo, args: SetupArgs) -> Result<(), String> {
    validate_harnesses(&args.harnesses)?;
    let base_dir = args.base_dir.unwrap_or_else(default_base_dir);
    if !io.terminal() {
        return Err(setup_non_tty_message(&base_dir, &args.harnesses));
    }

    for harness in &args.harnesses {
        let flow = login_flow(harness).expect("harnesses were validated");
        let auth_dir = Path::new(&base_dir).join("auth").join(harness);
        let credential_name = Path::new(flow.credential_file)
            .file_name()
            .expect("credential file has a basename");
        let target = auth_dir.join(credential_name);
        fs::create_dir_all(&auth_dir).map_err(|error| error.to_string())?;

        if target.exists() && !args.force {
            io.log(&format!(
                "[setup] {harness}: credentials already present ({}); use --force to redo",
                target.display()
            ));
            continue;
        }

        let command_text = std::iter::once(flow.executable)
            .chain(flow.args.iter().copied())
            .collect::<Vec<_>>()
            .join(" ");
        io.log(&format!(
            "[setup] {harness}: starting the harness's own login ({command_text})..."
        ));
        let command_args = flow
            .args
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<Vec<_>>();
        io.exec_interactive(
            flow.executable,
            &command_args,
            &[(flow.env_var.to_owned(), auth_dir.display().to_string())],
        )
        .map_err(|error| command_failure(&error))?;
        io.log(&format!(
            "[setup] {harness}: done — this org now holds its own {harness} grant"
        ));
        if harness == "claude" {
            io.log(&format!(
                "[setup] {harness}: if a long-lived token was printed, save it: umask 077; pbpaste > {}/oauth-token  (or paste it into that file)",
                auth_dir.display()
            ));
        }
    }
    Ok(())
}

fn default_base_dir() -> String {
    std::env::var("TIGHTBEAM_HOME")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".tightbeam")
                .display()
                .to_string()
        })
}

pub fn setup_non_tty_message(base_dir: &str, harnesses: &[String]) -> String {
    let commands = harnesses
        .iter()
        .filter_map(|harness| login_flow(harness).map(|flow| (harness, flow)))
        .map(|(harness, flow)| {
            let command = std::iter::once(flow.executable)
                .chain(flow.args.iter().copied())
                .collect::<Vec<_>>()
                .join(" ");
            format!("  {}={base_dir}/auth/{harness} {command}", flow.env_var)
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!("setup needs an interactive terminal. Run manually:\n{commands}")
}

fn credential_status(output: &str) -> String {
    let status = output.trim();
    if status.is_empty() {
        "missing".to_owned()
    } else {
        status.to_owned()
    }
}

pub fn assimilate(args: AssimilateArgs) -> Result<(), String> {
    let mut io = SystemIo;
    assimilate_with(&mut io, args)
}

fn assimilate_with(io: &mut dyn CeremonyIo, args: AssimilateArgs) -> Result<(), String> {
    validate_harnesses(&args.harnesses)?;
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

    let mut credentials = Vec::<(String, String)>::new();
    step(io, "CREDENTIALS", command_failure, |io| {
        for harness in &args.harnesses {
            let flow = login_flow(harness).expect("harnesses were validated");
            let source = remote_path(&format!("~/{}", flow.credential_file));
            let credential_name = Path::new(flow.credential_file)
                .file_name()
                .expect("credential file has basename")
                .to_string_lossy();
            let target = remote_path(&format!("{resolved_base}/auth/{harness}/{credential_name}"));
            let script = format!(
                "if [ -f {source} ]; then if [ -e {target} ]; then printf 'present\\n'; else cp {source} {target}; printf 'harvested\\n'; fi; else printf 'missing\\n'; fi"
            );
            let output = ssh(io, dry_run, &args.ssh_dest, &script)?;
            let mut status = credential_status(&output);
            if status == "missing" && args.push_credentials {
                let local_credential = PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                    .join(flow.credential_file);
                run_command(
                    io,
                    dry_run,
                    "scp",
                    &[
                        "-o".to_owned(),
                        "BatchMode=yes".to_owned(),
                        local_credential.display().to_string(),
                        format!("{}:{resolved_base}/auth/{harness}/", args.ssh_dest),
                    ],
                )?;
                status = "pushed".to_owned();
                io.log(&format!(
                    "[assimilate] CREDENTIALS: PUSHED LOCAL {harness} credentials to {}",
                    args.ssh_dest
                ));
            } else if status == "missing" && !dry_run {
                io.warn(&format!(
                    "[assimilate] WARNING: no {harness} credentials found on the satellite; continuing"
                ));
            }
            credentials.push((harness.clone(), status));
        }
        Ok(())
    })?;

    if !dry_run && !args.no_onboard {
        for (harness, status) in &mut credentials {
            if status != "missing" {
                continue;
            }
            let harness = harness.clone();
            let flow = login_flow(&harness).expect("harnesses were validated");
            let auth_dir = format!("{resolved_base}/auth/{harness}");
            if io.terminal() {
                let remote_command = format!(
                    "env {}={} {}",
                    flow.env_var,
                    remote_path(&auth_dir),
                    std::iter::once(flow.executable)
                        .chain(flow.args.iter().copied())
                        .collect::<Vec<_>>()
                        .join(" ")
                );
                step(io, &format!("ONBOARD {harness}"), command_failure, |io| {
                    io.exec_interactive(
                        "ssh",
                        &["-t".to_owned(), args.ssh_dest.clone(), remote_command],
                        &[],
                    )
                })?;
                *status = "onboarded".to_owned();
            } else {
                io.warn(&onboard_warning(&harness, &resolved_base));
            }
        }
    }

    step(io, "ADAPTERS", command_failure, |io| {
        ssh(
            io,
            dry_run,
            &args.ssh_dest,
            &format!(
                "cd {} && npm install --prefix adapters @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp",
                remote_path(&resolved_base)
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
    if dry_run {
        io.log("  credentials: dry run; not checked");
    } else {
        for (label, status) in [
            ("onboarded (own grant)", "onboarded"),
            ("harvested", "harvested"),
            ("already present", "present"),
            ("pushed", "pushed"),
            ("missing", "missing"),
        ] {
            io.log(&format!(
                "  credentials {label}: {}",
                by_status(&credentials, status)
            ));
        }
    }
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

pub fn onboard_warning(harness: &str, resolved_base: &str) -> String {
    let flow = login_flow(harness).expect("warning requested for supported harness");
    let command = std::iter::once(flow.executable)
        .chain(flow.args.iter().copied())
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "[assimilate] no terminal for {harness} onboarding — run on the satellite: {}={resolved_base}/auth/{harness} {command}",
        flow.env_var
    )
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

fn by_status(credentials: &[(String, String)], status: &str) -> String {
    let names = credentials
        .iter()
        .filter(|(_, value)| value == status)
        .map(|(harness, _)| harness.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    if names.is_empty() {
        "none".to_owned()
    } else {
        names
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeIo {
        logs: Vec<String>,
        warnings: Vec<String>,
        commands: Vec<(String, Vec<String>)>,
        responses: Vec<Result<String, ExecFailure>>,
        terminal: bool,
        dispatched: Vec<String>,
    }

    impl CeremonyIo for FakeIo {
        fn log(&mut self, message: &str) {
            self.logs.push(message.to_owned());
        }

        fn warn(&mut self, message: &str) {
            self.warnings.push(message.to_owned());
        }

        fn terminal(&self) -> bool {
            self.terminal
        }

        fn exec(&mut self, file: &str, args: &[String]) -> Result<String, ExecFailure> {
            self.commands.push((file.to_owned(), args.to_vec()));
            if self.responses.is_empty() {
                Ok(String::new())
            } else {
                self.responses.remove(0)
            }
        }

        fn exec_interactive(
            &mut self,
            file: &str,
            args: &[String],
            _env: &[(String, String)],
        ) -> Result<(), ExecFailure> {
            self.commands.push((file.to_owned(), args.to_vec()));
            Ok(())
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
            push_credentials: false,
            no_onboard: true,
            dry_run: false,
        }
    }

    #[test]
    fn validates_harnesses_and_returns_non_tty_setup_commands() {
        assert_eq!(
            setup_non_tty_message("/org", &["claude".to_owned(), "codex".to_owned()]),
            "setup needs an interactive terminal. Run manually:\n  CLAUDE_CONFIG_DIR=/org/auth/claude claude setup-token\n  CODEX_HOME=/org/auth/codex codex login"
        );
        assert_eq!(
            validate_harnesses(&["other".to_owned()]),
            Err("unsupported harness: other".to_owned())
        );
    }

    #[test]
    fn init_invokes_the_elixir_seed_task() {
        let mut io = FakeIo::default();
        io.responses
            .push(Ok("Initialized /org/identity\n".to_owned()));

        assert_eq!(
            init_with(
                &mut io,
                InitArgs {
                    base_dir: Some("/org".to_owned()),
                },
            ),
            Ok(())
        );
        assert_eq!(
            io.commands,
            vec![(
                "mix".to_owned(),
                vec![
                    "tightbeam.init".to_owned(),
                    "--base-dir".to_owned(),
                    "/org".to_owned(),
                ],
            )]
        );
        assert_eq!(io.logs, vec!["Initialized /org/identity"]);
    }

    #[test]
    fn non_tty_onboard_warning_names_manual_command() {
        assert_eq!(
            onboard_warning("codex", "/org"),
            "[assimilate] no terminal for codex onboarding — run on the satellite: CODEX_HOME=/org/auth/codex codex login"
        );
    }

    #[test]
    fn credential_status_defaults_only_empty_output_to_missing() {
        assert_eq!(credential_status("\n"), "missing");
        assert_eq!(credential_status("present\n"), "present");
        assert_eq!(credential_status("unexpected\n"), "unexpected");
    }

    #[test]
    fn empty_tilde_suffix_is_shell_quoted_like_typescript() {
        assert_eq!(remote_path("~/"), "~/''");
        assert_eq!(remote_path("~/.tightbeam"), "~/.tightbeam");
    }

    #[test]
    fn local_target_is_the_cargo_compile_target() {
        assert_eq!(local_target_triple(), env!("TIGHTBEAM_BUILD_TARGET"));
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
            vec![
                "ssh", "ssh", "ssh", "ssh", "ssh", "ssh", "ssh", "scp", "ssh"
            ]
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
            io.commands[7]
                .1
                .last()
                .unwrap()
                .ends_with(":/Users/remote/.tightbeam/bin/tightbeam")
        );
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
            9
        );
        assert!(
            io.logs
                .contains(&"[assimilate] REGISTER... skipped (--dry-run)".to_owned())
        );
        assert!(io.dispatched.is_empty());
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
    fn default_name_strips_user_prefix() {
        assert_eq!(default_assimilate_name("worker.local"), "worker.local");
        assert_eq!(
            default_assimilate_name("flynn@worker.local"),
            "worker.local"
        );
    }
}
