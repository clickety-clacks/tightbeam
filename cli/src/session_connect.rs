//! Persistent selected-session connection.
//!
//! The command deliberately keeps all protocol output in this module's main
//! thread.  Stdin, HTTP wake requests, REST snapshots, and the WebSocket each
//! have a worker, but none of those workers can write stdout.  That gives the
//! NDJSON stream one owner and makes the accepted-wake-before-event rule
//! enforceable without inventing another delivery path.

use std::collections::{HashSet, VecDeque};
use std::io::{self, BufRead, Write};
use std::net::TcpStream;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering},
    mpsc::{self, Sender},
};
use std::thread;
use std::time::Duration;

use serde_json::{Value, json};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Error as WebSocketError, Message, connect};

use crate::args::{Command, Identity, Target};
use crate::dispatch::{self, Endpoint};

const PROTOCOL_VERSION: u64 = 1;
const FIREHOSE_PROTOCOL_PLAN: [u64; 2] = [2, 1];
const SNAPSHOT_LIMIT: u64 = 500;
const SIGNAL_EXIT_PREFIX: &str = "session_connect_signal_exit:";
static SESSION_SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn session_signal_handler(signal: libc::c_int) {
    let _ = SESSION_SIGNAL.compare_exchange(0, signal, Ordering::SeqCst, Ordering::SeqCst);
}

struct SessionSignalGuard {
    previous: Vec<(libc::c_int, libc::sigaction)>,
}

impl SessionSignalGuard {
    fn install() -> Result<Self, String> {
        let mut previous = Vec::new();
        for signal in [libc::SIGINT, libc::SIGTERM] {
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = session_signal_handler as *const () as usize;
            unsafe { libc::sigemptyset(&mut action.sa_mask) };
            action.sa_flags = 0;
            let mut old: libc::sigaction = unsafe { std::mem::zeroed() };
            if unsafe { libc::sigaction(signal, &action, &mut old) } == -1 {
                let error = std::io::Error::last_os_error();
                for (installed, prior) in previous.iter().rev() {
                    unsafe { libc::sigaction(*installed, prior, std::ptr::null_mut()) };
                }
                return Err(format!("signal setup failed: {error}"));
            }
            previous.push((signal, old));
        }
        Ok(Self { previous })
    }
}

impl Drop for SessionSignalGuard {
    fn drop(&mut self) {
        for (signal, previous) in self.previous.iter().rev() {
            unsafe { libc::sigaction(*signal, previous, std::ptr::null_mut()) };
        }
        SESSION_SIGNAL.store(0, Ordering::SeqCst);
    }
}

#[derive(Debug)]
enum Input {
    Line(String),
    InvalidUtf8,
    Eof,
}

#[derive(Debug)]
enum Worker {
    Tick,
    Stop,
    Connected(u64),
    Frame(u64, Value),
    Closed(u64, ConnectionFailure),
    Fatal(ConnectionFailure),
    SendResult {
        request_id: String,
        result: Result<String, SendFailure>,
    },
    SnapshotResult {
        generation: u64,
        cycle: u64,
        result: Result<Snapshot, SnapshotFailure>,
    },
}

#[derive(Debug)]
struct SendFailure {
    code: String,
    message: String,
}

#[derive(Debug)]
struct SnapshotFailure {
    code: String,
    message: String,
    retryable: bool,
}

#[derive(Debug, Clone)]
struct ConnectionFailure {
    code: String,
    message: String,
    fatal: bool,
    close_code: Option<u16>,
}

impl ConnectionFailure {
    fn recoverable(code: &str, message: &str) -> Self {
        Self {
            code: code.to_owned(),
            message: message.to_owned(),
            fatal: false,
            close_code: None,
        }
    }

    fn fatal(code: &str, message: &str) -> Self {
        Self {
            code: code.to_owned(),
            message: message.to_owned(),
            fatal: true,
            close_code: None,
        }
    }
}

#[derive(Debug)]
struct Snapshot {
    session: Value,
    messages: Vec<Value>,
    wakes: Vec<Value>,
    turns: Vec<Value>,
    row_version: u64,
    cleared_through_seq: u64,
}

#[derive(Debug)]
struct SendFrame {
    request_id: String,
    content: String,
    idempotency_key: Option<String>,
}

#[derive(Debug)]
struct PendingSnapshot {
    generation: u64,
    cycle: u64,
    events: Vec<Value>,
}

#[derive(Debug, PartialEq, Eq)]
enum SnapshotResultDisposition {
    Ignore,
    Defer,
    Complete,
}

enum SnapshotResultAdmission {
    Ignore,
    Defer,
    Complete(Result<Snapshot, SnapshotFailure>),
}

#[derive(Debug)]
enum SnapshotEmissionError {
    Closed,
    Signaled(i32),
    Output(String),
}

