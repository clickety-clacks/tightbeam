use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

struct Manifest {
    execution_id: String,
    command: Vec<String>,
    cwd: PathBuf,
    claim_path: PathBuf,
    launcher_path: PathBuf,
    started_path: PathBuf,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
    not_started_path: PathBuf,
    terminal_path: PathBuf,
}

pub fn run(args: &[String]) -> Result<i32, String> {
    if args.len() != 1 {
        return Err("usage: tightbeam command-exec <prepared-receipt-path>".into());
    }

    let manifest = read_manifest(Path::new(&args[0]))?;
    create_once(
        &manifest.claim_path,
        b"claimed\n",
        "execution already consumed",
    )?;

    let (read_ack, write_ack) = match pipe(false) {
        Ok(ends) => ends,
        Err(error) => {
            write_not_started(&manifest, &error)?;
            println!(
                "{}",
                json!({"executionId": manifest.execution_id, "state": "not_started"})
            );
            return Ok(10);
        }
    };
    match unsafe { libc::fork() } {
        -1 => {
            let error = format!(
                "command supervisor could not fork: {}",
                std::io::Error::last_os_error()
            );
            write_not_started(&manifest, &error)?;
            println!(
                "{}",
                json!({"executionId": manifest.execution_id, "state": "not_started"})
            );
            Ok(10)
        }
        0 => {
            drop(read_ack);
            let result = supervise(&manifest, write_ack);
            if result.is_err() {
                unsafe { libc::_exit(1) };
            }
            unsafe { libc::_exit(0) };
        }
        _child => {
            drop(write_ack);
            let mut ack = String::new();
            File::from(read_ack)
                .read_to_string(&mut ack)
                .map_err(|error| format!("command supervisor acknowledgement failed: {error}"))?;
            match ack.trim() {
                "started" => {
                    println!(
                        "{}",
                        json!({"executionId": manifest.execution_id, "state": "started"})
                    );
                    Ok(0)
                }
                "not_started" => {
                    println!(
                        "{}",
                        json!({"executionId": manifest.execution_id, "state": "not_started"})
                    );
                    Ok(10)
                }
                value => Err(format!(
                    "command supervisor closed without a durable start verdict: {value}"
                )),
            }
        }
    }
}

fn supervise(manifest: &Manifest, mut acknowledgement: OwnedFd) -> Result<(), String> {
    if unsafe { libc::setsid() } == -1 {
        let error = format!(
            "command supervisor could not detach: {}",
            std::io::Error::last_os_error()
        );
        return prelaunch_refusal(manifest, &mut acknowledgement, &error);
    }

    let pid = unsafe { libc::getpid() };
    let pgid = unsafe { libc::getpgrp() };
    if let Err(error) = write_json_once(
        &manifest.launcher_path,
        &json!({
            "executionId": manifest.execution_id,
            "osPid": pid,
            "processGroupId": pgid,
            "recordedAt": now_ms()
        }),
    ) {
        return prelaunch_refusal(manifest, &mut acknowledgement, &error);
    }

    let stdout = match output_file(&manifest.stdout_path) {
        Ok(file) => file,
        Err(error) => return prelaunch_refusal(manifest, &mut acknowledgement, &error),
    };
    let stderr = match output_file(&manifest.stderr_path) {
        Ok(file) => file,
        Err(error) => return prelaunch_refusal(manifest, &mut acknowledgement, &error),
    };
    let (exec_read, exec_write) = match pipe(true) {
        Ok(ends) => ends,
        Err(error) => return prelaunch_refusal(manifest, &mut acknowledgement, &error),
    };

    match unsafe { libc::fork() } {
        -1 => {
            let error = format!(
                "command process could not fork: {}",
                std::io::Error::last_os_error()
            );
            prelaunch_refusal(manifest, &mut acknowledgement, &error)
        }
        0 => {
            drop(exec_read);
            drop(acknowledgement);
            exec_child(manifest, stdout, stderr, exec_write)
        }
        child => {
            drop(exec_write);
            drop(stdout);
            drop(stderr);
            let mut exec_error = String::new();
            File::from(exec_read)
                .read_to_string(&mut exec_error)
                .map_err(|error| format!("exec status could not be read: {error}"))?;

            if !exec_error.is_empty() {
                write_not_started(manifest, exec_error.trim())?;
                acknowledge_best_effort(&mut acknowledgement, "not_started");
                wait_child(child)?;
                return Ok(());
            }

            write_json_once(
                &manifest.started_path,
                &json!({
                    "executionId": manifest.execution_id,
                    "osPid": child,
                    "startedAt": now_ms()
                }),
            )?;
            acknowledge_best_effort(&mut acknowledgement, "started");
            drop(acknowledgement);

            let status = wait_child(child)?;
            let (stdout_bytes, stdout_sha256) = file_evidence(&manifest.stdout_path)?;
            let (stderr_bytes, stderr_sha256) = file_evidence(&manifest.stderr_path)?;
            let (exit_code, signal) = decode_status(status);

            write_json_once(
                &manifest.terminal_path,
                &json!({
                    "executionId": manifest.execution_id,
                    "finishedAt": now_ms(),
                    "exitCode": exit_code,
                    "signal": signal,
                    "stdoutBytes": stdout_bytes,
                    "stdoutSha256": stdout_sha256,
                    "stderrBytes": stderr_bytes,
                    "stderrSha256": stderr_sha256
                }),
            )
        }
    }
}

