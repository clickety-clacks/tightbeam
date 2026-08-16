use std::io::Read;
use std::path::{Path, PathBuf};

mod bank;
mod guard;
mod probe;
mod redact;

use bank::RealGh;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GithubState {
    Live,
    MissingCli,
    NeedsOnboarding,
    InsufficientScope,
    GitUnready,
    Unknown,
}

impl GithubState {
    fn as_str(&self) -> &'static str {
        match self {
            GithubState::Live => "live",
            GithubState::MissingCli => "missing_cli",
            GithubState::NeedsOnboarding => "needs_onboarding",
            GithubState::InsufficientScope => "insufficient_scope",
            GithubState::GitUnready => "git_unready",
            GithubState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GithubStatus {
    pub hostname: String,
    pub state: GithubState,
    pub account: Option<String>,
    pub git_protocol: Option<String>,
    pub git_remote: Option<String>,
    pub git_ready: Option<bool>,
    pub detail: String,
}

pub fn onboard(hostname: &str, remote: Option<&str>) -> Result<(), String> {
    // Validate before banking_into touches the filesystem, so a bad
    // --hostname leaves nothing behind.
    probe::normalize_hostname(hostname)?;
    let base_dir = crate::base_dir::resolve();
    let gh = RealGh::banking_into(&base_dir)?;
    probe::onboard_with(hostname, remote, &base_dir, gh)
}

pub fn check_tool_call_stdin() -> Result<(), String> {
    let mut raw = String::new();
    std::io::stdin()
        .read_to_string(&mut raw)
        .map_err(|error| format!("could not read tool-call JSON from stdin: {error}"))?;
    let base_dir = crate::base_dir::resolve();
    guard::check_tool_call_with(&raw, &RealGh::using_banked(&base_dir))
}

/// The Tightbeam-owned gh config dir. One shared dir, not per-hostname:
/// GH_CONFIG_DIR is single-valued while gh's hosts.yml natively holds every
/// hostname, so per-host dirs would make a project that spans github.com and a
/// GHE host impossible to configure.
pub fn gh_config_dir(base_dir: &Path) -> PathBuf {
    base_dir.join("auth").join("github").join("gh")
}

#[cfg(test)]
mod test_support {
    use std::collections::VecDeque;
    use std::os::unix::process::ExitStatusExt;
    use std::path::PathBuf;
    use std::process::Output;
    use std::sync::Mutex;

    use super::bank::Gh;

    pub(super) struct FakeGh {
        present: bool,
        outputs: Mutex<VecDeque<(&'static [&'static str], Output)>>,
        statuses: Mutex<VecDeque<(&'static [&'static str], std::process::ExitStatus)>>,
        git_outputs: Mutex<VecDeque<(&'static str, Output)>>,
    }

    impl FakeGh {
        pub(super) fn new(present: bool) -> Self {
            Self {
                present,
                outputs: Mutex::new(VecDeque::new()),
                statuses: Mutex::new(VecDeque::new()),
                git_outputs: Mutex::new(VecDeque::new()),
            }
        }

        pub(super) fn output(self, args: &'static [&'static str], output: Output) -> Self {
            self.outputs.lock().unwrap().push_back((args, output));
            self
        }

        pub(super) fn status(
            self,
            args: &'static [&'static str],
            status: std::process::ExitStatus,
        ) -> Self {
            self.statuses.lock().unwrap().push_back((args, status));
            self
        }

        pub(super) fn git_output(self, remote: &'static str, output: Output) -> Self {
            self.git_outputs.lock().unwrap().push_back((remote, output));
            self
        }
    }

    impl Gh for FakeGh {
        fn which_gh(&self) -> Option<PathBuf> {
            self.present.then(|| PathBuf::from("/usr/bin/gh"))
        }

        fn output(&self, args: &[&str]) -> Result<Output, String> {
            let (expected, output) = self
                .outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected gh output call");
            assert_eq!(args, expected);
            Ok(output)
        }

        fn status(&self, args: &[&str]) -> Result<std::process::ExitStatus, String> {
            let (expected, status) = self
                .statuses
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected gh status call");
            assert_eq!(args, expected);
            Ok(status)
        }

        fn git_ls_remote(&self, remote: &str) -> Result<Output, String> {
            let (expected, output) = self
                .git_outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected git ls-remote call");
            assert_eq!(remote, expected);
            Ok(output)
        }
    }

    pub(super) fn out(code: i32, stdout: &str, stderr: &str) -> Output {
        Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.as_bytes().to_vec(),
            stderr: stderr.as_bytes().to_vec(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn banked_config_dir_is_shared_across_hostnames() {
        let base = Path::new("/base");
        assert_eq!(
            gh_config_dir(base),
            Path::new("/base/auth/github/gh"),
            "one dir for all hostnames: GH_CONFIG_DIR is single-valued while hosts.yml is not"
        );
    }
}
