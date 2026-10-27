//! `tightbeam skill`: the external-agent skills that ship with this release.
//!
//! The skill files live in `priv/skills/` and are compiled into this binary, so the
//! CLI always carries exactly the edition written for its own version. Installing
//! copies them into an agent's user skills directory; nothing here talks to a gateway.

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

/// Each shipped external-agent skill: its directory name and its SKILL.md bytes.
pub const SHIPPED: &[(&str, &str)] = &[
    (
        "tightbeam-cli",
        include_str!("../../priv/skills/tightbeam-cli/SKILL.md"),
    ),
    (
        "tightbeam-operator",
        include_str!("../../priv/skills/tightbeam-operator/SKILL.md"),
    ),
];

const STAMP_PREFIX: &str = "Written for Tightbeam ";
const USAGE: &str =
    "usage: tightbeam skill list | tightbeam skill install [--skill <name>] [--dir <skillsDir>]";

/// A harness whose user skills directory `skill install` fills by default: its name,
/// the environment variable that relocates its configuration directory, and the
/// directory's default name under the home directory.
const DEFAULT_HARNESS_DIRS: &[(&str, &str, &str)] = &[
    ("claude", "CLAUDE_CONFIG_DIR", ".claude"),
    ("codex", "CODEX_HOME", ".codex"),
];

/// The Tightbeam version a skill says it was written for.
pub fn stamped_version(skill: &str) -> Option<&str> {
    skill.lines().find_map(|line| {
        let rest = line.strip_prefix(STAMP_PREFIX)?;
        let token = rest.split_whitespace().next()?;
        Some(token.strip_suffix('.').unwrap_or(token))
    })
}

fn description(skill: &str) -> Option<&str> {
    let frontmatter = skill.strip_prefix("---\n")?.split("\n---\n").next()?;
    frontmatter
        .lines()
        .find_map(|line| line.strip_prefix("description: "))
}

pub fn run(args: &[String]) -> Result<(), String> {
    let output = match args.first().map(String::as_str) {
        Some("list") if args.len() == 1 => list(),
        Some("install") => {
            let (selected, dir) = parse_install(&args[1..])?;
            let targets = match dir {
                Some(dir) => vec![Target {
                    label: "dir".to_owned(),
                    skills_dir: PathBuf::from(dir),
                }],
                None => {
                    let (targets, skipped) = default_targets(&|name| std::env::var_os(name));
                    if targets.is_empty() {
                        return Err(format!(
                            "skill install: no agent configuration directory found ({}); pass --dir <skillsDir>",
                            skipped.join("; ")
                        ));
                    }
                    targets
                }
            };
            install(&selected, &targets)?
        }
        _ => return Err(USAGE.to_owned()),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&output).expect("skill output serializes")
    );
    Ok(())
}

fn list() -> Value {
    json!({
        "version": env!("CARGO_PKG_VERSION"),
        "skills": SHIPPED
            .iter()
            .map(|(name, bytes)| json!({
                "name": name,
                "writtenFor": stamped_version(bytes),
                "description": description(bytes),
            }))
            .collect::<Vec<_>>(),
    })
}

