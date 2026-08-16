use super::bank::Gh;
use super::probe::check_github_ready;

pub(super) fn check_tool_call_with(raw: &str, gh: &impl Gh) -> Result<(), String> {
    let texts = tool_call_strings(raw);
    let mut remotes = texts
        .iter()
        .filter(|text| has_git_operation(text) || looks_like_gh_repo_call(text))
        .flat_map(|text| github_remotes(text))
        .collect::<Vec<_>>();
    remotes.sort();
    remotes.dedup();

    let gh_repo = texts.iter().any(|text| looks_like_gh_repo_call(text));
    if remotes.is_empty() && !gh_repo {
        return Ok(());
    }

    if remotes.is_empty() {
        return check_github_ready("github.com", None, gh);
    }

    for remote in remotes {
        let hostname = github_hostname_from_remote(&remote).unwrap_or_else(|| "github.com".into());
        check_github_ready(&hostname, Some(&remote), gh)?;
    }
    Ok(())
}

// Only the command field of a Bash tool call IS an operation. Scanning every
// JSON string treated prompts, briefs, and descriptions as if they could run —
// and any such field beginning "Git clone the repo first..." sat at "command
// position" by construction. When the payload has no command field (a non-Bash
// hook shape, or non-JSON stdin), fall back to scanning everything: over-broad
// gating of an unknown shape beats silently ignoring it.
fn tool_call_strings(raw: &str) -> Vec<String> {
    match serde_json::from_str::<serde_json::Value>(raw) {
        Ok(value) => {
            if let Some(command) = value
                .pointer("/tool_input/command")
                .and_then(serde_json::Value::as_str)
            {
                return vec![command.to_owned()];
            }
            let mut strings = Vec::new();
            collect_json_strings(&value, &mut strings);
            strings.push(raw.to_owned());
            strings
        }
        Err(_) => vec![raw.to_owned()],
    }
}

fn collect_json_strings(value: &serde_json::Value, strings: &mut Vec<String>) {
    match value {
        serde_json::Value::String(value) => strings.push(value.clone()),
        serde_json::Value::Array(values) => {
            for value in values {
                collect_json_strings(value, strings);
            }
        }
        serde_json::Value::Object(map) => {
            for value in map.values() {
                collect_json_strings(value, strings);
            }
        }
        _ => {}
    }
}

// The guard judges operations, not mentions. A `tightbeam assign` whose brief
// says "read the gh issue thread at https://github.com/org/repo" performs no
// GitHub operation and must not be refused — that false positive blocked real
// org traffic on day one. Command-position matching under-matches by design
// (e.g. a gh call nested inside `sh -c "..."` slips through): for a hygiene
// gate the acceptable direction to be wrong in is letting gh fail at runtime
// with its own auth error, never blocking commands that merely talk about
// GitHub.
fn looks_like_gh_repo_call(text: &str) -> bool {
    has_operation(text, "gh ", &["repo", "pr", "issue", "api"])
}

fn has_git_operation(text: &str) -> bool {
    has_operation(
        text,
        "git ",
        &[
            "clone",
            "fetch",
            "pull",
            "push",
            "ls-remote",
            "remote",
            "submodule",
        ],
    )
}

fn has_operation(text: &str, program: &str, areas: &[&str]) -> bool {
    // Quoted spans are blanked before matching: a shell only executes what
    // sits outside quotes, so `--brief 'Fix it.\ngh pr view 123'` carries no
    // gh operation no matter how its prose is line-broken. The original text
    // still feeds remote extraction, where quoted URLs are legitimate
    // operands (`git clone 'https://…'`).
    let down = blank_quoted(text).to_ascii_lowercase();
    down.match_indices(program).any(|(idx, _)| {
        at_command_position(&down, idx)
            && areas.iter().any(|area| {
                let rest = down[idx + program.len()..].trim_start();
                rest.strip_prefix(area).is_some_and(|after| {
                    after.is_empty() || !after.starts_with(char::is_alphanumeric)
                })
            })
    })
}

fn blank_quoted(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for ch in text.chars() {
        match quote {
            Some(open) => {
                out.push(' ');
                if escaped {
                    escaped = false;
                } else if open == '"' && ch == '\\' {
                    escaped = true;
                } else if ch == open {
                    quote = None;
                }
            }
            None => {
                if ch == '\'' || ch == '"' {
                    quote = Some(ch);
                    out.push(' ');
                } else {
                    out.push(ch);
                }
            }
        }
    }
    // An unterminated quote blanks to the end — under-matching, the
    // acceptable direction.
    out
}

