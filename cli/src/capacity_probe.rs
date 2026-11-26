//! Read subscription usage on the credential host. Only normalized capacity or fixed error
//! codes cross stdout. This command neither refreshes nor writes a credential.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
#[cfg(test)]
mod native;

use chrono::DateTime;
use serde_json::{Value, json};

const TIMEOUT: Duration = Duration::from_secs(5);
const CODEX_USAGE: &str = "https://chatgpt.com/backend-api/wham/usage";
const CLAUDE_USAGE: &str = "https://api.anthropic.com/api/oauth/usage";
const CLAUDE_PROFILE: &str = "https://api.anthropic.com/api/oauth/profile";
const CLAUDE_BETA: &str = "oauth-2025-04-20";

type ProbeResult = Result<Value, Value>;

pub(crate) fn probe(args: &[String]) -> Result<i32, String> {
    let [provider, path] = args else {
        return Err("usage: tightbeam capacity-probe <provider> <credential-path>".to_owned());
    };
    let result = match provider.as_str() {
        "openai" => read(path, codex_usage),
        "anthropic" => read(path, claude_usage),
        _ => return Err("capacity-probe does not support this provider".to_owned()),
    };
    let result = match result {
        Ok(sample) => json!({ "sample": sample }),
        Err(error) => json!({ "error": error }),
    };
    println!("{result}");
    Ok(0)
}

fn read(path: &str, usage: fn(&Value, &ureq::Agent) -> ProbeResult) -> ProbeResult {
    usage(&credential(path.as_ref())?, &usage_agent())
}

fn credential(path: &std::path::Path) -> ProbeResult {
    let raw = std::fs::read(path).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            error("CREDENTIAL_MISSING")
        } else {
            error("CREDENTIAL_UNREADABLE")
        }
    })?;
    serde_json::from_slice(&raw).map_err(|_| error("CREDENTIAL_REJECTED"))
}

fn usage_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(TIMEOUT)
        .build()
}

fn codex_usage(credential: &Value, agent: &ureq::Agent) -> ProbeResult {
    let tokens = &credential["tokens"];
    let access = required_string(&tokens["access_token"])?;
    let account = required_string(&tokens["account_id"])?;
    require_unexpired(codex_expiry(&tokens["access_token"]))?;

    let payload = request(
        agent
            .get(CODEX_USAGE)
            .set("Authorization", &format!("Bearer {access}"))
            .set("chatgpt-account-id", account),
    )?;
    let observed = now_ms();
    let mut sample = normalize_codex(&payload, observed)?;
    sample["subscription"] = codex_subscription(tokens["id_token"].as_str(), observed);
    Ok(sample)
}

fn codex_expiry(access: &Value) -> Option<i64> {
    jwt_claims(access.as_str()?)
        .and_then(|claims| claims["exp"].as_i64())
        .and_then(|expiry| expiry.checked_mul(1000))
}

fn claude_usage(credential: &Value, agent: &ureq::Agent) -> ProbeResult {
    claude_usage_at(credential, agent, CLAUDE_USAGE, CLAUDE_PROFILE)
}

