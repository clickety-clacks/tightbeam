//! Complete artifacts output through the compiled CLI and real HTTP framing.
//! All records, identities and tokens here are synthetic; no gateway is booted.
use serde_json::{Value, json};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant};

const OLD_LIMIT: usize = 10 * 1024 * 1024;

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "tightbeam-large-response-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn request(stream: &mut TcpStream) -> Value {
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut bytes = Vec::new();
    loop {
        let mut block = [0; 1024];
        let n = stream.read(&mut block).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&block[..n]);
        assert!(bytes.len() < 8192);
        if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
            let headers = std::str::from_utf8(&bytes[..end]).unwrap();
            assert!(headers.starts_with("POST /agent/dispatch HTTP/1.1\r\n"));
            let length: usize = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse().unwrap())
                })
                .unwrap();
            if bytes.len() >= end + 4 + length {
                return serde_json::from_slice(&bytes[end + 4..end + 4 + length]).unwrap();
            }
        }
    }
}

enum Framing {
    Length,
    Chunked,
    Truncated,
}

fn exchange(status: u16, body: Vec<u8>, framing: Framing) -> (bool, Vec<u8>, String) {
    let scratch = Scratch::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "CLI did not connect");
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept: {error}"),
            }
        };
        // Accepted sockets can inherit the listener's nonblocking mode on BSD.
        stream.set_nonblocking(false).unwrap();
        let sent = request(&mut stream);
        assert_eq!(sent["verb"], "artifacts");
        // No filtered-only substitute for the complete listing.
        assert_eq!(sent["params"], json!({}));
        stream
            .set_write_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        write!(
            stream,
            "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nConnection: close\r\n"
        )
        .unwrap();
        match framing {
            Framing::Length | Framing::Truncated => {
                let missing = if matches!(framing, Framing::Truncated) {
                    100
                } else {
                    0
                };
                write!(stream, "Content-Length: {}\r\n\r\n", body.len() + missing).unwrap();
                // The rejected pre-fix client can close before consuming it all.
                let _ = stream.write_all(&body);
            }
            Framing::Chunked => {
                write!(stream, "Transfer-Encoding: chunked\r\n\r\n").unwrap();
                for chunk in body.chunks(8191) {
                    if write!(stream, "{:x}\r\n", chunk.len())
                        .and_then(|_| stream.write_all(chunk))
                        .and_then(|_| stream.write_all(b"\r\n"))
                        .is_err()
                    {
                        return;
                    }
                }
                let _ = stream.write_all(b"0\r\n\r\n");
            }
        }
    });
    // Files avoid blocking the child's >10MiB stdout on a full pipe while
    // retaining a bounded test watchdog and the complete output for assertions.
    let stdout = scratch.0.join("stdout");
    let stderr = scratch.0.join("stderr");
    let mut child = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["artifacts", "--as-user", "large-response-fixture"])
        .env_clear()
        .env("TIGHTBEAM_URL", format!("http://{address}"))
        .env("TIGHTBEAM_TOKEN", "synthetic-loopback-token")
        .env("TIGHTBEAM_BASE_DIR", &scratch.0)
        .current_dir(&scratch.0)
        .stdin(Stdio::null())
        .stdout(File::create(&stdout).unwrap())
        .stderr(File::create(&stderr).unwrap())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("CLI exceeded loopback test watchdog");
        }
        thread::sleep(Duration::from_millis(10));
    };
    server.join().unwrap();
    (
        status.success(),
        fs::read(stdout).unwrap(),
        fs::read_to_string(stderr).unwrap(),
    )
}

fn listing() -> Vec<u8> {
    let mut artifacts: Vec<Value> = (0..3000)
        .map(|n| {
            json!({
                "artifactId": format!("art_synthetic_{n}"),
                "title": "éλ🦀".repeat(512)
            })
        })
        .collect();
    artifacts.push(json!({"artifactId": "art_synthetic_selected", "title": "after former cutoff"}));
    let body = serde_json::to_vec(&json!({"result": {"artifacts": artifacts}})).unwrap();
    assert!(
        body.windows(b"art_synthetic_selected".len())
            .position(|part| part == b"art_synthetic_selected")
            .unwrap()
            > OLD_LIMIT
    );
    body
}

#[test]
fn complete_artifacts_beyond_ten_mib_with_length_and_chunked_transport() {
    for framing in [Framing::Length, Framing::Chunked] {
        let (success, stdout, stderr) = exchange(200, listing(), framing);
        assert!(success, "{stderr}");
        let parsed: Value = serde_json::from_slice(&stdout).unwrap();
        let rows = parsed["artifacts"].as_array().unwrap();
        assert_eq!(rows.len(), 3001);
        for (n, row) in rows[..3000].iter().enumerate() {
            assert_eq!(row["artifactId"], format!("art_synthetic_{n}"));
            assert_eq!(row["title"], "éλ🦀".repeat(512));
        }
        assert_eq!(rows[3000]["artifactId"], "art_synthetic_selected");
        assert!(stderr.is_empty(), "{stderr}");
    }
}

fn failure(status: u16, body: Vec<u8>, framing: Framing) -> Value {
    let (success, stdout, stderr) = exchange(status, body, framing);
    assert!(!success);
    assert!(
        stdout.is_empty(),
        "a refusal must not print partial success"
    );
    assert!(
        !stderr.contains("fixtureSECRET"),
        "diagnostic leaked secret"
    );
    let machine: Value = serde_json::from_str(stderr.lines().last().unwrap()).unwrap();
    assert_eq!(machine["ok"], false);
    assert_eq!(machine["httpStatus"], status);
    machine
}

#[test]
fn large_malformed_json_and_incomplete_http_remain_distinct_failures() {
    let mut malformed = listing();
    malformed.pop(); // Full HTTP body, incomplete JSON.
    let decoded = failure(200, malformed, Framing::Length);
    assert_eq!(decoded["error"]["code"], "response_undecodable");
    assert!(decoded["error"]["bodyBytes"].as_u64().unwrap() > OLD_LIMIT as u64);

    // Even valid JSON must not succeed when HTTP framing says bytes are missing.
    let unreadable = failure(200, listing(), Framing::Truncated);
    assert_eq!(unreadable["error"]["code"], "response_unreadable");
}

#[test]
fn http_refusal_error_envelope_pending_and_redaction_are_preserved() {
    for status in [200, 503] {
        let body = serde_json::to_vec(&json!({"error": {
            "code": "fixture_refusal", "message": "refused", "token": "fixtureSECRET"
        }}))
        .unwrap();
        let error = failure(status, body, Framing::Length);
        assert_eq!(error["error"]["code"], "fixture_refusal");
    }
    let pending = failure(202, br#"{"decisionPending":{"code":"decision_pending","decisionRequestId":"dr_synthetic","message":"held"}}"#.to_vec(), Framing::Length);
    assert_eq!(
        pending["decisionPending"]["decisionRequestId"],
        "dr_synthetic"
    );
    assert!(pending["error"].is_null());
}

#[test]
fn dispatch_retains_existing_lossy_utf8_decoding() {
    let (success, stdout, stderr) = exchange(
        200,
        b"{\"result\":{\"title\":\"\xff\"}}".to_vec(),
        Framing::Length,
    );
    assert!(success, "{stderr}");
    let result: Value = serde_json::from_slice(&stdout).unwrap();
    assert_eq!(result["title"], "\u{fffd}");
}
