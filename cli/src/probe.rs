use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

const LINEAGE_KEY: &[u8] = b"TIGHTBEAM_LINEAGE=";
const CANONICAL_ENTRIES: [&str; 10] = [
    "adapters",
    "assets",
    "auth",
    "bin",
    "gateway.json",
    "homes",
    "identity",
    "staging",
    "state.db",
    "work",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommandFailure {
    Timeout,
    Failed,
}

trait ProbeIo {
    fn proc_pids(&self) -> io::Result<Vec<u32>>;
    fn proc_read(&self, pid: u32, name: &str) -> io::Result<Vec<u8>>;
    fn proc_read_link(&self, pid: u32, name: &str) -> io::Result<Vec<u8>>;
    fn path_metadata(&self, path: &Path) -> io::Result<()>;
    fn directory_names(&self, path: &Path) -> io::Result<Vec<OsString>>;
    fn command(
        &self,
        program: &str,
        args: &[OsString],
        deadline: Duration,
    ) -> Result<Vec<u8>, CommandFailure>;
}

struct SystemIo;

impl ProbeIo for SystemIo {
    fn proc_pids(&self) -> io::Result<Vec<u32>> {
        let mut pids = Vec::new();
        for entry in fs::read_dir("/proc")? {
            let entry = entry?;
            if let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() {
                pids.push(pid);
            }
        }
        pids.sort_unstable();
        Ok(pids)
    }

    fn proc_read(&self, pid: u32, name: &str) -> io::Result<Vec<u8>> {
        fs::read(PathBuf::from("/proc").join(pid.to_string()).join(name))
    }

    fn proc_read_link(&self, pid: u32, name: &str) -> io::Result<Vec<u8>> {
        fs::read_link(PathBuf::from("/proc").join(pid.to_string()).join(name))
            .map(|path| path.as_os_str().as_bytes().to_vec())
    }

    fn path_metadata(&self, path: &Path) -> io::Result<()> {
        fs::symlink_metadata(path).map(|_| ())
    }

    fn directory_names(&self, path: &Path) -> io::Result<Vec<OsString>> {
        fs::read_dir(path)?
            .map(|entry| entry.map(|entry| entry.file_name()))
            .collect()
    }

    fn command(
        &self,
        program: &str,
        args: &[OsString],
        deadline: Duration,
    ) -> Result<Vec<u8>, CommandFailure> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| CommandFailure::Failed)?;
        let mut stdout = child.stdout.take().ok_or(CommandFailure::Failed)?;
        let mut stderr = child.stderr.take().ok_or(CommandFailure::Failed)?;
        let stdout_reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout.read_to_end(&mut bytes).map(|_| bytes)
        });
        let stderr_reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            stderr.read_to_end(&mut bytes).map(|_| ())
        });
        let started = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    let output = stdout_reader
                        .join()
                        .map_err(|_| CommandFailure::Failed)?
                        .map_err(|_| CommandFailure::Failed)?;
                    stderr_reader
                        .join()
                        .map_err(|_| CommandFailure::Failed)?
                        .map_err(|_| CommandFailure::Failed)?;
                    return if status.success() {
                        Ok(output)
                    } else {
                        Err(CommandFailure::Failed)
                    };
                }
                Ok(None) if started.elapsed() < deadline => {
                    thread::sleep(Duration::from_millis(5));
                }
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = stdout_reader.join();
                    let _ = stderr_reader.join();
                    return Err(CommandFailure::Timeout);
                }
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = stdout_reader.join();
                    let _ = stderr_reader.join();
                    return Err(CommandFailure::Failed);
                }
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RawProcess {
    pid: u32,
    lstart: Option<Vec<u8>>,
    ppid: Option<u32>,
    pgid: Option<u32>,
    token: Option<Vec<u8>>,
    evidence: &'static str,
    executable: Option<Vec<u8>>,
    cwd: Option<Vec<u8>>,
    elapsed_s: Option<u64>,
    harnesses: Vec<String>,
}