// Command position: everything between the last shell connector and the
// candidate program must be an env assignment (`GIT_TERMINAL_PROMPT=0 git
// clone …` is the single most common agent invocation shape) or a plain
// command wrapper. An empty span — string start or right after a connector —
// qualifies trivially.
fn at_command_position(text: &str, idx: usize) -> bool {
    let span_start = text[..idx]
        .rfind([';', '&', '|', '(', '{', '\n', '`'])
        .map_or(0, |connector| connector + 1);
    text[span_start..idx].split_whitespace().all(|token| {
        is_env_assignment(token)
            || matches!(
                token,
                "env" | "command" | "exec" | "time" | "nohup" | "xargs"
            )
    })
}

fn is_env_assignment(token: &str) -> bool {
    token.split_once('=').is_some_and(|(name, _value)| {
        !name.is_empty()
            && !name.starts_with(|ch: char| ch.is_ascii_digit())
            && name
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
    })
}

fn github_remotes(text: &str) -> Vec<String> {
    let mut remotes = Vec::new();
    for prefix in [
        "https://github.com/",
        "http://github.com/",
        "ssh://git@github.com/",
        "git@github.com:",
    ] {
        for value in prefixed_values(text, prefix) {
            let value = value
                .trim_matches(|ch: char| matches!(ch, '.' | ',' | ')' | ']' | '}'))
                .to_owned();
            if repo_shaped(value.strip_prefix(prefix).unwrap_or(&value)) {
                remotes.push(value);
            }
        }
    }
    remotes
}

// Only owner/repo-shaped paths are candidate git remotes. A command whose
// comment links https://github.com/org/repo/pull/123 must not have that page
// URL ls-remote'd — the probe would fail and refuse a valid command on a
// fully live host.
fn repo_shaped(path: &str) -> bool {
    if path.ends_with(".git") {
        return true;
    }
    path.split('/')
        .filter(|segment| !segment.is_empty())
        .count()
        == 2
}

fn prefixed_values(text: &str, prefix: &str) -> Vec<String> {
    let mut values = Vec::new();
    let mut search_from = 0;
    while let Some(offset) = text[search_from..].find(prefix) {
        let start = search_from + offset;
        let tail = &text[start..];
        let end = tail
            .char_indices()
            .find_map(|(index, ch)| remote_boundary(ch).then_some(index))
            .unwrap_or(tail.len());
        values.push(tail[..end].to_owned());
        search_from = start + end.max(prefix.len());
        if search_from >= text.len() {
            break;
        }
    }
    values
}

fn remote_boundary(ch: char) -> bool {
    ch.is_whitespace()
        || matches!(
            ch,
            '"' | '\'' | '\\' | '`' | '<' | '>' | '(' | ')' | '[' | ']' | '{' | '}' | ';'
        )
}

fn github_hostname_from_remote(remote: &str) -> Option<String> {
    if remote.starts_with("git@github.com:") {
        return Some("github.com".to_owned());
    }
    let after_scheme = remote.split_once("://").map(|(_, rest)| rest)?;
    let host_and_path = after_scheme
        .split_once('@')
        .map(|(_, rest)| rest)
        .unwrap_or(after_scheme);
    let host = host_and_path.split('/').next()?.split(':').next()?;
    (host == "github.com" || host.ends_with(".github.com")).then(|| host.to_owned())
}

#[cfg(test)]
mod tests {
    use super::super::test_support::{FakeGh, out};
    use super::*;

