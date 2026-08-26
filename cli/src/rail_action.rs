//! Closed, internal action classifier for destructive-command rails.
//!
//! A hook receives the full PreToolUse JSON envelope on stdin. Matching that
//! envelope as text lets quoted prose impersonate an action. This module reads
//! the command field, tokenizes shell command segments without executing them,
//! and classifies only an executable argv plus its action arguments.

use std::io::{self, Read};

pub(crate) fn run(args: &[String]) -> Result<i32, String> {
    let [action] = args else {
        return Err("usage: tightbeam rail-action <action>".to_owned());
    };

    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|error| format!("rail-action could not read stdin: {error}"))?;

    let envelope: serde_json::Value = serde_json::from_str(&input)
        .map_err(|error| format!("rail-action received malformed hook JSON: {error}"))?;
    let command = envelope
        .get("tool_input")
        .and_then(|value| value.get("command"))
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "rail-action hook JSON has no tool_input.command".to_owned())?;

    let action = Action::parse(action)?;
    Ok(if command_matches(action, command) {
        0
    } else {
        1
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Action {
    GitStash,
    GitResetHard,
    GitCleanForce,
    GitCheckoutDiscard,
    GitRestore,
}

impl Action {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "git-stash" => Ok(Self::GitStash),
            "git-reset-hard" => Ok(Self::GitResetHard),
            "git-clean-force" => Ok(Self::GitCleanForce),
            "git-checkout-discard" => Ok(Self::GitCheckoutDiscard),
            "git-restore" => Ok(Self::GitRestore),
            _ => Err(format!("unknown rail action: {value}")),
        }
    }
}

fn command_matches(action: Action, command: &str) -> bool {
    shell_segments(command)
        .iter()
        .any(|argv| argv_matches(action, argv))
}

fn argv_matches(action: Action, argv: &[String]) -> bool {
    let argv = command_argv(argv);

    if let Some(nested) = nested_shell_command(argv) {
        return command_matches(action, nested);
    }

    let Some((subcommand, rest)) = git_action_argv(argv) else {
        return false;
    };

    if matches!(rest, [argument] if matches!(argument.as_str(), "-h" | "--help")) {
        return false;
    }

    match action {
        Action::GitStash if subcommand == "stash" => match rest.first().map(String::as_str) {
            None => true,
            Some(argument) if argument.starts_with('-') => true,
            Some("push" | "pop" | "drop" | "clear" | "apply" | "save") => true,
            Some(_) => false,
        },
        Action::GitResetHard if subcommand == "reset" => rest.iter().any(|arg| arg == "--hard"),
        Action::GitCleanForce if subcommand == "clean" => rest.iter().any(|arg| {
            arg == "--force"
                || (arg.starts_with('-')
                    && !arg.starts_with("--")
                    && arg.chars().skip(1).any(|flag| flag == 'f'))
        }),
        Action::GitCheckoutDiscard if subcommand == "checkout" => {
            rest.iter().any(|arg| arg == "--")
        }
        Action::GitRestore if subcommand == "restore" => true,
        _ => false,
    }
}

fn nested_shell_command(argv: &[String]) -> Option<&str> {
    let [shell, args @ ..] = argv else {
        return None;
    };
    let shell = program_name(shell);
    if !matches!(shell, "sh" | "bash" | "zsh") {
        return None;
    }

    let mut index = 0;
    while let Some(argument) = args.get(index) {
        if argument == "--" {
            return None;
        }

        let command_option = argument == "-c"
            || argument.starts_with('-')
                && !argument.starts_with("--")
                && argument.chars().skip(1).any(|flag| flag == 'c');
        if command_option {
            let mut command_index = index + 1;
            if args
                .get(command_index)
                .is_some_and(|argument| argument == "--")
            {
                command_index += 1;
            }
            return args.get(command_index).map(String::as_str);
        }

        let takes_separate_value = matches!(argument.as_str(), "-o" | "-O" | "+o" | "+O")
            || shell == "bash" && matches!(argument.as_str(), "--init-file" | "--rcfile");
        index += if takes_separate_value { 2 } else { 1 };
    }

    None
}

fn program_name(value: &str) -> &str {
    value.rsplit('/').next().unwrap_or(value)
}

