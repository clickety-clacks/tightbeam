use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::{fs, time::SystemTime};

fn executable(path: &std::path::Path, body: &str) {
    fs::write(path, body).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn test_root(subject: &str) -> std::path::PathBuf {
    let unique = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("tightbeam-doctor-{subject}-{unique}"))
}

fn bank_captured_hollow_anthropic(base_dir: &std::path::Path) {
    let store = base_dir.join("auth").join("claude");
    fs::create_dir_all(store.join(".tightbeam")).unwrap();
    fs::write(
        store.join(".tightbeam").join("credential.json"),
        serde_json::to_vec(&serde_json::json!({
            "provider": "anthropic",
            "kind": "subscription",
            "onboarded": true
        }))
        .unwrap(),
    )
    .unwrap();
    // Captured from the real hollow Claude credential that caused the incident. Keep the
    // surrounding vendor fields so this exercises the banked response shape, not a toy object.
    let captured = serde_json::json!({
        "claudeAiOauth": {
            "accessToken": "",
            "refreshToken": "",
            "expiresAt": 0,
            "refreshTokenExpiresAt": 0,
            "scopes": [],
            "subscriptionType": "",
            "rateLimitTier": "",
            "auditSecret": "MUST-NOT-LEAK"
        }
    });
    fs::write(
        store.join(".credentials.json"),
        serde_json::to_vec(&captured).unwrap(),
    )
    .unwrap();
}

#[test]
fn doctor_exits_nonzero_when_no_registered_harness_cli_is_runnable() {
    let root = test_root("exit");
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
fn doctor_reports_banked_oauth_corruption_after_ps_failure() {
    let root = test_root("corrupt");
    let path = root.join("path");
    let base_dir = root.join("org");
    fs::create_dir_all(&path).unwrap();

    executable(&path.join("codex"), "#!/bin/sh\nexit 0\n");
    executable(&path.join("uname"), "#!/bin/sh\nprintf 'test-host\\n'\n");
    executable(&path.join("ps"), "#!/bin/sh\nexit 1\n");
    bank_captured_hollow_anthropic(&base_dir);

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
    if cfg!(target_os = "macos") {
        assert!(
            report["epistemics"]["notes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|note| note == "probe: ps enumeration failed")
        );
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("banked OAuth credential for anthropic is CORRUPT"));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("MUST-NOT-LEAK"));
    assert!(!stderr.contains("MUST-NOT-LEAK"));

    fs::remove_dir_all(root).unwrap();
}

#[cfg(target_os = "macos")]
#[test]
fn doctor_reports_ordinary_ps_failure_as_structured_data_and_fails() {
    let root = test_root("ps-failure");
    let path = root.join("path");
    let base_dir = root.join("org");
    fs::create_dir_all(&path).unwrap();

    executable(&path.join("codex"), "#!/bin/sh\nexit 0\n");
    executable(&path.join("uname"), "#!/bin/sh\nprintf 'test-host\\n'\n");
    executable(&path.join("ps"), "#!/bin/sh\nexit 1\n");

    let output = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["doctor", "--json", "--base-dir", base_dir.to_str().unwrap()])
        .env("PATH", &path)
        .output()
        .unwrap();

    assert!(!output.status.success(), "ps failure passed doctor");
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        report["credential_health"]["anthropic"]["status"],
        "not_banked"
    );
    assert!(
        report["epistemics"]["notes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|note| note == "probe: ps enumeration failed")
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("probe: ps enumeration failed"));

    fs::remove_dir_all(root).unwrap();
}

#[cfg(target_os = "macos")]
#[test]
fn doctor_uses_absolute_lsof_and_fails_closed_when_it_cannot_collect() {
    let root = test_root("absolute-lsof");
    let path = root.join("path");
    let base_dir = root.join("org");
    let path_lsof_marker = root.join("path-lsof-ran");
    fs::create_dir_all(&path).unwrap();

    executable(&path.join("codex"), "#!/bin/sh\nexit 0\n");
    executable(&path.join("uname"), "#!/bin/sh\nprintf 'test-host\\n'\n");
    executable(
        &path.join("ps"),
        "#!/bin/sh\nif [ \"$1\" = \"-axEww\" ]; then\n  printf '2000000000 node codex-acp\\n'\nelse\n  printf '2000000000 1 2000000000 /usr/bin/node\\n'\nfi\n",
    );
    executable(
        &path.join("lsof"),
        "#!/bin/sh\nprintf used > \"$TIGHTBEAM_TEST_PATH_LSOF_MARKER\"\nexit 0\n",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["doctor", "--json", "--base-dir", base_dir.to_str().unwrap()])
        .env("PATH", &path)
        .env("TIGHTBEAM_TEST_PATH_LSOF_MARKER", &path_lsof_marker)
        .output()
        .unwrap();

    assert!(
        !output.status.success(),
        "an inconclusive lsof probe passed doctor"
    );
    assert!(
        !path_lsof_marker.exists(),
        "doctor invoked the PATH lsof instead of /usr/sbin/lsof"
    );
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(
        report["epistemics"]["notes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|note| note == "probe: /usr/sbin/lsof failed")
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("probe: /usr/sbin/lsof failed"));

    fs::remove_dir_all(root).unwrap();
}
