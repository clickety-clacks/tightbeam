use crate::args::{AccountAction, CapacityAction, Identity};
use crate::dispatch::{self, Endpoint};
use crate::session_connect::{ReadSelection, encode_path, set_read_timeout, websocket_url};
use serde_json::{Value, json};
use std::fmt::Write as _;
use std::io::{self, Write};
use std::net::TcpStream;
use std::time::Duration;
use tungstenite::{Message, WebSocket, stream::MaybeTlsStream};

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

impl std::fmt::Display for ReadError {
    fn fmt(&self, output: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport => output.write_str("gateway connection lost while reading"),
            Self::InvalidJson => output.write_str("gateway response was not valid JSON"),
            Self::Http { status, body } => {
                write!(output, "gateway HTTP {status}")?;
                if let Some(code) = body.pointer("/error/code").and_then(Value::as_str) {
                    write!(output, " {code}")?;
                }
                if let Some(message) = body.pointer("/error/message").and_then(Value::as_str) {
                    write!(output, ": {message}")?;
                }
                Ok(())
            }
        }
    }
}

fn usage_path(account: Option<&str>) -> String {
    match account {
        Some(id) => format!("/api/capacity/{}", encode_path(id)),
        None => "/api/capacity".into(),
    }
}

fn capacity_path(action: &CapacityAction) -> String {
    match action {
        CapacityAction::Show { account, refresh } => {
            let mut path = usage_path(account.as_deref());
            if *refresh {
                path.push_str("?refresh=wait");
            }
            path
        }
        CapacityAction::History { account } => format!("{}/history", usage_path(Some(account))),
        CapacityAction::Forecast { account } => {
            format!("{}/forecast", usage_path(account.as_deref()))
        }
        CapacityAction::Health => "/api/capacity/health".into(),
        CapacityAction::Watch { account } => {
            format!("{}?refresh=cache", usage_path(account.as_deref()))
        }
    }
}

pub(crate) fn run_accounts(
    endpoint: &Endpoint,
    identity: &Identity,
    action: &AccountAction,
    json: bool,
) -> Result<(), String> {
    let path = match action {
        AccountAction::List => "/api/accounts".into(),
        AccountAction::Show(account) => format!("/api/accounts/{}", encode_path(account)),
        _ => return Err("account mutations use dispatch".into()),
    };
    let selection = ReadSelection::for_invocation(endpoint, identity);
    let body = read_json(endpoint, &selection, &path).map_err(|error| error.to_string())?;
    let output = if json {
        format!("{body}\n")
    } else if let Some(accounts) = body["accounts"]
        .as_array()
        .or_else(|| body["items"].as_array())
    {
        if accounts.is_empty() {
            "No provider accounts.\n".into()
        } else {
            accounts.iter().map(account_summary).collect()
        }
    } else {
        account_summary(body.get("account").unwrap_or(&body))
    };
    emit(&output)
}

pub(crate) fn run_capacity(
    endpoint: &Endpoint,
    identity: &Identity,
    action: &CapacityAction,
    json: bool,
) -> Result<(), String> {
    let selection = ReadSelection::for_invocation(endpoint, identity);
    let path = capacity_path(action);
    if let CapacityAction::Watch { account } = action {
        return watch(endpoint, &selection, &path, account.as_deref(), |body| {
            emit(&format_capacity(action, body, json))
        });
    }
    let body = read_json(endpoint, &selection, &path).map_err(|error| error.to_string())?;
    emit(&format_capacity(action, &body, json))
}

fn emit(text: &str) -> Result<(), String> {
    let mut output = io::stdout().lock();
    output
        .write_all(text.as_bytes())
        .and_then(|()| output.flush())
        .map_err(|error| error.to_string())
}

const SUBSCRIPTION_ID: &str = "capacity-watch";
const PROTOCOL: u64 = 2;
const WATCH_CLASSES: &[&str] = &[
    "capacity.changed",
    "provider_account.changed",
    "provider_account.removed",
    "account_serving.changed",
    "account_limit.changed",
];

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