pub fn run(session_key: String, identity: Identity) -> Result<(), String> {
    let endpoint = match dispatch::discover() {
        Ok(endpoint) => endpoint,
        Err(error) => {
            emit(&fatal("discovery_failed", "gateway discovery failed"))?;
            return Err(error);
        }
    };
    let signal_guard = SessionSignalGuard::install()?;

    let stopped = Arc::new(AtomicBool::new(false));
    let lifecycle = Arc::new(AtomicU64::new(0));
    let (input_tx, input_rx) = mpsc::channel();
    let (worker_tx, worker_rx) = mpsc::channel();

    spawn_stdin_reader(input_tx);
    let socket_worker = spawn_socket_worker(
        endpoint.clone(),
        session_key.clone(),
        worker_tx.clone(),
        stopped.clone(),
        lifecycle.clone(),
    );

    let result = (|| -> Result<(), String> {
        let mut output = emit;
        let mut seen_request_ids = HashSet::new();
        let mut pending_sends = 0usize;
        let mut deferred_events: VecDeque<(u64, Value)> = VecDeque::new();
        let mut pending_snapshot: Option<PendingSnapshot> = None;
        let mut completed_snapshot: Option<Snapshot> = None;
        let mut completed_snapshot_failure: Option<(u64, SnapshotFailure)> = None;
        let mut generation: u64 = 0;
        let mut snapshot_cycle: u64 = 0;
        let mut ready = false;
        let mut eof = false;
        let mut accepted_row_version = 0;
        let mut accepted_boundary = 0;

        'main: loop {
            if shutdown_requested(false, pending_sends, session_signal()) {
                stopped.store(true, Ordering::SeqCst);
                break 'main;
            }
            let message = if pending_sends == 0 {
                deferred_events
                    .pop_front()
                    .map(|frame| Worker::Frame(frame.0, frame.1))
                    .or_else(|| match worker_rx.recv_timeout(Duration::from_millis(50)) {
                        Ok(message) => Some(message),
                        Err(mpsc::RecvTimeoutError::Timeout) => Some(Worker::Tick),
                        Err(mpsc::RecvTimeoutError::Disconnected) => Some(Worker::Stop),
                    })
            } else {
                match worker_rx.recv_timeout(Duration::from_millis(50)) {
                    Ok(message) => Some(message),
                    Err(mpsc::RecvTimeoutError::Timeout) => Some(Worker::Tick),
                    Err(mpsc::RecvTimeoutError::Disconnected) => Some(Worker::Stop),
                }
            };

            let Some(message) = message else { break 'main };
            match message {
                Worker::Tick => {}
                Worker::Stop => break 'main,
                Worker::Connected(new_generation) => {
                    generation = new_generation;
                    set_lifecycle_generation(&lifecycle, generation);
                    snapshot_cycle = snapshot_cycle.saturating_add(1);
                    ready = false;
                    accepted_row_version = 0;
                    accepted_boundary = 0;
                    pending_snapshot = None;
                    completed_snapshot = None;
                    completed_snapshot_failure = None;
                    deferred_events.clear();
                }
                Worker::Frame(frame_generation, frame) if frame_generation == generation => {
                    if lifecycle_generation(&lifecycle) != generation {
                        continue;
                    }
                    let frame_type = frame.get("type").and_then(Value::as_str).unwrap_or("");
                    match frame_type {
                        "auth_result" => {
                            if frame.get("success") != Some(&Value::Bool(true)) {
                                emit(&fatal("auth_failed", "gateway authentication failed"))?;
                                stopped.store(true, Ordering::SeqCst);
                                return Err("gateway authentication failed".to_owned());
                            }
                        }
                        "subscription_ready" => {
                            begin_snapshot_after_subscription_ready(
                                &frame,
                                &endpoint,
                                &session_key,
                                generation,
                                snapshot_cycle,
                                &worker_tx,
                                &mut pending_snapshot,
                            );
                        }
                        "change" | "heartbeat" => {
                            if !stage_live_event(
                                frame_generation,
                                frame.clone(),
                                &mut pending_snapshot,
                                pending_sends,
                                &mut deferred_events,
                            ) {
                                if is_history_boundary_change(
                                    &frame,
                                    &session_key,
                                    accepted_row_version,
                                    accepted_boundary,
                                ) {
                                    emit(&snapshot_aborted(
                                        generation,
                                        snapshot_cycle,
                                        "history_boundary_changed",
                                        "snapshot history boundary changed during live delivery",
                                    ))?;
                                    emit(&event_frame(generation, frame.clone()))?;
                                    ready = false;
                                    snapshot_cycle = snapshot_cycle.saturating_add(1);
                                    begin_snapshot(
                                        &endpoint,
                                        &session_key,
                                        generation,
                                        snapshot_cycle,
                                        &worker_tx,
                                        &mut pending_snapshot,
                                    );
                                } else if ready {
                                    emit(&event_frame(generation, frame))?;
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Worker::Closed(closed_generation, failure) if closed_generation == generation => {
                    set_lifecycle_generation(&lifecycle, 0);
                    if pending_snapshot.is_some() {
                        emit(&snapshot_aborted(
                            generation,
                            snapshot_cycle,
                            "connection_lost",
                            "snapshot did not complete",
                        ))?;
                        pending_snapshot = None;
                    }
                    completed_snapshot = None;
                    completed_snapshot_failure = None;
                    deferred_events.clear();
                    ready = false;
                    emit(&json!({
                        "type": "connection",
                        "protocolVersion": PROTOCOL_VERSION,
                        "state": "reconnecting",
                        "generation": generation,
                        "code": failure.code,
                        "closeCode": failure.close_code,
                        "message": safe_reason(&failure.message),
                    }))?;
                }
                Worker::Fatal(failure) => {
                    set_lifecycle_generation(&lifecycle, 0);
                    emit(&fatal(&failure.code, &safe_reason(&failure.message)))?;
                    stopped.store(true, Ordering::SeqCst);
                    return Err(safe_reason(&failure.message));
                }
                Worker::SendResult { request_id, result } => {
                    pending_sends = pending_sends.saturating_sub(1);
                    match result {
                        Ok(wake_id) => emit(&json!({
                            "type": "send.accepted",
                            "protocolVersion": PROTOCOL_VERSION,
                            "requestId": request_id,
                            "wakeId": wake_id,
                        }))?,
                        Err(error) => emit(&json!({
                            "type": "send.rejected",
                            "protocolVersion": PROTOCOL_VERSION,
                            "requestId": request_id,
                            "code": error.code,
                            "message": error.message,
                        }))?,
                    }
                    if can_release_snapshot(pending_sends) {
                        if let Some((failure_cycle, error)) = completed_snapshot_failure.take() {
                            finish_snapshot_failure(
                                error,
                                generation,
                                failure_cycle,
                                &mut pending_snapshot,
                                &endpoint,
                                &session_key,
                                &mut snapshot_cycle,
                                &worker_tx,
                                &lifecycle,
                                &SESSION_SIGNAL,
                                &stopped,
                                &mut ready,
                                &mut output,
                            )?;
                        } else if let Some(snapshot) = completed_snapshot.take() {
                            finish_snapshot(
                                snapshot,
                                &mut pending_snapshot,
                                &endpoint,
                                &session_key,
                                generation,
                                &mut snapshot_cycle,
                                &worker_tx,
                                &mut accepted_row_version,
                                &mut accepted_boundary,
                                &mut ready,
                                &lifecycle,
                                &SESSION_SIGNAL,
                                &mut output,
                            )?;
                        }
                    }
                }
                Worker::SnapshotResult {
                    generation: result_generation,
                    cycle: result_cycle,
                    result,
                } => {
                    match admit_snapshot_result(
                        result_generation,
                        result_cycle,
                        result,
                        generation,
                        snapshot_cycle,
                        lifecycle_generation(&lifecycle),
                        pending_snapshot.as_ref(),
                        pending_sends,
                        &mut completed_snapshot,
                        &mut completed_snapshot_failure,
                    ) {
                        SnapshotResultAdmission::Ignore => continue,
                        SnapshotResultAdmission::Defer => {}
                        SnapshotResultAdmission::Complete(result) => match result {
                            Ok(snapshot) => {
                                finish_snapshot(
                                    snapshot,
                                    &mut pending_snapshot,
                                    &endpoint,
                                    &session_key,
                                    generation,
                                    &mut snapshot_cycle,
                                    &worker_tx,
                                    &mut accepted_row_version,
                                    &mut accepted_boundary,
                                    &mut ready,
                                    &lifecycle,
                                    &SESSION_SIGNAL,
                                    &mut output,
                                )?;
                            }
                            Err(error) => {
                                finish_snapshot_failure(
                                    error,
                                    generation,
                                    result_cycle,
                                    &mut pending_snapshot,
                                    &endpoint,
                                    &session_key,
                                    &mut snapshot_cycle,
                                    &worker_tx,
                                    &lifecycle,
                                    &SESSION_SIGNAL,
                                    &stopped,
                                    &mut ready,
                                    &mut output,
                                )?;
                            }
                        },
                    }
                }
                _ => {}
            }

            while let Ok(input) = input_rx.try_recv() {
                match input {
                    Input::Eof => {
                        eof = true;
                        if shutdown_requested(eof, pending_sends, None) {
                            stopped.store(true, Ordering::SeqCst);
                        }
                    }
                    Input::InvalidUtf8 if !eof => emit(&invalid_utf8_input_error())?,
                    Input::Line(line) if !eof => match parse_input(&line, &mut seen_request_ids) {
                        Ok(Some(frame)) => {
                            pending_sends += 1;
                            spawn_send(
                                endpoint.clone(),
                                session_key.clone(),
                                identity.clone(),
                                frame,
                                worker_tx.clone(),
                            );
                        }
                        Ok(None) => {}
                        Err((request_id, code, message)) => emit(&json!({
                            "type": "input.error",
                            "protocolVersion": PROTOCOL_VERSION,
                            "requestId": request_id,
                            "code": code,
                            "message": message,
                        }))?,
                    },
                    Input::Line(_) => {}
                    Input::InvalidUtf8 => {}
                }
            }

            if shutdown_requested(eof, pending_sends, None) {
                stopped.store(true, Ordering::SeqCst);
                break 'main;
            }
        }
        Ok(())
    })();

    stopped.store(true, Ordering::SeqCst);
    let _ = socket_worker.join();
    let signal_status = signal_exit_status(session_signal());
    drop(signal_guard);
    match signal_status {
        Some(status) => Err(signal_exit_error(status)),
        None => result,
    }
}

fn spawn_stdin_reader(tx: Sender<Input>) {
    thread::spawn(move || {
        let stdin = io::stdin();
        let mut reader = stdin.lock();
        let mut line = Vec::new();
        loop {
            line.clear();
            match reader.read_until(b'\n', &mut line) {
                Ok(0) => {
                    let _ = tx.send(Input::Eof);
                    break;
                }
                Ok(_) => match decode_input_line(&line) {
                    Input::Line(line) => {
                        if tx.send(Input::Line(line)).is_err() {
                            break;
                        }
                    }
                    Input::InvalidUtf8 => {
                        if tx.send(Input::InvalidUtf8).is_err() {
                            break;
                        }
                    }
                    Input::Eof => break,
                },
                Err(_) => {
                    let _ = tx.send(Input::Eof);
                    break;
                }
            }
        }
    });
}

fn spawn_socket_worker(
    endpoint: Endpoint,
    session_key: String,
    tx: Sender<Worker>,
    stopped: Arc<AtomicBool>,
    lifecycle: Arc<AtomicU64>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut generation = 0u64;
        while !stopped.load(Ordering::SeqCst) {
            generation = generation.saturating_add(1);
            let result = connect_and_read(
                &endpoint,
                &session_key,
                generation,
                &tx,
                &stopped,
                &lifecycle,
            );
            if let Err(error) = result {
                invalidate_lifecycle_generation(&lifecycle, generation);
                if stopped.load(Ordering::SeqCst) {
                    break;
                }
                if error.fatal {
                    let _ = tx.send(Worker::Fatal(error));
                    break;
                }
                let _ = tx.send(Worker::Closed(generation, error));
                thread::sleep(Duration::from_millis(250));
            }
        }
    })
}

fn connect_and_read(
    endpoint: &Endpoint,
    session_key: &str,
    generation: u64,
    tx: &Sender<Worker>,
    stopped: &Arc<AtomicBool>,
    lifecycle: &Arc<AtomicU64>,
) -> Result<(), ConnectionFailure> {
    let (mut socket, firehose_protocol) = connect_firehose(endpoint, stopped)?;

    let _ = set_read_timeout(socket.get_mut(), Some(Duration::from_millis(50)));
    if stopped.load(Ordering::SeqCst) {
        close_socket_normally(&mut socket);
        return Ok(());
    }

    socket
        .send(Message::Text(
            json!({"type": "auth", "token": endpoint.token}).to_string(),
        ))
        .map_err(|_| {
            ConnectionFailure::recoverable(
                "connection_lost",
                "websocket authentication request failed",
            )
        })?;

    let auth_frame = read_handshake_frame(&mut socket, stopped)?;
    if auth_frame.get("type").and_then(Value::as_str) != Some("auth_result")
        || auth_frame.get("success") != Some(&Value::Bool(true))
    {
        return Err(ConnectionFailure::fatal(
            "auth_failed",
            "gateway authentication failed",
        ));
    }

    socket
        .send(Message::Text(
            json!({
                "type": "subscribe",
                "protocolVersion": firehose_protocol,
                "subscriptionId": format!("external-agent-{generation}"),
                "filters": {
                    "sessionKey": session_key,
                    "classes": ["message.created", "wake.", "turn.", "session."]
                }
            })
            .to_string(),
        ))
        .map_err(|_| {
            ConnectionFailure::recoverable(
                "connection_lost",
                "websocket subscription request failed",
            )
        })?;

    let ready_frame = read_handshake_frame(&mut socket, stopped)?;
    if ready_frame.get("type").and_then(Value::as_str) != Some("subscription_ready") {
        return Err(ConnectionFailure::fatal(
            "invalid_subscription_response",
            "gateway did not acknowledge the subscription",
        ));
    }

    if stopped.load(Ordering::SeqCst) {
        close_socket_normally(&mut socket);
        return Ok(());
    }
    set_lifecycle_generation(lifecycle, generation);
    if tx.send(Worker::Connected(generation)).is_err() {
        return Ok(());
    }
    for frame in [auth_frame, ready_frame] {
        if tx.send(Worker::Frame(generation, frame)).is_err() {
            return Ok(());
        }
    }

    let mut last_seq = 0u64;
    while !stopped.load(Ordering::SeqCst) {
        let message = match socket.read() {
            Ok(message) => message,
            Err(WebSocketError::Io(error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(_) => {
                return Err(ConnectionFailure::recoverable(
                    "connection_lost",
                    "websocket connection lost",
                ));
            }
        };
        match message {
            Message::Text(text) => {
                let frame: Value = serde_json::from_str(&text).map_err(|_| {
                    ConnectionFailure::recoverable("connection_lost", "firehose frame was invalid")
                })?;
                if frame.get("type").and_then(Value::as_str) == Some("change")
                    && (frame.get("schemaVersion").and_then(Value::as_u64)
                        != Some(firehose_protocol)
                        || !session_change_frame_compatible(&frame))
                {
                    close_socket_with_protocol_error(&mut socket);
                    if let Err(error) = rebuild_session_collection(endpoint) {
                        return Err(ConnectionFailure::fatal(&error.code, &error.message));
                    }
                    let mut error = ConnectionFailure::fatal(
                        "schema_mismatch",
                        "Firehose frame did not match the negotiated schema",
                    );
                    error.close_code = Some(1002);
                    return Err(error);
                }
                if frame.get("type").and_then(Value::as_str) == Some("auth_result")
                    && frame.get("success") == Some(&Value::Bool(false))
                {
                    return Err(ConnectionFailure::fatal(
                        "auth_failed",
                        "gateway authentication failed",
                    ));
                }
                if let Some(seq) = frame.get("seq").and_then(Value::as_u64) {
                    if seq > last_seq.saturating_add(1) {
                        return Err(ConnectionFailure::recoverable(
                            "connection_lost",
                            "firehose sequence gap",
                        ));
                    }
                    if seq <= last_seq
                        && frame.get("type").and_then(Value::as_str) != Some("heartbeat")
                    {
                        continue;
                    }
                    last_seq = seq;
                }
                if tx.send(Worker::Frame(generation, frame)).is_err() {
                    return Ok(());
                }
            }
            Message::Ping(payload) => {
                socket.send(Message::Pong(payload)).map_err(|_| {
                    ConnectionFailure::recoverable("connection_lost", "websocket connection lost")
                })?;
            }
            Message::Close(frame) => return Err(close_failure(frame)),
            Message::Binary(_) => {
                return Err(ConnectionFailure::recoverable(
                    "connection_lost",
                    "firehose binary frame was invalid",
                ));
            }
            Message::Pong(_) => {}
            _ => {}
        }
    }
    close_socket_normally(&mut socket);
    invalidate_lifecycle_generation(lifecycle, generation);
    Ok(())
}

fn connect_firehose(
    endpoint: &Endpoint,
    stopped: &AtomicBool,
) -> Result<(tungstenite::WebSocket<MaybeTlsStream<TcpStream>>, u64), ConnectionFailure> {
    for protocol_version in FIREHOSE_PROTOCOL_PLAN {
        if stopped.load(Ordering::SeqCst) {
            return Err(ConnectionFailure::recoverable(
                "connection_lost",
                "websocket connection stopped",
            ));
        }

        let url = websocket_url(&endpoint.base, protocol_version);
        match connect(url.as_str()) {
            Ok((socket, _)) => return Ok((socket, protocol_version)),
            Err(WebSocketError::Http(response)) if response.status().as_u16() == 426 => {
                if response
                    .body()
                    .as_ref()
                    .is_some_and(|body| !body.is_empty())
                {
                    return Err(ConnectionFailure::fatal(
                        "invalid_protocol_refusal",
                        "gateway protocol refusal was not empty",
                    ));
                }

                rebuild_session_collection(endpoint)
                    .map_err(|error| ConnectionFailure::fatal(&error.code, &error.message))?;
            }
            Err(_) => {
                return Err(ConnectionFailure::recoverable(
                    "connection_lost",
                    "websocket connection failed",
                ));
            }
        }
    }

    Err(ConnectionFailure::fatal(
        "unsupported_protocol_version",
        "gateway refused every supported Firehose protocol",
    ))
}

fn read_handshake_frame(
    socket: &mut tungstenite::WebSocket<MaybeTlsStream<TcpStream>>,
    stopped: &AtomicBool,
) -> Result<Value, ConnectionFailure> {
    loop {
        if stopped.load(Ordering::SeqCst) {
            return Err(ConnectionFailure::recoverable(
                "connection_lost",
                "websocket connection stopped",
            ));
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                return serde_json::from_str(&text).map_err(|_| {
                    ConnectionFailure::recoverable(
                        "connection_lost",
                        "Firehose handshake frame was invalid",
                    )
                });
            }
            Ok(Message::Ping(payload)) => {
                socket.send(Message::Pong(payload)).map_err(|_| {
                    ConnectionFailure::recoverable("connection_lost", "websocket connection lost")
                })?;
            }
            Ok(Message::Close(frame)) => return Err(close_failure(frame)),
            Ok(Message::Binary(_)) => {
                return Err(ConnectionFailure::fatal(
                    "invalid_firehose_frame",
                    "Firehose handshake frame was binary",
                ));
            }
            Ok(_) => {}
            Err(WebSocketError::Io(error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(_) => {
                return Err(ConnectionFailure::recoverable(
                    "connection_lost",
                    "websocket connection lost",
                ));
            }
        }
    }
}

fn set_read_timeout(
    stream: &mut MaybeTlsStream<TcpStream>,
    timeout: Option<Duration>,
) -> io::Result<()> {
    match stream {
        MaybeTlsStream::Plain(stream) => stream.set_read_timeout(timeout),
        MaybeTlsStream::Rustls(stream) => stream.sock.set_read_timeout(timeout),
        _ => Ok(()),
    }
}

fn close_socket_normally(socket: &mut tungstenite::WebSocket<MaybeTlsStream<TcpStream>>) {
    let _ = socket.close(Some(normal_close_frame()));
}

fn normal_close_frame() -> tungstenite::protocol::CloseFrame<'static> {
    tungstenite::protocol::CloseFrame {
        code: tungstenite::protocol::frame::coding::CloseCode::Normal,
        reason: "client shutdown".into(),
    }
}

fn websocket_url(base: &str, protocol_version: u64) -> String {
    let base = base
        .trim_end_matches('/')
        .replacen("https://", "wss://", 1)
        .replacen("http://", "ws://", 1);
    format!("{base}/ws/changes?protocolVersion={protocol_version}")
}

fn close_socket_with_protocol_error(
    socket: &mut tungstenite::WebSocket<MaybeTlsStream<TcpStream>>,
) {
    let _ = socket.close(Some(tungstenite::protocol::CloseFrame {
        code: tungstenite::protocol::frame::coding::CloseCode::Protocol,
        reason: "schema mismatch".into(),
    }));
}

fn spawn_send(
    endpoint: Endpoint,
    session_key: String,
    identity: Identity,
    frame: SendFrame,
    tx: Sender<Worker>,
) {
    thread::spawn(move || {
        let has_idempotency_key = frame
            .idempotency_key
            .as_deref()
            .is_some_and(|key| !key.trim().is_empty());
        let request = Command::Wake {
            identity,
            target: Target::Session(session_key),
            prompt: frame.content,
            after_ms: None,
            at: None,
            condition_kind: None,
            condition_scope: None,
            predicate: None,
            assignment_id: None,
            after_turn: false,
            replace_queued: false,
            idempotency_key: frame.idempotency_key,
            class: None,
        };
        let result = dispatch::build_request(&request)
            .map_err(|error| SendFailure {
                code: "invalid_frame".to_owned(),
                message: safe_reason(&error),
            })
            .and_then(|request| {
                dispatch::send_to_for_session(&endpoint, &request).map_err(|error| {
                    let (code, message) = match error {
                        dispatch::SessionSendError::Transport(error) => (
                            "outcome_unknown".to_owned(),
                            format!(
                                "wake outcome is unknown; {}: {}",
                                if has_idempotency_key {
                                    "retry only with the same idempotencyKey"
                                } else {
                                    "do not retry without an idempotencyKey"
                                },
                                safe_reason(&error)
                            ),
                        ),
                        dispatch::SessionSendError::Response { code, message } => {
                            (code, safe_reason(&message))
                        }
                    };
                    SendFailure {
                        code: code.to_owned(),
                        message,
                    }
                })
            })
            .and_then(|value| {
                value
                    .and_then(|value| {
                        value
                            .get("wakeId")
                            .and_then(Value::as_str)
                            .map(str::to_owned)
                    })
                    .ok_or_else(|| SendFailure {
                        code: "server_error".to_owned(),
                        message: "gateway response did not contain wakeId".to_owned(),
                    })
            });
        let _ = tx.send(Worker::SendResult {
            request_id: frame.request_id,
            result,
        });
    });
}

fn stage_live_event(
    frame_generation: u64,
    frame: Value,
    pending_snapshot: &mut Option<PendingSnapshot>,
    pending_sends: usize,
    deferred_events: &mut VecDeque<(u64, Value)>,
) -> bool {
    if let Some(snapshot) = pending_snapshot.as_mut() {
        snapshot.events.push(frame);
        true
    } else if pending_sends > 0 {
        deferred_events.push_back((frame_generation, frame));
        true
    } else {
        false
    }
}

fn finish_snapshot(
    snapshot: Snapshot,
    pending_snapshot: &mut Option<PendingSnapshot>,
    endpoint: &Endpoint,
    session_key: &str,
    generation: u64,
    snapshot_cycle: &mut u64,
    worker_tx: &Sender<Worker>,
    accepted_row_version: &mut u64,
    accepted_boundary: &mut u64,
    ready: &mut bool,
    lifecycle: &AtomicU64,
    signal: &AtomicI32,
    output: &mut dyn FnMut(&Value) -> Result<(), String>,
) -> Result<(), String> {
    let pending_matches = pending_snapshot.as_ref().is_some_and(|pending| {
        pending.generation == generation && pending.cycle == *snapshot_cycle
    });
    if !pending_matches {
        *ready = false;
        return Ok(());
    }
    if lifecycle_generation(lifecycle) != generation {
        pending_snapshot.take();
        *ready = false;
        return output_snapshot_abort(
            generation,
            *snapshot_cycle,
            "connection_lost",
            "snapshot did not complete",
            signal,
            output,
        );
    }
    let events = pending_snapshot
        .as_ref()
        .expect("pending snapshot matched above")
        .events
        .clone();
    if events.iter().any(|event| {
        is_history_boundary_change(
            event,
            session_key,
            snapshot.row_version,
            snapshot.cleared_through_seq,
        )
    }) {
        pending_snapshot.take();
        output_snapshot_abort(
            generation,
            *snapshot_cycle,
            "history_boundary_changed",
            "snapshot history boundary changed during reads",
            signal,
            output,
        )?;
        if let Some(status) = snapshot_signal(signal) {
            return Err(signal_exit_error_for(status));
        }
        if lifecycle_generation(lifecycle) != generation {
            return Ok(());
        }
        *snapshot_cycle = snapshot_cycle.saturating_add(1);
        begin_snapshot(
            endpoint,
            session_key,
            generation,
            *snapshot_cycle,
            worker_tx,
            pending_snapshot,
        );
        *ready = false;
        return Ok(());
    }

    let cycle = *snapshot_cycle;
    let frame = json!({
        "type": "snapshot.begin",
        "protocolVersion": PROTOCOL_VERSION,
        "generation": generation,
        "snapshotCycle": cycle,
        "sessionKey": session_key,
        "resources": ["sessions", "transcript messages", "wakes", "turns"],
    });
    if let Err(error) = emit_snapshot_frame(lifecycle, signal, generation, frame, output) {
        return handle_snapshot_emission_error(
            error,
            generation,
            cycle,
            pending_snapshot,
            ready,
            signal,
            output,
        );
    }
    if let Err(error) = emit_snapshot_frame(
        lifecycle,
        signal,
        generation,
        json!({
            "type": "snapshot.item",
            "protocolVersion": PROTOCOL_VERSION,
            "generation": generation,
            "snapshotCycle": cycle,
            "resource": "sessions",
            "item": snapshot.session,
        }),
        output,
    ) {
        return handle_snapshot_emission_error(
            error,
            generation,
            cycle,
            pending_snapshot,
            ready,
            signal,
            output,
        );
    }
    for item in snapshot.messages {
        if let Err(error) = emit_snapshot_frame(
            lifecycle,
            signal,
            generation,
            json!({
                "type": "snapshot.item",
                "protocolVersion": PROTOCOL_VERSION,
                "generation": generation,
                "snapshotCycle": cycle,
                "resource": "transcript messages",
                "item": item,
            }),
            output,
        ) {
            return handle_snapshot_emission_error(
                error,
                generation,
                cycle,
                pending_snapshot,
                ready,
                signal,
                output,
            );
        }
    }
    for item in snapshot.wakes {
        if let Err(error) = emit_snapshot_frame(
            lifecycle,
            signal,
            generation,
            json!({
                "type": "snapshot.item",
                "protocolVersion": PROTOCOL_VERSION,
                "generation": generation,
                "snapshotCycle": cycle,
                "resource": "wakes",
                "item": item,
            }),
            output,
        ) {
            return handle_snapshot_emission_error(
                error,
                generation,
                cycle,
                pending_snapshot,
                ready,
                signal,
                output,
            );
        }
    }
    for item in snapshot.turns {
        if let Err(error) = emit_snapshot_frame(
            lifecycle,
            signal,
            generation,
            json!({
                "type": "snapshot.item",
                "protocolVersion": PROTOCOL_VERSION,
                "generation": generation,
                "snapshotCycle": cycle,
                "resource": "turns",
                "item": item,
            }),
            output,
        ) {
            return handle_snapshot_emission_error(
                error,
                generation,
                cycle,
                pending_snapshot,
                ready,
                signal,
                output,
            );
        }
    }
    if let Err(error) = emit_snapshot_frame(
        lifecycle,
        signal,
        generation,
        json!({
        "type": "snapshot.end",
        "protocolVersion": PROTOCOL_VERSION,
        "generation": generation,
        "snapshotCycle": cycle,
        "sessionKey": session_key,
        }),
        output,
    ) {
        return handle_snapshot_emission_error(
            error,
            generation,
            cycle,
            pending_snapshot,
            ready,
            signal,
            output,
        );
    }
    for event in events {
        if let Err(error) = emit_snapshot_frame(
            lifecycle,
            signal,
            generation,
            event_frame(generation, event),
            output,
        ) {
            return handle_snapshot_emission_error(
                error,
                generation,
                cycle,
                pending_snapshot,
                ready,
                signal,
                output,
            );
        }
    }
    if let Err(error) = emit_snapshot_frame(
        lifecycle,
        signal,
        generation,
        json!({
        "type": "ready",
        "protocolVersion": PROTOCOL_VERSION,
        "generation": generation,
        "snapshotCycle": cycle,
        "sessionKey": session_key,
        }),
        output,
    ) {
        return handle_snapshot_emission_error(
            error,
            generation,
            cycle,
            pending_snapshot,
            ready,
            signal,
            output,
        );
    }
    pending_snapshot.take();
    *accepted_row_version = snapshot.row_version;
    *accepted_boundary = snapshot.cleared_through_seq;
    *ready = true;
    Ok(())
}

fn finish_snapshot_failure(
    error: SnapshotFailure,
    generation: u64,
    cycle: u64,
    pending_snapshot: &mut Option<PendingSnapshot>,
    endpoint: &Endpoint,
    session_key: &str,
    snapshot_cycle: &mut u64,
    worker_tx: &Sender<Worker>,
    lifecycle: &AtomicU64,
    signal: &AtomicI32,
    stopped: &AtomicBool,
    ready: &mut bool,
    output: &mut dyn FnMut(&Value) -> Result<(), String>,
) -> Result<(), String> {
    let pending_matches = pending_snapshot
        .as_ref()
        .is_some_and(|pending| pending.generation == generation && pending.cycle == cycle);
    if !pending_matches || *snapshot_cycle != cycle {
        *ready = false;
        return Ok(());
    }

    *ready = false;
    *pending_snapshot = None;
    if let Some(status) = snapshot_signal(signal) {
        return Err(signal_exit_error_for(status));
    }
    if lifecycle_generation(lifecycle) != generation {
        output(&snapshot_aborted(
            generation,
            cycle,
            "connection_lost",
            "snapshot did not complete",
        ))?;
        return Ok(());
    }
    output(&snapshot_aborted(
        generation,
        cycle,
        &error.code,
        &error.message,
    ))?;
    if let Some(status) = snapshot_signal(signal) {
        return Err(signal_exit_error_for(status));
    }
    if lifecycle_generation(lifecycle) != generation {
        return Ok(());
    }
    if error.retryable {
        *snapshot_cycle = cycle.saturating_add(1);
        begin_snapshot(
            endpoint,
            session_key,
            generation,
            *snapshot_cycle,
            worker_tx,
            pending_snapshot,
        );
        return Ok(());
    }

    if let Some(status) = snapshot_signal(signal) {
        return Err(signal_exit_error_for(status));
    }
    lifecycle.store(0, Ordering::SeqCst);
    output(&fatal(&error.code, &error.message))?;
    stopped.store(true, Ordering::SeqCst);
    Err(error.message)
}

fn emit_snapshot_frame(
    lifecycle: &AtomicU64,
    signal: &AtomicI32,
    generation: u64,
    frame: Value,
    output: &mut dyn FnMut(&Value) -> Result<(), String>,
) -> Result<(), SnapshotEmissionError> {
    if let Some(status) = snapshot_signal(signal) {
        return Err(SnapshotEmissionError::Signaled(status));
    }
    if lifecycle_generation(lifecycle) != generation {
        return Err(SnapshotEmissionError::Closed);
    }
    output(&frame).map_err(SnapshotEmissionError::Output)
}

fn handle_snapshot_emission_error(
    error: SnapshotEmissionError,
    generation: u64,
    cycle: u64,
    pending_snapshot: &mut Option<PendingSnapshot>,
    ready: &mut bool,
    signal: &AtomicI32,
    output: &mut dyn FnMut(&Value) -> Result<(), String>,
) -> Result<(), String> {
    match error {
        SnapshotEmissionError::Closed => {
            pending_snapshot.take();
            *ready = false;
            output_snapshot_abort(
                generation,
                cycle,
                "connection_lost",
                "snapshot did not complete",
                signal,
                output,
            )
        }
        SnapshotEmissionError::Signaled(status) => {
            pending_snapshot.take();
            *ready = false;
            Err(signal_exit_error_for(status))
        }
        SnapshotEmissionError::Output(error) => {
            pending_snapshot.take();
            *ready = false;
            Err(error)
        }
    }
}

fn output_snapshot_abort(
    generation: u64,
    cycle: u64,
    code: &str,
    message: &str,
    signal: &AtomicI32,
    output: &mut dyn FnMut(&Value) -> Result<(), String>,
) -> Result<(), String> {
    if let Some(status) = snapshot_signal(signal) {
        return Err(signal_exit_error_for(status));
    }
    output(&snapshot_aborted(generation, cycle, code, message))?;
    if let Some(status) = snapshot_signal(signal) {
        return Err(signal_exit_error_for(status));
    }
    Ok(())
}

fn begin_snapshot(
    endpoint: &Endpoint,
    session_key: &str,
    generation: u64,
    cycle: u64,
    tx: &Sender<Worker>,
    pending: &mut Option<PendingSnapshot>,
) {
    *pending = Some(PendingSnapshot {
        generation,
        cycle,
        events: Vec::new(),
    });
    let endpoint = endpoint.clone();
    let session_key = session_key.to_owned();
    let tx = tx.clone();
    thread::spawn(move || {
        let result = load_snapshot(&endpoint, &session_key);
        let _ = tx.send(Worker::SnapshotResult {
            generation,
            cycle,
            result,
        });
    });
}

fn begin_snapshot_after_subscription_ready(
    frame: &Value,
    endpoint: &Endpoint,
    session_key: &str,
    generation: u64,
    cycle: u64,
    tx: &Sender<Worker>,
    pending: &mut Option<PendingSnapshot>,
) {
    if frame.get("type").and_then(Value::as_str) == Some("subscription_ready") {
        begin_snapshot(endpoint, session_key, generation, cycle, tx, pending);
    }
}

fn close_failure(frame: Option<tungstenite::protocol::CloseFrame>) -> ConnectionFailure {
    let Some(frame) = frame else {
        return ConnectionFailure::recoverable("connection_lost", "gateway connection closed");
    };
    let close_code = u16::from(frame.code);
    let reason = safe_reason(frame.reason.as_ref());
    let message = if reason == "gateway connection failed" {
        format!("gateway connection closed (close code {close_code})")
    } else {
        format!("gateway connection closed (close code {close_code}): {reason}")
    };
    let mut failure = match close_code {
        1008 => ConnectionFailure::fatal(
            "auth_failed",
            "gateway policy closed the connection; credential or session is no longer authorized",
        ),
        1002 => ConnectionFailure::fatal("protocol_error", &message),
        1012 => ConnectionFailure::recoverable("server_restart", &message),
        _ => ConnectionFailure::recoverable("connection_lost", &message),
    };
    failure.close_code = Some(close_code);
    failure
}

fn load_snapshot(endpoint: &Endpoint, session_key: &str) -> Result<Snapshot, SnapshotFailure> {
    let session_path = format!("/api/sessions/{}", encode_path(session_key));
    let first = get_json(endpoint, &session_path)?;
    let session = first
        .get("item")
        .cloned()
        .ok_or_else(|| snapshot_failure("projection_invalid", false))?;
    if !session_item_capability_compatible(&session) {
        return Err(snapshot_failure("projection_invalid", false));
    }
    let row_version = session
        .get("rowVersion")
        .and_then(Value::as_u64)
        .ok_or_else(|| snapshot_failure("projection_invalid", false))?;
    let cleared_through_seq = session
        .get("clearedThroughSeq")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let messages = get_collection(endpoint, &format!("{session_path}/messages"), session_key)?;
    let wakes = get_collection(endpoint, &format!("{session_path}/wakes"), session_key)?;
    let turns = get_collection(endpoint, &format!("{session_path}/turns"), session_key)?;
    let second = get_json(endpoint, &session_path)?;
    let second_session = second
        .get("item")
        .ok_or_else(|| snapshot_failure("projection_invalid", false))?;
    if second_session.get("rowVersion") != Some(&json!(row_version))
        || second_session.get("clearedThroughSeq") != Some(&json!(cleared_through_seq))
    {
        return Err(snapshot_failure("history_boundary_changed", true));
    }

    let mut messages = messages;
    messages.retain(|message| {
        message
            .get("seq")
            .and_then(Value::as_u64)
            .is_some_and(|seq| seq > cleared_through_seq)
    });
    messages.sort_by_key(|item| {
        (
            item.get("seq").and_then(Value::as_u64).unwrap_or(0),
            item.get("id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
        )
    });
    let mut wakes = wakes;
    wakes.sort_by_key(|item| {
        (
            item.get("createdAt").and_then(Value::as_u64).unwrap_or(0),
            item.get("wakeId")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
        )
    });
    let mut turns = turns;
    turns.sort_by_key(|item| {
        (
            item.get("createdAt").and_then(Value::as_u64).unwrap_or(0),
            item.get("seq").and_then(Value::as_u64).unwrap_or(0),
        )
    });
    Ok(Snapshot {
        session: second_session.clone(),
        messages,
        wakes,
        turns,
        row_version,
        cleared_through_seq,
    })
}

fn get_collection(
    endpoint: &Endpoint,
    path: &str,
    session_key: &str,
) -> Result<Vec<Value>, SnapshotFailure> {
    let mut cursor: Option<String> = None;
    let mut items = Vec::new();
    loop {
        let query = match &cursor {
            Some(cursor) => format!(
                "?sessionKey={}&limit={SNAPSHOT_LIMIT}&after={}",
                encode_path(session_key),
                encode_path(cursor)
            ),
            None => format!(
                "?sessionKey={}&limit={SNAPSHOT_LIMIT}",
                encode_path(session_key)
            ),
        };
        let response = get_json(endpoint, &(path.to_owned() + &query))?;
        let page_items = response
            .get("items")
            .and_then(Value::as_array)
            .ok_or_else(|| snapshot_failure("projection_invalid", false))?;
        items.extend(page_items.iter().cloned());
        let page = response.get("page").cloned().unwrap_or(Value::Null);
        if page.get("hasMoreAfter") == Some(&Value::Bool(true)) {
            cursor = page
                .get("newestCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            if cursor.is_none() {
                return Err(snapshot_failure("projection_invalid", false));
            }
        } else {
            return Ok(items);
        }
    }
}

fn get_json(endpoint: &Endpoint, path: &str) -> Result<Value, SnapshotFailure> {
    let call =
        dispatch::gateway_request("GET", endpoint, path, Some(Duration::from_secs(15))).call();
    let (status, response) = match call {
        Ok(response) => (response.status(), response),
        Err(ureq::Error::Status(status, response)) => (status, response),
        Err(ureq::Error::Transport(_)) => return Err(snapshot_failure("connection_lost", true)),
    };
    let body = response
        .into_string()
        .map_err(|_| snapshot_failure("projection_invalid", false))?;
    let value: Value =
        serde_json::from_str(&body).map_err(|_| snapshot_failure("projection_invalid", false))?;
    if !(200..300).contains(&status) {
        let code = value
            .pointer("/error/code")
            .and_then(Value::as_str)
            .unwrap_or("auth_failed");
        return Err(snapshot_failure(code, false));
    }
    Ok(value)
}

fn rebuild_session_collection(endpoint: &Endpoint) -> Result<Vec<Value>, SnapshotFailure> {
    let response = get_json(endpoint, "/api/sessions")?;
    if response.get("schemaVersion") != Some(&json!(1)) {
        return Err(snapshot_failure("projection_invalid", false));
    }
    let sessions = response
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .ok_or_else(|| snapshot_failure("projection_invalid", false))?;
    if sessions
        .iter()
        .any(|session| !session_item_capability_compatible(session))
    {
        return Err(snapshot_failure("projection_invalid", false));
    }
    Ok(sessions)
}

fn session_change_frame_compatible(frame: &Value) -> bool {
    match frame.get("class").and_then(Value::as_str) {
        Some(
            "session.spawned" | "session.updated" | "session.harness_changed" | "session.retired",
        ) => frame
            .get("payload")
            .is_some_and(session_item_capability_compatible),
        _ => true,
    }
}

fn session_item_capability_compatible(item: &Value) -> bool {
    if !item.is_object() {
        return false;
    }
    let Some(capabilities) = item.get("capabilities") else {
        return true;
    };
    let Some(capabilities) = capabilities.as_object() else {
        return false;
    };
    let Some(capability) = capabilities.get("setHarness") else {
        return true;
    };
    capabilities.len() == 1 && set_harness_capability_compatible(capability)
}

fn set_harness_capability_compatible(capability: &Value) -> bool {
    let Some(capability) = capability.as_object() else {
        return false;
    };
    match capability.get("supported") {
        Some(Value::Bool(false)) => {
            capability.len() == 2 && capability.get("reason").is_some_and(Value::is_string)
        }
        Some(Value::Bool(true)) => {
            let Some(options) = capability.get("options").and_then(Value::as_array) else {
                return false;
            };
            capability.len() == 2
                && options.iter().all(|option| {
                    let Some(option) = option.as_object() else {
                        return false;
                    };
                    option.len() == 3
                        && option
                            .get("title")
                            .and_then(Value::as_str)
                            .is_some_and(|title| {
                                !title.is_empty()
                                    && option.get("value").and_then(Value::as_str) == Some(title)
                            })
                        && option.get("enabled").is_some_and(Value::is_boolean)
                })
                && options
                    .iter()
                    .any(|option| option["enabled"] == Value::Bool(true))
        }
        _ => false,
    }
}

fn parse_input(
    line: &str,
    seen_request_ids: &mut HashSet<String>,
) -> Result<Option<SendFrame>, (Value, String, String)> {
    if line.trim().is_empty() {
        return Ok(None);
    }
    let value: Value = serde_json::from_str(line.trim_end_matches(['\r', '\n'])).map_err(|_| {
        (
            Value::Null,
            "invalid_json".to_owned(),
            "stdin line is not valid JSON".to_owned(),
        )
    })?;
    let object = value.as_object().ok_or_else(|| {
        (
            Value::Null,
            "invalid_frame".to_owned(),
            "stdin frame must be a JSON object".to_owned(),
        )
    })?;
    let allowed = [
        "type",
        "protocolVersion",
        "requestId",
        "content",
        "idempotencyKey",
    ];
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err((
            Value::Null,
            "invalid_frame".to_owned(),
            "stdin frame contains an unknown key".to_owned(),
        ));
    }
    if object.get("type").and_then(Value::as_str) != Some("send") {
        return Err((
            Value::Null,
            "invalid_frame".to_owned(),
            "stdin type must be send".to_owned(),
        ));
    }
    if object.get("protocolVersion").and_then(Value::as_u64) != Some(PROTOCOL_VERSION) {
        return Err((
            Value::Null,
            "unsupported_protocol_version".to_owned(),
            "protocolVersion must be 1".to_owned(),
        ));
    }
    let request_id = object
        .get("requestId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            (
                Value::Null,
                "invalid_frame".to_owned(),
                "requestId must be a nonempty string".to_owned(),
            )
        })?
        .to_owned();
    let content = object
        .get("content")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            (
                Value::String(request_id.clone()),
                "invalid_frame".to_owned(),
                "content must be a nonempty string".to_owned(),
            )
        })?
        .to_owned();
    let idempotency_key = match object.get("idempotencyKey") {
        None => None,
        Some(Value::String(value)) if !value.is_empty() => Some(value.clone()),
        _ => {
            return Err((
                Value::String(request_id),
                "invalid_frame".to_owned(),
                "idempotencyKey must be a nonempty string".to_owned(),
            ));
        }
    };
    if !seen_request_ids.insert(request_id.clone()) {
        return Err((
            Value::String(request_id),
            "duplicate_request_id".to_owned(),
            "requestId was already used".to_owned(),
        ));
    }
    Ok(Some(SendFrame {
        request_id,
        content,
        idempotency_key,
    }))
}

fn is_history_boundary_change(
    frame: &Value,
    session_key: &str,
    row_version: u64,
    boundary: u64,
) -> bool {
    frame.get("class").and_then(Value::as_str) == Some("session.updated")
        && frame
            .pointer("/refs/sessionKey")
            .and_then(Value::as_str)
            .is_some_and(|key| key == session_key)
        && frame
            .pointer("/payload/rowVersion")
            .and_then(Value::as_u64)
            .is_some_and(|version| version > row_version)
        && frame
            .pointer("/payload/clearedThroughSeq")
            .and_then(Value::as_u64)
            .is_some_and(|value| value != boundary)
}

fn event_frame(generation: u64, event: Value) -> Value {
    json!({
        "type": "event",
        "protocolVersion": PROTOCOL_VERSION,
        "generation": generation,
        "event": event,
    })
}

fn snapshot_aborted(generation: u64, cycle: u64, code: &str, message: &str) -> Value {
    json!({
        "type": "snapshot.aborted",
        "protocolVersion": PROTOCOL_VERSION,
        "generation": generation,
        "snapshotCycle": cycle,
        "code": code,
        "message": message,
    })
}

fn invalid_utf8_input_error() -> Value {
    json!({
        "type": "input.error",
        "protocolVersion": PROTOCOL_VERSION,
        "requestId": Value::Null,
        "code": "invalid_utf8",
        "message": "stdin line is not valid UTF-8",
    })
}

fn fatal(code: &str, message: &str) -> Value {
    json!({
        "type": "fatal",
        "protocolVersion": PROTOCOL_VERSION,
        "code": code,
        "message": message,
    })
}

fn snapshot_failure(code: &str, retryable: bool) -> SnapshotFailure {
    SnapshotFailure {
        code: code.to_owned(),
        message: match code {
            "history_boundary_changed" => {
                "snapshot history boundary changed during reads".to_owned()
            }
            "connection_lost" => "snapshot did not complete".to_owned(),
            _ => "snapshot could not be completed".to_owned(),
        },
        retryable,
    }
}

fn safe_reason(reason: &str) -> String {
    if reason.is_empty() {
        "gateway connection failed".to_owned()
    } else {
        reason.chars().take(160).collect()
    }
}

fn session_signal() -> Option<i32> {
    snapshot_signal(&SESSION_SIGNAL)
}

fn snapshot_signal(signal: &AtomicI32) -> Option<i32> {
    match signal.load(Ordering::SeqCst) {
        libc::SIGINT | libc::SIGTERM => Some(signal.load(Ordering::SeqCst)),
        _ => None,
    }
}

fn encode_path(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                vec![byte as char]
            }
            byte => format!("%{byte:02X}").chars().collect(),
        })
        .collect()
}

