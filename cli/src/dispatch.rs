use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::args::{Command, Identity, Target};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestSpec {
    pub path: &'static str,
    pub headers_sans_token_value: [(&'static str, &'static str); 2],
    pub body_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub base: String,
    pub token: String,
}

fn quoted(value: &str) -> String {
    serde_json::to_string(value).expect("strings are always JSON serializable")
}

fn identity_field(identity: &Identity) -> String {
    match identity {
        Identity::Role(value) => format!("\"as\":{}", quoted(value)),
        Identity::User(value) => format!("\"asUser\":{}", quoted(value)),
        Identity::Process(value) => format!("\"asProcess\":{}", quoted(value)),
    }
}

fn object(fields: Vec<String>) -> String {
    format!("{{{}}}", fields.join(","))
}

fn string_field(name: &str, value: &str) -> String {
    format!("\"{name}\":{}", quoted(value))
}

fn bool_field(name: &str, value: bool) -> String {
    format!("\"{name}\":{value}")
}

fn params_field(fields: Vec<String>) -> String {
    format!("\"params\":{}", object(fields))
}

fn request(
    identity: &Identity,
    verb: &str,
    mut fields: Vec<String>,
    params: Vec<String>,
) -> RequestSpec {
    let mut body = vec![identity_field(identity), string_field("verb", verb)];
    body.append(&mut fields);
    body.push(params_field(params));
    RequestSpec {
        path: "/agent/dispatch",
        headers_sans_token_value: [
            ("authorization", "Bearer <token>"),
            ("content-type", "application/json"),
        ],
        body_json: object(body),
    }
}

