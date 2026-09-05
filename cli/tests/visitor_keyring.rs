use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_BASE_DIR_ID: AtomicU64 = AtomicU64::new(0);

fn base_dir() -> PathBuf {
    std::env::temp_dir().join(format!(
        "tightbeam-visitor-keyring-cli-{}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos(),
        NEXT_BASE_DIR_ID.fetch_add(1, Ordering::Relaxed)
    ))
}

#[test]
fn keyring_init_reports_only_the_durable_path_and_ids_and_never_replaces() {
    let base = base_dir();
    fs::create_dir(&base).unwrap();

    let first = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["visitor", "keyring-init", "--base-dir"])
        .arg(&base)
        .output()
        .unwrap();
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    assert!(first.stderr.is_empty());

    let public: serde_json::Value = serde_json::from_slice(&first.stdout).unwrap();
    let object = public.as_object().unwrap();
    assert_eq!(object.len(), 3);
    assert!(
        object["activeDerivationKeyId"]
            .as_str()
            .unwrap()
            .starts_with("vdk_")
    );
    assert!(
        object["activeDigestKeyId"]
            .as_str()
            .unwrap()
            .starts_with("vgk_")
    );

    let path = base.join("secrets/visitor-keyring-v1.json");
    assert_eq!(object["path"].as_str().unwrap(), path.to_string_lossy());
    assert_eq!(
        fs::metadata(base.join("secrets")).unwrap().mode() & 0o7777,
        0o700
    );
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o7777, 0o600);

    let stored = fs::read(&path).unwrap();
    let document: serde_json::Value = serde_json::from_slice(&stored).unwrap();
    for key in document["keys"].as_object().unwrap().values() {
        let encoded = key["bytesBase64"].as_str().unwrap();
        assert!(
            !first
                .stdout
                .windows(encoded.len())
                .any(|window| window == encoded.as_bytes())
        );
        assert!(
            !first
                .stderr
                .windows(encoded.len())
                .any(|window| window == encoded.as_bytes())
        );
    }

    let second = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["visitor", "keyring-init", "--base-dir"])
        .arg(&base)
        .output()
        .unwrap();
    assert!(!second.status.success());
    assert!(second.stdout.is_empty());
    assert_eq!(
        String::from_utf8(second.stderr).unwrap(),
        "visitor_keyring_exists\n"
    );
    assert_eq!(fs::read(&path).unwrap(), stored);

    fs::remove_dir_all(base).unwrap();
}

#[test]
fn concurrent_cli_initializers_publish_exactly_one_keyring() {
    let base = base_dir();
    fs::create_dir(&base).unwrap();
    let barrier = Arc::new(Barrier::new(9));
    let mut workers = Vec::new();

    for _ in 0..8 {
        let base = base.clone();
        let barrier = barrier.clone();
        workers.push(thread::spawn(move || {
            barrier.wait();
            Command::new(env!("CARGO_BIN_EXE_tightbeam"))
                .args(["visitor", "keyring-init", "--base-dir"])
                .arg(base)
                .output()
                .unwrap()
        }));
    }
    barrier.wait();

    let outputs = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect::<Vec<_>>();
    let winners = outputs
        .iter()
        .filter(|output| output.status.success())
        .collect::<Vec<_>>();
    assert_eq!(winners.len(), 1);

    for loser in outputs.iter().filter(|output| !output.status.success()) {
        assert!(loser.stdout.is_empty());
        let error = String::from_utf8(loser.stderr.clone()).unwrap();
        assert!(
            matches!(
                error.as_str(),
                "visitor_keyring_init_busy\n" | "visitor_keyring_exists\n"
            ),
            "unexpected refusal: {error:?}"
        );
    }

    let public: serde_json::Value = serde_json::from_slice(&winners[0].stdout).unwrap();
    let stored = fs::read(base.join("secrets/visitor-keyring-v1.json")).unwrap();
    let document: serde_json::Value = serde_json::from_slice(&stored).unwrap();
    assert_eq!(
        public["activeDerivationKeyId"],
        document["activeDerivationKeyId"]
    );
    assert_eq!(public["activeDigestKeyId"], document["activeDigestKeyId"]);

    fs::remove_dir_all(base).unwrap();
}
