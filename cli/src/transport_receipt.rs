//! R6: one DB-independent, non-waiting append/rotate seam for CLI failures.
//! Callers provide only the closed diagnostic record; errors here never replace
//! the request result or expose an OS error, path, or rejected record.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

pub(crate) const SEGMENT_BYTES: u64 = 4 * 1024 * 1024;
pub(crate) const SEGMENT_RECORDS: usize = 1024;
const RECORD_BYTES: usize = 4096;

/// A record is built from typed transport evidence at the request seam. The
/// writer repeats the field whitelist so future response fields cannot leak
/// into a receipt by passing a whole gateway envelope to the sink.
pub(crate) fn append(base: &Path, record: &serde_json::Value) -> bool {
    append_inner(base, record).is_ok()
}

fn append_inner(base: &Path, record: &serde_json::Value) -> Result<(), ()> {
    let mut fields = serde_json::Map::new();
    for name in [
        "observed_at_ms",
        "request_id",
        "code",
        "operation",
        "effect_kind",
        "listener_generation",
        "cause",
        "timeout_source",
        "budget_ms",
        "elapsed_ms",
        "gateway_accepted",
        "effect_state",
        "action",
    ] {
        fields.insert(
            name.to_owned(),
            record.get(name).cloned().unwrap_or(serde_json::Value::Null),
        );
    }
    fields.insert("schema_version".into(), "cli-transport-v1".into());
    fields.insert("event".into(), "cli_transport_failed".into());
    fields.insert("actor".into(), "process:tightbeam".into());
    fields.insert("principal_kind".into(), "unknown".into());
    fields.insert("principal_ref".into(), serde_json::Value::Null);
    let mut line = serde_json::to_vec(&fields).map_err(|_| ())?;
    line.push(b'\n');
    if line.len() > RECORD_BYTES {
        return Err(());
    }

    let dir = base.join("diagnostics");
    fs::create_dir_all(&dir).map_err(|_| ())?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).map_err(|_| ())?;

    let lock = ReceiptLock::acquire(&dir.join("cli-transport-v1.lock"))?;
    let path = dir.join("cli-transport-v1.log");
    let mut active = private_file(&path, true)?;
    let size = active.metadata().map_err(|_| ())?.len();
    let mut count = 0;
    let mut complete = true;
    let mut buffer = [0_u8; 65536];
    loop {
        let n = active.read(&mut buffer).map_err(|_| ())?;
        if n == 0 {
            break;
        }
        count += buffer[..n].iter().filter(|b| **b == b'\n').count();
        complete = buffer[n - 1] == b'\n';
    }
    if !complete || count >= SEGMENT_RECORDS || size + line.len() as u64 > SEGMENT_BYTES {
        drop(active);
        fs::rename(&path, dir.join("cli-transport-v1.log.1")).map_err(|_| ())?;
        active = private_file(&path, true)?;
    }
    active.seek(SeekFrom::End(0)).map_err(|_| ())?;
    active.write_all(&line).map_err(|_| ())?;
    drop(active);
    drop(lock);
    Ok(())
}

struct ReceiptLock(File);

impl ReceiptLock {
    fn acquire(path: &Path) -> Result<Self, ()> {
        // Each attempt opens an independent file description, so contention
        // refuses immediately even between threads in one process.
        let file = private_file(path, false)?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(());
        }
        Ok(Self(file))
    }
}