fn claude_usage_at(
    credential: &Value,
    agent: &ureq::Agent,
    usage_url: &str,
    profile_url: &str,
) -> ProbeResult {
    let oauth = &credential["claudeAiOauth"];
    let access = required_string(&oauth["accessToken"])?;
    require_unexpired(oauth["expiresAt"].as_i64())?;
    if !oauth["scopes"]
        .as_array()
        .is_some_and(|scopes| scopes.iter().any(|scope| scope == "user:profile"))
    {
        return Err(error("TOKEN_SCOPE_INSUFFICIENT"));
    }

    let auth = format!("Bearer {access}");
    let payload = request(
        agent
            .get(usage_url)
            .set("Authorization", &auth)
            .set("anthropic-beta", CLAUDE_BETA),
    )?;
    let mut sample = normalize_claude(&payload, now_ms())?;
    let profile = request(agent.get(profile_url).set("Authorization", &auth));
    if let Err(error) = &profile {
        if error["code"] == "UPSTREAM_RATE_LIMITED" {
            sample["profileHold"] = error.clone();
        }
    }
    let (status, status_reason) = match profile {
        Ok(profile) => match field(&profile, "subscription_status") {
            Ok(Some(Value::String(status)))
                if matches!(status.as_str(), "active" | "lapsed" | "free") =>
            {
                (status, None)
            }
            Ok(None) => ("unknown".into(), Some("not_exposed_by_provider")),
            _ => ("unknown".into(), Some("unrecognized_value")),
        },
        Err(_) => ("unknown".into(), Some("read_failed")),
    };
    let (plan, plan_reason) = match &oauth["subscriptionType"] {
        Value::String(plan) if !plan.trim().is_empty() => (Some(plan), None),
        Value::Null => (None, Some("not_exposed_by_provider")),
        _ => (None, Some("unrecognized_value")),
    };
    sample["plan"] = json!(plan);
    sample["subscription"] = json!({
        "status": status,
        "statusReason": status_reason,
        "observedAt": if status_reason == Some("read_failed") { sample["observedAt"].as_i64() } else { Some(now_ms()) },
        "planUnknownReason": plan_reason,
        "periodEndUnknownReason": if status_reason == Some("read_failed") { "read_failed" } else { "not_yet_observed" }
    });
    Ok(sample)
}

fn required_string(value: &Value) -> Result<&str, Value> {
    value
        .as_str()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| error("CREDENTIAL_REJECTED"))
}

fn require_unexpired(expiry: Option<i64>) -> Result<(), Value> {
    match expiry {
        Some(expiry) if expiry > now_ms() => Ok(()),
        Some(_) => Err(error("CREDENTIAL_EXPIRED")),
        None => Err(error("CREDENTIAL_EXPIRY_UNKNOWN")),
    }
}

fn request(request: ureq::Request) -> ProbeResult {
    match request.call() {
        Ok(response) if response.status() / 100 == 2 => {
            serde_json::from_reader(response.into_reader())
                .map_err(|_| error("UPSTREAM_CONTRACT_CHANGED"))
        }
        Err(ureq::Error::Status(401 | 403, _)) => Err(error("CREDENTIAL_REJECTED")),
        Err(ureq::Error::Status(429, response)) => Err(json!({
            "code": "UPSTREAM_RATE_LIMITED",
            "retryAfterSeconds": retry_after(response.header("Retry-After"), now_ms())
        })),
        Err(ureq::Error::Transport(transport)) if transport.kind() == ureq::ErrorKind::Io => {
            if std::error::Error::source(&transport)
                .and_then(|source| source.downcast_ref::<std::io::Error>())
                .is_some_and(|io| io.kind() == std::io::ErrorKind::TimedOut)
            {
                Err(error("UPSTREAM_TIMEOUT"))
            } else {
                Err(error("UPSTREAM_UNAVAILABLE"))
            }
        }
        _ => Err(error("UPSTREAM_UNAVAILABLE")),
    }
}

fn retry_after(header: Option<&str>, now: i64) -> i64 {
    let header = header.unwrap_or_default().trim();
    if header.bytes().all(|byte| byte.is_ascii_digit()) {
        if let Ok(seconds) = header.parse::<i64>() {
            return seconds.clamp(1, i64::MAX / 1000);
        }
    }

    DateTime::parse_from_rfc2822(header)
        .ok()
        .map(|date| date.timestamp_millis().saturating_sub(now))
        .filter(|delay| *delay > 0)
        .map(|delay| (delay - 1) / 1000 + 1)
        .unwrap_or(60)
}

