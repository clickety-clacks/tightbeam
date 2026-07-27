//! The wrapper's stderr is the only evidence channel the substrate has for a child's
//! exit code, and it lives on the wrapper's side of the seam — the substrate parses
//! `tightbeam rail-exec child exit: <N>` and cannot second-guess it.
//!
//! When the script never received its input, the wrapper used to print that exact line
//! with a made-up `1` in it, so a check that judged nothing was recorded as a script
//! that failed. This asserts the real binary's real bytes: the parsed line appears only
//! when a child exit was actually observed (task #43).

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::{fs, thread};

const PARSED_PREFIX: &str = "tightbeam rail-exec child exit:";
const SCRIPT_ERROR: i32 = 10;

fn script(name: &str, body: &str) -> (std::path::PathBuf, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-rail-exec-stdin-{}-{name}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&path, permissions).unwrap();
    (dir, path)
}

fn rail_exec(script_path: &std::path::Path, input: Vec<u8>) -> (i32, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args([
            "rail-exec",
            "--profile",
            "(version 1)\n(allow default)",
            "--timeout-ms",
            "5000",
            "--",
            script_path.to_str().unwrap(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    // The wrapper reads one line and may stop consuming, so write from a thread rather
    // than deadlocking this one against a full pipe.
    let mut stdin = child.stdin.take().unwrap();
    let writer = thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });

    let output = child.wait_with_output().unwrap();
    let _ = writer.join();

    (
        output.status.code().unwrap(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

#[test]
fn undelivered_stdin_does_not_forge_a_child_exit_line() {
    // 512KB against a script that exits without reading: the pipe buffer fills, the
    // write fails, and the script judged nothing. Note the child exits ZERO here, so
    // the old `child exit: 1` was false about both the number and the fact.
    let (dir, path) = script("ignores-stdin", "exit 0");
    let (code, stderr) = rail_exec(&path, vec![b'x'; 512 * 1024]);

    assert_eq!(code, SCRIPT_ERROR);
    assert!(
        !stderr.contains(PARSED_PREFIX),
        "wrapper forged the line the substrate parses: {stderr}"
    );
    assert!(
        stderr.contains("script input undelivered"),
        "wrapper did not say what actually happened: {stderr}"
    );

    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn an_observed_child_exit_still_reports_its_code() {
    // The other direction: when the wrapper DID see the child's code, the parsed line is
    // still there and still carries it. Removing the forgery must not remove the truth.
    let (dir, path) = script("reads-then-fails", "IFS= read -r _line; exit 7");
    let (code, stderr) = rail_exec(&path, b"{}\n".to_vec());

    assert_eq!(code, SCRIPT_ERROR);
    assert!(
        stderr.contains(&format!("{PARSED_PREFIX} 7")),
        "wrapper dropped an observed child exit: {stderr}"
    );

    fs::remove_dir_all(dir).unwrap();
}