enum WatchError {
    Reconnect,
    Stop(String),
}

fn next_frame(socket: &mut Socket) -> Result<Value, WatchError> {
    loop {
        match socket.read() {
            Ok(Message::Text(text)) => {
                return serde_json::from_str(&text).map_err(|_| WatchError::Reconnect);
            }
            Ok(Message::Ping(_)) => socket.flush().map_err(|_| WatchError::Reconnect)?,
            Ok(Message::Close(Some(frame))) if u16::from(frame.code) == 1008 => {
                return Err(WatchError::Stop(
                    "Firehose authorization was revoked".into(),
                ));
            }
            Ok(Message::Close(_) | Message::Binary(_)) | Err(_) => {
                return Err(WatchError::Reconnect);
            }
            Ok(_) => {}
        }
    }
}

fn open_watch(
    endpoint: &Endpoint,
    selection: &ReadSelection,
    account: Option<&str>,
) -> Result<Socket, WatchError> {
    let url = websocket_url(&endpoint.base, PROTOCOL);
    let (mut socket, _) = tungstenite::connect(url.as_str()).map_err(|error| {
        if let tungstenite::Error::Http(response) = error {
            match response.status().as_u16() {
                401 | 403 | 404 | 426 => {
                    return WatchError::Stop(format!(
                        "Firehose refused capacity watch (HTTP {})",
                        response.status().as_u16()
                    ));
                }
                _ => {}
            }
        }
        WatchError::Reconnect
    })?;
    set_read_timeout(socket.get_mut(), Some(Duration::from_secs(45)))
        .map_err(|_| WatchError::Reconnect)?;
    socket
        .send(Message::Text(
            selection.auth_frame(&endpoint.token).to_string(),
        ))
        .map_err(|_| WatchError::Reconnect)?;
    let auth = next_frame(&mut socket)?;
    if auth["type"] != "auth_result" || auth["success"] != true || auth["isAdmin"] != true {
        return Err(WatchError::Stop(
            "capacity watch requires an administrator credential".into(),
        ));
    }

    let mut filters = json!({"classes": WATCH_CLASSES});
    if let Some(account) = account {
        filters["accountId"] = json!(account);
    }
    socket
        .send(Message::Text(
            json!({
                "type": "subscribe", "protocolVersion": PROTOCOL,
                "subscriptionId": SUBSCRIPTION_ID, "filters": filters,
            })
            .to_string(),
        ))
        .map_err(|_| WatchError::Reconnect)?;
    loop {
        let frame = next_frame(&mut socket)?;
        match frame["type"].as_str() {
            Some("subscription_ready") if frame["subscriptionId"] == SUBSCRIPTION_ID => {
                return Ok(socket);
            }
            Some("heartbeat") => {}
            Some("reload_required") => return Err(WatchError::Reconnect),
            _ => {
                return Err(WatchError::Stop(
                    "Firehose did not accept the capacity subscription".into(),
                ));
            }
        }
    }
}

