//! Hand-parsed CLI arguments.
//!
//! Unlike the TypeScript seam, multiple identity flags are rejected as required
//! by the port specification's conflict ruling.

use std::collections::HashMap;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Identity {
    Role(String),
    User(String),
    Process(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Session(String),
    Role(String),
    User(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Help,
    Wake {
        identity: Identity,
        target: Target,
        prompt: String,
        after_ms: Option<String>,
        at: Option<String>,
    },
    Spawn {
        identity: Identity,
        display_name: String,
        idempotency_key: String,
        archetype: Option<String>,
        harness: Option<String>,
        model: Option<String>,
        handle: Option<String>,
        host: Option<String>,
    },
    List {
        identity: Identity,
    },
    Retire {
        identity: Identity,
        session_key: String,
        idempotency_key: Option<String>,
    },
    CancelWake {
        identity: Identity,
        wake_id: String,
    },
    RoleCreate {
        identity: Identity,
        name: String,
        bind: Option<String>,
    },
    RoleBind {
        identity: Identity,
        name: String,
        session_key: String,
    },
    RoleRemove {
        identity: Identity,
        name: String,
    },
    RoleList {
        identity: Identity,
    },
    SkillList {
        identity: Identity,
    },
    SkillPut {
        identity: Identity,
        name: String,
        content: String,
    },
    SkillRemove {
        identity: Identity,
        name: String,
    },
    ApproveDevice {
        identity: Identity,
        device_id: String,
        user_id: Option<String>,
    },
    DenyDevice {
        identity: Identity,
        device_id: String,
    },
    RevokeDevice {
        identity: Identity,
        device_id: String,
    },
    PromoteUser {
        identity: Identity,
        user_id: String,
        is_admin: bool,
    },
    Setup(SetupArgs),
    Assimilate(AssimilateArgs),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupArgs {
    pub base_dir: Option<String>,
    pub harnesses: Vec<String>,
    pub force: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssimilateArgs {
    pub ssh_dest: String,
    pub as_user: String,
    pub name: Option<String>,
    pub base_dir: String,
    pub harnesses: Vec<String>,
    pub push_credentials: bool,
    pub no_onboard: bool,
    pub dry_run: bool,
}

pub const HELP: &str = r#"tightbeam — coordinate with other agent sessions in this org.

Every command is one of the substrate's verbs; you invoke them exactly as the
human operator does. Output is JSON on stdout; a nonzero exit means failure
(the message is on stderr).

IDENTITY (required on every command — this is the #1 thing to get right):
  --as <role>          act as a role you currently hold. Use this when YOU (an
                       agent) run the command. The role must be bound to your
                       active session.
                       To reply to [from user:mike], use wake --user mike; to
                       reply to [from agent:notetaker], use wake --role
                       notetaker. [from process:x] cannot be woken.
  --as-user <userId>   act as a human user (e.g. "flynn"). Use this for
                       operator/admin actions or when no agent identity applies.
  --as-process <name>  act as automation (cron, CI, a webhook — e.g.
                       "cron"). Processes may wake and cancel-wake ONLY —
                       they cannot spawn, retire, or administer.
  Pass exactly ONE identity. It is who the call is attributed to, NOT the
  target of the call.

TARGET (for commands that take one — pass exactly one):
  --session <key>      this exact session incarnation
  --role <name>        the office; falls back to its owner's Main if unstaffed
  --user <id>          that human's Main

COMMANDS:
  wake (--session <key> | --role <name> | --user <id>) --prompt "<text>"
       [--after 30s|5m|2h] [--at <epochMs>]
      Send a prompt to the selected target. Immediate = a direct message; with --after or
      --at = a scheduled wake that fires later. A wake ALWAYS carries a prompt —
      there is no content-free ping. This is how you DM or nudge another
      session (or yourself).
        tightbeam wake --role reviewer --prompt "review PR 12" --as coder
        tightbeam wake --session agent:coder:app --prompt "check CI" --after 5m --as coder

  spawn --display "<name>" [--name <role>] [--archetype <a>]
        [--harness claude|codex] [--model <ref>] [--host <host>]
        [--key <idempotencyKey>]
      Hire a new session (a worker). --display is its human label; --name
      registers a role bound to the new session — do NOT confuse it with --as,
      which is YOUR identity. --key makes the spawn idempotent
      (same key returns the same session). Omitted fields inherit the
      archetype's defaults.
        tightbeam spawn --display "Reviewer" --name reviewer:x \
          --harness codex --model "gpt-5.6-sol[high]" --as orchestrator:news
      --host picks a machine WITHIN the archetype's allowed set (see list's
      archetypes/hosts); omitted, the archetype's default placement applies.
      Model refs must come from list's model catalog — never invent one.

  list
      Show the sessions you can address (with handles + provenance), the
      org's shape — archetypes (with allowed hosts), known hosts, and the
      valid model catalog per harness — and, for admins, pending devices.
        tightbeam list --as orchestrator:news

  retire --session <key> [--key <idempotencyKey>]
      End a session deliberately.

  cancel-wake <wakeId>
      Cancel a pending (scheduled) wake by its id (from the wake command's
      output).

  role create <name> [--bind <sessionKey>]       create a role
  role bind <name> <sessionKey>                  bind a role to a session
  role rm <name>                                 remove a role
  role list                                      list roles

  ADMIN (require --as-user of an admin, or an admin-owned agent handle):
  skill list                                    every skill in the library
  skill put <name> --file <path>                create/update a skill (admin);
      <name> may be a tree path ("swift/concurrency" — a technique inside the
      "swift" subject tree; electing "swift" takes the whole tree). Writes the
      library and pushes every satellite replica immediately.
  skill rm <name>                               remove a skill (admin); refused
      while any archetype elects it. Pruning inside a tree is an edit.

  approve-device <deviceId> [--user <userId>]   approve a pending device
  deny-device <deviceId>                         reject a pending device
  revoke-device <deviceId>                       revoke a device's token
  promote-user <userId> [--demote]               grant/remove admin on a user

  setup [--base-dir p] [--harness claude,codex] [--force]
      Onboard harness credentials for THIS machine's org (run once at
      install, once per harness you want supported). Walks you through each
      harness's own login flow with its config dir pointed at the org's
      auth store, so the org gets its OWN grant — never a copy of your
      personal login. Copies share a grant, and shared grants revoke each
      other on refresh. Needs an interactive terminal.
        tightbeam setup --base-dir ~/.tightbeam-beam

  assimilate <ssh-dest> [--name n] [--base-dir p] [--harness claude,codex]
             [--push-credentials] [--no-onboard] [--dry-run]
      Prepare a machine to run agent harnesses and register it as a host
      (admin). Probes ssh/node/rsync, creates the base dir, installs the
      ACP adapters and this CLI, records the host, and walks you through
      onboarding a dedicated login per harness on the satellite (the
      `setup` ceremony, over ssh -t; skipped without a terminal or with
      --no-onboard). Harvesting the satellite's own login happens only if
      one is already present in place; pushing YOURS needs the explicit
      --push-credentials — both share a grant and can race on refresh.
      After: add the host to an archetype's `where`.
        tightbeam assimilate work-1.local --as-user flynn

DISCOVERY: the CLI finds the gateway via TIGHTBEAM_URL + TIGHTBEAM_TOKEN, else
  <TIGHTBEAM_HOME|~/.tightbeam>/gateway.json. In an agent shell this is already
  set for you.

DURATIONS (for --after): <n>ms | <n>s | <n>m | <n>h  (e.g. 30s, 5m, 2h).

  tightbeam help | --help | -h    show this text."#;

const BOOLEAN_FLAGS: &[&str] = &[
    "demote",
    "dry-run",
    "force",
    "help",
    "no-onboard",
    "push-credentials",
];

#[derive(Debug)]
struct Flags {
    positional: Vec<String>,
    flags: HashMap<String, String>,
}

fn split_args(args: Vec<String>) -> Flags {
    let mut positional = Vec::new();
    let mut flags = HashMap::new();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if let Some(name) = arg.strip_prefix("--") {
            if BOOLEAN_FLAGS.contains(&name) {
                flags.insert(name.to_owned(), String::new());
            } else {
                let value = args.get(index + 1).cloned().unwrap_or_default();
                flags.insert(name.to_owned(), value);
                index += 1;
            }
        } else {
            positional.push(arg.clone());
        }
        index += 1;
    }
    Flags { positional, flags }
}

fn nonempty(flags: &HashMap<String, String>, name: &str) -> Option<String> {
    flags.get(name).filter(|value| !value.is_empty()).cloned()
}

fn identity(flags: &HashMap<String, String>) -> Result<Identity, String> {
    let identities = [
        nonempty(flags, "as").map(Identity::Role),
        nonempty(flags, "as-user").map(Identity::User),
        nonempty(flags, "as-process").map(Identity::Process),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();

    match identities.as_slice() {
        [identity] => Ok(identity.clone()),
        [] => Err(
            "identity required: pass --as <your-agent-handle> (when an agent runs this) or --as-user <userId> (operator action). This is WHO the call is from, not the target. Run 'tightbeam help'.".to_owned(),
        ),
        _ => Err(
            "identity flags are mutually exclusive: pass exactly one of --as, --as-user, or --as-process"
                .to_owned(),
        ),
    }
}

pub fn parse_after(text: &str) -> Result<String, String> {
    let (digits, multiplier) = if let Some(value) = text.strip_suffix("ms") {
        (value, 1.0)
    } else if let Some(value) = text.strip_suffix('s') {
        (value, 1_000.0)
    } else if let Some(value) = text.strip_suffix('m') {
        (value, 60_000.0)
    } else if let Some(value) = text.strip_suffix('h') {
        (value, 3_600_000.0)
    } else {
        return Err(bad_after(text));
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(bad_after(text));
    }
    let value = digits
        .parse::<f64>()
        .expect("an ASCII digit sequence parses as a JavaScript number");
    Ok(js_number_json(value * multiplier))
}

fn bad_after(text: &str) -> String {
    format!("bad --after value: {text} (use e.g. 30s, 5m, 2h)")
}

fn number_coercion(text: &str) -> f64 {
    let text =
        text.trim_matches(|character: char| character.is_whitespace() || character == '\u{feff}');
    if text.is_empty() {
        return 0.0;
    }

    for (prefix, radix) in [
        ("0x", 16),
        ("0X", 16),
        ("0b", 2),
        ("0B", 2),
        ("0o", 8),
        ("0O", 8),
    ] {
        if let Some(digits) = text.strip_prefix(prefix) {
            if digits.is_empty() {
                return f64::NAN;
            }
            let mut value = 0.0;
            for digit in digits.chars() {
                let Some(digit) = digit.to_digit(radix) else {
                    return f64::NAN;
                };
                value = value * f64::from(radix) + f64::from(digit);
            }
            return value;
        }
    }

    match text {
        "Infinity" | "+Infinity" => f64::INFINITY,
        "-Infinity" => f64::NEG_INFINITY,
        _ => text.parse::<f64>().unwrap_or(f64::NAN),
    }
}

fn js_number_json(value: f64) -> String {
    if !value.is_finite() {
        return "null".to_owned();
    }
    if value == 0.0 {
        return "0".to_owned();
    }

    let negative = value.is_sign_negative();
    let rendered = value.abs().to_string();
    let (mantissa, explicit_exponent) =
        rendered
            .split_once(['e', 'E'])
            .map_or((rendered.as_str(), 0), |(mantissa, exponent)| {
                (
                    mantissa,
                    exponent.parse::<i32>().expect("f64 exponent is valid"),
                )
            });
    let decimal = mantissa.find('.').unwrap_or(mantissa.len());
    let mut digits = mantissa.replace('.', "");
    let leading_zeroes = digits.bytes().take_while(|byte| *byte == b'0').count();
    digits.drain(..leading_zeroes);
    let exponent = explicit_exponent + decimal as i32 - leading_zeroes as i32 - 1;

    let body = if (-6..=20).contains(&exponent) {
        let decimal = exponent + 1;
        if decimal <= 0 {
            format!("0.{}{}", "0".repeat((-decimal) as usize), digits)
        } else if decimal as usize >= digits.len() {
            format!("{}{}", digits, "0".repeat(decimal as usize - digits.len()))
        } else {
            let decimal = decimal as usize;
            format!("{}.{}", &digits[..decimal], &digits[decimal..])
        }
    } else {
        while digits.ends_with('0') {
            digits.pop();
        }
        let fraction = if digits.len() > 1 {
            format!(".{}", &digits[1..])
        } else {
            String::new()
        };
        let sign = if exponent >= 0 { "+" } else { "" };
        format!("{}{fraction}e{sign}{exponent}", &digits[..1])
    };

    if negative { format!("-{body}") } else { body }
}

fn generated_key() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let millis = now.as_millis();
    let mut value = (now.as_nanos() as u64) ^ u64::from(std::process::id());
    let mut suffix = [b'0'; 6];
    const DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    for byte in suffix.iter_mut().rev() {
        *byte = DIGITS[(value % 36) as usize];
        value /= 36;
    }
    format!("cli_{millis}_{}", String::from_utf8_lossy(&suffix))
}

pub fn parse(args: Vec<String>) -> Result<Command, String> {
    let parsed = split_args(args);
    let command = parsed.positional.first().map(String::as_str);
    if command.is_none()
        || matches!(command, Some("help" | "-h"))
        || parsed.flags.contains_key("help")
        || parsed.flags.contains_key("h")
    {
        return Ok(Command::Help);
    }

    let flags = &parsed.flags;
    match command.expect("checked above") {
        "wake" => {
            let targets = [
                nonempty(flags, "session").map(Target::Session),
                nonempty(flags, "role").map(Target::Role),
                nonempty(flags, "user").map(Target::User),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
            if parsed.positional.get(1).is_some() || targets.len() != 1 {
                return Err("usage: tightbeam wake exactly one of --session <key>, --role <name>, --user <id> --prompt ...".to_owned());
            }
            let prompt = nonempty(flags, "prompt")
                .ok_or_else(|| "--prompt is required (a wake must carry a prompt)".to_owned())?;
            let after_ms = nonempty(flags, "after")
                .map(|value| parse_after(&value))
                .transpose()?;
            let at = nonempty(flags, "at").map(|value| js_number_json(number_coercion(&value)));
            Ok(Command::Wake {
                identity: identity(flags)?,
                target: targets.into_iter().next().expect("exactly one target"),
                prompt,
                after_ms,
                at,
            })
        }
        "spawn" => {
            let display_name =
                nonempty(flags, "display").ok_or_else(|| "--display is required".to_owned())?;
            Ok(Command::Spawn {
                identity: identity(flags)?,
                display_name,
                idempotency_key: nonempty(flags, "key").unwrap_or_else(generated_key),
                archetype: nonempty(flags, "archetype"),
                harness: nonempty(flags, "harness"),
                model: nonempty(flags, "model"),
                handle: nonempty(flags, "name"),
                host: nonempty(flags, "host"),
            })
        }
        "list" => Ok(Command::List {
            identity: identity(flags)?,
        }),
        "retire" => {
            let session_key = nonempty(flags, "session");
            if parsed.positional.get(1).is_some()
                || session_key.is_none()
                || nonempty(flags, "role").is_some()
                || nonempty(flags, "user").is_some()
            {
                return Err("usage: tightbeam retire --session <key>".to_owned());
            }
            Ok(Command::Retire {
                identity: identity(flags)?,
                session_key: session_key.expect("checked above"),
                idempotency_key: nonempty(flags, "key"),
            })
        }
        "cancel-wake" => {
            let wake_id = parsed
                .positional
                .get(1)
                .cloned()
                .ok_or_else(|| "usage: tightbeam cancel-wake <wakeId>".to_owned())?;
            Ok(Command::CancelWake {
                identity: identity(flags)?,
                wake_id,
            })
        }
        "role" => parse_role(&parsed, flags),
        "skill" => parse_skill(&parsed, flags),
        "approve-device" => {
            let device_id = parsed.positional.get(1).cloned().ok_or_else(|| {
                "usage: tightbeam approve-device <deviceId> [--user <userId>]".to_owned()
            })?;
            Ok(Command::ApproveDevice {
                identity: identity(flags)?,
                device_id,
                user_id: nonempty(flags, "user"),
            })
        }
        "deny-device" => {
            let device_id = device_id(&parsed, "deny-device")?;
            Ok(Command::DenyDevice {
                identity: identity(flags)?,
                device_id,
            })
        }
        "revoke-device" => {
            let device_id = device_id(&parsed, "revoke-device")?;
            Ok(Command::RevokeDevice {
                identity: identity(flags)?,
                device_id,
            })
        }
        "promote-user" => {
            let user_id =
                parsed.positional.get(1).cloned().ok_or_else(|| {
                    "usage: tightbeam promote-user <userId> [--demote]".to_owned()
                })?;
            Ok(Command::PromoteUser {
                identity: identity(flags)?,
                user_id,
                is_admin: !flags.contains_key("demote"),
            })
        }
        "setup" => Ok(Command::Setup(SetupArgs {
            base_dir: nonempty(flags, "base-dir"),
            harnesses: nonempty(flags, "harness")
                .unwrap_or_else(|| "claude,codex".to_owned())
                .split(',')
                .map(str::to_owned)
                .collect(),
            force: flags.contains_key("force"),
        })),
        "assimilate" => {
            let ssh_dest = parsed.positional.get(1).cloned().ok_or_else(|| {
                "usage: tightbeam assimilate <ssh-dest> --as-user <adminUserId>".to_owned()
            })?;
            let Some(as_user) = nonempty(flags, "as-user") else {
                return Err("--as-user is required for assimilate (admin required)".to_owned());
            };
            let selected_identity = identity(flags)?;
            debug_assert_eq!(selected_identity, Identity::User(as_user.clone()));
            Ok(Command::Assimilate(AssimilateArgs {
                ssh_dest,
                as_user,
                name: nonempty(flags, "name"),
                base_dir: nonempty(flags, "base-dir").unwrap_or_else(|| "~/.tightbeam".to_owned()),
                harnesses: nonempty(flags, "harness")
                    .unwrap_or_else(|| "claude,codex".to_owned())
                    .split(',')
                    .map(str::to_owned)
                    .collect(),
                push_credentials: flags.contains_key("push-credentials"),
                no_onboard: flags.contains_key("no-onboard"),
                dry_run: flags.contains_key("dry-run"),
            }))
        }
        unknown => Err(format!(
            "unknown command: {unknown} — run 'tightbeam help' for usage. Commands: wake, spawn, list, retire, cancel-wake, role, skill, approve-device, deny-device, revoke-device, promote-user, setup, assimilate"
        )),
    }
}

fn parse_role(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    let action = parsed.positional.get(1).map(String::as_str);
    let name = parsed.positional.get(2).cloned();
    match action {
        Some("create") => {
            let name = name.ok_or_else(|| {
                "usage: tightbeam role create <name> [--bind <sessionKey>]".to_owned()
            })?;
            Ok(Command::RoleCreate {
                identity: identity(flags)?,
                name,
                bind: nonempty(flags, "bind"),
            })
        }
        Some("bind") => {
            let name = name.ok_or_else(|| {
                "usage: tightbeam role bind <name> <sessionKey>".to_owned()
            })?;
            let session_key = parsed.positional.get(3).cloned().ok_or_else(|| {
                "usage: tightbeam role bind <name> <sessionKey>".to_owned()
            })?;
            Ok(Command::RoleBind {
                identity: identity(flags)?,
                name,
                session_key,
            })
        }
        Some("rm") => {
            let name = name.ok_or_else(|| "usage: tightbeam role rm <name>".to_owned())?;
            Ok(Command::RoleRemove {
                identity: identity(flags)?,
                name,
            })
        }
        Some("list") => Ok(Command::RoleList {
            identity: identity(flags)?,
        }),
        _ => Err("usage: tightbeam role create <name> [--bind <sessionKey>] | bind <name> <sessionKey> | rm <name> | list".to_owned()),
    }
}

fn parse_skill(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    let action = parsed.positional.get(1).map(String::as_str);
    let name = parsed.positional.get(2).cloned();
    match action {
        Some("list") => Ok(Command::SkillList {
            identity: identity(flags)?,
        }),
        Some("put") => {
            let name =
                name.ok_or_else(|| "usage: tightbeam skill put <name> --file <path>".to_owned())?;
            let path = nonempty(flags, "file")
                .ok_or_else(|| "usage: tightbeam skill put <name> --file <path>".to_owned())?;
            let content = fs::read(path)
                .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
                .map_err(|error| error.to_string())?;
            Ok(Command::SkillPut {
                identity: identity(flags)?,
                name,
                content,
            })
        }
        Some("rm") => {
            let name = name.ok_or_else(|| "usage: tightbeam skill rm <name>".to_owned())?;
            Ok(Command::SkillRemove {
                identity: identity(flags)?,
                name,
            })
        }
        _ => Err("usage: tightbeam skill list | put <name> --file <path> | rm <name>".to_owned()),
    }
}

fn device_id(parsed: &Flags, command: &str) -> Result<String, String> {
    parsed
        .positional
        .get(1)
        .cloned()
        .ok_or_else(|| format!("usage: tightbeam {command} <deviceId>"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn parses_help_forms() {
        for args in [
            strings(&[]),
            strings(&["help"]),
            strings(&["--help"]),
            strings(&["-h"]),
        ] {
            assert_eq!(parse(args), Ok(Command::Help));
        }
    }

    #[test]
    fn parses_all_duration_units() {
        assert_eq!(parse_after("30s"), Ok("30000".to_owned()));
        assert_eq!(parse_after("5m"), Ok("300000".to_owned()));
        assert_eq!(parse_after("2h"), Ok("7200000".to_owned()));
        assert_eq!(parse_after("250ms"), Ok("250".to_owned()));
        assert_eq!(
            parse_after("18446744073709551616ms"),
            Ok("18446744073709552000".to_owned())
        );
        assert_eq!(
            parse_after("soon"),
            Err("bad --after value: soon (use e.g. 30s, 5m, 2h)".to_owned())
        );
    }

    #[test]
    fn coerces_and_serializes_numbers_like_javascript() {
        for (input, expected) in [
            ("+1", "1"),
            ("0x10", "16"),
            ("0b10", "2"),
            ("0o10", "8"),
            ("1.0", "1"),
            ("1e20", "100000000000000000000"),
            ("1e21", "1e+21"),
            ("1e-6", "0.000001"),
            ("1e-7", "1e-7"),
            ("Infinity", "null"),
            ("not-a-number", "null"),
            ("-0", "0"),
            ("\u{feff}1\u{feff}", "1"),
        ] {
            assert_eq!(js_number_json(number_coercion(input)), expected);
        }
    }

    #[test]
    fn rejects_missing_and_multiple_identity() {
        assert!(
            parse(strings(&["list"]))
                .unwrap_err()
                .starts_with("identity required:")
        );
        assert_eq!(
            parse(strings(&["list", "--as", "coder", "--as-user", "flynn"])),
            Err("identity flags are mutually exclusive: pass exactly one of --as, --as-user, or --as-process".to_owned())
        );
    }

    #[test]
    fn requires_exactly_one_wake_target_and_session_only_retire() {
        for args in [
            strings(&["wake", "--prompt", "hello", "--as-user", "flynn"]),
            strings(&[
                "wake",
                "--session",
                "s",
                "--role",
                "r",
                "--prompt",
                "hello",
                "--as-user",
                "flynn",
            ]),
        ] {
            assert!(parse(args).unwrap_err().contains("exactly one of"));
        }
        for args in [
            strings(&["retire", "s", "--as-user", "flynn"]),
            strings(&["retire", "--role", "r", "--as-user", "flynn"]),
            strings(&["retire", "--user", "u", "--as-user", "flynn"]),
        ] {
            assert_eq!(
                parse(args),
                Err("usage: tightbeam retire --session <key>".to_owned())
            );
        }
    }

    #[test]
    fn unknown_command_matches_reference_text() {
        assert_eq!(
            parse(strings(&["frobnicate", "--as-user", "flynn"])),
            Err("unknown command: frobnicate — run 'tightbeam help' for usage. Commands: wake, spawn, list, retire, cancel-wake, role, skill, approve-device, deny-device, revoke-device, promote-user, setup, assimilate".to_owned())
        );
    }

    #[test]
    fn parses_every_command_happy_shape() {
        let commands = [
            strings(&[
                "wake", "--role", "reviewer", "--prompt", "go", "--as", "coder",
            ]),
            strings(&[
                "spawn",
                "--display",
                "Worker",
                "--key",
                "k",
                "--as-user",
                "flynn",
            ]),
            strings(&["list", "--as-process", "cron"]),
            strings(&["retire", "--session", "agent:x", "--as", "owner"]),
            strings(&["cancel-wake", "w1", "--as-process", "cron"]),
            strings(&["role", "create", "reviewer", "--as-user", "flynn"]),
            strings(&["role", "bind", "reviewer", "agent:x", "--as-user", "flynn"]),
            strings(&["role", "rm", "reviewer", "--as-user", "flynn"]),
            strings(&["role", "list", "--as-user", "flynn"]),
            strings(&["skill", "list", "--as-user", "flynn"]),
            strings(&["skill", "rm", "swift", "--as-user", "flynn"]),
            strings(&["approve-device", "d1", "--as-user", "flynn"]),
            strings(&["deny-device", "d1", "--as-user", "flynn"]),
            strings(&["revoke-device", "d1", "--as-user", "flynn"]),
            strings(&["promote-user", "mike", "--demote", "--as-user", "flynn"]),
            strings(&["setup"]),
            strings(&["assimilate", "host", "--as-user", "flynn"]),
        ];
        for args in commands {
            assert!(parse(args).is_ok());
        }

        let skill_path = std::env::temp_dir().join(format!(
            "tightbeam_skill_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&skill_path, "skill body").unwrap();
        let skill_put = parse(vec![
            "skill".to_owned(),
            "put".to_owned(),
            "swift".to_owned(),
            "--file".to_owned(),
            skill_path.display().to_string(),
            "--as-user".to_owned(),
            "flynn".to_owned(),
        ]);
        fs::remove_file(skill_path).unwrap();
        assert!(matches!(skill_put, Ok(Command::SkillPut { .. })));
    }

    #[test]
    fn skill_put_decodes_invalid_utf8_with_replacement_characters() {
        let skill_path = std::env::temp_dir().join(format!(
            "tightbeam_invalid_utf8_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&skill_path, [b'a', 0xff, b'b']).unwrap();
        let command = parse(vec![
            "skill".to_owned(),
            "put".to_owned(),
            "bytes".to_owned(),
            "--file".to_owned(),
            skill_path.display().to_string(),
            "--as-user".to_owned(),
            "flynn".to_owned(),
        ])
        .unwrap();
        fs::remove_file(skill_path).unwrap();

        assert!(matches!(
            command,
            Command::SkillPut { content, .. } if content == "a\u{fffd}b"
        ));
    }
}