fn decode_input_line(bytes: &[u8]) -> Input {
    match String::from_utf8(bytes.to_vec()) {
        Ok(line) => Input::Line(line),
        Err(_) => Input::InvalidUtf8,
    }
}

fn snapshot_result_is_current(
    result_generation: u64,
    result_cycle: u64,
    current_generation: u64,
    current_cycle: u64,
    active_generation: u64,
    pending: Option<&PendingSnapshot>,
) -> bool {
    result_generation == current_generation
        && result_cycle == current_cycle
        && active_generation == current_generation
        && pending.is_some_and(|pending| {
            pending.generation == result_generation && pending.cycle == result_cycle
        })
}

fn snapshot_result_disposition(
    result_generation: u64,
    result_cycle: u64,
    current_generation: u64,
    current_cycle: u64,
    active_generation: u64,
    pending: Option<&PendingSnapshot>,
    pending_sends: usize,
) -> SnapshotResultDisposition {
    if !snapshot_result_is_current(
        result_generation,
        result_cycle,
        current_generation,
        current_cycle,
        active_generation,
        pending,
    ) {
        SnapshotResultDisposition::Ignore
    } else if pending_sends > 0 {
        SnapshotResultDisposition::Defer
    } else {
        SnapshotResultDisposition::Complete
    }
}

