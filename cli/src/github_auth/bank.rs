use std::fs;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use super::gh_config_dir;

pub(super) trait Gh {
    fn which_gh(&self) -> Option<PathBuf>;
    fn output(&self, args: &[&str]) -> Result<Output, String>;
    fn status(&self, args: &[&str]) -> Result<std::process::ExitStatus, String>;
    fn git_ls_remote(&self, remote: &str) -> Result<Output, String>;
    fn git_remote_url(&self, _name: &str) -> Result<Option<String>, String> {
        Ok(None)
    }
    fn git_submodule_urls(&self) -> Result<Vec<String>, String> {
        Ok(Vec::new())
    }
    fn secure_banked_files(&self) -> Result<(), String> {
        Ok(())
    }
    fn bank_layout(&self) -> BankLayout {
        BankLayout::OperatorOnly
    }
}

/// The provisioned Cursor execution group. Resolved by NAME at use, exactly
/// as `Tightbeam.Harness.Cursor.grant_bank_access!` does, so no other group
/// can ever be granted by accident.
pub(super) const WORKSPACE_GROUP: &str = "tightbeam-workspace";

/// How the banked GitHub config is laid out on disk. Every mode the bank
/// writes — at creation, after gh login, at the end of onboarding — comes from
/// this one value, so `tightbeam onboard github` (credential rotation) can
/// never silently revoke a grant that a provisioned host carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum BankLayout {
    /// Only the operator reads the bank: every dir 0700, every file 0600.
    OperatorOnly,
    /// A provisioned Cursor execution identity reads the bank on its canonical
    /// path through the named workspace group (`grant_bank_access!`): the
    /// traversal dirs `auth` and `auth/github` 0710, the gh dir 0750, and
    /// exactly gh's `config.yml` and `hosts.yml` 0640 on the group — the
    /// same two files the Elixir grant names — including a `hosts.yml` gh
    /// recreates during login with the operator's primary group. Everything
    /// else under the gh dir stays operator-only.
    WorkspaceGranted { gid: u32 },
}

impl BankLayout {
    /// The grant is real only when the gh dir carries the workspace group
    /// resolved by name, and that group is not this process's primary group
    /// (`provisioned_workspace_gid` refuses the same case: a primary group
    /// lands on every dir the operator creates and would make everything look
    /// granted). Any other group on the dir is not a grant and gets the
    /// operator-only layout; a missing dir or group likewise.
    fn detect_with(dir: &Path, workspace_gid: Option<u32>) -> Self {
        let primary = unsafe { libc::getgid() };
        match (fs::metadata(dir), workspace_gid) {
            (Ok(metadata), Some(gid)) if gid != primary && metadata.gid() == gid => {
                BankLayout::WorkspaceGranted { gid }
            }
            _ => BankLayout::OperatorOnly,
        }
    }

    /// The only files the grant reads: what gh needs to authenticate. Mirrors
    /// `grant_bank_access!`'s allowlist exactly.
    fn granted_file(self, path: &Path) -> bool {
        matches!(self, BankLayout::WorkspaceGranted { .. })
            && matches!(
                path.file_name().and_then(|name| name.to_str()),
                Some("config.yml" | "hosts.yml")
            )
    }

    /// `auth` and `auth/github`: traversal only, never listing.
    pub(super) fn traversal_mode(self) -> u32 {
        match self {
            BankLayout::OperatorOnly => 0o700,
            BankLayout::WorkspaceGranted { .. } => 0o710,
        }
    }

    fn dir_mode(self) -> u32 {
        match self {
            BankLayout::OperatorOnly => 0o700,
            BankLayout::WorkspaceGranted { .. } => 0o750,
        }
    }