fn is_assignment(value: &str) -> bool {
    let Some((name, _)) = value.split_once('=') else {
        return false;
    };

    !name.is_empty()
        && name.chars().enumerate().all(|(index, ch)| {
            ch == '_' || ch.is_ascii_alphanumeric() && (index > 0 || !ch.is_ascii_digit())
        })
}

fn command_argv(mut argv: &[String]) -> &[String] {
    while argv.first().is_some_and(|arg| is_assignment(arg)) {
        argv = &argv[1..];
    }

    if argv
        .first()
        .is_some_and(|arg| program_name(arg) == "command")
    {
        argv = &argv[1..];
        while argv.first().is_some_and(|arg| arg.starts_with('-')) {
            argv = &argv[1..];
        }
    }

    if argv.first().is_some_and(|arg| program_name(arg) == "env") {
        argv = &argv[1..];
        loop {
            match argv {
                [option, _, rest @ ..] if matches!(option.as_str(), "-u" | "--unset") => {
                    argv = rest
                }
                [option, rest @ ..]
                    if option == "-i"
                        || option == "--ignore-environment"
                        || option.starts_with("--unset=") =>
                {
                    argv = rest
                }
                [assignment, rest @ ..] if is_assignment(assignment) => argv = rest,
                _ => break,
            }
        }
    }

    argv
}

fn git_action_argv(argv: &[String]) -> Option<(&str, &[String])> {
    let argv = command_argv(argv);
    let [program, rest @ ..] = argv else {
        return None;
    };
    if program_name(program) != "git" {
        return None;
    }

    let mut index = 0;
    while let Some(argument) = rest.get(index) {
        if !argument.starts_with('-') || argument == "-" {
            return Some((argument, &rest[index + 1..]));
        }

        let takes_separate_value = matches!(
            argument.as_str(),
            "-C" | "-c"
                | "--git-dir"
                | "--work-tree"
                | "--namespace"
                | "--exec-path"
                | "--config-env"
        );
        index += if takes_separate_value { 2 } else { 1 };
    }

    None
}

fn heredoc_delimiters(line: &str) -> Vec<(String, bool)> {
    #[derive(Clone, Copy, Eq, PartialEq)]
    enum Quote {
        None,
        Single,
        Double,
    }

    let chars: Vec<char> = line.chars().collect();
    let mut delimiters = Vec::new();
    let mut quote = Quote::None;
    let mut escaped = false;
    let mut index = 0;

    while index < chars.len() {
        let ch = chars[index];
        if escaped {
            escaped = false;
            index += 1;
            continue;
        }
        match quote {
            Quote::Single => {
                if ch == '\'' {
                    quote = Quote::None;
                }
                index += 1;
            }
            Quote::Double => {
                if ch == '"' {
                    quote = Quote::None;
                } else if ch == '\\' {
                    escaped = true;
                }
                index += 1;
            }
            Quote::None if ch == '\'' => {
                quote = Quote::Single;
                index += 1;
            }
            Quote::None if ch == '"' => {
                quote = Quote::Double;
                index += 1;
            }
            Quote::None if ch == '\\' => {
                escaped = true;
                index += 1;
            }
            Quote::None if ch == '<' && chars.get(index + 1) == Some(&'<') => {
                if chars.get(index + 2) == Some(&'<') {
                    index += 3;
                    continue;
                }
                index += 2;
                let strip_tabs = chars.get(index) == Some(&'-');
                if strip_tabs {
                    index += 1;
                }
                while chars.get(index).is_some_and(|ch| ch.is_ascii_whitespace()) {
                    index += 1;
                }

                let delimiter_quote = match chars.get(index) {
                    Some('\'') => {
                        index += 1;
                        Some('\'')
                    }
                    Some('"') => {
                        index += 1;
                        Some('"')
                    }
                    _ => None,
                };
                let start = index;
                while let Some(ch) = chars.get(index) {
                    if delimiter_quote.is_some_and(|closing| *ch == closing)
                        || delimiter_quote.is_none()
                            && (ch.is_ascii_whitespace() || matches!(ch, ';' | '&' | '|'))
                    {
                        break;
                    }
                    index += 1;
                }
                if index > start {
                    delimiters.push((chars[start..index].iter().collect(), strip_tabs));
                }
                if delimiter_quote.is_some() && chars.get(index) == delimiter_quote.as_ref() {
                    index += 1;
                }
            }
            Quote::None => index += 1,
        }
    }

    delimiters
}