fn admit_snapshot_result(
    result_generation: u64,
    result_cycle: u64,
    result: Result<Snapshot, SnapshotFailure>,
    current_generation: u64,
    current_cycle: u64,
    active_generation: u64,
    pending: Option<&PendingSnapshot>,
    pending_sends: usize,
    completed_snapshot: &mut Option<Snapshot>,
    completed_snapshot_failure: &mut Option<(u64, SnapshotFailure)>,
) -> SnapshotResultAdmission {
    match snapshot_result_disposition(
        result_generation,
        result_cycle,
        current_generation,
        current_cycle,
        active_generation,
        pending,
        pending_sends,
    ) {
        SnapshotResultDisposition::Ignore => SnapshotResultAdmission::Ignore,
        SnapshotResultDisposition::Defer => {
            match result {
                Ok(snapshot) => *completed_snapshot = Some(snapshot),
                Err(error) => *completed_snapshot_failure = Some((result_cycle, error)),
            }
            SnapshotResultAdmission::Defer
        }
        SnapshotResultDisposition::Complete => SnapshotResultAdmission::Complete(result),
    }
}

fn lifecycle_generation(lifecycle: &AtomicU64) -> u64 {
    lifecycle.load(Ordering::SeqCst)
}

fn set_lifecycle_generation(lifecycle: &AtomicU64, generation: u64) {
    lifecycle.store(generation, Ordering::SeqCst);
}

