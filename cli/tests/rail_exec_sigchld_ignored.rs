//! The wrapper is spawned by whatever the substrate happens to be running under, and one
//! thing an ancestor can hand it silently is `SIGCHLD` set to `SIG_IGN` — a disposition
//! that survives `exec`. Under it the kernel reaps the wrapper's child the moment it dies:
//! no zombie, nothing to wait for, and the leader's pid released with no wait of the
//! wrapper's own involved. That is the pid-identity defect arriving through the
//! environment rather than through the code, and it cannot be reproduced from inside the
//! wrapper's own test module, because the disposition has to be set in the process that
//! `exec`s the binary.
//!
//! So this sets it where it actually comes from — in the forked child, before it becomes
//! the wrapper — and asserts the wrapper is not at its mercy.
//!
//! MEASURED rather than assumed, because POSIX leaves the SIGCHLD case of `exec`
//! explicitly unspecified and the two platforms do not agree. A C probe that ignores
//! SIGCHLD, `exec`s itself, then forks a child that exits and calls `waitpid`:
//!
//!   * linux (shrdlu, 6.x): ignore SURVIVED the exec, and `waitpid` found NO SUCH CHILD —
//!     the kernel had already reaped it. This test is red here without the fix, in the
//!     harshest possible form: every rail check, not merely a timing-out one, ends in the
//!     script-error band because the wrapper never has a child to wait for.
//!   * darwin 25.5: ignore SURVIVED the exec, but the child STILL became a zombie and
//!     `waitpid` reaped it normally — darwin does not honour the ignore as auto-reap.
//!
//! So the scenario this pins is real on linux and, today, not constructible on darwin,
//! where the test can only pass. It stays unconditional anyway: what differs is a kernel
//! behaviour neither platform documents as stable, the assertion is a plain band check,
//! and the day darwin adopts the other reading this is already in place.

use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::{fs, io};

const PASS: i32 = 0;

// A permissive profile is still a real profile on both platforms: the wrapper imposes it
// either way, so a hardcoded SBPL string here would refuse containment on linux and turn
// every assertion below into a CONTAINED_REFUSED.
#[cfg(target_os = "macos")]
const PERMISSIVE_PROFILE: &str = "(version 1)\n(allow default)";
#[cfg(target_os = "linux")]
const PERMISSIVE_PROFILE: &str = r#"{"tightbeam_containment":1,"write_roots":["/"]}"#;

#[test]
fn an_inherited_sigchld_ignore_cannot_release_the_leaders_pid() {
    let dir = std::env::temp_dir().join(format!(
        "tightbeam-rail-exec-sigchld-{}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("exits-clean");
    fs::write(&path, "#!/bin/sh\nIFS= read -r _line\nexit 0\n").unwrap();
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&path, permissions).unwrap();

    let mut command = Command::new(env!("CARGO_BIN_EXE_tightbeam"));
    command
        .args([
            "rail-exec",
            "--profile",
            PERMISSIVE_PROFILE,
            "--timeout-ms",
            "5000",
            "--",
            path.to_str().unwrap(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // In the fork, before the exec: this is the wrapper's own disposition being set by its
    // parent, which is the only place it can come from. Setting it in THIS process instead
    // would be a different and much worse test — cargo runs every test in one process, so
    // it would auto-reap the children of every test running alongside it.
    unsafe {
        command.pre_exec(|| {
            if libc::signal(libc::SIGCHLD, libc::SIG_IGN) == libc::SIG_ERR {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let child = command.spawn().unwrap();
    let output = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

    // Band 0 is the whole assertion, and it is a state rather than a stopwatch: the
    // wrapper can only report a child's successful exit if it still had a child to wait
    // for. Under the inherited ignore it has none — `waitid` answers ECHILD, the run ends
    // in the error band, and the group id it was holding stands for nothing.
    assert_eq!(
        output.status.code().unwrap(),
        PASS,
        "the wrapper let an inherited SIGCHLD disposition decide whether its child existed: {stderr}"
    );
    assert!(
        !stderr.contains("wait failed"),
        "the wrapper lost track of its own child: {stderr}"
    );

    fs::remove_dir_all(dir).unwrap();
}
