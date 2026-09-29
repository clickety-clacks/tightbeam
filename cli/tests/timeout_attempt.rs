//! Pinned-client and integrated CLI evidence for bounded transport diagnostics.
//! Uses real loopback TCP for GET/POST; the pre-connect case holds only the
//! test resolver until the client's own deadline has expired. These cases do
//! not replace real gateway listener lifecycle/restart R9 evidence.

use std::error::Error as _;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

#[path = "../src/lease.rs"]
mod actual_lease;

const REQUEST_ID: &str = "req_abcdefghijklmnopqrstuv";

fn assert_phase(error: &ureq::Transport, phase: ureq::TransportPhase, route: ureq::TransportRoute) {
    assert_eq!(
        error.phase_evidence(),
        Some(ureq::TransportEvidence { phase, route })
    );
    assert!(!error.has_prior_exchange());
}

fn call(agent: ureq::Agent, method: &'static str, addr: SocketAddr) -> ureq::Transport {
    let request = agent
        .request(method, &format!("http://{addr}/timeout-proof"))
        .set("x-tightbeam-request-id", REQUEST_ID);
    let result = if method == "POST" {
        request.send_string("test-payload")
    } else {
        request.call()
    };
    match result {
        Err(ureq::Error::Transport(error)) => error,
        other => panic!("expected a transport failure, got {other:?}"),
    }
}

fn assert_ambiguous_timeout(error: &ureq::Transport) {
    assert_eq!(error.kind(), ureq::ErrorKind::Io);
    let source = error
        .source()
        .and_then(|source| source.downcast_ref::<io::Error>())
        .expect("pinned client exposes typed io source");
    assert_eq!(source.kind(), io::ErrorKind::TimedOut);
    // Deliberately no matching on Display/message/elapsed to infer phase.
}

fn preconnect(method: &'static str) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let resolves = Arc::new(AtomicUsize::new(0));
    let resolver_count = Arc::clone(&resolves);
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let release = std::sync::Mutex::new(release_rx);
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_millis(100))
            .timeout(Duration::from_millis(100))
            .resolver(move |_: &str| {
                resolver_count.fetch_add(1, Ordering::SeqCst);
                entered_tx.send(Instant::now()).unwrap();
                release
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(5))
                    .unwrap();
                Ok(vec![addr])
            })
            .build();
        done_tx.send(call(agent, method, addr)).unwrap();
    });
    let entered = entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    // This wait exhausts the real configured deadline; it does not guess a
    // thread's progress. The resolver remains blocked until explicit release.
    let exhausted = entered + Duration::from_millis(200);
    while Instant::now() < exhausted {
        thread::sleep(exhausted.saturating_duration_since(Instant::now()));
    }
    release_tx.send(()).unwrap();
    let error = done_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    worker.join().unwrap();
    assert_ambiguous_timeout(&error);
    assert_phase(
        &error,
        ureq::TransportPhase::Connect,
        ureq::TransportRoute::Direct,
    );
    assert_eq!(resolves.load(Ordering::SeqCst), 1, "no DNS retry");
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock,
        "the deadline expired before any TCP connection"
    );
}

fn accept_bounded(listener: &TcpListener) -> TcpStream {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                // Accept polling is nonblocking; fixture reads use explicit timeouts.
                stream.set_nonblocking(false).unwrap();
                return stream;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "client never connected");
                thread::sleep(Duration::from_millis(1));
            }
            Err(error) => panic!("loopback accept failed: {error}"),
        }
    }
}

fn read_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut bytes = Vec::new();
    loop {
        let mut buffer = [0_u8; 1024];
        let n = stream.read(&mut buffer).unwrap();
        assert!(n > 0, "client closed before sending its request");
        bytes.extend_from_slice(&buffer[..n]);
        assert!(bytes.len() < 8192, "unexpected unbounded test request");
        if let Some(header_end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
            let headers = std::str::from_utf8(&bytes[..header_end]).unwrap();
            let body_len: usize = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse().unwrap())
                })
                .unwrap_or(0);
            if bytes.len() >= header_end + 4 + body_len {
                return String::from_utf8(bytes).unwrap();
            }
        }
    }
}

