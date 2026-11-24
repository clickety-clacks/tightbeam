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

const DEADLINE: Duration = Duration::from_secs(15);
const MAX_LINE: usize = 512 * 1024;

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
        claude(&binary, &dir).unwrap();
        assert!(dir.join("finished-claude").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
