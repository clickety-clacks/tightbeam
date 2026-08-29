use sha2::{Digest, Sha256};
use std::ffi::CStr;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const ACCOUNT: &str = "tightbeam-cursor";
pub const LAUNCHER: &str = "/usr/local/libexec/tightbeam-cursor-launcher";
const CURSOR_VERSION: &str = "2026.08.11-e8db854";

pub fn running_as_launcher() -> bool {
    let Ok(actual) = std::env::current_exe().and_then(fs::canonicalize) else {
        return false;
    };
    fs::canonicalize(LAUNCHER).is_ok_and(|launcher| actual == launcher)
}

pub fn launcher_command_allowed(args: &[String]) -> bool {
    args.first().is_some_and(|arg| arg == "cursor-exec")
}

pub fn require_onboard_prerequisite(machine: &str) -> Result<(), String> {
    let base = crate::base_dir::resolve();
    let operator_uid = unsafe { libc::geteuid() }.to_string();
    #[allow(deprecated)]
    let operator_home = std::env::home_dir().unwrap_or_default();
    let executable = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("tightbeam"));

    let result = (|| {
        let account = account_named(ACCOUNT)?;
        let execution_base = account.home.join(".tightbeam");
        verify_dedicated_cursor_install(&account)?;
        verify_launcher_install(Path::new(LAUNCHER))?;
        verify_account_policy()?;
        let output = Command::new("/usr/bin/sudo")
            .args([
                "-n",
                "-H",
                "-u",
                ACCOUNT,
                "--",
                LAUNCHER,
                "cursor-exec",
                "verify",
            ])
            .arg(&execution_base)
            .arg(&base)
            .arg(&operator_uid)
            .arg(&operator_home)
            .arg("--")
            .output()
            .map_err(|error| format!("could not run the Cursor execution launcher: {error}"))?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
        }
        Ok(())
    })();

    result.map_err(|reason| {
        format!(
            "{reason}\n\n{}",
            admin_instructions(&base, &operator_home, &executable, machine)
        )
    })
}

fn verify_dedicated_cursor_install(account: &Account) -> Result<(), String> {
    for path in [
        account
            .home
            .join(".local/share/cursor-agent/versions")
            .join(CURSOR_VERSION)
            .join("cursor-agent"),
        account
            .home
            .join(".local/share/cursor-agent/versions")
            .join(CURSOR_VERSION)
            .join("index.js"),
    ] {
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            format!(
                "dedicated Cursor bundle is not installed at {}: {error}",
                path.display()
            )
        })?;
        if metadata.file_type().is_symlink()
            || !metadata.is_file()
            || metadata.uid() != 0
            || metadata.permissions().mode() & 0o022 != 0
        {
            return Err(format!(
                "dedicated Cursor bundle file {} must be owned by root, must not be a symlink, and must not be group/world writable",
                path.display()
            ));
        }
    }
    Ok(())
}

fn verify_launcher_install(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        format!("Cursor execution launcher is not installed at {LAUNCHER}: {error}")
    })?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != 0
        || metadata.permissions().mode() & 0o022 != 0
    {
        return Err(format!(
            "Cursor execution launcher at {LAUNCHER} must be a root-owned, non-symlink file that is not group/world writable"
        ));
    }
    Ok(())
}

fn verify_account_policy() -> Result<(), String> {
    let output = Command::new("/usr/bin/id")
        .args(["-Gn", ACCOUNT])
        .output()
        .map_err(|error| format!("could not inspect Cursor execution account: {error}"))?;
    if !output.status.success() {
        return Err(format!("Cursor execution account {ACCOUNT} does not exist"));
    }
    let groups = String::from_utf8_lossy(&output.stdout);
    if groups
        .split_whitespace()
        .any(|group| matches!(group, "admin" | "sudo" | "wheel"))
    {
        return Err(format!(
            "Cursor execution account {ACCOUNT} is an administrator"
        ));
    }
    Ok(())
}