fn prelaunch_refusal(
    manifest: &Manifest,
    acknowledgement: &mut OwnedFd,
    error: &str,
) -> Result<(), String> {
    write_not_started(manifest, error)?;
    acknowledge_best_effort(acknowledgement, "not_started");
    Ok(())
}

fn exec_child(manifest: &Manifest, stdout: File, stderr: File, exec_write: OwnedFd) -> ! {
    let failure = (|| -> Result<(), String> {
        std::env::set_current_dir(&manifest.cwd)
            .map_err(|error| format!("cwd could not be entered: {error}"))?;

        let stdin = File::open("/dev/null")
            .map_err(|error| format!("detached stdin could not be opened: {error}"))?;

        if unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) } == libc::SIG_ERR {
            return Err(format!(
                "SIGPIPE disposition could not be restored: {}",
                std::io::Error::last_os_error()
            ));
        }

        if unsafe { libc::dup2(stdin.as_raw_fd(), libc::STDIN_FILENO) } == -1
            || unsafe { libc::dup2(stdout.as_raw_fd(), libc::STDOUT_FILENO) } == -1
            || unsafe { libc::dup2(stderr.as_raw_fd(), libc::STDERR_FILENO) } == -1
        {
            return Err(format!(
                "detached command streams could not be attached: {}",
                std::io::Error::last_os_error()
            ));
        }

        let command = manifest
            .command
            .iter()
            .map(|part| {
                CString::new(part.as_bytes()).map_err(|_| "command contains NUL".to_string())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut argv = command.iter().map(|part| part.as_ptr()).collect::<Vec<_>>();
        argv.push(std::ptr::null());

        unsafe { libc::execvp(command[0].as_ptr(), argv.as_ptr()) };
        Err(format!("exec failed: {}", std::io::Error::last_os_error()))
    })()
    .unwrap_err();

    let _ = File::from(exec_write).write_all(failure.as_bytes());
    unsafe { libc::_exit(127) }
}

fn read_manifest(path: &Path) -> Result<Manifest, String> {
    let bytes = fs::read_to_string(path)
        .map_err(|error| format!("prepared execution receipt could not be read: {error}"))?;
    let value: Value = serde_json::from_str(&bytes)
        .map_err(|error| format!("prepared execution receipt is invalid JSON: {error}"))?;
    let field = |name: &str| {
        value[name]
            .as_str()
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| format!("prepared execution receipt lacks {name}"))
    };
    let command = value["command"]
        .as_array()
        .ok_or_else(|| "prepared execution receipt lacks command".to_string())?
        .iter()
        .map(|part| {
            part.as_str()
                .map(str::to_owned)
                .ok_or_else(|| "prepared command contains a non-string value".to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    if command.first().is_none_or(|part| part.is_empty()) {
        return Err("prepared command is empty".into());
    }

    let command_json = field("commandJson")?;
    let command_sha256 = field("commandSha256")?;
    if hex_sha256(command_json.as_bytes()) != command_sha256 {
        return Err("prepared command hash does not match its exact bytes".into());
    }
    let decoded: Vec<String> = serde_json::from_str(&command_json)
        .map_err(|error| format!("exact command bytes are invalid: {error}"))?;
    if decoded != command {
        return Err("prepared command differs from its exact command bytes".into());
    }

    let pinned_host = field("host")?;
    let actual_host = current_host()?;
    if pinned_host != actual_host {
        return Err(format!(
            "prepared execution is pinned to host {pinned_host}, not {actual_host}"
        ));
    }

    Ok(Manifest {
        execution_id: field("executionId")?,
        command,
        cwd: PathBuf::from(field("cwd")?),
        claim_path: PathBuf::from(field("claimPath")?),
        launcher_path: PathBuf::from(field("launcherIdentityPath")?),
        started_path: PathBuf::from(field("startedPath")?),
        stdout_path: PathBuf::from(field("stdoutPath")?),
        stderr_path: PathBuf::from(field("stderrPath")?),
        not_started_path: PathBuf::from(field("notStartedPath")?),
        terminal_path: PathBuf::from(field("terminalPath")?),
    })
}

fn pipe(close_on_exec: bool) -> Result<(OwnedFd, OwnedFd), String> {
    let mut ends = [0; 2];
    if unsafe { libc::pipe(ends.as_mut_ptr()) } == -1 {
        return Err(format!(
            "pipe could not be created: {}",
            std::io::Error::last_os_error()
        ));
    }
    let read = unsafe { OwnedFd::from_raw_fd(ends[0]) };
    let write = unsafe { OwnedFd::from_raw_fd(ends[1]) };
    if close_on_exec {
        set_fd_cloexec(read.as_raw_fd())?;
        set_fd_cloexec(write.as_raw_fd())?;
    }
    Ok((read, write))
}

fn set_fd_cloexec(fd: libc::c_int) -> Result<(), String> {
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
        Err(format!(
            "close-on-exec could not be set: {}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}

fn output_file(path: &Path) -> Result<File, String> {
    ensure_parent(path)?;
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| {
            format!(
                "execution output could not be opened at {}: {error}",
                path.display()
            )
        })
}

fn create_once(path: &Path, bytes: &[u8], already_exists: &str) -> Result<(), String> {
    ensure_parent(path)?;
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                already_exists.to_string()
            } else {
                format!("receipt could not be opened at {}: {error}", path.display())
            }
        })?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| {
            format!(
                "receipt could not be written at {}: {error}",
                path.display()
            )
        })?;
    sync_parent(path)
}