fn postconnect(method: &'static str) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(2))
            .timeout(Duration::from_secs(2))
            .build();
        done_tx.send(call(agent, method, addr)).unwrap();
    });
    let mut accepted = accept_bounded(&listener);
    let request = read_request(&mut accepted);
    assert!(request.starts_with(&format!("{method} /timeout-proof HTTP/1.1\r\n")));
    assert!(
        request
            .to_ascii_lowercase()
            .contains(&format!("x-tightbeam-request-id: {REQUEST_ID}\r\n"))
    );
    if method == "POST" {
        assert!(request.ends_with("\r\n\r\ntest-payload"));
    }
    // Keep the accepted stream open and send NO response bytes. The actual
    // client deadline must fire after the server has read the whole request.
    let error = done_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    worker.join().unwrap();
    assert_ambiguous_timeout(&error);
    assert_phase(
        &error,
        ureq::TransportPhase::AwaitResponse,
        ureq::TransportRoute::Direct,
    );
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock,
        "the uncertain failure must not cause a new connection/replay"
    );
    drop(accepted);
}

#[test]
fn get_connect_allowance_exhaustion_has_no_tcp_accept() {
    preconnect("GET");
}

#[test]
fn post_connect_allowance_exhaustion_has_no_tcp_accept() {
    preconnect("POST");
}

#[test]
fn get_request_deadline_follows_actual_accept_without_response_headers() {
    postconnect("GET");
}

#[test]
fn post_request_deadline_follows_actual_accept_without_response_headers() {
    postconnect("POST");
}

#[test]
fn pooled_post_deadline_uses_the_observed_existing_socket() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(2))
            .timeout(Duration::from_secs(2))
            .build();
        assert_eq!(
            agent
                .get(&format!("http://{addr}/seed"))
                .call()
                .unwrap()
                .into_string()
                .unwrap(),
            "x"
        );
        done_tx.send(call(agent, "POST", addr)).unwrap();
    });
    let mut stream = accept_bounded(&listener);
    assert!(read_request(&mut stream).starts_with("GET /seed HTTP/1.1\r\n"));
    stream
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx")
        .unwrap();
    assert!(read_request(&mut stream).starts_with("POST /timeout-proof HTTP/1.1\r\n"));
    let error = done_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    worker.join().unwrap();
    assert_ambiguous_timeout(&error);
    assert_phase(
        &error,
        ureq::TransportPhase::AwaitResponse,
        ureq::TransportRoute::Direct,
    );
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock,
        "the second request used the accepted socket, without replay"
    );
}

#[test]
fn tls_handshake_failure_can_be_connection_failed_after_tcp_accept() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || {
        let result = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(2))
            .timeout(Duration::from_secs(2))
            .build()
            .get(&format!("https://{addr}/timeout-proof"))
            .call();
        done_tx.send(result).unwrap();
    });
    let mut stream = accept_bounded(&listener);
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut tls_header = [0_u8; 5];
    stream.read_exact(&mut tls_header).unwrap();
    assert_eq!(tls_header[0], 22, "actual TLS handshake record");
    let error = match done_rx.recv_timeout(Duration::from_secs(5)).unwrap() {
        Err(ureq::Error::Transport(error)) => error,
        other => panic!("expected TLS negotiation failure, got {other:?}"),
    };
    worker.join().unwrap();
    assert_eq!(error.kind(), ureq::ErrorKind::ConnectionFailed);
    assert_phase(
        &error,
        ureq::TransportPhase::TlsHandshake,
        ureq::TransportRoute::Direct,
    );
    let source = error
        .source()
        .and_then(|e| e.downcast_ref::<io::Error>())
        .unwrap();
    assert!(matches!(
        source.kind(),
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
    ));
    // Coarse ConnectionFailed is therefore NOT proof that TCP never connected.
}