fn admin_instructions(
    base: &Path,
    operator_home: &Path,
    executable: &Path,
    machine: &str,
) -> String {
    if cfg!(target_os = "macos") {
        format!(
            "An administrator must provision the dedicated Cursor identity. Tightbeam never runs these commands itself:\n\n\
             sudo dscl . -create /Users/{ACCOUNT}\n\
             sudo dscl . -create /Users/{ACCOUNT} UserShell /usr/bin/false\n\
             sudo dscl . -create /Users/{ACCOUNT} RealName 'Tightbeam Cursor'\n\
             sudo dscl . -create /Users/{ACCOUNT} UniqueID 503\n\
             sudo dscl . -create /Users/{ACCOUNT} PrimaryGroupID 20\n\
             sudo dscl . -create /Users/{ACCOUNT} NFSHomeDirectory /Users/{ACCOUNT}\n\
             sudo dscl . -create /Users/{ACCOUNT} IsHidden 1\n\
             sudo createhomedir -c -u {ACCOUNT}\n\
             sudo dseditgroup -o create tightbeam-workspace\n\
             sudo dseditgroup -o edit -a $USER -t user tightbeam-workspace\n\
             sudo dseditgroup -o edit -a {ACCOUNT} -t user tightbeam-workspace\n\
             sudo install -d -o {ACCOUNT} -g tightbeam-workspace -m 0750 /Users/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             sudo /usr/bin/ditto {operator_home}/.local/share/cursor-agent/versions/{CURSOR_VERSION} /Users/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             sudo chown -R {ACCOUNT}:tightbeam-workspace /Users/{ACCOUNT}/.local\n\
             sudo chmod -R go-w /Users/{ACCOUNT}/.local\n\
             sudo -u {ACCOUNT} -H /usr/bin/ssh-keygen -q -t ed25519 -N '' -C tightbeam-cursor -f /Users/{ACCOUNT}/.ssh/id_ed25519\n\
             sudo mkdir -p /Users/{ACCOUNT}/.tightbeam /Users/{ACCOUNT}/.cursor {base}/work\n\
             sudo chown -R {ACCOUNT}:tightbeam-workspace /Users/{ACCOUNT}\n\
             sudo chown -R root:tightbeam-workspace /Users/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             sudo chmod -R go-w /Users/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             sudo chmod 0710 /Users/{ACCOUNT}\n\
             sudo chmod 2770 /Users/{ACCOUNT}/.tightbeam /Users/{ACCOUNT}/.cursor\n\
             sudo chgrp tightbeam-workspace {base}/work\n\
             sudo chmod -R g+rwX {base}/work\n\
             sudo chmod 2770 {base}/work\n\
             sudo mkdir -p {base}/homes/{machine}/cursor/.tightbeam/harness-processes\n\
             sudo chown -R $USER:tightbeam-workspace {base}/homes/{machine}/cursor\n\
             sudo chmod 2770 {base}/homes/{machine}/cursor/.tightbeam {base}/homes/{machine}/cursor/.tightbeam/harness-processes\n\
             sudo chgrp tightbeam-workspace {base}/auth\n\
             sudo chmod 0710 {base}/auth\n\
             sudo chgrp -R tightbeam-workspace {base}/auth/github\n\
             sudo chmod -R g+rX {base}/auth/github\n\
             test ! -e {operator_home}/.cursor || sudo chmod 0700 {operator_home}/.cursor\n\
             test ! -e {operator_home}/.agents || sudo chmod 0700 {operator_home}/.agents\n\
             test ! -e {operator_home}/.pi || sudo chmod 0700 {operator_home}/.pi\n\
             sudo mkdir -p /usr/local/libexec\n\
             sudo install -o root -g wheel -m 0755 {executable} {LAUNCHER}\n\
             printf 'Defaults!{LAUNCHER} env_keep += \"CURSOR_API_KEY AGENT_CLI_CREDENTIAL_STORE CURSOR_CONFIG_DIR TIGHTBEAM_HOME TIGHTBEAM_MACHINE TIGHTBEAM_LINEAGE GH_CONFIG_DIR\"\\n%tightbeam-workspace ALL=({ACCOUNT}) NOPASSWD: {LAUNCHER} *\\n' | sudo tee /etc/sudoers.d/tightbeam-cursor >/dev/null\n\
             sudo chmod 0440 /etc/sudoers.d/tightbeam-cursor\n\
             sudo visudo -cf /etc/sudoers.d/tightbeam-cursor",
            base = base.display(),
            operator_home = operator_home.display(),
            executable = executable.display(),
            machine = machine
        )
    } else {
        format!(
            "An administrator must provision the dedicated Cursor identity. Tightbeam never runs these commands itself:\n\n\
             sudo useradd --create-home --shell /usr/sbin/nologin {ACCOUNT}\n\
             sudo groupadd --force tightbeam-workspace\n\
             sudo usermod --append --groups tightbeam-workspace $USER\n\
             sudo usermod --append --groups tightbeam-workspace {ACCOUNT}\n\
             sudo install -d -o {ACCOUNT} -g tightbeam-workspace -m 0750 /home/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             sudo cp -a {operator_home}/.local/share/cursor-agent/versions/{CURSOR_VERSION}/. /home/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}/\n\
             sudo chown -R {ACCOUNT}:tightbeam-workspace /home/{ACCOUNT}/.local\n\
             sudo chmod -R go-w /home/{ACCOUNT}/.local\n\
             sudo -u {ACCOUNT} -H /usr/bin/ssh-keygen -q -t ed25519 -N '' -C tightbeam-cursor -f /home/{ACCOUNT}/.ssh/id_ed25519\n\
             sudo mkdir -p /home/{ACCOUNT}/.tightbeam /home/{ACCOUNT}/.cursor {base}/work\n\
             sudo chown -R {ACCOUNT}:tightbeam-workspace /home/{ACCOUNT}\n\
             sudo chown -R root:tightbeam-workspace /home/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             sudo chmod -R go-w /home/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             sudo chmod 0710 /home/{ACCOUNT}\n\
             sudo chmod 2770 /home/{ACCOUNT}/.tightbeam /home/{ACCOUNT}/.cursor\n\
             sudo chgrp tightbeam-workspace {base}/work\n\
             sudo chmod -R g+rwX {base}/work\n\
             sudo chmod 2770 {base}/work\n\
             sudo mkdir -p {base}/homes/{machine}/cursor/.tightbeam/harness-processes\n\
             sudo chown -R $USER:tightbeam-workspace {base}/homes/{machine}/cursor\n\
             sudo chmod 2770 {base}/homes/{machine}/cursor/.tightbeam {base}/homes/{machine}/cursor/.tightbeam/harness-processes\n\
             sudo chgrp tightbeam-workspace {base}/auth\n\
             sudo chmod 0710 {base}/auth\n\
             sudo chgrp -R tightbeam-workspace {base}/auth/github\n\
             sudo chmod -R g+rX {base}/auth/github\n\
             test ! -e {operator_home}/.cursor || sudo chmod 0700 {operator_home}/.cursor\n\
             test ! -e {operator_home}/.agents || sudo chmod 0700 {operator_home}/.agents\n\
             test ! -e {operator_home}/.pi || sudo chmod 0700 {operator_home}/.pi\n\
             sudo mkdir -p /usr/local/libexec\n\
             sudo install -o root -g root -m 0755 {executable} {LAUNCHER}\n\
             printf 'Defaults!{LAUNCHER} env_keep += \"CURSOR_API_KEY AGENT_CLI_CREDENTIAL_STORE CURSOR_CONFIG_DIR TIGHTBEAM_HOME TIGHTBEAM_MACHINE TIGHTBEAM_LINEAGE GH_CONFIG_DIR\"\\n%tightbeam-workspace ALL=({ACCOUNT}) NOPASSWD: {LAUNCHER} *\\n' | sudo tee /etc/sudoers.d/tightbeam-cursor >/dev/null\n\
             sudo chmod 0440 /etc/sudoers.d/tightbeam-cursor\n\
             sudo visudo -cf /etc/sudoers.d/tightbeam-cursor",
            base = base.display(),
            operator_home = operator_home.display(),
            executable = executable.display(),
            machine = machine
        )
    }
}

