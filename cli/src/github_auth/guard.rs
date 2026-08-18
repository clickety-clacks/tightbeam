use super::bank::Gh;
use super::probe::check_github_ready;

pub(super) fn check_tool_call_with(raw: &str, gh: &impl Gh) -> Result<(), String> {
    let mut remotes = Vec::new();
    let mut gh_repo = false;

    for text in tool_call_strings(raw) {
        for command in executable_commands(&text) {
            gh_repo |= looks_like_gh_repo_call(&command);

            let Some((verb, args)) = git_operation(&command) else {
                continue;
            };

            let mut operation_remotes = args
                .iter()
                .flat_map(|arg| github_remotes(arg))
                .collect::<Vec<_>>();

            let submodule_network = verb == "submodule" && submodule_network_operation(args);
            if operation_remotes.is_empty() && submodule_network {
                for url in gh.git_submodule_urls()? {
                    operation_remotes.extend(github_remotes(&url));
                }
            }

            if operation_remotes.is_empty() {
                let operand = git_remote_operand(verb, args);
                let remote_name = match operand {
                    Some(value) if is_named_remote(value) => Some(value),
                    None if matches!(verb, "fetch" | "pull" | "push") || submodule_network => {
                        Some("origin")
                    }
                    _ => None,
                };

                if let Some(name) = remote_name {
                    if let Some(url) = gh.git_remote_url(name)? {
                        operation_remotes.extend(github_remotes(&url));
                    }
                }
            }

            remotes.extend(operation_remotes);
        }
    }

    remotes.sort();
    remotes.dedup();

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

fn is_env_assignment(token: &str) -> bool {
    token.split_once('=').is_some_and(|(name, _value)| {
        !name.is_empty()
            && !name.starts_with(|ch: char| ch.is_ascii_digit())
            && name
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
    })
}

// The guard represents executable shell commands as words. Quoted arguments
// remain arguments, nested `sh -c` scripts are parsed recursively, and here-doc
// bodies are removed before tokenization. That is the distinction the rail
// needs: operations can be gated while briefs, prompts, and data stay data.
fn executable_commands(text: &str) -> Vec<Vec<String>> {
    let text = strip_heredoc_bodies(text);
    let mut expanded = Vec::new();
    for command in tokenize_commands(&text) {
        if let Some(script) = nested_shell_script(&command) {
            expanded.extend(executable_commands(script));
        } else {
            expanded.push(command);
        }
    }
    expanded
}

fn nested_shell_script(command: &[String]) -> Option<&str> {
    let command = normalized_command(command);
    let program = command.first()?.rsplit('/').next()?;
    if !matches!(program, "sh" | "bash" | "dash" | "zsh" | "ksh") {
        return None;
    }

    command.windows(2).find_map(|pair| {
        let flag = pair[0].as_str();
        (flag == "-c" || (flag.starts_with('-') && flag[1..].contains('c')))
            .then_some(pair[1].as_str())
    })
}

fn looks_like_gh_repo_call(command: &[String]) -> bool {
    let command = normalized_command(command);
    command
        .first()
        .and_then(|program| program.rsplit('/').next())
        .is_some_and(|program| program == "gh")
        && command[1..]
            .iter()
            .any(|word| matches!(word.as_str(), "repo" | "pr" | "issue" | "api"))
}

fn git_operation(command: &[String]) -> Option<(&str, &[String])> {
    let command = normalized_command(command);
    if command.first()?.rsplit('/').next()? != "git" {
        return None;
    }

    let mut index = 1;
    while index < command.len() {
        let word = command[index].as_str();
        if matches!(
            word,
            "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace"
        ) {
            index += 2;
        } else if word.starts_with('-') {
            index += 1;
        } else {
            break;
        }
    }

    let verb = command.get(index)?.as_str();
    matches!(
        verb,
        "clone" | "fetch" | "pull" | "push" | "ls-remote" | "remote" | "submodule"
    )
    .then_some((verb, &command[index + 1..]))
}

fn git_remote_operand<'a>(verb: &str, args: &'a [String]) -> Option<&'a str> {
    if !matches!(verb, "clone" | "fetch" | "pull" | "push" | "ls-remote") {
        return None;
    }

    let value_options = [
        "-b",
        "--branch",
        "-c",
        "--config",
        "--depth",
        "--deepen",
        "--filter",
        "--jobs",
        "--origin",
        "-o",
        "--push-option",
        "--refmap",
        "--server-option",
        "--shallow-exclude",
        "--shallow-since",
        "--upload-pack",
    ];
    let mut skip_value = false;
    for word in args {
        if skip_value {
            skip_value = false;
            continue;
        }
        if word == "--" {
            continue;
        }
        if word.starts_with('-') {
            skip_value = value_options.contains(&word.as_str()) && !word.contains('=');
            continue;
        }
        return Some(word);
    }
    None
}

