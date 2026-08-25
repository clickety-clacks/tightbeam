use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::args::{Command, Identity, Target, ToplineSelection, TuneControl};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestSpec {
    pub path: &'static str,
    pub body_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub base: String,
    pub token: String,
    pub origin: Origin,
}

/// WHERE the endpoint came from, kept because it answers a question its VALUES cannot.
///
/// "Is this request aimed at the gateway running on this machine?" was answered by
/// comparing an endpoint's token to the local one -- so a deliberately remote `--url`
/// that happened to carry the same token was classified local, and an operator adding a
/// user to another org got a row inserted into this machine's database instead. Value
/// equality was never the question. An endpoint is local when it was RESOLVED from this
/// machine's own provisioning, and that is decided once, where the resolution happens,
/// and then carried rather than re-derived.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    /// A `.tightbeam-session` file found walking up from the working directory.
    Session(PathBuf),
    /// `TIGHTBEAM_URL` and `TIGHTBEAM_TOKEN` named a gateway outright. Explicit, and
    /// therefore never this machine's own affair even when the two coincide.
    Named,
    /// This machine's provisioned `gateway.json`.
    Provisioned,
}

impl Endpoint {
    /// The session file this endpoint came from, for the callers that report it.
    pub fn session_file(&self) -> Option<&Path> {
        match &self.origin {
            Origin::Session(path) => Some(path),
            _ => None,
        }
    }
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
        body_json: object(body),
    }
}