pub fn run(args: &[String]) -> Result<i32, String> {
    let (mode, rest) = args.split_first().ok_or_else(|| usage().to_owned())?;

    match mode.as_str() {
        "verify" => {
            verify_args(rest)?;
            println!("cursor execution identity verified");
            Ok(0)
        }
        "launch" => {
            let command = verify_launch_args(rest)?;
            verify_launch_command(Path::new(&rest[0]), Path::new(&rest[1]), command)?;
            crate::harness_process::cursor_session_exec(command)
        }
        "group" => {
            if rest.len() != 8 {
                return Err(usage().to_owned());
            }
            verify_identity(Path::new(&rest[0]), Path::new(&rest[1]), &rest[2], &rest[3])?;
            crate::harness_process::group(&rest[4..])
        }
        _ => Err(usage().to_owned()),
    }
}

fn verify_launch_command(base: &Path, _org_base: &Path, command: &[String]) -> Result<(), String> {
    if command.len() != 5 || command[2] != "--" || command[4] != "acp" {
        return Err(usage().to_owned());
    }
    let identity = Path::new(&command[0]);
    let identity_parent = identity.parent().ok_or_else(|| usage().to_owned())?;
    let org_base = fs::canonicalize(_org_base).map_err(|error| {
        format!("cursor execution identity refused: operator managed base: {error}")
    })?;
    let identity_parent = fs::canonicalize(identity_parent).map_err(|error| {
        format!("cursor execution identity refused: identity directory: {error}")
    })?;
    if !identity_parent.starts_with(org_base.join("homes"))
        || !identity_parent.ends_with(Path::new("cursor/.tightbeam/harness-processes"))
    {
        return Err(
            "cursor execution identity refused: identity path is outside the managed base".into(),
        );
    }
    let executable = fs::canonicalize(&command[3]).map_err(|error| {
        format!("cursor execution identity refused: adapter executable: {error}")
    })?;
    let expected = fs::canonicalize(
        base.parent()
            .ok_or_else(|| {
                "cursor execution identity refused: managed base has no home".to_owned()
            })?
            .join(".local/share/cursor-agent/versions")
            .join(CURSOR_VERSION)
            .join("cursor-agent"),
    )
    .map_err(|error| {
        format!("cursor execution identity refused: managed Cursor adapter: {error}")
    })?;
    if executable != expected {
        return Err(
            "cursor execution identity refused: command is not the managed Cursor adapter".into(),
        );
    }
    Ok(())
}