/// Build the dispatch request without performing discovery or network I/O.
pub fn build_request(command: &Command) -> Result<RequestSpec, String> {
    match command {
        Command::Help | Command::Setup(_) | Command::Assimilate(_) => {
            Err("command does not dispatch through /agent/dispatch".to_owned())
        }
        Command::Wake {
            identity,
            target,
            prompt,
            after_ms,
            at,
        } => {
            let target = match target {
                Target::Session(value) => string_field("sessionKey", value),
                Target::Role(value) => string_field("role", value),
                Target::User(value) => string_field("userId", value),
            };
            let mut params = vec![string_field("prompt", prompt)];
            if let Some(value) = after_ms {
                params.push(format!("\"afterMs\":{value}"));
            }
            if let Some(value) = at {
                params.push(format!("\"at\":{value}"));
            }
            Ok(request(identity, "wake", vec![target], params))
        }
        Command::ArtifactRecord {
            identity,
            kind,
            title,
            origin_path,
            description,
            work_item_id,
            content_sha256,
        } => {
            let mut params = vec![
                string_field("kind", kind),
                string_field("title", title),
                string_field("originPath", origin_path),
            ];
            for (name, value) in [
                ("description", description),
                ("workItemId", work_item_id),
                ("contentSha256", content_sha256),
            ] {
                if let Some(value) = value {
                    params.push(string_field(name, value));
                }
            }
            Ok(request(identity, "artifact-record", vec![], params))
        }
        Command::Artifacts {
            identity,
            work_item_id,
            session_key,
        } => {
            let mut params = Vec::new();
            for (name, value) in [("workItemId", work_item_id), ("sessionKey", session_key)] {
                if let Some(value) = value {
                    params.push(string_field(name, value));
                }
            }
            Ok(request(identity, "artifacts", vec![], params))
        }
        Command::Spawn {
            identity,
            display_name,
            idempotency_key,
            archetype,
            harness,
            model,
            handle,
            host,
        } => {
            let mut params = vec![
                string_field("displayName", display_name),
                string_field("idempotencyKey", idempotency_key),
            ];
            for (name, value) in [
                ("archetype", archetype),
                ("harness", harness),
                ("model", model),
                ("handle", handle),
                ("host", host),
            ] {
                if let Some(value) = value {
                    params.push(string_field(name, value));
                }
            }
            Ok(request(identity, "spawn", vec![], params))
        }
        Command::List { identity } => Ok(request(identity, "inspect", vec![], vec![])),
        Command::Retire {
            identity,
            session_key,
            idempotency_key,
        } => {
            let params = idempotency_key
                .as_ref()
                .map(|value| vec![string_field("idempotencyKey", value)])
                .unwrap_or_default();
            Ok(request(
                identity,
                "retire",
                vec![string_field("sessionKey", session_key)],
                params,
            ))
        }
        Command::Assign {
            identity,
            subject,
            target,
            idempotency_key,
            work_item_id,
            reviews,
            files,
        } => {
            let target = match target {
                Target::Session(value) => string_field("sessionKey", value),
                Target::Role(value) => string_field("role", value),
                Target::User(_) => unreachable!("assign has no user target"),
            };
            let mut params = vec![string_field("subject", subject)];
            if let Some(value) = idempotency_key {
                params.push(string_field("idempotencyKey", value));
            }
            if let Some(value) = work_item_id {
                params.push(string_field("workItemId", value));
            }
            if let Some(value) = reviews {
                params.push(string_field("reviews", value));
            }
            if let Some(value) = files {
                params.push(format!(
                    "\"files\":{}",
                    serde_json::to_string(value).expect("strings are JSON serializable")
                ));
            }
            Ok(request(identity, "assign", vec![target], params))
        }
        Command::Dispatch {
            identity,
            subject,
            holder,
            work_item_id,
            brief,
            idempotency_key,
        } => {
            let mut params = vec![
                string_field("subject", subject),
                string_field("brief", brief),
            ];
            if let Some(value) = work_item_id {
                params.push(string_field("workItemId", value));
            }
            if let Some(value) = idempotency_key {
                params.push(string_field("idempotencyKey", value));
            }
            Ok(request(
                identity,
                "dispatch",
                vec![string_field("sessionKey", holder)],
                params,
            ))
        }
        Command::RunTests {
            identity,
            assignment_id,
        } => Ok(request(
            identity,
            "run-tests",
            vec![],
            vec![string_field("assignmentId", assignment_id)],
        )),
        Command::RunSmoke {
            identity,
            assignment_id,
        } => Ok(request(
            identity,
            "run-smoke",
            vec![],
            vec![string_field("assignmentId", assignment_id)],
        )),
        Command::WorkItemCreate {
            identity,
            title,
            spec_ref_name,
            spec_ref_sha256,
        } => {
            let mut params = vec![string_field("title", title)];
            if let Some(value) = spec_ref_name {
                params.push(string_field("specRefName", value));
            }
            if let Some(value) = spec_ref_sha256 {
                params.push(string_field("specRefSha256", value));
            }
            Ok(request(identity, "work-item-create", vec![], params))
        }
        Command::WorkItemGet {
            identity,
            work_item_id,
        } => Ok(request(
            identity,
            "work-item-get",
            vec![],
            vec![string_field("workItemId", work_item_id)],
        )),
        Command::Attest {
            identity,
            assignment_id,
            kind,
            verdict,
            note,
        } => {
            let mut params = vec![
                string_field("assignmentId", assignment_id),
                string_field("kind", kind),
            ];
            if let Some(value) = note {
                params.push(string_field("note", value));
            }
            if let Some(value) = verdict {
                params.push(string_field("verdictKind", value));
            }
            Ok(request(identity, "attest", vec![], params))
        }
        Command::Attests {
            identity,
            assignment_id,
        } => Ok(request(
            identity,
            "attests",
            vec![],
            vec![string_field("assignmentId", assignment_id)],
        )),
        Command::Assignments {
            identity,
            target,
            state,
        } => {
            let fields = target
                .as_ref()
                .map(|target| match target {
                    Target::Session(value) => string_field("sessionKey", value),
                    Target::Role(value) => string_field("role", value),
                    Target::User(_) => unreachable!("assignments has no user target"),
                })
                .into_iter()
                .collect();
            let params = state
                .as_ref()
                .map(|value| vec![string_field("state", value)])
                .unwrap_or_default();
            Ok(request(identity, "assignments", fields, params))
        }
        Command::CancelWake { identity, wake_id } => Ok(request(
            identity,
            "wake",
            vec![],
            vec![string_field("cancelWakeId", wake_id)],
        )),
        Command::RoleCreate {
            identity,
            name,
            bind,
        } => {
            let mut params = vec![string_field("name", name)];
            if let Some(value) = bind {
                params.push(string_field("bind", value));
            }
            Ok(request(identity, "role-create", vec![], params))
        }
        Command::RoleBind {
            identity,
            name,
            session_key,
        } => Ok(request(
            identity,
            "role-bind",
            vec![],
            vec![
                string_field("name", name),
                string_field("sessionKey", session_key),
            ],
        )),
        Command::RoleRemove { identity, name } => Ok(request(
            identity,
            "role-rm",
            vec![],
            vec![string_field("name", name)],
        )),
        Command::RoleList { identity } => Ok(request(identity, "role-list", vec![], vec![])),
        Command::SkillList { identity } => Ok(request(identity, "skill-list", vec![], vec![])),
        Command::SkillPut {
            identity,
            name,
            content,
        } => Ok(request(
            identity,
            "skill-put",
            vec![],
            vec![string_field("name", name), string_field("content", content)],
        )),
        Command::SkillRemove { identity, name } => Ok(request(
            identity,
            "skill-rm",
            vec![],
            vec![string_field("name", name)],
        )),
        Command::ApproveDevice {
            identity,
            device_id,
            user_id,
        } => {
            let mut params = vec![string_field("deviceId", device_id)];
            if let Some(value) = user_id {
                params.push(string_field("userId", value));
            }
            Ok(request(identity, "approve-device", vec![], params))
        }
        Command::DenyDevice {
            identity,
            device_id,
        } => Ok(request(
            identity,
            "deny-device",
            vec![],
            vec![string_field("deviceId", device_id)],
        )),
        Command::RevokeDevice {
            identity,
            device_id,
        } => Ok(request(
            identity,
            "revoke-device",
            vec![],
            vec![string_field("deviceId", device_id)],
        )),
        Command::PromoteUser {
            identity,
            user_id,
            is_admin,
        } => Ok(request(
            identity,
            "promote-user",
            vec![],
            vec![
                string_field("userId", user_id),
                bool_field("isAdmin", *is_admin),
            ],
        )),
        Command::ConfigGet { identity, setting } => Ok(request(
            identity,
            "config",
            vec![],
            vec![
                string_field("action", "get"),
                string_field("setting", setting),
            ],
        )),
        Command::ConfigSet {
            identity,
            setting,
            value,
        } => Ok(request(
            identity,
            "config",
            vec![],
            vec![
                string_field("action", "set"),
                string_field("setting", setting),
                string_field("value", value),
            ],
        )),
    }
}

