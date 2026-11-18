//! Read the per-session statute set compiled by `Tightbeam.Rails`.
//!
//! The shared Elixir `Tightbeam.RailScope` matcher runs once when the session
//! workdir sidecar is provisioned. Hooks use this small reader only after the
//! statute's own pattern or action has matched, so an unrelated call never
//! depends on the sidecar or a runtime lookup.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

const SCOPE_FILE: &str = ".tightbeam-rail-scope.json";
const SESSION_FILE: &str = ".tightbeam-session";
const SESSION_WORKDIR_ENV: &str = "TIGHTBEAM_SESSION_WORKDIR";

/// Return success only when this statute appears in the calling session's
/// compiled scope set. An anchor captured by the adapter takes precedence, and
/// resolves to the nearest session marker above it; otherwise use the nearest
/// marker above the hook process cwd. Event cwd fields never select the scope.
pub fn run(args: &[String]) -> Result<bool, String> {
    let hook_cwd = env::current_dir()
        .map_err(|error| format!("could not resolve calling session workdir: {error}"))?;
    let explicit_path = env::var_os(SESSION_WORKDIR_ENV);
    let session_workdir =
        resolve_session_workdir(&hook_cwd, explicit_path.as_deref().map(Path::new))?;
    run_in(&session_workdir, args)
}

fn run_in(session_workdir: &Path, args: &[String]) -> Result<bool, String> {
    let [flag, statute] = args else {
        return Err("usage: tightbeam rail-scope-check --statute <qualified-name>".to_owned());
    };
    if flag != "--statute" || statute.is_empty() {
        return Err("usage: tightbeam rail-scope-check --statute <qualified-name>".to_owned());
    }

    compiled_statute_matches(session_workdir, statute)
}

fn resolve_session_workdir(
    hook_cwd: &Path,
    explicit_session_workdir: Option<&Path>,
) -> Result<PathBuf, String> {
    let explicit_path = explicit_session_workdir.filter(|path| !path.as_os_str().is_empty());

    match explicit_path {
        Some(path) => find_explicit_session_workdir(path),
        None => session_workdir_at_or_above(hook_cwd, "hook working directory"),
    }
}

fn find_explicit_session_workdir(path: &Path) -> Result<PathBuf, String> {
    if path.as_os_str().is_empty() || !path.is_absolute() {
        return Err(format!(
            "{SESSION_WORKDIR_ENV} must name an absolute session workdir"
        ));
    }

    session_workdir_at_or_above(path, SESSION_WORKDIR_ENV)
}