    /// Set `mode` on `path`, first moving it onto the granted group when one
    /// exists. Group before mode: a 0640 file must never spend an instant
    /// readable by a group that is not the grant.
    pub(super) fn apply(self, path: &Path, mode: u32) -> Result<(), String> {
        if let BankLayout::WorkspaceGranted { gid } = self {
            std::os::unix::fs::chown(path, None, Some(gid)).map_err(|error| {
                format!(
                    "could not set group {gid} ({WORKSPACE_GROUP}) on {}: {error}; \
                     is this session a member of {WORKSPACE_GROUP} (id -Gn)?",
                    path.display()
                )
            })?;
        }
        fs::set_permissions(path, fs::Permissions::from_mode(mode))
            .map_err(|error| format!("could not set {mode:o} on {}: {error}", path.display()))
    }
}

fn group_gid_by_name(name: &str) -> Option<u32> {
    let name = std::ffi::CString::new(name).ok()?;
    let mut group = unsafe { std::mem::zeroed::<libc::group>() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0_u8; 16_384];
    loop {
        let status = unsafe {
            libc::getgrnam_r(
                name.as_ptr(),
                &mut group,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        // A large member list overflows the buffer; that must not read as
        // "no such group" and silently reset a granted host.
        if status == libc::ERANGE && buffer.len() < 1 << 22 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        if status != 0 || result.is_null() {
            return None;
        }
        return Some(group.gr_gid);
    }
}

/// Runs gh (and git, whose credential helper is gh) against the banked
/// Tightbeam config dir when one exists. The OS keyring is deliberately out of
/// the read path: agent processes descend from the gateway daemon, and a
/// daemon-descended context cannot read the login keychain
/// (errSecInteractionNotAllowed) — a keyring credential probes live from an
/// operator terminal while being unreadable everywhere project work runs.
pub(super) struct RealGh {
    config_dir: Option<PathBuf>,
    layout: BankLayout,
}

impl RealGh {
    /// Probe-side construction: the banked dir is pinned whether or not it
    /// exists yet. Falling back to the ambient environment would let a
    /// keyring or operator-shell credential answer "live" for environments
    /// that cannot read it — the exact inconsistency this capability exists
    /// to eliminate. An absent dir makes gh answer needs_onboarding, which
    /// is the honest state.
    pub(super) fn using_banked(base_dir: &Path) -> Self {
        RealGh {
            config_dir: Some(gh_config_dir(base_dir)),
            layout: BankLayout::OperatorOnly,
        }
    }

    /// Onboarding-side construction: the banked dir is the destination, so it
    /// is created before gh runs, under the layout the host already carries.
    /// A fresh dir is operator-only on an unprovisioned host; on a provisioned
    /// one it inherits `auth/github`'s group on macOS (BSD semantics) and the
    /// operator's primary group on Linux, so the grant is detected on the
    /// first onboarding there and on the next Cursor delivery here — either
    /// way only the name-resolved group is ever granted. The restricted paths
    /// are named explicitly — never walked upward — so nothing above base_dir
    /// can ever be chmodded regardless of how the path shape evolves.
    pub(super) fn banking_into(base_dir: &Path) -> Result<Self, String> {
        Self::banking_into_with(base_dir, group_gid_by_name(WORKSPACE_GROUP))
    }

    fn banking_into_with(base_dir: &Path, workspace_gid: Option<u32>) -> Result<Self, String> {
        let dir = gh_config_dir(base_dir);
        fs::create_dir_all(&dir)
            .map_err(|error| format!("could not create {}: {error}", dir.display()))?;
        let layout = BankLayout::detect_with(&dir, workspace_gid);
        layout.apply(&base_dir.join("auth"), layout.traversal_mode())?;
        layout.apply(
            &base_dir.join("auth").join("github"),
            layout.traversal_mode(),
        )?;
        layout.apply(&dir, layout.dir_mode())?;
        Ok(RealGh {
            config_dir: Some(dir),
            layout,
        })
    }

    fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        if let Some(dir) = &self.config_dir {
            command.env("GH_CONFIG_DIR", dir);
        }
        command
    }
}

/// Probes are bounded: the guard runs inside a PreToolUse hook, and an
/// unbounded `git ls-remote` against an unreachable host would hang the
/// agent's whole tool path. A timed-out probe maps to an error, which the
/// callers treat as `unknown` — per spec, never live. The login ceremony
/// (`status`) stays unbounded on purpose: a human is completing a browser
/// flow that legitimately takes minutes.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

impl Gh for RealGh {
    fn which_gh(&self) -> Option<PathBuf> {
        crate::preflight::on_path("gh", &std::env::var("PATH").unwrap_or_default())
    }

    fn output(&self, args: &[&str]) -> Result<Output, String> {
        let child = self
            .command("gh")
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| format!("failed to run gh {}: {error}", args.join(" ")))?;
        wait_bounded(child, &format!("gh {}", args.join(" ")))
    }

    fn status(&self, args: &[&str]) -> Result<std::process::ExitStatus, String> {
        self.command("gh")
            .args(args)
            .status()
            .map_err(|error| format!("failed to run gh {}: {error}", args.join(" ")))
    }

    fn git_ls_remote(&self, remote: &str) -> Result<Output, String> {
        let child = self
            .command("git")
            .args(["ls-remote", remote, "HEAD"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| format!("failed to run git ls-remote: {error}"))?;
        wait_bounded(child, "git ls-remote")
    }

    fn git_remote_url(&self, name: &str) -> Result<Option<String>, String> {
        let key = format!("remote.{name}.url");
        let output = self
            .command("git")
            .args(["config", "--get", &key])
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|error| format!("failed to resolve git remote {name}: {error}"))?;

        if !output.status.success() {
            return Ok(None);
        }

        let url = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        Ok((!url.is_empty()).then_some(url))
    }

    fn git_submodule_urls(&self) -> Result<Vec<String>, String> {
        let mut urls = Vec::new();
        for args in [
            vec!["config", "--get-regexp", r"^submodule\..*\.url$"],
            vec![
                "config",
                "--file",
                ".gitmodules",
                "--get-regexp",
                r"^submodule\..*\.url$",
            ],
        ] {
            let output = self
                .command("git")
                .args(&args)
                .stdin(std::process::Stdio::null())
                .output()
                .map_err(|error| format!("failed to resolve git submodule URLs: {error}"))?;
            if !output.status.success() {
                continue;
            }
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                if let Some(url) = line.split_whitespace().nth(1) {
                    urls.push(url.to_owned());
                }
            }
        }
        urls.sort();
        urls.dedup();
        Ok(urls)
    }

    fn secure_banked_files(&self) -> Result<(), String> {
        if let Some(dir) = &self.config_dir {
            restrict_banked_tree(dir, self.layout, 0)?;
        }
        Ok(())
    }

    fn bank_layout(&self) -> BankLayout {
        self.layout
    }
}