fn without_heredoc_bodies(command: &str) -> String {
    use std::collections::VecDeque;

    let mut pending: VecDeque<(String, bool)> = VecDeque::new();
    let mut kept = Vec::new();

    for line in command.lines() {
        if let Some((delimiter, strip_tabs)) = pending.front() {
            let candidate = if *strip_tabs {
                line.trim_start_matches('\t')
            } else {
                line
            };
            if candidate == delimiter {
                pending.pop_front();
            }
            continue;
        }

        pending.extend(heredoc_delimiters(line));
        kept.push(line);
    }

    kept.join("\n")
}

fn shell_segments(command: &str) -> Vec<Vec<String>> {
    #[derive(Clone, Copy, Eq, PartialEq)]
    enum Quote {
        None,
        Single,
        Double,
    }

    fn finish_token(tokens: &mut Vec<String>, token: &mut String, started: &mut bool) {
        if *started {
            tokens.push(std::mem::take(token));
            *started = false;
        }
    }

    fn finish_segment(segments: &mut Vec<Vec<String>>, tokens: &mut Vec<String>) {
        if !tokens.is_empty() {
            segments.push(std::mem::take(tokens));
        }
    }

    let mut segments = Vec::new();
    let mut tokens = Vec::new();
    let mut token = String::new();
    let mut token_started = false;
    let mut quote = Quote::None;
    let mut escaped = false;
    let mut comment = false;
    let command = without_heredoc_bodies(command);
    let mut chars = command.chars().peekable();

    while let Some(ch) = chars.next() {
        if comment {
            if ch == '\n' {
                comment = false;
                finish_token(&mut tokens, &mut token, &mut token_started);
                finish_segment(&mut segments, &mut tokens);
            }
            continue;
        }

        if escaped {
            token.push(ch);
            token_started = true;
            escaped = false;
            continue;
        }

        match quote {
            Quote::Single => {
                if ch == '\'' {
                    quote = Quote::None;
                } else {
                    token.push(ch);
                }
                token_started = true;
            }
            Quote::Double => {
                if ch == '"' {
                    quote = Quote::None;
                } else if ch == '\\' {
                    escaped = true;
                } else {
                    token.push(ch);
                }
                token_started = true;
            }
            Quote::None => match ch {
                '\\' => escaped = true,
                '\'' => {
                    quote = Quote::Single;
                    token_started = true;
                }
                '"' => {
                    quote = Quote::Double;
                    token_started = true;
                }
                '#' if !token_started => comment = true,
                ' ' | '\t' | '\r' => finish_token(&mut tokens, &mut token, &mut token_started),
                '\n' | ';' | '(' | ')' => {
                    finish_token(&mut tokens, &mut token, &mut token_started);
                    finish_segment(&mut segments, &mut tokens);
                }
                '&' | '|' => {
                    finish_token(&mut tokens, &mut token, &mut token_started);
                    if chars.peek() == Some(&ch) {
                        chars.next();
                    }
                    finish_segment(&mut segments, &mut tokens);
                }
                _ => {
                    token.push(ch);
                    token_started = true;
                }
            },
        }
    }

    finish_token(&mut tokens, &mut token, &mut token_started);
    finish_segment(&mut segments, &mut tokens);
    segments
}

#[cfg(test)]
mod tests {
    use super::{Action, command_matches, shell_segments};

    #[test]
    fn tokenizes_compounds_but_keeps_quoted_prose_in_one_argv() {
        assert_eq!(
            shell_segments("tightbeam attest a --note 'git stash'; cd src && git reset --hard"),
            vec![
                vec!["tightbeam", "attest", "a", "--note", "git stash"],
                vec!["cd", "src"],
                vec!["git", "reset", "--hard"]
            ]
        );
    }