fn verify_launch_args(args: &[String]) -> Result<&[String], String> {
    if args.len() < 6 || args[5] != "--" {
        return Err(usage().to_owned());
    }
    verify_identity(Path::new(&args[0]), Path::new(&args[1]), &args[2], &args[3])?;
    let expected = &args[4];
    if expected.len() != 64 || !expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("cursor execution identity refused: managed hook hash is invalid".into());
    }
    let hooks = account_named(ACCOUNT)?.home.join(".cursor/hooks.json");
    let bytes = fs::read(&hooks).map_err(|error| {
        format!("cursor execution identity refused: managed hooks are unreadable: {error}")
    })?;
    if format!("{:x}", Sha256::digest(&bytes)) != expected.to_ascii_lowercase() {
        return Err("cursor execution identity refused: managed hook hash differs from the compiled projection".into());
    }
    Ok(&args[6..])
}

fn verify_args(args: &[String]) -> Result<&[String], String> {
    if args.len() < 5 || args[4] != "--" {
        return Err(usage().to_owned());
    }
    verify_identity(Path::new(&args[0]), Path::new(&args[1]), &args[2], &args[3])?;
    Ok(&args[5..])
}

fn verify_identity(
    base: &Path,
    org_base: &Path,
    operator_uid: &str,
    operator_home: &str,
) -> Result<(), String> {
    let operator_uid = operator_uid
        .parse::<u32>()
        .map_err(|_| "operator uid is invalid".to_owned())?;
    let sudo_uid = std::env::var("SUDO_UID")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| {
            "cursor execution identity refused: sudo did not attest the operator uid".to_owned()
        })?;
    if sudo_uid != operator_uid {
        return Err(
            "cursor execution identity refused: requested operator uid differs from sudo's actual caller"
                .into(),
        );
    }
    let operator = account_for_uid(sudo_uid)?;
    if operator.home != Path::new(operator_home) {
        return Err(
            "cursor execution identity refused: requested operator home differs from the caller's real account home"
                .into(),
        );
    }
    let org_base = canonical_directory(org_base, "operator managed base")?;
    let org_metadata = fs::metadata(&org_base).map_err(|error| {
        format!("cursor execution identity refused: operator managed base: {error}")
    })?;
    if org_metadata.uid() != sudo_uid {
        return Err(
            "cursor execution identity refused: operator managed base is not owned by the sudo caller"
                .into(),
        );
    }
    let actual_uid = unsafe { libc::geteuid() };
    let account = account_for_uid(actual_uid)?;
    verify_dedicated_cursor_install(&account)?;

    if actual_uid == 0 || actual_uid == operator_uid {
        return Err(format!(
            "cursor execution identity refused: actual uid {actual_uid} is not a dedicated non-root uid"
        ));
    }
    if account.name != ACCOUNT {
        return Err(format!(
            "cursor execution identity refused: actual account is {}, expected {ACCOUNT}",
            account.name
        ));
    }
    reject_admin_groups()?;
    if std::env::var_os("HOME").as_deref() != Some(account.home.as_os_str()) {
        return Err(format!(
            "cursor execution identity refused: HOME does not equal the real account home {}",
            account.home.display()
        ));
    }
    if account.home == Path::new(operator_home) {
        return Err("cursor execution identity refused: account home equals operator home".into());
    }
    if base != account.home.join(".tightbeam") {
        return Err("cursor execution identity refused: managed base is not under the execution account's real home".into());
    }

    let base = canonical_directory(base, "managed base")?;
    let metadata = fs::metadata(&base)
        .map_err(|error| format!("cursor execution identity refused: managed base: {error}"))?;
    if metadata.uid() != actual_uid {
        return Err("cursor execution identity refused: managed base is not owned by the execution identity".into());
    }
    fs::read_dir(&base).map_err(|error| {
        format!("cursor execution identity refused: managed base is inaccessible: {error}")
    })?;
    verify_workspace(&org_base.join("work"))?;

    for relative in [
        ".cursor/hooks.json",
        ".agents/skills",
        ".pi/agent/extensions",
    ] {
        let personal = Path::new(operator_home).join(relative);
        if fs::metadata(&personal).is_ok() {
            return Err(format!(
                "cursor execution identity refused: operator-personal path is accessible: {}",
                personal.display()
            ));
        }
    }
    Ok(())
}