#[test]
fn proxy_connect_timeout_does_not_prove_a_gateway_connection() {
    let proxy = TcpListener::bind("127.0.0.1:0").unwrap();
    proxy.set_nonblocking(true).unwrap();
    let proxy_addr = proxy.local_addr().unwrap();
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || {
        let result = ureq::AgentBuilder::new()
            .proxy(ureq::Proxy::new(format!("http://{proxy_addr}")).unwrap())
            .timeout_connect(Duration::from_secs(2))
            .timeout(Duration::from_secs(2))
            .build()
            .get("https://unresolved.invalid/timeout-proof")
            .call();
        done_tx.send(result).unwrap();
    });
    let mut stream = accept_bounded(&proxy);
    assert!(read_request(&mut stream).starts_with("CONNECT unresolved.invalid:443 HTTP/1.1\r\n"));
    // No CONNECT response and no origin DNS/TCP or TLS success is supplied.
    let error = match done_rx.recv_timeout(Duration::from_secs(5)).unwrap() {
        Err(ureq::Error::Transport(error)) => error,
        other => panic!("expected proxy negotiation timeout, got {other:?}"),
    };
    worker.join().unwrap();
    assert_ambiguous_timeout(&error);
    assert_phase(
        &error,
        ureq::TransportPhase::ProxyHandshake,
        ureq::TransportRoute::HttpTunnel,
    );
}

struct CliRoot(std::path::PathBuf);

impl CliRoot {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "tightbeam-timeout-attempt-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn spawn(&self, command: &str, addr: SocketAddr) -> std::process::Child {
        // The isolated POST fixture has no session marker. Supply a synthetic
        // actor explicitly so the real CLI reaches the loopback gateway.
        let identity: &[&str] = if command == "list" {
            &["--as-user", "timeout-loopback-fixture"]
        } else {
            &[]
        };
        std::process::Command::new(env!("CARGO_BIN_EXE_tightbeam"))
            .arg(command)
            .args(identity)
            .env_clear()
            .env("TIGHTBEAM_URL", format!("http://{addr}"))
            .env("TIGHTBEAM_TOKEN", "synthetic-loopback-token")
            .env("TIGHTBEAM_BASE_DIR", &self.0)
            .current_dir(&self.0)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap()
    }
}

impl Drop for CliRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn finish_cli(mut child: std::process::Child) -> std::process::Output {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().unwrap().is_some() {
            return child.wait_with_output().unwrap();
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!("CLI did not finish its one gateway exchange: {output:?}");
        }
        thread::sleep(Duration::from_millis(2));
    }
}

fn generated_id(request: &str) -> String {
    let ids: Vec<_> = request
        .lines()
        .filter_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("x-tightbeam-request-id")
                .then(|| value.trim())
        })
        .collect();
    assert_eq!(ids.len(), 1, "one generated ID header per actual attempt");
    let id = ids[0];
    let suffix = id
        .strip_prefix("req_")
        .expect("generated request-ID namespace");
    assert_eq!(suffix.len(), 22);
    assert!(
        suffix
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    );
    id.to_owned()
}

fn machine_failure(output: &std::process::Output) -> serde_json::Value {
    assert!(
        !output.status.success(),
        "expected original CLI failure: {output:?}"
    );
    let stderr = std::str::from_utf8(&output.stderr).unwrap();
    let mut lines = stderr.lines();
    let human = lines.next().expect("human reading first");
    assert!(!human.starts_with('{'), "human reading missing: {stderr}");
    let machine = lines.next().expect("machine reading second");
    assert!(
        lines.next().is_none(),
        "unexpected extra failure lines: {stderr}"
    );
    serde_json::from_str(machine).unwrap()
}

fn one_receipt(root: &CliRoot) -> serde_json::Value {
    let log = std::fs::read_to_string(root.0.join("diagnostics/cli-transport-v1.log")).unwrap();
    let records: Vec<serde_json::Value> = log
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        records.len(),
        1,
        "one failure receipt for one actual attempt"
    );
    records.into_iter().next().unwrap()
}