#[derive(Debug, Clone)]
struct RawFacts {
    platform: &'static str,
    pids_scanned: usize,
    pids_env_unreadable: Option<usize>,
    processes: Vec<RawProcess>,
    notes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Host {
    hostname: String,
    platform: &'static str,
    probe_version: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Entries {
    adapters: &'static str,
    assets: &'static str,
    auth: &'static str,
    bin: &'static str,
    gateway_json: &'static str,
    homes: &'static str,
    identity: &'static str,
    staging: &'static str,
    state_db: &'static str,
    work: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct BaseDir {
    path: String,
    status: &'static str,
    entries: Entries,
    adapter_stderr_log_count: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Candidate {
    pid: u32,
    ppid: Option<u32>,
    pgid: Option<u32>,
    lineage: Option<String>,
    lineage_raw: Option<String>,
    lineage_raw_b64: Option<String>,
    evidence: &'static str,
    executable: Option<String>,
    elapsed_s: Option<u64>,
    started_at_s: Option<u64>,
    cwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AdapterCandidate {
    pid: u32,
    harness: String,
    ppid: Option<u32>,
    pgid: Option<u32>,
    lineage: Option<String>,
    lineage_raw: Option<String>,
    lineage_raw_b64: Option<String>,
    evidence: &'static str,
    executable: Option<String>,
    elapsed_s: Option<u64>,
    started_at_s: Option<u64>,
    cwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Epistemics {
    census_grade: &'static str,
    absence_means: &'static str,
    lineage_is_claim: bool,
    pids_scanned: usize,
    pids_env_unreadable: Option<usize>,
    platform_limits: Vec<&'static str>,
    notes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Report {
    schema: &'static str,
    probed_at_ms: u64,
    collection_ms: u64,
    host: Host,
    base_dir: BaseDir,
    marked_candidates: Vec<Candidate>,
    identity_candidates: BTreeMap<String, Vec<u32>>,
    adapter_candidates: Vec<AdapterCandidate>,
    epistemics: Epistemics,
}

#[derive(Debug, Clone)]
struct TokenFields {
    lineage: Option<String>,
    raw: Option<String>,
    raw_b64: Option<String>,
}

fn base64url_decode(input: &[u8]) -> Option<Vec<u8>> {
    let mut output = Vec::with_capacity(input.len() * 3 / 4);
    let mut accumulator = 0u32;
    let mut bits = 0u8;
    for byte in input {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return None,
        };
        accumulator = (accumulator << 6) | u32::from(value);
        bits += 6;
        while bits >= 8 {
            bits -= 8;
            output.push((accumulator >> bits) as u8);
            accumulator &= (1u32 << bits).saturating_sub(1);
        }
    }
    if bits == 6 || (bits > 0 && accumulator != 0) {
        None
    } else {
        Some(output)
    }
}

fn base64_standard(input: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut result = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        result.push(ALPHABET[((value >> 18) & 63) as usize] as char);
        result.push(ALPHABET[((value >> 12) & 63) as usize] as char);
        result.push(if chunk.len() > 1 {
            ALPHABET[((value >> 6) & 63) as usize] as char
        } else {
            '='
        });
        result.push(if chunk.len() > 2 {
            ALPHABET[(value & 63) as usize] as char
        } else {
            '='
        });
    }
    result
}

fn token_fields(token: Option<&[u8]>) -> TokenFields {
    let Some(token) = token else {
        return TokenFields {
            lineage: None,
            raw: None,
            raw_b64: None,
        };
    };
    let bounded = &token[..token.len().min(256)];
    let raw = String::from_utf8_lossy(bounded);
    let raw_b64 = matches!(raw, std::borrow::Cow::Owned(_)).then(|| base64_standard(bounded));
    let lineage = token
        .strip_prefix(b"tb1-")
        .and_then(base64url_decode)
        .and_then(|bytes| String::from_utf8(bytes).ok());
    TokenFields {
        lineage,
        raw: Some(raw.into_owned()),
        raw_b64,
    }
}

fn exact_environ_token(bytes: &[u8]) -> Option<Vec<u8>> {
    bytes
        .split(|byte| *byte == 0)
        .find_map(|entry| entry.strip_prefix(LINEAGE_KEY).map(ToOwned::to_owned))
}

fn adapter_harnesses(
    bytes: &[u8],
    catalog: Option<&crate::harnesses::HarnessCatalog>,
) -> Vec<String> {
    catalog
        .map(|catalog| {
            catalog
                .harnesses
                .iter()
                .filter(|harness| {
                    harness.process_markers.iter().any(|marker| {
                        let marker = marker.as_bytes();
                        bytes.windows(marker.len()).any(|window| window == marker)
                    })
                })
                .map(|harness| harness.wire_name.clone())
                .collect()
        })
        .unwrap_or_default()
}

fn parse_stat(bytes: &[u8]) -> Option<(u32, u32, u64)> {
    let close = bytes.iter().rposition(|byte| *byte == b')')?;
    let rest = bytes.get(close + 2..)?;
    let fields = rest
        .split(|byte| byte.is_ascii_whitespace())
        .filter(|field| !field.is_empty())
        .collect::<Vec<_>>();
    Some((
        std::str::from_utf8(fields.get(1)?).ok()?.parse().ok()?,
        std::str::from_utf8(fields.get(2)?).ok()?.parse().ok()?,
        std::str::from_utf8(fields.get(19)?).ok()?.parse().ok()?,
    ))
}

fn is_not_found(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::NotFound
}

fn collect_linux(
    io: &impl ProbeIo,
    own_pid: u32,
    catalog: Option<&crate::harnesses::HarnessCatalog>,
) -> Result<RawFacts, String> {
    let pids = io
        .proc_pids()
        .map_err(|_| "probe: process enumeration failed".to_owned())?;
    let pids_scanned = pids.len();
    let mut pids_env_unreadable = 0usize;
    let mut processes = Vec::new();
    for pid in pids {
        if pid == own_pid {
            continue;
        }
        let first = match io
            .proc_read(pid, "stat")
            .ok()
            .and_then(|bytes| parse_stat(&bytes))
        {
            Some(value) => value,
            None => continue,
        };
        let (token, evidence) = match io.proc_read(pid, "environ") {
            Ok(bytes) => {
                let token = exact_environ_token(&bytes);
                let evidence = if token.is_some() {
                    "environ_exact"
                } else {
                    "none_observed"
                };
                (token, evidence)
            }
            Err(error) if is_not_found(&error) => continue,
            Err(_) => {
                pids_env_unreadable += 1;
                (None, "env_unreadable")
            }
        };
        let cmdline = match io.proc_read(pid, "cmdline") {
            Ok(bytes) => Some(bytes),
            Err(error) if is_not_found(&error) => continue,
            Err(_) => None,
        };
        let harnesses = cmdline
            .as_deref()
            .map(|bytes| adapter_harnesses(bytes, catalog))
            .unwrap_or_default();
        if token.is_none() && harnesses.is_empty() {
            continue;
        }
        let executable = io.proc_read_link(pid, "exe").ok();
        let cwd = io.proc_read_link(pid, "cwd").ok();
        let stable = io
            .proc_read(pid, "stat")
            .ok()
            .and_then(|bytes| parse_stat(&bytes))
            .is_some_and(|(_, _, start)| start == first.2);
        if !stable {
            continue;
        }
        processes.push(RawProcess {
            pid,
            lstart: None,
            ppid: Some(first.0),
            pgid: Some(first.1),
            token,
            evidence,
            executable,
            cwd,
            elapsed_s: None,
            harnesses,
        });
    }
    Ok(RawFacts {
        platform: "linux",
        pids_scanned,
        pids_env_unreadable: Some(pids_env_unreadable),
        processes,
        notes: Vec::new(),
    })
}

fn bounded_tokens(line: &[u8]) -> Vec<Vec<u8>> {
    let mut tokens = Vec::new();
    let mut offset = 0usize;
    while let Some(found) = line[offset..]
        .windows(LINEAGE_KEY.len())
        .position(|window| window == LINEAGE_KEY)
    {
        let start = offset + found;
        let bounded = start == 0 || line[start - 1].is_ascii_whitespace();
        let value_start = start + LINEAGE_KEY.len();
        let end = line[value_start..]
            .iter()
            .position(|byte| byte.is_ascii_whitespace())
            .map_or(line.len(), |length| value_start + length);
        if bounded {
            tokens.push(line[value_start..end].to_vec());
        }
        offset = value_start.max(start + 1);
    }
    tokens
}

fn preferred_token(line: &[u8]) -> Option<Vec<u8>> {
    let tokens = bounded_tokens(line);
    tokens
        .iter()
        .find(|token| token_fields(Some(token)).lineage.is_some())
        .cloned()
        .or_else(|| tokens.into_iter().next())
}

fn parse_darwin_pass1(
    bytes: &[u8],
    own_pid: u32,
    catalog: Option<&crate::harnesses::HarnessCatalog>,
) -> Vec<RawProcess> {
    let mut processes = Vec::new();
    for line in bytes.split(|byte| *byte == b'\n') {
        let Some((pid, lstart, command)) = parse_pid_lstart_line(line) else {
            continue;
        };
        if pid == own_pid {
            continue;
        }
        let token = preferred_token(command);
        let harnesses = adapter_harnesses(command, catalog);
        if token.is_none() && harnesses.is_empty() {
            continue;
        }
        let evidence = if token.is_some() {
            "argv_or_env_indistinguishable"
        } else {
            "none_observed"
        };
        processes.push(RawProcess {
            pid,
            lstart: Some(lstart.to_vec()),
            ppid: None,
            pgid: None,
            token,
            evidence,
            executable: None,
            cwd: None,
            elapsed_s: None,
            harnesses,
        });
    }
    processes
}

fn parse_pid_lstart_line(line: &[u8]) -> Option<(u32, &[u8], &[u8])> {
    let mut cursor = 0usize;
    while line.get(cursor).is_some_and(u8::is_ascii_whitespace) {
        cursor += 1;
    }
    let pid_start = cursor;
    while line
        .get(cursor)
        .is_some_and(|byte| !byte.is_ascii_whitespace())
    {
        cursor += 1;
    }
    let pid = std::str::from_utf8(&line[pid_start..cursor])
        .ok()?
        .parse::<u32>()
        .ok()?;
    while line.get(cursor).is_some_and(u8::is_ascii_whitespace) {
        cursor += 1;
    }
    let lstart_start = cursor;
    let mut lstart_end = cursor;
    for _ in 0..5 {
        let field_start = cursor;
        while line
            .get(cursor)
            .is_some_and(|byte| !byte.is_ascii_whitespace())
        {
            cursor += 1;
        }
        if cursor == field_start {
            return None;
        }
        lstart_end = cursor;
        while line.get(cursor).is_some_and(u8::is_ascii_whitespace) {
            cursor += 1;
        }
    }
    Some((pid, &line[lstart_start..lstart_end], &line[cursor..]))
}

fn parse_pid_lstart(bytes: &[u8]) -> BTreeMap<u32, Vec<u8>> {
    bytes
        .split(|byte| *byte == b'\n')
        .filter_map(|line| {
            parse_pid_lstart_line(line).map(|(pid, lstart, _)| (pid, lstart.to_vec()))
        })
        .collect()
}

fn pid_list(processes: &[RawProcess]) -> OsString {
    processes
        .iter()
        .map(|process| process.pid.to_string())
        .collect::<Vec<_>>()
        .join(",")
        .into()
}

fn parse_pass2(bytes: &[u8]) -> BTreeMap<u32, (u32, u32, Vec<u8>)> {
    let mut result = BTreeMap::new();
    for line in bytes.split(|byte| *byte == b'\n') {
        let mut cursor = 0usize;
        let mut fields = Vec::new();
        for _ in 0..3 {
            while line.get(cursor).is_some_and(u8::is_ascii_whitespace) {
                cursor += 1;
            }
            let start = cursor;
            while line
                .get(cursor)
                .is_some_and(|byte| !byte.is_ascii_whitespace())
            {
                cursor += 1;
            }
            if start == cursor {
                break;
            }
            fields.push(&line[start..cursor]);
        }
        while line.get(cursor).is_some_and(u8::is_ascii_whitespace) {
            cursor += 1;
        }
        let [pid, ppid, pgid] = fields.as_slice() else {
            continue;
        };
        let comm = &line[cursor..];
        let parse = |value: &[u8]| std::str::from_utf8(value).ok()?.parse::<u32>().ok();
        if let (Some(pid), Some(ppid), Some(pgid)) = (parse(pid), parse(ppid), parse(pgid)) {
            result.insert(pid, (ppid, pgid, comm.to_vec()));
        }
    }
    result
}

fn parse_lsof(bytes: &[u8]) -> BTreeMap<u32, Vec<u8>> {
    let mut result = BTreeMap::new();
    let mut pid = None;
    for line in bytes.split(|byte| *byte == b'\n') {
        if let Some(value) = line.strip_prefix(b"p") {
            pid = std::str::from_utf8(value)
                .ok()
                .and_then(|value| value.parse::<u32>().ok());
        } else if let (Some(pid), Some(path)) = (pid, line.strip_prefix(b"n")) {
            result.insert(pid, path.to_vec());
        }
    }
    result
}

fn parse_etime(value: &[u8]) -> Option<u64> {
    let value = std::str::from_utf8(value).ok()?;
    let (days, clock) = value.split_once('-').map_or((0, value), |(days, rest)| {
        if days.is_empty() || days.len() > 5 {
            return (u64::MAX, rest);
        }
        (days.parse().unwrap_or(u64::MAX), rest)
    });
    if days == u64::MAX {
        return None;
    }
    let parts = clock
        .split(':')
        .map(str::parse::<u64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    let (hours, minutes, seconds) = match parts.as_slice() {
        [minutes, seconds] => (0, *minutes, *seconds),
        [hours, minutes, seconds] => (*hours, *minutes, *seconds),
        _ => return None,
    };
    if hours > 23 || minutes > 59 || seconds > 59 {
        return None;
    }
    days.checked_mul(86_400)?
        .checked_add(hours.checked_mul(3_600)?)?
        .checked_add(minutes.checked_mul(60)?)?
        .checked_add(seconds)
}

fn parse_etime_output(bytes: &[u8]) -> BTreeMap<u32, u64> {
    let mut result = BTreeMap::new();
    for line in bytes.split(|byte| *byte == b'\n') {
        let mut fields = line
            .split(|byte| byte.is_ascii_whitespace())
            .filter(|field| !field.is_empty());
        if let (Some(pid), Some(etime)) = (fields.next(), fields.next())
            && let (Some(pid), Some(elapsed)) = (
                std::str::from_utf8(pid)
                    .ok()
                    .and_then(|value| value.parse::<u32>().ok()),
                parse_etime(etime),
            )
        {
            result.insert(pid, elapsed);
        }
    }
    result
}

fn note_failure(notes: &mut Vec<String>, command: &str, failure: CommandFailure) {
    let suffix = match failure {
        CommandFailure::Timeout => "timed out",
        CommandFailure::Failed => "failed",
    };
    notes.push(format!("{command} {suffix}"));
}

fn collect_darwin(
    io: &impl ProbeIo,
    own_pid: u32,
    catalog: Option<&crate::harnesses::HarnessCatalog>,
) -> Result<RawFacts, String> {
    let pass1 = io
        .command(
            "ps",
            &["-axEww".into(), "-o".into(), "pid=,lstart=,command=".into()],
            Duration::from_millis(1500),
        )
        .map_err(|failure| match failure {
            CommandFailure::Timeout => "probe: ps enumeration timed out".to_owned(),
            CommandFailure::Failed => "probe: ps enumeration failed".to_owned(),
        })?;
    let pids_scanned = pass1
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.iter().all(|byte| byte.is_ascii_whitespace()))
        .count();
    let mut processes = parse_darwin_pass1(&pass1, own_pid, catalog);
    let mut notes = Vec::new();
    if !processes.is_empty() {
        let list = pid_list(&processes);
        match io.command(
            "ps",
            &[
                "-o".into(),
                "pid=,ppid=,pgid=,comm=".into(),
                "-p".into(),
                list.clone(),
            ],
            Duration::from_millis(1000),
        ) {
            Ok(bytes) => {
                let details = parse_pass2(&bytes);
                processes.retain_mut(|process| {
                    if let Some((ppid, pgid, executable)) = details.get(&process.pid) {
                        process.ppid = Some(*ppid);
                        process.pgid = Some(*pgid);
                        process.executable = Some(executable.clone());
                        true
                    } else {
                        false
                    }
                });
            }
            Err(failure) => note_failure(&mut notes, "ps pass 2", failure),
        }
        match io.command(
            "lsof",
            &[
                "-n".into(),
                "-a".into(),
                "-p".into(),
                list,
                "-d".into(),
                "cwd".into(),
                "-Fn".into(),
            ],
            Duration::from_millis(1000),
        ) {
            Ok(bytes) => {
                let cwd = parse_lsof(&bytes);
                for process in &mut processes {
                    process.cwd = cwd.get(&process.pid).cloned();
                }
            }
            Err(failure) => note_failure(&mut notes, "lsof", failure),
        }
    }
    Ok(RawFacts {
        platform: "macos",
        pids_scanned,
        pids_env_unreadable: None,
        processes,
        notes,
    })
}

fn add_elapsed(io: &impl ProbeIo, raw: &mut RawFacts) {
    if raw.processes.is_empty() {
        return;
    }
    match io.command(
        "ps",
        &[
            "-o".into(),
            "pid=,etime=".into(),
            "-p".into(),
            pid_list(&raw.processes),
        ],
        Duration::from_millis(1000),
    ) {
        Ok(bytes) => {
            let elapsed = parse_etime_output(&bytes);
            for process in &mut raw.processes {
                process.elapsed_s = elapsed.get(&process.pid).copied();
            }
        }
        Err(failure) => note_failure(&mut raw.notes, "ps etime", failure),
    }
    if raw.platform == "macos" {
        match io.command(
            "ps",
            &[
                "-o".into(),
                "pid=,lstart=".into(),
                "-p".into(),
                pid_list(&raw.processes),
            ],
            Duration::from_millis(1000),
        ) {
            Ok(bytes) => {
                let identities = parse_pid_lstart(&bytes);
                raw.processes.retain(|process| {
                    identities
                        .get(&process.pid)
                        .is_some_and(|lstart| process.lstart.as_ref() == Some(lstart))
                });
            }
            Err(failure) => {
                note_failure(&mut raw.notes, "ps identity", failure);
            }
        }
    }
}

fn hostname(io: &impl ProbeIo, notes: &mut Vec<String>) -> String {
    match io.command("uname", &["-n".into()], Duration::from_millis(1000)) {
        Ok(bytes) => String::from_utf8_lossy(&bytes).trim().to_owned(),
        Err(failure) => {
            note_failure(notes, "uname", failure);
            "(unknown)".to_owned()
        }
    }
}

fn status_for(io: &impl ProbeIo, path: &Path) -> &'static str {
    match io.path_metadata(path) {
        Ok(_) => "present",
        Err(error) if error.kind() == io::ErrorKind::NotFound => "absent",
        Err(_) => "unreadable",
    }
}

fn entries_with(status: &'static str) -> Entries {
    Entries {
        adapters: status,
        assets: status,
        auth: status,
        bin: status,
        gateway_json: status,
        homes: status,
        identity: status,
        staging: status,
        state_db: status,
        work: status,
    }
}

fn inspect_base_dir(io: &impl ProbeIo, path: &Path, notes: &mut Vec<String>) -> BaseDir {
    let path_string = path.as_os_str().to_string_lossy().into_owned();
    let metadata_status = status_for(io, path);
    if metadata_status != "present" {
        return BaseDir {
            path: path_string,
            status: metadata_status,
            entries: entries_with(metadata_status),
            adapter_stderr_log_count: None,
        };
    }
    let names = match io.directory_names(path) {
        Ok(names) => names,
        Err(_) => {
            notes.push("base directory read_dir failed".to_owned());
            return BaseDir {
                path: path_string,
                status: "unreadable",
                entries: entries_with("unreadable"),
                adapter_stderr_log_count: None,
            };
        }
    };
    let value = |name: &str| status_for(io, &path.join(name));
    let entries = Entries {
        adapters: value(CANONICAL_ENTRIES[0]),
        assets: value(CANONICAL_ENTRIES[1]),
        auth: value(CANONICAL_ENTRIES[2]),
        bin: value(CANONICAL_ENTRIES[3]),
        gateway_json: value(CANONICAL_ENTRIES[4]),
        homes: value(CANONICAL_ENTRIES[5]),
        identity: value(CANONICAL_ENTRIES[6]),
        staging: value(CANONICAL_ENTRIES[7]),
        state_db: value(CANONICAL_ENTRIES[8]),
        work: value(CANONICAL_ENTRIES[9]),
    };
    let count = names
        .iter()
        .filter(|name| {
            let bytes = name.as_bytes();
            bytes.starts_with(b"adapter-") && bytes.ends_with(b".stderr.log")
        })
        .count();
    BaseDir {
        path: path_string,
        status: "present",
        entries,
        adapter_stderr_log_count: Some(count),
    }
}

fn platform_limits(platform: &str) -> Vec<&'static str> {
    if platform == "linux" {
        vec![
            "environ is ptrace-gated; other-user and protected processes are unreadable",
            "procfs may hide processes entirely",
            "markers are spoofable env content",
        ]
    } else {
        vec![
            "env visible only for same-euid processes; platform binaries may hide it even own-user",
            "ps flattens argv and env; marker position is indistinguishable",
            "markers are spoofable argv or env content",
        ]
    }
}

fn assemble(
    raw: RawFacts,
    probed_at_ms: u64,
    collection_ms: u64,
    hostname: String,
    base_dir: BaseDir,
) -> Report {
    let probed_at_s = probed_at_ms / 1000;
    let mut marked_candidates = Vec::new();
    let mut adapter_candidates = Vec::new();
    for process in raw.processes {
        let token = token_fields(process.token.as_deref());
        let started_at_s = process
            .elapsed_s
            .and_then(|elapsed| probed_at_s.checked_sub(elapsed));
        let common = Candidate {
            pid: process.pid,
            ppid: process.ppid,
            pgid: process.pgid,
            lineage: token.lineage.clone(),
            lineage_raw: token.raw.clone(),
            lineage_raw_b64: token.raw_b64.clone(),
            evidence: process.evidence,
            executable: process
                .executable
                .as_deref()
                .map(|bytes| String::from_utf8_lossy(bytes).into_owned()),
            elapsed_s: process.elapsed_s,
            started_at_s,
            cwd: process
                .cwd
                .as_deref()
                .map(|bytes| String::from_utf8_lossy(bytes).into_owned()),
        };
        if process.token.is_some() {
            marked_candidates.push(common.clone());
        }
        for harness in process.harnesses {
            adapter_candidates.push(AdapterCandidate {
                pid: common.pid,
                harness: harness.clone(),
                ppid: common.ppid,
                pgid: common.pgid,
                lineage: common.lineage.clone(),
                lineage_raw: common.lineage_raw.clone(),
                lineage_raw_b64: common.lineage_raw_b64.clone(),
                evidence: common.evidence,
                executable: common.executable.clone(),
                elapsed_s: common.elapsed_s,
                started_at_s: common.started_at_s,
                cwd: common.cwd.clone(),
            });
        }
    }
    marked_candidates.sort_by_key(|candidate| candidate.pid);
    adapter_candidates.sort_by_key(|candidate| (candidate.pid, candidate.harness.clone()));
    let mut identity_candidates: BTreeMap<String, Vec<u32>> = BTreeMap::new();
    for candidate in &marked_candidates {
        if let Some(identity) = candidate
            .lineage
            .as_ref()
            .or(candidate.lineage_raw.as_ref())
        {
            identity_candidates
                .entry(identity.clone())
                .or_default()
                .push(candidate.pid);
        }
    }
    Report {
        schema: "tightbeam.probe.v1",
        probed_at_ms,
        collection_ms,
        host: Host {
            hostname,
            platform: raw.platform,
            probe_version: env!("CARGO_PKG_VERSION"),
        },
        base_dir,
        marked_candidates,
        identity_candidates,
        adapter_candidates,
        epistemics: Epistemics {
            census_grade: "accident",
            absence_means: "possibly_laundered",
            lineage_is_claim: true,
            pids_scanned: raw.pids_scanned,
            pids_env_unreadable: raw.pids_env_unreadable,
            platform_limits: platform_limits(raw.platform),
            notes: raw.notes,
        },
    }
}

// An explicit --base-dir still wins; everything below it is the shared resolver.
// This read TIGHTBEAM_HOME only, so `doctor` reported on a different org than the
// installed service ran -- a health verdict about somebody else's install.
fn resolve_base_dir(value: Option<String>) -> PathBuf {
    value
        .map(PathBuf::from)
        .unwrap_or_else(crate::base_dir::resolve)
}

fn human(report: &Report) -> String {
    let mut lines = vec![format!(
        "{} ({}) — {} {}",
        report.host.hostname, report.host.platform, report.base_dir.path, report.base_dir.status
    )];
    if report.marked_candidates.is_empty() {
        lines.push("no marked candidates".to_owned());
    } else {
        for (identity, pids) in &report.identity_candidates {
            lines.push(format!("{identity}:"));
            for candidate in report
                .marked_candidates
                .iter()
                .filter(|candidate| pids.contains(&candidate.pid))
            {
                let uptime = candidate
                    .elapsed_s
                    .map_or_else(|| "?".to_owned(), |value| format!("{value}s"));
                lines.push(format!(
                    "  pid {} ppid {} up {} cwd {} exe {} {}",
                    candidate.pid,
                    candidate
                        .ppid
                        .map_or_else(|| "?".to_owned(), |v| v.to_string()),
                    uptime,
                    candidate.cwd.as_deref().unwrap_or("?"),
                    candidate.executable.as_deref().unwrap_or("?"),
                    candidate.evidence
                ));
            }
        }
    }
    let adapters = report
        .adapter_candidates
        .iter()
        .map(|candidate| format!("{}:{}", candidate.pid, candidate.harness))
        .collect::<Vec<_>>()
        .join(", ");
    lines.push(format!(
        "adapter candidates: {}",
        if adapters.is_empty() {
            "none"
        } else {
            &adapters
        }
    ));
    let unreadable = report
        .epistemics
        .pids_env_unreadable
        .map_or_else(String::new, |count| format!(" ({count} env-unreadable)"));
    lines.push(format!(
        "scanned {} pids{} — claims, not proof; absence may be laundered",
        report.epistemics.pids_scanned, unreadable
    ));
    lines.join("\n")
}

fn object(entries: impl IntoIterator<Item = (&'static str, Value)>) -> Value {
    Value::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect::<Map<_, _>>(),
    )
}

fn optional_u32(value: Option<u32>) -> Value {
    value.map_or(Value::Null, |value| Value::from(u64::from(value)))
}

fn optional_u64(value: Option<u64>) -> Value {
    value.map_or(Value::Null, Value::from)
}

fn optional_string(value: &Option<String>) -> Value {
    value
        .as_ref()
        .map_or(Value::Null, |value| Value::from(value.clone()))
}

fn candidate_value(candidate: &Candidate) -> Value {
    object([
        ("pid", Value::from(u64::from(candidate.pid))),
        ("ppid", optional_u32(candidate.ppid)),
        ("pgid", optional_u32(candidate.pgid)),
        ("lineage", optional_string(&candidate.lineage)),
        ("lineage_raw", optional_string(&candidate.lineage_raw)),
        (
            "lineage_raw_b64",
            optional_string(&candidate.lineage_raw_b64),
        ),
        ("evidence", Value::from(candidate.evidence)),
        ("executable", optional_string(&candidate.executable)),
        ("elapsed_s", optional_u64(candidate.elapsed_s)),
        ("started_at_s", optional_u64(candidate.started_at_s)),
        ("cwd", optional_string(&candidate.cwd)),
    ])
}

fn adapter_candidate_value(candidate: &AdapterCandidate) -> Value {
    object([
        ("pid", Value::from(u64::from(candidate.pid))),
        ("harness", Value::from(candidate.harness.clone())),
        ("ppid", optional_u32(candidate.ppid)),
        ("pgid", optional_u32(candidate.pgid)),
        ("lineage", optional_string(&candidate.lineage)),
        ("lineage_raw", optional_string(&candidate.lineage_raw)),
        (
            "lineage_raw_b64",
            optional_string(&candidate.lineage_raw_b64),
        ),
        ("evidence", Value::from(candidate.evidence)),
        ("executable", optional_string(&candidate.executable)),
        ("elapsed_s", optional_u64(candidate.elapsed_s)),
        ("started_at_s", optional_u64(candidate.started_at_s)),
        ("cwd", optional_string(&candidate.cwd)),
    ])
}

fn entries_value(entries: &Entries) -> Value {
    object([
        ("adapters", Value::from(entries.adapters)),
        ("assets", Value::from(entries.assets)),
        ("auth", Value::from(entries.auth)),
        ("bin", Value::from(entries.bin)),
        ("gateway.json", Value::from(entries.gateway_json)),
        ("homes", Value::from(entries.homes)),
        ("identity", Value::from(entries.identity)),
        ("staging", Value::from(entries.staging)),
        ("state.db", Value::from(entries.state_db)),
        ("work", Value::from(entries.work)),
    ])
}

fn report_value(report: &Report) -> Value {
    let entries = &report.base_dir.entries;
    let identity_candidates = report
        .identity_candidates
        .iter()
        .map(|(identity, pids)| {
            (
                identity.clone(),
                Value::Array(
                    pids.iter()
                        .map(|pid| Value::from(u64::from(*pid)))
                        .collect(),
                ),
            )
        })
        .collect::<Map<_, _>>();
    object([
        ("schema", Value::from(report.schema)),
        ("probed_at_ms", Value::from(report.probed_at_ms)),
        ("collection_ms", Value::from(report.collection_ms)),
        (
            "host",
            object([
                ("hostname", Value::from(report.host.hostname.clone())),
                ("platform", Value::from(report.host.platform)),
                ("probe_version", Value::from(report.host.probe_version)),
            ]),
        ),
        (
            "base_dir",
            object([
                ("path", Value::from(report.base_dir.path.clone())),
                ("status", Value::from(report.base_dir.status)),
                ("entries", entries_value(entries)),
                (
                    "adapter_stderr_log_count",
                    report
                        .base_dir
                        .adapter_stderr_log_count
                        .map_or(Value::Null, |count| Value::from(count as u64)),
                ),
            ]),
        ),
        (
            "marked_candidates",
            Value::Array(
                report
                    .marked_candidates
                    .iter()
                    .map(candidate_value)
                    .collect(),
            ),
        ),
        ("identity_candidates", Value::Object(identity_candidates)),
        (
            "adapter_candidates",
            Value::Array(
                report
                    .adapter_candidates
                    .iter()
                    .map(adapter_candidate_value)
                    .collect(),
            ),
        ),
        (
            "epistemics",
            object([
                ("census_grade", Value::from(report.epistemics.census_grade)),
                (
                    "absence_means",
                    Value::from(report.epistemics.absence_means),
                ),
                (
                    "lineage_is_claim",
                    Value::from(report.epistemics.lineage_is_claim),
                ),
                (
                    "pids_scanned",
                    Value::from(report.epistemics.pids_scanned as u64),
                ),
                (
                    "pids_env_unreadable",
                    report
                        .epistemics
                        .pids_env_unreadable
                        .map_or(Value::Null, |count| Value::from(count as u64)),
                ),
                (
                    "platform_limits",
                    Value::Array(
                        report
                            .epistemics
                            .platform_limits
                            .iter()
                            .map(|limit| Value::from(*limit))
                            .collect(),
                    ),
                ),
                (
                    "notes",
                    Value::Array(
                        report
                            .epistemics
                            .notes
                            .iter()
                            .cloned()
                            .map(Value::from)
                            .collect(),
                    ),
                ),
            ]),
        ),
    ])
}

#[derive(Clone, Copy)]
enum JsonOrder {
    Report,
    Host,
    BaseDir,
    Entries,
    Candidate,
    AdapterCandidate,
    Epistemics,
    Natural,
}

fn object_key_order(order: JsonOrder) -> Option<&'static [&'static str]> {
    match order {
        JsonOrder::Report => Some(&[
            "schema",
            "probed_at_ms",
            "collection_ms",
            "host",
            "base_dir",
            "marked_candidates",
            "identity_candidates",
            "adapter_candidates",
            "epistemics",
        ]),
        JsonOrder::Host => Some(&["hostname", "platform", "probe_version"]),
        JsonOrder::BaseDir => Some(&["path", "status", "entries", "adapter_stderr_log_count"]),
        JsonOrder::Entries => Some(&CANONICAL_ENTRIES),
        JsonOrder::Candidate => Some(&[
            "pid",
            "ppid",
            "pgid",
            "lineage",
            "lineage_raw",
            "lineage_raw_b64",
            "evidence",
            "executable",
            "elapsed_s",
            "started_at_s",
            "cwd",
        ]),
        JsonOrder::AdapterCandidate => Some(&[
            "pid",
            "harness",
            "ppid",
            "pgid",
            "lineage",
            "lineage_raw",
            "lineage_raw_b64",
            "evidence",
            "executable",
            "elapsed_s",
            "started_at_s",
            "cwd",
        ]),
        JsonOrder::Epistemics => Some(&[
            "census_grade",
            "absence_means",
            "lineage_is_claim",
            "pids_scanned",
            "pids_env_unreadable",
            "platform_limits",
            "notes",
        ]),
        JsonOrder::Natural => None,
    }
}

fn child_order(order: JsonOrder, key: &str) -> JsonOrder {
    match (order, key) {
        (JsonOrder::Report, "host") => JsonOrder::Host,
        (JsonOrder::Report, "base_dir") => JsonOrder::BaseDir,
        (JsonOrder::Report, "marked_candidates") => JsonOrder::Candidate,
        (JsonOrder::Report, "adapter_candidates") => JsonOrder::AdapterCandidate,
        (JsonOrder::Report, "epistemics") => JsonOrder::Epistemics,
        (JsonOrder::BaseDir, "entries") => JsonOrder::Entries,
        _ => JsonOrder::Natural,
    }
}

fn write_pretty_value(value: &Value, indent: usize, output: &mut String, order: JsonOrder) {
    match value {
        Value::Array(values) if values.is_empty() => output.push_str("[]"),
        Value::Array(values) => {
            output.push('[');
            for (index, value) in values.iter().enumerate() {
                output.push('\n');
                output.push_str(&" ".repeat(indent + 2));
                write_pretty_value(value, indent + 2, output, order);
                if index + 1 != values.len() {
                    output.push(',');
                }
            }
            output.push('\n');
            output.push_str(&" ".repeat(indent));
            output.push(']');
        }
        Value::Object(map) if map.is_empty() => output.push_str("{}"),
        Value::Object(map) => {
            output.push('{');
            let keys = object_key_order(order)
                .map(|keys| keys.iter().map(|key| (*key).to_owned()).collect::<Vec<_>>())
                .unwrap_or_else(|| map.keys().cloned().collect());
            for (index, key) in keys.iter().enumerate() {
                output.push('\n');
                output.push_str(&" ".repeat(indent + 2));
                output.push_str(&serde_json::to_string_pretty(key).expect("JSON key serializes"));
                output.push_str(": ");
                write_pretty_value(&map[key], indent + 2, output, child_order(order, key));
                if index + 1 != keys.len() {
                    output.push(',');
                }
            }
            output.push('\n');
            output.push_str(&" ".repeat(indent));
            output.push('}');
        }
        _ => output.push_str(&serde_json::to_string_pretty(value).expect("JSON value serializes")),
    }
}

fn report_json(report: &Report) -> String {
    let mut output = String::new();
    write_pretty_value(&report_value(report), 0, &mut output, JsonOrder::Report);
    output
}

pub fn run(json: bool, base_dir: Option<String>) -> Result<(), String> {
    let wall = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let probed_at_ms = u64::try_from(wall.as_millis()).unwrap_or(u64::MAX);
    let monotonic = Instant::now();
    let io = SystemIo;
    let resolved_base_dir = resolve_base_dir(base_dir);
    let harness_result = crate::harnesses::load_from(&resolved_base_dir);
    let harness_error = harness_result.as_ref().err().cloned();
    let harness_catalog = harness_result.as_ref().ok();
    let mut raw = match std::env::consts::OS {
        "linux" => collect_linux(&io, std::process::id(), harness_catalog)?,
        "macos" => collect_darwin(&io, std::process::id(), harness_catalog)?,
        _ => return Err("probe: unsupported platform".to_owned()),
    };
    if let Some(reason) = harness_error {
        raw.notes.push(reason);
    }
    add_elapsed(&io, &mut raw);
    let hostname = hostname(&io, &mut raw.notes);
    let base_dir = inspect_base_dir(&io, &resolved_base_dir, &mut raw.notes);
    let mut report = assemble(raw, probed_at_ms, 0, hostname, base_dir);
    report.collection_ms = u64::try_from(monotonic.elapsed().as_millis()).unwrap_or(u64::MAX);
    if json {
        println!("{}", report_json(&report));
    } else {
        println!("{}", human(&report));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stat(ppid: u32, pgid: u32, start: u64) -> Vec<u8> {
        let mut fields = vec!["S".to_owned(), ppid.to_string(), pgid.to_string()];
        fields.extend((6..=21).map(|_| "0".to_owned()));
        fields.push(start.to_string());
        format!("1 (odd ) ( comm) {}", fields.join(" ")).into_bytes()
    }

    #[derive(Default)]
    struct FakeIo {
        pids: Vec<u32>,
        reads: BTreeMap<(u32, String), Result<Vec<u8>, io::ErrorKind>>,
        read_sequences:
            std::cell::RefCell<BTreeMap<(u32, String), Vec<Result<Vec<u8>, io::ErrorKind>>>>,
        links: BTreeMap<(u32, String), Result<Vec<u8>, io::ErrorKind>>,
        commands: std::cell::RefCell<Vec<Result<Vec<u8>, CommandFailure>>>,
        metadata_error: Option<io::ErrorKind>,
        directory_error: Option<io::ErrorKind>,
    }

    impl ProbeIo for FakeIo {
        fn proc_pids(&self) -> io::Result<Vec<u32>> {
            Ok(self.pids.clone())
        }
        fn proc_read(&self, pid: u32, name: &str) -> io::Result<Vec<u8>> {
            if let Some(sequence) = self
                .read_sequences
                .borrow_mut()
                .get_mut(&(pid, name.to_owned()))
                && !sequence.is_empty()
            {
                return sequence.remove(0).map_err(io::Error::from);
            }
            self.reads
                .get(&(pid, name.to_owned()))
                .cloned()
                .unwrap_or(Err(io::ErrorKind::NotFound))
                .map_err(io::Error::from)
        }
        fn proc_read_link(&self, pid: u32, name: &str) -> io::Result<Vec<u8>> {
            self.links
                .get(&(pid, name.to_owned()))
                .cloned()
                .unwrap_or(Err(io::ErrorKind::NotFound))
                .map_err(io::Error::from)
        }
        fn path_metadata(&self, _path: &Path) -> io::Result<()> {
            self.metadata_error.map_or(Ok(()), |kind| Err(kind.into()))
        }
        fn directory_names(&self, _path: &Path) -> io::Result<Vec<OsString>> {
            self.directory_error
                .map_or_else(|| Ok(Vec::new()), |kind| Err(kind.into()))
        }
        fn command(
            &self,
            _program: &str,
            _args: &[OsString],
            _deadline: Duration,
        ) -> Result<Vec<u8>, CommandFailure> {
            self.commands.borrow_mut().remove(0)
        }
    }

    #[test]
    fn marker_codec_and_raw_policy() {
        let value = token_fields(Some(b"tb1-cmVzaWRlbnRAZWV6bw"));
        assert_eq!(value.lineage.as_deref(), Some("resident@eezo"));
        assert_eq!(value.raw_b64, None);
        assert_eq!(token_fields(Some(b"tb2-any")).lineage, None);
        assert_eq!(token_fields(Some(b"tb1-!!!")).lineage, None);
        let invalid = token_fields(Some(b"tb2-\xff"));
        assert_eq!(invalid.raw.as_deref(), Some("tb2-�"));
        assert_eq!(invalid.raw_b64.as_deref(), Some("dGIyLf8="));
        assert_eq!(token_fields(Some(&vec![b'x'; 300])).raw.unwrap().len(), 256);
    }

    #[test]
    fn fixture_process_marker_comes_from_the_projection() {
        assert_eq!(
            adapter_harnesses(
                b"node fixture-acp",
                Some(&crate::harnesses::catalog().unwrap())
            ),
            vec!["fixture".to_owned()]
        );
        assert!(
            adapter_harnesses(
                b"node absent-acp",
                Some(&crate::harnesses::catalog().unwrap())
            )
            .is_empty()
        );
    }

    #[test]
    fn environ_is_exact_and_stat_uses_last_paren() {
        assert_eq!(
            exact_environ_token(b"X_TIGHTBEAM_LINEAGE=no\0TIGHTBEAM_LINEAGE=yes\0"),
            Some(b"yes".to_vec())
        );
        assert_eq!(exact_environ_token(b"X_TIGHTBEAM_LINEAGE=no\0"), None);
        assert_eq!(parse_stat(&stat(2, 3, 99)), Some((2, 3, 99)));
    }

    #[test]
    fn darwin_boundary_and_prefer_decodable() {
        assert_eq!(preferred_token(b"x 'TIGHTBEAM_LINEAGE=bad"), None);
        assert_eq!(preferred_token(b"xTIGHTBEAM_LINEAGE=bad"), None);
        assert_eq!(
            preferred_token(b" TIGHTBEAM_LINEAGE=bad TIGHTBEAM_LINEAGE=tb1-YUBi"),
            Some(b"tb1-YUBi".to_vec())
        );
        assert_eq!(
            preferred_token(b"TIGHTBEAM_LINEAGE=first TIGHTBEAM_LINEAGE=second"),
            Some(b"first".to_vec())
        );
    }

    #[test]
    fn darwin_rows_distinguish_spoofable_marker_and_unmarked_adapter_evidence() {
        let rows = parse_darwin_pass1(
            b"7 Thu Jul 30 12:34:56 2026 node TIGHTBEAM_LINEAGE=tb1-YUBi\n\
              8 Thu Jul 30 12:34:56 2026 codex-acp\n",
            999,
            Some(&crate::harnesses::catalog().unwrap()),
        );
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].evidence, "argv_or_env_indistinguishable");
        assert_eq!(rows[1].evidence, "none_observed");
    }

    #[test]
    fn parsers_handle_spaces_lsof_and_etime() {
        let pass2 = parse_pass2(b" 7 1 7 /path with spaces\n");
        assert_eq!(pass2.get(&7).unwrap().2, b"/path with spaces");
        assert_eq!(
            parse_lsof(b"p7\nn/tmp/a b\n").get(&7),
            Some(&b"/tmp/a b".to_vec())
        );
        for (input, expected) in [
            (b"00:03".as_slice(), Some(3)),
            (b"59:59", Some(3599)),
            (b"2:00:00", Some(7200)),
            (b"3-12:00:01", Some(302_401)),
            (b"99:99", None),
            (b"garbage", None),
        ] {
            assert_eq!(parse_etime(input), expected);
        }
    }

    #[test]
    fn linux_retention_and_dual_harness_rows() {
        let mut io = FakeIo {
            pids: vec![10, 11, 12],
            ..FakeIo::default()
        };
        for pid in [10, 11, 12] {
            io.reads.insert((pid, "stat".into()), Ok(stat(1, pid, 5)));
        }
        io.reads.insert(
            (10, "environ".into()),
            Ok(b"TIGHTBEAM_LINEAGE=tb1-YUBi\0".to_vec()),
        );
        io.reads.insert((10, "cmdline".into()), Ok(Vec::new()));
        io.reads
            .insert((11, "environ".into()), Err(io::ErrorKind::PermissionDenied));
        io.reads.insert(
            (11, "cmdline".into()),
            Ok(b"npm claude-agent-acp codex-acp".to_vec()),
        );
        io.reads
            .insert((12, "environ".into()), Err(io::ErrorKind::PermissionDenied));
        io.reads
            .insert((12, "cmdline".into()), Ok(b"other".to_vec()));
        let raw = collect_linux(&io, 999, Some(&crate::harnesses::catalog().unwrap())).unwrap();
        assert_eq!(raw.pids_scanned, 3);
        assert_eq!(raw.pids_env_unreadable, Some(2));
        assert_eq!(raw.processes.len(), 2);
        assert_eq!(raw.processes[1].evidence, "env_unreadable");
        assert_eq!(raw.processes[1].harnesses, vec!["claude", "codex"]);
        assert_eq!(raw.processes[0].executable, None);
        assert_eq!(raw.processes[0].cwd, None);
    }

    #[test]
    fn linux_drops_environ_and_cmdline_enoent_but_keeps_cmdline_io_claim() {
        let mut io = FakeIo {
            pids: vec![20, 21, 22],
            ..FakeIo::default()
        };
        for pid in [20, 21, 22] {
            io.reads.insert((pid, "stat".into()), Ok(stat(1, pid, 9)));
        }
        io.reads
            .insert((20, "environ".into()), Err(io::ErrorKind::NotFound));
        io.reads.insert(
            (21, "environ".into()),
            Ok(b"TIGHTBEAM_LINEAGE=tb1-YUBi\0".to_vec()),
        );
        io.reads
            .insert((21, "cmdline".into()), Err(io::ErrorKind::NotFound));
        io.reads.insert(
            (22, "environ".into()),
            Ok(b"TIGHTBEAM_LINEAGE=tb1-YUBi\0".to_vec()),
        );
        io.reads
            .insert((22, "cmdline".into()), Err(io::ErrorKind::PermissionDenied));
        let raw = collect_linux(&io, 999, Some(&crate::harnesses::catalog().unwrap())).unwrap();
        assert_eq!(raw.pids_scanned, 3);
        assert_eq!(raw.processes.len(), 1);
        assert_eq!(raw.processes[0].pid, 22);
        assert_eq!(raw.processes[0].evidence, "environ_exact");
    }

    #[test]
    fn linux_drops_candidate_when_restat_starttime_changes() {
        let mut io = FakeIo {
            pids: vec![30],
            ..FakeIo::default()
        };
        io.read_sequences.borrow_mut().insert(
            (30, "stat".into()),
            vec![Ok(stat(1, 30, 9)), Ok(stat(1, 30, 10))],
        );
        io.reads.insert(
            (30, "environ".into()),
            Ok(b"TIGHTBEAM_LINEAGE=tb1-YUBi\0".to_vec()),
        );
        io.reads.insert((30, "cmdline".into()), Ok(Vec::new()));
        assert!(
            collect_linux(&io, 999, Some(&crate::harnesses::catalog().unwrap()))
                .unwrap()
                .processes
                .is_empty()
        );
    }

    #[test]
    fn linux_drops_candidate_when_restat_errors() {
        let mut io = FakeIo {
            pids: vec![31],
            ..FakeIo::default()
        };
        io.read_sequences.borrow_mut().insert(
            (31, "stat".into()),
            vec![Ok(stat(1, 31, 9)), Err(io::ErrorKind::PermissionDenied)],
        );
        io.reads.insert(
            (31, "environ".into()),
            Ok(b"TIGHTBEAM_LINEAGE=tb1-YUBi\0".to_vec()),
        );
        io.reads.insert((31, "cmdline".into()), Ok(Vec::new()));
        assert!(
            collect_linux(&io, 999, Some(&crate::harnesses::catalog().unwrap()))
                .unwrap()
                .processes
                .is_empty()
        );
    }

    #[test]
    fn linux_excludes_own_pid_from_candidate_set() {
        let mut io = FakeIo {
            pids: vec![40, 41],
            ..FakeIo::default()
        };
        for pid in [40, 41] {
            io.reads.insert((pid, "stat".into()), Ok(stat(1, pid, 9)));
            io.reads.insert(
                (pid, "environ".into()),
                Ok(b"TIGHTBEAM_LINEAGE=tb1-YUBi\0".to_vec()),
            );
            io.reads.insert((pid, "cmdline".into()), Ok(Vec::new()));
        }
        let raw = collect_linux(&io, 40, Some(&crate::harnesses::catalog().unwrap())).unwrap();
        assert_eq!(raw.pids_scanned, 2);
        assert_eq!(
            raw.processes.iter().map(|row| row.pid).collect::<Vec<_>>(),
            vec![41]
        );
    }

    #[test]
    fn darwin_deadline_degradation_retains_rows_and_successful_absence_drops() {
        let pass1 =
            b"7 Thu Jul 30 12:34:56 2026 node codex-acp TIGHTBEAM_LINEAGE=tb1-YUBi\n".to_vec();
        let io = FakeIo {
            commands: std::cell::RefCell::new(vec![
                Ok(pass1.clone()),
                Err(CommandFailure::Timeout),
                Err(CommandFailure::Failed),
            ]),
            ..FakeIo::default()
        };
        let raw = collect_darwin(&io, 999, Some(&crate::harnesses::catalog().unwrap())).unwrap();
        assert_eq!(raw.processes.len(), 1);
        assert_eq!(raw.processes[0].ppid, None);
        assert_eq!(raw.processes[0].executable, None);
        assert_eq!(raw.processes[0].cwd, None);
        assert_eq!(raw.notes, vec!["ps pass 2 timed out", "lsof failed"]);

        let io = FakeIo {
            commands: std::cell::RefCell::new(vec![Ok(pass1), Ok(Vec::new()), Ok(Vec::new())]),
            ..FakeIo::default()
        };
        assert!(
            collect_darwin(&io, 999, Some(&crate::harnesses::catalog().unwrap()))
                .unwrap()
                .processes
                .is_empty()
        );
    }

    #[test]
    fn darwin_drops_candidate_when_final_lstart_changes() {
        let io = FakeIo {
            commands: std::cell::RefCell::new(vec![
                Ok(b"7 Thu Jul 30 12:34:56 2026 node codex-acp\n".to_vec()),
                Ok(b"7 1 7 /usr/local/bin/node\n".to_vec()),
                Ok(b"p7\nfcwd\nn/tmp/work\n".to_vec()),
                Ok(b"7 00:03\n".to_vec()),
                Ok(b"7 Fri Jul 31 12:34:56 2026\n".to_vec()),
            ]),
            ..FakeIo::default()
        };
        let mut raw =
            collect_darwin(&io, 999, Some(&crate::harnesses::catalog().unwrap())).unwrap();
        add_elapsed(&io, &mut raw);
        assert!(raw.processes.is_empty());
    }

    #[test]
    fn darwin_retains_candidate_with_failure_note_when_identity_check_fails() {
        let io = FakeIo {
            commands: std::cell::RefCell::new(vec![
                Ok(b"7 Thu Jul 30 12:34:56 2026 node codex-acp\n".to_vec()),
                Ok(b"7 1 7 /usr/local/bin/node\n".to_vec()),
                Ok(b"p7\nfcwd\nn/tmp/work\n".to_vec()),
                Ok(b"7 00:03\n".to_vec()),
                Err(CommandFailure::Timeout),
            ]),
            ..FakeIo::default()
        };
        let mut raw =
            collect_darwin(&io, 999, Some(&crate::harnesses::catalog().unwrap())).unwrap();
        add_elapsed(&io, &mut raw);
        assert_eq!(raw.processes.len(), 1);
        assert_eq!(raw.processes[0].pid, 7);
        assert_eq!(raw.notes, vec!["ps identity timed out"]);
    }

    #[test]
    fn darwin_pass1_timeout_and_failure_are_fatal() {
        for (failure, expected) in [
            (CommandFailure::Timeout, "probe: ps enumeration timed out"),
            (CommandFailure::Failed, "probe: ps enumeration failed"),
        ] {
            let io = FakeIo {
                commands: std::cell::RefCell::new(vec![Err(failure)]),
                ..FakeIo::default()
            };
            assert_eq!(
                collect_darwin(&io, 999, Some(&crate::harnesses::catalog().unwrap())).unwrap_err(),
                expected
            );
        }
    }

    #[test]
    fn privacy_discards_full_command_buffers() {
        let io = FakeIo {
            commands: std::cell::RefCell::new(vec![
                Ok(b"7 Thu Jul 30 12:34:56 2026 node codex-acp --token SECRETXYZ\n".to_vec()),
                Ok(b"7 1 7 /usr/local/bin/node\n".to_vec()),
                Ok(b"p7\nfcwd\nn/tmp/work\n".to_vec()),
            ]),
            ..FakeIo::default()
        };
        let raw = collect_darwin(&io, 999, Some(&crate::harnesses::catalog().unwrap())).unwrap();
        let report = assemble(
            raw,
            1,
            2,
            "host".into(),
            inspect_base_dir(&SystemIo, Path::new("/missing"), &mut Vec::new()),
        );
        assert_eq!(report.adapter_candidates.len(), 1);
        assert_eq!(report.adapter_candidates[0].pid, 7);
        assert!(
            !serde_json::to_string(&report_value(&report))
                .unwrap()
                .contains("SECRETXYZ")
        );
    }

    #[test]
    fn assembly_groups_fallback_and_preserves_row_parity() {
        let raw = RawFacts {
            platform: "linux",
            pids_scanned: 2,
            pids_env_unreadable: Some(0),
            processes: vec![RawProcess {
                pid: 4,
                lstart: None,
                ppid: Some(1),
                pgid: Some(4),
                token: Some(b"tb2-raw".to_vec()),
                evidence: "environ_exact",
                executable: Some(b"/x/\xff".to_vec()),
                cwd: Some(b"/c/\xff".to_vec()),
                elapsed_s: Some(3),
                harnesses: vec!["codex".to_owned()],
            }],
            notes: Vec::new(),
        };
        let report = assemble(
            raw,
            10_000,
            7,
            "host".into(),
            inspect_base_dir(
                &SystemIo,
                Path::new("/definitely/missing/tb"),
                &mut Vec::new(),
            ),
        );
        assert_eq!(report.identity_candidates.get("tb2-raw"), Some(&vec![4]));
        assert_eq!(report.marked_candidates[0].started_at_s, Some(7));
        assert_eq!(
            report.marked_candidates[0].executable.as_deref(),
            Some("/x/�")
        );
        assert_eq!(
            report.adapter_candidates[0].lineage_raw,
            report.marked_candidates[0].lineage_raw
        );
    }

    #[test]
    fn base_dir_has_closed_entries_and_root_log_count() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam_probe_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("state.db-wal"), b"").unwrap();
        fs::write(root.join("state.db-shm"), b"").unwrap();
        fs::write(root.join("adapter-codex:x@y.stderr.log"), b"").unwrap();
        let base = inspect_base_dir(&SystemIo, &root, &mut Vec::new());
        assert_eq!(base.status, "present");
        assert_eq!(base.adapter_stderr_log_count, Some(1));
        assert_eq!(base.entries.state_db, "absent");
        assert_eq!(entries_value(&base.entries).as_object().unwrap().len(), 10);
        fs::remove_dir_all(root).unwrap();