fn submodule_network_operation(args: &[String]) -> bool {
    args.iter()
        .find(|word| !word.starts_with('-'))
        .is_some_and(|word| matches!(word.as_str(), "add" | "update"))
}

fn is_named_remote(value: &str) -> bool {
    !value.is_empty()
        && !value.contains("://")
        && !value.starts_with("git@")
        && !value.starts_with('.')
        && !value.starts_with('/')
        && !value.contains('/')
}

fn normalized_command(command: &[String]) -> &[String] {
    let mut index = 0;
    loop {
        loop {
            if command
                .get(index)
                .is_some_and(|word| is_env_assignment(word))
            {
                index += 1;
                continue;
            }
            let width = leading_redirection_width(command, index);
            if width > 0 {
                index += width;
                continue;
            }
            break;
        }

        let Some(program) = command.get(index).and_then(|word| word.rsplit('/').next()) else {
            return &command[command.len()..];
        };
        match program {
            "env" => {
                index += 1;
                while command
                    .get(index)
                    .is_some_and(|word| word.starts_with('-') || is_env_assignment(word))
                {
                    index += 1;
                }
            }
            "command" | "exec" | "time" | "nohup" | "xargs" => {
                index += 1;
                while command.get(index).is_some_and(|word| word.starts_with('-')) {
                    index += 1;
                }
            }
            _ => return &command[index..],
        }
    }
}

fn leading_redirection_width(command: &[String], index: usize) -> usize {
    let Some(word) = command.get(index) else {
        return 0;
    };
    let redirect = word.trim_start_matches(|ch: char| ch.is_ascii_digit());
    for operator in ["<<<", "<<-", "<<", ">>", "<>", ">|", ">", "<"] {
        if redirect == operator {
            return if command.get(index + 1).is_some() {
                2
            } else {
                1
            };
        }
        if redirect
            .strip_prefix(operator)
            .is_some_and(|target| !target.is_empty())
        {
            return 1;
        }
    }
    0
}

fn strip_heredoc_bodies(text: &str) -> String {
    let mut pending = std::collections::VecDeque::<(String, bool)>::new();
    let mut stripped = String::with_capacity(text.len());

    for line in text.split_inclusive('\n') {
        if let Some((delimiter, strip_tabs)) = pending.front() {
            let candidate = line.trim_end_matches('\n').trim_end_matches('\r');
            let candidate = if *strip_tabs {
                candidate.trim_start_matches('\t')
            } else {
                candidate
            };
            if candidate == delimiter {
                pending.pop_front();
            }
            if line.ends_with('\n') {
                stripped.push('\n');
            }
            continue;
        }

        stripped.push_str(line);
        pending.extend(heredoc_delimiters(line));
    }
    stripped
}

fn heredoc_delimiters(line: &str) -> Vec<(String, bool)> {
    let chars = line.chars().collect::<Vec<_>>();
    let mut delimiters = Vec::new();
    let mut quote = None;
    let mut escaped = false;
    let mut index = 0;

    while index < chars.len() {
        let ch = chars[index];
        if let Some(open) = quote {
            if escaped {
                escaped = false;
            } else if open == '"' && ch == '\\' {
                escaped = true;
            } else if ch == open {
                quote = None;
            }
            index += 1;
            continue;
        }
        if matches!(ch, '\'' | '"') {
            quote = Some(ch);
            index += 1;
            continue;
        }
        if ch != '<' || chars.get(index + 1) != Some(&'<') || chars.get(index + 2) == Some(&'<') {
            index += 1;
            continue;
        }

        index += 2;
        let strip_tabs = chars.get(index) == Some(&'-');
        if strip_tabs {
            index += 1;
        }
        while chars.get(index).is_some_and(|ch| ch.is_whitespace()) {
            index += 1;
        }

        let mut delimiter = String::new();
        let mut delimiter_quote = None;
        while let Some(&ch) = chars.get(index) {
            if let Some(open) = delimiter_quote {
                if ch == open {
                    delimiter_quote = None;
                } else {
                    delimiter.push(ch);
                }
            } else if matches!(ch, '\'' | '"') {
                delimiter_quote = Some(ch);
            } else if ch.is_whitespace() || matches!(ch, ';' | '&' | '|') {
                break;
            } else {
                delimiter.push(ch);
            }
            index += 1;
        }
        if !delimiter.is_empty() {
            delimiters.push((delimiter, strip_tabs));
        }
    }
    delimiters
}

