use std::fs;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn probe_is_silent_and_read_only_for_disabled_pending_and_completed_installs() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let base = std::env::temp_dir().join(format!(
        "tightbeam-first-run-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&base).unwrap();
    let probe = |flag: &str, pending| {
        let output = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
            .args(["onboard", "--first-run", "--check"])
            .env("TIGHTBEAM_BASE_DIR", &base)
            .env("TIGHTBEAM_FIRST_RUN_ONBOARDING", flag)
            .output()
            .unwrap();
        assert_eq!(output.status.success(), pending);
        assert!(output.stdout.is_empty() && output.stderr.is_empty());
    };
    probe("false", false);
    probe("true", true);
    assert!(fs::read_dir(&base).unwrap().next().is_none());
    let database = rusqlite::Connection::open(base.join("state.db")).unwrap();
    database
        .execute_batch(
            "CREATE TABLE org_settings (key TEXT PRIMARY KEY, value TEXT);
         CREATE TABLE sessions (sessionKey TEXT, ownerUserId TEXT, state TEXT);",
        )
        .unwrap();
    probe("true", false);
    database
        .execute(
            "INSERT INTO org_settings VALUES ('first-run-tour', 'pending')",
            [],
        )
        .unwrap();
    probe("true", true);
    fs::write(base.join("first-run-onboarding.done"), b"").unwrap();
    probe("true", false);
    fs::remove_dir_all(base).unwrap();
}
