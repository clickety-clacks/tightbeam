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
    pub session_file: bool,
}

fn quoted(value: &str) -> String {
    serde_json::to_string(value).expect("strings are always JSON serializable")
}

fn identity_field(identity: &Identity) -> Option<String> {
    match identity {
        Identity::Role(value) => Some(format!("\"as\":{}", quoted(value))),
        Identity::User(value) => Some(format!("\"asUser\":{}", quoted(value))),
        Identity::Process(value) => Some(format!("\"asProcess\":{}", quoted(value))),
        Identity::Omitted => None,
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

fn string_array_field(name: &str, value: &[String]) -> String {
    format!(
        "\"{name}\":{}",
        serde_json::to_string(value).expect("string arrays are JSON serializable")
    )
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
    let mut body = Vec::new();
    if let Some(identity) = identity_field(identity) {
        body.push(identity);
    }
    body.push(string_field("verb", verb));
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
        Command::Help
        | Command::Probe { .. }
        | Command::Init(_)
        | Command::Setup(_)
        | Command::Assimilate(_) => {
            Err("command does not dispatch through /agent/dispatch".to_owned())
        }
        Command::Wake {
            identity,
            target,
            prompt,
            after_ms,
            at,
            condition_kind,
            condition_scope,
            idempotency_key,
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
            for (name, value) in [
                ("conditionKind", condition_kind),
                ("conditionScope", condition_scope),
                ("idempotencyKey", idempotency_key),
            ] {
                if let Some(value) = value {
                    params.push(string_field(name, value));
                }
            }
            Ok(request(identity, "wake", vec![target], params))
        }
        Command::Condition {
            identity,
            kind,
            scope,
            idempotency_key,
        } => {
            let mut params = vec![string_field("kind", kind)];
            if let Some(value) = scope {
                params.push(string_field("scope", value));
            }
            if let Some(value) = idempotency_key {
                params.push(string_field("idempotencyKey", value));
            }
            Ok(request(identity, "condition", vec![], params))
        }
        Command::FactsRead {
            identity,
            kind,
            scope,
        } => {
            let mut params = vec![string_field("kind", kind)];
            if let Some(value) = scope {
                params.push(string_field("scope", value));
            }
            Ok(request(identity, "facts-read", vec![], params))
        }
        Command::Rule {
            identity,
            request_id,
            decision,
            rationale,
        } => {
            let mut params = vec![
                string_field("requestId", request_id),
                string_field("decision", decision),
            ];
            if let Some(value) = rationale {
                params.push(string_field("rationale", value));
            }
            Ok(request(identity, "rule", vec![], params))
        }
        Command::Waive {
            identity,
            request_id,
            session_key,
            statute_name,
            reason,
        } => {
            let mut params = Vec::new();
            for (name, value) in [
                ("requestId", request_id),
                ("sessionKey", session_key),
                ("statuteName", statute_name),
                ("reason", reason),
            ] {
                if let Some(value) = value {
                    params.push(string_field(name, value));
                }
            }
            Ok(request(identity, "waive", vec![], params))
        }
        Command::RevokeWaiver {
            identity,
            waiver_id,
            reason,
        } => {
            let mut params = vec![string_field("waiverId", waiver_id)];
            if let Some(value) = reason {
                params.push(string_field("reason", value));
            }
            Ok(request(identity, "revoke-waiver", vec![], params))
        }
        Command::Withdraw {
            identity,
            request_id,
            reason,
        } => Ok(request(
            identity,
            "withdraw",
            vec![],
            vec![
                string_field("requestId", request_id),
                string_field("reason", reason),
            ],
        )),
        Command::DecisionRequests { identity, status } => {
            let params = status
                .as_ref()
                .map(|value| vec![string_field("status", value)])
                .unwrap_or_default();
            Ok(request(identity, "decision-requests", vec![], params))
        }
        Command::DecisionRequest {
            identity,
            request_id,
        } => Ok(request(
            identity,
            "decision-request",
            vec![],
            vec![string_field("requestId", request_id)],
        )),
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
        Command::Critical {
            identity,
            for_ms,
            reason,
        } => Ok(request(
            identity,
            "critical",
            vec![],
            vec![
                format!("\"forMs\":{for_ms}"),
                string_field("reason", reason),
            ],
        )),
        Command::Adjudicate {
            identity,
            episode,
            action,
            model,
            reason,
        } => {
            let mut params = vec![
                string_field("episode", episode),
                string_field("action", action),
            ];
            if let Some(value) = model {
                params.push(string_field("model", value));
            }
            if let Some(value) = reason {
                params.push(string_field("reason", value));
            }
            Ok(request(identity, "adjudicate", vec![], params))
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
                params.push(string_array_field("files", value));
            }
            Ok(request(identity, "assign", vec![target], params))
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
        Command::CancelProducerJob { identity, job_id } => Ok(request(
            identity,
            "cancel-producer-job",
            vec![],
            vec![string_field("jobId", job_id)],
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
        Command::WorkItemUpdate {
            identity,
            work_item_id,
            title,
            spec_ref_name,
            spec_ref_sha256,
            clear_spec_ref,
        } => {
            let mut params = vec![string_field("workItemId", work_item_id)];
            if let Some(value) = title {
                params.push(string_field("title", value));
            }
            if *clear_spec_ref {
                params.push("\"specRefName\":null".to_owned());
                params.push("\"specRefSha256\":null".to_owned());
            } else {
                if let Some(value) = spec_ref_name {
                    params.push(string_field("specRefName", value));
                }
                if let Some(value) = spec_ref_sha256 {
                    params.push(string_field("specRefSha256", value));
                }
            }
            Ok(request(identity, "work-item-update", vec![], params))
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
        Command::WorkItemList { identity } => {
            Ok(request(identity, "work-item-list", vec![], vec![]))
        }
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
        Command::RevokeAssignment {
            identity,
            assignment_id,
        } => Ok(request(
            identity,
            "revoke-assignment",
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
    let cwd = std::env::current_dir().map_err(|error| error.to_string())?;
    discover_with(|name| std::env::var(name).ok(), &cwd, &home)
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

fn discover_with<F>(get_env: F, cwd: &Path, home_dir: &Path) -> Result<Endpoint, String>
where
    F: Fn(&str) -> Option<String>,
{
    for directory in cwd.ancestors() {
        let path = directory.join(".tightbeam-session");
        if !path.exists() {
            continue;
        }

        let encoded = fs::read_to_string(&path)
            .map_err(|error| format!("malformed session file '{}': {error}", path.display()))?;
        let config: Value = serde_json::from_str(&encoded)
            .map_err(|error| format!("malformed session file '{}': {error}", path.display()))?;
        let base = config
            .get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("malformed session file '{}': missing url", path.display()))?;
        let token = config
            .get("token")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("malformed session file '{}': missing token", path.display()))?;
        return Ok(Endpoint {
            base: base.to_owned(),
            token: token.to_owned(),
            session_file: true,
        });
    }

    let url = get_env("TIGHTBEAM_URL").filter(|value| !value.is_empty());
    let token = get_env("TIGHTBEAM_TOKEN").filter(|value| !value.is_empty());
    if let (Some(base), Some(token)) = (url, token) {
        return Ok(Endpoint {
            base,
            token,
            session_file: false,
        });
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
        session_file: false,
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
    run_with(command, discover, send_to)
}

fn run_with<D, S>(command: Command, discover_endpoint: D, send_request: S) -> Result<(), String>
where
    D: FnOnce() -> Result<Endpoint, String>,
    S: FnOnce(&Endpoint, &RequestSpec) -> Result<Option<Value>, String>,
{
    match command {
        Command::Help => unreachable!("help is handled before dispatch"),
        Command::Probe { json, base_dir } => crate::probe::run(json, base_dir),
        Command::Init(args) => crate::ceremonies::init(args),
        Command::Setup(args) => crate::ceremonies::setup(args),
        Command::Assimilate(args) => crate::ceremonies::assimilate(args),
        command => {
            let endpoint = discover_endpoint()?;
            if identity_omitted(&command) && !endpoint.session_file {
                return Err("identity required: pass --as <your-agent-handle> (when an agent runs this) or --as-user <userId> (operator action). This is WHO the call is from, not the target. Run 'tightbeam help'.".to_owned());
            }
            let request = build_request(&command)?;
            if let Some(result) = send_request(&endpoint, &request)? {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&result).expect("JSON value serializes")
                );
            }
            Ok(())
        }
    }
}

fn identity_omitted(command: &Command) -> bool {
    let identity = match command {
        Command::Wake { identity, .. }
        | Command::Condition { identity, .. }
        | Command::FactsRead { identity, .. }
        | Command::Rule { identity, .. }
        | Command::Waive { identity, .. }
        | Command::RevokeWaiver { identity, .. }
        | Command::Withdraw { identity, .. }
        | Command::DecisionRequests { identity, .. }
        | Command::DecisionRequest { identity, .. }
        | Command::Spawn { identity, .. }
        | Command::List { identity }
        | Command::Retire { identity, .. }
        | Command::Critical { identity, .. }
        | Command::Adjudicate { identity, .. }
        | Command::Assign { identity, .. }
        | Command::RunTests { identity, .. }
        | Command::RunSmoke { identity, .. }
        | Command::CancelProducerJob { identity, .. }
        | Command::WorkItemCreate { identity, .. }
        | Command::WorkItemUpdate { identity, .. }
        | Command::WorkItemGet { identity, .. }
        | Command::WorkItemList { identity }
        | Command::Attest { identity, .. }
        | Command::Attests { identity, .. }
        | Command::RevokeAssignment { identity, .. }
        | Command::Assignments { identity, .. }
        | Command::CancelWake { identity, .. }
        | Command::RoleCreate { identity, .. }
        | Command::RoleBind { identity, .. }
        | Command::RoleRemove { identity, .. }
        | Command::RoleList { identity }
        | Command::SkillList { identity }
        | Command::SkillPut { identity, .. }
        | Command::SkillRemove { identity, .. }
        | Command::ApproveDevice { identity, .. }
        | Command::DenyDevice { identity, .. }
        | Command::RevokeDevice { identity, .. }
        | Command::PromoteUser { identity, .. } => identity,
        Command::Help
        | Command::Probe { .. }
        | Command::Init(_)
        | Command::Setup(_)
        | Command::Assimilate(_) => {
            return false;
        }
    };
    matches!(identity, Identity::Omitted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args;

    #[test]
    fn builds_critical_request() {
        assert_eq!(
            build_request(&Command::Critical {
                identity: Identity::Role("coder".to_owned()),
                for_ms: "300000".to_owned(),
                reason: "main commit".to_owned(),
            })
            .unwrap()
            .body_json,
            r#"{"as":"coder","verb":"critical","params":{"forMs":300000,"reason":"main commit"}}"#
        );
    }
    use std::collections::HashMap;
    use std::time::{SystemTime, UNIX_EPOCH};

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

        assert_eq!(
            body(&[
                "wake",
                "--session",
                "agent:r",
                "--prompt",
                "retry",
                "--when-fact",
                "quota-recovered",
                "--when-scope",
                "codex:sol",
                "--fallback-after",
                "30m",
                "--key",
                "wake-1",
                "--as",
                "coder",
            ]),
            r#"{"as":"coder","verb":"wake","sessionKey":"agent:r","params":{"prompt":"retry","afterMs":1800000,"conditionKind":"quota-recovered","conditionScope":"codex:sol","idempotencyKey":"wake-1"}}"#
        );

        assert_eq!(
            body(&[
                "condition",
                "--kind",
                "deploy-succeeded",
                "--scope",
                "prod",
                "--key",
                "deploy-1",
                "--as-process",
                "ci",
            ]),
            r#"{"asProcess":"ci","verb":"condition","params":{"kind":"deploy-succeeded","scope":"prod","idempotencyKey":"deploy-1"}}"#
        );

        assert_eq!(
            body(&[
                "facts-read",
                "--kind",
                "tour-given",
                "--scope",
                "agent:tour:app",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"facts-read","params":{"kind":"tour-given","scope":"agent:tour:app"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_escalation_bodies() {
        assert_eq!(
            body(&[
                "rule",
                "--request",
                "dr_1",
                "--decision",
                "allow",
                "--rationale",
                "safe",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"rule","params":{"requestId":"dr_1","decision":"allow","rationale":"safe"}}"#
        );
        assert_eq!(
            body(&[
                "waive",
                "--session",
                "s1",
                "--statute",
                "review",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"waive","params":{"sessionKey":"s1","statuteName":"review"}}"#
        );
        assert_eq!(
            body(&["decision-request", "dr_1", "--as", "coder"]),
            r#"{"as":"coder","verb":"decision-request","params":{"requestId":"dr_1"}}"#
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
    fn builds_byte_exact_assignment_bodies() {
        assert_eq!(
            body(&[
                "assign",
                "--subject",
                "ship",
                "--role",
                "builder",
                "--idempotency-key",
                "idem",
                "--work-item",
                "wi_1",
                "--reviews",
                "asg_parent",
                "--files",
                "[\"lib/a.ex\",\"test/a_test.exs\"]",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"assign","role":"builder","params":{"subject":"ship","idempotencyKey":"idem","workItemId":"wi_1","reviews":"asg_parent","files":["lib/a.ex","test/a_test.exs"]}}"#
        );
        assert_eq!(
            body(&[
                "attest",
                "asg_1",
                "--kind",
                "completion",
                "--note",
                "ready",
                "--as",
                "builder"
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
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"attest","params":{"assignmentId":"asg_1","kind":"verdict","verdictKind":"tests-passed"}}"#
        );
        assert_eq!(
            body(&["attests", "asg_1", "--as", "reviewer"]),
            r#"{"as":"reviewer","verb":"attests","params":{"assignmentId":"asg_1"}}"#
        );
        assert_eq!(
            body(&["revoke-assignment", "asg_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"revoke-assignment","params":{"assignmentId":"asg_1"}}"#
        );
        assert_eq!(
            body(&[
                "assignments",
                "--session",
                "s1",
                "--state",
                "all",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"assignments","sessionKey":"s1","params":{"state":"all"}}"#
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
        assert_eq!(
            body(&["cancel-producer-job", "pj_1", "--as", "builder"]),
            r#"{"as":"builder","verb":"cancel-producer-job","params":{"jobId":"pj_1"}}"#
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
                "flynn"
            ]),
            format!(
                r#"{{"asUser":"flynn","verb":"work-item-create","params":{{"title":"Ship","specRefName":"spec.md","specRefSha256":"{sha}"}}}}"#
            )
        );
        assert_eq!(
            body(&[
                "work-item-update",
                "wi_1",
                "--clear-spec-ref",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"work-item-update","params":{"workItemId":"wi_1","specRefName":null,"specRefSha256":null}}"#
        );
        assert_eq!(
            body(&["work-item-get", "wi_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-get","params":{"workItemId":"wi_1"}}"#
        );
        assert_eq!(
            body(&["work-item-list", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-list","params":{}}"#
        );
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
            discover_with(|name| env.get(name).cloned(), &root, &root),
            Ok(Endpoint {
                base: "https://gateway".to_owned(),
                token: "env-token".to_owned(),
                session_file: false,
            })
        );

        let env = HashMap::from([(
            "TIGHTBEAM_HOME".to_owned(),
            configured.display().to_string(),
        )]);
        assert_eq!(
            discover_with(|name| env.get(name).cloned(), &root, &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:4321".to_owned(),
                token: "configured".to_owned(),
                session_file: false,
            })
        );
        assert_eq!(
            discover_with(|_| None, &root, &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:9876".to_owned(),
                token: "default".to_owned(),
                session_file: false,
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
    fn discovery_walks_up_and_session_file_wins() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("tightbeam_cli_session_{unique}"));
        let nested = root.join("one/two");
        fs::create_dir_all(&nested).unwrap();
        fs::write(
            root.join(".tightbeam-session"),
            r#"{"url":"https://session","token":"tbs_test","sessionKey":"s1","future":true}"#,
        )
        .unwrap();
        let env = HashMap::from([
            ("TIGHTBEAM_URL".to_owned(), "https://env".to_owned()),
            ("TIGHTBEAM_TOKEN".to_owned(), "env-token".to_owned()),
        ]);

        assert_eq!(
            discover_with(|name| env.get(name).cloned(), &nested, &root),
            Ok(Endpoint {
                base: "https://session".to_owned(),
                token: "tbs_test".to_owned(),
                session_file: true,
            })
        );
        assert_eq!(
            build_request(&Command::List {
                identity: Identity::Omitted
            })
            .unwrap()
            .body_json,
            r#"{"verb":"inspect","params":{}}"#
        );

        fs::write(root.join(".tightbeam-session"), "{").unwrap();
        let error = discover_with(|_| None, &nested, &root).unwrap_err();
        assert!(error.contains(&root.join(".tightbeam-session").display().to_string()));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn run_without_session_file_requires_identity_before_network() {
        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "tbc_test".to_owned(),
            session_file: false,
        };
        let error = run_with(
            Command::List {
                identity: Identity::Omitted,
            },
            || Ok(endpoint),
            |_, _| panic!("network sender must not be called"),
        )
        .unwrap_err();

        assert_eq!(
            error,
            "identity required: pass --as <your-agent-handle> (when an agent runs this) or --as-user <userId> (operator action). This is WHO the call is from, not the target. Run 'tightbeam help'."
        );
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
