//! Pinned-client boundary characterization before transport instrumentation.
//! Uses real loopback TCP for GET/POST; the pre-connect case holds only the
//! test resolver until the client's own deadline has expired. These are not
//! CLI/R9 acceptance tests and do not claim a production connected observer.

use std::error::Error as _;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

const REQUEST_ID: &str = "req_abcdefghijklmnopqrstuv";

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
            Ok((stream, _)) => return stream,
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
}