pub fn build_register_host_request(
    as_user: &str,
    name: &str,
    ssh: &str,
    base_dir: &str,
    cli_bin: &str,
    adapter_bin_dir: &str,
) -> RequestSpec {
    request(
        &Identity::User(as_user.to_owned()),
        "register-host",
        vec![],
        vec![
            string_field("name", name),
            string_field("ssh", ssh),
            string_field("baseDir", base_dir),
            string_field("cliBin", cli_bin),
            string_field("adapterBinDir", adapter_bin_dir),
        ],
    )
}

pub fn discover() -> Result<Endpoint, String> {
    #[allow(deprecated)]
    let home = std::env::home_dir().unwrap_or_default();
    discover_with(|name| std::env::var(name).ok(), &home)
}

fn gateway_config_path<F>(get_env: &F, home_dir: &Path) -> PathBuf
where
    F: Fn(&str) -> Option<String>,
{
    get_env("TIGHTBEAM_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir.join(".tightbeam"))
        .join("gateway.json")
}

fn discover_with<F>(get_env: F, home_dir: &Path) -> Result<Endpoint, String>
where
    F: Fn(&str) -> Option<String>,
{
    let url = get_env("TIGHTBEAM_URL").filter(|value| !value.is_empty());
    let token = get_env("TIGHTBEAM_TOKEN").filter(|value| !value.is_empty());
    if let (Some(base), Some(token)) = (url, token) {
        return Ok(Endpoint { base, token });
    }

    let path = gateway_config_path(&get_env, home_dir);
    let encoded = fs::read_to_string(&path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            format!(
                "ENOENT: no such file or directory, open '{}'",
                path.display()
            )
        } else {
            error.to_string()
        }
    })?;
    let config: Value = serde_json::from_str(&encoded).map_err(|error| error.to_string())?;
    let port = config
        .get("port")
        .map(Value::to_string)
        .unwrap_or_else(|| "undefined".to_owned());
    let token = config
        .get("cliToken")
        .and_then(Value::as_str)
        .unwrap_or("undefined")
        .to_owned();
    Ok(Endpoint {
        base: format!("http://127.0.0.1:{port}"),
        token,
    })
}