fn invalidate_lifecycle_generation(lifecycle: &AtomicU64, generation: u64) {
    let _ = lifecycle.compare_exchange(generation, 0, Ordering::SeqCst, Ordering::SeqCst);
}

fn can_release_snapshot(pending_sends: usize) -> bool {
    pending_sends == 0
}

fn shutdown_requested(eof: bool, pending_sends: usize, signal: Option<i32>) -> bool {
    signal.is_some() || (eof && can_release_snapshot(pending_sends))
}

fn signal_exit_status(signal: Option<i32>) -> Option<i32> {
    match signal {
        Some(libc::SIGINT) => Some(128 + libc::SIGINT),
        Some(libc::SIGTERM) => Some(128 + libc::SIGTERM),
        _ => None,
    }
}

fn signal_exit_error(status: i32) -> String {
    format!("{SIGNAL_EXIT_PREFIX}{status}")
}

fn signal_exit_error_for(signal: i32) -> String {
    signal_exit_error(signal_exit_status(Some(signal)).unwrap_or(signal))
}

pub fn exit_status(error: &str) -> Option<i32> {
    error
        .strip_prefix(SIGNAL_EXIT_PREFIX)
        .and_then(|status| status.parse().ok())
}

fn emit(value: &Value) -> Result<(), String> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value).map_err(|_| "stdout_failed".to_owned())?;
    stdout
        .write_all(b"\n")
        .map_err(|_| "stdout_failed".to_owned())?;
    stdout.flush().map_err(|_| "stdout_failed".to_owned())
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{TcpListener, TcpStream};

    use super::*;

    fn endpoint(listener: &TcpListener) -> Endpoint {
        Endpoint {
            base: format!("http://{}", listener.local_addr().unwrap()),
            token: "tbc_session_connect_test".to_owned(),
            origin: crate::dispatch::Origin::Named,
        }
    }

    fn read_http_request(stream: &mut TcpStream) -> String {
        let mut reader = BufReader::new(stream);
        let mut request = String::new();
        let mut content_length = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line.is_empty() {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                if name.eq_ignore_ascii_case("content-length") {
                    content_length = value.trim().parse().unwrap();
                }
            }
            let finished = line == "\r\n";
            request.push_str(&line);
            if finished {
                break;
            }
        }
        let mut body = vec![0; content_length];
        reader.read_exact(&mut body).unwrap();
        request.push_str(&String::from_utf8(body).unwrap());
        request
    }

    fn write_json_response(stream: &mut TcpStream, status: &str, extra: &str, body: &str) {
        write!(
            stream,
            "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n{extra}\r\n{body}",
            body.len()
        )
        .unwrap();
        stream.flush().unwrap();
    }

    fn assert_gateway_headers(request: &str) {
        let lower = request.to_ascii_lowercase();
        assert!(
            lower.contains("authorization: bearer tbc_session_connect_test\r\n"),
            "{request}"
        );
        assert!(
            lower.contains("x-tightbeam-cli-version: 0.1.9\r\n"),
            "{request}"
        );
    }

    fn accept_subscribed_socket(
        stream: TcpStream,
        protocol_version: u64,
    ) -> (tungstenite::WebSocket<TcpStream>, Value) {
        let mut socket = tungstenite::accept_hdr(
            stream,
            |request: &tungstenite::handshake::server::Request, response| {
                assert_eq!(
                    request.uri().query(),
                    Some(format!("protocolVersion={protocol_version}").as_str())
                );
                Ok(response)
            },
        )
        .unwrap();

        let Message::Text(auth) = socket.read().unwrap() else {
            panic!("expected auth request")
        };
        assert_eq!(
            serde_json::from_str::<Value>(&auth).unwrap()["type"],
            "auth"
        );
        socket
            .send(Message::Text(
                json!({"type": "auth_result", "success": true}).to_string(),
            ))
            .unwrap();

        let Message::Text(subscribe) = socket.read().unwrap() else {
            panic!("expected subscribe request")
        };
        let subscribe: Value = serde_json::from_str(&subscribe).unwrap();
        assert_eq!(subscribe["type"], "subscribe");
        assert_eq!(subscribe["protocolVersion"], protocol_version);
        socket
            .send(Message::Text(
                json!({"type": "subscription_ready", "subscriptionId": "external-agent-1"})
                    .to_string(),
            ))
            .unwrap();
        (socket, subscribe)
    }

    fn send_frame(endpoint: Endpoint, idempotency_key: Option<&str>) -> (String, SendFailure) {
        let (tx, rx) = mpsc::channel();
        spawn_send(
            endpoint,
            "agent:main/example".to_owned(),
            Identity::Session,
            SendFrame {
                request_id: "request-1".to_owned(),
                content: "synthetic message".to_owned(),
                idempotency_key: idempotency_key.map(str::to_owned),
            },
            tx,
        );
        match rx.recv_timeout(Duration::from_secs(3)).unwrap() {
            Worker::SendResult {
                request_id,
                result: Err(error),
            } => (request_id, error),
            other => panic!("expected a failed session wake, got {other:?}"),
        }
    }

    fn respond_to_snapshot_request(stream: &mut TcpStream, request_number: usize) {
        let session = json!({
            "item": {
                "sessionKey": "agent:main/example",
                "rowVersion": 7,
                "clearedThroughSeq": 2,
                "capabilities": {
                    "setHarness": {
                        "supported": false,
                        "reason": "session is not active"
                    }
                }
            }
        });
        let collection = json!({
            "items": [],
            "page": {"hasMoreAfter": false}
        });
        let body = if request_number == 0 || request_number == 4 {
            session.to_string()
        } else {
            collection.to_string()
        };
        write_json_response(stream, "200 OK", "", &body);
    }

    #[test]
    fn snapshot_uses_each_rest_path_and_the_shared_gateway_request_headers() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let session_key = "agent:main/example";
        let encoded_key = encode_path(session_key);
        let expected = [
            format!("GET /api/sessions/{encoded_key} HTTP/1.1"),
            format!(
                "GET /api/sessions/{encoded_key}/messages?sessionKey={encoded_key}&limit=500 HTTP/1.1"
            ),
            format!(
                "GET /api/sessions/{encoded_key}/wakes?sessionKey={encoded_key}&limit=500 HTTP/1.1"
            ),
            format!(
                "GET /api/sessions/{encoded_key}/turns?sessionKey={encoded_key}&limit=500 HTTP/1.1"
            ),
            format!("GET /api/sessions/{encoded_key} HTTP/1.1"),
        ];
        let server = thread::spawn(move || {
            let mut requests = Vec::new();
            for index in 0..expected.len() {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_http_request(&mut stream);
                respond_to_snapshot_request(&mut stream, index);
                requests.push(request);
            }
            (expected, requests)
        });

        let snapshot = load_snapshot(&endpoint, session_key).unwrap();
        let (expected, requests) = server.join().unwrap();
        assert_eq!(
            requests.len(),
            5,
            "four unique REST paths, five boundary-checked GETs"
        );
        for (request, expected_line) in requests.iter().zip(expected) {
            assert_eq!(request.lines().next(), Some(expected_line.as_str()));
            assert_gateway_headers(request);
        }
        assert_eq!(snapshot.row_version, 7);
        assert_eq!(snapshot.cleared_through_seq, 2);
        assert!(snapshot.messages.is_empty());
        assert!(snapshot.wakes.is_empty());
        assert!(snapshot.turns.is_empty());
    }

    #[test]
    fn snapshot_redirect_is_returned_as_a_gateway_failure_without_following_it() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_http_request(&mut stream);
            write_json_response(
                &mut stream,
                "302 Found",
                "location: /must-not-follow\r\n",
                r#"{"error":{"code":"snapshot_redirect","message":"gateway redirect"}}"#,
            );
            request
        });

        let error = load_snapshot(&endpoint, "agent:main/example").unwrap_err();
        let request = server.join().unwrap();
        assert!(request.starts_with("GET /api/sessions/agent%3Amain%2Fexample HTTP/1.1"));
        assert_gateway_headers(&request);
        assert_eq!(error.code, "snapshot_redirect");
        assert!(!error.retryable);
    }

    #[test]
    fn session_wake_redirect_keeps_the_gateway_refusal_and_does_not_follow_it() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_http_request(&mut stream);
            write_json_response(
                &mut stream,
                "302 Found",
                "location: /must-not-follow\r\n",
                r#"{"error":{"code":"wake_redirect","message":"wake was redirected"}}"#,
            );
            request
        });

        let (request_id, error) = send_frame(endpoint, Some("retry-key"));
        let request = server.join().unwrap();
        assert_eq!(request_id, "request-1");
        assert!(request.starts_with("POST /agent/dispatch HTTP/1.1"));
        assert_gateway_headers(&request);
        assert_eq!(error.code, "wake_redirect");
        assert_eq!(error.message, "wake was redirected");
    }

    #[test]
    fn session_wake_transport_failure_only_advises_retry_when_a_key_exists() {
        for (key, expected_guidance) in [
            (Some("retry-key"), "retry only with the same idempotencyKey"),
            (None, "do not retry without an idempotencyKey"),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let endpoint = endpoint(&listener);
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_http_request(&mut stream);
                drop(stream);
                request
            });

            let (request_id, error) = send_frame(endpoint, key);
            let request = server.join().unwrap();
            assert_eq!(request_id, "request-1");
            assert!(request.starts_with("POST /agent/dispatch HTTP/1.1"));
            assert_gateway_headers(&request);
            assert_eq!(error.code, "outcome_unknown");
            assert!(
                error.message.contains(expected_guidance),
                "{}",
                error.message
            );
        }
    }

    #[test]
    fn websocket_handshake_failure_is_reported_without_ureq_phase_claims() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_http_request(&mut stream);
            write!(
                stream,
                "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )
            .unwrap();
            stream.flush().unwrap();
            request
        });

        let (tx, _rx) = mpsc::channel();
        let stopped = Arc::new(AtomicBool::new(false));
        let lifecycle = Arc::new(AtomicU64::new(0));
        let failure = connect_and_read(
            &endpoint,
            "agent:main/example",
            1,
            &tx,
            &stopped,
            &lifecycle,
        )
        .unwrap_err();
        let request = server.join().unwrap();

        assert!(request.starts_with("GET /ws/changes?protocolVersion=2 HTTP/1.1"));
        assert_eq!(failure.code, "connection_lost");
        assert_eq!(failure.message, "websocket connection failed");
        assert_eq!(failure.close_code, None);
    }

    #[test]
    fn protocol_426_rebuilds_before_the_single_legacy_fallback() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let server = thread::spawn(move || {
            let (mut refusal, _) = listener.accept().unwrap();
            let offer = read_http_request(&mut refusal);
            assert!(offer.starts_with("GET /ws/changes?protocolVersion=2 HTTP/1.1"));
            write!(
                refusal,
                "HTTP/1.1 426 Upgrade Required\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )
            .unwrap();
            refusal.flush().unwrap();
            drop(refusal);

            let (mut rebuild, _) = listener.accept().unwrap();
            let rebuild_request = read_http_request(&mut rebuild);
            write_json_response(
                &mut rebuild,
                "200 OK",
                "",
                r#"{"schemaVersion":1,"items":[]}"#,
            );
            drop(rebuild);

            let (stream, _) = listener.accept().unwrap();
            let (mut socket, subscribe) = accept_subscribed_socket(stream, 1);
            socket
                .send(Message::Text(
                    json!({
                        "type": "change",
                        "schemaVersion": 1,
                        "class": "session.updated",
                        "seq": 1,
                        "payload": {
                            "sessionKey": "agent:main/example",
                            "rowVersion": 3
                        }
                    })
                    .to_string(),
                ))
                .unwrap();
            socket
                .send(Message::Close(Some(tungstenite::protocol::CloseFrame {
                    code: tungstenite::protocol::frame::coding::CloseCode::Normal,
                    reason: "fixture complete".into(),
                })))
                .unwrap();
            (offer, rebuild_request, subscribe)
        });

        let (tx, rx) = mpsc::channel();
        let stopped = Arc::new(AtomicBool::new(false));
        let lifecycle = Arc::new(AtomicU64::new(0));
        let result = connect_and_read(
            &endpoint,
            "agent:main/example",
            1,
            &tx,
            &stopped,
            &lifecycle,
        );
        let (offer, rebuild_request, subscribe) = server.join().unwrap();

        let failure = result.unwrap_err();
        assert_eq!(failure.code, "connection_lost");
        assert_eq!(failure.close_code, Some(1000));
        assert!(rebuild_request.starts_with("GET /api/sessions HTTP/1.1"));
        assert_gateway_headers(&rebuild_request);
        assert_eq!(subscribe["protocolVersion"], 1);

        let frames = rx.try_iter().collect::<Vec<_>>();
        assert!(matches!(frames.first(), Some(Worker::Connected(1))));
        assert!(
            matches!(frames.get(2), Some(Worker::Frame(1, frame)) if frame["type"] == "subscription_ready")
        );
        assert!(frames.iter().any(|message| matches!(
            message,
            Worker::Frame(1, frame)
                if frame["type"] == "change"
                    && frame["schemaVersion"] == 1
                    && frame["class"] == "session.updated"
                    && frame["payload"].get("capabilities").is_none()
        )));
        assert!(offer.contains("protocolVersion=2"));
    }

    #[test]
    fn protocol_offer_exhaustion_rebuilds_once_per_empty_refusal_and_stops() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let server = thread::spawn(move || {
            let mut requests = Vec::new();
            for protocol_version in [2, 1] {
                let (mut refusal, _) = listener.accept().unwrap();
                let offer = read_http_request(&mut refusal);
                assert!(offer.starts_with(&format!(
                    "GET /ws/changes?protocolVersion={protocol_version} HTTP/1.1"
                )));
                write!(
                    refusal,
                    "HTTP/1.1 426 Upgrade Required\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                )
                .unwrap();
                refusal.flush().unwrap();
                drop(refusal);

                let (mut rebuild, _) = listener.accept().unwrap();
                let rebuild_request = read_http_request(&mut rebuild);
                assert!(rebuild_request.starts_with("GET /api/sessions HTTP/1.1"));
                assert_gateway_headers(&rebuild_request);
                write_json_response(
                    &mut rebuild,
                    "200 OK",
                    "",
                    r#"{"schemaVersion":1,"items":[]}"#,
                );
                requests.push((offer, rebuild_request));
            }
            requests
        });

        let stopped = AtomicBool::new(false);
        let failure = match connect_firehose(&endpoint, &stopped) {
            Err(failure) => failure,
            Ok(_) => panic!("protocol offers unexpectedly succeeded"),
        };
        let requests = server.join().unwrap();

        assert_eq!(failure.code, "unsupported_protocol_version");
        assert!(failure.fatal);
        assert_eq!(requests.len(), 2);
        assert!(requests[0].0.contains("protocolVersion=2"));
        assert!(requests[1].0.contains("protocolVersion=1"));
    }

    #[test]
    fn schema_mismatch_closes_with_1002_rebuilds_once_without_applying_bad_notice() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let (mut socket, _) = accept_subscribed_socket(stream, 2);
            socket
                .send(Message::Text(
                    json!({
                        "type": "change",
                        "schemaVersion": 2,
                        "class": "session.harness_changed",
                        "seq": 1,
                        "payload": {
                            "sessionKey": "agent:main/example",
                            "rowVersion": 4,
                            "capabilities": {
                                "setHarness": {
                                    "supported": true,
                                    "options": [
                                        {"title": "claude", "value": "claude", "enabled": false},
                                        {"title": "codex", "value": "codex", "enabled": true}
                                    ]
                                }
                            }
                        }
                    })
                    .to_string(),
                ))
                .unwrap();
            socket
                .send(Message::Text(
                    json!({
                        "type": "change",
                        "schemaVersion": 1,
                        "class": "session.updated",
                        "seq": 2
                    })
                    .to_string(),
                ))
                .unwrap();

            let close = socket.read().unwrap();
            assert!(matches!(
                close,
                Message::Close(Some(frame))
                    if u16::from(frame.code) == 1002
            ));
            drop(socket);

            let (mut rebuild, _) = listener.accept().unwrap();
            let request = read_http_request(&mut rebuild);
            write_json_response(
                &mut rebuild,
                "200 OK",
                "",
                r#"{"schemaVersion":1,"items":[]}"#,
            );
            request
        });

        let (tx, rx) = mpsc::channel();
        let stopped = Arc::new(AtomicBool::new(false));
        let lifecycle = Arc::new(AtomicU64::new(0));
        let failure = connect_and_read(
            &endpoint,
            "agent:main/example",
            4,
            &tx,
            &stopped,
            &lifecycle,
        )
        .unwrap_err();
        let rebuild_request = server.join().unwrap();

        assert_eq!(failure.code, "schema_mismatch");
        assert!(failure.fatal);
        assert_eq!(failure.close_code, Some(1002));
        assert!(rebuild_request.starts_with("GET /api/sessions HTTP/1.1"));
        assert_gateway_headers(&rebuild_request);

        let applied_changes = rx
            .try_iter()
            .filter_map(|message| match message {
                Worker::Frame(_, frame) if frame["type"] == "change" => Some(frame),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(applied_changes.len(), 1);
        assert_eq!(applied_changes[0]["class"], "session.harness_changed");
        assert_eq!(
            applied_changes[0]["payload"]["capabilities"]["setHarness"]["supported"],
            true
        );
    }

    #[test]
    fn accepts_only_the_send_frame_shape() {
        let mut ids = HashSet::new();
        let frame = parse_input(
            r#"{"type":"send","protocolVersion":1,"requestId":"r1","content":"hello","idempotencyKey":"k1"}"#,
            &mut ids,
        )
        .unwrap()
        .unwrap();
        assert_eq!(frame.request_id, "r1");
        assert_eq!(frame.content, "hello");
        assert_eq!(frame.idempotency_key.as_deref(), Some("k1"));

        let duplicate = parse_input(
            r#"{"type":"send","protocolVersion":1,"requestId":"r1","content":"again"}"#,
            &mut ids,
        )
        .unwrap_err();
        assert_eq!(duplicate.1, "duplicate_request_id");

        let unknown = parse_input(
            r#"{"type":"send","protocolVersion":1,"requestId":"r2","content":"hello","extra":true}"#,
            &mut ids,
        )
        .unwrap_err();
        assert_eq!(unknown.1, "invalid_frame");
    }

    #[test]
    fn request_id_is_reserved_only_after_frame_validation() {
        let mut ids = HashSet::new();
        assert_eq!(
            parse_input(
                r#"{"type":"send","protocolVersion":1,"requestId":"r1","content":""}"#,
                &mut ids,
            )
            .unwrap_err()
            .1,
            "invalid_frame"
        );
        assert!(
            parse_input(
                r#"{"type":"send","protocolVersion":1,"requestId":"r1","content":"ok"}"#,
                &mut ids,
            )
            .is_ok()
        );
    }

    #[test]
    fn encodes_path_components_without_normalizing_session_keys() {
        assert_eq!(encode_path("agent:main/a"), "agent%3Amain%2Fa");
    }

    #[test]
    fn policy_close_is_fatal_but_restart_close_preserves_public_code_and_code_number() {
        let policy = close_failure(Some(tungstenite::protocol::CloseFrame {
            code: tungstenite::protocol::frame::coding::CloseCode::Policy,
            reason: "session retired".into(),
        }));
        assert!(policy.fatal);
        assert_eq!(policy.code, "auth_failed");
        assert_eq!(policy.close_code, Some(1008));

        let restart = close_failure(Some(tungstenite::protocol::CloseFrame {
            code: tungstenite::protocol::frame::coding::CloseCode::Restart,
            reason: "gateway restarting".into(),
        }));
        assert!(!restart.fatal);
        assert_eq!(restart.code, "server_restart");
        assert_eq!(restart.close_code, Some(1012));
        assert!(restart.message.contains("close code 1012"));
    }

    #[test]
    fn identifies_only_a_newer_boundary_change() {
        let frame = json!({
            "class": "session.updated",
            "refs": {"sessionKey": "s"},
            "payload": {"rowVersion": 4, "clearedThroughSeq": 2}
        });
        assert!(is_history_boundary_change(&frame, "s", 3, 1));
        assert!(!is_history_boundary_change(&frame, "s", 4, 1));
        assert!(!is_history_boundary_change(&frame, "other", 3, 1));
    }

    #[test]
    fn invalid_utf8_recovery_keeps_following_lines_readable() {
        assert!(matches!(
            decode_input_line(&[0xff, b'\n']),
            Input::InvalidUtf8
        ));
        assert!(matches!(
            decode_input_line(b"next request\n"),
            Input::Line(line) if line == "next request\n"
        ));
        assert_eq!(
            invalid_utf8_input_error()
                .get("code")
                .and_then(Value::as_str),
            Some("invalid_utf8")
        );
    }

    #[test]
    fn snapshot_success_and_failure_results_require_the_open_generation_and_cycle() {
        let pending = PendingSnapshot {
            generation: 7,
            cycle: 3,
            events: Vec::new(),
        };

        assert!(snapshot_result_is_current(7, 3, 7, 3, 7, Some(&pending)));
        for (generation, cycle, active) in [(6, 3, 7), (7, 2, 7), (7, 3, 0)] {
            assert!(!snapshot_result_is_current(
                generation,
                cycle,
                7,
                3,
                active,
                Some(&pending)
            ));
        }
        assert!(!snapshot_result_is_current(7, 3, 7, 3, 7, None));
    }

    #[test]
    fn snapshot_release_waits_for_all_send_results() {
        assert!(!can_release_snapshot(1));
        assert!(can_release_snapshot(0));
    }

    #[test]
    fn snapshot_failure_is_deferred_until_sends_and_stale_failures_are_ignored() {
        let pending = PendingSnapshot {
            generation: 7,
            cycle: 3,
            events: Vec::new(),
        };

        assert_eq!(
            snapshot_result_disposition(7, 3, 7, 3, 7, Some(&pending), 1),
            SnapshotResultDisposition::Defer
        );
        assert_eq!(
            snapshot_result_disposition(7, 3, 7, 3, 7, Some(&pending), 0),
            SnapshotResultDisposition::Complete
        );
        for (generation, cycle, active, open) in [
            (6, 3, 7, true),
            (7, 2, 7, true),
            (7, 3, 0, true),
            (7, 3, 7, false),
        ] {
            assert_eq!(
                snapshot_result_disposition(
                    generation,
                    cycle,
                    7,
                    3,
                    active,
                    open.then_some(&pending),
                    1,
                ),
                SnapshotResultDisposition::Ignore
            );
        }
    }

    #[test]
    fn stale_reconnect_result_is_ignored_before_current_result_reaches_output() {
        let pending = PendingSnapshot {
            generation: 8,
            cycle: 4,
            events: Vec::new(),
        };
        let mut completed = None;
        let mut completed_failure = None;
        let stale = admit_snapshot_result(
            7,
            3,
            Err(snapshot_failure("connection_lost", true)),
            8,
            4,
            8,
            Some(&pending),
            0,
            &mut completed,
            &mut completed_failure,
        );
        assert!(matches!(stale, SnapshotResultAdmission::Ignore));
        assert!(completed.is_none());
        assert!(completed_failure.is_none());

        let current = admit_snapshot_result(
            8,
            4,
            Ok(Snapshot {
                session: json!({"sessionKey": "s"}),
                messages: Vec::new(),
                wakes: Vec::new(),
                turns: Vec::new(),
                row_version: 1,
                cleared_through_seq: 0,
            }),
            8,
            4,
            8,
            Some(&pending),
            1,
            &mut completed,
            &mut completed_failure,
        );
        assert!(matches!(current, SnapshotResultAdmission::Defer));
        assert!(completed.is_some());
        assert!(completed_failure.is_none());
    }

    #[test]
    fn snapshot_prefix_keeps_live_event_after_send_accepted() {
        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "token".to_owned(),
            origin: crate::dispatch::Origin::Named,
        };
        let lifecycle = AtomicU64::new(7);
        let signal = AtomicI32::new(0);
        let (worker_tx, _worker_rx) = mpsc::channel();
        let mut pending = Some(PendingSnapshot {
            generation: 7,
            cycle: 3,
            events: Vec::new(),
        });
        let mut deferred = VecDeque::new();
        assert!(stage_live_event(
            7,
            json!({"class": "wake.created"}),
            &mut pending,
            1,
            &mut deferred,
        ));
        assert!(deferred.is_empty());
        assert_eq!(pending.as_ref().unwrap().events.len(), 1);

        let mut frames = vec![json!({
            "type": "send.accepted",
            "requestId": "r1",
        })];
        let mut output = |value: &Value| {
            frames.push(value.clone());
            Ok(())
        };
        let mut cycle = 3;
        let mut accepted_row_version = 0;
        let mut accepted_boundary = 0;
        let mut ready = false;
        finish_snapshot(
            Snapshot {
                session: json!({"sessionKey": "s"}),
                messages: Vec::new(),
                wakes: Vec::new(),
                turns: Vec::new(),
                row_version: 1,
                cleared_through_seq: 0,
            },
            &mut pending,
            &endpoint,
            "s",
            7,
            &mut cycle,
            &worker_tx,
            &mut accepted_row_version,
            &mut accepted_boundary,
            &mut ready,
            &lifecycle,
            &signal,
            &mut output,
        )
        .unwrap();

        assert_eq!(
            frames.first().and_then(|frame| frame.get("type")),
            Some(&Value::String("send.accepted".to_owned()))
        );
        let event_index = frames
            .iter()
            .position(|frame| frame.get("type").and_then(Value::as_str) == Some("event"))
            .expect("buffered event emitted");
        assert!(event_index > 0);
        assert!(ready);
    }

    #[test]
    fn close_between_snapshot_frames_aborts_without_ready_or_further_items() {
        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "token".to_owned(),
            origin: crate::dispatch::Origin::Named,
        };
        let lifecycle = Arc::new(AtomicU64::new(7));
        let signal = AtomicI32::new(0);
        let (worker_tx, _worker_rx) = mpsc::channel();
        let mut pending = Some(PendingSnapshot {
            generation: 7,
            cycle: 3,
            events: vec![json!({"class": "wake.created"})],
        });
        let mut cycle = 3;
        let mut accepted_row_version = 0;
        let mut accepted_boundary = 0;
        let mut ready = false;
        let mut frames = Vec::new();
        let mut output = |value: &Value| {
            frames.push(value.clone());
            if value.get("type").and_then(Value::as_str) == Some("snapshot.begin") {
                lifecycle.store(0, Ordering::SeqCst);
            }
            Ok(())
        };

        finish_snapshot(
            Snapshot {
                session: json!({"sessionKey": "s"}),
                messages: vec![json!({"id": "m1"})],
                wakes: Vec::new(),
                turns: Vec::new(),
                row_version: 1,
                cleared_through_seq: 0,
            },
            &mut pending,
            &endpoint,
            "s",
            7,
            &mut cycle,
            &worker_tx,
            &mut accepted_row_version,
            &mut accepted_boundary,
            &mut ready,
            &lifecycle,
            &signal,
            &mut output,
        )
        .unwrap();

        assert_eq!(
            frames
                .iter()
                .map(|frame| frame.get("type").and_then(Value::as_str))
                .collect::<Vec<_>>(),
            vec![Some("snapshot.begin"), Some("snapshot.aborted")]
        );
        assert!(!ready);
        assert!(pending.is_none());
        assert_eq!(lifecycle_generation(&lifecycle), 0);
    }

    #[test]
    fn signal_between_snapshot_frames_stops_before_ready_after_current_frame() {
        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "token".to_owned(),
            origin: crate::dispatch::Origin::Named,
        };
        let lifecycle = AtomicU64::new(7);
        let signal = AtomicI32::new(0);
        let (worker_tx, _worker_rx) = mpsc::channel();
        let mut pending = Some(PendingSnapshot {
            generation: 7,
            cycle: 3,
            events: Vec::new(),
        });
        let mut cycle = 3;
        let mut accepted_row_version = 0;
        let mut accepted_boundary = 0;
        let mut ready = false;
        let mut frames = Vec::new();
        let mut output = |value: &Value| {
            frames.push(value.clone());
            if value.get("type").and_then(Value::as_str) == Some("snapshot.begin") {
                signal.store(libc::SIGTERM, Ordering::SeqCst);
            }
            Ok(())
        };

        let error = finish_snapshot(
            Snapshot {
                session: json!({"sessionKey": "s"}),
                messages: Vec::new(),
                wakes: Vec::new(),
                turns: Vec::new(),
                row_version: 1,
                cleared_through_seq: 0,
            },
            &mut pending,
            &endpoint,
            "s",
            7,
            &mut cycle,
            &worker_tx,
            &mut accepted_row_version,
            &mut accepted_boundary,
            &mut ready,
            &lifecycle,
            &signal,
            &mut output,
        )
        .unwrap_err();

        assert_eq!(exit_status(&error), Some(143));
        assert_eq!(
            frames
                .iter()
                .map(|frame| frame.get("type").and_then(Value::as_str))
                .collect::<Vec<_>>(),
            vec![Some("snapshot.begin")]
        );
        assert!(!ready);
        assert!(pending.is_none());
    }

    #[test]
    fn stdout_failure_stops_snapshot_before_ready() {
        let endpoint = Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "token".to_owned(),
            origin: crate::dispatch::Origin::Named,
        };
        let lifecycle = AtomicU64::new(7);
        let signal = AtomicI32::new(0);
        let (worker_tx, _worker_rx) = mpsc::channel();
        let mut pending = Some(PendingSnapshot {
            generation: 7,
            cycle: 3,
            events: Vec::new(),
        });
        let mut cycle = 3;
        let mut accepted_row_version = 0;
        let mut accepted_boundary = 0;
        let mut ready = false;
        let mut frames = Vec::new();
        let mut output = |value: &Value| {
            frames.push(value.clone());
            if value.get("type").and_then(Value::as_str) == Some("snapshot.item") {
                return Err("stdout_failed".to_owned());
            }
            Ok(())
        };

        let error = finish_snapshot(
            Snapshot {
                session: json!({"sessionKey": "s"}),
                messages: Vec::new(),
                wakes: Vec::new(),
                turns: Vec::new(),
                row_version: 1,
                cleared_through_seq: 0,
            },
            &mut pending,
            &endpoint,
            "s",
            7,
            &mut cycle,
            &worker_tx,
            &mut accepted_row_version,
            &mut accepted_boundary,
            &mut ready,
            &lifecycle,
            &signal,
            &mut output,
        )
        .unwrap_err();

        assert_eq!(error, "stdout_failed");
        assert_eq!(frames.len(), 2);
        assert!(!ready);
        assert!(pending.is_none());
    }

    #[test]
    fn socket_worker_stops_joined_after_normal_close() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let (mut socket, _) = accept_subscribed_socket(stream, 2);
            loop {
                match socket.read().unwrap() {
                    Message::Close(frame) => return frame,
                    _ => {}
                }
            }
        });
        let endpoint = Endpoint {
            base: format!("ws://{address}"),
            token: "token".to_owned(),
            origin: crate::dispatch::Origin::Named,
        };
        let stopped = Arc::new(AtomicBool::new(false));
        let lifecycle = Arc::new(AtomicU64::new(0));
        let (tx, rx) = mpsc::channel();
        let worker = spawn_socket_worker(
            endpoint,
            "agent:main/example".to_owned(),
            tx,
            stopped.clone(),
            lifecycle.clone(),
        );
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(5)).unwrap(),
            Worker::Connected(1)
        ));
        stopped.store(true, Ordering::SeqCst);
        worker.join().unwrap();
        let close = server.join().unwrap().expect("normal close frame");
        assert_eq!(u16::from(close.code), 1000);
        assert_eq!(lifecycle_generation(&lifecycle), 0);
    }

    fn receive_closed(
        rx: &std::sync::mpsc::Receiver<Worker>,
        generation: u64,
    ) -> ConnectionFailure {
        loop {
            match rx.recv_timeout(Duration::from_secs(5)).unwrap() {
                Worker::Closed(actual, failure) if actual == generation => return failure,
                Worker::Fatal(failure) => panic!("socket worker failed fatally: {}", failure.code),
                _ => {}
            }
        }
    }

    fn receive_subscription_ready(
        rx: &std::sync::mpsc::Receiver<Worker>,
        generation: u64,
    ) -> Value {
        loop {
            match rx.recv_timeout(Duration::from_secs(5)).unwrap() {
                Worker::Frame(actual, frame)
                    if actual == generation
                        && frame.get("type").and_then(Value::as_str)
                            == Some("subscription_ready") =>
                {
                    return frame;
                }
                Worker::Fatal(failure) => panic!("socket worker failed fatally: {}", failure.code),
                _ => {}
            }
        }
    }

    #[test]
    fn sequence_gap_and_server_restart_reconnect_then_snapshot_after_ready() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = endpoint(&listener);
        let snapshot_endpoint = endpoint.clone();
        let session_key = "agent:main/example";
        let encoded_key = encode_path(session_key);
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let (mut first, first_subscribe) = accept_subscribed_socket(stream, 2);
            first
                .send(Message::Text(
                    json!({
                        "type": "change",
                        "schemaVersion": 2,
                        "class": "session.updated",
                        "seq": 2,
                        "payload": {"sessionKey": session_key, "rowVersion": 8}
                    })
                    .to_string(),
                ))
                .unwrap();
            drop(first);

            let (stream, _) = listener.accept().unwrap();
            let (mut second, second_subscribe) = accept_subscribed_socket(stream, 2);
            second
                .send(Message::Close(Some(tungstenite::protocol::CloseFrame {
                    code: tungstenite::protocol::frame::coding::CloseCode::Restart,
                    reason: "gateway restarting".into(),
                })))
                .unwrap();
            drop(second);

            let (stream, _) = listener.accept().unwrap();
            let (mut third, third_subscribe) = accept_subscribed_socket(stream, 2);
            let mut requests = Vec::new();
            for request_number in 0..5 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_http_request(&mut stream);
                assert_gateway_headers(&request);
                respond_to_snapshot_request(&mut stream, request_number);
                requests.push(request);
            }
            let close = third.read().unwrap();
            (
                first_subscribe,
                second_subscribe,
                third_subscribe,
                requests,
                close,
            )
        });

        let stopped = Arc::new(AtomicBool::new(false));
        let lifecycle = Arc::new(AtomicU64::new(0));
        let (tx, rx) = mpsc::channel();
        let snapshot_tx = tx.clone();
        let worker = spawn_socket_worker(
            endpoint,
            session_key.to_owned(),
            tx,
            stopped.clone(),
            lifecycle.clone(),
        );

        let gap = receive_closed(&rx, 1);
        assert_eq!(gap.code, "connection_lost");
        assert!(gap.message.contains("firehose sequence gap"));
        assert!(!gap.fatal);

        let restart = receive_closed(&rx, 2);
        assert_eq!(restart.code, "server_restart");
        assert_eq!(restart.close_code, Some(1012));
        assert!(!restart.fatal);

        let ready = receive_subscription_ready(&rx, 3);
        let mut pending = None;
        begin_snapshot_after_subscription_ready(
            &json!({"type": "auth_result"}),
            &snapshot_endpoint,
            session_key,
            3,
            9,
            &snapshot_tx,
            &mut pending,
        );
        assert!(pending.is_none());

        begin_snapshot_after_subscription_ready(
            &ready,
            &snapshot_endpoint,
            session_key,
            3,
            9,
            &snapshot_tx,
            &mut pending,
        );
        assert!(matches!(
            pending,
            Some(PendingSnapshot {
                generation: 3,
                cycle: 9,
                ..
            })
        ));

        let snapshot = loop {
            match rx.recv_timeout(Duration::from_secs(5)).unwrap() {
                Worker::SnapshotResult {
                    generation: 3,
                    cycle: 9,
                    result,
                } => break result.unwrap(),
                Worker::Fatal(failure) => panic!("socket worker failed fatally: {}", failure.code),
                _ => {}
            }
        };
        assert_eq!(snapshot.session["rowVersion"], 7);
        assert_eq!(
            snapshot.session["capabilities"]["setHarness"],
            json!({"supported": false, "reason": "session is not active"})
        );

        stopped.store(true, Ordering::SeqCst);
        worker.join().unwrap();
        let (first_subscribe, second_subscribe, third_subscribe, requests, close) =
            server.join().unwrap();
        for subscribe in [first_subscribe, second_subscribe, third_subscribe] {
            assert_eq!(subscribe["protocolVersion"], 2);
        }
        assert_eq!(requests.len(), 5);
        assert!(requests[0].starts_with(&format!("GET /api/sessions/{encoded_key} HTTP/1.1")));
        assert!(requests[1].starts_with(&format!(
            "GET /api/sessions/{encoded_key}/messages?sessionKey={encoded_key}&limit=500 HTTP/1.1"
        )));
        assert!(requests[2].starts_with(&format!(
            "GET /api/sessions/{encoded_key}/wakes?sessionKey={encoded_key}&limit=500 HTTP/1.1"
        )));
        assert!(requests[3].starts_with(&format!(
            "GET /api/sessions/{encoded_key}/turns?sessionKey={encoded_key}&limit=500 HTTP/1.1"
        )));
        assert!(requests[4].starts_with(&format!("GET /api/sessions/{encoded_key} HTTP/1.1")));
        assert!(matches!(
            close,
            Message::Close(Some(frame)) if u16::from(frame.code) == 1000
        ));
        assert_eq!(lifecycle_generation(&lifecycle), 0);
    }

    #[test]
    fn signal_shutdown_returns_shell_status_after_cleanup() {
        assert_eq!(signal_exit_status(Some(libc::SIGINT)), Some(130));
        assert_eq!(signal_exit_status(Some(libc::SIGTERM)), Some(143));
        assert_eq!(exit_status(&signal_exit_error(130)), Some(130));
        assert_eq!(exit_status(&signal_exit_error(143)), Some(143));
    }

    #[test]
    fn shutdown_paths_request_worker_stop_and_normal_close() {
        assert!(shutdown_requested(true, 0, None));
        assert!(!shutdown_requested(true, 1, None));
        assert!(shutdown_requested(false, 1, Some(libc::SIGTERM)));
        assert_eq!(u16::from(normal_close_frame().code), 1000);
    }

    #[test]
    fn https_discovery_offers_v2_before_the_legacy_v1_query() {
        assert_eq!(
            websocket_url("https://gateway.example/", 2),
            "wss://gateway.example/ws/changes?protocolVersion=2"
        );
        assert_eq!(
            websocket_url("http://gateway.example", 1),
            "ws://gateway.example/ws/changes?protocolVersion=1"
        );
        assert_eq!(FIREHOSE_PROTOCOL_PLAN, [2, 1]);
    }

    #[test]
    fn session_reader_accepts_absent_legacy_and_both_closed_capability_forms() {
        assert!(session_item_capability_compatible(
            &json!({"sessionKey": "s"})
        ));
        assert!(session_item_capability_compatible(&json!({
            "sessionKey": "s",
            "capabilities": {"legacy": {"supported": true}}
        })));
        assert!(session_item_capability_compatible(&json!({
            "sessionKey": "s",
            "capabilities": {
                "setHarness": {
                    "supported": false,
                    "reason": "session is not active"
                }
            }
        })));
        assert!(session_item_capability_compatible(&json!({
            "sessionKey": "s",
            "capabilities": {
                "setHarness": {
                    "supported": true,
                    "options": [
                        {"title": "claude", "value": "claude", "enabled": false},
                        {"title": "codex", "value": "codex", "enabled": true}
                    ]
                }
            }
        })));
    }

    #[test]
    fn session_reader_rejects_mixed_or_open_capability_shapes() {
        for item in [
            json!({
                "capabilities": {
                    "setHarness": {
                        "supported": false,
                        "reason": "session is not active",
                        "options": []
                    }
                }
            }),
            json!({
                "capabilities": {
                    "setHarness": {
                        "supported": true,
                        "options": [{"title": "codex", "value": "codex", "enabled": true, "extra": true}]
                    }
                }
            }),
            json!({
                "capabilities": {
                    "setHarness": {
                        "supported": true,
                        "options": [{"title": "codex", "value": "other", "enabled": true}]
                    }
                }
            }),
            json!({
                "capabilities": {
                    "setHarness": {
                        "supported": true,
                        "options": [{"title": "codex", "value": "codex", "enabled": "true"}]
                    }
                }
            }),
            json!({
                "capabilities": {
                    "setHarness": {"supported": false, "reason": "session is not active"},
                    "anotherCapability": {"supported": true}
                }
            }),
        ] {
            assert!(!session_item_capability_compatible(&item), "{item}");
        }
    }
}
