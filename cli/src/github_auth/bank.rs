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
}

/// Runs gh (and git, whose credential helper is gh) against the banked
/// Tightbeam config dir when one exists. The OS keyring is deliberately out of
/// the read path: agent processes descend from the gateway daemon, and a
/// daemon-descended context cannot read the login keychain
/// (errSecInteractionNotAllowed) — a keyring credential probes live from an
/// operator terminal while being unreadable everywhere project work runs.
pub(super) struct RealGh {
    config_dir: Option<PathBuf>,
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
        }
    }

    /// Onboarding-side construction: the banked dir is the destination, so it
    /// is created (0700) before gh runs. The restricted paths are named
    /// explicitly — never walked upward — so nothing above base_dir can ever
    /// be chmodded regardless of how the path shape evolves.
    pub(super) fn banking_into(base_dir: &Path) -> Result<Self, String> {
        let dir = gh_config_dir(base_dir);
        fs::create_dir_all(&dir)
            .map_err(|error| format!("could not create {}: {error}", dir.display()))?;
        // A provisioned Cursor execution identity reads this bank on its
        // canonical path through a group grant (auth 0710, github 0710, gh 0750;
        // Tightbeam.Harness.Cursor.grant_bank_access!). Detect that grant by the
        // gh dir carrying a group other than this process's own, and preserve
        // traversal for it; otherwise keep the operator-only 0700 layout.
        let own_gid = unsafe { libc::getgid() };
        let group_granted = fs::metadata(&dir)
            .map(|m| m.gid() != own_gid)
            .unwrap_or(false);
        let modes: [(std::path::PathBuf, u32); 3] = if group_granted {
            [
                (base_dir.join("auth"), 0o710),
                (base_dir.join("auth").join("github"), 0o710),
                (dir.clone(), 0o750),
            ]
        } else {
            [
                (base_dir.join("auth"), 0o700),
                (base_dir.join("auth").join("github"), 0o700),
                (dir.clone(), 0o700),
            ]
        };
        for (restrict, mode) in modes {
            fs::set_permissions(&restrict, fs::Permissions::from_mode(mode)).map_err(|error| {
                format!("could not set {mode:o} on {}: {error}", restrict.display())
            })?;
        }
        Ok(RealGh {
            config_dir: Some(dir),
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
            restrict_banked_tree(dir)?;
        }
        Ok(())
    }
}

fn restrict_banked_tree(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;

    if metadata.file_type().is_symlink() {
        return Err(format!(
            "refusing symlink in banked GitHub config: {}",
            path.display()
        ));
    }

    if metadata.is_dir() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("could not set 0700 on {}: {error}", path.display()))?;
        for entry in fs::read_dir(path)
            .map_err(|error| format!("could not read {}: {error}", path.display()))?
        {
            let entry = entry.map_err(|error| {
                format!("could not inspect entry in {}: {error}", path.display())
            })?;
            restrict_banked_tree(&entry.path())?;
        }
        return Ok(());
    }

    if metadata.is_file() {
        return fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("could not set 0600 on {}: {error}", path.display()));
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
}
