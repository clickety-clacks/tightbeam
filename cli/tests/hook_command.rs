use std::io::Write;
use std::process::{Command, Output, Stdio};

fn invoke(input: &[u8], arguments: &[&str]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(arguments)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start CLI");

    child
        .stdin
        .take()
        .expect("piped stdin")
        .write_all(input)
        .expect("write hook input");

    child.wait_with_output().expect("collect CLI output")
}

#[test]
fn hook_command_decodes_valid_json_without_writing_a_projection() {
    let output = invoke(
        br#"{"tool_name":"Bash","description":"x; git stash","tool_input":{"command":"git status"}}"#,
        &["hook-command"],
    );

    assert_eq!(output.status.code(), Some(0));
    assert!(output.stdout.is_empty());
    assert!(output.stderr.is_empty());
}

#[test]
fn hook_command_fails_closed_when_input_is_not_json() {
    for input in [
        b"".as_slice(),
        b"not-json",
        b"{\"tool_input\":",
        b"{} trailing",
    ] {
        let output = invoke(input, &["hook-command"]);
        assert_eq!(output.status.code(), Some(2), "input: {input:?}");
        assert!(!output.stderr.is_empty(), "input: {input:?}");
    }
}

#[test]
fn hook_command_fails_closed_on_invalid_utf8() {
    let output = invoke(&[0xff], &["hook-command"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(!output.stderr.is_empty());
}

#[test]
fn hook_command_stays_out_of_public_help() {
    let output = invoke(b"", &["help"]);
    assert_eq!(output.status.code(), Some(0));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("hook-command"));
}
