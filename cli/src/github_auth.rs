use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GithubState {
    Live,
    MissingCli,
    NeedsOnboarding,
    InsufficientScope,
    GitUnready,
    Unknown,
}

impl GithubState {
    fn as_str(&self) -> &'static str {
        match self {
            GithubState::Live => "live",
            GithubState::MissingCli => "missing_cli",
            GithubState::NeedsOnboarding => "needs_onboarding",
            GithubState::InsufficientScope => "insufficient_scope",
            GithubState::GitUnready => "git_unready",
            GithubState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GithubStatus {
    pub hostname: String,
    pub state: GithubState,
    pub account: Option<String>,
    pub git_protocol: Option<String>,
    pub git_remote: Option<String>,
    pub git_ready: Option<bool>,
    pub detail: String,
}

pub fn onboard(hostname: &str, remote: Option<&str>) -> Result<(), String> {
    let base_dir = crate::base_dir::resolve();
    let gh = RealGh::banking_into(&base_dir)?;
    onboard_with(hostname, remote, &base_dir, gh)
}

pub fn check_tool_call_stdin() -> Result<(), String> {
    let mut raw = String::new();
    std::io::stdin()
        .read_to_string(&mut raw)
        .map_err(|error| format!("could not read tool-call JSON from stdin: {error}"))?;
    let base_dir = crate::base_dir::resolve();
    check_tool_call_with(&raw, &RealGh::using_banked(&base_dir))
}

/// The Tightbeam-owned gh config dir. One shared dir, not per-hostname:
/// GH_CONFIG_DIR is single-valued while gh's hosts.yml natively holds every
/// hostname, so per-host dirs would make a project that spans github.com and a
/// GHE host impossible to configure.
pub fn gh_config_dir(base_dir: &Path) -> PathBuf {
    base_dir.join("auth").join("github").join("gh")
}

trait Gh {
    fn which_gh(&self) -> Option<PathBuf>;
    fn output(&self, args: &[&str]) -> Result<Output, String>;
    fn status(&self, args: &[&str]) -> Result<std::process::ExitStatus, String>;
    fn git_ls_remote(&self, remote: &str) -> Result<Output, String>;
}

/// Runs gh (and git, whose credential helper is gh) against the banked
/// Tightbeam config dir when one exists. The OS keyring is deliberately out of
/// the read path: agent processes descend from the gateway daemon, and a
/// daemon-descended context cannot read the login keychain
/// (errSecInteractionNotAllowed) — a keyring credential probes live from an
/// operator terminal while being unreadable everywhere project work runs.
struct RealGh {
    config_dir: Option<PathBuf>,
}

impl RealGh {
    /// Probe-side construction: the banked dir is pinned whether or not it
    /// exists yet. Falling back to the ambient environment would let a
    /// keyring or operator-shell credential answer "live" for environments
    /// that cannot read it — the exact inconsistency this capability exists
    /// to eliminate. An absent dir makes gh answer needs_onboarding, which
    /// is the honest state.
    fn using_banked(base_dir: &Path) -> Self {
        RealGh {
            config_dir: Some(gh_config_dir(base_dir)),
        }
    }

    /// Onboarding-side construction: the banked dir is the destination, so it
    /// is created (0700) before gh runs.
    fn banking_into(base_dir: &Path) -> Result<Self, String> {
        let dir = gh_config_dir(base_dir);
        fs::create_dir_all(&dir)
            .map_err(|error| format!("could not create {}: {error}", dir.display()))?;
        let mut restrict = dir.clone();
        loop {
            fs::set_permissions(&restrict, fs::Permissions::from_mode(0o700))
                .map_err(|error| format!("could not set 0700 on {}: {error}", restrict.display()))?;
            if restrict.ends_with("auth") || !restrict.pop() {
                break;
            }
        }
        Ok(RealGh {
            config_dir: Some(dir),
        })
    }

    fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        if let Some(dir) = &self.config_dir {
            command.env("GH_CONFIG_DIR", dir);
        }
        command
    }
}

/// Probes are bounded: the guard runs inside a PreToolUse hook, and an
/// unbounded `git ls-remote` against an unreachable host would hang the
/// agent's whole tool path. A timed-out probe maps to an error, which the
/// callers treat as `unknown` — per spec, never live. The login ceremony
/// (`status`) stays unbounded on purpose: a human is completing a browser
/// flow that legitimately takes minutes.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

impl Gh for RealGh {
    fn which_gh(&self) -> Option<PathBuf> {
        crate::preflight::on_path("gh", &std::env::var("PATH").unwrap_or_default())
    }

