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

/// The pinned Cursor operand is obtainable: Cursor publishes every agent-cli
/// version at this URL shape (the same one its installer script downloads
/// from), and each archive's `dist-package/` is byte-identical to the pinned
/// bundle `Tightbeam.Harness.Cursor` verifies at every launch. The launcher
/// script is byte-identical across all four platform archives; `index.js` is
/// platform-specific, so its pin is a per-platform table. All five digests
/// mirror the adapter's (`@launcher_sha256` / `@bundle_sha256_by_platform`);
/// `test/cursor_registration_test.exs` pins the parity, and every digest was
/// verified against the real downloaded archives (ops, 2026-08-30).
const CURSOR_DOWNLOAD_URL: &str =
    "https://downloads.cursor.com/lab/{CURSOR_VERSION}/{OS}/{ARCH}/agent-cli-package.tar.gz";
const CURSOR_LAUNCHER_SHA256: &str =
    "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831";
const CURSOR_BUNDLE_SHA256_BY_PLATFORM: [(&str, &str, &str); 4] = [
    (
        "darwin",
        "arm64",
        "6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0",
    ),
    (
        "darwin",
        "x64",
        "2def6db128c49b95f33b8b6f9624a15e65616f074ae505c06ffccf35fe0feb7b",
    ),
    (
        "linux",
        "x64",
        "f6fd4e6bf3d6ecbf66cc2dcabcf708b8a7c37b400d10c82a58658b5e331c36d0",
    ),
    (
        "linux",
        "arm64",
        "468106299df5dcebf227e0d478172a7241a202d25c4b2b7060b6723ee19cabac",
    ),
];

/// This host's CPU architecture in Cursor's download vocabulary. Provisioning
/// instructions are printed by the CLI running ON the host being provisioned,
/// so compile-time arch is the host arch. An arch outside the table falls
/// through unmapped: the URL 404s and the digest lookup refuses — loudly,
/// never silently.
fn host_arch() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "arm64",
        "x86_64" => "x64",
        other => other,
    }
}

fn cursor_bundle_sha256(os: &str, arch: &str) -> Option<&'static str> {
    CURSOR_BUNDLE_SHA256_BY_PLATFORM
        .iter()
        .find(|(o, a, _)| *o == os && *a == arch)
        .map(|(_, _, digest)| *digest)
}

pub fn running_as_launcher() -> bool {
    let Ok(actual) = std::env::current_exe().and_then(fs::canonicalize) else {
        return false;
    };
    fs::canonicalize(LAUNCHER).is_ok_and(|launcher| actual == launcher)
}

/// Root-owned directory carrying a `tightbeam` symlink to the launcher, so the
/// dedicated identity resolves the rail helper without traversing the operator's
/// home. The projected rails put it first on PATH.
pub const HELPER_PATH_DIR: &str = "/usr/local/libexec/tightbeam-cursor-path";

/// Read-only rail guards the projected hooks invoke as `tightbeam <guard>`.
const UNPRIVILEGED_GUARDS: [&str; 2] = ["github-auth-check", "tool-call-observed"];

/// What the launcher binary agrees to run. `cursor-exec` always (that is the
/// sudoers grant). The rail guards only when invoked WITHOUT a privilege change
/// — real uid == effective uid and no `SUDO_UID` — i.e. by the execution
/// identity itself from inside a Cursor session, never through the sudoers
/// wildcard by another workspace member.
pub fn launcher_command_allowed(args: &[String]) -> bool {
    launcher_command_allowed_with(args, invoked_unprivileged())
}

fn launcher_command_allowed_with(args: &[String], unprivileged: bool) -> bool {
    match args.first().map(String::as_str) {
        Some("cursor-exec") => true,
        Some(guard) if UNPRIVILEGED_GUARDS.contains(&guard) => unprivileged,
        _ => false,
    }
}