fn tokenize_commands(text: &str) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    let mut command = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut comment = false;

    for ch in text.chars() {
        if comment {
            if ch == '\n' {
                push_word(&mut command, &mut word);
                push_command(&mut commands, &mut command);
                comment = false;
            }
            continue;
        }

        if let Some(open) = quote {
            if escaped {
                word.push(ch);
                escaped = false;
            } else if open == '"' && ch == '\\' {
                escaped = true;
            } else if ch == open {
                quote = None;
            } else {
                word.push(ch);
            }
            continue;
        }

        if escaped {
            word.push(ch);
            escaped = false;
            continue;
        }

        match ch {
            '\\' => escaped = true,
            '\'' | '"' => quote = Some(ch),
            '#' if word.is_empty() => comment = true,
            '\n' => {
                push_word(&mut command, &mut word);
                push_command(&mut commands, &mut command);
            }
            ch if ch.is_whitespace() => push_word(&mut command, &mut word),
            ';' | '&' | '|' | '(' | ')' | '{' | '}' | '`' => {
                push_word(&mut command, &mut word);
                push_command(&mut commands, &mut command);
            }
            _ => word.push(ch),
        }
    }
    if escaped {
        word.push('\\');
    }
    push_word(&mut command, &mut word);
    push_command(&mut commands, &mut command);
    commands
}

fn push_word(command: &mut Vec<String>, word: &mut String) {
    if !word.is_empty() {
        command.push(std::mem::take(word));
    }
}

fn push_command(commands: &mut Vec<Vec<String>>, command: &mut Vec<String>) {
    if !command.is_empty() {
        commands.push(std::mem::take(command));
    }
}