    fn output(&self, args: &[&str]) -> Result<Output, String> {
        let child = self
            .command("gh")
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| format!("failed to run gh {}: {error}", args.join(" ")))?;
        wait_bounded(child, &format!("gh {}", args.join(" ")))
    }

    fn status(&self, args: &[&str]) -> Result<std::process::ExitStatus, String> {
        self.command("gh")
            .args(args)
            .status()
            .map_err(|error| format!("failed to run gh {}: {error}", args.join(" ")))
    }

    fn git_ls_remote(&self, remote: &str) -> Result<Output, String> {
        let child = self
            .command("git")
            .args(["ls-remote", remote, "HEAD"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| format!("failed to run git ls-remote: {error}"))?;
        wait_bounded(child, "git ls-remote")
    }
}

// Probe output is small (auth status lines, one ls-remote ref), so waiting for
// exit before draining the pipes cannot deadlock on a full pipe buffer in
// practice; a pathological child that fills the buffer just gets killed at the
// deadline like any other hang.
fn wait_bounded(mut child: std::process::Child, what: &str) -> Result<Output, String> {
    let deadline = std::time::Instant::now() + PROBE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child
                    .wait_with_output()
                    .map_err(|error| format!("failed reading {what} output: {error}"));
            }
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "{what} timed out after {}s",
                    PROBE_TIMEOUT.as_secs()
                ));
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(error) => return Err(format!("failed waiting for {what}: {error}")),
        }
    }
}

fn onboard_with(
    hostname: &str,
    remote: Option<&str>,
    base_dir: &Path,
    gh: impl Gh,
) -> Result<(), String> {
    let hostname = normalize_hostname(hostname)?;
    let remote = remote.map(str::trim).filter(|value| !value.is_empty());
    let mut status = probe_with(&hostname, &gh);

    match status.state {
        GithubState::MissingCli => return Err(status.detail),
        GithubState::Live => {}
        _ => {
            eprintln!(
                "GitHub auth for {hostname} is not live ({state}); starting GitHub CLI login.",
                state = status.state.as_str()
            );
            // --insecure-storage is deliberate, not a fallback: the credential
            // must land in the banked GH_CONFIG_DIR as a 0600 file, because the
            // OS keyring is unreadable from the daemon-descended environments
            // that do project work. The storage mode is surfaced in the result
            // and in capability metadata rather than passing as implicit success.
            let login = gh.status(&[
                "auth",
                "login",
                "--hostname",
                &hostname,
                "--web",
                "--git-protocol",
                "https",
                "--insecure-storage",
            ])?;
            if !login.success() {
                return Err(format!(
                    "gh auth login for {hostname} exited with status {login}. Nothing was banked. \
                     Do not paste a PAT into an agent; rerun tightbeam onboard github --hostname {hostname}."
                ));
            }
            status = probe_with(&hostname, &gh);
        }
    }

    if status.state != GithubState::Live {
        return Err(format!(
            "GitHub auth for {hostname} is still not live after onboarding: {}. \
             Do not paste a PAT into an agent.",
            status.detail
        ));
    }

    if let Some(remote) = remote {
        status = probe_git_remote(&status, remote, &gh);
        if status.state != GithubState::Live {
            return Err(format!(
                "GitHub repository auth for {remote} is not live: {}. \
                 Run tightbeam onboard github --hostname {hostname} and repair git auth; \
                 do not paste a PAT into an agent.",
                status.detail
            ));
        }
    }

    write_metadata(base_dir, &status)?;
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "status": "onboarded",
            "capability": "github",
            "hostname": status.hostname,
            "account": status.account,
            "gitProtocol": status.git_protocol,
            "gitRemote": status.git_remote,
            "gitReady": status.git_ready,
            "storage": "file",
            "configDir": gh_config_dir(base_dir),
            "metadata": metadata_path(base_dir, &hostname),
        }))
        .expect("JSON value serializes")
    );
    Ok(())
}

