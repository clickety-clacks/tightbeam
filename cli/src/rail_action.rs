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
    if let [shell, flag, nested, ..] = argv
        && matches!(shell.as_str(), "sh" | "bash" | "zsh")
        && flag == "-c"
    {
        return command_matches(action, nested);
    }

    let [program, subcommand, rest @ ..] = argv else {
        return false;
    };

    if program != "git" {
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
    fn sibling_git_actions_use_argv_and_preserve_non_destructive_forms() {
        assert!(command_matches(
            Action::GitResetHard,
            "git reset --hard HEAD"
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
}