#[test]
fn actual_cli_unreachable_port_keeps_typed_refusal_or_unknown_fallback_for_get_and_post() {
    for command in ["help", "list"] {
        let root = CliRoot::new();
        // Port zero has no listening endpoint. Its OS error kind may vary, so
        // assert either typed refusal or the honest unknown-phase fallback.
        let addr = SocketAddr::from(([127, 0, 0, 1], 0));
        let output = finish_cli(root.spawn(command, addr));
        assert_eq!(output.status.success(), command == "help");
        let record = one_receipt(&root);
        let diagnostic_code = match record["code"].as_str() {
            Some("gateway_unavailable") => {
                assert!(matches!(
                    record["cause"].as_str(),
                    Some("connect_refused" | "connect_timeout" | "dns_failed")
                ));
                assert_eq!(record["gateway_accepted"], false);
                assert_eq!(record["effect_kind"], "read");
                assert_eq!(record["effect_state"], "none");
                assert_eq!(record["action"], "retry_safe");
                if record["cause"] == "connect_timeout" {
                    assert_eq!(record["timeout_source"], "cli_connect");
                    assert!(record["budget_ms"].as_u64().is_some());
                } else {
                    assert_eq!(record["timeout_source"], "none");
                    assert!(record["budget_ms"].is_null());
                }
                Some("gateway_unavailable")
            }
            Some("gateway_transport_uncertain") => {
                assert!(matches!(
                    record["cause"].as_str(),
                    Some("request_timeout" | "connection_reset" | "transport_failed")
                ));
                assert_eq!(record["gateway_accepted"], "unknown");
                assert_eq!(record["effect_kind"], "read");
                assert_eq!(record["effect_state"], "none");
                assert_eq!(record["action"], "retry_safe");
                if record["cause"] == "request_timeout" {
                    assert_eq!(record["timeout_source"], "cli_request");
                    assert!(record["budget_ms"].as_u64().is_some());
                } else {
                    assert_eq!(record["timeout_source"], "none");
                    assert!(record["budget_ms"].is_null());
                }
                Some("gateway_transport_uncertain")
            }
            None => {
                assert!(record["cause"].is_null());
                assert_eq!(record["gateway_accepted"], "unknown");
                assert_eq!(record["effect_kind"], "read");
                assert!(record["effect_state"].is_null());
                assert!(record["action"].is_null());
                assert!(record["timeout_source"].is_null());
                assert!(record["budget_ms"].is_null());
                None
            }
            code => panic!("unexpected transport classification: {code:?}"),
        };
        assert!(record["listener_generation"].is_null());
        if command == "list" {
            let machine = machine_failure(&output);
            assert_eq!(machine["attempt"]["requestId"], record["request_id"]);
            if let Some(code) = diagnostic_code {
                assert_eq!(machine["attempt"]["diagnostic"]["code"], code);
            } else {
                assert!(machine["attempt"]["diagnostic"].is_null());
            }
        }
    }
}

