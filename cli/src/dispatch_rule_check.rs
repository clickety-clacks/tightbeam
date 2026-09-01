use std::collections::HashSet;
use std::io::Read;

use serde::Deserialize;
use serde::de::{MapAccess, SeqAccess, Visitor};
use serde_json::Value;

use crate::dispatch::{Origin, RequestSpec};

const RULE: &str = "github-network-auth-required";
const HANDLER: &str = "github-network-auth-v1";

#[derive(Debug, Clone, PartialEq, Eq)]
struct Args {
    rule: String,
    handler: String,
    abi: u64,
    identity_sha: String,
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
    pub(crate) command: String,
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
    let args = parse_args(raw_args)?;
    let endpoint = authenticated_session_endpoint()?;
    let context = authenticate_context(&endpoint, &args)?;

    let mut raw = Vec::new();
    std::io::stdin()
        .read_to_end(&mut raw)
        .map_err(|_| runtime_failure(&context))?;

    let input = match normalize(&raw, args.abi) {
        Ok(input) => input,
        Err(cause) => {
            observe_malformed(&endpoint, &args, &context, cause)?;
            return Err(format!(
                "[gate: {RULE}] state=malformed_tool_call machine={} profile=none hostname=none phase=normalization cause={} principal={} repair=tightbeam doctor --json",
                context.machine,
                cause.as_str(),
                context.principal
            ));
        }
    };

    crate::github_auth::check_compiled_rule(
        &endpoint,
        &args.identity_sha,
        &context.machine,
        &context.principal,
        &input.command,
    )
}

fn parse_args(raw: &[String]) -> Result<Args, String> {
    let mut rule = None;
    let mut handler = None;
    let mut abi = None;
    let mut identity_sha = None;
    let mut index = 0;

    while index < raw.len() {
        let slot = match raw[index].as_str() {
            "--rule" => &mut rule,
            "--handler" => &mut handler,
            "--identity-sha" => &mut identity_sha,
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

    let parsed = Args {
        rule: rule.ok_or_else(invalid_invocation)?,
        handler: handler.ok_or_else(invalid_invocation)?,
        abi: abi.ok_or_else(invalid_invocation)?,
        identity_sha: identity_sha.ok_or_else(invalid_invocation)?,
    };

    if parsed.rule != RULE || parsed.handler != HANDLER || parsed.abi != 1 {
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
        return Err(runtime_failure(&context));
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

fn runtime_failure(context: &Context) -> String {
    format!(
        "[gate: {RULE}] state=rule_runtime_failure machine={} profile=none hostname=none phase=authentication cause=authenticated_context_failure principal={} repair=tightbeam doctor --json",
        context.machine, context.principal
    )
}

fn observe_malformed(
    endpoint: &crate::dispatch::Endpoint,
    args: &Args,
    context: &Context,
    cause: MalformedToolCallCauseV1,
) -> Result<(), String> {
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
        .map(|_| ())
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
                command: " echo  x\n".to_owned()
            })
        );
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
}