fn reject_admin_groups() -> Result<(), String> {
    let output = Command::new("/usr/bin/id")
        .arg("-Gn")
        .output()
        .map_err(|error| {
            format!("cursor execution identity refused: groups unavailable: {error}")
        })?;
    if !output.status.success() {
        return Err("cursor execution identity refused: groups unavailable".into());
    }
    let groups = String::from_utf8_lossy(&output.stdout);
    if groups
        .split_whitespace()
        .any(|group| matches!(group, "admin" | "sudo" | "wheel"))
    {
        return Err(
            "cursor execution identity refused: execution account is an administrator".into(),
        );
    }
    Ok(())
}

fn verify_workspace(workspace: &Path) -> Result<(), String> {
    let workspace = canonical_directory(workspace, "managed workspace")?;
    let metadata = fs::metadata(&workspace).map_err(|error| {
        format!("cursor execution identity refused: managed workspace: {error}")
    })?;
    if metadata.mode() & 0o2000 == 0 {
        return Err("cursor execution identity refused: managed workspace is not setgid".into());
    }
    if metadata.uid() != unsafe { libc::geteuid() }
        && !supplementary_groups().contains(&metadata.gid())
    {
        return Err("cursor execution identity refused: managed workspace is not owned by the execution identity or one of its groups".into());
    }
    fs::read_dir(workspace).map_err(|error| {
        format!("cursor execution identity refused: managed workspace is inaccessible: {error}")
    })?;
    Ok(())
}

fn supplementary_groups() -> Vec<u32> {
    let count = unsafe { libc::getgroups(0, std::ptr::null_mut()) };
    if count <= 0 {
        return vec![unsafe { libc::getegid() }];
    }
    let mut groups = vec![0; count as usize];
    let written = unsafe { libc::getgroups(count, groups.as_mut_ptr()) };
    if written < 0 {
        vec![unsafe { libc::getegid() }]
    } else {
        groups.truncate(written as usize);
        groups
    }
}

fn canonical_directory(path: &Path, label: &str) -> Result<PathBuf, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("cursor execution identity refused: {label}: {error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!(
            "cursor execution identity refused: {label} must be a non-symlink directory"
        ));
    }
    fs::canonicalize(path)
        .map_err(|error| format!("cursor execution identity refused: {label}: {error}"))
}

struct Account {
    name: String,
    home: PathBuf,
}

