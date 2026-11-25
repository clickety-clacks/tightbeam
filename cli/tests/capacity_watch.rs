use serde_json::{Value, json};
use std::io::{self, BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::time::Duration;
use tungstenite::{Message, WebSocket};

// Subset of the gateway fixture captured from the capacity route implementation.
// Source: test/support/fixtures/capacity/wire.json at 007629cd.
const WIRE: &str = include_str!("fixtures/capacity_wire_931.json");

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
        request
            .iter()
            .any(|header| { header.eq_ignore_ascii_case("authorization: Bearer tbc_synthetic") })
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
        "filters":{"classes":[
            "capacity.changed","provider_account.changed","provider_account.removed",
            "account_serving.changed","account_limit.changed"
        ]}}),
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
    let url = format!("http://{}", listener.local_addr().unwrap());

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
    let mut child = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["capacity", "watch", "--json", "--as-user", "operator"])
        .current_dir(std::env::temp_dir())
        .env("TIGHTBEAM_URL", url)
        .env("TIGHTBEAM_TOKEN", "tbc_synthetic")
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (send, receive) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            if send.send(line).is_err() {
                break;
            }
        }
    });

    let snapshots = (0..expected.len())
        .map(|_| receive.recv_timeout(Duration::from_secs(8)))
        .collect::<Result<Vec<_>, _>>();
    let _ = child.kill();
    child.wait().unwrap();
    reader.join().unwrap();

    for (line, snapshot) in snapshots.unwrap().into_iter().zip(expected) {
        assert_eq!(
            serde_json::from_str::<Value>(&line.unwrap()).unwrap(),
            snapshot
        );
    }
    server.join().unwrap();
}
