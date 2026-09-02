use std::collections::{HashMap, HashSet};
use std::io::Read;

use serde::Deserialize;
use serde::de::{MapAccess, SeqAccess, Visitor};
use serde_json::Value;

use crate::dispatch::{Origin, RequestSpec};

const RULE: &str = "github-network-auth-required";
const HANDLER: &str = "github-network-auth-v1";
const RETURNS: &[&str] = &[
    "not_applicable",
    "live",
    "profile_not_elected",
    "missing_cli",
    "needs_onboarding",
    "hollow",
    "expired",
    "insufficient_scope",
    "git_unready",
    "revoked",
    "present_but_unverified",
    "unknown",
    "ambiguous_hostname",
    "projection_override",
    "malformed_tool_call",
    "rule_runtime_failure",
];

#[derive(Debug, Clone, PartialEq, Eq)]
struct Args {
    rule: String,
    handler: String,
    abi: u64,
    identity_sha: String,
    effects: HashMap<String, Effect>,
    fallback_repair: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Effect {
    Allow,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Context {
    machine: String,
    principal: String,
    identity_sha: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ToolCallInputV1 {
    pub(crate) abi: u64,
    pub(crate) tool: ToolCallToolV1,
    pub(crate) command: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ToolCallToolV1 {
    Bash,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ToolCheckMaterialV1 {
    pub(crate) state: String,
    pub(crate) operation_class: String,
    pub(crate) machine: String,
    pub(crate) profile: Option<String>,
    pub(crate) hostname: Option<String>,
    pub(crate) phase: String,
    pub(crate) cause: String,
    pub(crate) principal: String,
    pub(crate) repair: Option<String>,
    pub(crate) observation_ids: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MalformedToolCallCauseV1 {
    NativeInvalidUtf8,
    NativeInvalidJson,
    NativeDuplicateMember,
    NativeMultipleValues,
    NativeTrailingBytes,
    NativeRootNotObject,
    NativeToolNameMissing,
    NativeToolNameInvalid,
    NativeToolInputMissing,
    NativeToolInputInvalid,
    NativeCommandMissing,
    NativeCommandInvalid,
}

impl MalformedToolCallCauseV1 {
    fn as_str(self) -> &'static str {
        match self {
            Self::NativeInvalidUtf8 => "native_invalid_utf8",
            Self::NativeInvalidJson => "native_invalid_json",
            Self::NativeDuplicateMember => "native_duplicate_member",
            Self::NativeMultipleValues => "native_multiple_values",
            Self::NativeTrailingBytes => "native_trailing_bytes",
            Self::NativeRootNotObject => "native_root_not_object",
            Self::NativeToolNameMissing => "native_tool_name_missing",
            Self::NativeToolNameInvalid => "native_tool_name_invalid",
            Self::NativeToolInputMissing => "native_tool_input_missing",
            Self::NativeToolInputInvalid => "native_tool_input_invalid",
            Self::NativeCommandMissing => "native_command_missing",
            Self::NativeCommandInvalid => "native_command_invalid",
        }
    }
}

pub(crate) fn run(raw_args: &[String]) -> Result<i32, String> {
    let args = match parse_args(raw_args) {
        Ok(args) => args,
        Err(_) => {
            return execute_runtime_failure(
                &closed_failure_args(),
                RuntimeFailure::projected(
                    "invocation",
                    "invalid_compiled_dispatch_rule_invocation",
                ),
            );
        }
    };

    let materials = match collect_materials(&args) {
        Ok(materials) => materials,
        Err(failure) => return execute_runtime_failure(&args, failure),
    };
    execute_materials(&args, materials)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RuntimeFailure {
    phase: &'static str,
    cause: &'static str,
    machine: String,
    profile: Option<String>,
    principal: String,
}

impl RuntimeFailure {
    fn projected(phase: &'static str, cause: &'static str) -> Self {
        Self {
            phase,
            cause,
            machine: projected_field("TIGHTBEAM_MACHINE"),
            profile: projected_optional_field("TIGHTBEAM_GITHUB_PROFILE"),
            principal: projected_field("TIGHTBEAM_PRINCIPAL"),
        }
    }

    fn authenticated(phase: &'static str, cause: &'static str, context: &Context) -> Self {
        Self {
            phase,
            cause,
            machine: marker_field(&context.machine),
            profile: projected_optional_field("TIGHTBEAM_GITHUB_PROFILE"),
            principal: marker_field(&context.principal),
        }
    }
}

fn collect_materials(args: &Args) -> Result<Vec<ToolCheckMaterialV1>, RuntimeFailure> {
    let endpoint = authenticated_session_endpoint().map_err(|_| {
        RuntimeFailure::projected("authentication", "session_authentication_failed")
    })?;
    let context = authenticate_context(&endpoint, args)
        .map_err(|_| RuntimeFailure::projected("authentication", "authenticated_context_failed"))?;

    let mut raw = Vec::new();
    std::io::stdin().read_to_end(&mut raw).map_err(|_| {
        RuntimeFailure::authenticated("normalization", "tool_input_read_failed", &context)
    })?;

    let input = match normalize(&raw, args.abi) {
        Err(cause) => ToolCallInputOrMaterial::Material(ToolCheckMaterialV1 {
            state: "malformed_tool_call".to_owned(),
            operation_class: "malformed".to_owned(),
            machine: context.machine.clone(),
            profile: None,
            hostname: None,
            phase: "normalization".to_owned(),
            cause: cause.as_str().to_owned(),
            principal: context.principal.clone(),
            repair: Some(args.fallback_repair.clone()),
            observation_ids: vec![observe_malformed(&endpoint, args, &context, cause).map_err(
                |_| {
                    RuntimeFailure::authenticated(
                        "recording",
                        "observation_record_failed",
                        &context,
                    )
                },
            )?],
        }),
        Ok(input) => ToolCallInputOrMaterial::Input(input),
    };

    let materials = match input {
        ToolCallInputOrMaterial::Material(material) => vec![material],
        ToolCallInputOrMaterial::Input(input) => crate::github_auth::check_compiled_rule(
            &endpoint,
            &args.identity_sha,
            &context.machine,
            &context.principal,
            &input,
        )
        .map_err(|_| {
            RuntimeFailure::authenticated("handler", "compiled_handler_failed", &context)
        })?,
    };
    Ok(materials)
}

enum ToolCallInputOrMaterial {
    Input(ToolCallInputV1),
    Material(ToolCheckMaterialV1),
}

fn execute_materials(args: &Args, materials: Vec<ToolCheckMaterialV1>) -> Result<i32, String> {
    for material in materials {
        match args.effects.get(&material.state) {
            Some(Effect::Allow) if material.repair.is_none() => continue,
            Some(Effect::Deny) if material.repair.as_deref().is_some_and(|r| !r.is_empty()) => {
                return Err(render_refusal(&material));
            }
            _ => {
                return execute_runtime_failure(
                    args,
                    RuntimeFailure {
                        phase: "execution",
                        cause: "invalid_compiled_effect_or_material",
                        machine: projected_field("TIGHTBEAM_MACHINE"),
                        profile: projected_optional_field("TIGHTBEAM_GITHUB_PROFILE"),
                        principal: projected_field("TIGHTBEAM_PRINCIPAL"),
                    },
                );
            }
        }
    }
    Ok(0)
}

fn execute_runtime_failure(args: &Args, failure: RuntimeFailure) -> Result<i32, String> {
    let material = ToolCheckMaterialV1 {
        state: "rule_runtime_failure".to_owned(),
        operation_class: "not_applicable".to_owned(),
        machine: failure.machine,
        profile: failure.profile,
        hostname: None,
        phase: failure.phase.to_owned(),
        cause: failure.cause.to_owned(),
        principal: failure.principal,
        repair: Some(args.fallback_repair.clone()),
        observation_ids: Vec::new(),
    };

    match args.effects.get("rule_runtime_failure") {
        Some(Effect::Deny) if !args.fallback_repair.trim().is_empty() => {
            Err(render_refusal(&material))
        }
        _ => Err(render_refusal(&ToolCheckMaterialV1 {
            cause: "invalid_compiled_runtime_failure_effect".to_owned(),
            repair: Some("tightbeam doctor --json".to_owned()),
            ..material
        })),
    }
}

fn closed_failure_args() -> Args {
    let effects = RETURNS
        .iter()
        .map(|state| {
            (
                (*state).to_owned(),
                if matches!(*state, "not_applicable" | "live") {
                    Effect::Allow
                } else {
                    Effect::Deny
                },
            )
        })
        .collect();
    Args {
        rule: RULE.to_owned(),
        handler: HANDLER.to_owned(),
        abi: 1,
        identity_sha: String::new(),
        effects,
        fallback_repair: "tightbeam doctor --json".to_owned(),
    }
}

fn projected_field(name: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .map(|value| marker_field(&value))
        .unwrap_or_else(|| "none".to_owned())
}

fn projected_optional_field(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .map(|value| marker_field(&value))
}

fn marker_field(value: &str) -> String {
    let safe = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | ':' | '@') {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>();
    if safe.is_empty() {
        "none".to_owned()
    } else {
        safe
    }
}

fn render_refusal(material: &ToolCheckMaterialV1) -> String {
    format!(
        "[gate: {RULE}] state={} operation_class={} machine={} profile={} hostname={} phase={} cause={} principal={} observation_ids={} repair={}",
        material.state,
        material.operation_class,
        material.machine,
        material.profile.as_deref().unwrap_or("none"),
        material.hostname.as_deref().unwrap_or("none"),
        material.phase,
        material.cause,
        material.principal,
        material.observation_ids.join(","),
        material.repair.as_deref().unwrap_or("none")
    )
}

fn parse_args(raw: &[String]) -> Result<Args, String> {
    let mut rule = None;
    let mut handler = None;
    let mut abi = None;
    let mut identity_sha = None;
    let mut effects = None;
    let mut fallback_repair = None;
    let mut index = 0;

    while index < raw.len() {
        let slot = match raw[index].as_str() {
            "--rule" => &mut rule,
            "--handler" => &mut handler,
            "--identity-sha" => &mut identity_sha,
            "--effects" => &mut effects,
            "--fallback-repair" => &mut fallback_repair,
            "--abi" => {
                index += 1;
                let value = raw.get(index).ok_or_else(invalid_invocation)?;
                if abi
                    .replace(value.parse::<u64>().map_err(|_| invalid_invocation())?)
                    .is_some()
                {
                    return Err(invalid_invocation());
                }
                index += 1;
                continue;
            }
            _ => return Err(invalid_invocation()),
        };
        index += 1;
        let value = raw.get(index).ok_or_else(invalid_invocation)?;
        if value.is_empty() || slot.replace(value.clone()).is_some() {
            return Err(invalid_invocation());
        }
        index += 1;
    }

    let effects = effects.ok_or_else(invalid_invocation)?;
    let effects = serde_json::from_str::<HashMap<String, String>>(&effects)
        .map_err(|_| invalid_invocation())?
        .into_iter()
        .map(|(state, effect)| match effect.as_str() {
            "allow" => Ok((state, Effect::Allow)),
            "deny" => Ok((state, Effect::Deny)),
            _ => Err(invalid_invocation()),
        })
        .collect::<Result<HashMap<_, _>, _>>()?;
    let parsed = Args {
        rule: rule.ok_or_else(invalid_invocation)?,
        handler: handler.ok_or_else(invalid_invocation)?,
        abi: abi.ok_or_else(invalid_invocation)?,
        identity_sha: identity_sha.ok_or_else(invalid_invocation)?,
        effects,
        fallback_repair: fallback_repair.ok_or_else(invalid_invocation)?,
    };

    if parsed.rule != RULE
        || parsed.handler != HANDLER
        || parsed.abi != 1
        || parsed.fallback_repair.trim().is_empty()
        || parsed.effects.get("malformed_tool_call") != Some(&Effect::Deny)
        || parsed.effects.get("rule_runtime_failure") != Some(&Effect::Deny)
        || parsed.effects.len() != RETURNS.len()
        || RETURNS
            .iter()
            .any(|state| !parsed.effects.contains_key(*state))
    {
        return Err(invalid_invocation());
    }
    Ok(parsed)
}

fn invalid_invocation() -> String {
    "rule_runtime_failure: invalid compiled dispatch-rule invocation".to_owned()
}

fn authenticated_session_endpoint() -> Result<crate::dispatch::Endpoint, String> {
    let cwd = std::env::current_dir().map_err(|_| "rule_runtime_failure".to_owned())?;
    match crate::dispatch::discover_session_from(&cwd)? {
        Some(
            endpoint @ crate::dispatch::Endpoint {
                origin: Origin::Session(_),
                ..
            },
        ) => Ok(endpoint),
        _ => Err("rule_runtime_failure: session authentication is required".to_owned()),
    }
}

fn authenticate_context(
    endpoint: &crate::dispatch::Endpoint,
    args: &Args,
) -> Result<Context, String> {
    let machine = std::env::var("TIGHTBEAM_MACHINE").ok();
    let principal = std::env::var("TIGHTBEAM_PRINCIPAL").ok();
    let body = serde_json::json!({
        "identitySha": args.identity_sha,
        "machine": machine,
        "principal": principal,
    });
    let request = RequestSpec {
        method: "POST",
        path: "/agent/github/context",
        body_json: body.to_string(),
    };
    let result = crate::dispatch::send_to(endpoint, &request)?
        .ok_or_else(|| "rule_runtime_failure: missing authenticated context".to_owned())?;
    let context = Context {
        machine: required_result_string(&result, "machine")?,
        principal: required_result_string(&result, "principal")?,
        identity_sha: required_result_string(&result, "identitySha")?,
    };

    if machine.as_deref() != Some(context.machine.as_str())
        || principal.as_deref() != Some(context.principal.as_str())
        || context.identity_sha != args.identity_sha
    {
        return Err("rule_runtime_failure: authenticated context mismatch".to_owned());
    }
    Ok(context)
}

fn required_result_string(result: &Value, key: &str) -> Result<String, String> {
    result
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "rule_runtime_failure: invalid authenticated context".to_owned())
}

fn observe_malformed(
    endpoint: &crate::dispatch::Endpoint,
    args: &Args,
    context: &Context,
    cause: MalformedToolCallCauseV1,
) -> Result<String, String> {
    let request = RequestSpec {
        method: "POST",
        path: "/agent/github/observe",
        body_json: serde_json::json!({
            "identitySha": args.identity_sha,
            "machine": context.machine,
            "principal": context.principal,
            "state": "malformed_tool_call",
            "operationClass": "malformed",
            "phase": "normalization",
            "cause": cause.as_str(),
            "rule": RULE,
        })
        .to_string(),
    };
    crate::dispatch::send_to(endpoint, &request)
        .and_then(|result| {
            result
                .and_then(|value| value.get("id").and_then(Value::as_str).map(str::to_owned))
                .ok_or_else(|| "observation response omitted id".to_owned())
        })
        .map_err(|_| {
            format!(
                "[gate: {RULE}] state=rule_runtime_failure machine={} profile=none hostname=none phase=recording cause=observation_record_failed principal={} repair=tightbeam doctor --json",
                context.machine, context.principal
            )
        })
}

pub(crate) fn normalize(raw: &[u8], abi: u64) -> Result<ToolCallInputV1, MalformedToolCallCauseV1> {
    std::str::from_utf8(raw).map_err(|_| MalformedToolCallCauseV1::NativeInvalidUtf8)?;

    let mut stream = serde_json::Deserializer::from_slice(raw).into_iter::<Value>();
    let first = stream
        .next()
        .ok_or(MalformedToolCallCauseV1::NativeInvalidJson)?
        .map_err(|_| MalformedToolCallCauseV1::NativeInvalidJson)?;
    let first_end = stream.byte_offset();

    let mut duplicate_check = serde_json::Deserializer::from_slice(&raw[..first_end]);
    if NoDuplicateValue::deserialize(&mut duplicate_check).is_err() {
        return Err(MalformedToolCallCauseV1::NativeDuplicateMember);
    }

    let remainder = &raw[first_end..];
    if remainder.iter().any(|byte| !byte.is_ascii_whitespace()) {
        let mut rest = serde_json::Deserializer::from_slice(remainder).into_iter::<Value>();
        if rest.next().is_some_and(|value| value.is_ok()) {
            return Err(MalformedToolCallCauseV1::NativeMultipleValues);
        }
        return Err(MalformedToolCallCauseV1::NativeTrailingBytes);
    }

    let object = first
        .as_object()
        .ok_or(MalformedToolCallCauseV1::NativeRootNotObject)?;
    let tool = object
        .get("tool_name")
        .ok_or(MalformedToolCallCauseV1::NativeToolNameMissing)?;
    if tool.as_str() != Some("Bash") {
        return Err(MalformedToolCallCauseV1::NativeToolNameInvalid);
    }
    let input = object
        .get("tool_input")
        .ok_or(MalformedToolCallCauseV1::NativeToolInputMissing)?;
    let input = input
        .as_object()
        .ok_or(MalformedToolCallCauseV1::NativeToolInputInvalid)?;
    let command = input
        .get("command")
        .ok_or(MalformedToolCallCauseV1::NativeCommandMissing)?;
    let command = command
        .as_str()
        .ok_or(MalformedToolCallCauseV1::NativeCommandInvalid)?;

    Ok(ToolCallInputV1 {
        abi,
        tool: ToolCallToolV1::Bash,
        command: command.to_owned(),
    })
}

struct NoDuplicateValue;

impl<'de> Deserialize<'de> for NoDuplicateValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(NoDuplicateVisitor)
    }
}

struct NoDuplicateVisitor;

impl<'de> Visitor<'de> for NoDuplicateVisitor {
    type Value = NoDuplicateValue;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a JSON value without duplicate object members")
    }

    fn visit_bool<E>(self, _value: bool) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }
    fn visit_i64<E>(self, _value: i64) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }
    fn visit_u64<E>(self, _value: u64) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }
    fn visit_f64<E>(self, _value: f64) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }
    fn visit_str<E>(self, _value: &str) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }
    fn visit_string<E>(self, _value: String) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }
    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(NoDuplicateValue)
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        while sequence.next_element::<NoDuplicateValue>()?.is_some() {}
        Ok(NoDuplicateValue)
    }

    fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut keys = HashSet::new();
        while let Some(key) = map.next_key::<String>()? {
            if !keys.insert(key) {
                return Err(serde::de::Error::custom("duplicate member"));
            }
            map.next_value::<NoDuplicateValue>()?;
        }
        Ok(NoDuplicateValue)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizer_accepts_harness_metadata_and_preserves_command_bytes() {
        let raw = b"{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\" echo  x\\n\",\"description\":\"ignored\"},\"session_id\":\"ignored\"}  \n";
        assert_eq!(
            normalize(raw, 1),
            Ok(ToolCallInputV1 {
                abi: 1,
                tool: ToolCallToolV1::Bash,
                command: " echo  x\n".to_owned()
            })
        );
    }

    #[test]
    fn harness_metadata_does_not_change_the_typed_normalized_input() {
        let claude =
            br#"{"tool_name":"Bash","tool_input":{"command":"git status"},"session_id":"claude"}"#;
        let codex = br#"{"tool_name":"Bash","tool_input":{"command":"git status"},"hook_event_name":"PreToolUse"}"#;

        assert_eq!(normalize(claude, 1), normalize(codex, 1));
    }

    #[test]
    fn normalizer_returns_the_closed_cause_order() {
        let cases: &[(&[u8], MalformedToolCallCauseV1)] = &[
            (&[0xff], MalformedToolCallCauseV1::NativeInvalidUtf8),
            (b"{", MalformedToolCallCauseV1::NativeInvalidJson),
            (
                br#"{"tool_name":"Bash","tool_name":"Bash","tool_input":{"command":"x"}}"#,
                MalformedToolCallCauseV1::NativeDuplicateMember,
            ),
            (b"{} {}", MalformedToolCallCauseV1::NativeMultipleValues),
            (
                b"{} trailing",
                MalformedToolCallCauseV1::NativeTrailingBytes,
            ),
            (b"[]", MalformedToolCallCauseV1::NativeRootNotObject),
            (b"{}", MalformedToolCallCauseV1::NativeToolNameMissing),
            (
                br#"{"tool_name":"bash","tool_input":{"command":"x"}}"#,
                MalformedToolCallCauseV1::NativeToolNameInvalid,
            ),
            (
                br#"{"tool_name":"Bash"}"#,
                MalformedToolCallCauseV1::NativeToolInputMissing,
            ),
            (
                br#"{"tool_name":"Bash","tool_input":[]}"#,
                MalformedToolCallCauseV1::NativeToolInputInvalid,
            ),
            (
                br#"{"tool_name":"Bash","tool_input":{}}"#,
                MalformedToolCallCauseV1::NativeCommandMissing,
            ),
            (
                br#"{"tool_name":"Bash","tool_input":{"command":1}}"#,
                MalformedToolCallCauseV1::NativeCommandInvalid,
            ),
        ];
        for (raw, cause) in cases {
            assert_eq!(normalize(raw, 1), Err(*cause), "{}", cause.as_str());
        }
    }

    #[test]
    fn compiled_effects_alone_choose_allow_or_deny() {
        let effects = RETURNS
            .iter()
            .map(|state| {
                (
                    (*state).to_owned(),
                    if matches!(*state, "not_applicable" | "live") {
                        Effect::Allow
                    } else {
                        Effect::Deny
                    },
                )
            })
            .collect();
        let args = Args {
            rule: RULE.to_owned(),
            handler: HANDLER.to_owned(),
            abi: 1,
            identity_sha: "fixture".to_owned(),
            effects,
            fallback_repair: "tightbeam doctor --json".to_owned(),
        };
        let live = ToolCheckMaterialV1 {
            state: "live".to_owned(),
            operation_class: "gh".to_owned(),
            machine: "fixture-host".to_owned(),
            profile: Some("work".to_owned()),
            hostname: Some("github.com".to_owned()),
            phase: "provider".to_owned(),
            cause: "current_provider_probe_live".to_owned(),
            principal: "session:fixture".to_owned(),
            repair: None,
            observation_ids: vec!["obs_fixture".to_owned()],
        };
        assert_eq!(execute_materials(&args, vec![live]), Ok(0));

        let expired = ToolCheckMaterialV1 {
            state: "expired".to_owned(),
            operation_class: "git".to_owned(),
            machine: "fixture-host".to_owned(),
            profile: Some("work".to_owned()),
            hostname: Some("github.com".to_owned()),
            phase: "provider".to_owned(),
            cause: "provider_http_401".to_owned(),
            principal: "session:fixture".to_owned(),
            repair: Some(
                "tightbeam onboard github --profile work --hostname github.com".to_owned(),
            ),
            observation_ids: vec!["obs_fixture".to_owned()],
        };
        let refusal = execute_materials(&args, vec![expired]).unwrap_err();
        assert!(refusal.contains("state=expired"));
        assert!(refusal.contains("observation_ids=obs_fixture"));
    }

    #[test]
    fn invalid_compiled_invocation_is_a_named_runtime_failure_material() {
        let refusal = run(&[]).unwrap_err();
        assert!(refusal.starts_with("[gate: github-network-auth-required]"));
        assert!(refusal.contains("state=rule_runtime_failure"));
        assert!(refusal.contains("operation_class=not_applicable"));
        assert!(refusal.contains("phase=invocation"));
        assert!(refusal.contains("cause=invalid_compiled_dispatch_rule_invocation"));
        assert!(refusal.contains("repair=tightbeam doctor --json"));
        assert!(!refusal.contains("invalid compiled dispatch-rule invocation"));
    }

    #[test]
    fn invalid_handler_material_reenters_the_runtime_failure_effect() {
        let args = closed_failure_args();
        let invalid = ToolCheckMaterialV1 {
            state: "live".to_owned(),
            operation_class: "gh".to_owned(),
            machine: "fixture host\nspoof".to_owned(),
            profile: Some("work".to_owned()),
            hostname: Some("github.com".to_owned()),
            phase: "provider".to_owned(),
            cause: "current_provider_probe_live".to_owned(),
            principal: "session:fixture\nspoof".to_owned(),
            repair: Some("unexpected repair".to_owned()),
            observation_ids: Vec::new(),
        };

        let refusal = execute_materials(&args, vec![invalid]).unwrap_err();
        assert!(refusal.contains("state=rule_runtime_failure"));
        assert!(refusal.contains("phase=execution"));
        assert!(refusal.contains("cause=invalid_compiled_effect_or_material"));
        assert!(!refusal.contains("fixture_host_spoof"));
        assert!(!refusal.contains("session:fixture_spoof"));
        assert_eq!(refusal.lines().count(), 1);
    }

    #[test]
    fn synthetic_runtime_failure_carries_only_projected_marker_fields() {
        let refusal = execute_runtime_failure(
            &closed_failure_args(),
            RuntimeFailure {
                phase: "handler",
                cause: "compiled_handler_failed",
                machine: "fixture-host".to_owned(),
                profile: Some("work_profile".to_owned()),
                principal: "session:fixture".to_owned(),
            },
        )
        .unwrap_err();

        assert!(refusal.contains("machine=fixture-host"));
        assert!(refusal.contains("profile=work_profile"));
        assert!(refusal.contains("principal=session:fixture"));
        assert!(refusal.contains("phase=handler"));
        assert!(refusal.contains("cause=compiled_handler_failed"));
        assert!(refusal.contains("observation_ids="));
    }
}