fn restrict_banked_tree(path: &Path, layout: BankLayout, depth: usize) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;

    if metadata.file_type().is_symlink() {
        return Err(format!(
            "refusing symlink in banked GitHub config: {}",
            path.display()
        ));
    }

    if metadata.is_dir() {
        // Only the gh dir itself is traversable by the grant; anything nested
        // is not on the grant's read path.
        if depth == 0 {
            layout.apply(path, layout.dir_mode())?;
        } else {
            BankLayout::OperatorOnly.apply(path, 0o700)?;
        }
        for entry in fs::read_dir(path)
            .map_err(|error| format!("could not read {}: {error}", path.display()))?
        {
            let entry = entry.map_err(|error| {
                format!("could not inspect entry in {}: {error}", path.display())
            })?;
            restrict_banked_tree(&entry.path(), layout, depth + 1)?;
        }
        return Ok(());
    }

    if metadata.is_file() {
        return if depth == 1 && layout.granted_file(path) {
            layout.apply(path, 0o640)
        } else {
            BankLayout::OperatorOnly.apply(path, 0o600)
        };
    }

    Err(format!(
        "unsupported entry in banked GitHub config: {}",
        path.display()
    ))
}

// Probe output is small (auth status lines, one ls-remote ref), so waiting for
// exit before draining the pipes cannot deadlock on a full pipe buffer in
// practice; a pathological child that fills the buffer just gets killed at the
// deadline like any other hang.
fn wait_bounded(mut child: std::process::Child, what: &str) -> Result<Output, String> {
    let deadline = std::time::Instant::now() + PROBE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child
                    .wait_with_output()
                    .map_err(|error| format!("failed reading {what} output: {error}"));
            }
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "{what} timed out after {}s",
                    PROBE_TIMEOUT.as_secs()
                ));
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(error) => return Err(format!("failed waiting for {what}: {error}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn banking_into_creates_restricted_config_dir() {
        let root = std::env::temp_dir().join(format!(
            "tb-gh-bank-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let gh = RealGh::banking_into(&root).unwrap();
        let dir = gh_config_dir(&root);
        assert_eq!(gh.config_dir.as_deref(), Some(dir.as_path()));
        for restricted in [&dir, &root.join("auth/github"), &root.join("auth")] {
            assert_eq!(
                fs::metadata(restricted).unwrap().permissions().mode() & 0o777,
                0o700,
                "{} must not be group/world readable",
                restricted.display()
            );
        }
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn using_banked_pins_the_config_dir_even_when_absent() {
        let root = std::env::temp_dir().join(format!(
            "tb-gh-missing-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        // No ambient fallback: an absent banked dir must probe as
        // needs_onboarding, never as whatever the operator shell can reach.
        assert_eq!(
            RealGh::using_banked(&root).config_dir.as_deref(),
            Some(gh_config_dir(&root).as_path())
        );
    }

    #[test]
    fn secure_banked_files_repairs_existing_file_and_directory_modes() {
        let root = std::env::temp_dir().join(format!(
            "tb-gh-private-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let gh = RealGh::banking_into(&root).unwrap();
        let dir = gh_config_dir(&root);
        let nested = dir.join("nested");
        fs::create_dir_all(&nested).unwrap();
        fs::set_permissions(&nested, fs::Permissions::from_mode(0o755)).unwrap();
        let hosts = dir.join("hosts.yml");
        fs::write(&hosts, "github.com:\n").unwrap();
        fs::set_permissions(&hosts, fs::Permissions::from_mode(0o644)).unwrap();

        gh.secure_banked_files().unwrap();

        assert_eq!(
            fs::metadata(&nested).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&hosts).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(&root).unwrap();
    }

    /// A group this process may hand files to that is not its primary group —
    /// the shape of a provisioned `tightbeam-workspace` grant on any host.
    fn supplementary_group() -> Option<u32> {
        let own = unsafe { libc::getgid() };
        let count = unsafe { libc::getgroups(0, std::ptr::null_mut()) };
        if count <= 0 {
            return None;
        }
        let mut groups = vec![0; count as usize];
        let written = unsafe { libc::getgroups(count, groups.as_mut_ptr()) };
        if written < 0 {
            return None;
        }
        groups.truncate(written as usize);
        groups.into_iter().find(|gid| *gid != own)
    }

    fn fresh_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "tb-gh-{label}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn mode_of(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn workspace_grant_survives_rebanking_and_securing() {
        let Some(gid) = supplementary_group() else {
            eprintln!("skipping: this process has no supplementary group to grant");
            return;
        };
        let root = fresh_root("granted");
        // First onboarding on an unprovisioned host: operator-only.
        RealGh::banking_into_with(&root, Some(gid)).unwrap();
        let dir = gh_config_dir(&root);
        assert_eq!(mode_of(&dir), 0o700);

        // The host is provisioned and grant_bank_access! runs: the gh dir
        // carries the workspace group.
        std::os::unix::fs::chown(&dir, None, Some(gid)).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o750)).unwrap();

        // Credential rotation: onboarding again must keep the grant, on the
        // traversal dirs and on the files gh writes with the operator's group.
        let gh = RealGh::banking_into_with(&root, Some(gid)).unwrap();
        assert_eq!(gh.bank_layout(), BankLayout::WorkspaceGranted { gid });
        assert_eq!(mode_of(&root.join("auth")), 0o710);
        assert_eq!(mode_of(&root.join("auth/github")), 0o710);
        assert_eq!(mode_of(&dir), 0o750);

        let hosts = dir.join("hosts.yml");
        fs::write(&hosts, "github.com:\n").unwrap();
        fs::set_permissions(&hosts, fs::Permissions::from_mode(0o644)).unwrap();
        let config = dir.join("config.yml");
        fs::write(&config, "git_protocol: https\n").unwrap();
        let state = dir.join("state.yml");
        fs::write(&state, "checked_for_update_at: 0\n").unwrap();
        let nested = dir.join("nested");
        fs::create_dir_all(&nested).unwrap();
        let nested_file = nested.join("hosts.yml");
        fs::write(&nested_file, "not the bank\n").unwrap();
        gh.secure_banked_files().unwrap();

        // Exactly the Elixir grant's allowlist reads 0640 on the group …
        for granted in [&hosts, &config] {
            assert_eq!(mode_of(granted), 0o640, "{}", granted.display());
            assert_eq!(fs::metadata(granted).unwrap().gid(), gid);
        }
        assert_eq!(fs::metadata(&dir).unwrap().gid(), gid);
        // … and nothing else under the gh dir is on the grant's read path,
        // not even an allowlisted name one level down.
        assert_eq!(mode_of(&state), 0o600);
        assert_eq!(mode_of(&nested), 0o700);
        assert_eq!(mode_of(&nested_file), 0o600);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_group_that_is_not_the_workspace_grant_is_reset_to_operator_only() {
        let Some(gid) = supplementary_group() else {
            eprintln!("skipping: this process has no supplementary group to grant");
            return;
        };
        let root = fresh_root("ungranted");
        RealGh::banking_into_with(&root, None).unwrap();
        let dir = gh_config_dir(&root);
        std::os::unix::fs::chown(&dir, None, Some(gid)).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o750)).unwrap();

        // No workspace group on this host, or a different one: not a grant.
        for workspace_gid in [None, Some(gid.wrapping_add(1))] {
            let gh = RealGh::banking_into_with(&root, workspace_gid).unwrap();
            assert_eq!(gh.bank_layout(), BankLayout::OperatorOnly);
            assert_eq!(mode_of(&root.join("auth")), 0o700);
            assert_eq!(mode_of(&root.join("auth/github")), 0o700);
            assert_eq!(mode_of(&dir), 0o700);
        }
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn layout_detection_needs_the_named_group_on_the_gh_dir() {
        let root = fresh_root("detect");
        let dir = gh_config_dir(&root);
        assert_eq!(
            BankLayout::detect_with(&dir, Some(12_345)),
            BankLayout::OperatorOnly,
            "an absent dir is never a grant"
        );
        fs::create_dir_all(&dir).unwrap();
        assert_eq!(
            BankLayout::detect_with(&dir, None),
            BankLayout::OperatorOnly,
            "no workspace group on the host is never a grant"
        );
        let primary = unsafe { libc::getgid() };
        std::os::unix::fs::chown(&dir, None, Some(primary)).unwrap();
        assert_eq!(
            BankLayout::detect_with(&dir, Some(primary)),
            BankLayout::OperatorOnly,
            "the operator's primary group is never a grant, even when it is the named group"
        );
        if let Some(gid) = supplementary_group() {
            std::os::unix::fs::chown(&dir, None, Some(gid)).unwrap();
            assert_eq!(
                BankLayout::detect_with(&dir, Some(gid)),
                BankLayout::WorkspaceGranted { gid },
                "the dir carrying the named, non-primary group is the grant"
            );
            assert_eq!(
                BankLayout::detect_with(&dir, Some(gid.wrapping_add(1))),
                BankLayout::OperatorOnly,
                "a different group on the dir is not the grant"
            );
        }
        fs::remove_dir_all(&root).unwrap();
    }
}
