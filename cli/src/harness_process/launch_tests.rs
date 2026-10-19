use super::*;

#[test]
fn launcher_probe() {
    let Ok(path) = std::env::var("TB_TEST_LAUNCH_PATH") else { return; };
    let result = session_exec(&[path, "failed-launch".into(), "--".into(), "/bin/true".into()]);
    match result {
        Ok(status) => std::process::exit(status),
        Err(error) => { eprintln!("{error}"); std::process::exit(1); }
    }
}

#[test]
fn each_prepublication_failure_is_terminal_and_attributed() {
    for step in ["fork", "session", "leader", "boot", "start_time", "write"] {
        let dir = std::env::temp_dir().join(format!("launch-failure-{}-{step}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("launch.identity");
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "harness_process::launch_tests::launcher_probe", "--nocapture"])
            .env("TB_TEST_LAUNCH_PATH", &path).env("TB_TEST_LAUNCH_FAILURE", step)
            .output().unwrap();
        assert!(!output.status.success(), "{step}");
        assert_eq!(fs::read(&path).unwrap(), b"", "{step} published identity");
        assert_eq!(fs::read_to_string(dir.join("launch.identity.failed")).unwrap(),
            format!("tightbeam-launch-failed-v1\tfailed-launch\t{step}\t1\n"));
        fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn record_write_failure_exits_nonzero_and_names_the_failed_step() {
    let dir = std::env::temp_dir().join(format!("launch-record-failure-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join("launch.identity.failed.pending"), "occupied").unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "harness_process::launch_tests::launcher_probe", "--nocapture"])
        .env("TB_TEST_LAUNCH_PATH", dir.join("launch.identity"))
        .env("TB_TEST_LAUNCH_FAILURE", "boot").output().unwrap();
    assert!(!output.status.success());
    assert!(!dir.join("launch.identity.failed").exists());
    assert!(String::from_utf8_lossy(&output.stderr).contains("boot, exit 1"));
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn truncated_identity_is_never_authority() {
    let path = std::env::temp_dir().join(format!("launch-partial-{}.identity", std::process::id()));
    let pid = unsafe { libc::getpid() };
    let boot = boot_identity().unwrap();
    let body = format!("{pid}\t{pid}\t1\t0\t{boot}\tpartial-launch\n");
    for offset in 0..body.len() {
        fs::write(&path, &body.as_bytes()[..offset]).unwrap();
        assert!(read_identity_record(&path, pid, &boot, "partial-launch").is_err(), "offset {offset}");
    }
    fs::remove_file(path).unwrap();
}
