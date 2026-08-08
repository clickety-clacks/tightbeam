use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::{fs, time::SystemTime};

fn executable(path: &std::path::Path, body: &str) {
    fs::write(path, body).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

#[test]
fn doctor_exits_nonzero_when_no_registered_harness_cli_is_runnable() {
    let unique = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("tightbeam-doctor-exit-{unique}"));
    let path = root.join("path");
    let base_dir = root.join("org");
    fs::create_dir_all(&path).unwrap();

    executable(&path.join("uname"), "#!/bin/sh\nprintf 'test-host\\n'\n");
    executable(&path.join("ps"), "#!/bin/sh\nexit 0\n");
    executable(&path.join("lsof"), "#!/bin/sh\nexit 0\n");

    let output = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["doctor", "--base-dir", base_dir.to_str().unwrap()])
        .env("PATH", &path)
        .output()
        .unwrap();

    assert!(
        !output.status.success(),
        "doctor exited zero even though PATH contained no registered harness CLI"
    );
    assert!(
        !String::from_utf8_lossy(&output.stdout).contains("run tightbeam doctor"),
        "doctor's own note pointed back to doctor"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn doctor_reports_banked_oauth_corruption_as_structured_data_and_fails() {
    let unique = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("tightbeam-doctor-corrupt-{unique}"));
    let path = root.join("path");
    let base_dir = root.join("org");
    let store = base_dir.join("auth").join("claude");
    fs::create_dir_all(&path).unwrap();
    fs::create_dir_all(store.join(".tightbeam")).unwrap();

    executable(&path.join("codex"), "#!/bin/sh\nexit 0\n");
    let metadata = fs::read(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../test/fixtures/credentials/anthropic-subscription-metadata.json"),
    )
    .unwrap();
    fs::write(store.join(".tightbeam").join("credential.json"), metadata).unwrap();
    let mut captured: serde_json::Value = serde_json::from_slice(
        &fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../test/fixtures/credentials/claude-hollow-oauth-captured.json"),
        )
        .unwrap(),
    )
    .unwrap();
    captured["claudeAiOauth"]["auditSecret"] = serde_json::Value::from("MUST-NOT-LEAK");
    fs::write(
        store.join(".credentials.json"),
        serde_json::to_vec(&captured).unwrap(),
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["doctor", "--json", "--base-dir", base_dir.to_str().unwrap()])
        .env("PATH", &path)
        .output()
        .unwrap();

    assert!(
        !output.status.success(),
        "a corrupt credential passed doctor"
    );
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        report["credential_health"]["anthropic"]["status"],
        "corrupt"
    );
    assert_eq!(
        report["credential_health"]["anthropic"]["corrupt_fields"],
        serde_json::json!([
            "claudeAiOauth.accessToken",
            "claudeAiOauth.refreshToken",
            "claudeAiOauth.expiresAt"
        ])
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("banked OAuth credential for anthropic is CORRUPT"));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("MUST-NOT-LEAK"));
    assert!(!stderr.contains("MUST-NOT-LEAK"));

    fs::remove_dir_all(root).unwrap();
}
