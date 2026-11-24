//! Host-local native reads. These can refresh credentials, so they must be
//! called only inside the account writer lease through process settlement.

use std::io::{self, BufRead, BufReader};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::child_process::{RunError, Supervised, nonblocking, supervise};

use super::{
    ProbeResult, claude_usage_at, codex_expiry, codex_subscription, codex_usage, credential, error,
    normalize_codex_app_server, now_ms, required_string, usage_agent,
};

const DEADLINE: Duration = Duration::from_secs(15);
const MAX_LINE: usize = 512 * 1024;

// The eventual caller is the single owning-host command built by the idle
// writer lease. There is no runtime entrypoint until that lease is verified.
pub(super) fn collect(provider: &str, binary: &Path, home: &Path) -> ProbeResult {
    match provider {
        "openai" => collect_codex(binary, home),
        "anthropic" => collect_claude(binary, home, super::CLAUDE_USAGE, super::CLAUDE_PROFILE),
        _ => Err(error("UPSTREAM_CONTRACT_CHANGED")),
    }
}

fn collect_codex(binary: &Path, home: &Path) -> ProbeResult {
    let path = home.join("auth.json");
    let original = credential(&path)?;
    let expiry = codex_expiry(&original["tokens"]["access_token"]);
    let refresh = expiry.is_none_or(|expiry| expiry <= now_ms());
    let (account, limits) = codex(binary, home, refresh).map_err(native_failure)?;
    let updated = credential(&path)?;
    let observed = now_ms();

    // A successful but unrepresentable response can use the HTTP mapping.
    // Do not immediately repeat a failed native quota request against the
    // provider, since it may have rejected or throttled the request.
    match normalize_codex_app_server(&limits, &account, observed) {
        Ok(mut sample) => {
            let identity = updated["tokens"]["id_token"].as_str();
            sample["subscription"] = codex_subscription(identity, observed);
            Ok(sample)
        }
        Err(_) => codex_usage(&updated, &usage_agent()),
    }
}

fn collect_claude(binary: &Path, home: &Path, usage_url: &str, profile_url: &str) -> ProbeResult {
    let path = home.join(".credentials.json");
    let original = credential(&path)?;
    let oauth = &original["claudeAiOauth"];
    required_string(&oauth["accessToken"])?;
    let needs_refresh = oauth["expiresAt"]
        .as_i64()
        .is_none_or(|expiry| expiry <= now_ms());
    let updated = if needs_refresh {
        claude(binary, home).map_err(native_failure)?;
        let updated = credential(&path)?;
        if updated["claudeAiOauth"]["expiresAt"]
            .as_i64()
            .is_none_or(|expiry| expiry <= now_ms())
        {
            return Err(error("REFRESH_REJECTED"));
        }
        updated
    } else {
        original
    };

    claude_usage_at(&updated, &usage_agent(), usage_url, profile_url)
}

fn native_failure(reason: RunError) -> Value {
    // Upstream protocol errors and child output never leave this process.
    match reason {
        RunError::Failed(message) if message.contains("onboarding lease expired") => {
            error("UPSTREAM_TIMEOUT")
        }
        _ => error("UPSTREAM_UNAVAILABLE"),
    }
}

pub(super) fn codex(binary: &Path, home: &Path, refresh: bool) -> Result<(Value, Value), RunError> {
    let mut command = native_command(binary, home);
    command
        .arg("-c")
        .arg("cli_auth_credentials_store=\"file\"")
        .arg("app-server")
        .env("CODEX_HOME", home)
        .env_remove("OPENAI_API_KEY")
        .env_remove("CODEX_API_KEY")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());

    let (output, status) = supervise(
        command,
        "Codex account usage probe",
        Instant::now() + DEADLINE,
        |child| {
            let pipes = child.child();
            let stdin = pipes.stdin.take().ok_or_else(failed)?;
            let stdout = pipes.stdout.take().ok_or_else(failed)?;
            let input = stdin.as_raw_fd();
            nonblocking(input)?;
            nonblocking(stdout.as_raw_fd())?;
            let mut output = BufReader::new(stdout);

            send(
                child,
                input,
                &json!({
                    "id": 1,
                    "method": "initialize",
                    "params": {"clientInfo": {"name": "tightbeam-capacity", "version": "1"}}
                }),
            )?;
            response(child, &mut output, 1)?;
            send(
                child,
                input,
                &json!({"method": "initialized", "params": {}}),
            )?;
            send(
                child,
                input,
                &json!({"id": 2, "method": "account/read", "params": {"refreshToken": refresh}}),
            )?;
            let account = response(child, &mut output, 2)?;
            send(
                child,
                input,
                &json!({
                    "id": 3, "method": "account/rateLimits/read",
                    "params": {"excludeResetCreditDetails": true}
                }),
            )?;
            let limits = response(child, &mut output, 3)?;

            // Stdin EOF lets app-server cleanly exit. Keep the lease if it needs
            // time to settle or eventually requires the supervisor to terminate it.
            drop(stdin);
            while !child.exited()? {
                check_deadline(child)?;
                child.wait(None);
            }
            Ok((account, limits))
        },
    )?;

    if status.success() {
        Ok(output)
    } else {
        Err(failed())
    }
}