    #[test]
    fn tool_call_guard_ignores_non_github_commands() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {"command": "git status && ls"}
        })
        .to_string();

        check_tool_call_with(&raw, &FakeGh::new(false)).unwrap();
    }

    #[test]
    fn tool_call_guard_proves_github_remote_before_git_runs() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "git clone https://github.com/org/repo.git"
            }
        })
        .to_string();
        let gh = FakeGh::new(true)
            .output(
                &["auth", "status", "--active", "--hostname", "github.com"],
                out(0, "", ""),
            )
            .output(
                &["api", "--hostname", "github.com", "user", "--jq", ".login"],
                out(0, "octo\n", ""),
            )
            .output(&["config", "get", "git_protocol"], out(0, "https\n", ""))
            .git_output("https://github.com/org/repo.git", out(0, "abc\tHEAD\n", ""));

        check_tool_call_with(&raw, &gh).unwrap();
    }

    #[test]
    fn tool_call_guard_refuses_github_without_cli_before_pat_prompt() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "git clone https://github.com/org/repo.git"
            }
        })
        .to_string();

        let error = check_tool_call_with(&raw, &FakeGh::new(false)).unwrap_err();
        assert!(error.contains("Tightbeam cannot use GitHub"));
        assert!(error.contains("tightbeam onboard github --hostname github.com"));
        assert!(error.contains("--remote https://github.com/org/repo.git"));
        assert!(error.contains("Do not paste a PAT into an agent"));
    }

    #[test]
    fn tool_call_guard_ignores_github_mentions_that_are_not_operations() {
        // A refusal here would block org traffic whose *prose* names GitHub —
        // the exact false positive that hit `tightbeam assign --brief` on the
        // first live project. FakeGh::new(false) has no gh at all, so any probe
        // attempt would refuse: Ok proves no probe ran.
        for command in [
            "tightbeam assign --subject work --brief 'read the gh issue thread \
             at https://github.com/org/repo and summarize'",
            "echo see https://github.com/org/repo.git for details",
            "tightbeam wake --role coder --prompt 'fork https://github.com/org/repo, \
             then gh pr create'",
            // Multi-line brief: the newline must not promote quoted prose to
            // command position.
            "tightbeam assign --brief 'Fix the flaky test.\ngh pr view 123 has context'",
            // Sentence-initial imperatives inside quoted prose.
            "tightbeam assign --brief 'Git clone the repo first, then review'",
            "tightbeam dispatch --subject fix --brief 'GH issue 5; gh pr list shows the rest'",
            // A comment linking a non-repo GitHub page URL is not a remote.
            "gh_wrapper --note 'context: https://github.com/org/repo/pull/123'",
        ] {
            let raw = serde_json::json!({
                "tool_name": "Bash",
                "tool_input": {"command": command}
            })
            .to_string();
            assert_eq!(
                check_tool_call_with(&raw, &FakeGh::new(false)),
                Ok(()),
                "mention-only command must not be probed: {command}"
            );
        }
    }

    #[test]
    fn tool_call_guard_judges_only_the_command_field() {
        // Prompts, briefs, and descriptions ride alongside the command in the
        // tool-call JSON; only tool_input.command can run.
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "ls -la",
                "description": "List files before we git clone https://github.com/org/repo.git"
            }
        })
        .to_string();
        assert_eq!(check_tool_call_with(&raw, &FakeGh::new(false)), Ok(()));
    }

    #[test]
    fn tool_call_guard_gates_env_prefixed_operations() {
        // `NAME=value git …` is the most common agent invocation shape; it
        // must not slip past the gate.
        for command in [
            "GIT_TERMINAL_PROMPT=0 git clone https://github.com/org/repo.git",
            "GH_PAGER=cat gh pr view 1 --repo org/repo",
            "env GIT_SSH_COMMAND='ssh -i key' git fetch https://github.com/org/repo.git",
        ] {
            let raw = serde_json::json!({
                "tool_name": "Bash",
                "tool_input": {"command": command}
            })
            .to_string();
            let error = check_tool_call_with(&raw, &FakeGh::new(false)).unwrap_err();
            assert!(
                error.contains("Tightbeam cannot use GitHub"),
                "env-prefixed operation must be gated: {command}"
            );
        }
    }

    #[test]
    fn tool_call_guard_still_refuses_operations_after_shell_connectors() {
        for command in [
            "cd /work && git clone https://github.com/org/repo.git",
            "true; gh issue list --repo org/repo",
            "git fetch https://github.com/org/repo.git | cat",
        ] {
            let raw = serde_json::json!({
                "tool_name": "Bash",
                "tool_input": {"command": command}
            })
            .to_string();
            let error = check_tool_call_with(&raw, &FakeGh::new(false)).unwrap_err();
            assert!(
                error.contains("Tightbeam cannot use GitHub"),
                "operation must still be gated: {command}"
            );
        }
    }
}
