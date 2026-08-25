//! The satellite prerequisite probe: what one non-interactive ssh session can see.
//!
//! Assimilation is `ssh <dest> <script>` throughout, which is NOT a login shell. A
//! binary reachable only through `.bashrc` is not reachable here, so this probe
//! sources nothing and adds nothing to PATH: it must observe the PATH the real run
//! gets, not a friendlier one. Making the check pass by sourcing a profile would make
//! the probe lie in the other direction.
//!
//! The script always exits 0 and labels every line. Absence is then a parsed fact
//! rather than an exit status, which is what lets a failure name the missing binary:
//! the older `uname -sm && command -v node && command -v rsync` chain could only be
//! read by counting stdout lines, so it guessed which tool was missing and could not
//! see a third one at all.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::harnesses::HarnessCatalog;

const RUNTIME_BINARIES: [&str; 3] = ["node", "npm", "rsync"];
const ABSENT_BINARY: &str = "MISSING";
const ABSENT_BASE_DIR: &str = "ABSENT";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    /// Required to install and run Tight Beam's own plumbing on the satellite.
    Runtime,
    /// The vendor CLI a named harness invokes directly. Never installed by us.
    HarnessCli(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Requirement {
    pub binary: String,
    pub kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Observation {
    pub platform: String,
    pub binaries: Vec<(String, Option<String>)>,
    /// The base dir as the satellite resolves it, or None when it does not exist yet.
    pub base_dir: Option<String>,
}

impl Observation {
    fn path_of(&self, binary: &str) -> Option<&str> {
        self.binaries
            .iter()
            .find(|(name, _)| name == binary)
            .and_then(|(_, path)| path.as_deref())
    }
}

/// Every binary the run about to happen will invoke on the satellite.
///
/// The harness CLI names come from the harness projection, exactly like
/// `install_package`: which vendor binary a harness shells out to is the harness's
/// fact to state, not a literal for this CLI to carry.
pub fn requirements(catalog: &HarnessCatalog, harnesses: &[String]) -> Vec<Requirement> {
    let mut requirements = RUNTIME_BINARIES
        .iter()
        .map(|binary| Requirement {
            binary: (*binary).to_owned(),
            kind: Kind::Runtime,
        })
        .collect::<Vec<_>>();
    for harness in harnesses {
        let Some(projection) = catalog
            .harnesses
            .iter()
            .find(|candidate| candidate.wire_name == *harness)
        else {
            continue;
        };
        if requirements
            .iter()
            .any(|requirement| requirement.binary == projection.cli_binary)
        {
            continue;
        }
        requirements.push(Requirement {
            binary: projection.cli_binary.clone(),
            kind: Kind::HarnessCli(projection.wire_name.clone()),
        });
    }
    requirements
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

/// `remote_base_dir` is already shell-safe for the remote side (see `remote_path`),
/// so a leading `~` still expands. Reading it costs nothing here and is the only way
/// a dry run can report the resolved base dir as observed rather than as configured.
pub fn script(requirements: &[Requirement], remote_base_dir: &str) -> String {
    let names = requirements
        .iter()
        .map(|requirement| quote(&requirement.binary))
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "uname -sm; \
         for tb_binary in {names}; do \
         printf '%s %s\\n' \"$tb_binary\" \"$(command -v \"$tb_binary\" || echo {ABSENT_BINARY})\"; \
         done; \
         printf 'base-dir %s\\n' \"$(cd {remote_base_dir} 2>/dev/null && pwd || echo {ABSENT_BASE_DIR})\""
    )
}

pub fn parse(output: &str) -> Observation {
    let mut lines = output.lines().filter(|line| !line.trim().is_empty());
    let platform = lines.next().unwrap_or_default().trim().to_owned();
    let mut binaries = Vec::new();
    let mut base_dir = None;
    for line in lines {
        let Some((name, value)) = line.trim_end().split_once(' ') else {
            continue;
        };
        if name == "base-dir" {
            base_dir = (value != ABSENT_BASE_DIR).then(|| value.to_owned());
        } else {
            binaries.push((
                name.to_owned(),
                (value != ABSENT_BINARY).then(|| value.to_owned()),
            ));
        }
    }
    Observation {
        platform,
        binaries,
        base_dir,
    }
}

/// What the probe saw, in the operator's words. Reported whether or not the verdict
/// passes: a run that fails on `npm` should still show that `node` was found, so the
/// operator fixes the host once rather than one binary per attempt.
pub fn report(observation: &Observation) -> Vec<String> {
    let mut lines = vec![format!("  platform: {}", observation.platform)];
    for (name, path) in &observation.binaries {
        lines.push(format!(
            "  {name}: {}",
            path.as_deref().unwrap_or(ABSENT_BINARY)
        ));
    }
    lines.push(format!(
        "  base dir: {}",
        observation
            .base_dir
            .as_deref()
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| "absent (would be created)".to_owned())
    ));
    lines
}

/// Resolve `binary` against a PATH, the way execvp will.
///
/// Shared with the onboarding ceremonies: `assimilate` asks this question of a satellite
/// over ssh, `onboard` asks it of the machine the operator is sitting at, and both should
/// answer it the same way.
pub fn on_path(binary: &str, search_path: &str) -> Option<PathBuf> {
    search_path
        .split(':')
        .filter(|directory| !directory.is_empty())
        .map(|directory| Path::new(directory).join(binary))
        .find(|candidate| {
            fs::metadata(candidate)
                .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}

/// The same refusal as `verdict`, for a harness CLI missing on THIS machine.
///
/// An onboarding ceremony runs where the operator is, so the PATH that matters is this
/// process's rather than a non-interactive ssh session's -- but the rest of the prose is
/// deliberately the satellite wording. An operator who has read one of these should
/// recognise the other, and both refusals are about the same boundary: Tight Beam
/// installs its own plumbing, never the vendors' software.
pub fn missing_harness_cli(binary: &str, harness: &str, host: &str, search_path: &str) -> String {
    format!(
        "{binary} is missing on {host}: it is not on this shell's PATH. It is the CLI \
         harness {harness} invokes directly, and onboarding {harness} on this host \
         presupposes it -- Tight Beam installs its own plumbing (adapters, CLI, base dir) \
         and never the vendors' software. Install {binary} on {host} and re-run.\n\
         PATH searched: {search_path}"
    )
}

pub fn verdict(
    requirements: &[Requirement],
    observation: &Observation,
    ssh_dest: &str,
) -> Result<(), String> {
    if observation.platform.is_empty() {
        return Err(format!(
            "the probe returned nothing from {ssh_dest}; the satellite answered ssh but ran no shell"
        ));
    }
    let missing = requirements
        .iter()
        .filter(|requirement| observation.path_of(&requirement.binary).is_none())
        .collect::<Vec<_>>();
    if missing.is_empty() {
        return Ok(());
    }
    // One report naming every missing binary, not one paragraph each: the operator is
    // going to walk to that host once, and a probe that names only the first thing it
    // tripped over buys itself another round trip.
    let header = format!(
        "satellite {ssh_dest} is missing {} {}, yours to install rather than \
         assimilation's -- Tight Beam installs its own plumbing on a satellite \
         (adapters, CLI, base dir) and never the vendors' software. What counts is the \
         PATH a non-interactive ssh session sees; a tool reachable only from a login \
         shell profile does not. Install on {ssh_dest} and re-run:",
        missing.len(),
        if missing.len() == 1 {
            "prerequisite"
        } else {
            "prerequisites"
        }
    );
    Err(std::iter::once(header)
        .chain(missing.iter().map(|requirement| match &requirement.kind {
            Kind::Runtime => format!(
                "  {} -- needed to install and run Tight Beam's plumbing there",
                requirement.binary
            ),
            Kind::HarnessCli(harness) => format!(
                "  {} -- the CLI harness {harness} invokes directly; enabling {harness} on this host presupposes it",
                requirement.binary
            ),
        }))
        .collect::<Vec<_>>()
        .join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::harnesses::HarnessProjection;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn catalog() -> HarnessCatalog {
        HarnessCatalog {
            harnesses: [("claude", "claude-cli"), ("codex", "codex-cli")]
                .into_iter()
                .map(|(name, cli_binary)| HarnessProjection {
                    wire_name: name.to_owned(),
                    install_package: format!("{name}-package"),
                    cli_binary: cli_binary.to_owned(),
                    process_markers: Vec::new(),
                })
                .collect(),
        }
    }

    #[test]
    fn requirements_take_harness_cli_names_from_the_projection() {
        let selected = requirements(&catalog(), &["codex".to_owned()]);
        assert_eq!(
            selected
                .iter()
                .map(|requirement| requirement.binary.as_str())
                .collect::<Vec<_>>(),
            vec!["node", "npm", "rsync", "codex-cli"]
        );
        assert_eq!(
            selected[3].kind,
            Kind::HarnessCli("codex".to_owned()),
            "a harness CLI must stay distinguishable from a runtime prerequisite"
        );
        assert!(
            !requirements(&catalog(), &["codex".to_owned()])
                .iter()
                .any(|requirement| requirement.binary == "claude-cli"),
            "an unselected harness's CLI is not a prerequisite"
        );
    }

    /// npm was absent from the probe for as long as it has existed, though the very
    /// next step runs `npm install`. It is asserted by name so it cannot fall out
    /// again silently.
    #[test]
    fn npm_is_probed_because_the_adapter_install_needs_it() {
        assert!(
            requirements(&catalog(), &[])
                .iter()
                .any(|requirement| requirement.binary == "npm")
        );
    }

    #[test]
    fn script_reads_path_and_base_dir_without_writing_or_sourcing_anything() {
        let script = script(
            &requirements(&catalog(), &["claude".to_owned()]),
            "~/.tightbeam",
        );
        assert!(script.contains("command -v \"$tb_binary\""));
        assert!(script.contains("'claude-cli'"));
        assert!(script.contains("cd ~/.tightbeam 2>/dev/null && pwd"));
        for forbidden in ["bash -l", "--login", "source ", ". ~/", "mkdir", "install"] {
            assert!(
                !script.contains(forbidden),
                "the probe must not {forbidden}: it has to see what the real run sees, and it writes nothing"
            );
        }
    }

    #[test]
    fn parse_reads_labelled_lines_and_paths_containing_spaces() {
        let observation = parse(
            "Linux x86_64\nnode /usr/bin/node\nnpm MISSING\nrsync /opt/my tools/rsync\nbase-dir /home/flynn/.tightbeam\n",
        );
        assert_eq!(observation.platform, "Linux x86_64");
        assert_eq!(observation.path_of("node"), Some("/usr/bin/node"));
        assert_eq!(observation.path_of("npm"), None);
        assert_eq!(observation.path_of("rsync"), Some("/opt/my tools/rsync"));
        assert_eq!(
            observation.base_dir.as_deref(),
            Some("/home/flynn/.tightbeam")
        );
    }

    #[test]
    fn an_absent_base_dir_is_absent_rather_than_a_path_named_absent() {
        assert_eq!(parse("Darwin arm64\nbase-dir ABSENT\n").base_dir, None);
    }

    #[test]
    fn a_missing_harness_cli_names_the_binary_the_host_and_whose_job_it_is() {
        let requirements = requirements(&catalog(), &["claude".to_owned()]);
        let observation = parse("Linux x86_64\nnode /n\nnpm /np\nrsync /r\nclaude-cli MISSING\n");
        let reason = verdict(&requirements, &observation, "flynn@eurisko").unwrap_err();
        assert!(reason.contains("claude-cli"));
        assert!(reason.contains("flynn@eurisko"));
        assert!(reason.contains("harness claude"));
        assert!(reason.contains("never the vendors' software"));
        assert!(reason.contains("non-interactive ssh"));
    }

    #[test]
    fn every_missing_prerequisite_is_named_not_only_the_first() {
        let requirements = requirements(&catalog(), &["codex".to_owned()]);
        let observation =
            parse("Linux x86_64\nnode /n\nnpm MISSING\nrsync /r\ncodex-cli MISSING\n");
        let reason = verdict(&requirements, &observation, "eliza").unwrap_err();
        assert!(reason.contains("missing 2 prerequisites"), "{reason}");
        assert!(reason.contains("\n  npm "), "{reason}");
        assert!(reason.contains("\n  codex-cli "), "{reason}");
    }

    #[test]
    fn a_satisfied_host_passes_and_a_silent_one_does_not() {
        let requirements = requirements(&catalog(), &["codex".to_owned()]);
        assert_eq!(
            verdict(
                &requirements,
                &parse("Darwin arm64\nnode /n\nnpm /np\nrsync /r\ncodex-cli /c\nbase-dir ABSENT\n"),
                "eezo"
            ),
            Ok(())
        );
        assert!(verdict(&requirements, &parse(""), "eezo").is_err());
    }

    #[test]
    fn the_report_shows_what_was_found_and_what_was_not() {
        let lines = report(&parse(
            "Linux x86_64\nnode /usr/bin/node\nnpm MISSING\nbase-dir ABSENT\n",
        ));
        assert_eq!(lines[0], "  platform: Linux x86_64");
        assert_eq!(lines[1], "  node: /usr/bin/node");
        assert_eq!(lines[2], "  npm: MISSING");
        assert_eq!(lines[3], "  base dir: absent (would be created)");
    }

    /// Both refusals name the binary, the host, and the repair, and both say whose job
    /// the vendor's software is -- the point of sharing the prose with `verdict`.
    #[test]
    fn a_local_refusal_names_the_binary_the_host_the_path_and_the_repair() {
        let reason = missing_harness_cli("claude", "claude", "eurisko", "/usr/bin:/bin");
        assert!(
            reason.starts_with("claude is missing on eurisko"),
            "{reason}"
        );
        assert!(
            reason.contains("harness claude invokes directly"),
            "{reason}"
        );
        assert!(reason.contains("never the vendors' software"), "{reason}");
        assert!(
            reason.contains("Install claude on eurisko and re-run"),
            "{reason}"
        );
        assert!(reason.contains("PATH searched: /usr/bin:/bin"), "{reason}");
    }

    #[test]
    fn on_path_finds_only_executables_and_reports_where_it_looked() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam-on-path-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        fs::write(bin.join("runnable"), "#!/bin/sh\n").unwrap();
        fs::set_permissions(bin.join("runnable"), std::fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(bin.join("not-runnable"), "data").unwrap();
        fs::set_permissions(
            bin.join("not-runnable"),
            std::fs::Permissions::from_mode(0o644),
        )
        .unwrap();

        let path = bin.display().to_string();
        assert_eq!(on_path("runnable", &path), Some(bin.join("runnable")));
        assert_eq!(
            on_path("not-runnable", &path),
            None,
            "a readable file that cannot be executed is not on PATH for exec purposes"
        );
        assert_eq!(on_path("absent", &path), None);
        // An empty PATH entry must not be read as the current directory.
        assert_eq!(on_path("runnable", ""), None);
        fs::remove_dir_all(root).unwrap();
    }
}