fn watch(
    endpoint: &Endpoint,
    selection: &ReadSelection,
    path: &str,
    account: Option<&str>,
    mut output: impl FnMut(&Value) -> Result<(), String>,
) -> Result<(), String> {
    let mut backoff = Duration::from_millis(250);
    loop {
        let cycle = (|| {
            let mut socket = open_watch(endpoint, selection, account)?;
            let mut seq = 0_u64;
            loop {
                // The socket is already subscribed. Arrivals during the read stay
                // queued on that connection and are handled after its snapshot.
                let body = read_json(endpoint, selection, path).map_err(|error| match error {
                    ReadError::Transport
                    | ReadError::Http {
                        status: 500..=599, ..
                    } => WatchError::Reconnect,
                    error => WatchError::Stop(error.to_string()),
                })?;
                output(&body).map_err(WatchError::Stop)?;
                backoff = Duration::from_millis(250);

                loop {
                    let frame = next_frame(&mut socket)?;
                    match frame["type"].as_str() {
                        Some("reload_required") => return Err(WatchError::Reconnect),
                        Some("heartbeat") if frame["seq"].as_u64() != Some(seq) => {
                            return Err(WatchError::Reconnect);
                        }
                        Some("change") => {
                            if frame["seq"].as_u64() != seq.checked_add(1) {
                                return Err(WatchError::Reconnect);
                            }
                            if frame["schemaVersion"].as_u64() != Some(PROTOCOL)
                                || frame["subscriptionId"] != SUBSCRIPTION_ID
                            {
                                return Err(WatchError::Stop(
                                    "incompatible Firehose change envelope".into(),
                                ));
                            }
                            seq += 1;
                            if frame["class"]
                                .as_str()
                                .is_some_and(|class| WATCH_CLASSES.contains(&class))
                            {
                                break;
                            }
                        }
                        _ => {}
                    }
                }
            }
        })();
        match cycle {
            Err(WatchError::Stop(error)) => return Err(error),
            Err(WatchError::Reconnect) => {
                std::thread::sleep(backoff);
                backoff = (backoff * 2).min(Duration::from_secs(5));
            }
            Ok(()) => return Ok(()),
        }
    }
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

fn account_summary(account: &Value) -> String {
    let mut output = format!(
        "{} ({}) · {} on {}",
        scalar(&account["label"]),
        scalar(&account["id"]),
        scalar(&account["harness"]),
        scalar(&account["host"]),
    );
    if account["serving"] == true {
        output.push_str(" [serving]");
    }
    let _ = writeln!(
        output,
        "\n  Login: {}  Enabled: {}",
        with_reason(&account["loginState"], &account["loginReason"]),
        scalar(&account["enabled"]),
    );
    output
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
    write_usage_windows(&mut output, &sample["windows"]);
    if let Some(code) = result.pointer("/error/code").and_then(Value::as_str) {
        let _ = writeln!(output, "  Reading error: {code}");
    }
    output
}

fn write_usage_windows(output: &mut String, windows: &Value) {
    for window in windows.as_array().into_iter().flatten() {
        let remaining = window["usedPercent"].as_f64().map_or(Value::Null, |used| {
            Value::from((100.0 - used).clamp(0.0, 100.0))
        });
        let _ = write!(
            output,
            "  {}: {} used, {} remaining, reset {}",
            scalar(&window["name"]),
            percent(&window["usedPercent"]),
            percent(&remaining),
            reset_time(&window["resetsAt"]),
        );
        if let Some(model) = window["model"].as_str() {
            let _ = write!(output, " (model: {model})");
        }
        output.push('\n');
    }
}

fn capacity_history(value: &Value) -> String {
    let mut output = format!("History for {}\n", scalar(&value["accountId"]));
    match value["samples"].as_array() {
        Some(samples) if !samples.is_empty() => {
            for sample in samples {
                let _ = writeln!(output, "{}", reset_time(&sample["observedAt"]));
                write_usage_windows(&mut output, &sample["windows"]);
            }
        }
        _ => output.push_str("No usage history.\n"),
    }
    output
}

fn capacity_forecast(value: &Value) -> String {
    let Some(accounts) = value["accounts"].as_array() else {
        return forecast_account(value);
    };
    let mut output = format!("Forecast: {}\n", scalar(&value["status"]));
    for account in accounts {
        output.push_str(&forecast_account(account));
    }
    for pool in value["pools"].as_array().into_iter().flatten() {
        let _ = writeln!(
            output,
            "{} {} {} pool: {}, {} effective percent points remaining, exhaustion {}",
            scalar(&pool["provider"]),
            scalar(&pool["plan"]),
            scalar(&pool["windowName"]),
            scalar(&pool["status"]),
            scalar(&pool["effectiveRemainingPercentPoints"]),
            reset_time(&pool["exhaustionAt"]),
        );
    }
    output
}

fn forecast_account(value: &Value) -> String {
    let mut output = format!(
        "{}: {} ({} samples), exhaustion {}\n",
        scalar(&value["accountId"]),
        with_reason(&value["status"], &value["qualification"]),
        scalar(&value["historySampleCount"]),
        reset_time(&value["exhaustionAt"]),
    );
    for window in value["windows"].as_array().into_iter().flatten() {
        let _ = writeln!(
            output,
            "  {}: {}, {} remaining, exhaustion {}",
            scalar(&window["name"]),
            scalar(&window["status"]),
            percent(&window["remainingPercent"]),
            reset_time(&window["exhaustionAt"]),
        );
    }
    output
}

fn capacity_health(value: &Value) -> String {
    let mut output = format!("Capacity health: {}\n", scalar(&value["status"]));
    if let Some(providers) = value["providers"].as_object() {
        for (provider, health) in providers {
            let accounts = &health["accounts"];
            let _ = writeln!(
                output,
                "{provider}: CLI available {}, {} accounts ({} ready, {} degraded, {} need sign-in, {} unknown)",
                scalar(&health["cliAvailable"]),
                scalar(&accounts["total"]),
                scalar(&accounts["ready"]),
                scalar(&accounts["degraded"]),
                scalar(&accounts["reauthRequired"]),
                scalar(&accounts["unknown"]),
            );
        }
    }
    output
}

fn format_capacity(action: &CapacityAction, value: &Value, json: bool) -> String {
    if json {
        return format!("{value}\n");
    }
    match action {
        CapacityAction::Show { .. } | CapacityAction::Watch { .. } => capacity_usage(value),
        CapacityAction::History { .. } => capacity_history(value),
        CapacityAction::Forecast { .. } => capacity_forecast(value),
        CapacityAction::Health => capacity_health(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dispatch::Origin;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;

    const CAPACITY: &str = include_str!("../tests/fixtures/capacity_snapshot.json");

    #[test]
    fn capacity_fixture_preserves_rest_body_and_exposes_unknowns() {
        let response: Value = serde_json::from_str(CAPACITY).unwrap();
        let action = CapacityAction::Watch { account: None };
        let json = format_capacity(&action, &response, true);
        assert_eq!(json.lines().count(), 1);
        assert_eq!(serde_json::from_str::<Value>(&json).unwrap(), response);

        let text = format_capacity(&action, &response, false);
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
    fn watch_distinguishes_empty_snapshot_from_an_account_without_usage() {
        let action = CapacityAction::Watch { account: None };
        let empty = serde_json::json!({
            "generatedAt": 1795530000000_i64,
            "results": [],
            "counts": {"live": 0, "cache": 0, "stale": 0, "error": 0},
        });
        assert_eq!(
            format_capacity(&action, &empty, false),
            "No provider accounts.\n"
        );
        assert_eq!(
            serde_json::from_str::<Value>(&format_capacity(&action, &empty, true)).unwrap(),
            empty,
        );

        let sample: Value = serde_json::from_str(CAPACITY).unwrap();
        let account = &sample["results"][1];
        let action = CapacityAction::Watch {
            account: Some("acct_secondary".into()),
        };
        let text = format_capacity(&action, account, false);
        assert!(text.contains("Unknown period login (acct_secondary)"));
        assert!(text.contains("none (never_observed)"));
        assert_eq!(
            serde_json::from_str::<Value>(&format_capacity(&action, account, true)).unwrap()["sample"],
            Value::Null,
        );
    }

    #[test]
    fn account_summary_keeps_login_status_and_serving_separate() {
        let account = serde_json::json!({
            "id": "acct_backup",
            "host": "worker.example",
            "provider": "anthropic",
            "harness": "claude",
            "label": "Backup login",
            "loginState": "needs_sign_in",
            "loginReason": "file_missing",
            "enabled": true,
            "serving": false,
        });
        let text = account_summary(&account);
        assert_eq!(
            text,
            "Backup login (acct_backup) · claude on worker.example\n  Login: needs_sign_in (file_missing)  Enabled: true\n",
        );
        let mut serving = account;
        serving["serving"] = Value::Bool(true);
        assert!(account_summary(&serving).contains("[serving]"));
    }

    #[test]
    fn nullable_forecast_and_health_are_visible_without_synthesizing_values() {
        let forecast = serde_json::json!({
            "status": "insufficient_history",
            "accounts": [{
                "accountId": "acct_example",
                "status": "insufficient_history",
                "qualification": "needs_more_samples",
                "historySampleCount": 1,
                "exhaustionAt": null,
                "windows": []
            }],
            "pools": []
        });
        let output = format_capacity(
            &CapacityAction::Forecast { account: None },
            &forecast,
            false,
        );
        assert!(output.contains("acct_example: insufficient_history (needs_more_samples) (1 samples), exhaustion unknown"));
        let health = serde_json::json!({
            "status": "degraded",
            "providers": {
                "anthropic": {
                    "cliAvailable": false,
                    "accounts": {
                        "total": 2, "ready": 0, "degraded": 0, "reauthRequired": 1, "unknown": 1
                    }
                }
            }
        });
        let output = format_capacity(&CapacityAction::Health, &health, false);
        assert!(output.contains(
            "CLI available false, 2 accounts (0 ready, 0 degraded, 1 need sign-in, 1 unknown)"
        ));
        let history = serde_json::json!({"accountId":"acct_example","samples":[]});
        let action = CapacityAction::History {
            account: "acct_example".into(),
        };
        assert_eq!(
            format_capacity(&action, &history, false),
            "History for acct_example\nNo usage history.\n"
        );
    }

    // Subset of the gateway fixture captured from the capacity route implementation.
    // Source: test/support/fixtures/capacity/wire.json at 007629cd.
    const WIRE: &str = include_str!("../tests/fixtures/capacity_wire_931.json");

    fn fixture_socket(listener: &TcpListener) -> TcpStream {
        let (socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        socket
    }

    fn serve_snapshot(mut socket: TcpStream, body: &Value, before_reply: impl FnOnce()) {
        let request: Vec<_> = BufReader::new(&socket)
            .lines()
            .map(Result::unwrap)
            .take_while(|line| !line.is_empty())
            .collect();
        assert_eq!(
            request[0],
            "GET /api/capacity?refresh=cache&asUser=operator HTTP/1.1",
        );
        assert!(
            request.iter().any(|header| {
                header.eq_ignore_ascii_case("authorization: Bearer tbc_synthetic")
            })
        );
        before_reply();
        let body = body.to_string();
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len(),
        )
        .unwrap();
    }

    fn send_frame(socket: &mut WebSocket<TcpStream>, frame: Value) {
        socket.send(Message::Text(frame.to_string())).unwrap();
    }

    fn receive_frame(socket: &mut WebSocket<TcpStream>) -> Value {
        serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap()
    }

    fn serve_subscription(listener: &TcpListener) -> WebSocket<TcpStream> {
        let mut socket = tungstenite::accept(fixture_socket(listener)).unwrap();
        assert_eq!(
            receive_frame(&mut socket),
            json!({"type":"auth", "token":"tbc_synthetic", "asUser":"operator"}),
        );
        send_frame(
            &mut socket,
            json!({"type":"auth_result", "success":true, "isAdmin":true}),
        );
        assert_eq!(
            receive_frame(&mut socket),
            json!({"type":"subscribe", "protocolVersion":2, "subscriptionId":"capacity-watch",
                "filters":{"classes":WATCH_CLASSES}}),
        );
        // Without readiness the client must not start REST.
        listener.set_nonblocking(true).unwrap();
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        listener.set_nonblocking(false).unwrap();
        send_frame(
            &mut socket,
            json!({"type":"subscription_ready", "subscriptionId":"capacity-watch"}),
        );
        socket
    }

    #[test]
    fn capacity_watch_reconciles_during_snapshot_and_rebuilds_after_reload() {
        let wire: Value = serde_json::from_str(WIRE).unwrap();
        let baseline = wire["usageCache"]["body"].clone();
        let mut event = wire["capacityChanged"].clone();
        event["type"] = json!("change");
        event["schemaVersion"] = json!(2);
        event["subscriptionId"] = json!("capacity-watch");
        event["seq"] = json!(1);
        let mut updated = baseline.clone();
        updated["results"][0]["sample"]["windows"][0]["usedPercent"] = json!(77);
        let rebuilt = json!({
            "generatedAt": 1795570014000_i64, "results": [],
            "counts": {"live":0, "cache":0, "stale":0, "error":0},
        });
        let expected = [baseline.clone(), updated.clone(), rebuilt.clone()];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = Endpoint {
            base: format!("http://{}", listener.local_addr().unwrap()),
            token: "tbc_synthetic".into(),
            origin: Origin::Named,
        };

        let server = std::thread::spawn(move || {
            let mut socket = serve_subscription(&listener);
            serve_snapshot(fixture_socket(&listener), &baseline, || {
                send_frame(&mut socket, event)
            });
            serve_snapshot(fixture_socket(&listener), &updated, || {});
            send_frame(
                &mut socket,
                json!({"type":"reload_required", "reason":"backlog_overflow"}),
            );
            drop(socket);
            let _socket = serve_subscription(&listener);
            serve_snapshot(fixture_socket(&listener), &rebuilt, || {});
        });
        let (send, receive) = std::sync::mpsc::channel();
        let client = std::thread::spawn(move || {
            let selection =
                ReadSelection::for_invocation(&endpoint, &Identity::User("operator".into()));
            let action = CapacityAction::Watch { account: None };
            let path = capacity_path(&action);
            let mut count = 0;
            let result = watch(&endpoint, &selection, &path, None, |body| {
                send.send(format_capacity(&action, body, true))
                    .map_err(|error| error.to_string())?;
                count += 1;
                if count == 3 {
                    Err("test finished".into())
                } else {
                    Ok(())
                }
            });
            assert_eq!(result, Err("test finished".into()));
        });

        for snapshot in expected {
            let line = receive.recv_timeout(Duration::from_secs(8)).unwrap();
            assert_eq!(serde_json::from_str::<Value>(&line).unwrap(), snapshot);
        }
        client.join().unwrap();
        server.join().unwrap();
    }

    #[test]
    fn capacity_command_paths_match_the_gateway_routes() {
        assert_eq!(
            capacity_path(&CapacityAction::Show {
                account: None,
                refresh: false
            }),
            "/api/capacity"
        );
        assert_eq!(
            capacity_path(&CapacityAction::Show {
                account: Some("acct/legacy".into()),
                refresh: true
            }),
            "/api/capacity/acct%2Flegacy?refresh=wait"
        );
        assert_eq!(
            capacity_path(&CapacityAction::History {
                account: "acct_example".into()
            }),
            "/api/capacity/acct_example/history"
        );
        assert_eq!(
            capacity_path(&CapacityAction::Forecast { account: None }),
            "/api/capacity/forecast"
        );
        assert_eq!(
            capacity_path(&CapacityAction::Forecast {
                account: Some("acct_example".into())
            }),
            "/api/capacity/acct_example/forecast"
        );
        assert_eq!(
            capacity_path(&CapacityAction::Health),
            "/api/capacity/health"
        );
        assert_eq!(
            capacity_path(&CapacityAction::Watch {
                account: Some("acct_example".into())
            }),
            "/api/capacity/acct_example?refresh=cache"
        );
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
