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

    fs::remove_dir_all(root).unwrap();
}
