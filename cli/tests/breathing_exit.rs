use std::process::Command;

#[test]
fn malformed_breathing_is_a_textual_exit_one_without_a_fake_json_answer() {
    let output = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
        .args(["breathing", "turn", "tr_1", "--as-user", "owner"])
        .output()
        .expect("CLI starts");

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("usage: tightbeam breathing <session|assignment|work-item> <id>")
    );
}