fn session_workdir_at_or_above(start_dir: &Path, source: &str) -> Result<PathBuf, String> {
    let start_dir = start_dir
        .canonicalize()
        .map_err(|error| format!("could not resolve {source}: {error}"))?;

    for directory in start_dir.ancestors() {
        let marker = directory.join(SESSION_FILE);

        match fs::symlink_metadata(&marker) {
            Ok(metadata) if metadata.file_type().is_file() => {
                return Ok(directory.to_path_buf());
            }
            Ok(_) => {
                return Err(format!(
                    "{SESSION_FILE} at {} is not a regular file",
                    marker.display()
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!("could not inspect {}: {error}", marker.display()));
            }
        }
    }

    Err(format!(
        "no {SESSION_FILE} was found at or above {source} {}",
        start_dir.display()
    ))
}

fn compiled_statute_matches(session_workdir: &Path, statute: &str) -> Result<bool, String> {
    let path = session_workdir.join(SCOPE_FILE);
    if !path.is_file() {
        return Err(format!(
            "{SCOPE_FILE} was not found in calling session workdir {}",
            session_workdir.display()
        ));
    }

    let bytes = fs::read_to_string(&path)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    let document: Value = serde_json::from_str(&bytes)
        .map_err(|error| format!("invalid {}: {error}", path.display()))?;
    let statutes = document
        .get("statutes")
        .and_then(Value::as_array)
        .ok_or_else(|| format!("{} has no statute array", path.display()))?;

    for item in statutes {
        if !item.is_string() {
            return Err(format!("{} has a non-string statute name", path.display()));
        }
    }

    Ok(statutes.iter().any(|item| item.as_str() == Some(statute)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_workdir() -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock follows epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("tightbeam-rail-scope-{suffix}"))
    }

    fn write_scope(workdir: &Path, archetype: &str, statutes: &[&str]) {
        fs::create_dir_all(workdir).expect("create session workdir");
        fs::write(workdir.join(SESSION_FILE), "fixture-session")
            .expect("write fixture session marker");
        let document = serde_json::json!({
            "archetype": archetype,
            "statutes": statutes,
        });
        fs::write(
            workdir.join(SCOPE_FILE),
            serde_json::to_string(&document).expect("serialize session scope"),
        )
        .expect("write session scope");
    }

    fn run_from_hook_cwd(hook_cwd: &Path, statute: &str) -> Result<bool, String> {
        let args = ["--statute".to_owned(), statute.to_owned()];
        let session_workdir = resolve_session_workdir(hook_cwd, None)?;
        run_in(&session_workdir, &args)
    }

    fn run_for_explicit_session(
        hook_cwd: &Path,
        session_workdir: &Path,
        statute: &str,
    ) -> Result<bool, String> {
        let args = ["--statute".to_owned(), statute.to_owned()];
        let session_workdir = resolve_session_workdir(hook_cwd, Some(session_workdir))?;
        run_in(&session_workdir, &args)
    }

    #[test]
    fn substrate_session_outside_tool_cwd_is_not_denied_by_its_scope() {
        let root = temporary_workdir();
        let session_workdir = root.join("substrate-session");
        let caller_project = session_workdir.join("repo/src");
        let tool_cwd = root.join("other-session/repo");
        write_scope(&session_workdir, "local-worker", &[]);
        write_scope(
            &tool_cwd,
            "agentic-engineering.coder",
            &["agentic-engineering.no-git-stash"],
        );
        fs::create_dir_all(&caller_project).expect("create caller project subdirectory");

        assert!(
            !run_for_explicit_session(
                &tool_cwd,
                &caller_project,
                "agentic-engineering.no-git-stash"
            )
            .expect("substrate session does not match the kungfu statute")
        );

        fs::remove_dir_all(root).expect("remove workdir");
    }

    #[test]
    fn nested_kungfu_session_uses_its_scope_instead_of_the_outer_workdir() {
        let root = temporary_workdir();
        let outer_session_workdir = root.join("substrate-session");
        let session_workdir = outer_session_workdir.join("nested-kungfu-session");
        let caller_project = session_workdir.join("repo/src");
        let event_cwd = outer_session_workdir.join("repo");
        write_scope(&outer_session_workdir, "local-worker", &[]);
        write_scope(
            &session_workdir,
            "agentic-engineering.coder",
            &["agentic-engineering.no-git-stash"],
        );
        fs::create_dir_all(&caller_project).expect("create caller project subdirectory");
        fs::create_dir_all(&event_cwd).expect("create event working directory");

        assert!(
            run_for_explicit_session(
                &event_cwd,
                &caller_project,
                "agentic-engineering.no-git-stash"
            )
            .expect("caller session includes the kungfu statute")
        );

        fs::remove_file(session_workdir.join(SCOPE_FILE)).expect("remove nested scope sidecar");
        assert!(
            run_for_explicit_session(
                &event_cwd,
                &caller_project,
                "agentic-engineering.no-git-stash"
            )
            .expect_err("a missing nested scope must not borrow the outer session sidecar")
            .contains("not found in calling session workdir")
        );

        fs::remove_dir_all(root).expect("remove workdir");
    }

    #[test]
    fn a_subdirectory_uses_the_nearest_session_sidecar() {
        let root = temporary_workdir();
        let session_workdir = root.join("session");
        let hook_cwd = session_workdir.join("repo/src");
        write_scope(
            &session_workdir,
            "agentic-engineering.coder",
            &["agentic-engineering.no-git-stash"],
        );
        fs::create_dir_all(&hook_cwd).expect("create hook subdirectory");

        assert!(
            run_from_hook_cwd(&hook_cwd, "agentic-engineering.no-git-stash")
                .expect("a subdirectory finds its session root sidecar")
        );

        fs::remove_dir_all(root).expect("remove workdir");
    }

    #[test]
    fn an_explicit_session_root_overrides_a_matching_hook_working_directory() {
        let root = temporary_workdir();
        let substrate_session = root.join("substrate-session");
        let other_session = root.join("other-session");
        write_scope(&substrate_session, "local-worker", &[]);
        write_scope(
            &other_session,
            "agentic-engineering.coder",
            &["agentic-engineering.no-git-stash"],
        );

        assert!(
            !run_for_explicit_session(
                &other_session,
                &substrate_session,
                "agentic-engineering.no-git-stash"
            )
            .expect("explicit caller root selects the substrate scope")
        );

        fs::remove_dir_all(root).expect("remove workdir");
    }

    #[test]
    fn an_empty_explicit_session_root_falls_back_to_nearest_marker() {
        let root = temporary_workdir();
        let session_workdir = root.join("session");
        let hook_cwd = session_workdir.join("repo/src");
        write_scope(
            &session_workdir,
            "agentic-engineering.coder",
            &["agentic-engineering.no-git-stash"],
        );
        fs::create_dir_all(&hook_cwd).expect("create hook subdirectory");

        let session_workdir =
            resolve_session_workdir(&hook_cwd, Some(Path::new(""))).expect("empty is absent");
        assert!(
            run_in(
                &session_workdir,
                &[
                    "--statute".to_owned(),
                    "agentic-engineering.no-git-stash".to_owned()
                ]
            )
            .expect("fallback reads nearest session scope")
        );

        fs::remove_dir_all(root).expect("remove workdir");
    }

    #[test]
    fn missing_or_malformed_session_scope_does_not_supply_a_statute_set() {
        let root = temporary_workdir();
        fs::create_dir_all(&root).expect("create workdir");

        assert!(compiled_statute_matches(&root, "named-statute").is_err());

        fs::write(root.join(SCOPE_FILE), "not json").expect("write malformed scope");
        assert!(compiled_statute_matches(&root, "named-statute").is_err());

        fs::write(
            root.join(SCOPE_FILE),
            r#"{"archetype":"agentic-engineering.coder"}"#,
        )
        .expect("write old scope schema");
        assert!(compiled_statute_matches(&root, "named-statute").is_err());

        fs::write(
            root.join(SCOPE_FILE),
            r#"{"archetype":"agentic-engineering.coder","statutes":[17]}"#,
        )
        .expect("write malformed statute set");
        assert!(compiled_statute_matches(&root, "named-statute").is_err());

        fs::remove_dir_all(root).expect("remove workdir");
    }
}
