use crate::dispatch::{self, Endpoint};
use crate::session_connect::ReadSelection;
use serde_json::Value;
use std::fmt::Write as _;
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
enum ReadError {
    Transport,
    InvalidJson,
    Http { status: u16, body: Value },
}

fn read_json(
    endpoint: &Endpoint,
    selection: &ReadSelection,
    path: &str,
) -> Result<Value, ReadError> {
    let path = selection.request_path(path);
    let request = dispatch::gateway_request("GET", endpoint, &path, Some(Duration::from_secs(15)));
    let response = match request.call() {
        Ok(response) | Err(ureq::Error::Status(_, response)) => response,
        Err(ureq::Error::Transport(_)) => return Err(ReadError::Transport),
    };
    let status = response.status();
    let body = response.into_string().map_err(|_| ReadError::Transport)?;
    let parsed = serde_json::from_str::<Value>(&body);
    if !(200..300).contains(&status) {
        return Err(ReadError::Http {
            status,
            body: parsed.unwrap_or(Value::Null),
        });
    }
    parsed.map_err(|_| ReadError::InvalidJson)
}

fn scalar(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(boolean) => boolean.to_string(),
        _ => "unknown".into(),
    }
}

fn with_reason(value: &Value, reason: &Value) -> String {
    match reason.as_str() {
        Some(reason) if !reason.is_empty() => format!("{} ({reason})", scalar(value)),
        _ => scalar(value),
    }
}

fn percent(value: &Value) -> String {
    value
        .as_f64()
        .map_or_else(|| "unknown".into(), |number| format!("{number:.1}%"))
}

fn reset_time(value: &Value) -> String {
    value.as_i64().map_or_else(
        || "unknown".into(),
        |epoch_ms| format!("{epoch_ms} ms since Unix epoch"),
    )
}

fn capacity_usage(value: &Value) -> String {
    match value["results"].as_array() {
        Some(results) if results.is_empty() => "No provider accounts.\n".into(),
        Some(results) => results
            .iter()
            .map(usage_result)
            .collect::<Vec<_>>()
            .join("\n"),
        None => usage_result(value),
    }
}

fn usage_result(result: &Value) -> String {
    let summary = &result["summary"];
    let sample = &result["sample"];
    let label = summary["label"]
        .as_str()
        .or_else(|| sample["label"].as_str())
        .unwrap_or("Unknown account");
    let mut output = format!("{label} ({})", scalar(&result["accountId"]));
    if sample["serving"] == true {
        output.push_str(" [serving]");
    }
    output.push('\n');
    let _ = writeln!(
        output,
        "  Provider: {}  Login: {}  Plan: {}",
        scalar(&summary["provider"]),
        with_reason(&summary["accountState"], &summary["accountStateReason"]),
        with_reason(&summary["plan"], &summary["planUnknownReason"]),
    );
    let _ = writeln!(
        output,
        "  Subscription: {}  Period end: {}",
        with_reason(
            &summary["subscriptionStatus"],
            &summary["subscriptionStatusReason"]
        ),
        with_reason(
            &Value::String(reset_time(&summary["subscriptionPeriodEndAt"])),
            &summary["subscriptionPeriodEndUnknownReason"],
        ),
    );
    let _ = writeln!(
        output,
        "  Reading: {}  Age (seconds): {}",
        with_reason(&summary["usageFreshness"], &summary["usageFreshnessReason"]),
        scalar(&summary["usageAgeSeconds"]),
    );
    if let Some(windows) = sample["windows"].as_array() {
        for window in windows {
            let remaining = window["usedPercent"].as_f64().map_or(Value::Null, |used| {
                Value::from((100.0 - used).clamp(0.0, 100.0))
            });
            let _ = writeln!(
                output,
                "  {}: {} used, {} remaining, reset {}",
                scalar(&window["name"]),
                percent(&window["usedPercent"]),
                percent(&remaining),
                reset_time(&window["resetsAt"]),
            );
        }
    }
    if let Some(code) = result.pointer("/error/code").and_then(Value::as_str) {
        let _ = writeln!(output, "  Reading error: {code}");
    }
    output
}

fn format_snapshot(value: &Value, json: bool) -> String {
    if json {
        format!("{value}\n")
    } else {
        capacity_usage(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args::Identity;
    use crate::dispatch::Origin;
    use std::io::{BufRead, BufReader, Write as _};
    use std::net::TcpListener;

    const CAPACITY: &str = include_str!("../tests/fixtures/capacity_snapshot.json");

    #[test]
    fn capacity_fixture_preserves_rest_body_and_exposes_unknowns() {
        let response: Value = serde_json::from_str(CAPACITY).unwrap();
        let json = format_snapshot(&response, true);
        assert_eq!(json.lines().count(), 1);
        assert_eq!(serde_json::from_str::<Value>(&json).unwrap(), response);

        let text = format_snapshot(&response, false);
        for expected in [
            "Primary login (acct_primary) [serving]",
            "32.5% used, 67.5% remaining, reset 1795540000000 ms since Unix epoch",
            "Unknown period login (acct_secondary)",
            "unknown (not_reported)",
            "none (never_observed)",
            "Reading error: CREDENTIAL_MISSING",
        ] {
            assert!(text.contains(expected), "missing {expected}:\n{text}");
        }
        assert!(!text.contains("0.0% used"));
    }

    #[test]
    fn capacity_rest_uses_gateway_auth_and_preserves_body_and_error() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = Endpoint {
            base: format!("http://{}", listener.local_addr().unwrap()),
            token: "tbc_synthetic".into(),
            origin: Origin::Named,
        };
        let server = std::thread::spawn(move || {
            for (status, payload) in [
                ("200 OK", CAPACITY),
                (
                    "403 Forbidden",
                    r#"{"error":{"code":"forbidden","message":"not visible"}}"#,
                ),
            ] {
                let (mut socket, _) = listener.accept().unwrap();
                let request: Vec<_> = BufReader::new(&socket)
                    .lines()
                    .map(Result::unwrap)
                    .take_while(|line| !line.is_empty())
                    .collect();
                assert_eq!(
                    request[0],
                    "GET /fixture?mode=test&asUser=read%20selector HTTP/1.1"
                );
                assert!(
                    request.iter().any(
                        |line| line.eq_ignore_ascii_case("authorization: Bearer tbc_synthetic")
                    )
                );
                assert!(request.iter().any(|line| {
                    line.to_ascii_lowercase()
                        .starts_with("x-tightbeam-cli-version:")
                }));
                write!(
                    socket,
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                    payload.len(),
                ).unwrap();
            }
        });
        let selection =
            ReadSelection::for_invocation(&endpoint, &Identity::User("read selector".into()));
        let fixture: Value = serde_json::from_str(CAPACITY).unwrap();
        assert_eq!(
            read_json(&endpoint, &selection, "/fixture?mode=test"),
            Ok(fixture),
        );
        assert_eq!(
            read_json(&endpoint, &selection, "/fixture?mode=test"),
            Err(ReadError::Http {
                status: 403,
                body: serde_json::json!({"error":{"code":"forbidden","message":"not visible"}}),
            }),
        );
        server.join().unwrap();
    }
}