fn normalize_hostname(hostname: &str) -> Result<String, String> {
    let hostname = hostname.trim();
    if hostname.is_empty() {
        return Err("--hostname must not be empty".to_owned());
    }
    if hostname.contains('/') || hostname.contains('@') || hostname.contains(':') {
        return Err(format!(
            "--hostname must be a GitHub hostname like github.com, got {hostname:?}"
        ));
    }
    let labels = hostname.split('.').collect::<Vec<_>>();
    if labels.iter().any(|label| label.is_empty())
        || labels
            .iter()
            .any(|label| label.starts_with('-') || label.ends_with('-'))
        || labels.iter().any(|label| {
            !label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        || matches!(hostname, "." | "..")
    {
        return Err(format!(
            "--hostname must be a DNS-style GitHub hostname like github.com, got {hostname:?}"
        ));
    }
    Ok(hostname.to_owned())
}

fn probe_with(hostname: &str, gh: &impl Gh) -> GithubStatus {
    if gh.which_gh().is_none() {
        let search_path = std::env::var("PATH").unwrap_or_default();
        return GithubStatus {
            hostname: hostname.to_owned(),
            state: GithubState::MissingCli,
            account: None,
            git_protocol: None,
            git_remote: None,
            git_ready: None,
            detail: format!(
                "gh is missing from PATH; install GitHub CLI on this host and run \
                 tightbeam onboard github --hostname {hostname}. PATH searched: {search_path}"
            ),
        };
    }

    let status = gh.output(&["auth", "status", "--active", "--hostname", hostname]);
    if let Ok(output) = status {
        if !output.status.success() {
            return GithubStatus {
                hostname: hostname.to_owned(),
                state: GithubState::NeedsOnboarding,
                account: None,
                git_protocol: None,
                git_remote: None,
                git_ready: None,
                detail: stderr_or_stdout(&output),
            };
        }
    } else if let Err(error) = status {
        return GithubStatus {
            hostname: hostname.to_owned(),
            state: GithubState::Unknown,
            account: None,
            git_protocol: None,
            git_remote: None,
            git_ready: None,
            detail: error,
        };
    }

    let account = gh.output(&["api", "--hostname", hostname, "user", "--jq", ".login"]);
    match account {
        Ok(output) if output.status.success() => {
            let account = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            GithubStatus {
                hostname: hostname.to_owned(),
                state: GithubState::Live,
                account: (!account.is_empty()).then_some(account),
                git_protocol: git_protocol(gh, hostname),
                git_remote: None,
                git_ready: None,
                detail: "gh api authenticated successfully".to_owned(),
            }
        }
        Ok(output) => {
            let detail = stderr_or_stdout(&output);
            GithubStatus {
                hostname: hostname.to_owned(),
                state: classify_api_failure(&detail),
                account: None,
                git_protocol: git_protocol(gh, hostname),
                git_remote: None,
                git_ready: None,
                detail,
            }
        }
        Err(error) => GithubStatus {
            hostname: hostname.to_owned(),
            state: GithubState::Unknown,
            account: None,
            git_protocol: git_protocol(gh, hostname),
            git_remote: None,
            git_ready: None,
            detail: error,
        },
    }
}

fn probe_git_remote(status: &GithubStatus, remote: &str, gh: &impl Gh) -> GithubStatus {
    let output = gh.git_ls_remote(remote);
    match output {
        // The success path scrubs too: git_remote lands in stdout JSON and
        // capability.json, and a working credentialed URL is exactly the one
        // whose secret must not be persisted.
        Ok(output) if output.status.success() => GithubStatus {
            git_remote: Some(scrub_detail(remote)),
            git_ready: Some(true),
            ..status.clone()
        },
        Ok(output) => GithubStatus {
            state: GithubState::GitUnready,
            git_remote: Some(scrub_detail(remote)),
            git_ready: Some(false),
            detail: scrub_detail(&stderr_or_stdout(&output)),
            ..status.clone()
        },
        Err(error) => GithubStatus {
            state: GithubState::Unknown,
            git_remote: Some(scrub_detail(remote)),
            git_ready: Some(false),
            detail: scrub_detail(&error),
            ..status.clone()
        },
    }
}

fn check_tool_call_with(raw: &str, gh: &impl Gh) -> Result<(), String> {
    let texts = tool_call_strings(raw);
    let mut remotes = texts
        .iter()
        .filter(|text| has_git_operation(text) || looks_like_gh_repo_call(text))
        .flat_map(|text| github_remotes(text))
        .collect::<Vec<_>>();
    remotes.sort();
    remotes.dedup();

    let gh_repo = texts.iter().any(|text| looks_like_gh_repo_call(text));
    if remotes.is_empty() && !gh_repo {
        return Ok(());
    }

    if remotes.is_empty() {
        return check_github_ready("github.com", None, gh);
    }

    for remote in remotes {
        let hostname = github_hostname_from_remote(&remote).unwrap_or_else(|| "github.com".into());
        check_github_ready(&hostname, Some(&remote), gh)?;
    }
    Ok(())
}

fn check_github_ready(hostname: &str, remote: Option<&str>, gh: &impl Gh) -> Result<(), String> {
    let status = probe_with(hostname, gh);
    if status.state != GithubState::Live {
        return Err(github_refusal(hostname, remote, &status));
    }

    if let Some(remote) = remote {
        let status = probe_git_remote(&status, remote, gh);
        if status.state != GithubState::Live {
            return Err(github_refusal(hostname, Some(remote), &status));
        }
    }
    Ok(())
}

fn github_refusal(hostname: &str, remote: Option<&str>, status: &GithubStatus) -> String {
    let mut repair = format!("tightbeam onboard github --hostname {hostname}");
    if let Some(remote) = remote {
        repair.push_str(" --remote ");
        repair.push_str(&scrub_detail(remote));
    }

    format!(
        "Tightbeam cannot use GitHub from this host for {hostname}: {state}: {detail}. \
         Run: {repair}. Do not paste a PAT into an agent.",
        state = status.state.as_str(),
        detail = scrub_detail(&status.detail)
    )
}

fn tool_call_strings(raw: &str) -> Vec<String> {
    let mut strings = Vec::new();
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) {
        collect_json_strings(&value, &mut strings);
    }
    strings.push(raw.to_owned());
    strings
}

fn collect_json_strings(value: &serde_json::Value, strings: &mut Vec<String>) {
    match value {
        serde_json::Value::String(value) => strings.push(value.clone()),
        serde_json::Value::Array(values) => {
            for value in values {
                collect_json_strings(value, strings);
            }
        }
        serde_json::Value::Object(map) => {
            for value in map.values() {
                collect_json_strings(value, strings);
            }
        }
        _ => {}
    }
}

// The guard judges operations, not mentions. A `tightbeam assign` whose brief
// says "read the gh issue thread at https://github.com/org/repo" performs no
// GitHub operation and must not be refused — that false positive blocked real
// org traffic on day one. Command-position matching under-matches by design
// (e.g. a gh call nested inside `sh -c "..."` slips through): for a hygiene
// gate the acceptable direction to be wrong in is letting gh fail at runtime
// with its own auth error, never blocking commands that merely talk about
// GitHub.
fn looks_like_gh_repo_call(text: &str) -> bool {
    has_operation(text, "gh ", &["repo", "pr", "issue", "api"])
}

fn has_git_operation(text: &str) -> bool {
    has_operation(
        text,
        "git ",
        &[
            "clone",
            "fetch",
            "pull",
            "push",
            "ls-remote",
            "remote",
            "submodule",
        ],
    )
}

fn has_operation(text: &str, program: &str, areas: &[&str]) -> bool {
    let down = text.to_ascii_lowercase();
    down.match_indices(program).any(|(idx, _)| {
        at_command_position(&down, idx)
            && areas.iter().any(|area| {
                let rest = down[idx + program.len()..].trim_start();
                rest.strip_prefix(area)
                    .is_some_and(|after| after.is_empty() || !after.starts_with(char::is_alphanumeric))
            })
    })
}

fn at_command_position(text: &str, idx: usize) -> bool {
    let head = text[..idx].trim_end_matches([' ', '\t']);
    match head.chars().last() {
        None => true,
        Some(ch) => matches!(ch, ';' | '&' | '|' | '(' | '{' | '\n' | '`'),
    }
}

fn github_remotes(text: &str) -> Vec<String> {
    let mut remotes = Vec::new();
    for prefix in [
        "https://github.com/",
        "http://github.com/",
        "ssh://git@github.com/",
        "git@github.com:",
    ] {
        remotes.extend(prefixed_values(text, prefix));
    }
    remotes
        .into_iter()
        .map(|value| {
            value
                .trim_matches(|ch: char| matches!(ch, '.' | ',' | ')' | ']' | '}'))
                .to_owned()
        })
        .filter(|value| value.contains('/'))
        .collect()
}

fn prefixed_values(text: &str, prefix: &str) -> Vec<String> {
    let mut values = Vec::new();
    let mut search_from = 0;
    while let Some(offset) = text[search_from..].find(prefix) {
        let start = search_from + offset;
        let tail = &text[start..];
        let end = tail
            .char_indices()
            .find_map(|(index, ch)| remote_boundary(ch).then_some(index))
            .unwrap_or(tail.len());
        values.push(tail[..end].to_owned());
        search_from = start + end.max(prefix.len());
        if search_from >= text.len() {
            break;
        }
    }
    values
}

fn remote_boundary(ch: char) -> bool {
    ch.is_whitespace()
        || matches!(
            ch,
            '"' | '\'' | '\\' | '`' | '<' | '>' | '(' | ')' | '[' | ']' | '{' | '}' | ';'
        )
}

fn github_hostname_from_remote(remote: &str) -> Option<String> {
    if remote.starts_with("git@github.com:") {
        return Some("github.com".to_owned());
    }
    let after_scheme = remote.split_once("://").map(|(_, rest)| rest)?;
    let host_and_path = after_scheme
        .split_once('@')
        .map(|(_, rest)| rest)
        .unwrap_or(after_scheme);
    let host = host_and_path.split('/').next()?.split(':').next()?;
    (host == "github.com" || host.ends_with(".github.com")).then(|| host.to_owned())
}

fn classify_api_failure(detail: &str) -> GithubState {
    let down = detail.to_ascii_lowercase();
    if down.contains("scope") || down.contains("forbidden") || down.contains("403") {
        GithubState::InsufficientScope
    } else if down.contains("not logged") || down.contains("authentication") || down.contains("401")
    {
        GithubState::NeedsOnboarding
    } else {
        GithubState::Unknown
    }
}

fn git_protocol(gh: &impl Gh, hostname: &str) -> Option<String> {
    let _ = hostname;
    let output = gh.output(&["config", "get", "git_protocol"]).ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn stderr_or_stdout(output: &Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if !stderr.is_empty() {
        stderr
    } else {
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    }
}

fn scrub_detail(detail: &str) -> String {
    let mut redacted = String::new();
    for word in detail.split_whitespace() {
        let cleaned = if word.contains("github_pat_") && !word.contains("://") {
            "[redacted]".to_owned()
        } else if let Some((scheme, rest)) = word.split_once("://") {
            if let Some((userinfo, host_path)) = rest.split_once('@') {
                // user:password AND token-as-username forms — gh accepts
                // https://ghp_xxx@host clones, so a bare token can be the
                // entire userinfo with no colon in sight.
                let userinfo_is_secret = userinfo.contains(':')
                    || userinfo.contains("github_pat_")
                    || ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]
                        .iter()
                        .any(|prefix| userinfo.contains(prefix));
                if userinfo_is_secret {
                    format!("{scheme}://[redacted]@{host_path}")
                } else {
                    word.to_owned()
                }
            } else {
                word.to_owned()
            }
        } else if word.starts_with("ghp_")
            || word.starts_with("gho_")
            || word.starts_with("ghu_")
            || word.starts_with("ghs_")
            || word.starts_with("ghr_")
        {
            "[redacted]".to_owned()
        } else {
            word.to_owned()
        };
        if !redacted.is_empty() {
            redacted.push(' ');
        }
        redacted.push_str(&cleaned);
    }
    redacted
}

fn metadata_path(base_dir: &Path, hostname: &str) -> PathBuf {
    base_dir
        .join("auth")
        .join("github")
        .join(hostname)
        .join(".tightbeam")
        .join("capability.json")
}

fn write_metadata(base_dir: &Path, status: &GithubStatus) -> Result<(), String> {
    let path = metadata_path(base_dir, &status.hostname);
    let parent = path
        .parent()
        .ok_or_else(|| format!("metadata path has no parent: {}", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))?;

    let checked_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let body = serde_json::json!({
        "hostname": status.hostname,
        "account": status.account,
        "git_protocol": status.git_protocol,
        "git_remote": status.git_remote,
        "git_ready": status.git_ready,
        "checked_at_unix": checked_at,
        "status": status.state.as_str(),
        "source": "gh",
        "storage": "file",
    });
    fs::write(
        &path,
        serde_json::to_vec_pretty(&body).expect("JSON value serializes"),
    )
    .map_err(|error| format!("could not write {}: {error}", path.display()))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("could not set 0600 on {}: {error}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::os::unix::process::ExitStatusExt;
    use std::sync::Mutex;

    struct FakeGh {
        present: bool,
        outputs: Mutex<VecDeque<(&'static [&'static str], Output)>>,
        statuses: Mutex<VecDeque<(&'static [&'static str], std::process::ExitStatus)>>,
        git_outputs: Mutex<VecDeque<(&'static str, Output)>>,
    }

    impl FakeGh {
        fn new(present: bool) -> Self {
            Self {
                present,
                outputs: Mutex::new(VecDeque::new()),
                statuses: Mutex::new(VecDeque::new()),
                git_outputs: Mutex::new(VecDeque::new()),
            }
        }

        fn output(self, args: &'static [&'static str], output: Output) -> Self {
            self.outputs.lock().unwrap().push_back((args, output));
            self
        }

        fn status(self, args: &'static [&'static str], status: std::process::ExitStatus) -> Self {
            self.statuses.lock().unwrap().push_back((args, status));
            self
        }

        fn git_output(self, remote: &'static str, output: Output) -> Self {
            self.git_outputs.lock().unwrap().push_back((remote, output));
            self
        }
    }

    impl Gh for FakeGh {
        fn which_gh(&self) -> Option<PathBuf> {
            self.present.then(|| PathBuf::from("/usr/bin/gh"))
        }

        fn output(&self, args: &[&str]) -> Result<Output, String> {
            let (expected, output) = self
                .outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected gh output call");
            assert_eq!(args, expected);
            Ok(output)
        }

        fn status(&self, args: &[&str]) -> Result<std::process::ExitStatus, String> {
            let (expected, status) = self
                .statuses
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected gh status call");
            assert_eq!(args, expected);
            Ok(status)
        }

        fn git_ls_remote(&self, remote: &str) -> Result<Output, String> {
            let (expected, output) = self
                .git_outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected git ls-remote call");
            assert_eq!(remote, expected);
            Ok(output)
        }
    }

    fn out(code: i32, stdout: &str, stderr: &str) -> Output {
        Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.as_bytes().to_vec(),
            stderr: stderr.as_bytes().to_vec(),
        }
    }

    #[test]
    fn missing_gh_is_a_named_state_with_no_login_attempt() {
        let status = probe_with("github.com", &FakeGh::new(false));
        assert_eq!(status.state, GithubState::MissingCli);
        assert!(status.detail.contains("gh is missing from PATH"));
        assert!(
            status
                .detail
                .contains("tightbeam onboard github --hostname github.com")
        );
    }

    #[test]
    fn live_probe_records_account_and_protocol() {
        let gh = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(0, "", ""),
            )
            .output(
                &["api", "--hostname", "github.com", "user", "--jq", ".login"],
                out(0, "octo\n", ""),
            )
            .output(&["config", "get", "git_protocol"], out(0, "https\n", ""));
        let status = probe_with("github.com", &gh);
        assert_eq!(status.state, GithubState::Live);
        assert_eq!(status.account.as_deref(), Some("octo"));
        assert_eq!(status.git_protocol.as_deref(), Some("https"));
    }

    #[test]
    fn onboarding_never_uses_with_token_and_writes_no_secret_metadata() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam-github-auth-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let gh = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(1, "", "not logged in"),
            )
            .status(
                &[
                    "auth",
                    "login",
                    "--hostname",
                    "github.com",
                    "--web",
                    "--git-protocol",
                    "https",
                    "--insecure-storage",
                ],
                std::process::ExitStatus::from_raw(0),
            )
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(0, "", ""),
            )
            .output(
                &["api", "--hostname", "github.com", "user", "--jq", ".login"],
                out(0, "octo\n", ""),
            )
            .output(&["config", "get", "git_protocol"], out(0, "https\n", ""));
        onboard_with("github.com", None, &root, gh).unwrap();

        let metadata = fs::read_to_string(metadata_path(&root, "github.com")).unwrap();
        assert!(metadata.contains("\"status\": \"live\""));
        assert!(metadata.contains("\"account\": \"octo\""));
        assert!(metadata.contains("\"storage\": \"file\""));
        assert!(!metadata.contains("token"));
        assert!(!metadata.contains("PAT"));
        assert_eq!(
            fs::metadata(metadata_path(&root, "github.com"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn remote_git_failure_is_git_unready_not_live() {
        let gh = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(0, "", ""),
            )
            .output(
                &["api", "--hostname", "github.com", "user", "--jq", ".login"],
                out(0, "octo\n", ""),
            )
            .output(&["config", "get", "git_protocol"], out(0, "https\n", ""))
            .git_output(
                "https://user:github_pat_secret@github.com/org/repo.git",
                out(
                    128,
                    "",
                    "remote: Repository not found for github_pat_secret\n",
                ),
            );
        let status = probe_with("github.com", &gh);
        let status = probe_git_remote(
            &status,
            "https://user:github_pat_secret@github.com/org/repo.git",
            &gh,
        );
        assert_eq!(status.state, GithubState::GitUnready);
        assert_eq!(status.git_ready, Some(false));
        assert!(!status.detail.contains("github_pat_secret"));
        assert!(!status.git_remote.unwrap().contains("github_pat_secret"));
    }

    #[test]
    fn invalid_hostname_refuses_before_running_gh() {
        assert!(normalize_hostname("").is_err());
        assert!(normalize_hostname("https://github.com").is_err());
        assert!(normalize_hostname("git@github.com").is_err());
        assert!(normalize_hostname(".").is_err());
        assert!(normalize_hostname("..").is_err());
        assert!(normalize_hostname("github..com").is_err());
        assert!(normalize_hostname("-github.com").is_err());
        assert!(normalize_hostname("github-.com").is_err());
        assert!(normalize_hostname("github_com").is_err());
    }

    #[test]
    fn scrub_detail_redacts_tokens_and_credentialed_urls() {
        let detail =
            "https://user:github_pat_secret@github.com/org/repo.git failed ghp_secret gho_secret";
        let scrubbed = scrub_detail(detail);
        assert!(!scrubbed.contains("github_pat_secret"));
        assert!(!scrubbed.contains("ghp_secret"));
        assert!(!scrubbed.contains("gho_secret"));
        assert!(scrubbed.contains("https://[redacted]@github.com/org/repo.git"));
    }

    #[test]
    fn tool_call_guard_ignores_non_github_commands() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {"command": "git status && ls"}
        })
        .to_string();

        check_tool_call_with(&raw, &FakeGh::new(false)).unwrap();
    }

    #[test]
    fn tool_call_guard_proves_github_remote_before_git_runs() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "git clone https://github.com/org/repo.git"
            }
        })
        .to_string();
        let gh = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(0, "", ""),
            )
            .output(
                &["api", "--hostname", "github.com", "user", "--jq", ".login"],
                out(0, "octo\n", ""),
            )
            .output(&["config", "get", "git_protocol"], out(0, "https\n", ""))
            .git_output("https://github.com/org/repo.git", out(0, "abc\tHEAD\n", ""));

        check_tool_call_with(&raw, &gh).unwrap();
    }

    #[test]
    fn tool_call_guard_refuses_github_without_cli_before_pat_prompt() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "git clone https://github.com/org/repo.git"
            }
        })
        .to_string();

        let error = check_tool_call_with(&raw, &FakeGh::new(false)).unwrap_err();
        assert!(error.contains("Tightbeam cannot use GitHub"));
        assert!(error.contains("tightbeam onboard github --hostname github.com"));
        assert!(error.contains("--remote https://github.com/org/repo.git"));
        assert!(error.contains("Do not paste a PAT into an agent"));
    }

    #[test]
    fn tool_call_guard_ignores_github_mentions_that_are_not_operations() {
        // A refusal here would block org traffic whose *prose* names GitHub —
        // the exact false positive that hit `tightbeam assign --brief` on the
        // first live project. FakeGh::new(false) has no gh at all, so any probe
        // attempt would refuse: Ok proves no probe ran.
        for command in [
            "tightbeam assign --subject work --brief 'read the gh issue thread \
             at https://github.com/org/repo and summarize'",
            "echo see https://github.com/org/repo.git for details",
            "tightbeam wake --role coder --prompt 'fork https://github.com/org/repo, \
             then gh pr create'",
        ] {
            let raw = serde_json::json!({
                "tool_name": "Bash",
                "tool_input": {"command": command}
            })
            .to_string();
            assert_eq!(
                check_tool_call_with(&raw, &FakeGh::new(false)),
                Ok(()),
                "mention-only command must not be probed: {command}"
            );
        }
    }

    #[test]
    fn tool_call_guard_still_refuses_operations_after_shell_connectors() {
        for command in [
            "cd /work && git clone https://github.com/org/repo.git",
            "true; gh issue list --repo org/repo",
            "git fetch https://github.com/org/repo.git | cat",
        ] {
            let raw = serde_json::json!({
                "tool_name": "Bash",
                "tool_input": {"command": command}
            })
            .to_string();
            let error = check_tool_call_with(&raw, &FakeGh::new(false)).unwrap_err();
            assert!(
                error.contains("Tightbeam cannot use GitHub"),
                "operation must still be gated: {command}"
            );
        }
    }

    #[test]
    fn banked_config_dir_is_shared_across_hostnames() {
        let base = Path::new("/base");
        assert_eq!(
            gh_config_dir(base),
            Path::new("/base/auth/github/gh"),
            "one dir for all hostnames: GH_CONFIG_DIR is single-valued while hosts.yml is not"
        );
    }

    #[test]
    fn banking_into_creates_restricted_config_dir() {
        let root = std::env::temp_dir().join(format!(
            "tb-gh-bank-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let gh = RealGh::banking_into(&root).unwrap();
        let dir = gh_config_dir(&root);
        assert_eq!(gh.config_dir.as_deref(), Some(dir.as_path()));
        for restricted in [&dir, &root.join("auth/github"), &root.join("auth")] {
            assert_eq!(
                fs::metadata(restricted).unwrap().permissions().mode() & 0o777,
                0o700,
                "{} must not be group/world readable",
                restricted.display()
            );
        }
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn using_banked_pins_the_config_dir_even_when_absent() {
        let root = std::env::temp_dir().join(format!(
            "tb-gh-missing-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        // No ambient fallback: an absent banked dir must probe as
        // needs_onboarding, never as whatever the operator shell can reach.
        assert_eq!(
            RealGh::using_banked(&root).config_dir.as_deref(),
            Some(gh_config_dir(&root).as_path())
        );
    }
}