fn parse_install(args: &[String]) -> Result<(Vec<&'static str>, Option<String>), String> {
    let mut skill = None;
    let mut dir = None;
    let mut index = 0;
    while index < args.len() {
        let slot = match args[index].as_str() {
            "--skill" => &mut skill,
            "--dir" => &mut dir,
            _ => return Err(USAGE.to_owned()),
        };
        match args.get(index + 1) {
            Some(value) if !value.is_empty() && slot.is_none() => *slot = Some(value.clone()),
            _ => return Err(USAGE.to_owned()),
        }
        index += 2;
    }
    let selected = match skill {
        None => SHIPPED.iter().map(|(name, _)| *name).collect(),
        Some(wanted) => match SHIPPED.iter().find(|(name, _)| *name == wanted) {
            Some((name, _)) => vec![*name],
            None => {
                return Err(format!(
                    "skill install: no shipped skill named '{wanted}' (shipped: {})",
                    SHIPPED
                        .iter()
                        .map(|(name, _)| *name)
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
        },
    };
    Ok((selected, dir))
}

#[derive(Debug, PartialEq)]
struct Target {
    label: String,
    skills_dir: PathBuf,
}

/// The skills directory of each default harness whose configuration directory exists.
/// A harness that is not set up on this machine is skipped, never created.
fn default_targets(env: &dyn Fn(&str) -> Option<std::ffi::OsString>) -> (Vec<Target>, Vec<String>) {
    let home = env("HOME").filter(|value| !value.is_empty());
    let mut targets = Vec::new();
    let mut skipped = Vec::new();
    for (harness, variable, default_name) in DEFAULT_HARNESS_DIRS {
        let config_dir = match env(variable).filter(|value| !value.is_empty()) {
            Some(dir) => PathBuf::from(dir),
            None => match &home {
                Some(home) => Path::new(home).join(default_name),
                None => {
                    skipped.push(format!("{harness}: HOME is not set"));
                    continue;
                }
            },
        };
        if config_dir.is_dir() {
            targets.push(Target {
                label: (*harness).to_owned(),
                skills_dir: config_dir.join("skills"),
            });
        } else {
            skipped.push(format!("{harness}: {} not found", config_dir.display()));
        }
    }
    (targets, skipped)
}

fn install(selected: &[&str], targets: &[Target]) -> Result<Value, String> {
    let mut installed = Vec::new();
    for target in targets {
        for name in selected {
            let (_, bytes) = SHIPPED
                .iter()
                .find(|(shipped, _)| shipped == name)
                .expect("selected skills are shipped");
            let directory = target.skills_dir.join(name);
            let path = directory.join("SKILL.md");
            let previous = fs::read_to_string(&path)
                .ok()
                .map(|text| stamped_version(&text).map(str::to_owned));
            fs::create_dir_all(&directory)
                .map_err(|error| format!("skill install: {}: {error}", directory.display()))?;
            let staged = directory.join(format!(".SKILL.md.{}", std::process::id()));
            fs::write(&staged, bytes)
                .and_then(|()| fs::rename(&staged, &path))
                .map_err(|error| {
                    let _ = fs::remove_file(&staged);
                    format!("skill install: {}: {error}", path.display())
                })?;
            installed.push(json!({
                "target": target.label,
                "skill": name,
                "path": path.display().to_string(),
                "writtenFor": stamped_version(bytes),
                "replaced": previous.is_some(),
                "previousWrittenFor": previous.flatten(),
            }));
        }
    }
    Ok(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "installed": installed,
        "next": "Start a fresh agent session so it loads the installed skills.",
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tightbeam-skill-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn every_shipped_skill_is_stamped_with_this_cli_version() {
        for (name, bytes) in SHIPPED {
            assert_eq!(
                stamped_version(bytes),
                Some(env!("CARGO_PKG_VERSION")),
                "{name} must say it was written for this release; re-check it against \
                 `tightbeam --help` and update its stamp"
            );
            assert!(bytes.starts_with(&format!("---\nname: {name}\n")));
            assert!(description(bytes).is_some_and(|text| !text.is_empty()));
        }
    }

    #[test]
    fn install_writes_each_skill_and_reports_what_it_replaced() {
        let root = scratch("install");
        let target = Target {
            label: "dir".to_owned(),
            skills_dir: root.join("skills"),
        };
        let older = root.join("skills/tightbeam-cli");
        fs::create_dir_all(&older).unwrap();
        fs::write(older.join("SKILL.md"), "Written for Tightbeam 0.0.1.\n").unwrap();
        fs::write(older.join("notes.txt"), "kept").unwrap();

        let (selected, _) = parse_install(&[]).unwrap();
        let output = install(&selected, &[target]).unwrap();
        let rows = output["installed"].as_array().unwrap();
        assert_eq!(rows.len(), SHIPPED.len());
        assert_eq!(rows[0]["previousWrittenFor"], "0.0.1");
        assert_eq!(rows[1]["replaced"], false);
        for (name, bytes) in SHIPPED {
            let written = fs::read_to_string(root.join("skills").join(name).join("SKILL.md"));
            assert_eq!(written.unwrap(), *bytes);
        }
        assert_eq!(fs::read_to_string(older.join("notes.txt")).unwrap(), "kept");
        let leftovers = fs::read_dir(&older)
            .unwrap()
            .filter(|entry| {
                entry
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".SKILL")
            })
            .count();
        assert_eq!(leftovers, 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn install_selects_one_skill_and_refuses_unknown_names_and_flags() {
        let (selected, dir) = parse_install(&[
            "--skill".to_owned(),
            "tightbeam-operator".to_owned(),
            "--dir".to_owned(),
            "/x".to_owned(),
        ])
        .unwrap();
        assert_eq!(selected, vec!["tightbeam-operator"]);
        assert_eq!(dir.as_deref(), Some("/x"));
        assert!(parse_install(&["--skill".to_owned(), "nope".to_owned()]).is_err());
        assert!(parse_install(&["--force".to_owned()]).is_err());
        assert!(parse_install(&["--dir".to_owned()]).is_err());
    }

    #[test]
    fn default_targets_only_existing_harness_directories() {
        let home = scratch("home");
        fs::create_dir_all(home.join(".claude")).unwrap();
        let relocated = home.join("elsewhere");
        fs::create_dir_all(&relocated).unwrap();
        let home_value = home.clone().into_os_string();

        let (targets, skipped) = default_targets(&|name| match name {
            "HOME" => Some(home_value.clone()),
            _ => None,
        });
        assert_eq!(
            targets,
            vec![Target {
                label: "claude".to_owned(),
                skills_dir: home.join(".claude/skills"),
            }]
        );
        assert_eq!(skipped.len(), 1);
        assert!(!home.join(".codex").exists());

        let relocated_value = relocated.clone().into_os_string();
        let (targets, _) = default_targets(&|name| match name {
            "HOME" => Some(home_value.clone()),
            "CODEX_HOME" => Some(relocated_value.clone()),
            _ => None,
        });
        assert_eq!(targets[1].skills_dir, relocated.join("skills"));
        fs::remove_dir_all(home).unwrap();
    }
}