pub(super) fn claude(binary: &Path, home: &Path) -> Result<(), RunError> {
    let mut command = native_command(binary, home);
    command
        .args(["auth", "status"])
        .env("CLAUDE_CONFIG_DIR", home)
        .env("DISABLE_AUTOUPDATER", "1")
        .env("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
        .env_remove("CLAUDE_CODE_OAUTH_TOKEN")
        .env_remove("ANTHROPIC_API_KEY")
        .env_remove("ANTHROPIC_AUTH_TOKEN")
        .stdin(Stdio::null())
        .stdout(Stdio::null());

    let (_, status) = supervise(
        command,
        "Claude credential status",
        Instant::now() + DEADLINE,
        |child| {
            while !child.exited()? {
                check_deadline(child)?;
                child.wait(None);
            }
            Ok(())
        },
    )?;

    if status.success() {
        Ok(())
    } else {
        Err(failed())
    }
}

fn native_command(binary: &Path, home: &Path) -> Command {
    let mut command = Command::new(binary);
    command
        .current_dir(home)
        .stderr(Stdio::null())
        .process_group(0);
    command
}

fn failed() -> RunError {
    RunError::Failed("vendor capacity command failed".into())
}

fn check_deadline(child: &Supervised) -> Result<(), RunError> {
    if let Some(error) = child.interrupted().or_else(|| child.expired()) {
        Err(error)
    } else {
        Ok(())
    }
}

fn send(child: &Supervised, input: i32, message: &Value) -> Result<(), RunError> {
    let mut bytes = serde_json::to_vec(message).map_err(|_| failed())?;
    bytes.push(b'\n');
    child.write_all(input, &bytes)
}

fn response(
    child: &Supervised,
    output: &mut BufReader<std::process::ChildStdout>,
    id: u64,
) -> Result<Value, RunError> {
    let mut line = Vec::new();

    loop {
        check_deadline(child)?;
        match output.fill_buf() {
            Ok([]) => return Err(failed()),
            Ok(bytes) => {
                let end = bytes.iter().position(|byte| *byte == b'\n');
                let consumed = end.map_or(bytes.len(), |end| end + 1);
                line.extend_from_slice(&bytes[..consumed]);
                output.consume(consumed);
                if line.len() > MAX_LINE {
                    return Err(failed());
                }
                if end.is_some() {
                    let mut reply: Value = serde_json::from_slice(&line).map_err(|_| failed())?;
                    if reply["id"] == id && reply.get("method").is_none() {
                        return reply.get_mut("result").map(Value::take).ok_or_else(failed);
                    }
                    line.clear();
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                child.wait(Some(libc::pollfd {
                    fd: output.get_ref().as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                }));
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return Err(failed()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn mock_native_children_finish_before_return_and_never_emit_their_output() {
        let dir = std::env::temp_dir().join(format!(
            "tightbeam-capacity-child-{}-{}",
            std::process::id(),
            super::super::now_ms()
        ));
        std::fs::create_dir(&dir).unwrap();
        let binary = dir.join("vendor");
        std::fs::write(&binary, r#"#!/bin/sh
set -eu
if [ "$1" = auth ]; then
    printf '%s\n' '{"loggedIn": true,"email":"private-fixture"}'
    touch finished-claude
    exit 0
fi
IFS= read -r first
printf '%s\n' '{"id":1,"result":{}}'
IFS= read -r initialized
IFS= read -r account
case "$account" in *'"refreshToken":true'*) ;; *) exit 9 ;; esac
printf '%s\n' '{"method":"notice","params":{"payload":"ignored"}}' '{"id":2,"result":{"account":{"planType":"pro"}}}'
IFS= read -r limits
case "$limits" in *'"excludeResetCreditDetails":true'*) ;; *) exit 9 ;; esac
printf '%s\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300}}}}'
if IFS= read -r extra; then exit 9; fi
touch finished-codex
"#).unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();

        let (account, limits) = codex(&binary, &dir, true).unwrap();
        assert!(dir.join("finished-codex").exists());
        let normalized = super::super::normalize_codex_app_server(&limits, &account, 1000).unwrap();
        assert_eq!(normalized["windows"][0]["windowSeconds"], 18_000);
        std::fs::write(
            dir.join("auth.json"),
            r#"{"tokens":{"access_token":"synthetic-invalid-jwt","id_token":"not-a-token"}}"#,
        )
        .unwrap();
        let sample = collect("openai", &binary, &dir).unwrap();
        assert_eq!(sample["windows"][0]["usedPercent"], 42.0);
        assert_eq!(sample["subscription"]["statusReason"], "unrecognized_value");
        claude(&binary, &dir).unwrap();
        assert!(dir.join("finished-claude").exists());
        std::fs::write(
            dir.join(".credentials.json"),
            r#"{"claudeAiOauth":{"accessToken":"synthetic","expiresAt":1}}"#,
        )
        .unwrap();
        assert_eq!(
            collect("anthropic", &binary, &dir),
            Err(error("REFRESH_REJECTED"))
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