        let unreadable = FakeIo {
            directory_error: Some(io::ErrorKind::PermissionDenied),
            ..FakeIo::default()
        };
        let mut notes = Vec::new();
        let base = inspect_base_dir(&unreadable, Path::new("/opaque"), &mut notes);
        assert_eq!(base.status, "unreadable");
        assert_eq!(base.adapter_stderr_log_count, None);
        assert_eq!(base.entries.adapters, "unreadable");
        assert_eq!(notes, vec!["base directory read_dir failed"]);
    }

    #[test]
    fn timeout_notes_are_constant_and_do_not_leak_raw_buffers() {
        let raw = RawFacts {
            platform: "macos",
            pids_scanned: 0,
            pids_env_unreadable: None,
            processes: Vec::new(),
            notes: vec!["lsof timed out".to_owned()],
        };
        let report = assemble(
            raw,
            1,
            2,
            "host".into(),
            inspect_base_dir(&SystemIo, Path::new("/missing"), &mut Vec::new()),
        );
        let encoded = serde_json::to_string(&report_value(&report)).unwrap();
        assert!(!encoded.contains("SECRETXYZ"));
        assert!(encoded.contains("lsof timed out"));
    }

    #[test]
    fn empty_report_schema_is_byte_stable() {
        let raw = RawFacts {
            platform: "linux",
            pids_scanned: 0,
            pids_env_unreadable: Some(0),
            processes: Vec::new(),
            notes: Vec::new(),
        };
        let report = assemble(
            raw,
            1000,
            5,
            "host".into(),
            BaseDir {
                path: "/missing".into(),
                status: "absent",
                entries: entries_with("absent"),
                adapter_stderr_log_count: None,
            },
        );
        let encoded = format!("{}\n", report_json(&report));
        assert_eq!(
            encoded,
            r#"{
  "schema": "tightbeam.probe.v1",
  "probed_at_ms": 1000,
  "collection_ms": 5,
  "host": {
    "hostname": "host",
    "platform": "linux",
    "probe_version": "0.1.0"
  },
  "base_dir": {
    "path": "/missing",
    "status": "absent",
    "entries": {
      "adapters": "absent",
      "assets": "absent",
      "auth": "absent",
      "bin": "absent",
      "gateway.json": "absent",
      "homes": "absent",
      "identity": "absent",
      "staging": "absent",
      "state.db": "absent",
      "work": "absent"
    },
    "adapter_stderr_log_count": null
  },
  "marked_candidates": [],
  "identity_candidates": {},
  "adapter_candidates": [],
  "epistemics": {
    "census_grade": "accident",
    "absence_means": "possibly_laundered",
    "lineage_is_claim": true,
    "pids_scanned": 0,
    "pids_env_unreadable": 0,
    "platform_limits": [
      "environ is ptrace-gated; other-user and protected processes are unreadable",
      "procfs may hide processes entirely",
      "markers are spoofable env content"
    ],
    "notes": []
  }
}
"#
        );
    }

    #[test]
    fn populated_report_schema_is_byte_stable() {
        let raw = RawFacts {
            platform: "linux",
            pids_scanned: 3,
            pids_env_unreadable: Some(1),
            processes: vec![
                RawProcess {
                    pid: 9,
                    lstart: None,
                    ppid: Some(2),
                    pgid: Some(9),
                    token: Some(b"raw\xff".to_vec()),
                    evidence: "env_unreadable",
                    executable: Some(b"/bin/codex".to_vec()),
                    cwd: Some(b"/tmp/codex".to_vec()),
                    elapsed_s: Some(5),
                    harnesses: vec!["codex".to_owned()],
                },
                RawProcess {
                    pid: 4,
                    lstart: None,
                    ppid: Some(1),
                    pgid: Some(4),
                    token: Some(b"tb1-YUBi".to_vec()),
                    evidence: "environ_exact",
                    executable: Some(b"/bin/node".to_vec()),
                    cwd: Some(b"/work".to_vec()),
                    elapsed_s: Some(3),
                    harnesses: vec!["claude".to_owned(), "codex".to_owned()],
                },
            ],
            notes: vec!["ps etime timed out".to_owned()],
        };
        let report = assemble(
            raw,
            10_000,
            7,
            "eezo".into(),
            BaseDir {
                path: "/srv/tightbeam".into(),
                status: "present",
                entries: entries_with("present"),
                adapter_stderr_log_count: Some(2),
            },
        );
        let encoded = format!("{}\n", report_json(&report));
        assert_eq!(
            encoded,
            r#"{
  "schema": "tightbeam.probe.v1",
  "probed_at_ms": 10000,
  "collection_ms": 7,
  "host": {
    "hostname": "eezo",
    "platform": "linux",
    "probe_version": "0.1.0"
  },
  "base_dir": {
    "path": "/srv/tightbeam",
    "status": "present",
    "entries": {
      "adapters": "present",
      "assets": "present",
      "auth": "present",
      "bin": "present",
      "gateway.json": "present",
      "homes": "present",
      "identity": "present",
      "staging": "present",
      "state.db": "present",
      "work": "present"
    },
    "adapter_stderr_log_count": 2
  },
  "marked_candidates": [
    {
      "pid": 4,
      "ppid": 1,
      "pgid": 4,
      "lineage": "a@b",
      "lineage_raw": "tb1-YUBi",
      "lineage_raw_b64": null,
      "evidence": "environ_exact",
      "executable": "/bin/node",
      "elapsed_s": 3,
      "started_at_s": 7,
      "cwd": "/work"
    },
    {
      "pid": 9,
      "ppid": 2,
      "pgid": 9,
      "lineage": null,
      "lineage_raw": "raw�",
      "lineage_raw_b64": "cmF3/w==",
      "evidence": "env_unreadable",
      "executable": "/bin/codex",
      "elapsed_s": 5,
      "started_at_s": 5,
      "cwd": "/tmp/codex"
    }
  ],
  "identity_candidates": {
    "a@b": [
      4
    ],
    "raw�": [
      9
    ]
  },
  "adapter_candidates": [
    {
      "pid": 4,
      "harness": "claude",
      "ppid": 1,
      "pgid": 4,
      "lineage": "a@b",
      "lineage_raw": "tb1-YUBi",
      "lineage_raw_b64": null,
      "evidence": "environ_exact",
      "executable": "/bin/node",
      "elapsed_s": 3,
      "started_at_s": 7,
      "cwd": "/work"
    },
    {
      "pid": 4,
      "harness": "codex",
      "ppid": 1,
      "pgid": 4,
      "lineage": "a@b",
      "lineage_raw": "tb1-YUBi",
      "lineage_raw_b64": null,
      "evidence": "environ_exact",
      "executable": "/bin/node",
      "elapsed_s": 3,
      "started_at_s": 7,
      "cwd": "/work"
    },
    {
      "pid": 9,
      "harness": "codex",
      "ppid": 2,
      "pgid": 9,
      "lineage": null,
      "lineage_raw": "raw�",
      "lineage_raw_b64": "cmF3/w==",
      "evidence": "env_unreadable",
      "executable": "/bin/codex",
      "elapsed_s": 5,
      "started_at_s": 5,
      "cwd": "/tmp/codex"
    }
  ],
  "epistemics": {
    "census_grade": "accident",
    "absence_means": "possibly_laundered",
    "lineage_is_claim": true,
    "pids_scanned": 3,
    "pids_env_unreadable": 1,
    "platform_limits": [
      "environ is ptrace-gated; other-user and protected processes are unreadable",
      "procfs may hide processes entirely",
      "markers are spoofable env content"
    ],
    "notes": [
      "ps etime timed out"
    ]
  }
}
"#
        );
    }
}