fn write_json_once(path: &Path, value: &Value) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    create_once(path, &bytes, "execution receipt already exists")
}

fn write_not_started(manifest: &Manifest, error: &str) -> Result<(), String> {
    write_json_once(
        &manifest.not_started_path,
        &json!({
            "executionId": manifest.execution_id,
            "recordedAt": now_ms(),
            "error": error
        }),
    )
}

fn acknowledge(fd: &mut OwnedFd, value: &str) -> Result<(), String> {
    File::from(fd.try_clone().map_err(|error| error.to_string())?)
        .write_all(format!("{value}\n").as_bytes())
        .map_err(|error| format!("command verdict could not be acknowledged: {error}"))
}

fn acknowledge_best_effort(fd: &mut OwnedFd, value: &str) {
    if let Err(error) = acknowledge(fd, value) {
        let _ = writeln!(std::io::stderr(), "{error}");
    }
}

fn current_host() -> Result<String, String> {
    if let Ok(host) = std::env::var("TIGHTBEAM_LOCAL_HOST_NAME")
        && !host.is_empty()
    {
        return Ok(host);
    }

    let mut bytes = [0_u8; 256];
    if unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len()) } == -1 {
        return Err(format!(
            "local hostname could not be read: {}",
            std::io::Error::last_os_error()
        ));
    }
    let length = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    String::from_utf8(bytes[..length].to_vec())
        .map_err(|_| "local hostname is not valid UTF-8".to_string())
}

fn wait_child(child: libc::pid_t) -> Result<libc::c_int, String> {
    let mut status = 0;
    loop {
        let waited = unsafe { libc::waitpid(child, &mut status, 0) };
        if waited == child {
            return Ok(status);
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(format!("command process could not be waited: {error}"));
        }
    }
}

fn decode_status(status: libc::c_int) -> (Option<i32>, Option<i32>) {
    if libc::WIFEXITED(status) {
        (Some(libc::WEXITSTATUS(status)), None)
    } else if libc::WIFSIGNALED(status) {
        (None, Some(libc::WTERMSIG(status)))
    } else {
        (None, None)
    }
}

fn file_evidence(path: &Path) -> Result<(u64, String), String> {
    let mut file = File::open(path).map_err(|error| {
        format!(
            "execution output could not be opened at {}: {error}",
            path.display()
        )
    })?;
    file.sync_all().map_err(|error| {
        format!(
            "execution output could not be synced at {}: {error}",
            path.display()
        )
    })?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|error| {
        format!(
            "execution output could not be read at {}: {error}",
            path.display()
        )
    })?;
    Ok((bytes.len() as u64, hex_sha256(&bytes)))
}

fn hex_sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn ensure_parent(path: &Path) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "receipt path has no parent".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("receipt directory could not be created: {error}"))
}

fn sync_parent(path: &Path) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "receipt path has no parent".to_string())?;
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("receipt directory could not be synced: {error}"))
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

#[cfg(test)]
mod tests {
    use super::{acknowledge_best_effort, decode_status, hex_sha256, pipe};

    #[test]
    fn hashes_exact_bytes() {
        assert_eq!(
            hex_sha256(b"out\n"),
            "54034ac5c6e9ea95734ec2b729fd6d62abf64af34a9f9ce5d466cb788191a73d"
        );
    }

    #[test]
    fn decodes_exit_and_signal_statuses() {
        assert_eq!(decode_status(7 << 8), (Some(7), None));
        assert_eq!(decode_status(libc::SIGTERM), (None, Some(libc::SIGTERM)));
    }

    #[test]
    fn a_missing_acknowledgement_reader_cannot_abort_supervision() {
        let (reader, mut writer) = pipe(false).unwrap();
        drop(reader);
        acknowledge_best_effort(&mut writer, "started");
    }
}