pub fn send(request: &RequestSpec) -> Result<Option<Value>, String> {
    let endpoint = discover()?;
    send_to(&endpoint, request)
}

fn send_to(endpoint: &Endpoint, request: &RequestSpec) -> Result<Option<Value>, String> {
    let url = format!("{}{}", endpoint.base, request.path);
    let call = ureq::post(&url)
        .set("authorization", &format!("Bearer {}", endpoint.token))
        .set("content-type", "application/json")
        .send_string(&request.body_json);

    let (status, response) = match call {
        Ok(response) => (response.status(), response),
        Err(ureq::Error::Status(status, response)) => (status, response),
        Err(ureq::Error::Transport(error)) => return Err(error.to_string()),
    };
    let encoded = response.into_string().map_err(|error| error.to_string())?;
    parse_response(status, &encoded)
}

fn parse_response(status: u16, encoded: &str) -> Result<Option<Value>, String> {
    let json: Value = serde_json::from_str(encoded).map_err(|error| error.to_string())?;

    if !(200..300).contains(&status) {
        let code = json
            .pointer("/error/code")
            .and_then(Value::as_str)
            .unwrap_or("undefined");
        let message = json.pointer("/error/message").and_then(Value::as_str);
        return Err(match message {
            Some(message) if !message.is_empty() => format!("{code}: {message}"),
            _ => code.to_owned(),
        });
    }

    if json.get("error").is_some_and(|error| !error.is_null()) {
        return Err(serde_json::to_string_pretty(&json).expect("JSON value serializes"));
    }
    Ok(json.get("result").cloned())
}

