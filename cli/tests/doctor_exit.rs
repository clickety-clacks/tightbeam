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

    executable(&path.join("uname"), "#!/bin/sh\nprintf 'test-host\n'\n");
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

#[cfg(target_os = "macos")]
#[test]
fn doctor_uses_absolute_lsof_and_fails_closed_when_it_cannot_collect() {
    let unique = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("tightbeam-doctor-lsof-{unique}"));
    let path = root.join("path");
    let base_dir = root.join("org");
    let path_lsof_marker = root.join("path-lsof-ran");
    fs::create_dir_all(&path).unwrap();

    executable(&path.join("codex"), "#!/bin/sh\nexit 0\n");
    executable(&path.join("uname"), "#!/bin/sh\nprintf 'test-host\n'\n");
    executable(
        &path.join("ps"),
        "#!/bin/sh\nif [ \"$1\" = \"-axEww\" ]; then\n  printf '2000000000 node codex-acp\n'\nelse\n  printf '2000000000 1 2000000000 /usr/bin/node\n'\nfi\n",
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