/// Build the dispatch request without performing discovery or network I/O.
pub fn build_request(command: &Command) -> Result<RequestSpec, String> {
    match command {
        Command::Help
        | Command::CommandHelp(_)
        | Command::Doctor { .. }
        | Command::GithubAuthCheck
        | Command::UpdateClients { .. }
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
            class,
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
                ("class", class),
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
            for (name, value) in [("scope", scope), ("idempotencyKey", idempotency_key)] {
                if let Some(value) = value {
                    params.push(string_field(name, value));
                }
            }
            Ok(request(identity, "condition", vec![], params))
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
            body_json: "{}".to_owned(),
        }),
        Command::Spawn {
            identity,
            display_name,
            idempotency_key,
            archetype,
            harness,
            model,
            effort,
            context,
            handle,
            host,
        } => {
            let mut params = vec![
                string_field("displayName", display_name),
                string_field("idempotencyKey", idempotency_key),
            ];
            // One pass, original field order. A model field NAMED but empty
            // crosses as JSON null; omitted stays omitted, because inheritance
            // on the far side depends on telling those apart. The other fields
            // have no meaningful empty value, so they lift into the same shape.
            for (name, value) in [
                ("archetype", archetype.clone().map(Some)),
                ("harness", harness.clone().map(Some)),
                ("model", model.clone()),
                ("effort", effort.clone()),
                ("context", context.clone()),
                ("handle", handle.clone().map(Some)),
                ("host", host.clone().map(Some)),
            ] {
                match value {
                    Some(Some(value)) => params.push(string_field(name, &value)),
                    Some(None) => params.push(format!("\"{name}\":null")),
                    None => {}
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
        Command::Tune {
            identity,
            session_key,
            control,
        } => {
            let params = match control {
                TuneControl::Harness {
                    harness,
                    model,
                    effort,
                    context,
                } => tune_model_params("set_harness", Some(harness), model, effort, context),
                TuneControl::Model {
                    model,
                    effort,
                    context,
                } => tune_model_params("set_model", None, model, effort, context),
                TuneControl::Effort(effort) => vec![
                    string_field("setting", "set_reasoning"),
                    string_field("reasoningLevel", effort),
                ],
                TuneControl::Fast(value) => vec![
                    string_field("setting", "set_fast_mode"),
                    string_field("fastMode", value),
                ],
            };
            Ok(request(
                identity,
                "tune",
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
            effect_kind,
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
            if let Some(value) = effect_kind {
                params.push(string_field("effectKind", value));
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
            effect_kind,
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
            if let Some(value) = effect_kind {
                params.push(string_field("effectKind", value));
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
        Command::OperatorAsk {
            identity,
            question,
            note,
            options,
            assignment_id,
            deadline_ms,
            supersedes,
        } => {
            let mut params = vec![string_field("question", question)];
            if let Some(value) = note {
                params.push(string_field("note", value));
            }
            if let Some(labels) = options {
                let options = labels
                    .iter()
                    .map(|label| serde_json::json!({"label": label}))
                    .collect::<Vec<_>>();
                params.push(format!(
                    "\"options\":{}",
                    serde_json::to_string(&options).expect("operator option labels serialize")
                ));
            }
            if let Some(value) = assignment_id {
                params.push(string_field("assignment", value));
            }
            if let Some(value) = deadline_ms {
                params.push(format!("\"deadline\":{value}"));
            }
            if let Some(value) = supersedes {
                params.push(string_field("supersedes", value));
            }
            Ok(request(identity, "operator-ask", vec![], params))
        }
        Command::OperatorRule {
            identity,
            request_id,
            decision,
            response,
            rationale,
        } => {
            let mut params = vec![string_field("request", request_id)];
            if let Some(value) = decision {
                params.push(string_field("decision", value));
            }
            if let Some(value) = response {
                params.push(string_field("response", value));
            }
            if let Some(value) = rationale {
                params.push(string_field("rationale", value));
            }
            Ok(request(identity, "operator-rule", vec![], params))
        }
        Command::OperatorWithdraw {
            identity,
            request_id,
            reason,
        } => Ok(request(
            identity,
            "operator-withdraw",
            vec![],
            vec![
                string_field("request", request_id),
                string_field("reason", reason),
            ],
        )),
        Command::DecisionRequests { identity, status } => {
            let mut params = Vec::new();
            if let Some(value) = status {
                params.push(string_field("status", value));
            }
            Ok(request(identity, "decision-requests", vec![], params))
        }
        Command::DecisionRequest {
            identity,
            request_id,
        } => Ok(request(
            identity,
            "decision-request",
            vec![],
            vec![string_field("request", request_id)],
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
        Command::WorkItemCreate {
            identity,
            title,
            spec_ref_name,
            spec_ref_sha256,
            priority,
            idempotency_key,
        } => {
            let mut params = vec![string_field("title", title)];
            if let Some(value) = spec_ref_name {
                params.push(string_field("specRefName", value));
            }
            if let Some(value) = spec_ref_sha256 {
                params.push(string_field("specRefSha256", value));
            }
            if let Some(value) = priority {
                params.push(format!("\"priority\":{value}"));
            }
            if let Some(value) = idempotency_key {
                params.push(string_field("idempotencyKey", value));
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
            priority,
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
            if let Some(value) = priority {
                params.push(format!("\"priority\":{value}"));
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
            // A surrender is the sole terminal operation a stale session may make.
            // Keep its wire shape apart from generic dispatch: that endpoint remains
            // release-gated, and this one must never accept an asserted identity or
            // ordinary attest fields.
            if kind == "surrender" {
                if !matches!(identity, Identity::Session) {
                    return Err(
                        "terminal surrender must use the session's implicit identity".to_owned(),
                    );
                }
                let note = note
                    .as_deref()
                    .ok_or_else(|| "--note is required when --kind is surrender".to_owned())?;
                if verdict.is_some() || commit_refs.is_some() {
                    return Err(
                        "terminal surrender accepts only --kind surrender and --note".to_owned(),
                    );
                }
                return Ok(RequestSpec {
                    path: "/agent/terminal",
                    body_json: object(vec![
                        string_field("assignmentId", assignment_id),
                        string_field("disposition", "surrender"),
                        string_field("note", note),
                    ]),
                });
            }
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
            idempotency_key,
            archetype,
            manifest,
            skill,
            remove,
            content,
        } => {
            let mut params = vec![
                string_field("idempotencyKey", idempotency_key),
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
        Command::IdentityRelearn {
            identity,
            idempotency_key,
            action,
        } => Ok(request(
            identity,
            "identity-relearn",
            vec![],
            std::iter::once(string_field("idempotencyKey", idempotency_key))
                .chain(action.as_ref().map(|value| string_field("action", value)))
                .collect(),
        )),
        Command::IdentityRepoint {
            identity,
            session_key,
            archetype,
        } => Ok(request(
            identity,
            "identity-repoint",
            vec![string_field("sessionKey", session_key)],
            vec![string_field("archetype", archetype)],
        )),
        Command::Learn {
            identity,
            idempotency_key,
            name,
        } => Ok(request(
            identity,
            "learn",
            vec![],
            vec![
                string_field("idempotencyKey", idempotency_key),
                string_field("name", name),
            ],
        )),
        Command::Unlearn {
            identity,
            idempotency_key,
            name,
        } => Ok(request(
            identity,
            "unlearn",
            vec![],
            vec![
                string_field("idempotencyKey", idempotency_key),
                string_field("name", name),
            ],
        )),
        Command::KungfuList { identity } => Ok(request(identity, "kungfu-list", vec![], vec![])),
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
        Command::AddUser {
            identity,
            user_id,
            admin,
        } => Ok(request(
            identity,
            "add-user",
            vec![],
            vec![
                string_field("userId", user_id),
                format!("\"isAdmin\":{admin}"),
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
        } => {
            let encoded_value = if setting == "default-priority" {
                format!("\"value\":{value}")
            } else {
                string_field("value", value)
            };
            Ok(request(
                identity,
                "config",
                vec![],
                vec![
                    string_field("action", "set"),
                    string_field("setting", setting),
                    encoded_value,
                ],
            ))
        }
        Command::HostEnvSet {
            identity,
            host,
            harness,
            name,
            value,
        } => Ok(request(
            identity,
            "host-env-set",
            vec![],
            vec![
                string_field("host", host),
                string_field("harness", harness),
                string_field("name", name),
                string_field("value", value),
            ],
        )),
        Command::HostEnvList {
            identity,
            host,
            harness,
        } => {
            let mut params = Vec::new();
            if let Some(value) = host {
                params.push(string_field("host", value));
            }
            if let Some(value) = harness {
                params.push(string_field("harness", value));
            }
            Ok(request(identity, "host-env-list", vec![], params))
        }
        Command::HostEnvUnset {
            identity,
            host,
            harness,
            name,
        } => Ok(request(
            identity,
            "host-env-unset",
            vec![],
            vec![
                string_field("host", host),
                string_field("harness", harness),
                string_field("name", name),
            ],
        )),
        Command::HostToolchainSet {
            identity,
            host,
            dirs,
        } => Ok(request(
            identity,
            "host-toolchain-set",
            vec![],
            vec![
                string_field("host", host),
                format!(
                    "\"dirs\":{}",
                    serde_json::to_string(dirs).expect("toolchain directories serialize")
                ),
            ],
        )),
        Command::HarnessProcesses { identity } => {
            Ok(request(identity, "harness-processes", vec![], vec![]))
        }
    }
}

pub fn build_onboard_phase_request(
    identity: &Identity,
    provider: &str,
    phase: &str,
    kind: &str,
    machine: Option<&str>,
    lease_id: Option<&str>,
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
    if let Some(lease_id) = lease_id {
        params.push(string_field("leaseId", lease_id));
    }
    if let Some(reason) = reason {
        params.push(string_field("reason", reason));
    }
    request(identity, "onboard", vec![], params)
}

/// Build a `wake --user <owner>` request carrying the onboarding sign-in prompt, so the
/// operator who cannot see the ceremony's terminal still receives the URL+code. The wake
/// row IS the durable record of the delivery (wi_0535922b) -- it persists in the substrate
/// with the code text, the target, and timestamps.
///
/// `userId` is a target field and `prompt` a param, exactly as `Command::Wake` builds them.
pub fn build_operator_wake_request(
    identity: &Identity,
    owner_user_id: &str,
    prompt: &str,
) -> RequestSpec {
    request(
        identity,
        "wake",
        vec![string_field("userId", owner_user_id)],
        vec![string_field("prompt", prompt)],
    )
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

pub fn build_update_clients_request(as_user: &str) -> RequestSpec {
    request(
        &Identity::User(as_user.to_owned()),
        "update-clients",
        vec![],
        vec![],
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
            origin: Origin::Named,
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
            // A satellite's session file carries the gateway's ADVERTISED (websocket)
            // url; this base roots an HTTP `/agent/dispatch`. Same normalization the
            // gateway.json reader applies (815d27e) -- the two readers of one url must
            // agree, and this one was missed.
            base: http_scheme(base),
            token: token.to_owned(),
            origin: Origin::Session(path),
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
        origin: Origin::Provisioned,
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
    let call = gateway_request("POST", endpoint, request.path, timeout)
        .set("content-type", "application/json")
        .send_string(&request.body_json);

    let (status, response) = match call {
        Ok(response) => (response.status(), response),
        Err(ureq::Error::Status(status, response)) => (status, response),
        Err(ureq::Error::Transport(error)) => return Err(error.to_string()),
    };
    let encoded = response.into_string().map_err(|error| error.to_string())?;
    if !(200..300).contains(&status) && request.body_json.contains(r#""verb":"tune""#) {
        return Err(tune_refusal_json(&encoded));
    }
    parse_response(status, &encoded)
}

fn tune_refusal_json(encoded: &str) -> String {
    let parsed: Value = match serde_json::from_str(encoded) {
        Ok(parsed) => parsed,
        Err(error) => return error.to_string(),
    };
    let error = parsed.get("error").unwrap_or(&parsed);
    let mut refusal = match error.as_object() {
        Some(fields) => fields.clone(),
        None => {
            return serde_json::to_string(&serde_json::json!({
                "ok": false,
                "code": "undefined",
                "message": ""
            }))
            .expect("JSON value serializes");
        }
    };
    refusal.insert("ok".to_owned(), Value::Bool(false));

    serde_json::to_string(&Value::Object(refusal)).expect("JSON value serializes")
}

pub(crate) fn gateway_request(
    method: &str,
    endpoint: &Endpoint,
    path: &str,
    timeout: Option<Duration>,
) -> ureq::Request {
    let mut builder = ureq::AgentBuilder::new();
    if let Some(timeout) = timeout {
        builder = builder.timeout(timeout).timeout_connect(timeout);
    }
    let request = builder
        .build()
        .request(method, &format!("{}{path}", endpoint.base))
        .set("authorization", &format!("Bearer {}", endpoint.token))
        .set("x-tightbeam-cli-version", env!("CARGO_PKG_VERSION"));
    if path == "/agent/terminal" {
        request.set("x-tightbeam-terminal-version", "1")
    } else {
        request
    }
}

/// LOAD-BEARING WORDING. This sentence is control flow, not just prose.
///
/// `ceremonies::cancel_after_begin` matches `contains("onboarding lease expired")` on
/// whatever a failed cancel dispatch returns, and this is the only thing that produces
/// that substring on that route. Reword it and the guard stops matching, falls through to
/// its `_` arm, and the cancel failure silently vanishes from the operator's message. No
/// test covers the transition, so nothing goes red.
///
/// The phrase is doing the job of an error code while looking like an error message.
/// Several sites across four modules produce it, tests in four modules assert on it (one
/// of them NEGATIVELY, that a message must not contain it), and this guard is the only
/// place it changes behaviour. Making it a real variant is a change worth doing and is not
/// this branch's to make.
///
/// Deliberately no count. The first version of this comment carried one, and it was wrong
/// before it reached review — restated from a message, never recounted against the file.
/// A tally in a comment is stale the moment someone adds a test; what a reader needs is
/// that exactly one site branches on it, and that survives.
fn ceremony_expired() -> String {
    "gateway request refused because the onboarding lease expired".to_owned()
}

pub(crate) fn parse_response(status: u16, encoded: &str) -> Result<Option<Value>, String> {
    let json: Value = serde_json::from_str(encoded).map_err(|error| error.to_string())?;

    if !(200..300).contains(&status) {
        let code = json
            .pointer("/error/code")
            .and_then(Value::as_str)
            .unwrap_or("undefined");
        let message = json.pointer("/error/message").and_then(Value::as_str);
        let request_id = json.pointer("/error/requestId").and_then(Value::as_str);
        let rendered = match message {
            Some(message) if !message.is_empty() => format!("{code}: {message}"),
            _ => code.to_owned(),
        };
        return Err(match request_id {
            Some(request_id) if !request_id.is_empty() => format!("{rendered} ({request_id})"),
            _ => rendered,
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
        Command::AddUser {
            identity,
            user_id,
            admin,
        } => {
            // Resolve the requested org before inspecting or mutating local state. An
            // explicit remote endpoint must not get a user inserted into whichever
            // empty state.db happens to exist on this machine.
            let endpoint = discover_endpoint()?;
            let first_user = first_user_for_target(add_user_target_is_local(&endpoint), || {
                crate::users::create_first_if_local(&user_id, admin)
            })?;
            match first_user {
                crate::users::FirstUser::Created {
                    user_id,
                    is_admin,
                    created_at,
                } => {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "user": {
                                "userId": user_id,
                                "isAdmin": is_admin,
                                "createdAt": created_at
                            }
                        }))
                        .expect("JSON value serializes")
                    );
                    Ok(())
                }
                crate::users::FirstUser::Dispatch => {
                    require_session_endpoint(&identity, &endpoint)?;
                    let request = request(
                        &identity,
                        "add-user",
                        vec![],
                        vec![
                            string_field("userId", &user_id),
                            format!("\"isAdmin\":{admin}"),
                        ],
                    );
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
        Command::UpdateClients { as_user } => crate::ceremonies::update_clients(&as_user),
        Command::Assimilate(args) => crate::ceremonies::assimilate(args),
        Command::GithubAuthCheck => crate::github_auth::check_tool_call_stdin(),
        Command::Onboard {
            identity,
            provider,
            api_key,
            hostname,
            remote,
        } => {
            if provider == "github" {
                return crate::github_auth::onboard(
                    hostname.as_deref().unwrap_or("github.com"),
                    remote.as_deref(),
                );
            }
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

fn add_user_target_is_local(endpoint: &Endpoint) -> bool {
    add_user_endpoint_matches_local(endpoint, &provisioned())
}

fn first_user_for_target<F>(local: bool, create: F) -> Result<crate::users::FirstUser, String>
where
    F: FnOnce() -> Result<crate::users::FirstUser, String>,
{
    if local {
        create()
    } else {
        Ok(crate::users::FirstUser::Dispatch)
    }
}

/// The one case that may create a user without asking a gateway: this machine IS the
/// gateway host, and the request resolved to it because nothing else was named.
///
/// Both halves are provenance, not comparison. `Origin::Named` and `Origin::Session` each
/// say an endpoint was chosen deliberately, and a deliberate choice is honoured as made
/// even when it resolves to the same address and the same token as the local gateway --
/// which is precisely the case that used to fall through to a local mutation.
fn add_user_endpoint_matches_local(endpoint: &Endpoint, provisioned: &Provisioned) -> bool {
    matches!(provisioned, Provisioned::GatewayHost)
        && matches!(endpoint.origin, Origin::Provisioned)
}

fn require_session_endpoint(identity: &Identity, endpoint: &Endpoint) -> Result<(), String> {
    if matches!(identity, Identity::Session) && endpoint.session_file().is_none() {
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
        | Command::Condition { identity, .. }
        | Command::ArtifactRecord { identity, .. }
        | Command::Artifacts { identity, .. }
        | Command::Spawn { identity, .. }
        | Command::List { identity }
        | Command::Retire { identity, .. }
        | Command::Tune { identity, .. }
        | Command::Assign { identity, .. }
        | Command::Dispatch { identity, .. }
        | Command::EffortRule { identity, .. }
        | Command::OperatorAsk { identity, .. }
        | Command::OperatorRule { identity, .. }
        | Command::OperatorWithdraw { identity, .. }
        | Command::DecisionRequests { identity, .. }
        | Command::DecisionRequest { identity, .. }
        | Command::RevokeAssignment { identity, .. }
        | Command::WorkItemCreate { identity, .. }
        | Command::WorkItemUpdate { identity, .. }
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
        | Command::IdentityRepoint { identity, .. }
        | Command::Learn { identity, .. }
        | Command::Unlearn { identity, .. }
        | Command::KungfuList { identity }
        | Command::IdentityApply { identity, .. }
        | Command::Onboard { identity, .. }
        | Command::AddUser { identity, .. }
        | Command::ConfigGet { identity, .. }
        | Command::ConfigSet { identity, .. }
        | Command::HostEnvSet { identity, .. }
        | Command::HostEnvList { identity, .. }
        | Command::HostEnvUnset { identity, .. }
        | Command::HostToolchainSet { identity, .. }
        | Command::HarnessProcesses { identity } => Some(identity),
        Command::Help
        | Command::CommandHelp(_)
        | Command::Doctor { .. }
        | Command::ToolCallObserved
        | Command::GithubAuthCheck
        | Command::UpdateClients { .. }
        | Command::Assimilate(_) => None,
    }
}

fn tune_model_params(
    setting: &str,
    harness: Option<&String>,
    model: &String,
    effort: &Option<String>,
    context: &Option<String>,
) -> Vec<String> {
    let mut params = vec![
        string_field("setting", setting),
        string_field("model", model),
    ];
    if let Some(harness) = harness {
        params.push(string_field("harness", harness));
    }
    if let Some(effort) = effort {
        params.push(string_field("effort", effort));
    }
    if let Some(context) = context {
        params.push(string_field("context", context));
    }
    params
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
    fn builds_harness_process_list_request() {
        assert_eq!(
            body(&["harness-process", "list", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"harness-processes","params":{}}"#
        );
    }

    #[test]
    fn tune_refusals_remain_machine_readable_json() {
        assert_eq!(
            tune_refusal_json(r#"{"error":{"code":"same_harness","message":"omit --harness"}}"#),
            r#"{"code":"same_harness","message":"omit --harness","ok":false}"#
        );
    }

    #[test]
    fn tune_refusals_preserve_verified_runtime_and_cleanup_fields() {
        let refusal = tune_refusal_json(
            r#"{"error":{"code":"runtime_config_mismatch","message":"readback differed","model":"gpt-5.6-sol","effort":"high","projectionCommitted":false,"cleanupStatus":"unverified","lifecycleEventId":"le_123","warnings":["candidate close unverified"]}}"#,
        );

        assert_eq!(
            serde_json::from_str::<Value>(&refusal).unwrap(),
            serde_json::json!({
                "ok": false,
                "code": "runtime_config_mismatch",
                "message": "readback differed",
                "model": "gpt-5.6-sol",
                "effort": "high",
                "projectionCommitted": false,
                "cleanupStatus": "unverified",
                "lifecycleEventId": "le_123",
                "warnings": ["candidate close unverified"]
            })
        );
    }

    #[test]
    fn add_user_builds_the_ordinary_authenticated_gateway_request() {
        assert_eq!(
            body(&["add-user", "guest", "--admin", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"add-user","params":{"userId":"guest","isAdmin":true}}"#
        );
    }

    /// The case the value comparison could not see.
    ///
    /// `--url` naming a remote gateway that happens to share the local token -- one org's
    /// token deployed on two hosts, or a satellite pointed back at its own gateway -- was
    /// classified LOCAL and inserted a user into whatever `state.db` this machine had.
    /// The comparison that shipped could not distinguish it because there is nothing in
    /// the values to distinguish; the fixtures below share base AND token deliberately,
    /// so nothing here can pass by comparing them.
    #[test]
    fn an_explicit_remote_add_user_target_cannot_use_the_local_empty_org_exception() {
        let base = "http://127.0.0.1:11373".to_owned();
        let token = "tbc_local".to_owned();
        let provisioned = Endpoint {
            base: base.clone(),
            token: token.clone(),
            origin: Origin::Provisioned,
        };
        let named = Endpoint {
            base: base.clone(),
            token: token.clone(),
            origin: Origin::Named,
        };
        let session = Endpoint {
            base,
            token,
            origin: Origin::Session(PathBuf::from("/work/.tightbeam-session")),
        };

        assert!(add_user_endpoint_matches_local(
            &provisioned,
            &Provisioned::GatewayHost
        ));
        assert!(
            !add_user_endpoint_matches_local(&named, &Provisioned::GatewayHost),
            "an endpoint named on the command line is the operator's choice of target, \
             whatever it resolves to"
        );
        assert!(!add_user_endpoint_matches_local(
            &session,
            &Provisioned::GatewayHost
        ));
        assert!(!add_user_endpoint_matches_local(
            &provisioned,
            &Provisioned::Satellite {
                machine: Some("worker".to_owned())
            }
        ));
        assert_eq!(
            first_user_for_target(false, || panic!("remote target attempted local mutation")),
            Ok(crate::users::FirstUser::Dispatch)
        );
    }

    #[test]
    fn gateway_request_owns_authentication_and_cli_version_for_every_path() {
        let endpoint = Endpoint {
            base: "http://gateway.example:11373".to_owned(),
            token: "tbc_org".to_owned(),
            origin: Origin::Provisioned,
        };

        for (method, path, terminal_protocol) in [
            ("POST", "/agent/dispatch", false),
            ("POST", "/agent/tool-call-observed", false),
            ("POST", "/agent/terminal", true),
            ("GET", "/harnesses", false),
        ] {
            let request = gateway_request(method, &endpoint, path, None);
            assert_eq!(request.method(), method);
            assert_eq!(request.url(), format!("http://gateway.example:11373{path}"));
            assert_eq!(request.header("authorization"), Some("Bearer tbc_org"));
            assert_eq!(
                request.header("x-tightbeam-cli-version"),
                Some(env!("CARGO_PKG_VERSION"))
            );
            assert_eq!(
                request.header("x-tightbeam-terminal-version"),
                terminal_protocol.then_some("1")
            );
        }
    }

    #[test]
    fn terminal_surrender_has_its_own_fixed_request_shape() {
        let request = build_request(&parse(&[
            "attest",
            "asg_1",
            "--kind",
            "surrender",
            "--note",
            "incompatible client",
        ]))
        .unwrap();
        assert_eq!(request.path, "/agent/terminal");
        assert_eq!(
            request.body_json,
            r#"{"assignmentId":"asg_1","disposition":"surrender","note":"incompatible client"}"#
        );
        assert_eq!(
            build_request(&parse(&[
                "attest",
                "asg_1",
                "--kind",
                "surrender",
                "--note",
                "no",
                "--as",
                "coder",
            ])),
            Err("terminal surrender must use the session's implicit identity".to_owned())
        );
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
                "--key",
                "historically-ignored",
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
                "wake", "--role", "owner", "--prompt", "finished", "--class", "fyi", "--as",
                "coder",
            ]),
            r#"{"as":"coder","verb":"wake","role":"owner","params":{"prompt":"finished","class":"fyi"}}"#
        );
        assert_eq!(
            body(&[
                "wake",
                "--role",
                "owner",
                "--prompt",
                "extension",
                "--class",
                "kungfu:deploy-window",
                "--as",
                "coder",
            ]),
            r#"{"as":"coder","verb":"wake","role":"owner","params":{"prompt":"extension","class":"kungfu:deploy-window"}}"#
        );
        assert_eq!(
            args::parse(
                [
                    "wake", "--role", "owner", "--prompt", "go", "--class", "", "--as", "coder",
                ]
                .iter()
                .map(|value| (*value).to_owned())
                .collect()
            )
            .unwrap_err(),
            "--class requires a class name"
        );
    }

    #[test]
    fn builds_byte_exact_condition_wake_and_fact_bodies() {
        assert_eq!(
            body(&[
                "wake",
                "--role",
                "owner",
                "--when-fact",
                "build-finished",
                "--when-scope",
                "app",
                "--fallback-after",
                "2h",
                "--prompt",
                "re-read durable state",
                "--key",
                "wake-1",
                "--as-process",
                "ci",
            ]),
            r#"{"asProcess":"ci","verb":"wake","role":"owner","params":{"prompt":"re-read durable state","afterMs":7200000,"conditionKind":"build-finished","conditionScope":"app","idempotencyKey":"wake-1"}}"#
        );
        assert_eq!(
            body(&[
                "wake",
                "--session",
                "agent:owner",
                "--when-fact",
                "review-landed",
                "--at",
                "123",
                "--prompt",
                "decide what follows",
                "--as",
                "worker",
            ]),
            r#"{"as":"worker","verb":"wake","sessionKey":"agent:owner","params":{"prompt":"decide what follows","at":123,"conditionKind":"review-landed"}}"#
        );
        assert_eq!(
            body(&[
                "condition",
                "--kind",
                "build-finished",
                "--scope",
                "app",
                "--key",
                "fact-1",
                "--as-process",
                "ci",
            ]),
            r#"{"asProcess":"ci","verb":"condition","params":{"kind":"build-finished","scope":"app","idempotencyKey":"fact-1"}}"#
        );
        assert_eq!(
            body(&["condition", "--kind", "review-landed", "--as", "reviewer",]),
            r#"{"as":"reviewer","verb":"condition","params":{"kind":"review-landed"}}"#
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
                "--effort",
                "high",
                "--context",
                "1m",
                "--host",
                "eezo",
                "--key",
                "k1",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"spawn","params":{"displayName":"Reviewer","idempotencyKey":"k1","archetype":"worker","harness":"codex","model":"gpt","effort":"high","context":"1m","handle":"reviewer","host":"eezo"}}"#
        );

        // A flag NAMED but left empty is a real selection — "the vendor's
        // default window", "no tier" — and it must cross as JSON null, not
        // vanish. Dropped here, the gateway reads silence and inherits the
        // default's context over the operator's explicit choice. The empty
        // flag is present-with-value; `nonempty` threw exactly those away.
        assert_eq!(
            body(&[
                "spawn",
                "--display",
                "Reviewer",
                "--archetype",
                "worker",
                "--harness",
                "codex",
                "--model",
                "gpt",
                "--context",
                "",
                "--key",
                "k1",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"spawn","params":{"displayName":"Reviewer","idempotencyKey":"k1","archetype":"worker","harness":"codex","model":"gpt","context":null}}"#
        );

        // …and an OMITTED flag still omits the key, or inheritance downstream
        // can never fire. The pair is what gives either one meaning.
        assert_eq!(
            body(&[
                "spawn",
                "--display",
                "Reviewer",
                "--archetype",
                "worker",
                "--harness",
                "codex",
                "--model",
                "gpt",
                "--key",
                "k1",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"spawn","params":{"displayName":"Reviewer","idempotencyKey":"k1","archetype":"worker","harness":"codex","model":"gpt"}}"#
        );
        let command = Command::IdentityEdit {
            identity: Identity::User("flynn".to_owned()),
            idempotency_key: "identity-edit-1".to_owned(),
            archetype: "coder".to_owned(),
            manifest: false,
            skill: Some("swift".to_owned()),
            remove: false,
            content: Some("line one\nline two".to_owned()),
        };
        assert_eq!(
            build_request(&command).unwrap().body_json,
            r#"{"asUser":"flynn","verb":"identity-edit","params":{"idempotencyKey":"identity-edit-1","archetype":"coder","manifest":false,"remove":false,"skill":"swift","content":"line one\nline two"}}"#
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
                "--effect-kind",
                "policy",
                "--files",
                "[\"lib/a.ex\",\"test/a_test.exs\"]",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"assign","role":"builder","params":{"subject":"ship","idempotencyKey":"idem","workItemId":"wi_1","reviews":"asg_parent","effectKind":"policy","files":["lib/a.ex","test/a_test.exs"]}}"#
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
                "--effect-kind",
                "release",
                "--workdir-root",
                "checkout",
                "--key",
                "idem",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"dispatch","sessionKey":"agent:builder","params":{"subject":"ship","brief":"Please ship it.","workItemId":"wi_1","effectKind":"release","workdirRoot":"checkout","idempotencyKey":"idem"}}"#
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
            body(&[
                "decision-request",
                "--request",
                "dr_12345678-1234-4234-9234-123456789abc",
                "--as",
                "parent",
            ]),
            r#"{"as":"parent","verb":"decision-request","params":{"request":"dr_12345678-1234-4234-9234-123456789abc"}}"#
        );
        assert_eq!(
            body(&[
                "operator-ask",
                "--question",
                "ship window?",
                "--note",
                "release train",
                "--options",
                "accept,wait",
                "--assignment",
                "asg_1",
                "--deadline",
                "2h",
                "--supersedes",
                "dr_old",
                "--as",
                "parent",
            ]),
            r#"{"as":"parent","verb":"operator-ask","params":{"question":"ship window?","note":"release train","options":[{"label":"accept"},{"label":"wait"}],"assignment":"asg_1","deadline":7200000,"supersedes":"dr_old"}}"#
        );
        assert_eq!(
            body(&[
                "operator-rule",
                "dr_1",
                "--decision",
                "accept",
                "--rationale",
                "ship 013 first",
                "--as-user",
                "mike",
            ]),
            r#"{"asUser":"mike","verb":"operator-rule","params":{"request":"dr_1","decision":"accept","rationale":"ship 013 first"}}"#
        );
        assert_eq!(
            body(&[
                "operator-withdraw",
                "dr_2",
                "--reason",
                "moot after 013",
                "--as",
                "parent",
            ]),
            r#"{"as":"parent","verb":"operator-withdraw","params":{"request":"dr_2","reason":"moot after 013"}}"#
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
        let class_a_sha = "d4e8260c8a82faf07ab2659e1f317bef961441af6ba43a4b9d1ef62fa01d4b86";
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
            body(&["work-item-update", "wi_1", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"work-item-update","params":{"workItemId":"wi_1"}}"#
        );
        assert_eq!(
            body(&[
                "work-item-update",
                "wi_1",
                "--title",
                "Retitled",
                "--spec-sha256",
                &sha,
                "--as-user",
                "flynn",
            ]),
            format!(
                r#"{{"asUser":"flynn","verb":"work-item-update","params":{{"workItemId":"wi_1","title":"Retitled","specRefSha256":"{sha}"}}}}"#
            )
        );
        assert_eq!(
            body(&[
                "work-item-update",
                "wi_1",
                "--title",
                "Together",
                "--spec-ref",
                "governing.md",
                "--spec-sha256",
                &sha,
                "--priority",
                "7",
                "--as-user",
                "flynn",
            ]),
            format!(
                r#"{{"asUser":"flynn","verb":"work-item-update","params":{{"workItemId":"wi_1","title":"Together","specRefName":"governing.md","specRefSha256":"{sha}","priority":7}}}}"#
            )
        );
        assert_eq!(
            body(&[
                "work-item-update",
                "wi_6d418db1-26b4-4ad0-9886-86e757e93342",
                "--spec-ref",
                "patrol-failure-classification-and-escalation-v1.md",
                "--spec-sha256",
                class_a_sha,
                "--as-user",
                "flynn",
            ]),
            format!(
                r#"{{"asUser":"flynn","verb":"work-item-update","params":{{"workItemId":"wi_6d418db1-26b4-4ad0-9886-86e757e93342","specRefName":"patrol-failure-classification-and-escalation-v1.md","specRefSha256":"{class_a_sha}"}}}}"#
            )
        );
        assert_eq!(
            body(&[
                "work-item-update",
                "wi_1",
                "--clear-spec-ref",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"work-item-update","params":{"workItemId":"wi_1","specRefName":null,"specRefSha256":null}}"#
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
            body(&[
                "work-item-create",
                "--title",
                "Urgent",
                "--priority",
                "7",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"work-item-create","params":{"title":"Urgent","priority":7}}"#
        );
        assert_eq!(
            body(&[
                "work-item-update",
                "wi_1",
                "--priority",
                "2",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"work-item-update","params":{"workItemId":"wi_1","priority":2}}"#
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
        assert_eq!(
            body(&["config", "get", "default-priority", "--as-user", "flynn"]),
            r#"{"asUser":"flynn","verb":"config","params":{"action":"get","setting":"default-priority"}}"#
        );
        assert_eq!(
            body(&[
                "config",
                "set",
                "default-priority",
                "6",
                "--as-user",
                "flynn"
            ]),
            r#"{"asUser":"flynn","verb":"config","params":{"action":"set","setting":"default-priority","value":6}}"#
        );
    }

    #[test]
    fn builds_byte_exact_host_env_bodies() {
        assert_eq!(
            body(&[
                "host-env-set",
                "--host",
                "gibson",
                "--harness",
                "claude",
                "EXAMPLE_OVERLAY_VAR=example",
                "--as",
                "operator",
            ]),
            r#"{"as":"operator","verb":"host-env-set","params":{"host":"gibson","harness":"claude","name":"EXAMPLE_OVERLAY_VAR","value":"example"}}"#
        );
        assert_eq!(
            body(&[
                "host-env-list",
                "--host",
                "gibson",
                "--harness",
                "claude",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"host-env-list","params":{"host":"gibson","harness":"claude"}}"#
        );
        assert_eq!(
            body(&[
                "host-env-unset",
                "--host",
                "gibson",
                "--harness",
                "claude",
                "EXAMPLE_OVERLAY_VAR",
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"host-env-unset","params":{"host":"gibson","harness":"claude","name":"EXAMPLE_OVERLAY_VAR"}}"#
        );
    }

    #[test]
    fn builds_byte_exact_host_toolchain_body() {
        assert_eq!(
            body(&[
                "host-toolchain-set",
                "--host",
                "gibson",
                "--dirs",
                r#"["/tools/one","/tools/two"]"#,
                "--as-user",
                "flynn",
            ]),
            r#"{"asUser":"flynn","verb":"host-toolchain-set","params":{"host":"gibson","dirs":["/tools/one","/tools/two"]}}"#
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
            Some("lease-7"),
            None,
        );

        assert_eq!(
            keyed.body_json,
            r#"{"asUser":"flynn","verb":"onboard","params":{"provider":"anthropic","phase":"finish","kind":"apiKey","machine":"work-1","leaseId":"lease-7"}}"#
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
            (
                &[
                    "identity",
                    "repoint",
                    "agent:retired",
                    "default",
                    "--as-user",
                    "flynn",
                ][..],
                r#"{"asUser":"flynn","verb":"identity-repoint","sessionKey":"agent:retired","params":{"archetype":"default"}}"#,
            ),
            (
                &["kungfu", "list", "--as-user", "flynn"][..],
                r#"{"asUser":"flynn","verb":"kungfu-list","params":{}}"#,
            ),
            (
                &[
                    "learn",
                    "agentic-engineering",
                    "--key",
                    "learn-1",
                    "--as-user",
                    "flynn",
                ][..],
                r#"{"asUser":"flynn","verb":"learn","params":{"idempotencyKey":"learn-1","name":"agentic-engineering"}}"#,
            ),
            (
                &[
                    "unlearn",
                    "agentic-engineering",
                    "--key",
                    "unlearn-1",
                    "--as-user",
                    "flynn",
                ][..],
                r#"{"asUser":"flynn","verb":"unlearn","params":{"idempotencyKey":"unlearn-1","name":"agentic-engineering"}}"#,
            ),
            (
                &[
                    "identity",
                    "relearn",
                    "--resolve",
                    "--key",
                    "relearn-1",
                    "--as-user",
                    "flynn",
                ][..],
                r#"{"asUser":"flynn","verb":"identity-relearn","params":{"idempotencyKey":"relearn-1","action":"resolve"}}"#,
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
                origin: Origin::Provisioned,
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
                origin: Origin::Named,
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
                    origin: Origin::Provisioned,
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
                origin: Origin::Provisioned,
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
                origin: Origin::Provisioned,
            })
        );

        assert_eq!(
            discover_with(|_| None, &root, &root),
            Ok(Endpoint {
                base: "http://127.0.0.1:9876".to_owned(),
                token: "default".to_owned(),
                origin: Origin::Provisioned,
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
                origin: Origin::Provisioned,
            })
        );
        assert_eq!(
            discover_from(&gateway),
            Ok(Endpoint {
                base: "http://127.0.0.1:11373".to_owned(),
                token: "tbc_org".to_owned(),
                origin: Origin::Provisioned,
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
                    origin: Origin::Provisioned,
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
                origin: Origin::Session(ancestor.join("work").join(".tightbeam-session")),
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

    // MIRROR of `a_satellite_url_written_as_a_websocket_scheme_dispatches_over_http`,
    // one call-site over. That test guards gateway.json's reader; this guards the
    // SESSION-CREDENTIAL reader. A satellite's `.tightbeam-session` carries the
    // gateway's ADVERTISED (websocket) url, so the first agent to file from a
    // satellite hit "Unknown Scheme: unknown scheme 'ws'" rooting `/agent/dispatch`
    // -- `discover_session_from` handed the ws:// base through untouched while the
    // gateway.json reader (815d27e) normalized it. One url, two readers; 815d27e
    // fixed one. The sibling session test above hardcodes https:// and can never
    // catch this: its warning that fixtures encoding an assumption production
    // violates cannot fail came true here, one call-site over.
    #[test]
    fn a_session_url_written_as_a_websocket_scheme_dispatches_over_http() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("tightbeam_cli_session_ws_{unique}"));
        let cases = [
            ("ws", "ws://gibson:11373", "http://gibson:11373"),
            ("wss", "wss://gibson:11373", "https://gibson:11373"),
            // http and https are already the dispatch scheme and pass through whole.
            ("http", "http://gibson:11373", "http://gibson:11373"),
            ("https", "https://gibson:11373", "https://gibson:11373"),
        ];
        for (name, written, expected) in cases {
            let dir = root.join(name);
            fs::create_dir_all(&dir).unwrap();
            let session = dir.join(".tightbeam-session");
            fs::write(
                &session,
                format!(r#"{{"url":"{written}","token":"tbs_org"}}"#),
            )
            .unwrap();

            assert_eq!(
                discover_session_from(&dir),
                Ok(Some(Endpoint {
                    base: expected.to_owned(),
                    token: "tbs_org".to_owned(),
                    origin: Origin::Session(session),
                })),
                "{name}"
            );
        }
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
                    origin: Origin::Session(PathBuf::from("/work/.tightbeam-session")),
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
            origin: Origin::Provisioned,
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

    /// Serialises the tests that mutate `TIGHTBEAM_MACHINE`.
    ///
    /// The environment is process-global and cargo runs tests in threads, so two tests
    /// setting and restoring the same variable interleave: one restores while the other is
    /// mid-run, and the loser reads a value it never set. Neither test is wrong on its own,
    /// which is why this failed only under parallelism and only sometimes.
    static MACHINE_ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
        // The stub codex below is `true`: it exits zero and writes nothing, which is the
        // shape of a CANCELLED device-code login, and the openai leg now refuses it. This
        // test is about endpoints rather than credentials, so it stages the credential the
        // real ceremony would have produced and lets the phases run. Do not delete this as
        // setup noise -- without it the run cancels and never reaches `finish`.
        fs::write(staging.join("auth.json"), br#"{"tokens":{}}"#).unwrap();
        let _env = MACHINE_ENV
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
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
                hostname: None,
                remote: None,
            },
            || {
                discoveries.set(discoveries.get() + 1);
                Ok(Endpoint {
                    base: gateway.clone(),
                    token: "tbc_one".to_owned(),
                    origin: Origin::Provisioned,
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
                        "leaseId": "lease-7",
                        "leaseTtlMs": 60_000
                    })))
                } else {
                    // What the gateway actually answers a finish with
                    // (gateway.ex:2495). This used to be `Ok(None)`, which the CLI read as
                    // success -- so this test asserted, and protected, the defect that a
                    // transport 2xx counts as the gateway confirming an install.
                    Ok(Some(serde_json::json!({
                        "provider": "openai",
                        "credentialKind": "subscription",
                        "status": "onboarded"
                    })))
                }
            },
            |endpoint, deadline| {
                catalog_calls
                    .borrow_mut()
                    .push((endpoint.base.clone(), deadline));
                Ok(Some(crate::harnesses::HarnessCatalog {
                    harnesses: vec![crate::harnesses::HarnessProjection {
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

    /// A 2xx is the transport saying it arrived, not the gateway saying it installed.
    ///
    /// The same mistake as reading a codex exit code as "a credential was produced", one
    /// layer out. `parse_response` answers `Ok(None)` for a success with no `result`, so
    /// before this every 2xx reached `Ok(())` and the CLI reported a completed onboarding
    /// the gateway had never confirmed. The stub here returns exactly that: a finish that
    /// succeeds at the transport and says nothing.
    ///
    /// Today's gateway cannot send it. It is checked because the CLI and the gateway are
    /// versioned and shipped separately, and the CLI is the half that has to survive
    /// meeting a version of the other that answers differently.
    #[test]
    fn a_finish_the_gateway_never_confirmed_is_refused_and_cancelled() {
        use std::cell::RefCell;

        let staging = std::env::temp_dir().join(format!(
            "tightbeam-onboard-unconfirmed-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = fs::remove_dir_all(&staging);
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("auth.json"), br#"{"tokens":{}}"#).unwrap();
        let _env = MACHINE_ENV
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let prior_machine = std::env::var_os("TIGHTBEAM_MACHINE");
        unsafe {
            std::env::set_var("TIGHTBEAM_MACHINE", "fixture-machine");
        }

        let phases = RefCell::new(Vec::new());
        let result = run_with(
            Command::Onboard {
                identity: Identity::User("flynn".to_owned()),
                provider: "openai".to_owned(),
                api_key: false,
                hostname: None,
                remote: None,
            },
            || {
                Ok(Endpoint {
                    base: "https://gateway.test".to_owned(),
                    token: "tbc_one".to_owned(),
                    origin: Origin::Provisioned,
                })
            },
            |_, request, _| {
                let phase = if request.body_json.contains(r#""phase":"begin""#) {
                    "begin"
                } else if request.body_json.contains(r#""phase":"finish""#) {
                    "finish"
                } else {
                    "cancel"
                };
                phases.borrow_mut().push(phase);
                match phase {
                    "begin" => Ok(Some(serde_json::json!({
                        "stagingPath": staging,
                        "leaseId": "lease-7",
                        "leaseTtlMs": 60_000
                    }))),
                    // 2xx, no result. The transport succeeded and the gateway said nothing.
                    _ => Ok(None),
                }
            },
            |_, _| {
                Ok(Some(crate::harnesses::HarnessCatalog {
                    harnesses: vec![crate::harnesses::HarnessProjection {
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

        let error = result.unwrap_err();
        assert!(error.contains("did not confirm"), "{error}");
        assert!(error.contains("doctor"), "no way forward offered: {error}");
        assert_eq!(
            phases.into_inner(),
            vec!["begin", "finish", "cancel"],
            "an unconfirmed finish must release the lease rather than leave it open"
        );
    }

    /// The one condition, at the seam, without the ceremony around it.
    #[test]
    fn only_an_onboarded_status_counts_as_a_finished_onboarding() {
        use crate::ceremonies::onboarded_outcome;

        let confirmed = serde_json::json!({"provider": "openai", "status": "onboarded"});
        assert_eq!(onboarded_outcome(Some(confirmed.clone())), Ok(confirmed));

        for unconfirmed in [
            None,
            Some(serde_json::json!({})),
            Some(serde_json::json!(null)),
            Some(serde_json::json!({"status": "pending"})),
            Some(serde_json::json!({"provider": "openai"})),
        ] {
            let error = onboarded_outcome(unconfirmed.clone()).unwrap_err();
            assert!(
                error.contains("did not confirm"),
                "{unconfirmed:?} was accepted as a finished onboarding"
            );
        }
    }

    #[test]
    fn an_expired_deadline_refuses_gateway_io_as_lease_expiry() {
        use std::time::{Duration, Instant};

        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "tbc_test".to_owned(),
            origin: Origin::Provisioned,
        };
        let request = build_onboard_phase_request(
            &Identity::User("flynn".to_owned()),
            "openai",
            "finish",
            "subscription",
            Some("work-1"),
            None,
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
        assert_eq!(
            parse_response(
                500,
                r#"{"error":{"code":"decision_request_integrity_invalid","message":"decision request integrity check failed","requestId":"dr_exact"}}"#
            ),
            Err(
                "decision_request_integrity_invalid: decision request integrity check failed (dr_exact)"
                    .to_owned()
            )
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