#[test]
fn actual_cli_correlates_observed_headers_without_overwriting_foreign_error_fields() {
    for echo_matches in [true, false] {
        let root = CliRoot::new();
        let gateway = TcpListener::bind("127.0.0.1:0").unwrap();
        gateway.set_nonblocking(true).unwrap();
        let child = root.spawn("list", gateway.local_addr().unwrap());
        let mut stream = accept_bounded(&gateway);
        let request = read_request(&mut stream);
        assert!(request.starts_with("POST /agent/dispatch HTTP/1.1\r\n"));
        let id = generated_id(&request);
        let echo = if echo_matches {
            id.as_str()
        } else {
            "req_foreign"
        };
        // This is actual CLI/header correlation proof against a loopback
        // responder, not proof that ListenerLifecycle minted a generation.
        let generation = "lgen_abcdefghijklmnopqrstuv";
        let body = r#"{"error":{"code":"fixture_refusal","message":"fixture","requestId":"req_upstream_foreign","diagnostic":{"origin":"upstream"}}}"#;
        write!(stream, "HTTP/1.1 503 Service Unavailable\r\nx-tightbeam-request-id: {echo}\r\nx-tightbeam-listener-generation: {generation}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        drop(stream);
        let output = finish_cli(child);
        let machine = machine_failure(&output);
        assert_eq!(machine["error"]["requestId"], "req_upstream_foreign");
        assert_eq!(machine["error"]["diagnostic"]["origin"], "upstream");
        let attempt = &machine["attempt"];
        assert_eq!(attempt.as_object().unwrap().len(), 5);
        assert_eq!(attempt["requestId"], id);
        assert_eq!(attempt["operation"], "cli.list");
        assert!(
            attempt["diagnostic"].is_null(),
            "foreign envelope is not a local DB timeout"
        );
        assert_eq!(attempt["receipt"], "not_applicable");
        if echo_matches {
            assert_eq!(attempt["listenerGeneration"], generation);
        } else {
            assert!(attempt["listenerGeneration"].is_null());
        }
        assert!(
            !root.0.join("diagnostics/cli-transport-v1.log").exists(),
            "completed HTTP refusal is not a transport failure"
        );
        assert_eq!(
            gateway.accept().unwrap_err().kind(),
            io::ErrorKind::WouldBlock,
            "no replay"
        );
    }
}

#[test]
fn actual_cli_get_and_post_body_failure_write_at_most_one_correlated_receipt() {
    for command in ["help", "list"] {
        let root = CliRoot::new();
        let gateway = TcpListener::bind("127.0.0.1:0").unwrap();
        gateway.set_nonblocking(true).unwrap();
        let child = root.spawn(command, gateway.local_addr().unwrap());
        let mut stream = accept_bounded(&gateway);
        let request = read_request(&mut stream);
        let id = generated_id(&request);
        let expected_line = if command == "help" {
            "GET /harnesses HTTP/1.1\r\n"
        } else {
            "POST /agent/dispatch HTTP/1.1\r\n"
        };
        assert!(request.starts_with(expected_line));
        write!(stream, "HTTP/1.1 200 OK\r\nx-tightbeam-request-id: {id}\r\nx-tightbeam-listener-generation: lgen_abcdefghijklmnopqrstuv\r\nContent-Length: 50\r\nConnection: close\r\n\r\nx").unwrap();
        drop(stream); // actual EOF with a still-incomplete HTTP body
        let output = finish_cli(child);
        assert_eq!(
            output.status.success(),
            command == "help",
            "preserve help fallback: {output:?}"
        );
        if command == "list" {
            let machine = machine_failure(&output);
            assert_eq!(machine["error"]["code"], "response_unreadable");
            assert_eq!(machine["attempt"]["requestId"], id);
            assert_eq!(machine["attempt"]["receipt"], "recorded");
        }
        let log = std::fs::read_to_string(root.0.join("diagnostics/cli-transport-v1.log")).unwrap();
        let records: Vec<serde_json::Value> = log
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(records.len(), 1);
        let record = &records[0];
        assert_eq!(record["request_id"], id);
        assert_eq!(
            record["operation"],
            if command == "help" {
                "cli.help"
            } else {
                "cli.list"
            }
        );
        assert_eq!(record["listener_generation"], "lgen_abcdefghijklmnopqrstuv");
        assert_eq!(record["code"], "gateway_transport_uncertain");
        assert_eq!(record["effect_kind"], "read");
        assert_eq!(record["effect_state"], "none");
        assert_eq!(record["gateway_accepted"], "unknown");
        assert_eq!(
            gateway.accept().unwrap_err().kind(),
            io::ErrorKind::WouldBlock,
            "no replay"
        );
    }
}

#[test]
fn actual_cli_unavailable_receipt_does_not_replace_the_original_body_failure() {
    let root = CliRoot::new();
    std::fs::write(root.0.join("diagnostics"), "blocked fixture").unwrap();
    let gateway = TcpListener::bind("127.0.0.1:0").unwrap();
    gateway.set_nonblocking(true).unwrap();
    let child = root.spawn("list", gateway.local_addr().unwrap());
    let mut stream = accept_bounded(&gateway);
    let id = generated_id(&read_request(&mut stream));
    write!(stream, "HTTP/1.1 200 OK\r\nx-tightbeam-request-id: {id}\r\nContent-Length: 50\r\nConnection: close\r\n\r\nx").unwrap();
    drop(stream);
    let output = finish_cli(child);
    let machine = machine_failure(&output);
    assert_eq!(machine["error"]["code"], "response_unreadable");
    assert_eq!(machine["attempt"]["requestId"], id);
    assert_eq!(machine["attempt"]["receipt"], "unavailable");
    assert!(String::from_utf8_lossy(&output.stderr).contains("diagnosticReceipt=unavailable"));
    assert_eq!(
        std::fs::read_to_string(root.0.join("diagnostics")).unwrap(),
        "blocked fixture"
    );
    assert_eq!(
        gateway.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
}

fn cli_redirect_is_not_followed(command: &str, request_line: &str, success: bool) {
    let root = CliRoot::new();
    let gateway = TcpListener::bind("127.0.0.1:0").unwrap();
    gateway.set_nonblocking(true).unwrap();
    let target = TcpListener::bind("127.0.0.1:0").unwrap();
    target.set_nonblocking(true).unwrap();
    let child = root.spawn(command, gateway.local_addr().unwrap());
    let mut stream = accept_bounded(&gateway);
    let request = read_request(&mut stream);
    assert!(
        request.starts_with(request_line),
        "unexpected actual gateway request: {request}"
    );
    let body = r#"{"error":{"code":"redirect_refused","message":"synthetic redirect"}}"#;
    write!(stream,
        "HTTP/1.1 302 Found\r\nLocation: http://{}/must-not-run\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        target.local_addr().unwrap(), body.len(), body).unwrap();
    drop(stream);
    let output = finish_cli(child);
    assert_eq!(
        output.status.success(),
        success,
        "changed CLI result: {output:?}"
    );
    if !success {
        assert!(String::from_utf8_lossy(&output.stderr).contains("redirect_refused"));
    }
    assert_eq!(
        target.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock,
        "302 reached a second HTTP exchange"
    );
    assert_eq!(
        gateway.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock,
        "gateway request was replayed"
    );
}

#[test]
fn actual_cli_post_does_not_follow_gateway_302() {
    cli_redirect_is_not_followed("list", "POST /agent/dispatch HTTP/1.1\r\n", false);
}

#[test]
fn actual_cli_catalog_get_does_not_follow_gateway_302_and_keeps_help_fallback() {
    cli_redirect_is_not_followed("help", "GET /harnesses HTTP/1.1\r\n", true);
}

#[test]
fn actual_cli_fresh_gateway_post_does_not_replay_after_peer_eof() {
    let root = CliRoot::new();
    let gateway = TcpListener::bind("127.0.0.1:0").unwrap();
    gateway.set_nonblocking(true).unwrap();
    let child = root.spawn("list", gateway.local_addr().unwrap());
    let mut stream = accept_bounded(&gateway);
    let request = read_request(&mut stream);
    assert!(request.starts_with("POST /agent/dispatch HTTP/1.1\r\n"));
    let id = generated_id(&request);
    // The peer read the full real request but supplies no response. The fresh
    // Agent must not enter ureq's recycled-stream retry branches.
    drop(stream);
    let output = finish_cli(child);
    let machine = machine_failure(&output);
    assert_eq!(machine["attempt"]["requestId"], id);
    assert_eq!(
        machine["attempt"]["diagnostic"]["code"],
        "gateway_transport_uncertain"
    );
    assert_eq!(
        machine["attempt"]["diagnostic"]["gatewayAccepted"],
        "unknown"
    );
    let record = one_receipt(&root);
    assert_eq!(record["request_id"], id);
    assert!(record["listener_generation"].is_null());
    assert_eq!(
        gateway.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
}

#[test]
fn actual_cli_fresh_catalog_get_does_not_replay_after_peer_eof() {
    let root = CliRoot::new();
    let gateway = TcpListener::bind("127.0.0.1:0").unwrap();
    gateway.set_nonblocking(true).unwrap();
    let child = root.spawn("help", gateway.local_addr().unwrap());
    let mut stream = accept_bounded(&gateway);
    let request = read_request(&mut stream);
    assert!(request.starts_with("GET /harnesses HTTP/1.1\r\n"));
    let id = generated_id(&request);
    drop(stream);
    assert!(
        finish_cli(child).status.success(),
        "help keeps its offline fallback"
    );
    let record = one_receipt(&root);
    assert_eq!(record["request_id"], id);
    assert_eq!(record["code"], "gateway_transport_uncertain");
    assert_eq!(record["gateway_accepted"], "unknown");
    assert!(record["listener_generation"].is_null());
    assert_eq!(
        gateway.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
}

#[test]
fn non_gateway_agent_keeps_redirect_policy_and_marks_prior_exchange() {
    let first = TcpListener::bind("127.0.0.1:0").unwrap();
    first.set_nonblocking(true).unwrap();
    let second = TcpListener::bind("127.0.0.1:0").unwrap();
    second.set_nonblocking(true).unwrap();
    let addr = first.local_addr().unwrap();
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || {
        let result = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(2))
            .build()
            .get(&format!("http://{addr}/first"))
            .call();
        done_tx.send(result).unwrap();
    });
    let mut stream = accept_bounded(&first);
    assert!(read_request(&mut stream).starts_with("GET /first HTTP/1.1\r\n"));
    write!(stream, "HTTP/1.1 302 Found\r\nLocation: http://{}/second\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        second.local_addr().unwrap()).unwrap();
    drop(stream);
    let mut redirected = accept_bounded(&second);
    assert!(read_request(&mut redirected).starts_with("GET /second HTTP/1.1\r\n"));
    let error = match done_rx.recv_timeout(Duration::from_secs(5)).unwrap() {
        Err(ureq::Error::Transport(error)) => error,
        other => panic!("expected second-leg timeout: {other:?}"),
    };
    worker.join().unwrap();
    assert_ambiguous_timeout(&error);
    assert!(error.has_prior_exchange());
    assert_eq!(
        error.phase_evidence().unwrap().phase,
        ureq::TransportPhase::AwaitResponse
    );
    // B must leave diagnostic=None here: the final leg cannot stand in for the
    // first leg or fabricate per-leg IDs. Gateway callers do not follow it.
}

fn lease_request_has_one_worker_attempt(method: &'static str) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let (observation_tx, observation_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let (outer_tx, outer_rx) = mpsc::sync_channel(1);
    let (worker_done_tx, worker_done_rx) = mpsc::sync_channel(1);
    let outer = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(2);
        let result = actual_lease::until(deadline, move |remaining| {
            let agent = ureq::AgentBuilder::new()
                .redirects(0)
                .timeout_connect(remaining)
                .timeout(remaining)
                .build();
            let error = call(agent, method, addr);
            observation_tx.send(error).unwrap();
            // Keep work completion behind an explicit barrier so the outer
            // deadline wins regardless of a socket timeout rounding earlier.
            release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            worker_done_tx.send(()).unwrap();
        });
        outer_tx.send(result).unwrap();
    });
    let mut stream = accept_bounded(&listener);
    let request = read_request(&mut stream);
    assert!(request.starts_with(&format!("{method} /timeout-proof HTTP/1.1\r\n")));
    assert_eq!(
        request
            .to_ascii_lowercase()
            .matches("x-tightbeam-request-id:")
            .count(),
        1
    );
    assert_eq!(
        outer_rx.recv_timeout(Duration::from_secs(5)).unwrap(),
        Err(())
    );
    let error = observation_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_phase(
        &error,
        ureq::TransportPhase::AwaitResponse,
        ureq::TransportRoute::Direct,
    );
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    release_tx.send(()).unwrap();
    worker_done_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    outer.join().unwrap();
    // Receipt-count assertions belong to final B call-site hookup; this test
    // proves actual lease/worker transport ownership without an outer replay.
}

#[test]
fn get_absolute_lease_keeps_the_single_request_with_its_worker() {
    lease_request_has_one_worker_attempt("GET");
}

#[test]
fn post_absolute_lease_keeps_the_single_request_with_its_worker() {
    lease_request_has_one_worker_attempt("POST");
}