impl Drop for ReceiptLock {
    fn drop(&mut self) {
        // Explicitly release before close: a concurrently spawned child can
        // briefly inherit this open file description before exec closes it.
        // Closing only our descriptor would leave that shared lock alive.
        // This also releases on failed append/rename; never unlink the lock.
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn private_file(path: &Path, read: bool) -> Result<File, ()> {
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .read(read)
        .truncate(false)
        .mode(0o600)
        .open(path)
        .map_err(|_| ())?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|_| ())?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Temp(std::path::PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "tightbeam-receipt-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn file(&self, suffix: &str) -> std::path::PathBuf {
            self.0
                .join("diagnostics")
                .join(format!("cli-transport-v1.log{suffix}"))
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn record() -> serde_json::Value {
        serde_json::json!({"observed_at_ms": 1, "request_id": "req_abcdefghijklmnopqrstuv",
            "code": "gateway_unavailable", "operation": "cli.list", "effect_kind": "read",
            "listener_generation": null, "cause": "connect_refused", "timeout_source": "none",
            "budget_ms": null, "elapsed_ms": 1, "gateway_accepted": false,
            "effect_state": "none", "action": "retry_safe"})
    }

    #[test]
    fn writer_owns_schema_principal_and_whitelist_and_private_permissions() {
        let temp = Temp::new();
        let mut value = record();
        value["token"] = "sentinel_token".into();
        value["principal_ref"] = "sentinel_credential_identity".into();
        value["schema_version"] = "not_the_writer".into();
        assert!(append(&temp.0, &value));
        let encoded = fs::read_to_string(temp.file("")).unwrap();
        assert!(!encoded.contains("sentinel"));
        let written: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(written["schema_version"], "cli-transport-v1");
        assert_eq!(written["principal_ref"], serde_json::Value::Null);
        assert_eq!(written["principal_kind"], "unknown");
        assert_eq!(
            fs::metadata(temp.0.join("diagnostics"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(temp.file("")).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn count_rotation_retains_only_two_bounded_parseable_segments() {
        let temp = Temp::new();
        for _ in 0..(SEGMENT_RECORDS * 2 + 3) {
            assert!(append(&temp.0, &record()));
        }
        let active = fs::read_to_string(temp.file("")).unwrap();
        let prior = fs::read_to_string(temp.file(".1")).unwrap();
        assert_eq!(active.lines().count(), 3);
        assert_eq!(prior.lines().count(), SEGMENT_RECORDS);
        assert!(active.len() + prior.len() <= (SEGMENT_BYTES * 2) as usize);
        assert!(!temp.file(".2").exists());
        for line in active.lines().chain(prior.lines()) {
            serde_json::from_str::<serde_json::Value>(line).unwrap();
        }
    }

    #[test]
    fn byte_limit_rotates_before_append_and_torn_tail_does_not_swallow_next_record() {
        let temp = Temp::new();
        assert!(append(&temp.0, &record()));
        let safe = fs::read_to_string(temp.file("")).unwrap();
        let padding = format!(
            "\"{}\"\n",
            "a".repeat(SEGMENT_BYTES as usize - safe.len() - 3)
        );
        fs::write(temp.file(""), format!("{safe}{padding}")).unwrap();
        assert!(append(&temp.0, &record()));
        assert_eq!(fs::metadata(temp.file(".1")).unwrap().len(), SEGMENT_BYTES);
        assert_eq!(
            fs::read_to_string(temp.file("")).unwrap().lines().count(),
            1
        );
        fs::write(temp.file(""), format!("{safe}{{\"torn\":")).unwrap();
        assert!(append(&temp.0, &record()));
        assert_eq!(
            fs::read_to_string(temp.file(".1")).unwrap(),
            format!("{safe}{{\"torn\":")
        );
        serde_json::from_str::<serde_json::Value>(&fs::read_to_string(temp.file("")).unwrap())
            .unwrap();
    }

    #[test]
    fn contention_and_write_failure_report_unavailable_without_wait_or_raw_error() {
        let temp = Temp::new();
        assert!(append(&temp.0, &record()));
        let lock = private_file(&temp.0.join("diagnostics/cli-transport-v1.lock"), false).unwrap();
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let (tx, rx) = std::sync::mpsc::channel();
        let base = temp.0.clone();
        let thread = std::thread::spawn(move || tx.send(append(&base, &record())).unwrap());
        assert!(
            !rx.recv_timeout(std::time::Duration::from_secs(2))
                .expect("must not wait for lock")
        );
        thread.join().unwrap();
        drop(lock);
        let invalid = temp.0.join("not_directory");
        fs::write(&invalid, "sentinel_path").unwrap();
        assert!(!append(&invalid, &record()));
        let mut oversized = record();
        oversized["operation"] = "a".repeat(4096).into();
        assert!(!append(&temp.0, &oversized));
        assert_eq!(
            fs::read_to_string(temp.file("")).unwrap().lines().count(),
            1
        );
    }

    #[test]
    fn independent_processes_share_nonwaiting_lock_and_rotation() {
        const CHILD_BASE: &str = "TIGHTBEAM_RECEIPT_TEST_BASE";
        const CHILD_MODE: &str = "TIGHTBEAM_RECEIPT_TEST_MODE";
        const TEST: &str =
            "transport_receipt::tests::independent_processes_share_nonwaiting_lock_and_rotation";

        // Re-enter this test in a fresh OS process so the actual writer opens
        // its own lock descriptor. These controls exist only in the test
        // executable; no production delay/failure API is introduced.
        if let Some(base) = std::env::var_os(CHILD_BASE) {
            let base = std::path::PathBuf::from(base);
            let mode = std::env::var(CHILD_MODE).unwrap();
            if mode == "contended" {
                assert!(!append(&base, &record()));
            } else {
                let accepted = (0..128).filter(|_| append(&base, &record())).count();
                fs::write(base.join(format!("accepted-{mode}")), accepted.to_string()).unwrap();
            }
            return;
        }

        fn spawn(base: &Path, mode: &str) -> std::process::Child {
            std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST, "--nocapture"])
                .env(CHILD_BASE, base)
                .env(CHILD_MODE, mode)
                .spawn()
                .unwrap()
        }

        fn finish(child: &mut std::process::Child) {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    assert!(status.success(), "receipt child failed: {status}");
                    return;
                }
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("receipt child waited for a lock or failed to exit");
                }
                // Timeout guard only: test ordering uses the held OS lock,
                // not a sleep intended to guess when a write has happened.
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }

        let temp = Temp::new();
        for _ in 0..SEGMENT_RECORDS {
            assert!(append(&temp.0, &record()));
        }
        let lock = private_file(&temp.0.join("diagnostics/cli-transport-v1.lock"), false).unwrap();
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let mut contended = spawn(&temp.0, "contended");
        // The lock remains held until the child has exited: a blocking lock
        // implementation fails this proof instead of being released for it.
        finish(&mut contended);
        drop(lock);

        let mut children: Vec<_> = (0..4).map(|i| spawn(&temp.0, &i.to_string())).collect();
        for child in &mut children {
            finish(child);
        }
        let accepted: usize = (0..4)
            .map(|i| {
                fs::read_to_string(temp.0.join(format!("accepted-{i}")))
                    .unwrap()
                    .parse::<usize>()
                    .unwrap()
            })
            .sum();
        assert!(accepted > 0);
        assert!(accepted <= 512);

        let active = fs::read_to_string(temp.file("")).unwrap();
        let prior = fs::read_to_string(temp.file(".1")).unwrap();
        assert_eq!(prior.lines().count(), SEGMENT_RECORDS);
        assert_eq!(active.lines().count(), accepted);
        assert!(active.len() + prior.len() <= (SEGMENT_BYTES * 2) as usize);
        for line in active.lines().chain(prior.lines()) {
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            assert_eq!(value["event"], "cli_transport_failed");
            assert_eq!(value["request_id"], record()["request_id"]);
        }
        assert!(!temp.file(".2").exists());
    }

    #[test]
    fn inherited_descriptor_does_not_extend_completed_writer_lock() {
        let temp = Temp::new();
        assert!(append(&temp.0, &record()));
        let lock = ReceiptLock::acquire(&temp.0.join("diagnostics/cli-transport-v1.lock")).unwrap();
        // dup shares the same open file description just as fork inheritance
        // does; retain that reference across the writer ownership boundary.
        let inherited = lock.0.try_clone().unwrap();
        assert!(!append(&temp.0, &record()));
        drop(lock);
        assert!(append(&temp.0, &record()));
        drop(inherited);
        assert_eq!(
            fs::read_to_string(temp.file("")).unwrap().lines().count(),
            2
        );
    }
}