    #[test]
    fn stash_matches_actions_and_nested_shells_not_mentions() {
        for command in [
            "git stash",
            "git stash -u",
            "cd src && git stash push -m wip",
            "sh -c 'git stash pop'",
            "git -C repo stash",
            "/usr/bin/git --no-pager stash",
            "env HOME=/tmp git stash",
            "command git stash",
            "/bin/sh -c 'git -C repo stash'",
            "sh -c -- 'git stash clear'",
            "bash --noprofile -c 'git stash apply'",
            "zsh -fc 'git stash drop'",
        ] {
            assert!(command_matches(Action::GitStash, command), "{command}");
        }

        for command in [
            "git stash list",
            "git stash show -p",
            "rg 'git stash' lib test",
            "tightbeam attest asg_1 --note 'git stash was refused'",
            "printf '%s' 'git stash'",
            "git commit -m 'do not git stash by hand'",
        ] {
            assert!(!command_matches(Action::GitStash, command), "{command}");
        }
    }

    #[test]
    fn option_bearing_nested_shells_cannot_bypass_any_closed_action() {
        for (action, nested) in [
            (Action::GitStash, "git stash"),
            (Action::GitResetHard, "git reset --hard HEAD"),
            (Action::GitCleanForce, "git clean -xdf"),
            (Action::GitCheckoutDiscard, "git checkout main -- path"),
            (Action::GitRestore, "git restore path"),
        ] {
            assert!(command_matches(
                action,
                &format!("bash --noprofile -c '{nested}'")
            ));
            assert!(command_matches(action, &format!("sh -c -- '{nested}'")));
        }
    }

    #[test]
    fn shell_option_operands_cannot_impersonate_the_command_switch() {
        for (action, nested) in [
            (Action::GitStash, "git stash"),
            (Action::GitResetHard, "git reset --hard HEAD"),
            (Action::GitCleanForce, "git clean -xdf"),
            (Action::GitCheckoutDiscard, "git checkout main -- path"),
            (Action::GitRestore, "git restore path"),
        ] {
            assert!(!command_matches(
                action,
                &format!("bash --rcfile -c '{nested}'")
            ));
            assert!(!command_matches(
                action,
                &format!("bash --init-file -c '{nested}'")
            ));
            assert!(command_matches(
                action,
                &format!("bash --rcfile /tmp/bashrc -c '{nested}'")
            ));
        }
    }

    #[test]
    fn heredoc_report_bodies_are_not_executable_segments() {
        let report = "cat <<'REPORT'\ngit stash\nREPORT";
        assert!(!command_matches(Action::GitStash, report));

        let followed_by_action = "cat <<REPORT\ngit stash is prose\nREPORT\ngit stash";
        assert!(command_matches(Action::GitStash, followed_by_action));

        assert!(!command_matches(
            Action::GitStash,
            "printf '%s' 'literal <<REPORT and git stash'"
        ));
    }

    #[test]
    fn sibling_git_actions_use_argv_and_preserve_non_destructive_forms() {
        assert!(command_matches(
            Action::GitResetHard,
            "git reset --hard HEAD"
        ));
        assert!(command_matches(
            Action::GitResetHard,
            "/usr/bin/git -C repo reset --hard HEAD"
        ));
        assert!(!command_matches(
            Action::GitResetHard,
            "git reset --soft HEAD"
        ));
        assert!(command_matches(Action::GitCleanForce, "git clean -xdf"));
        assert!(!command_matches(
            Action::GitCleanForce,
            "git clean --dry-run"
        ));
        assert!(command_matches(
            Action::GitCheckoutDiscard,
            "git checkout main -- path"
        ));
        assert!(!command_matches(
            Action::GitCheckoutDiscard,
            "git checkout --detach HEAD"
        ));
        assert!(command_matches(Action::GitRestore, "git restore path"));
        assert!(!command_matches(
            Action::GitRestore,
            "echo 'git restore path'"
        ));
    }

    #[test]
    fn help_only_invocations_are_not_destructive_actions() {
        for (action, subcommand, destructive) in [
            (Action::GitStash, "stash", "git stash"),
            (Action::GitResetHard, "reset", "git reset --hard HEAD"),
            (Action::GitCleanForce, "clean", "git clean -xdf"),
            (
                Action::GitCheckoutDiscard,
                "checkout",
                "git checkout main -- path",
            ),
            (Action::GitRestore, "restore", "git restore path"),
        ] {
            assert!(command_matches(action, destructive));
            assert!(!command_matches(action, &format!("git {subcommand} -h")));
            assert!(!command_matches(
                action,
                &format!("git {subcommand} --help")
            ));
        }
    }
}
