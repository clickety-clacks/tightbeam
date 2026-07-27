//! The single resolver for `base_dir` in the CLI — where the org lives.
//!
//! This is the Rust half of `Tightbeam.BaseDir`, and it must stay behaviourally
//! identical to it. The gateway WRITES `gateway.json` into the base dir it
//! resolved; the CLI READS it from the base dir it resolves. If the two disagree,
//! the CLI talks to a gateway the operator did not install — or to none at all.
//!
//! They did disagree. `Tightbeam.BaseDir` unified four Elixir resolvers on
//! 2026-07-27 and stopped there, because its invariant test scans `lib/` and the
//! CLI is structurally outside its reach. There were three more here, all of them
//! reading `TIGHTBEAM_HOME` and none of them reading `TIGHTBEAM_BASE_DIR` at all:
//!
//!   * `dispatch::gateway_config_path` — endpoint discovery
//!   * `probe::resolve_base_dir` — `tightbeam doctor` / containment census
//!   * `harnesses::home_dir` — the harness projection cache
//!
//! So with `TIGHTBEAM_BASE_DIR` set — which is what the README documents, and
//! what the systemd unit and LaunchDaemon in it both set — the CLI read
//! `~/.tightbeam/gateway.json`: not its own gateway, but whatever unrelated org
//! happened to live at the default path. Found on shrdlu, 2026-07-27, by the
//! production-install smoke: `tightbeam onboard anthropic` dialled port 4321 from
//! a pre-existing org while its own gateway was serving on 11373. Nothing was
//! listening there, so it failed loudly by luck; had that org been up, onboarding
//! would have banked a credential into a stranger's org and reported success.
//!
//! Precedence, matching `Tightbeam.BaseDir` exactly:
//!
//!   1. `TIGHTBEAM_BASE_DIR`
//!   2. `TIGHTBEAM_HOME`
//!   3. `<home>/.tightbeam`
//!
//! A variable that is SET BUT EMPTY wins and resolves to an empty path, which is
//! Elixir's behaviour (`System.get_env/1` returns `""`, and `"" || x` is `""`) and
//! was already `dispatch`'s. Treating empty as unset would be a third rule, and a
//! rule the gateway does not share is the whole defect being fixed here.

use std::path::{Path, PathBuf};

/// Resolve `base_dir` from the process environment.
pub fn resolve() -> PathBuf {
    #[allow(deprecated)]
    let home = std::env::home_dir().unwrap_or_default();
    resolve_with(&|name| std::env::var(name).ok(), &home)
}

/// Resolve `base_dir` against an injected environment — the testable form, and
/// the one `dispatch` already threads a closure through.
pub fn resolve_with<F>(get_env: &F, home_dir: &Path) -> PathBuf
where
    F: Fn(&str) -> Option<String>,
{
    get_env("TIGHTBEAM_BASE_DIR")
        .or_else(|| get_env("TIGHTBEAM_HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| default_in(home_dir))
}

/// The default when neither variable is set.
pub fn default_in(home_dir: &Path) -> PathBuf {
    home_dir.join(".tightbeam")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect();
        move |name: &str| map.get(name).cloned()
    }

    #[test]
    fn base_dir_wins_over_home_which_is_the_case_that_was_broken() {
        // The CLI never read TIGHTBEAM_BASE_DIR, so a service installed exactly as
        // the README documents got a CLI that looked for its gateway in a different
        // org — and `tightbeam onboard` is the first command the boot summary tells
        // the operator to run.
        assert_eq!(
            resolve_with(
                &env(&[
                    ("TIGHTBEAM_BASE_DIR", "/srv/from-base-dir"),
                    ("TIGHTBEAM_HOME", "/srv/from-home"),
                ]),
                Path::new("/home/someone"),
            ),
            PathBuf::from("/srv/from-base-dir")
        );
    }

    #[test]
    fn home_is_honoured_when_base_dir_is_unset() {
        assert_eq!(
            resolve_with(
                &env(&[("TIGHTBEAM_HOME", "/srv/from-home")]),
                Path::new("/home/someone"),
            ),
            PathBuf::from("/srv/from-home")
        );
    }

    #[test]
    fn falls_back_to_dot_tightbeam_under_home() {
        assert_eq!(
            resolve_with(&env(&[]), Path::new("/home/someone")),
            PathBuf::from("/home/someone/.tightbeam")
        );
        assert_eq!(
            default_in(Path::new("/home/someone")),
            PathBuf::from("/home/someone/.tightbeam")
        );
    }

    #[test]
    fn a_set_but_empty_variable_wins_and_is_empty_because_the_gateway_agrees() {
        // Not a nicety: Elixir resolves `TIGHTBEAM_BASE_DIR=""` to `""`, so the CLI
        // must too. Whatever this configuration means, both halves must mean the
        // same thing by it.
        assert_eq!(
            resolve_with(
                &env(&[("TIGHTBEAM_BASE_DIR", ""), ("TIGHTBEAM_HOME", "/srv/home")]),
                Path::new("/home/someone"),
            ),
            PathBuf::new()
        );
        assert_eq!(
            resolve_with(&env(&[("TIGHTBEAM_HOME", "")]), Path::new("/home/someone")),
            PathBuf::new()
        );
    }

    #[test]
    fn exactly_one_resolver_exists_in_the_cli() {
        // The Elixir suite asserts this over `lib/`, which is exactly why the CLI's
        // three resolvers survived that fix untouched. Same invariant, same reason,
        // enforced on this side of the language boundary where it can actually see.
        let mut readers = Vec::new();
        let mut stack = vec![PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src")];

        while let Some(directory) = stack.pop() {
            for entry in std::fs::read_dir(&directory).expect("cli/src is readable") {
                let path = entry.expect("readable dir entry").path();

                if path.is_dir() {
                    stack.push(path);
                    continue;
                }

                if path.extension().is_some_and(|ext| ext == "rs")
                    && path.file_name().is_some_and(|name| name != "base_dir.rs")
                {
                    let source = std::fs::read_to_string(&path).expect("readable source");

                    if ["TIGHTBEAM_BASE_DIR", "TIGHTBEAM_HOME"].iter().any(|var| {
                        source.contains(&format!("var(\"{var}\")"))
                            || source.contains(&format!("get_env(\"{var}\")"))
                    }) {
                        readers.push(path.display().to_string());
                    }
                }
            }
        }

        assert!(
            readers.is_empty(),
            "base_dir must be resolved only by crate::base_dir, but these files read \
             the environment directly: {readers:?}\n\n\
             Two resolvers can disagree, and when they did, `tightbeam onboard` \
             dispatched to an unrelated org's gateway. Call base_dir::resolve() or \
             base_dir::resolve_with() instead."
        );
    }
}