fn error(code: &str) -> Value {
    json!({ "code": code })
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn jwt_claims(token: &str) -> Option<Value> {
    let mut parts = token.split('.');
    let claims = parts.nth(1)?;
    parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    let decoded = URL_SAFE_NO_PAD.decode(claims).ok()?;
    let claims: Value = serde_json::from_slice(&decoded).ok()?;
    claims.is_object().then_some(claims)
}

fn field(document: &Value, name: &str) -> Result<Option<Value>, ()> {
    fn visit<'a>(value: &'a Value, name: &str, found: &mut Option<&'a Value>) -> Result<(), ()> {
        match value {
            Value::Object(object) => {
                if let Some(candidate) = object.get(name) {
                    if found.is_some_and(|previous| previous != candidate) {
                        return Err(());
                    }
                    *found = Some(candidate);
                }
                for child in object.values() {
                    visit(child, name, found)?;
                }
            }
            Value::Array(array) => {
                for child in array {
                    visit(child, name, found)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    let mut found = None;
    visit(document, name, &mut found)?;
    Ok(found.cloned())
}

fn provider_time(value: &Value) -> Option<i64> {
    if let Some(string) = value.as_str() {
        return DateTime::parse_from_rfc3339(string)
            .ok()
            .map(|date| date.timestamp_millis());
    }
    if let Some(integer) = value.as_i64() {
        return if integer.unsigned_abs() > 100_000_000_000 {
            Some(integer)
        } else {
            integer.checked_mul(1000)
        };
    }
    value.as_f64().map(|seconds| (seconds * 1000.0) as i64)
}

fn codex_subscription(identity: Option<&str>, observed: i64) -> Value {
    let claims = identity.and_then(jwt_claims);
    let statement_at = claims
        .as_ref()
        .and_then(|claims| {
            ["chatgpt_subscription_last_checked", "iat"]
                .into_iter()
                .find_map(|name| {
                    field(claims, name)
                        .ok()
                        .flatten()
                        .as_ref()
                        .and_then(provider_time)
                })
        })
        .unwrap_or(observed);
    let period_end = match &claims {
        Some(claims) => match field(claims, "chatgpt_subscription_active_until") {
            Ok(Some(value)) => provider_time(&value).ok_or("unrecognized_value"),
            Ok(None) => Err("not_exposed_by_provider"),
            Err(()) => Err("unrecognized_value"),
        },
        None if identity.is_none_or(|id| id.trim().is_empty()) => Err("not_yet_observed"),
        None => Err("unrecognized_value"),
    };
    match period_end {
        Ok(end) => json!({
            "status": "unknown", "observedAt": statement_at, "periodEndAt": end,
            "periodEndKind": if end < statement_at { "expires" } else { "unstated" }
        }),
        Err(reason) => json!({
            "status": "unknown", "observedAt": statement_at, "statusReason": reason,
            "periodEndUnknownReason": reason
        }),
    }
}

#[derive(Default)]
struct Windows {
    entries: Vec<Value>,
    omitted: usize,
}

impl Windows {
    fn add(&mut self, window: Option<Value>) {
        match window {
            Some(window) if !self.entries.iter().any(|entry| entry["id"] == window["id"]) => {
                self.entries.push(window);
            }
            _ => self.omitted += 1,
        }
    }

    fn sample(self, observed: i64, plan: Option<&str>, provider: &str) -> ProbeResult {
        if self.entries.is_empty() {
            return Err(error("UPSTREAM_CONTRACT_CHANGED"));
        }
        let code = format!("{}_USAGE_WINDOW_OMITTED", provider.to_ascii_uppercase());
        let message = match provider {
            "codex" => "Codex omitted an invalid or unrecognized usage window.",
            _ => "Claude omitted an invalid or unrecognized usage window.",
        };
        let diagnostic = json!({"code": code, "message": message});
        Ok(json!({
            "plan": plan, "observedAt": observed, "windows": self.entries,
            "diagnostics": vec![diagnostic; self.omitted]
        }))
    }
}

fn window(
    id: &str,
    name: &str,
    scope: &str,
    model: Option<&str>,
    used: &Value,
    reset: Option<i64>,
    seconds: Option<i64>,
) -> Option<Value> {
    let used = used.as_f64().filter(|used| (0.0..=100.0).contains(used))?;
    Some(json!({
        "id": id, "name": name, "scope": scope, "model": model, "usedPercent": used,
        "resetsAt": reset, "windowSeconds": seconds
    }))
}

fn codex_window(
    id: &str,
    name: &str,
    value: &Value,
    observed: i64,
    additional: bool,
) -> Option<Value> {
    for key in ["reset_at", "reset_after_seconds", "limit_window_seconds"] {
        if !value[key].is_null() && value[key].as_i64().is_none() {
            return None;
        }
    }
    let reset = match value["reset_at"].as_i64() {
        Some(seconds) => Some(seconds.checked_mul(1000)?),
        None => None,
    };
    let reset_after = if reset.is_none() {
        value["reset_after_seconds"].as_i64()
    } else {
        None
    };
    let model = additional.then_some(name);
    let mut normalized = window(
        id,
        name,
        if additional { "model" } else { "account" },
        model,
        &value["used_percent"],
        reset,
        value["limit_window_seconds"].as_i64(),
    )?;

    if let Some(delay) = reset_after {
        observed.checked_add(delay.checked_mul(1000)?)?;
        normalized["resetAfterSeconds"] = json!(delay);
    }
    Some(normalized)
}

const CODEX_WINDOWS: [(&str, &str, &str); 2] = [
    ("primary_window", "primary", "Primary"),
    ("secondary_window", "secondary", "Secondary"),
];

// Convert the app-server's bounded, on-host reply into the same window mapping
// as the read-only endpoint. The caller can fall back to HTTPS if the version
// cannot describe a bucket without inventing an ID or plan.
fn normalize_codex_app_server(doc: &Value, account: &Value, observed: i64) -> ProbeResult {
    let main = doc["rateLimits"]
        .as_object()
        .ok_or_else(|| error("UPSTREAM_CONTRACT_CHANGED"))?;
    let plan = main
        .get("planType")
        .and_then(Value::as_str)
        .or_else(|| account["account"]["planType"].as_str());
    let mut additional = Vec::new();

    if let Some(buckets) = doc["rateLimitsByLimitId"].as_object() {
        let primary_id = main
            .get("limitId")
            .and_then(Value::as_str)
            .unwrap_or("codex");
        for (id, bucket) in buckets {
            if id != primary_id {
                let name = bucket["limitName"]
                    .as_str()
                    .filter(|name| !slug(name).is_empty())
                    .ok_or_else(|| error("UPSTREAM_CONTRACT_CHANGED"))?;
                additional.push(
                    json!({ "limit_name": name, "rate_limit": native_codex_windows(bucket)? }),
                );
            }
        }
    }

    normalize_codex(
        &json!({
            "plan_type": plan,
            "rate_limit": native_codex_windows(&doc["rateLimits"])?,
            "additional_rate_limits": additional
        }),
        observed,
    )
}

fn native_codex_windows(bucket: &Value) -> ProbeResult {
    let mut windows = serde_json::Map::new();
    for (source, target) in [
        ("primary", "primary_window"),
        ("secondary", "secondary_window"),
    ] {
        let window = &bucket[source];
        if !window.is_null() {
            let seconds = match &window["windowDurationMins"] {
                Value::Null => None,
                minutes => Some(
                    minutes
                        .as_i64()
                        .and_then(|value| value.checked_mul(60))
                        .ok_or_else(|| error("UPSTREAM_CONTRACT_CHANGED"))?,
                ),
            };
            windows.insert(
                target.into(),
                json!({
                    "used_percent": window["usedPercent"],
                    "reset_at": window["resetsAt"],
                    "limit_window_seconds": seconds
                }),
            );
        }
    }
    Ok(Value::Object(windows))
}

fn normalize_codex(doc: &Value, observed: i64) -> ProbeResult {
    if !doc.is_object() || (!doc["plan_type"].is_null() && !doc["plan_type"].is_string()) {
        return Err(error("UPSTREAM_CONTRACT_CHANGED"));
    }
    let mut windows = Windows::default();
    if let Some(main) = doc.get("rate_limit") {
        if !main.is_object() {
            windows.omitted += 1;
        } else {
            for (key, id, name) in CODEX_WINDOWS {
                if !main[key].is_null() {
                    windows.add(codex_window(id, name, &main[key], observed, false));
                }
            }
        }
    }
    match doc.get("additional_rate_limits") {
        Some(Value::Array(entries)) => {
            let mut candidates: Vec<_> = entries.iter().enumerate().collect();
            candidates.sort_by_key(|(_, entry)| additional_name(entry));
            for (position, entry) in candidates {
                add_codex_limit(&mut windows, entry, position + 1, observed);
            }
        }
        Some(_) => windows.omitted += 1,
        None => {}
    }
    windows.sample(observed, doc["plan_type"].as_str(), "codex")
}

fn additional_name(entry: &Value) -> &str {
    let limit = &entry["rate_limit"];
    if CODEX_WINDOWS
        .iter()
        .any(|(key, _, _)| limit.get(key).is_some())
    {
        entry["limit_name"].as_str().unwrap_or_default()
    } else {
        entry["name"].as_str().unwrap_or_default()
    }
}

fn add_codex_limit(windows: &mut Windows, entry: &Value, position: usize, observed: i64) {
    let Some(limit) = entry.get("rate_limit") else {
        windows.omitted += 1;
        return;
    };
    if limit.is_null() {
        return;
    }
    if !limit.is_object()
        || ["name", "limit_name"]
            .iter()
            .any(|key| !entry[key].is_null() && !entry[key].is_string())
    {
        windows.omitted += 1;
        return;
    }
    let name = additional_name(entry);
    let slug = slug(name);
    let (id, display) = if slug.is_empty() {
        (
            format!("additional:unnamed:{position}"),
            format!("Unnamed additional limit {position}"),
        )
    } else {
        (format!("additional:{slug}"), name.to_owned())
    };
    if CODEX_WINDOWS
        .iter()
        .any(|(key, _, _)| limit.get(key).is_some())
    {
        for (key, suffix, label) in CODEX_WINDOWS {
            if !limit[key].is_null() {
                let mut parsed = codex_window(
                    &format!("{id}:{suffix}"),
                    &format!("{display} {label}"),
                    &limit[key],
                    observed,
                    true,
                );
                if let Some(window) = &mut parsed {
                    window["model"] = json!(if slug.is_empty() { None } else { Some(name) });
                }
                windows.add(parsed);
            }
        }
    } else {
        let mut parsed = codex_window(&id, &display, limit, observed, true);
        if let Some(window) = &mut parsed {
            window["model"] = json!(if slug.is_empty() { None } else { Some(name) });
        }
        windows.add(parsed);
    }
}

fn slug(name: &str) -> String {
    name.to_ascii_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

fn claude_window(
    id: &str,
    name: &str,
    model: Option<&str>,
    value: &Value,
    percent_field: &str,
    seconds: Option<i64>,
) -> Option<Value> {
    let reset = if value["resets_at"].is_null() {
        None
    } else {
        Some(
            DateTime::parse_from_rfc3339(value["resets_at"].as_str()?)
                .ok()?
                .timestamp_millis(),
        )
    };
    window(
        id,
        name,
        if model.is_some() { "model" } else { "account" },
        model,
        &value[percent_field],
        reset,
        seconds,
    )
}

fn normalize_claude(doc: &Value, observed: i64) -> ProbeResult {
    if !doc.is_object() {
        return Err(error("UPSTREAM_CONTRACT_CHANGED"));
    }
    let mut windows = Windows::default();
    for (id, name, model, seconds) in [
        ("five_hour", "Five hour", None, 18_000),
        ("seven_day", "Seven day", None, 604_800),
        (
            "seven_day_sonnet",
            "Seven day Sonnet",
            Some("sonnet"),
            604_800,
        ),
    ] {
        if !doc[id].is_null() {
            windows.add(claude_window(
                id,
                name,
                model,
                &doc[id],
                "utilization",
                Some(seconds),
            ));
        }
    }
    match doc.get("limits") {
        Some(Value::Object(limits)) => {
            for (key, value) in limits {
                let id = format!("limit:{}", key.replace('/', ":"));
                windows.add(claude_window(
                    &id,
                    key,
                    Some(key),
                    value,
                    "utilization",
                    None,
                ));
            }
        }
        Some(Value::Array(limits)) => {
            for entry in limits {
                let model = &entry["scope"]["model"];
                let identity = model["id"]
                    .as_str()
                    .or_else(|| model["display_name"].as_str());
                let name = model["display_name"].as_str().or(identity);
                let parsed = identity.zip(name).and_then(|(identity, name)| {
                    let id = format!("limit:{}", identity.replace('/', ":"));
                    claude_window(&id, name, Some(identity), entry, "percent", None)
                });
                windows.add(parsed);
            }
        }
        Some(_) => windows.omitted += 1,
        None => {}
    }
    windows.sample(observed, None, "claude")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_keeps_window_identity_and_drops_upstream_fields() {
        let doc = json!({
            "plan_type": "pro",
            "account_id": "upstream-private-id",
            "rate_limit": {
                "primary_window": { "used_percent": 42, "reset_after_seconds": 60, "limit_window_seconds": 18000 },
                "secondary_window": { "used_percent": 101 }
            },
            "additional_rate_limits": [
                {"limit_name": "GPT Extra", "rate_limit": {"primary_window": {"used_percent": 20, "reset_at": 20}}},
                {"name": "GPT Extra", "rate_limit": {"used_percent": 15}},
                {"name": "GPT Extra", "rate_limit": {"used_percent": 18}}
            ]
        });
        let sample = normalize_codex(&doc, 1000).unwrap();
        assert_eq!(sample["plan"], "pro");
        assert_eq!(
            sample["windows"],
            json!([
                {"id":"primary","name":"Primary","scope":"account","model":null,"usedPercent":42.0,"resetsAt":null,"resetAfterSeconds":60,"windowSeconds":18000},
                {"id":"additional:gpt-extra:primary","name":"GPT Extra Primary","scope":"model","model":"GPT Extra","usedPercent":20.0,"resetsAt":20000,"windowSeconds":null},
                {"id":"additional:gpt-extra","name":"GPT Extra","scope":"model","model":"GPT Extra","usedPercent":15.0,"resetsAt":null,"windowSeconds":null}
            ])
        );
        assert_eq!(sample["diagnostics"].as_array().unwrap().len(), 2);
        assert!(!sample.to_string().contains("upstream-private-id"));
    }

    #[test]
    fn codex_app_server_shares_http_window_ids_and_units() {
        let primary = json!({"usedPercent":42, "windowDurationMins":300, "resetsAt":1795538965});
        let result = json!({
            "rateLimits":{"limitId":"codex", "primary":primary},
            "rateLimitsByLimitId":{
                "codex":{"limitId":"codex", "primary":primary},
                "metered":{"limitId":"metered", "limitName":"GPT Extra",
                           "secondary":{"usedPercent":65, "windowDurationMins":10080, "resetsAt":null}}
            }
        });
        let account = json!({"account":{"planType":"pro", "email":"private-fixture"}});
        let sample = normalize_codex_app_server(&result, &account, 1000).unwrap();
        assert_eq!(sample["plan"], "pro");
        assert_eq!(
            sample["windows"],
            json!([
                {"id":"primary", "name":"Primary", "scope":"account", "model":null, "usedPercent":42.0, "windowSeconds":18000, "resetsAt":1795538965000i64},
                {"id":"additional:gpt-extra:secondary", "name":"GPT Extra Secondary", "scope":"model", "model":"GPT Extra", "usedPercent":65.0, "windowSeconds":604800, "resetsAt":null}
            ])
        );
        assert!(!sample.to_string().contains("private-fixture"));
    }

    #[test]
    fn claude_array_scope_and_omissions() {
        let doc = json!({
            "five_hour": {"utilization": 0.25},
            "seven_day": {"utilization": 0},
            "limits": [
                {"percent": 25, "scope": {"model": {"id": "model-1", "display_name": "Model one"}}},
                {"percent": 85, "scope": null}
            ]
        });
        let sample = normalize_claude(&doc, 1000).unwrap();
        assert_eq!(sample["windows"][0]["usedPercent"], 0.25);
        assert_eq!(sample["windows"][1]["usedPercent"], 0.0);
        assert_eq!(
            sample["windows"][2],
            json!({
                "id":"limit:model-1","name":"Model one","scope":"model","model":"model-1",
                "usedPercent":25.0,"resetsAt":null,"windowSeconds":null
            })
        );
        assert_eq!(sample["diagnostics"].as_array().unwrap().len(), 1);
        assert_eq!(
            normalize_claude(&json!({"five_hour":{"utilization":null}}), 1000),
            Err(error("UPSTREAM_CONTRACT_CHANGED"))
        );
        check_pinned_lachesis_usage_fixtures();
    }

    #[test]
    fn claude_profile_rate_limit_keeps_usage_and_retry_after() {
        use std::io::{BufRead, BufReader, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            for (path, response) in [
                (
                    "/usage",
                    "200 OK\r\nConnection: close\r\nContent-Length: 32\r\n\r\n{\"five_hour\":{\"utilization\":42}}",
                ),
                (
                    "/profile",
                    "429 Too Many Requests\r\nRetry-After: 3600\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
                ),
            ] {
                let (mut stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(&mut stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                assert_eq!(line, format!("GET {path} HTTP/1.1\r\n"));
                loop {
                    line.clear();
                    if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                        break;
                    }
                }
                write!(stream, "HTTP/1.1 {response}").unwrap();
            }
        });
        let credentials = json!({"claudeAiOauth":{
            "accessToken":"synthetic-access", "expiresAt":now_ms() + 60_000, "scopes":["user:profile"]
        }});
        let agent = ureq::AgentBuilder::new().timeout(TIMEOUT).build();
        let sample = claude_usage_at(
            &credentials,
            &agent,
            &format!("{base}/usage"),
            &format!("{base}/profile"),
        )
        .unwrap();
        server.join().unwrap();

        assert_eq!(sample["windows"][0]["usedPercent"], 42.0);
        assert_eq!(sample["subscription"]["statusReason"], "read_failed");
        assert_eq!(
            sample["profileHold"],
            json!({"code":"UPSTREAM_RATE_LIMITED","retryAfterSeconds":3600})
        );
    }

    #[test]
    fn retry_after_is_honored_for_duration_and_http_date() {
        assert_eq!(retry_after(Some("0"), 0), 1);
        assert_eq!(retry_after(Some("97"), 0), 97);
        assert_eq!(
            retry_after(Some("Thu, 01 Jan 1970 00:02:00 GMT"), 60_001),
            60
        );
        assert_eq!(retry_after(Some("invalid"), 0), 60);
    }

    fn check_pinned_lachesis_usage_fixtures() {
        let Ok(root) = std::env::var("LACHESIS_FIXTURE_DIR") else {
            return; // The pinned upstream checkout is provided by the parity verification run.
        };
        for (name, expected_diagnostics, expected_windows) in [
            ("claude-usage-sanitized-real.json", 2, 3),
            ("claude-usage-current-schema-sanitized-real.json", 2, 3),
        ] {
            let path = std::path::Path::new(&root).join(name);
            let doc: Value = serde_json::from_reader(std::fs::File::open(path).unwrap()).unwrap();
            let sample = normalize_claude(&doc["response"], 1_800_000_000_000).unwrap();
            let windows = sample["windows"].as_array().unwrap();
            assert_eq!(windows.len(), expected_windows, "{name}");
            for id in ["five_hour", "seven_day"] {
                let window = windows.iter().find(|window| window["id"] == id).unwrap();
                assert_eq!(
                    window["usedPercent"].as_f64(),
                    doc["response"][id]["utilization"].as_f64()
                );
                assert_eq!(
                    window["resetsAt"].as_i64(),
                    doc["response"][id]["resets_at"]
                        .as_str()
                        .map(|_| 946_684_800_000i64)
                );
                assert_eq!(window["scope"], "account");
            }
            assert_eq!(
                sample["diagnostics"].as_array().unwrap().len(),
                expected_diagnostics,
                "{name}"
            );
        }
    }
}
