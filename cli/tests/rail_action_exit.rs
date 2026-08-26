use std::io::Write;
use std::process::{Command, Stdio};

fn classify(input: &str) -> i32 {
    let mut child = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["rail-action", "git-stash"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn tightbeam rail-action");

    child
        .stdin
        .take()
        .expect("classifier stdin")
        .write_all(input.as_bytes())
        .expect("write classifier envelope");

    child
        .wait()
        .expect("wait for classifier")
        .code()
        .expect("classifier exited normally")
}

#[test]
fn action_classifier_reserves_two_for_faults() {
    assert_eq!(classify("not-json"), 2);
    assert_eq!(classify(r#"{"tool_input":{}}"#), 2);
    assert_eq!(classify(r#"{"tool_input":{"command":"echo safe"}}"#), 1);
    assert_eq!(classify(r#"{"tool_input":{"command":"git stash"}}"#), 0);
}