pub fn run(command: Command) -> Result<(), String> {
    match command {
        Command::Help => unreachable!("help is handled before dispatch"),
        Command::Setup(args) => crate::ceremonies::setup(args),
        Command::Assimilate(args) => crate::ceremonies::assimilate(args),
        command => {
            let request = build_request(&command)?;
            if let Some(result) = send(&request)? {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&result).expect("JSON value serializes")
                );
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args;
    use std::collections::HashMap;
    use std::process::Command as ProcessCommand;
    use std::time::{SystemTime, UNIX_EPOCH};

    const DISCOVERY_CHILD: &str = "TIGHTBEAM_TEST_DISCOVERY_CHILD";
    const EXPECTED_BASE: &str = "TIGHTBEAM_TEST_EXPECTED_BASE";
    const EXPECTED_TOKEN: &str = "TIGHTBEAM_TEST_EXPECTED_TOKEN";
    const EXPECTED_ERROR: &str = "TIGHTBEAM_TEST_EXPECTED_ERROR";

    fn parse(values: &[&str]) -> Command {
        args::parse(values.iter().map(|value| (*value).to_owned()).collect()).unwrap()
    }

    fn body(values: &[&str]) -> String {
        build_request(&parse(values)).unwrap().body_json
    }

    #[test]
    fn builds_byte_exact_wake_bodies_for_every_target() {
        assert_eq!(
            body(&[
                "wake",
                "--session",
                "agent:r",
                "--prompt",
                "go",
                "--after",
                "30s",
                "--as",
                "coder"
            ]),
            r#"{"as":"coder","verb":"wake","sessionKey":"agent:r","params":{"prompt":"go","afterMs":30000}}"#
        );
        assert_eq!(
            body(&[
                "wake",
                "--role",
                "reviewer",
                "--prompt",
                "go",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"wake","role":"reviewer","params":{"prompt":"go"}}"#
        );
        assert_eq!(
            body(&[
                "wake",
                "--user",
                "mike",
                "--prompt",
                "go",
                "--at",
                "123",
                "--as-process",
                "cron"
            ]),
            r#"{"asProcess":"cron","verb":"wake","userId":"mike","params":{"prompt":"go","at":123}}"#
        );
        assert_eq!(
            body(&[
                "wake",
                "--user",
                "mike",
                "--prompt",
                "go",
                "--at",
                "+1",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"wake","userId":"mike","params":{"prompt":"go","at":1}}"#
        );
        assert_eq!(
            body(&[
                "wake",
                "--user",
                "mike",
                "--prompt",
                "go",
                "--at",
                "0x10",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"wake","userId":"mike","params":{"prompt":"go","at":16}}"#
        );
    }

    #[test]
    fn builds_byte_exact_spawn_role_skill_and_promote_bodies() {
        assert_eq!(
            body(&[
                "spawn",
                "--display",
                "Reviewer",
                "--name",
                "reviewer",
                "--archetype",
                "worker",
                "--harness",
                "codex",
                "--model",
                "gpt",
                "--host",
                "eezo",
                "--key",
                "k1",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"spawn","params":{"displayName":"Reviewer","idempotencyKey":"k1","archetype":"worker","harness":"codex","model":"gpt","handle":"reviewer","host":"eezo"}}"#
        );
        assert_eq!(
            body(&[
                "role",
                "bind",
                "reviewer",
                "agent:r",
                "--as",
                "orchestrator"
            ]),
            r#"{"as":"orchestrator","verb":"role-bind","params":{"name":"reviewer","sessionKey":"agent:r"}}"#
        );

        let command = Command::SkillPut {
            identity: Identity::User("flynn".to_owned()),
            name: "swift/concurrency".to_owned(),
            content: "line one\nline two".to_owned(),
        };
        assert_eq!(
            build_request(&command).unwrap().body_json,
            r#"{"asUser":"flynn","verb":"skill-put","params":{"name":"swift/concurrency","content":"line one\nline two"}}"#
        );
        assert_eq!(
            body(&["promote-user", "mike", "--demote", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"promote-user","params":{"userId":"mike","isAdmin":false}}"#
        );
    }

    #[test]
    fn builds_byte_exact_artifact_bodies() {
        assert_eq!(
            body(&[
                "artifact-record",
                "--kind",
                "spec",
                "--title",
                "Banana design",
                "--path",
                "specs/banana.md",
                "--description",
                "Ratified design",
                "--work-item",
                "wi_1",
                "--sha256",
                "abc123",
                "--as",
                "writer",
            ]),
            r#"{"as":"writer","verb":"artifact-record","params":{"kind":"spec","title":"Banana design","originPath":"specs/banana.md","description":"Ratified design","workItemId":"wi_1","contentSha256":"abc123"}}"#
        );
        assert_eq!(
            body(&[
                "artifacts",
                "--work-item",
                "wi_1",
                "--session",
                "agent:writer:app",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"artifacts","params":{"workItemId":"wi_1","sessionKey":"agent:writer:app"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_assignment_bodies() {
        assert_eq!(
            body(&[
                "assign",
                "--subject",
                "ship",
                "--role",
                "builder",
                "--key",
                "idem",
                "--work-item",
                "wi_1",
                "--reviews",
                "asg_parent",
                "--files",
                "[\"lib/a.ex\",\"test/a_test.exs\"]",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"assign","role":"builder","params":{"subject":"ship","idempotencyKey":"idem","workItemId":"wi_1","reviews":"asg_parent","files":["lib/a.ex","test/a_test.exs"]}}"#
        );
        assert_eq!(
            body(&[
                "dispatch",
                "--holder",
                "agent:builder",
                "--subject",
                "ship",
                "--brief",
                "Please ship it.",
                "--work-item",
                "wi_1",
                "--key",
                "idem",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"dispatch","sessionKey":"agent:builder","params":{"subject":"ship","brief":"Please ship it.","workItemId":"wi_1","idempotencyKey":"idem"}}"#
        );
        assert_eq!(
            body(&[
                "assignments",
                "--session",
                "s1",
                "--state",
                "all",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"assignments","sessionKey":"s1","params":{"state":"all"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_attest_bodies() {
        assert_eq!(
            body(&[
                "attest",
                "asg_1",
                "--kind",
                "completion",
                "--note",
                "ready",
                "--as",
                "builder",
            ]),
            r#"{"as":"builder","verb":"attest","params":{"assignmentId":"asg_1","kind":"completion","note":"ready"}}"#
        );
        assert_eq!(
            body(&[
                "attest",
                "asg_1",
                "--kind",
                "verdict",
                "--verdict",
                "tests-passed",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"attest","params":{"assignmentId":"asg_1","kind":"verdict","verdictKind":"tests-passed"}}"#
        );
        assert_eq!(
            body(&["attests", "asg_1", "--as", "reviewer"]),
            r#"{"as":"reviewer","verb":"attests","params":{"assignmentId":"asg_1"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_work_item_bodies() {
        let sha = "a".repeat(64);
        assert_eq!(
            body(&[
                "work-item-create",
                "--title",
                "Ship",
                "--spec-ref",
                "spec.md",
                "--spec-sha256",
                &sha,
                "--as-user",
                "flynn",
            ]),
            format!(
                r#"{{"asUser":"flynn","verb":"work-item-create","params":{{"title":"Ship","specRefName":"spec.md","specRefSha256":"{sha}"}}}}"#
            )
        );
        assert_eq!(
            body(&["work-item-get", "wi_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-get","params":{"workItemId":"wi_1"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_producer_bodies() {
        assert_eq!(
            body(&["run-tests", "asg_1", "--as", "builder"]),
            r#"{"as":"builder","verb":"run-tests","params":{"assignmentId":"asg_1"}}"#
        );
        assert_eq!(
            body(&["run-smoke", "asg_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"run-smoke","params":{"assignmentId":"asg_1"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_config_bodies() {
        assert_eq!(
            body(&["config", "get", "default-archetype", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"config","params":{"action":"get","setting":"default-archetype"}}"#
        );
        assert_eq!(
            body(&[
                "config",
                "set",
                "default-archetype",
                "coder",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"config","params":{"action":"set","setting":"default-archetype","value":"coder"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_bodies_for_all_remaining_dispatch_commands() {
        for (args, expected) in [
            (
                &["list", "--as", "coder"][..],
                r#"{"as":"coder","verb":"inspect","params":{}}"#,
            ),
            (
                &[
                    "retire",
                    "--session",
                    "agent:r",
                    "--key",
                    "retire-k",
                    "--as-user",
                    "flynn",
                ][..],
                r#"{"asUser":"flynn","verb":"retire","sessionKey":"agent:r","params":{"idempotencyKey":"retire-k"}}"#,
            ),
            (
                &["cancel-wake", "wake-1", "--as-process", "cron"][..],
                r#"{"asProcess":"cron","verb":"wake","params":{"cancelWakeId":"wake-1"}}"#,
            ),
            (
                &[
                    "role",
                    "create",
                    "reviewer",
                    "--bind",
                    "agent:r",
                    "--as-user",
                    "flynn",
                ][..],
                r#"{"asUser":"flynn","verb":"role-create","params":{"name":"reviewer","bind":"agent:r"}}"#,
            ),
            (
                &["role", "rm", "reviewer", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"role-rm","params":{"name":"reviewer"}}"#,
            ),
            (
                &["role", "list", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"role-list","params":{}}"#,
            ),
            (
                &["skill", "list", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"skill-list","params":{}}"#,
            ),
            (
                &["skill", "rm", "swift", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"skill-rm","params":{"name":"swift"}}"#,
            ),
            (
                &[
                    "approve-device",
                    "device-1",
                    "--user",
                    "mike",
                    "--as-user",
                    "flynn",
                ][..],
                r#"{"asUser":"flynn","verb":"approve-device","params":{"deviceId":"device-1","userId":"mike"}}"#,
            ),
            (
                &["deny-device", "device-2", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"deny-device","params":{"deviceId":"device-2"}}"#,
            ),
            (
                &["revoke-device", "device-3", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"revoke-device","params":{"deviceId":"device-3"}}"#,
            ),
            (
                &["promote-user", "mike", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"promote-user","params":{"userId":"mike","isAdmin":true}}"#,
            ),
        ] {
            assert_eq!(body(args), expected);
        }
    }

    #[test]
    fn discovery_prefers_complete_env_then_tightbeam_home_then_home() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("tightbeam_cli_discovery_{unique}"));
        let configured = root.join("configured");
        let default = root.join(".tightbeam");
        fs::create_dir_all(&configured).unwrap();
        fs::create_dir_all(&default).unwrap();
        fs::write(
            configured.join("gateway.json"),
            r#"{"port":4321,"cliToken":"configured"}"#,
        )
        .unwrap();
        fs::write(
            default.join("gateway.json"),
            r#"{"port":9876,"cliToken":"default"}"#,
        )
        .unwrap();

        let env = HashMap::from([
            ("TIGHTBEAM_URL".to_owned(), "https://gateway".to_owned()),
            ("TIGHTBEAM_TOKEN".to_owned(), "env-token".to_owned()),
            (
                "TIGHTBEAM_HOME".to_owned(),
                configured.display().to_string(),
            ),
        ]);
        assert_eq!(
            discover_with(|name| env.get(name).cloned(), &root),
            Ok(Endpoint {
                base: "https://gateway".to_owned(),
                token: "env-token".to_owned()
            })
        );

        let env = HashMap::from([(
            "TIGHTBEAM_HOME".to_owned(),
            configured.display().to_string(),
        )]);
        assert_eq!(
            discover_with(|name| env.get(name).cloned(), &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:4321".to_owned(),
                token: "configured".to_owned()
            })
        );
        assert_eq!(
            discover_with(|_| None, &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:9876".to_owned(),
                token: "default".to_owned()
            })
        );
        let env = HashMap::from([("TIGHTBEAM_HOME".to_owned(), String::new())]);
        assert_eq!(
            gateway_config_path(&|name| env.get(name).cloned(), &root),
            PathBuf::from("gateway.json")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn discovery_ignores_session_files_across_full_precedence_matrix() {
        if std::env::var_os(DISCOVERY_CHILD).is_some() {
            if let Ok(expected) = std::env::var(EXPECTED_ERROR) {
                assert_eq!(discover(), Err(expected));
            } else {
                assert_eq!(
                    discover(),
                    Ok(Endpoint {
                        base: std::env::var(EXPECTED_BASE).unwrap(),
                        token: std::env::var(EXPECTED_TOKEN).unwrap(),
                    })
                );
            }
            return;
        }

        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "tightbeam_cli_session_ignored_{}_{}",
            std::process::id(),
            unique
        ));
        let ancestor = root.join("ancestor");
        let cwd = ancestor.join("work").join("nested");
        let configured = root.join("configured");
        let home = root.join("home");
        let empty_home = root.join("empty-home");

        for directory in [&cwd, &configured, &home.join(".tightbeam"), &empty_home] {
            fs::create_dir_all(directory).unwrap();
        }
        fs::write(
            ancestor.join(".tightbeam-session"),
            r#"{"url":"https://ancestor-session","token":"ancestor-token"}"#,
        )
        .unwrap();
        fs::write(
            ancestor.join("work").join(".tightbeam-session"),
            r#"{"url":"https://nearest-session","token":"nearest-token"}"#,
        )
        .unwrap();
        fs::write(
            configured.join("gateway.json"),
            r#"{"port":4321,"cliToken":"configured"}"#,
        )
        .unwrap();
        fs::write(
            home.join(".tightbeam").join("gateway.json"),
            r#"{"port":9876,"cliToken":"default"}"#,
        )
        .unwrap();

        let configured_path = configured.display().to_string();
        let home_path = home.display().to_string();
        let empty_home_path = empty_home.display().to_string();
        let missing_config = empty_home.join(".tightbeam").join("gateway.json");
        let missing_error = format!(
            "ENOENT: no such file or directory, open '{}'",
            missing_config.display()
        );
        let cases = [
            (
                "complete env",
                vec![
                    ("HOME", home_path.as_str()),
                    ("TIGHTBEAM_HOME", configured_path.as_str()),
                    ("TIGHTBEAM_URL", "https://env-gateway"),
                    ("TIGHTBEAM_TOKEN", "env-token"),
                    (EXPECTED_BASE, "https://env-gateway"),
                    (EXPECTED_TOKEN, "env-token"),
                ],
            ),
            (
                "url-only env falls back to configured home",
                vec![
                    ("HOME", home_path.as_str()),
                    ("TIGHTBEAM_HOME", configured_path.as_str()),
                    ("TIGHTBEAM_URL", "https://incomplete"),
                    (EXPECTED_BASE, "http://127.0.0.1:4321"),
                    (EXPECTED_TOKEN, "configured"),
                ],
            ),
            (
                "token-only env falls back to configured home",
                vec![
                    ("HOME", home_path.as_str()),
                    ("TIGHTBEAM_HOME", configured_path.as_str()),
                    ("TIGHTBEAM_TOKEN", "incomplete"),
                    (EXPECTED_BASE, "http://127.0.0.1:4321"),
                    (EXPECTED_TOKEN, "configured"),
                ],
            ),
            (
                "configured home without env credentials",
                vec![
                    ("HOME", home_path.as_str()),
                    ("TIGHTBEAM_HOME", configured_path.as_str()),
                    (EXPECTED_BASE, "http://127.0.0.1:4321"),
                    (EXPECTED_TOKEN, "configured"),
                ],
            ),
            (
                "default home",
                vec![
                    ("HOME", home_path.as_str()),
                    (EXPECTED_BASE, "http://127.0.0.1:9876"),
                    (EXPECTED_TOKEN, "default"),
                ],
            ),
            (
                "session files alone are not discovery sources",
                vec![
                    ("HOME", empty_home_path.as_str()),
                    (EXPECTED_ERROR, missing_error.as_str()),
                ],
            ),
        ];

        let current_exe = std::env::current_exe().unwrap();
        for (name, environment) in cases {
            let output = ProcessCommand::new(&current_exe)
                .arg("--exact")
                .arg("dispatch::tests::discovery_ignores_session_files_across_full_precedence_matrix")
                .arg("--nocapture")
                .current_dir(&cwd)
                .env_clear()
                .env(DISCOVERY_CHILD, "1")
                .envs(environment)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{name} child failed\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn successful_error_envelopes_are_visible_failures() {
        assert_eq!(
            parse_response(200, r#"{"error":{"code":"denied","message":"no"}}"#),
            Err(
                "{\n  \"error\": {\n    \"code\": \"denied\",\n    \"message\": \"no\"\n  }\n}"
                    .to_owned()
            )
        );
        assert_eq!(
            parse_response(403, r#"{"error":{"code":"denied","message":"no"}}"#),
            Err("denied: no".to_owned())
        );
    }
}