/// True only when this process was NOT entered through sudo: sudo always
/// exports SUDO_UID into the target environment (the caller cannot strip it),
/// and the launcher scrubs it from the Cursor session it execs, so its presence
/// is exactly "a workspace member is using the sudoers wildcard right now".
fn invoked_unprivileged() -> bool {
    std::env::var_os("SUDO_UID").is_none()
        && unsafe { libc::getuid() } == unsafe { libc::geteuid() }
        && unsafe { libc::getgid() } == unsafe { libc::getegid() }
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
        verify_helper_path_install(Path::new(HELPER_PATH_DIR))?;
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

/// The helper-path dir must be root-owned and not group/world-writable, and its
/// `tightbeam` entry must be a symlink to the launcher (canonicalize equality).
fn verify_helper_path_install(dir: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(dir).map_err(|error| {
        format!(
            "Cursor helper path dir is not installed at {}: {error}",
            dir.display()
        )
    })?;
    if !metadata.is_dir() || metadata.uid() != 0 || metadata.permissions().mode() & 0o022 != 0 {
        return Err(format!(
            "Cursor helper path dir {} must be a root-owned directory that is not group/world writable",
            dir.display()
        ));
    }
    let helper = dir.join("tightbeam");
    let link = fs::symlink_metadata(&helper).map_err(|error| {
        format!(
            "Cursor helper symlink is not installed at {}: {error}",
            helper.display()
        )
    })?;
    if !link.file_type().is_symlink() || link.uid() != 0 {
        return Err(format!(
            "{} must be a root-owned symlink to {LAUNCHER}",
            helper.display()
        ));
    }
    let resolved = fs::canonicalize(&helper)
        .map_err(|error| format!("could not resolve {}: {error}", helper.display()))?;
    let launcher = fs::canonicalize(LAUNCHER)
        .map_err(|error| format!("could not resolve {LAUNCHER}: {error}"))?;
    if resolved != launcher {
        return Err(format!(
            "{} resolves to {} rather than {LAUNCHER}",
            helper.display(),
            resolved.display()
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
    admin_instructions_for(
        base,
        operator_home,
        executable,
        machine,
        cfg!(target_os = "macos"),
    )
}

/// The pinned bundle's download URL for one concrete platform. Fully resolved
/// here — no shell substitution — so the digest printed next to it is the one
/// that archive must hash to.
fn cursor_download_url(os: &str, arch: &str) -> String {
    CURSOR_DOWNLOAD_URL
        .replace("{CURSOR_VERSION}", CURSOR_VERSION)
        .replace("{OS}", os)
        .replace("{ARCH}", arch)
}

fn admin_instructions_for(
    base: &Path,
    operator_home: &Path,
    executable: &Path,
    machine: &str,
    macos: bool,
) -> String {
    let os = if macos { "darwin" } else { "linux" };
    let arch = host_arch();
    let download_url = cursor_download_url(os, arch);
    let bundle_sha256 = cursor_bundle_sha256(os, arch).unwrap_or("UNSUPPORTED-CPU-ARCHITECTURE");
    if macos {
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
             TB_CURSOR=$(mktemp -d)\n\
             curl -fsSL {download_url} -o $TB_CURSOR/agent-cli-package.tar.gz\n\
             tar --strip-components=1 -xzf $TB_CURSOR/agent-cli-package.tar.gz -C $TB_CURSOR\n\
             printf '%s  %s\\n' {CURSOR_LAUNCHER_SHA256} $TB_CURSOR/cursor-agent {bundle_sha256} $TB_CURSOR/index.js | shasum -a 256 -c - && sudo tar --strip-components=1 --no-same-owner --no-same-permissions -xzf $TB_CURSOR/agent-cli-package.tar.gz -C /Users/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             rm -rf $TB_CURSOR\n\
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
             sudo mkdir -p {base}/homes/{machine}/cursor/.tightbeam/harness-processes {base}/homes/{machine}/cursor/acp-sessions\n\
             sudo chown -R $USER:tightbeam-workspace {base}/homes/{machine}/cursor\n\
             sudo chmod 2770 {base}/homes/{machine}/cursor {base}/homes/{machine}/cursor/.tightbeam {base}/homes/{machine}/cursor/.tightbeam/harness-processes {base}/homes/{machine}/cursor/acp-sessions\n\
             sudo chgrp tightbeam-workspace {base}/auth\n\
             sudo chmod 0710 {base}/auth\n\
             sudo chgrp -R tightbeam-workspace {base}/auth/github\n\
             sudo chmod -R g+rX {base}/auth/github\n\
             test ! -e {operator_home}/.cursor || sudo chmod 0700 {operator_home}/.cursor\n\
             test ! -e {operator_home}/.agents || sudo chmod 0700 {operator_home}/.agents\n\
             test ! -e {operator_home}/.pi || sudo chmod 0700 {operator_home}/.pi\n\
             sudo mkdir -p /usr/local/libexec\n\
             sudo install -o root -g wheel -m 0755 {executable} {LAUNCHER}\n\
             sudo install -d -o root -g wheel -m 0755 {HELPER_PATH_DIR}\n\
             sudo ln -sfn {LAUNCHER} {HELPER_PATH_DIR}/tightbeam\n\
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
             TB_CURSOR=$(mktemp -d)\n\
             curl -fsSL {download_url} -o $TB_CURSOR/agent-cli-package.tar.gz\n\
             tar --strip-components=1 -xzf $TB_CURSOR/agent-cli-package.tar.gz -C $TB_CURSOR\n\
             printf '%s  %s\\n' {CURSOR_LAUNCHER_SHA256} $TB_CURSOR/cursor-agent {bundle_sha256} $TB_CURSOR/index.js | sha256sum -c - && sudo tar --strip-components=1 --no-same-owner --no-same-permissions -xzf $TB_CURSOR/agent-cli-package.tar.gz -C /home/{ACCOUNT}/.local/share/cursor-agent/versions/{CURSOR_VERSION}\n\
             rm -rf $TB_CURSOR\n\
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
             sudo mkdir -p {base}/homes/{machine}/cursor/.tightbeam/harness-processes {base}/homes/{machine}/cursor/acp-sessions\n\
             sudo chown -R $USER:tightbeam-workspace {base}/homes/{machine}/cursor\n\
             sudo chmod 2770 {base}/homes/{machine}/cursor {base}/homes/{machine}/cursor/.tightbeam {base}/homes/{machine}/cursor/.tightbeam/harness-processes {base}/homes/{machine}/cursor/acp-sessions\n\
             sudo chgrp tightbeam-workspace {base}/auth\n\
             sudo chmod 0710 {base}/auth\n\
             sudo chgrp -R tightbeam-workspace {base}/auth/github\n\
             sudo chmod -R g+rX {base}/auth/github\n\
             test ! -e {operator_home}/.cursor || sudo chmod 0700 {operator_home}/.cursor\n\
             test ! -e {operator_home}/.agents || sudo chmod 0700 {operator_home}/.agents\n\
             test ! -e {operator_home}/.pi || sudo chmod 0700 {operator_home}/.pi\n\
             sudo mkdir -p /usr/local/libexec\n\
             sudo install -o root -g root -m 0755 {executable} {LAUNCHER}\n\
             sudo install -d -o root -g root -m 0755 {HELPER_PATH_DIR}\n\
             sudo ln -sfn {LAUNCHER} {HELPER_PATH_DIR}/tightbeam\n\
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
        for (macos, operator_home) in [(true, "/Users/operator"), (false, "/home/operator")] {
            let instructions = admin_instructions_for(
                Path::new("/srv/tightbeam"),
                Path::new(operator_home),
                Path::new("/build/tightbeam"),
                "test-machine",
                macos,
            );
            assert!(!instructions.contains("HOME="));
            assert!(instructions.contains(ACCOUNT));
            assert!(instructions.contains(LAUNCHER));
            assert!(instructions.contains("tightbeam-workspace"));
            assert!(instructions.contains("visudo"));
            assert!(instructions.contains(CURSOR_VERSION));
            assert!(instructions.contains(&format!("{operator_home}/.cursor")));
            assert_eq!(instructions.contains("IsHidden 1"), macos);
            assert!(instructions.contains("/build/tightbeam"));
            assert!(instructions.contains("/homes/test-machine/cursor"));
            assert!(instructions.contains("/homes/test-machine/cursor/acp-sessions"));
            assert!(instructions.contains("chmod 2770 /srv/tightbeam/homes/test-machine/cursor "));
            assert!(instructions.contains("chown -R root:tightbeam-workspace"));
            assert!(instructions.contains(HELPER_PATH_DIR));
            assert!(
                instructions.contains(&format!("ln -sfn {LAUNCHER} {HELPER_PATH_DIR}/tightbeam"))
            );
            assert!(!instructions.contains("GH_CONFIG_DIR PATH"));
            assert!(!instructions.contains("!secure_path"));
            // The pinned operand is obtained from Cursor's published archive
            // and verified against both pinned digests — never copied from
            // the operator's home, which need not have it installed.
            assert!(instructions.contains(&format!(
                "https://downloads.cursor.com/lab/{CURSOR_VERSION}/{}/",
                if macos { "darwin" } else { "linux" }
            )));
            assert!(instructions.contains("agent-cli-package.tar.gz"));
            assert!(instructions.contains(CURSOR_LAUNCHER_SHA256));
            let os = if macos { "darwin" } else { "linux" };
            assert!(instructions.contains(cursor_bundle_sha256(os, host_arch()).unwrap()));
            assert!(instructions.contains(&format!(
                "/{os}/{arch}/agent-cli-package.tar.gz",
                arch = host_arch()
            )));
            // Digests are checked on an unprivileged extraction FIRST, and the
            // root extraction is gated on that check passing; root never
            // preserves the archive's ownership or setuid bits.
            let check = if macos {
                "shasum -a 256 -c -"
            } else {
                "sha256sum -c -"
            };
            assert!(instructions.contains(&format!(
                "{check} && sudo tar --strip-components=1 --no-same-owner --no-same-permissions -xzf"
            )));
            assert!(!instructions.contains(if macos { "sha256sum" } else { "shasum" }));
            assert!(instructions.contains("TB_CURSOR=$(mktemp -d)"));
            assert!(!instructions.contains("| sudo tar"));
            assert!(!instructions.contains("ditto"));
            assert!(!instructions.contains(&format!("{operator_home}/.local/share/cursor-agent")));
        }
    }

    #[test]
    fn download_url_is_concrete_and_every_platform_pin_is_distinct() {
        assert_eq!(
            cursor_download_url("darwin", "arm64"),
            format!(
                "https://downloads.cursor.com/lab/{CURSOR_VERSION}/darwin/arm64/agent-cli-package.tar.gz"
            )
        );
        assert!(!cursor_download_url("linux", "x64").contains('{'));

        // Four platforms, four distinct index.js pins, no accidental reuse of
        // the darwin/arm64 digest for the rest (the round-4 finding).
        let mut digests: Vec<&str> = CURSOR_BUNDLE_SHA256_BY_PLATFORM
            .iter()
            .map(|(_, _, digest)| *digest)
            .collect();
        assert_eq!(digests.len(), 4);
        digests.sort_unstable();
        digests.dedup();
        assert_eq!(digests.len(), 4, "per-platform digests must be distinct");
        for (os, arch) in [
            ("darwin", "arm64"),
            ("darwin", "x64"),
            ("linux", "x64"),
            ("linux", "arm64"),
        ] {
            assert!(cursor_bundle_sha256(os, arch).is_some());
        }
        assert!(cursor_bundle_sha256("linux", "riscv64").is_none());
        assert!(["arm64", "x64"].contains(&host_arch()));
    }

    #[test]
    fn installed_launcher_allows_only_cursor_exec() {
        assert!(launcher_command_allowed(&["cursor-exec".to_owned()]));
        for command in ["harness-exec", "rail-exec", "command-exec", "doctor"] {
            assert!(!launcher_command_allowed(&[command.to_owned()]));
        }
    }

    #[test]
    fn launcher_allows_cursor_exec_always_and_guards_only_unprivileged() {
        let args = |cmd: &str| vec![cmd.to_owned()];
        for unprivileged in [true, false] {
            assert!(launcher_command_allowed_with(
                &args("cursor-exec"),
                unprivileged
            ));
            assert!(!launcher_command_allowed_with(
                &args("rail-exec"),
                unprivileged
            ));
            assert!(!launcher_command_allowed_with(
                &args("harness-exec"),
                unprivileged
            ));
            assert!(!launcher_command_allowed_with(
                &args("command-exec"),
                unprivileged
            ));
            assert!(!launcher_command_allowed_with(&[], unprivileged));
        }
        // Rail guards: admitted only without a privilege change.
        assert!(launcher_command_allowed_with(
            &args("github-auth-check"),
            true
        ));
        assert!(launcher_command_allowed_with(
            &args("tool-call-observed"),
            true
        ));
        assert!(!launcher_command_allowed_with(
            &args("github-auth-check"),
            false
        ));
        assert!(!launcher_command_allowed_with(
            &args("tool-call-observed"),
            false
        ));
    }
}
