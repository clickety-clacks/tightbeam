use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{SystemTime, UNIX_EPOCH};

use super::bank::Gh;
use super::redact::scrub_detail;
use super::{GithubState, GithubStatus, gh_config_dir};

pub(super) fn onboard_with(
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

pub(super) fn normalize_hostname(hostname: &str) -> Result<String, String> {
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

pub(super) fn probe_with(hostname: &str, gh: &impl Gh) -> GithubStatus {
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

pub(super) fn probe_git_remote(status: &GithubStatus, remote: &str, gh: &impl Gh) -> GithubStatus {
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

pub(super) fn check_github_ready(
    hostname: &str,
    remote: Option<&str>,
    gh: &impl Gh,
) -> Result<(), String> {
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

// Keyword sets are part of the cross-language contract: the Elixir brain
// (Tightbeam.GithubAuth.classify_api_failure/1) must classify identically —
// "invalid oauth token" and "not logged into any accounts" both mean
// needs_onboarding on both sides. "auth" deliberately catches oauth,
// authentication, and unauthorized.
fn classify_api_failure(detail: &str) -> GithubState {
    let down = detail.to_ascii_lowercase();
    if down.contains("scope") || down.contains("forbidden") || down.contains("403") {
        GithubState::InsufficientScope
    } else if down.contains("auth") || down.contains("not logged") || down.contains("401") {
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
    use super::super::test_support::{FakeGh, out};
    use super::*;
    use std::os::unix::process::ExitStatusExt;

    #[test]
    fn classify_api_failure_matches_the_elixir_classifier_contract() {
        // The sentinel phrases that previously classified differently per side
        // (Tightbeam.GithubAuth has the mirror of this test).
        assert_eq!(
            classify_api_failure("invalid oauth token"),
            GithubState::NeedsOnboarding
        );
        assert_eq!(
            classify_api_failure("You are not logged into any accounts"),
            GithubState::NeedsOnboarding
        );
        assert_eq!(
            classify_api_failure("HTTP 401 unauthorized"),
            GithubState::NeedsOnboarding
        );
        assert_eq!(
            classify_api_failure("missing required scope"),
            GithubState::InsufficientScope
        );
        assert_eq!(
            classify_api_failure("HTTP 403 Forbidden"),
            GithubState::InsufficientScope
        );
        assert_eq!(
            classify_api_failure("connection reset by peer"),
            GithubState::Unknown
        );
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
}