fn github_remotes(text: &str) -> Vec<String> {
    parse_github_remote(text)
        .map(|remote| vec![remote.original])
        .unwrap_or_default()
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedGithubRemote {
    original: String,
    hostname: String,
}

fn parse_github_remote(text: &str) -> Option<ParsedGithubRemote> {
    let original = text
        .trim()
        .trim_matches(|ch: char| matches!(ch, '(' | ')' | '[' | ']' | '{' | '}' | ',' | '.'));
    let scp_url;
    let parseable = if original.contains("://") {
        original
    } else {
        let (authority, path) = original.split_once(':')?;
        scp_url = format!("ssh://{authority}/{path}");
        &scp_url
    };

    let parsed = ureq::get(parseable).request_url().ok()?;
    if !matches!(parsed.scheme(), "git" | "http" | "https" | "ssh") {
        return None;
    }
    let hostname = github_hostname(parsed.host())?;
    Some(ParsedGithubRemote {
        original: original.to_owned(),
        hostname,
    })
}

fn github_hostname(host: &str) -> Option<String> {
    let hostname = host.trim_end_matches('.').to_ascii_lowercase();
    (hostname == "github.com" || hostname.ends_with(".github.com")).then_some(hostname)
}

fn github_hostname_from_remote(remote: &str) -> Option<String> {
    parse_github_remote(remote).map(|remote| remote.hostname)
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

    #[test]
    fn tool_call_guard_resolves_named_github_remotes_before_fetch() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {"command": "git fetch origin"}
        })
        .to_string();
        let gh = FakeGh::new(false).remote_url("origin", Some("https://github.com/org/repo.git"));

        let error = check_tool_call_with(&raw, &gh).unwrap_err();
        assert!(error.contains("Tightbeam cannot use GitHub"));
        assert!(error.contains("--remote https://github.com/org/repo.git"));
    }

    #[test]
    fn tool_call_guard_does_not_gate_named_non_github_remotes() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {"command": "git fetch origin"}
        })
        .to_string();
        let gh =
            FakeGh::new(false).remote_url("origin", Some("https://gitlab.example/org/repo.git"));

        assert_eq!(check_tool_call_with(&raw, &gh), Ok(()));
    }

    #[test]
    fn tool_call_guard_recurses_into_nested_shell_scripts() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "sh -c \"git clone https://github.com/org/repo.git\""
            }
        })
        .to_string();

        let error = check_tool_call_with(&raw, &FakeGh::new(false)).unwrap_err();
        assert!(error.contains("Tightbeam cannot use GitHub"));
    }

    #[test]
    fn tool_call_guard_ignores_github_operations_inside_heredoc_data() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "cat <<'EOF' > /tmp/note\ngit clone https://github.com/org/repo.git\nEOF\n"
            }
        })
        .to_string();

        assert_eq!(check_tool_call_with(&raw, &FakeGh::new(false)), Ok(()));
    }

    #[test]
    fn parsed_github_remotes_accept_userinfo_case_and_any_git_operand_path() {
        for remote in [
            "https://alice@github.com/org/repo.git",
            "https://x-access-token:ghp_secret@GitHub.com/org/repo.git",
            "ssh://git@GITHUB.COM/org/repo.git",
            "git@GitHub.com:org/repo.git",
            "https://github.com/org/repo/pull/123",
            "https://github.com/org",
        ] {
            let parsed = parse_github_remote(remote).expect("GitHub repository remote");
            assert_eq!(parsed.original, remote);
            assert_eq!(parsed.hostname, "github.com");
        }

        for non_remote in [
            "https://evil.example/github.com/org/repo.git",
            "https://github.com.evil.example/org/repo.git",
            "ftp://github.com/org/repo.git",
        ] {
            assert_eq!(parse_github_remote(non_remote), None, "{non_remote}");
        }
    }

    #[test]
    fn tool_call_guard_gates_userinfo_and_case_insensitive_github_urls() {
        let secret = "ghp_USERINFO_SECRET";
        for command in [
            "git fetch https://alice@github.com/org/repo.git".to_owned(),
            format!("git fetch https://x-access-token:{secret}@github.com/org/repo.git"),
            "git clone https://GitHub.com/org/repo.git".to_owned(),
        ] {
            let raw = serde_json::json!({
                "tool_name": "Bash",
                "tool_input": {"command": command}
            })
            .to_string();
            let error = check_tool_call_with(&raw, &FakeGh::new(false)).unwrap_err();
            assert!(error.contains("Tightbeam cannot use GitHub"), "{command}");
            assert!(!error.contains(secret), "{command}");
        }
    }

    #[test]
    fn tool_call_guard_handles_leading_redirects_and_push_value_options() {
        let redirected = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "> /tmp/clone.log git clone https://github.com/org/repo.git"
            }
        })
        .to_string();
        assert!(
            check_tool_call_with(&redirected, &FakeGh::new(false))
                .unwrap_err()
                .contains("Tightbeam cannot use GitHub")
        );

        let push = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {"command": "git push -o foo origin"}
        })
        .to_string();
        let gh = FakeGh::new(false).remote_url("origin", Some("https://github.com/org/repo.git"));
        assert!(
            check_tool_call_with(&push, &gh)
                .unwrap_err()
                .contains("Tightbeam cannot use GitHub")
        );
    }

    #[test]
    fn tool_call_guard_resolves_configured_submodules_and_relative_origins() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {"command": "git submodule update --init"}
        })
        .to_string();

        let configured =
            FakeGh::new(false).submodule_urls(vec!["https://github.com/org/submodule.git"]);
        assert!(
            check_tool_call_with(&raw, &configured)
                .unwrap_err()
                .contains("Tightbeam cannot use GitHub")
        );

        let relative = FakeGh::new(false)
            .submodule_urls(vec!["../submodule.git"])
            .remote_url("origin", Some("https://github.com/org/repo.git"));
        assert!(
            check_tool_call_with(&raw, &relative)
                .unwrap_err()
                .contains("Tightbeam cannot use GitHub")
        );
    }

    #[test]
    fn tool_call_guard_does_not_gate_userinfo_on_non_github_urls() {
        let raw = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": {
                "command": "git fetch https://alice@gitlab.example/org/repo.git"
            }
        })
        .to_string();

        assert_eq!(check_tool_call_with(&raw, &FakeGh::new(false)), Ok(()));
    }
}
