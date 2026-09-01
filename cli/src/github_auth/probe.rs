use std::process::Output;

use super::bank::Gh;
use super::redact::Scrubbed;
use super::{GithubState, GithubStatus};

pub(super) fn normalize_hostname(hostname: &str) -> Result<String, String> {
    let hostname = hostname.trim();
    if hostname.is_empty() {
        return Err("--hostname must not be empty".to_owned());
    }
    if hostname.contains('/') || hostname.contains('@') || hostname.contains("://") {
        return Err(format!(
            "--hostname must be a GitHub hostname like github.com, got {hostname:?}"
        ));
    }
    let hostname = hostname.trim_end_matches('.').to_ascii_lowercase();
    let (host, port) = hostname
        .rsplit_once(':')
        .map_or((hostname.as_str(), None), |(host, port)| (host, Some(port)));
    if port.is_some_and(|port| port.parse::<u16>().is_err()) {
        return Err(format!("--hostname has a malformed port: {hostname:?}"));
    }
    let labels = host.split('.').collect::<Vec<_>>();
    if labels.iter().any(|label| label.is_empty())
        || labels
            .iter()
            .any(|label| label.starts_with('-') || label.ends_with('-'))
        || labels.iter().any(|label| {
            !label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        || matches!(host, "." | "..")
    {
        return Err(format!(
            "--hostname must be a DNS-style GitHub hostname like github.com, got {hostname:?}"
        ));
    }
    Ok(hostname)
}

pub(super) fn probe_with(hostname: &str, gh: &impl Gh) -> GithubStatus {
    if gh.which_gh().is_none() {
        let search_path = std::env::var("PATH").unwrap_or_default();
        return GithubStatus {
            hostname: hostname.to_owned(),
            state: GithubState::MissingCli,
            failed_phase: "gh discovery",
            account: None,
            git_protocol: None,
            git_remote: None,
            git_ready: None,
            detail: Scrubbed::new(format!(
                "gh is missing from PATH; install GitHub CLI on this host and run \
                 tightbeam onboard github --hostname {hostname}. PATH searched: {search_path}"
            )),
        };
    }

    let auth_active = match gh.output(&["auth", "status", "--active", "--hostname", hostname]) {
        Ok(output) => output.status.success(),
        Err(error) => {
            return GithubStatus {
                hostname: hostname.to_owned(),
                state: GithubState::Unknown,
                failed_phase: "gh auth status",
                account: None,
                git_protocol: None,
                git_remote: None,
                git_ready: None,
                detail: Scrubbed::new(error),
            };
        }
    };

    let account = gh.output(&[
        "api",
        "--hostname",
        hostname,
        "-i",
        "user",
        "--jq",
        ".login",
    ]);
    match account {
        Ok(output) if output.status.success() && auth_active => {
            let account = String::from_utf8_lossy(&output.stdout)
                .lines()
                .rev()
                .map(str::trim)
                .find(|line| !line.is_empty() && !line.starts_with("HTTP/") && !line.contains(':'))
                .unwrap_or_default()
                .to_owned();
            GithubStatus {
                hostname: hostname.to_owned(),
                state: GithubState::Live,
                failed_phase: "gh api",
                account: (!account.is_empty()).then_some(account),
                git_protocol: git_protocol(gh, hostname),
                git_remote: None,
                git_ready: None,
                detail: Scrubbed::new("gh api authenticated successfully"),
            }
        }
        Ok(output) if output.status.success() => GithubStatus {
            hostname: hostname.to_owned(),
            state: GithubState::Unknown,
            failed_phase: "provider disagreement",
            account: None,
            git_protocol: git_protocol(gh, hostname),
            git_remote: None,
            git_ready: None,
            detail: Scrubbed::new("gh api returned 200 but gh auth status was not active"),
        },
        Ok(output) => {
            let detail = stderr_or_stdout(&output);
            GithubStatus {
                hostname: hostname.to_owned(),
                state: classify_api_failure(&detail),
                failed_phase: "gh api",
                account: None,
                git_protocol: git_protocol(gh, hostname),
                git_remote: None,
                git_ready: None,
                detail: Scrubbed::new(detail),
            }
        }
        Err(error) => GithubStatus {
            hostname: hostname.to_owned(),
            state: GithubState::Unknown,
            failed_phase: "gh api",
            account: None,
            git_protocol: git_protocol(gh, hostname),
            git_remote: None,
            git_ready: None,
            detail: Scrubbed::new(error),
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
            failed_phase: "git ls-remote",
            git_remote: Some(Scrubbed::new(remote)),
            git_ready: Some(true),
            ..status.clone()
        },
        Ok(output) => GithubStatus {
            state: GithubState::GitUnready,
            failed_phase: "git ls-remote",
            git_remote: Some(Scrubbed::new(remote)),
            git_ready: Some(false),
            detail: Scrubbed::new(stderr_or_stdout(&output)),
            ..status.clone()
        },
        Err(error) => GithubStatus {
            state: GithubState::Unknown,
            failed_phase: "git ls-remote",
            git_remote: Some(Scrubbed::new(remote)),
            git_ready: Some(false),
            detail: Scrubbed::new(error),
            ..status.clone()
        },
    }
}

#[cfg(test)]
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

#[cfg(test)]
fn github_refusal(hostname: &str, remote: Option<&str>, status: &GithubStatus) -> String {
    let host = projected_host_label();
    github_refusal_for(&host, hostname, remote, status)
}

#[cfg(test)]
fn github_refusal_for(
    host: &str,
    hostname: &str,
    remote: Option<&str>,
    status: &GithubStatus,
) -> String {
    let mut repair = format!("tightbeam onboard github --hostname {hostname}");
    if let Some(remote) = remote {
        repair.push_str(" --remote ");
        repair.push_str(Scrubbed::new(remote).as_str());
    }

    format!(
        "Tightbeam cannot use GitHub from {host} for {hostname}: failed phase {phase}; \
         {state}: {detail}. \
         Run: {repair}. Do not paste a PAT into an agent.",
        phase = status.failed_phase,
        state = status.state.as_str(),
        detail = status.detail
    )
}

#[cfg(test)]
fn projected_host_label() -> String {
    ["TIGHTBEAM_MACHINE", "TIGHTBEAM_LOCAL_HOST_NAME"]
        .iter()
        .find_map(|name| {
            std::env::var(name)
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        })
        .map(|host| format!("host {host}"))
        .unwrap_or_else(|| "this host".to_owned())
}

fn classify_api_failure(detail: &str) -> GithubState {
    let down = detail.to_ascii_lowercase();
    if http_status(&down) == Some(401) {
        GithubState::Expired
    } else if http_status(&down) == Some(403) {
        GithubState::InsufficientScope
    } else {
        GithubState::Unknown
    }
}

fn http_status(detail: &str) -> Option<u16> {
    detail.lines().find_map(|line| {
        let line = line.trim();
        if line.starts_with("http/") {
            line.split_whitespace().nth(1)?.parse().ok()
        } else {
            None
        }
    })
}

fn git_protocol(gh: &impl Gh, hostname: &str) -> Option<String> {
    let output = gh
        .output(&["config", "get", "git_protocol", "--host", hostname])
        .ok()?;
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

#[cfg(test)]
mod tests {
    use super::super::test_support::{FakeGh, out};
    use super::*;

    #[test]
    fn classify_api_failure_matches_the_elixir_classifier_contract() {
        // The sentinel phrases that previously classified differently per side
        // (Tightbeam.GithubAuth has the mirror of this test).
        assert_eq!(
            classify_api_failure("invalid oauth token"),
            GithubState::Unknown
        );
        assert_eq!(
            classify_api_failure("You are not logged into any accounts"),
            GithubState::Unknown
        );
        assert_eq!(
            classify_api_failure("HTTP/2 401 unauthorized"),
            GithubState::Expired
        );
        assert_eq!(
            classify_api_failure("missing required scope"),
            GithubState::Unknown
        );
        assert_eq!(
            classify_api_failure("HTTP/2 403 Forbidden"),
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
                &[
                    "api",
                    "--hostname",
                    "github.com",
                    "-i",
                    "user",
                    "--jq",
                    ".login",
                ],
                out(0, "octo\n", ""),
            )
            .output(
                &["config", "get", "git_protocol", "--host", "github.com"],
                out(0, "https\n", ""),
            );
        let status = probe_with("github.com", &gh);
        assert_eq!(status.state, GithubState::Live);
        assert_eq!(status.account.as_deref(), Some("octo"));
        assert_eq!(status.git_protocol.as_deref(), Some("https"));
    }

    #[test]
    fn api_status_is_authoritative_after_inactive_auth_status() {
        let disagreement = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(1, "", "not active"),
            )
            .output(
                &[
                    "api",
                    "--hostname",
                    "github.com",
                    "-i",
                    "user",
                    "--jq",
                    ".login",
                ],
                out(0, "octo\n", "HTTP/2 200"),
            )
            .output(
                &["config", "get", "git_protocol", "--host", "github.com"],
                out(0, "https\n", ""),
            );
        assert_eq!(
            probe_with("github.com", &disagreement).state,
            GithubState::Unknown
        );

        let expired = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(1, "", "not active"),
            )
            .output(
                &[
                    "api",
                    "--hostname",
                    "github.com",
                    "-i",
                    "user",
                    "--jq",
                    ".login",
                ],
                out(1, "", "HTTP/2 401 unauthorized"),
            )
            .output(
                &["config", "get", "git_protocol", "--host", "github.com"],
                out(0, "https\n", ""),
            );
        assert_eq!(
            probe_with("github.com", &expired).state,
            GithubState::Expired
        );
    }

    #[test]
    fn remote_git_failure_is_git_unready_not_live() {
        let gh = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(0, "", ""),
            )
            .output(
                &[
                    "api",
                    "--hostname",
                    "github.com",
                    "-i",
                    "user",
                    "--jq",
                    ".login",
                ],
                out(0, "octo\n", ""),
            )
            .output(
                &["config", "get", "git_protocol", "--host", "github.com"],
                out(0, "https\n", ""),
            )
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