fn account_named(name: &str) -> Result<Account, String> {
    let name = std::ffi::CString::new(name).expect("fixed account name has no NUL");
    let mut pwd = unsafe { std::mem::zeroed::<libc::passwd>() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0_u8; 16_384];
    let status = unsafe {
        libc::getpwnam_r(
            name.as_ptr(),
            &mut pwd,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return Err(format!("Cursor execution account {ACCOUNT} does not exist"));
    }
    account_from_passwd(&pwd)
}

fn account_for_uid(uid: u32) -> Result<Account, String> {
    let mut pwd = unsafe { std::mem::zeroed::<libc::passwd>() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0_u8; 16_384];
    let status = unsafe {
        libc::getpwuid_r(
            uid,
            &mut pwd,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return Err(format!(
            "cursor execution identity refused: uid {uid} has no real OS account"
        ));
    }
    account_from_passwd(&pwd)
}

fn account_from_passwd(pwd: &libc::passwd) -> Result<Account, String> {
    let name = unsafe { CStr::from_ptr(pwd.pw_name) }
        .to_string_lossy()
        .into_owned();
    let home = PathBuf::from(
        unsafe { CStr::from_ptr(pwd.pw_dir) }
            .to_string_lossy()
            .into_owned(),
    );
    Ok(Account { name, home })
}

fn usage() -> &'static str {
    "usage: tightbeam cursor-exec <verify|launch|group> <managed-base> <org-base> <operator-uid> <operator-home> -- ..."
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture() -> (PathBuf, PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let org = std::env::temp_dir().join(format!("tightbeam-cursor-identity-{nonce}"));
        let base = org.join("exec-home/.tightbeam");
        let identity_dir = org.join("homes/test/cursor/.tightbeam/harness-processes");
        fs::create_dir_all(&base).unwrap();
        fs::create_dir_all(&identity_dir).unwrap();
        let adapter_dir = base
            .parent()
            .unwrap()
            .join(".local/share/cursor-agent/versions")
            .join(CURSOR_VERSION);
        fs::create_dir_all(&adapter_dir).unwrap();
        let adapter = adapter_dir.join("cursor-agent");
        fs::write(&adapter, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&adapter, fs::Permissions::from_mode(0o755)).unwrap();
        (base, org, identity_dir)
    }

    #[test]
    fn launch_command_must_use_the_managed_identity_and_adapter_paths() {
        let (base, org, identity_dir) = fixture();
        let command = vec![
            identity_dir.join("launch.identity").display().to_string(),
            "launch-id".to_owned(),
            "--".to_owned(),
            base.parent()
                .unwrap()
                .join(".local/share/cursor-agent/versions")
                .join(CURSOR_VERSION)
                .join("cursor-agent")
                .display()
                .to_string(),
            "acp".to_owned(),
        ];
        assert!(verify_launch_command(&base, &org, &command).is_ok());

        let mut escaped = command.clone();
        escaped[0] = org.join("elsewhere/launch.identity").display().to_string();
        assert!(verify_launch_command(&base, &org, &escaped).is_err());

        let mut arbitrary = command;
        arbitrary[3] = "/bin/sh".to_owned();
        assert!(verify_launch_command(&base, &org, &arbitrary).is_err());
        fs::remove_dir_all(&org).unwrap();
    }

    #[test]
    fn admin_instructions_never_override_home_and_cover_both_platforms() {
        let instructions = admin_instructions(
            Path::new("/srv/tightbeam"),
            Path::new("/Users/operator"),
            Path::new("/build/tightbeam"),
            "test-machine",
        );
        assert!(!instructions.contains("HOME="));
        assert!(instructions.contains(ACCOUNT));
        assert!(instructions.contains(LAUNCHER));
        assert!(instructions.contains("tightbeam-workspace"));
        assert!(instructions.contains("visudo"));
        assert!(instructions.contains(CURSOR_VERSION));
        assert!(instructions.contains("/Users/operator/.cursor"));
        assert!(instructions.contains("IsHidden 1"));
        assert!(instructions.contains("/build/tightbeam"));
        assert!(instructions.contains("/homes/test-machine/cursor"));
        assert!(instructions.contains("chown -R root:tightbeam-workspace"));
        assert!(!instructions.contains("GH_CONFIG_DIR PATH"));
        assert!(!instructions.contains("!secure_path"));
    }

    #[test]
    fn installed_launcher_allows_only_cursor_exec() {
        assert!(launcher_command_allowed(&["cursor-exec".to_owned()]));
        for command in ["harness-exec", "rail-exec", "command-exec", "doctor"] {
            assert!(!launcher_command_allowed(&[command.to_owned()]));
        }
    }
}
