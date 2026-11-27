#![cfg(unix)]

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn setup_declines_and_dry_run_leave_the_plan_unapplied() {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let temporary =
        std::env::temp_dir().join(format!("tightbeam-setup-{}-{suffix}", std::process::id()));
    fs::create_dir(&temporary).unwrap();
    let base = temporary.join("org");
    let bin = temporary.join("bin");
    fs::create_dir(&bin).unwrap();
    let mutation = temporary.join("mutation");

    fn executable(file: &Path, script: &str) {
        fs::write(file, script).unwrap();
        fs::set_permissions(file, fs::Permissions::from_mode(0o755)).unwrap();
    }

    executable(
        &bin.join("systemctl"),
        "#!/bin/sh\ncase \"$2\" in\n  is-active|is-enabled) exit 1;;\n  show-environment) exit 0;;\nesac\nprintf mutation > \"$SETUP_TEST_MUTATION\"\nexit 1\n",
    );
    executable(
        &bin.join("launchctl"),
        "#!/bin/sh\nif [ \"$1\" = print ]; then\n  case \"$2\" in */com.tightbeam.*) exit 1;; esac\n  exit 0\nfi\nprintf mutation > \"$SETUP_TEST_MUTATION\"\nexit 1\n",
    );
    executable(&bin.join("codex"), "#!/bin/sh\nexit 0\n");
    let inherited = std::env::var_os("PATH").unwrap();
    let path = std::env::join_paths(std::iter::once(bin).chain(std::env::split_paths(&inherited)))
        .unwrap();

    for (arguments, answer, prompt) in [
        (vec!["--mode", "quick"], "no\n", true),
        (vec!["--mode", "quick"], "anything else\n", true),
        (vec!["--mode", "quick", "--dry-run"], "", false),
        (vec![], "quick\nno\n", true),
    ] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_tightbeam"))
            .arg("setup")
            .args(arguments)
            .env("HOME", &temporary)
            .env("PATH", &path)
            .env("SETUP_TEST_MUTATION", &mutation)
            .env("TIGHTBEAM_BASE_DIR", &base)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(answer.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(
            stdout
                .lines()
                .any(|line| line.starts_with("- ") && line.contains("lighter isolation"))
        );
        assert_eq!(stdout.lines().last() == Some("Install yes or no"), prompt);
        assert!(!base.exists());
        assert!(!mutation.exists());
    }
    fs::remove_dir_all(temporary).unwrap();
}
