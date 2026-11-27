use super::*;

#[test]
fn launcher_probe() {
    let Ok(path) = std::env::var("TB_TEST_LAUNCH_PATH") else {
        return;
    };
    let result = session_exec(&[
        path,
        "failed-launch".into(),
        "--".into(),
        "/bin/true".into(),
    ]);
    match result {
        Ok(status) => std::process::exit(status),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

#[test]
fn each_prepublication_failure_is_terminal_and_attributed() {
    for step in ["fork", "session", "leader", "boot", "start_time", "write"] {
        let dir =
            std::env::temp_dir().join(format!("launch-failure-{}-{step}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("launch.identity");
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "harness_process::launch_tests::launcher_probe",
                "--nocapture",
            ])
            .env("TB_TEST_LAUNCH_PATH", &path)
            .env("TB_TEST_LAUNCH_FAILURE", step)
            .output()
            .unwrap();
        assert!(!output.status.success(), "{step}");
        assert_eq!(fs::read(&path).unwrap(), b"", "{step} published identity");
        assert_eq!(
            fs::read_to_string(dir.join("launch.identity.failed")).unwrap(),
            format!("tightbeam-launch-failed-v1\tfailed-launch\t{step}\t1\n")
        );
        fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn record_write_failure_exits_nonzero_and_names_the_failed_step() {
    let dir = std::env::temp_dir().join(format!("launch-record-failure-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join("launch.identity.failed.pending"), "occupied").unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "harness_process::launch_tests::launcher_probe",
            "--nocapture",
        ])
        .env("TB_TEST_LAUNCH_PATH", dir.join("launch.identity"))
        .env("TB_TEST_LAUNCH_FAILURE", "boot")
        .output()
        .unwrap();
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
        assert!(
            read_identity_record(&path, pid, &boot, "partial-launch").is_err(),
            "offset {offset}"
        );
    }
    fs::remove_file(path).unwrap();
}

#[test]
fn writer_lock_probe() {
    let Ok(root) = std::env::var("TB_TEST_WRITER_ROOT") else {
        return;
    };
    let root = Path::new(&root);
    let result = session_exec(&[
        root.join("lease.identity").to_string_lossy().into_owned(),
        "writer-lease".into(),
        "--writer-lock".into(),
        root.join("lease.lock").to_string_lossy().into_owned(),
        "--writer-receipt".into(),
        root.join("writer.done").to_string_lossy().into_owned(),
        "--".into(),
        "/bin/sh".into(),
        "-c".into(),
        "test -e \"/dev/fd/${TIGHTBEAM_ACCOUNT_WRITER_FD:?}\" || exit 4; echo $$ > \"$1/ready\"; while test ! -e \"$1/release\"; do sleep 0.05; done".into(),
        "lease-test".into(),
        root.to_string_lossy().into_owned(),
    ]);
    std::process::exit(result.unwrap_or(1));
}

#[test]
fn ordinary_launch_probe() {
    let Ok(identity) = std::env::var("TB_TEST_ORDINARY_LAUNCH_IDENTITY") else {
        return;
    };
    let result = session_exec(&[
        identity,
        "ordinary-fixture".into(),
        "--".into(),
        "/bin/sh".into(),
        "-c".into(),
        "test -z \"${TIGHTBEAM_ACCOUNT_WRITER_FD+x}\"".into(),
    ]);
    std::process::exit(result.unwrap_or(1));
}

#[test]
fn ordinary_launch_removes_inherited_writer_context() {
    let root = std::env::temp_dir().join(format!("ordinary-writer-context-{}", std::process::id()));
    fs::create_dir(&root).unwrap();
    let status = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "harness_process::launch_tests::ordinary_launch_probe",
        ])
        .env(
            "TB_TEST_ORDINARY_LAUNCH_IDENTITY",
            root.join("launch.identity"),
        )
        .env("TIGHTBEAM_ACCOUNT_WRITER_FD", "31337")
        .status()
        .unwrap();
    assert!(status.success());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn losing_the_launcher_keeps_the_owning_host_writer_excluded() {
    let dir = std::env::temp_dir().join(format!("account-writer-test-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    let root = dir.as_path();
    let lock = root.join("lease.lock");
    let mut launcher = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "harness_process::launch_tests::writer_lock_probe",
        ])
        .env("TB_TEST_WRITER_ROOT", root)
        .spawn()
        .unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !root.join("ready").exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let ready = root.join("ready").exists();
    let kill = launcher.kill();
    let settlement = launcher.wait();
    let excluded = acquire_writer_lock(&lock).is_err();
    fs::write(root.join("release"), "").unwrap();

    assert!(ready, "writer never signaled readiness");
    kill.unwrap();
    settlement.unwrap();
    assert!(excluded, "launcher loss released an active writer's lock");

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if acquire_writer_lock(&lock).is_ok() {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "writer lock did not release"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        fs::read_to_string(root.join("writer.done")).unwrap(),
        "tightbeam-account-writer-v1\twriter-lease\t0\n"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn revoked_account_writer_cannot_start_late() {
    let root =
        std::env::temp_dir().join(format!("account-writer-revocation-{}", std::process::id()));
    fs::create_dir(&root).unwrap();
    let lock = root.join("lease.lock");
    let receipt = root.join("writer.done");
    let args = vec![
        lock.to_string_lossy().into_owned(),
        receipt.to_string_lossy().into_owned(),
    ];

    let held = acquire_writer_lock(&lock).unwrap();
    assert!(revoke_writer(&args).is_err());
    assert!(!receipt.with_extension("revoked").exists());
    drop(held);
    revoke_writer(&args).unwrap();

    fs::write(root.join("release"), "").unwrap();
    let status = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "harness_process::launch_tests::writer_lock_probe",
        ])
        .env("TB_TEST_WRITER_ROOT", &root)
        .status()
        .unwrap();
    assert!(!status.success());
    assert!(!root.join("ready").exists());
    assert!(!receipt.exists());
    fs::remove_dir_all(root).unwrap();
}
