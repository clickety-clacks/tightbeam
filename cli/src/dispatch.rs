use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::args::{Command, Identity, Target, ToplineSelection};

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
    pub session_file: Option<PathBuf>,
}

fn quoted(value: &str) -> String {
    serde_json::to_string(value).expect("strings are always JSON serializable")
}

fn identity_field(identity: &Identity) -> Option<String> {
    match identity {
        Identity::Role(value) => Some(format!("\"as\":{}", quoted(value))),
        Identity::User(value) => Some(format!("\"asUser\":{}", quoted(value))),
        Identity::Process(value) => Some(format!("\"asProcess\":{}", quoted(value))),
        Identity::Session => None,
    }
}

fn object(fields: Vec<String>) -> String {
    format!("{{{}}}", fields.join(","))
}

fn string_field(name: &str, value: &str) -> String {
    format!("\"{name}\":{}", quoted(value))
}

/// Roster filters, shared verbatim by `toplines` and `topline --under` — the
/// spec says "the same roster filters", so there is one builder, not two lists.
fn filter_params(filters: &crate::args::ToplineFilters) -> Vec<String> {
    let mut params = Vec::new();
    for (name, value) in [
        ("origin", &filters.origin),
        ("owner", &filters.owner),
        ("state", &filters.state),
        ("spec", &filters.spec),
        ("specSha", &filters.spec_sha),
        ("session", &filters.session),
    ] {
        if let Some(value) = value {
            params.push(string_field(name, value));
        }
    }
    if let Some(ms) = &filters.quiet_over_ms {
        params.push(format!("\"quietOver\":{ms}"));
    }
    params
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
    let mut body = identity_field(identity).into_iter().collect::<Vec<_>>();
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
        | Command::CommandHelp(_)
        | Command::Doctor { .. }
        | Command::Assimilate(_) => {
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
        // Not a verb and not on /agent/dispatch: it changes no domain state, it
        // tells the gateway to look at this session's running turn NOW, while the
        // command it observed has not run yet.
        Command::ToolCallObserved => Ok(RequestSpec {
            path: "/agent/tool-call-observed",
            headers_sans_token_value: [
                ("authorization", "Bearer <token>"),
                ("content-type", "application/json"),
            ],
            body_json: "{}".to_owned(),
        }),
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
            workdir_root,
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
            if let Some(value) = workdir_root {
                params.push(string_field("workdirRoot", value));
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
        Command::EffortRule {
            identity,
            request_id,
            action,
        } => Ok(request(
            identity,
            "effort-rule",
            vec![],
            vec![
                string_field("request", request_id),
                string_field("action", action),
            ],
        )),
        Command::DecisionRequests { identity, status } => {
            let mut params = Vec::new();
            if let Some(value) = status {
                params.push(string_field("status", value));
            }
            Ok(request(identity, "decision-requests", vec![], params))
        }
        Command::RevokeAssignment {
            identity,
            assignment_id,
        } => Ok(request(
            identity,
            "revoke-assignment",
            vec![],
            vec![string_field("assignmentId", assignment_id)],
        )),
        Command::WorkItemCreate {
            identity,
            title,
            spec_ref_name,
            spec_ref_sha256,
            idempotency_key,
        } => {
            let mut params = vec![string_field("title", title)];
            if let Some(value) = spec_ref_name {
                params.push(string_field("specRefName", value));
            }
            if let Some(value) = spec_ref_sha256 {
                params.push(string_field("specRefSha256", value));
            }
            if let Some(value) = idempotency_key {
                params.push(string_field("idempotencyKey", value));
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
        Command::WorkItemTrace {
            identity,
            work_item_id,
        } => Ok(request(
            identity,
            "work-item-trace",
            vec![],
            vec![string_field("workItemId", work_item_id)],
        )),
        Command::Attend { identity, high } => {
            // The tier only; the turn is the caller's running turn, which the
            // substrate derives — the CLI never names a turn.
            let params = if *high {
                vec!["\"high\":true".to_owned()]
            } else {
                vec![]
            };
            Ok(request(identity, "attend", vec![], params))
        }
        Command::Transcript {
            identity,
            session,
            name,
            before,
            after,
            limit,
        } => {
            // The retrieval key travels as an ordinary body PARAM, never as a
            // top-level typed target: transcript is declared non-target at the
            // router, which refuses any top-level targeting field.
            let mut params = Vec::new();
            if let Some(session) = session {
                params.push(string_field("sessionKey", session));
            }
            if let Some(name) = name {
                params.push(string_field("name", name));
            }
            if let Some(before) = before {
                params.push(string_field("before", before));
            }
            if let Some(after) = after {
                params.push(string_field("after", after));
            }
            if let Some(limit) = limit {
                params.push(format!("\"limit\":{limit}"));
            }
            Ok(request(identity, "transcript", vec![], params))
        }
        Command::Toplines {
            identity,
            filters,
            tree,
        } => {
            let mut params = filter_params(filters);
            if *tree {
                params.push("\"tree\":true".to_owned());
            }
            Ok(request(identity, "toplines", vec![], params))
        }
        // Every selector travels as an ordinary body PARAM: both verbs are declared
        // non-target at the router, and --session is a COHORT FILTER over creator
        // identity, not a target to resolve.
        //
        // The two arms are separate because assignment selection has NO filters to
        // send — `filter_params` is unreachable from it, so nothing can leak a
        // filter the reader would then ignore.
        Command::Topline {
            identity,
            selection:
                ToplineSelection::Under {
                    work_item_id,
                    filters,
                },
        } => {
            let mut params = filter_params(filters);
            params.push(string_field("under", work_item_id));
            Ok(request(identity, "topline", vec![], params))
        }
        Command::Topline {
            identity,
            selection: ToplineSelection::Assignments(ids),
        } => {
            let list = ids
                .iter()
                .map(|id| serde_json::Value::String(id.clone()))
                .collect::<Vec<_>>();

            Ok(request(
                identity,
                "topline",
                vec![],
                vec![format!(
                    "\"assignments\":{}",
                    serde_json::Value::Array(list)
                )],
            ))
        }
        Command::WorkItemIcebox {
            identity,
            work_item_id,
        } => Ok(request(
            identity,
            "work-item-icebox",
            vec![],
            vec![string_field("workItemId", work_item_id)],
        )),
        Command::WorkItemReopen {
            identity,
            work_item_id,
        } => Ok(request(
            identity,
            "work-item-reopen",
            vec![],
            vec![string_field("workItemId", work_item_id)],
        )),
        Command::WorkItemClose {
            identity,
            work_item_id,
        } => Ok(request(
            identity,
            "work-item-close",
            vec![],
            vec![string_field("workItemId", work_item_id)],
        )),
        Command::WorkItemFail {
            identity,
            work_item_id,
            reason,
        } => {
            let mut params = vec![string_field("workItemId", work_item_id)];
            if let Some(value) = reason {
                params.push(string_field("reason", value));
            }
            Ok(request(identity, "work-item-fail", vec![], params))
        }
        Command::Attest {
            identity,
            assignment_id,
            kind,
            verdict,
            note,
            commit_refs,
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
            if let Some(value) = commit_refs {
                params.push(format!(
                    "\"commitRefs\":{}",
                    serde_json::to_string(value).expect("commit refs are JSON serializable")
                ));
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
        Command::IdentityEdit {
            identity,
            archetype,
            manifest,
            skill,
            remove,
            content,
        } => {
            let mut params = vec![
                string_field("archetype", archetype),
                format!("\"manifest\":{manifest}"),
                format!("\"remove\":{remove}"),
            ];
            if let Some(value) = skill {
                params.push(string_field("skill", value));
            }
            if let Some(value) = content {
                params.push(string_field("content", value));
            }
            Ok(request(identity, "identity-edit", vec![], params))
        }
        Command::IdentityStatus {
            identity,
            archetype,
        } => Ok(request(
            identity,
            "identity-status",
            vec![],
            archetype
                .as_ref()
                .map(|value| vec![string_field("archetype", value)])
                .unwrap_or_default(),
        )),
        Command::IdentityRelearn { identity, action } => Ok(request(
            identity,
            "identity-relearn",
            vec![],
            action
                .as_ref()
                .map(|value| vec![string_field("action", value)])
                .unwrap_or_default(),
        )),
        Command::IdentityApply {
            identity,
            session_key,
            all,
        } => {
            let mut params = vec![format!("\"all\":{all}")];
            if let Some(value) = session_key {
                params.push(string_field("sessionKey", value));
            }
            Ok(request(identity, "identity-apply", vec![], params))
        }
        Command::Onboard {
            identity, provider, ..
        } => Ok(request(
            identity,
            "onboard",
            vec![],
            vec![string_field("provider", provider)],
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

pub fn build_onboard_phase_request(
    identity: &Identity,
    provider: &str,
    phase: &str,
    kind: &str,
    machine: Option<&str>,
    reason: Option<&str>,
) -> RequestSpec {
    // `kind` rides on EVERY phase, not just finish, so the conversation is
    // self-describing in a gateway log. Only finish acts on it.
    let mut params = vec![
        string_field("provider", provider),
        string_field("phase", phase),
        string_field("kind", kind),
    ];
    if let Some(machine) = machine {
        params.push(string_field("machine", machine));
    }
    if let Some(reason) = reason {
        params.push(string_field("reason", reason));
    }
    request(identity, "onboard", vec![], params)
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

pub fn discover_from(base_dir: &Path) -> Result<Endpoint, String> {
    endpoint_from_gateway_file(&base_dir.join("gateway.json"))
}

// One resolver, shared with the gateway. This read TIGHTBEAM_HOME alone, so with
// TIGHTBEAM_BASE_DIR set -- the variable the README documents and both service
// units set -- discovery looked for gateway.json in a DIFFERENT org than the one
// the service booted, and found whatever happened to be at the default path.
fn gateway_config_path<F>(get_env: &F, home_dir: &Path) -> PathBuf
where
    F: Fn(&str) -> Option<String>,
{
    crate::base_dir::resolve_with(get_env, home_dir).join("gateway.json")
}

fn discover_with<F>(get_env: F, cwd: &Path, home_dir: &Path) -> Result<Endpoint, String>
where
    F: Fn(&str) -> Option<String>,
{
    if let Some(endpoint) = discover_session_from(cwd)? {
        return Ok(endpoint);
    }

    let url = get_env("TIGHTBEAM_URL").filter(|value| !value.is_empty());
    let token = get_env("TIGHTBEAM_TOKEN").filter(|value| !value.is_empty());
    if let (Some(base), Some(token)) = (url, token) {
        return Ok(Endpoint {
            base,
            token,
            session_file: None,
        });
    }

    let path = gateway_config_path(&get_env, home_dir);
    endpoint_from_gateway_file(&path)
}

fn discover_session_from(cwd: &Path) -> Result<Option<Endpoint>, String> {
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
        return Ok(Some(Endpoint {
            base: base.to_owned(),
            token: token.to_owned(),
            session_file: Some(path),
        }));
    }

    Ok(None)
}

/// The advertised url names the WEBSOCKET wire; this base roots an HTTP path.
///
/// A gateway writes what it advertises to clients (`ws://host:port`), which is the
/// right answer for the wire and the wrong scheme for `/agent/dispatch` -- the http
/// client refuses it outright rather than treating it as http. Same host, same port,
/// same server; only the scheme differs, so the scheme is all this changes.
fn http_scheme(url: &str) -> String {
    match url.split_once("://") {
        Some(("ws", rest)) => format!("http://{rest}"),
        Some(("wss", rest)) => format!("https://{rest}"),
        _ => url.to_owned(),
    }
}

fn endpoint_from_gateway_file(path: &Path) -> Result<Endpoint, String> {
    let encoded = fs::read_to_string(path).map_err(|error| {
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
    let token = config
        .get("cliToken")
        .and_then(Value::as_str)
        .unwrap_or("undefined")
        .to_owned();
    // A SATELLITE's file names the gateway's advertised url, because the gateway
    // is somewhere else; the gateway host's own file carries a port, and 127.0.0.1
    // is correct there and nowhere else. The gateway writes both (Placement) and
    // only ever writes one of the two shapes per machine.
    let base = match config.get("url").and_then(Value::as_str) {
        Some(url) if !url.is_empty() => http_scheme(url),
        _ => {
            let port = config
                .get("port")
                .map(Value::to_string)
                .unwrap_or_else(|| "undefined".to_owned());
            format!("http://127.0.0.1:{port}")
        }
    };
    Ok(Endpoint {
        base,
        token,
        session_file: None,
    })
}

/// What a machine's provisioned `gateway.json` says about the MACHINE ITSELF.
///
/// Deliberately separate from `Endpoint`, which answers a different question: where to
/// send a request. An operator ceremony acts on the machine it is running on, and on a
/// satellite the two answers differ -- the endpoint points at the gateway, while the
/// ceremony must name the satellite.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Provisioned {
    /// A satellite's file. It names the gateway's advertised url, and carries this
    /// host's REGISTERED name unless an older gateway wrote it (`Placement.write_endpoint`
    /// has included `machine` since 4dd0d39; a gateway restart rewrites every host's).
    Satellite { machine: Option<String> },
    /// The gateway host's own file: a port, and no machine. The gateway defaults an
    /// unnamed onboarding machine to its own hostname, which is correct exactly here.
    GatewayHost,
    /// No provisioned file, so this machine cannot say what it is registered as.
    Absent,
}

/// Read the provisioning of the machine this process is running on.
pub fn provisioned() -> Provisioned {
    provisioned_in(&crate::base_dir::resolve())
}

fn provisioned_in(base_dir: &Path) -> Provisioned {
    let Ok(encoded) = fs::read_to_string(base_dir.join("gateway.json")) else {
        return Provisioned::Absent;
    };
    let Ok(config) = serde_json::from_str::<Value>(&encoded) else {
        return Provisioned::Absent;
    };
    let text = |key: &str| {
        config
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    // The url/port split is the same one `endpoint_from_gateway_file` reads, and for the
    // same reason: only a satellite's file names a url.
    match text("url") {
        Some(_) => Provisioned::Satellite {
            machine: text("machine"),
        },
        None => Provisioned::GatewayHost,
    }
}

pub fn send(request: &RequestSpec) -> Result<Option<Value>, String> {
    let endpoint = discover()?;
    send_to(&endpoint, request)
}

pub(crate) fn send_to(endpoint: &Endpoint, request: &RequestSpec) -> Result<Option<Value>, String> {
    send_to_with_deadline(endpoint, request, None)
}

pub(crate) fn send_to_with_deadline(
    endpoint: &Endpoint,
    request: &RequestSpec,
    deadline: Option<Instant>,
) -> Result<Option<Value>, String> {
    if let Some(deadline) = deadline {
        let endpoint = endpoint.clone();
        let request = request.clone();
        return crate::lease::until(deadline, move |remaining| {
            send_to_with_timeout(&endpoint, &request, Some(remaining))
        })
        .map_err(|()| ceremony_expired())?;
    }

    send_to_with_timeout(endpoint, request, None)
}

fn send_to_with_timeout(
    endpoint: &Endpoint,
    request: &RequestSpec,
    timeout: Option<Duration>,
) -> Result<Option<Value>, String> {
    let url = format!("{}{}", endpoint.base, request.path);
    let mut builder = ureq::AgentBuilder::new();
    if let Some(timeout) = timeout {
        builder = builder.timeout(timeout).timeout_connect(timeout);
    }
    let call = builder
        .build()
        .post(&url)
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

fn ceremony_expired() -> String {
    "gateway request refused because the onboarding lease expired".to_owned()
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

    // The third outcome (202). It is not a result: the verb HALTED and its
    // decision-request is open, so returning Ok here would exit 0 and tell an
    // agent the action happened. It is not the error envelope either, so it
    // needs its own branch or it falls through to `result` -- absent -- and
    // becomes a silent success. Rendered like a refusal because that is what
    // the caller must do about it: the action did not take effect.
    if let Some(pending) = json.get("decisionPending") {
        let id = pending
            .get("decisionRequestId")
            .and_then(Value::as_str)
            .unwrap_or("undefined");
        let message = pending
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("this action needs an owner decision");
        return Err(format!("decision_pending: {message} ({id})"));
    }

    Ok(json.get("result").cloned())
}

pub fn run(command: Command) -> Result<(), String> {
    // `tool-call-observed` carries no identity flag, so it is not in
    // `command_identity`; it is nonetheless a session call and only a session
    // call, and saying so here makes a run from outside a workdir fail with the
    // reason rather than with a 403 from the org token.
    let session_identity = matches!(command, Command::ToolCallObserved)
        || command_identity(&command).is_some_and(|identity| matches!(identity, Identity::Session));
    run_with(
        command,
        move || {
            if session_identity {
                let cwd = std::env::current_dir().map_err(|error| error.to_string())?;
                discover_session_from(&cwd)?.ok_or_else(|| identity_required(&cwd))
            } else {
                discover()
            }
        },
        send_to_with_deadline,
        crate::harnesses::load_optional_from,
    )
}

fn run_with<D, S, H>(
    command: Command,
    discover_endpoint: D,
    send_request: S,
    load_harnesses: H,
) -> Result<(), String>
where
    D: FnOnce() -> Result<Endpoint, String>,
    S: Fn(&Endpoint, &RequestSpec, Option<Instant>) -> Result<Option<Value>, String>,
    H: Fn(&Endpoint, Instant) -> Result<Option<crate::harnesses::HarnessCatalog>, String>,
{
    match command {
        Command::Help | Command::CommandHelp(_) => {
            unreachable!("help is handled before dispatch")
        }
        Command::Doctor { json, base_dir } => crate::probe::run(json, base_dir),
        Command::Assimilate(args) => crate::ceremonies::assimilate(args),
        Command::Onboard {
            identity,
            provider,
            api_key,
        } => {
            let endpoint = discover_endpoint()?;
            require_session_endpoint(&identity, &endpoint)?;
            crate::ceremonies::onboard(
                &identity,
                &provider,
                api_key,
                &endpoint,
                send_request,
                load_harnesses,
            )
        }
        command => {
            let endpoint = discover_endpoint()?;
            if let Some(identity) = command_identity(&command) {
                require_session_endpoint(identity, &endpoint)?;
            }
            let request = build_request(&command)?;
            if let Some(result) = send_request(&endpoint, &request, None)? {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&result).expect("JSON value serializes")
                );
            }
            Ok(())
        }
    }
}

fn require_session_endpoint(identity: &Identity, endpoint: &Endpoint) -> Result<(), String> {
    if matches!(identity, Identity::Session) && endpoint.session_file.is_none() {
        let cwd = std::env::current_dir().map_err(|error| error.to_string())?;
        return Err(identity_required(&cwd));
    }
    Ok(())
}

fn identity_required(cwd: &Path) -> String {
    format!(
        "identity required: no explicit --as, --as-user, or --as-process flag was passed, and no .tightbeam-session was found walking up from '{}' to the filesystem root. Pass --as <your-agent-handle> (agent action) or --as-user <userId> (operator action). This is WHO the call is from, not the target. Run 'tightbeam help'.",
        cwd.display()
    )
}

fn command_identity(command: &Command) -> Option<&Identity> {
    match command {
        Command::Wake { identity, .. }
        | Command::ArtifactRecord { identity, .. }
        | Command::Artifacts { identity, .. }
        | Command::Spawn { identity, .. }
        | Command::List { identity }
        | Command::Retire { identity, .. }
        | Command::Assign { identity, .. }
        | Command::Dispatch { identity, .. }
        | Command::EffortRule { identity, .. }
        | Command::DecisionRequests { identity, .. }
        | Command::RevokeAssignment { identity, .. }
        | Command::WorkItemCreate { identity, .. }
        | Command::WorkItemGet { identity, .. }
        | Command::WorkItemTrace { identity, .. }
        | Command::Attend { identity, .. }
        | Command::Transcript { identity, .. }
        | Command::Toplines { identity, .. }
        | Command::Topline { identity, .. }
        | Command::WorkItemIcebox { identity, .. }
        | Command::WorkItemReopen { identity, .. }
        | Command::WorkItemClose { identity, .. }
        | Command::WorkItemFail { identity, .. }
        | Command::Attest { identity, .. }
        | Command::Attests { identity, .. }
        | Command::Assignments { identity, .. }
        | Command::CancelWake { identity, .. }
        | Command::IdentityEdit { identity, .. }
        | Command::IdentityStatus { identity, .. }
        | Command::IdentityRelearn { identity, .. }
        | Command::IdentityApply { identity, .. }
        | Command::Onboard { identity, .. }
        | Command::ConfigGet { identity, .. }
        | Command::ConfigSet { identity, .. } => Some(identity),
        Command::Help
        | Command::CommandHelp(_)
        | Command::Doctor { .. }
        | Command::ToolCallObserved
        | Command::Assimilate(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args;
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
    }

    #[test]
    fn builds_byte_exact_spawn_and_identity_edit_bodies() {
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
        let command = Command::IdentityEdit {
            identity: Identity::User("flynn".to_owned()),
            archetype: "coder".to_owned(),
            manifest: false,
            skill: Some("swift".to_owned()),
            remove: false,
            content: Some("line one\nline two".to_owned()),
        };
        assert_eq!(
            build_request(&command).unwrap().body_json,
            r#"{"asUser":"flynn","verb":"identity-edit","params":{"archetype":"coder","manifest":false,"remove":false,"skill":"swift","content":"line one\nline two"}}"#
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
                "--workdir-root",
                "checkout",
                "--key",
                "idem",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"dispatch","sessionKey":"agent:builder","params":{"subject":"ship","brief":"Please ship it.","workItemId":"wi_1","workdirRoot":"checkout","idempotencyKey":"idem"}}"#
        );
        assert_eq!(
            body(&[
                "effort-rule",
                "--request",
                "dr_1",
                "--action",
                "continue",
                "--as",
                "parent",
            ]),
            r#"{"as":"parent","verb":"effort-rule","params":{"request":"dr_1","action":"continue"}}"#
        );
        assert_eq!(
            body(&["decision-requests", "--status", "open", "--as", "parent"]),
            r#"{"as":"parent","verb":"decision-requests","params":{"status":"open"}}"#
        );
        assert_eq!(
            body(&["revoke-assignment", "asg_1", "--as", "parent",]),
            r#"{"as":"parent","verb":"revoke-assignment","params":{"assignmentId":"asg_1"}}"#
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
                "verified",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"attest","params":{"assignmentId":"asg_1","kind":"verdict","verdictKind":"verified"}}"#
        );
        assert_eq!(
            body(&["attests", "asg_1", "--as", "reviewer"]),
            r#"{"as":"reviewer","verb":"attests","params":{"assignmentId":"asg_1"}}"#
        );
        assert_eq!(
            body(&[
                "attest",
                "asg_1",
                "--kind",
                "completion",
                "--commit-refs",
                r#"[{"repo":"eezo:/src/repo","commit":"abc123"}]"#,
                "--as",
                "builder",
            ]),
            r#"{"as":"builder","verb":"attest","params":{"assignmentId":"asg_1","kind":"completion","commitRefs":[{"commit":"abc123","repo":"eezo:/src/repo"}]}}"#
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
        assert_eq!(
            body(&["work-item-trace", "wi_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-trace","params":{"workItemId":"wi_1"}}"#
        );
        assert_eq!(
            body(&[
                "work-item-create",
                "--title",
                "Ship",
                "--key",
                "k1",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"work-item-create","params":{"title":"Ship","idempotencyKey":"k1"}}"#
        );
        assert_eq!(
            body(&["work-item-icebox", "wi_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-icebox","params":{"workItemId":"wi_1"}}"#
        );
        assert_eq!(
            body(&["work-item-reopen", "wi_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-reopen","params":{"workItemId":"wi_1"}}"#
        );
        assert_eq!(
            body(&["work-item-close", "wi_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-close","params":{"workItemId":"wi_1"}}"#
        );
        assert_eq!(
            body(&[
                "work-item-fail",
                "wi_1",
                "--reason",
                "cannot repro",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"work-item-fail","params":{"workItemId":"wi_1","reason":"cannot repro"}}"#
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
    fn onboarding_phase_names_the_machine_without_transporting_credentials() {
        let request = build_onboard_phase_request(
            &Identity::User("flynn".to_owned()),
            "openai",
            "begin",
            "subscription",
            Some("work-1"),
            None,
        );

        assert_eq!(
            request.body_json,
            r#"{"asUser":"flynn","verb":"onboard","params":{"provider":"openai","phase":"begin","kind":"subscription","machine":"work-1"}}"#
        );
        assert!(!request.body_json.contains("auth.json"));
        assert!(!request.body_json.contains("token"));

        // The api-key ceremony's conversation carries the KIND and nothing else
        // new. The key itself is staged on the host being onboarded and never
        // crosses the wire, exactly as the subscription credential never does.
        let keyed = build_onboard_phase_request(
            &Identity::User("flynn".to_owned()),
            "anthropic",
            "finish",
            "apiKey",
            Some("work-1"),
            None,
        );

        assert_eq!(
            keyed.body_json,
            r#"{"asUser":"flynn","verb":"onboard","params":{"provider":"anthropic","phase":"finish","kind":"apiKey","machine":"work-1"}}"#
        );
        assert!(!keyed.body_json.contains("sk-"));
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
                &["identity", "status", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"identity-status","params":{}}"#,
            ),
            (
                &["identity", "apply", "agent:coder:app", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"identity-apply","params":{"all":false,"sessionKey":"agent:coder:app"}}"#,
            ),
        ] {
            assert_eq!(body(args), expected);
        }
    }

    #[test]
    fn discovery_prefers_complete_env_then_base_dir_then_tightbeam_home_then_home() {
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

        assert_eq!(
            discover_from(&configured),
            Ok(Endpoint {
                base: "http://127.0.0.1:4321".to_owned(),
                token: "configured".to_owned(),
                session_file: None,
            })
        );

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
                session_file: None,
            })
        );

        for incomplete in [
            HashMap::from([
                ("TIGHTBEAM_URL".to_owned(), "https://incomplete".to_owned()),
                (
                    "TIGHTBEAM_HOME".to_owned(),
                    configured.display().to_string(),
                ),
            ]),
            HashMap::from([
                ("TIGHTBEAM_TOKEN".to_owned(), "incomplete".to_owned()),
                (
                    "TIGHTBEAM_HOME".to_owned(),
                    configured.display().to_string(),
                ),
            ]),
        ] {
            assert_eq!(
                discover_with(|name| incomplete.get(name).cloned(), &root, &root),
                Ok(Endpoint {
                    base: "http://127.0.0.1:4321".to_owned(),
                    token: "configured".to_owned(),
                    session_file: None,
                })
            );
        }

        let env = HashMap::from([(
            "TIGHTBEAM_HOME".to_owned(),
            configured.display().to_string(),
        )]);
        assert_eq!(
            discover_with(|name| env.get(name).cloned(), &root, &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:4321".to_owned(),
                token: "configured".to_owned(),
                session_file: None,
            })
        );

        // The shrdlu failure, as a test: with TIGHTBEAM_BASE_DIR naming the org --
        // the variable the README documents and both service units set -- discovery
        // must read THAT gateway.json. It read ~/.tightbeam's instead, so `tightbeam
        // onboard` dialled a pre-existing org's port while its own gateway served
        // elsewhere. Both variables set, disagreeing, is the case that matters:
        // BASE_DIR wins, exactly as Tightbeam.BaseDir resolves it.
        let env = HashMap::from([
            (
                "TIGHTBEAM_BASE_DIR".to_owned(),
                configured.display().to_string(),
            ),
            ("TIGHTBEAM_HOME".to_owned(), default.display().to_string()),
        ]);
        assert_eq!(
            discover_with(|name| env.get(name).cloned(), &root, &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:4321".to_owned(),
                token: "configured".to_owned(),
                session_file: None,
            })
        );

        assert_eq!(
            discover_with(|_| None, &root, &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:9876".to_owned(),
                token: "default".to_owned(),
                session_file: None,
            })
        );
        let env = HashMap::from([("TIGHTBEAM_HOME".to_owned(), String::new())]);
        assert_eq!(
            gateway_config_path(&|name| env.get(name).cloned(), &root),
            PathBuf::from("gateway.json")
        );
        fs::remove_dir_all(root).unwrap();
    }

    // A satellite's gateway.json names a URL, because the gateway is not on that
    // machine. The gateway host's own file carries a port and nothing else, and
    // 127.0.0.1 is right there and only there. A freshly assimilated satellite had
    // no endpoint at all: `tightbeam onboard` on it died with ENOENT on
    // gateway.json, and copying the gateway's file over would have pointed the
    // satellite's operator at the satellite's own localhost.
    #[test]
    fn a_satellite_gateway_file_names_its_url_and_the_gateway_host_keeps_the_port_form() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("tightbeam_cli_satellite_{unique}"));
        let satellite = root.join("satellite");
        let gateway = root.join("gateway");
        fs::create_dir_all(&satellite).unwrap();
        fs::create_dir_all(&gateway).unwrap();
        fs::write(
            satellite.join("gateway.json"),
            r#"{"url":"http://gateway.example:11373","cliToken":"tbc_org"}"#,
        )
        .unwrap();
        fs::write(
            gateway.join("gateway.json"),
            r#"{"port":11373,"cliToken":"tbc_org"}"#,
        )
        .unwrap();

        assert_eq!(
            discover_from(&satellite),
            Ok(Endpoint {
                base: "http://gateway.example:11373".to_owned(),
                token: "tbc_org".to_owned(),
                session_file: None,
            })
        );
        assert_eq!(
            discover_from(&gateway),
            Ok(Endpoint {
                base: "http://127.0.0.1:11373".to_owned(),
                token: "tbc_org".to_owned(),
                session_file: None,
            })
        );
        fs::remove_dir_all(root).unwrap();
    }

    // RECORDED REALITY, not a chosen fixture: `Placement.provision_endpoint` writes
    // TIGHTBEAM_ADVERTISED_URL verbatim, and that value is the WEBSOCKET url -- in
    // production, `ws://shrdlu:11373`. This base is the root of an HTTP path
    // (`/agent/dispatch`), and the http client rejects the scheme outright with
    // "Unknown Scheme: unknown scheme 'ws'", so every satellite ceremony died on the
    // one url a real gateway ever writes. The sibling fixtures above hardcode
    // `http://` and can never catch it: they encode an assumption production
    // violates. One host, one wire, two schemes -- the transport is the websocket's,
    // the dispatch path is HTTP's.
    #[test]
    fn a_satellite_url_written_as_a_websocket_scheme_dispatches_over_http() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("tightbeam_cli_ws_scheme_{unique}"));
        let cases = [
            (
                "ws",
                "ws://gateway.example:11373",
                "http://gateway.example:11373",
            ),
            (
                "wss",
                "wss://gateway.example:11373",
                "https://gateway.example:11373",
            ),
            // http and https are already the dispatch scheme and pass through whole.
            (
                "http",
                "http://gateway.example:11373",
                "http://gateway.example:11373",
            ),
            (
                "https",
                "https://gateway.example:11373",
                "https://gateway.example:11373",
            ),
        ];
        for (name, written, expected) in cases {
            let dir = root.join(name);
            fs::create_dir_all(&dir).unwrap();
            // The WHOLE shape a live gateway writes, `machine` included -- confirmed
            // reproduced on every provisioning pass, including a fresh re-assimilate.
            // A fixture that drops a field production always writes is a fixture that
            // can stop matching without anything failing.
            fs::write(
                dir.join("gateway.json"),
                format!(r#"{{"url":"{written}","cliToken":"tbc_org","machine":"work-1"}}"#),
            )
            .unwrap();

            assert_eq!(
                discover_from(&dir),
                Ok(Endpoint {
                    base: expected.to_owned(),
                    token: "tbc_org".to_owned(),
                    session_file: None,
                }),
                "{name}"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn discovery_walks_up_to_the_nearest_session_file_before_env_or_gateway() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("tightbeam_cli_session_{unique}"));
        let ancestor = root.join("ancestor");
        let cwd = ancestor.join("work").join("nested");
        let configured = root.join("configured");
        for directory in [&cwd, &configured] {
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

        let env = HashMap::from([
            ("TIGHTBEAM_URL".to_owned(), "https://env-gateway".to_owned()),
            ("TIGHTBEAM_TOKEN".to_owned(), "env-token".to_owned()),
            (
                "TIGHTBEAM_HOME".to_owned(),
                configured.display().to_string(),
            ),
        ]);
        assert_eq!(
            discover_with(|name| env.get(name).cloned(), &cwd, &root),
            Ok(Endpoint {
                base: "https://nearest-session".to_owned(),
                token: "nearest-token".to_owned(),
                session_file: Some(ancestor.join("work").join(".tightbeam-session")),
            })
        );

        fs::write(ancestor.join("work").join(".tightbeam-session"), "{").unwrap();
        let error = discover_with(|name| env.get(name).cloned(), &cwd, &root).unwrap_err();
        assert!(error.starts_with("malformed session file"));
        assert!(
            error.contains(
                &ancestor
                    .join("work")
                    .join(".tightbeam-session")
                    .display()
                    .to_string()
            )
        );

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bare_identity_builds_no_override_and_requires_a_session_file_before_network() {
        assert_eq!(body(&["list"]), r#"{"verb":"inspect","params":{}}"#);

        run_with(
            Command::List {
                identity: Identity::Session,
            },
            || {
                Ok(Endpoint {
                    base: "https://session-gateway".to_owned(),
                    token: "tbs_discovered".to_owned(),
                    session_file: Some(PathBuf::from("/work/.tightbeam-session")),
                })
            },
            |endpoint, request, deadline| {
                assert_eq!(deadline, None);
                assert_eq!(endpoint.token, "tbs_discovered");
                assert_eq!(request.body_json, r#"{"verb":"inspect","params":{}}"#);
                Ok(None)
            },
            |_, _| panic!("harness loader must not be called"),
        )
        .unwrap();

        let cwd = PathBuf::from("/tmp/tightbeam-no-session");
        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "tbc_test".to_owned(),
            session_file: None,
        };
        let error = run_with(
            Command::List {
                identity: Identity::Session,
            },
            || Ok(endpoint),
            |_, _, _| panic!("network sender must not be called"),
            |_, _| panic!("harness loader must not be called"),
        )
        .unwrap_err();

        assert_eq!(error, identity_required(&std::env::current_dir().unwrap()));
        assert!(identity_required(&cwd).contains(
            "no .tightbeam-session was found walking up from '/tmp/tightbeam-no-session' to the filesystem root"
        ));
    }

    #[test]
    fn onboarding_discovers_once_and_keeps_every_phase_on_that_endpoint() {
        use std::cell::{Cell, RefCell};

        let staging = std::env::temp_dir().join(format!(
            "tightbeam-onboard-endpoint-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = fs::remove_dir_all(&staging);
        fs::create_dir_all(&staging).unwrap();
        let prior_machine = std::env::var_os("TIGHTBEAM_MACHINE");
        unsafe {
            std::env::set_var("TIGHTBEAM_MACHINE", "fixture-machine");
        }

        let gateway = "https://one-gateway.test".to_owned();
        let discoveries = Cell::new(0);
        let calls = RefCell::new(Vec::new());
        let catalog_calls = RefCell::new(Vec::new());
        let result = run_with(
            Command::Onboard {
                identity: Identity::User("flynn".to_owned()),
                provider: "openai".to_owned(),
                api_key: false,
            },
            || {
                discoveries.set(discoveries.get() + 1);
                Ok(Endpoint {
                    base: gateway.clone(),
                    token: "tbc_one".to_owned(),
                    session_file: None,
                })
            },
            |endpoint, request, deadline| {
                let phase = if request.body_json.contains(r#""phase":"begin""#) {
                    "begin"
                } else if request.body_json.contains(r#""phase":"finish""#) {
                    "finish"
                } else {
                    panic!("unexpected onboarding request: {}", request.body_json);
                };
                calls
                    .borrow_mut()
                    .push((endpoint.base.clone(), phase, deadline.is_some()));
                if phase == "begin" {
                    Ok(Some(serde_json::json!({
                        "stagingPath": staging,
                        "leaseTtlMs": 60_000
                    })))
                } else {
                    Ok(None)
                }
            },
            |endpoint, deadline| {
                catalog_calls
                    .borrow_mut()
                    .push((endpoint.base.clone(), deadline));
                Ok(Some(crate::harnesses::HarnessCatalog {
                    harnesses: vec![crate::harnesses::HarnessProjection {
                        id: "codex".to_owned(),
                        wire_name: "codex".to_owned(),
                        install_package: "codex-acp".to_owned(),
                        cli_binary: "true".to_owned(),
                        process_markers: vec!["codex".to_owned()],
                    }],
                }))
            },
        );

        match prior_machine {
            Some(value) => unsafe { std::env::set_var("TIGHTBEAM_MACHINE", value) },
            None => unsafe { std::env::remove_var("TIGHTBEAM_MACHINE") },
        }
        let _ = fs::remove_dir_all(&staging);

        result.unwrap();
        assert_eq!(discoveries.get(), 1);
        let catalog_calls = catalog_calls.into_inner();
        assert_eq!(catalog_calls.len(), 1);
        assert_eq!(catalog_calls[0].0, gateway);
        assert_eq!(
            calls.into_inner(),
            vec![(gateway.clone(), "begin", false), (gateway, "finish", true),]
        );
    }

    #[test]
    fn an_expired_deadline_refuses_gateway_io_as_lease_expiry() {
        use std::time::{Duration, Instant};

        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "tbc_test".to_owned(),
            session_file: None,
        };
        let request = build_onboard_phase_request(
            &Identity::User("flynn".to_owned()),
            "openai",
            "finish",
            "subscription",
            Some("work-1"),
            None,
        );
        let error = send_to_with_deadline(
            &endpoint,
            &request,
            Some(Instant::now() - Duration::from_millis(1)),
        )
        .unwrap_err();

        assert!(error.contains("onboarding lease expired"), "{error}");
    }

    #[test]
    fn the_third_outcome_renders_named_and_keeps_the_other_two_intact() {
        // 202 + decisionPending: not a result, not an error. Without its own
        // branch it falls through to an absent "result" and becomes Ok(None) --
        // a silent exit 0 telling an agent the action happened.
        assert_eq!(
            parse_response(
                202,
                r#"{"decisionPending":{"decisionRequestId":"dr_7","code":"decision_pending","message":"this action needs an owner decision; request dr_7 is open"}}"#
            ),
            Err(
                "decision_pending: this action needs an owner decision; request dr_7 is open (dr_7)"
                    .to_owned()
            )
        );

        // A malformed pending envelope still names itself rather than vanishing.
        assert_eq!(
            parse_response(202, r#"{"decisionPending":{}}"#),
            Err("decision_pending: this action needs an owner decision (undefined)".to_owned())
        );

        // The two shapes that already worked are untouched.
        assert_eq!(
            parse_response(200, r#"{"result":{"id":"asg_1"}}"#),
            Ok(Some(serde_json::json!({"id": "asg_1"})))
        );
        assert_eq!(
            parse_response(403, r#"{"error":{"code":"denied","message":"no"}}"#),
            Err("denied: no".to_owned())
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

    #[test]
    fn provisioning_distinguishes_a_satellite_from_the_gateway_host_and_from_staleness() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("tightbeam_cli_provisioned_{unique}"));
        let cases = [
            (
                "satellite",
                r#"{"url":"http://gw:11373","cliToken":"t","machine":"work-1"}"#,
                Provisioned::Satellite {
                    machine: Some("work-1".to_owned()),
                },
            ),
            // Written by a gateway from before `machine` was included. The name is not
            // derivable here -- it is whatever `assimilate` registered -- so this must
            // stay distinguishable from the gateway host, which legitimately has none.
            (
                "stale_satellite",
                r#"{"url":"http://gw:11373","cliToken":"t"}"#,
                Provisioned::Satellite { machine: None },
            ),
            (
                "gateway_host",
                r#"{"port":11373,"cliToken":"t"}"#,
                Provisioned::GatewayHost,
            ),
        ];
        for (name, body, expected) in cases {
            let dir = root.join(name);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("gateway.json"), body).unwrap();
            assert_eq!(provisioned_in(&dir), expected, "{name}");
        }
        assert_eq!(
            provisioned_in(&root.join("nothing-here")),
            Provisioned::Absent
        );
        fs::remove_dir_all(root).unwrap();
    }
}
