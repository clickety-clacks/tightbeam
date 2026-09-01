use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

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
    fn git_current_remotes(&self) -> Result<Vec<(String, String, bool)>, String> {
        Ok(Vec::new())
    }
    fn secure_banked_files(&self) -> Result<(), String> {
        Ok(())
    }
}

/// Runs gh (and git, whose credential helper is gh) against one elected
/// provider-owned credential home. The OS keyring and ambient shell variables
/// are deliberately outside this path.
pub(super) struct RealGh {
    config_dir: Option<PathBuf>,
}

impl RealGh {
    pub(super) fn using_home(home: &Path) -> Self {
        RealGh {
            config_dir: Some(home.to_path_buf()),
        }
    }

    pub(super) fn banking_into_home(home: &Path) -> Result<Self, String> {
        fs::create_dir_all(home)
            .map_err(|error| format!("could not create GitHub credential home: {error}"))?;
        let mut current = home.to_path_buf();
        // `create_dir_all` may create the credential-homes ancestor too.  It is
        // part of the private provider-home boundary, not a harmless public
        // container, so secure every Tightbeam-created directory through it.
        for _ in 0..4 {
            fs::set_permissions(&current, fs::Permissions::from_mode(0o700)).map_err(|error| {
                format!("could not secure GitHub credential directory: {error}")
            })?;
            let Some(parent) = current.parent() else {
                break;
            };
            current = parent.to_path_buf();
        }
        Ok(RealGh {
            config_dir: Some(home.to_path_buf()),
        })
    }

    fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        if let Some(dir) = &self.config_dir {
            command.env("GH_CONFIG_DIR", dir);
        }
        for name in [
            "GH_TOKEN",
            "GITHUB_TOKEN",
            "GH_ENTERPRISE_TOKEN",
            "GITHUB_ENTERPRISE_TOKEN",
        ] {
            command.env_remove(name);
        }
        if program == "git" {
            command.env("GIT_TERMINAL_PROMPT", "0");
        }
        command
    }

    pub(super) fn login_device(
        &self,
        args: &[&str],
        identity: &crate::args::Identity,
        endpoint: &crate::dispatch::Endpoint,
        machine: &str,
        owner_user_id: Option<String>,
    ) -> Result<std::process::ExitStatus, String> {
        let mut command = self.command("gh");
        command.args(args);
        crate::ceremonies::run_github_device_login(
            command,
            identity,
            endpoint,
            machine,
            owner_user_id,
        )
    }
}

/// Probes are bounded: the guard runs inside a PreToolUse hook, and an
/// unbounded `git ls-remote` against an unreachable host would hang the
/// agent's whole tool path. A timed-out probe maps to an error, which the
/// callers treat as `unknown` — per spec, never live. Device login uses the
/// separately bounded first-class ceremony runner above.
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
            .stdin(std::process::Stdio::null())
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

    fn git_current_remotes(&self) -> Result<Vec<(String, String, bool)>, String> {
        let output = self
            .command("git")
            .args(["config", "--get-regexp", r"^remote\..*\.url$"])
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|error| format!("failed to list git remotes: {error}"))?;
        if !output.status.success() {
            return Ok(Vec::new());
        }

        let mut remotes = Vec::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let Some((key, url)) = line.split_once(char::is_whitespace) else {
                continue;
            };
            let Some(name) = key
                .strip_prefix("remote.")
                .and_then(|key| key.strip_suffix(".url"))
            else {
                continue;
            };
            let marker_key = format!("remote.{name}.gh-resolved");
            let marker = self
                .command("git")
                .args(["config", "--get", &marker_key])
                .stdin(std::process::Stdio::null())
                .output()
                .map_err(|error| format!("failed to read {marker_key}: {error}"))?;
            let base =
                marker.status.success() && String::from_utf8_lossy(&marker.stdout).trim() == "base";
            remotes.push((name.to_owned(), url.trim().to_owned(), base));
        }
        remotes.sort();
        Ok(remotes)
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
    fn banking_into_home_creates_restricted_provider_home() {
        let root = std::env::temp_dir().join(format!(
            "tb-gh-bank-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let home = root.join("credential-homes/machine/github/default");
        let gh = RealGh::banking_into_home(&home).unwrap();
        assert_eq!(gh.config_dir.as_deref(), Some(home.as_path()));
        for restricted in [
            &home,
            &root.join("credential-homes/machine/github"),
            &root.join("credential-homes/machine"),
            &root.join("credential-homes"),
        ] {
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
    fn secure_banked_files_repairs_existing_file_and_directory_modes() {
        let root = std::env::temp_dir().join(format!(
            "tb-gh-private-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let dir = root.join("credential-homes/machine/github/default");
        let gh = RealGh::banking_into_home(&dir).unwrap();
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
