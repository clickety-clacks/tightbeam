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
    Doctor {
        json: bool,
        base_dir: Option<String>,
    },
    Wake {
        identity: Identity,
        target: Target,
        prompt: String,
        after_ms: Option<String>,
        at: Option<String>,
    },
    ArtifactRecord {
        identity: Identity,
        kind: String,
        title: String,
        origin_path: String,
        description: Option<String>,
        work_item_id: Option<String>,
        content_sha256: Option<String>,
    },
    Artifacts {
        identity: Identity,
        work_item_id: Option<String>,
        session_key: Option<String>,
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
    Assign {
        identity: Identity,
        subject: String,
        target: Target,
        idempotency_key: Option<String>,
        work_item_id: Option<String>,
        reviews: Option<String>,
        files: Option<Vec<String>>,
    },
    Dispatch {
        identity: Identity,
        subject: String,
        holder: String,
        work_item_id: Option<String>,
        brief: String,
        idempotency_key: Option<String>,
    },
    RunTests {
        identity: Identity,
        assignment_id: String,
    },
    RunSmoke {
        identity: Identity,
        assignment_id: String,
    },
    WorkItemCreate {
        identity: Identity,
        title: String,
        spec_ref_name: Option<String>,
        spec_ref_sha256: Option<String>,
    },
    WorkItemGet {
        identity: Identity,
        work_item_id: String,
    },
    Attest {
        identity: Identity,
        assignment_id: String,
        kind: String,
        verdict: Option<String>,
        note: Option<String>,
    },
    Attests {
        identity: Identity,
        assignment_id: String,
    },
    Assignments {
        identity: Identity,
        target: Option<Target>,
        state: Option<String>,
    },
    CancelWake {
        identity: Identity,
        wake_id: String,
    },
    IdentityEdit {
        identity: Identity,
        archetype: String,
        manifest: bool,
        skill: Option<String>,
        remove: bool,
        content: Option<String>,
    },
    IdentityStatus {
        identity: Identity,
        archetype: Option<String>,
    },
    IdentityRelearn {
        identity: Identity,
        action: Option<String>,
    },
    IdentityApply {
        identity: Identity,
        session_key: Option<String>,
        all: bool,
    },
    Onboard {
        identity: Identity,
        provider: String,
    },
    ConfigGet {
        identity: Identity,
        setting: String,
    },
    ConfigSet {
        identity: Identity,
        setting: String,
        value: String,
    },
    Assimilate(AssimilateArgs),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssimilateArgs {
    pub ssh_dest: String,
    pub as_user: String,
    pub name: Option<String>,
    pub base_dir: String,
    pub harnesses: Vec<String>,
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

  artifact-record --kind <kind> --title <title> --path <originPath>
                  [--description <text>] [--work-item <workItemId>] [--sha256 <hex>]
      Record a deliberate artifact pointer for the calling session.
  artifacts [--work-item <workItemId>] [--session <key>]
      List artifact rows matching every supplied exact filter.

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

  work-item-create --title "<title>" [--spec-ref <name> --spec-sha256 <hex>]
  work-item-get <workItemId>
  assign --subject "<work>" (--session <key> | --role <name>)
         [--key <key>] [--work-item <workItemId>]
         [--reviews <assignmentId>] [--files '["lib/a.ex","test/a_test.exs"]']
      Open an obligation held by a session; a work item is the durable thread
      across assignments.
  dispatch (--to <sessionKey> | --holder <sessionKey>) --subject "<work>"
           --brief "<one sentence>" [--work-item <workItemId>] [--key <key>]
      Atomically open an assignment and wake its holder with the card id.
  run-tests <assignmentId>
  run-smoke <assignmentId>
      Queue the committed mechanical producer for an assignment.
  attest <assignmentId> --kind progress|completion|surrender|verdict
         [--verdict <kind>] [--note "..."]
      File against an assignment. Verdicts require --verdict and may be filed
      by any session or user; lifecycle attests remain holder-filed.
  attests <assignmentId>
      List every attest filed against an assignment.
  assignments [--session <key> | --role <name>] [--state open|closed|all]
      List assignments (open by default).

  cancel-wake <wakeId>
      Cancel a pending (scheduled) wake by its id (from the wake command's
      output).

  ADMIN (require --as-user of an admin, or an admin-owned agent handle):
  identity edit <archetype> [--manifest | --skill <name> [--rm]]
                [--file <path>]
      Edit the served identity. Without --file, content is read from stdin.
  identity relearn [--abort | --resolve]
      Import and merge the shipped kungfu; resolve or abort a conflict.
  identity status [<archetype>]
      Report the live revision, session revisions, staleness, and conflicts.
  identity apply (<session> | --all)
      Refresh selected sessions from the current live identity revision.
  onboard openai|anthropic
      Run this machine's guided credential onboarding flow.
  config get default-archetype                   read the default spawn archetype
  config set default-archetype <name>            set the default spawn archetype

  doctor [--json] [--base-dir p]
      Check the local Tightbeam installation and report its health.

  assimilate <ssh-dest> [--name n] [--base-dir p] [--harness claude,codex]
             [--dry-run]
      Prepare a machine to run agent harnesses and register it as a host
      (admin). Probes ssh/node/rsync, creates the base dir, installs the
      ACP adapters and this CLI, and records the host. Credentials never
      transit between machines; run `tightbeam onboard` independently on
      the assimilated host.
      After: add the host to an archetype's `where`.
        tightbeam assimilate work-1.local --as-user flynn

DISCOVERY: the CLI finds the gateway via TIGHTBEAM_URL + TIGHTBEAM_TOKEN, else
  <TIGHTBEAM_HOME|~/.tightbeam>/gateway.json. In an agent shell this is already
  set for you.

DURATIONS (for --after): <n>ms | <n>s | <n>m | <n>h  (e.g. 30s, 5m, 2h).

  tightbeam help | --help | -h    show this text."#;

const BOOLEAN_FLAGS: &[&str] = &[
    "abort",
    "all",
    "dry-run",
    "help",
    "json",
    "manifest",
    "resolve",
    "rm",
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
        "doctor" => {
            let base_dir = nonempty(flags, "base-dir");
            if parsed.positional.len() != 1
                || flags
                    .keys()
                    .any(|flag| !matches!(flag.as_str(), "json" | "base-dir"))
                || (flags.contains_key("base-dir") && base_dir.is_none())
            {
                return Err("usage: tightbeam doctor [--json] [--base-dir DIR]".to_owned());
            }
            Ok(Command::Doctor {
                json: flags.contains_key("json"),
                base_dir,
            })
        }
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
        "artifact-record" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam artifact-record --kind <kind> --title <title> --path <originPath> [--description <text>] [--work-item <workItemId>] [--sha256 <hex>]".to_owned());
            }
            Ok(Command::ArtifactRecord {
                identity: identity(flags)?,
                kind: nonempty(flags, "kind").ok_or_else(|| "--kind is required".to_owned())?,
                title: nonempty(flags, "title").ok_or_else(|| "--title is required".to_owned())?,
                origin_path: nonempty(flags, "path")
                    .ok_or_else(|| "--path is required".to_owned())?,
                description: nonempty(flags, "description"),
                work_item_id: nonempty(flags, "work-item"),
                content_sha256: nonempty(flags, "sha256"),
            })
        }
        "artifacts" => {
            if parsed.positional.len() != 1
                || flags.keys().any(|flag| {
                    !matches!(
                        flag.as_str(),
                        "work-item" | "session" | "as" | "as-user" | "as-process"
                    )
                })
            {
                return Err(
                    "usage: tightbeam artifacts [--work-item <workItemId>] [--session <key>]"
                        .to_owned(),
                );
            }
            Ok(Command::Artifacts {
                identity: identity(flags)?,
                work_item_id: nonempty(flags, "work-item"),
                session_key: nonempty(flags, "session"),
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
        "assign" => {
            let targets = [
                nonempty(flags, "session").map(Target::Session),
                nonempty(flags, "role").map(Target::Role),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
            if parsed.positional.get(1).is_some() || targets.len() != 1 {
                return Err("usage: tightbeam assign --subject <text> exactly one of --session <key>, --role <name>".to_owned());
            }
            let subject =
                nonempty(flags, "subject").ok_or_else(|| "--subject is required".to_owned())?;
            let files = nonempty(flags, "files")
                .map(|encoded| {
                    serde_json::from_str::<Vec<String>>(&encoded)
                        .map_err(|_| "--files must be a JSON array of strings".to_owned())
                })
                .transpose()?;
            Ok(Command::Assign {
                identity: identity(flags)?,
                subject,
                target: targets.into_iter().next().expect("exactly one target"),
                idempotency_key: nonempty(flags, "key"),
                work_item_id: nonempty(flags, "work-item"),
                reviews: nonempty(flags, "reviews"),
                files,
            })
        }
        "dispatch" => {
            let holders = [nonempty(flags, "to"), nonempty(flags, "holder")]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            if parsed.positional.get(1).is_some() || holders.len() != 1 {
                return Err("usage: tightbeam dispatch (--to <sessionKey> | --holder <sessionKey>) --subject <text> --brief <text>".to_owned());
            }
            let subject =
                nonempty(flags, "subject").ok_or_else(|| "--subject is required".to_owned())?;
            let brief = nonempty(flags, "brief").ok_or_else(|| "--brief is required".to_owned())?;
            Ok(Command::Dispatch {
                identity: identity(flags)?,
                subject,
                holder: holders.into_iter().next().expect("exactly one holder"),
                work_item_id: nonempty(flags, "work-item"),
                brief,
                idempotency_key: nonempty(flags, "key"),
            })
        }
        "run-tests" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam run-tests <assignmentId>".to_owned());
            }
            Ok(Command::RunTests {
                identity: identity(flags)?,
                assignment_id: parsed.positional[1].clone(),
            })
        }
        "run-smoke" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam run-smoke <assignmentId>".to_owned());
            }
            Ok(Command::RunSmoke {
                identity: identity(flags)?,
                assignment_id: parsed.positional[1].clone(),
            })
        }
        "work-item-create" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam work-item-create --title <title> [--spec-ref <name> --spec-sha256 <hex>]".to_owned());
            }
            let spec_ref_name = nonempty(flags, "spec-ref");
            let spec_ref_sha256 = nonempty(flags, "spec-sha256");
            let spec_ref_present = flags.contains_key("spec-ref");
            let spec_sha_present = flags.contains_key("spec-sha256");
            if spec_ref_present != spec_sha_present
                || (spec_ref_present && (spec_ref_name.is_none() || spec_ref_sha256.is_none()))
            {
                return Err(
                    "usage: --spec-ref and --spec-sha256 must be supplied together".to_owned(),
                );
            }
            Ok(Command::WorkItemCreate {
                identity: identity(flags)?,
                title: nonempty(flags, "title").ok_or_else(|| "--title is required".to_owned())?,
                spec_ref_name,
                spec_ref_sha256,
            })
        }
        "work-item-get" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam work-item-get <workItemId>".to_owned());
            }
            Ok(Command::WorkItemGet {
                identity: identity(flags)?,
                work_item_id: parsed.positional[1].clone(),
            })
        }
        "attest" => {
            let assignment_id =
                parsed.positional.get(1).cloned().ok_or_else(|| {
                    "usage: tightbeam attest <assignmentId> --kind <kind>".to_owned()
                })?;
            let kind = nonempty(flags, "kind").ok_or_else(|| "--kind is required".to_owned())?;
            let verdict = nonempty(flags, "verdict");
            if kind == "verdict" && verdict.is_none() {
                return Err("--verdict is required when --kind is verdict".to_owned());
            }
            if kind != "verdict" && verdict.is_some() {
                return Err("--verdict is only valid when --kind is verdict".to_owned());
            }
            Ok(Command::Attest {
                identity: identity(flags)?,
                assignment_id,
                kind,
                verdict,
                note: nonempty(flags, "note"),
            })
        }
        "attests" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam attests <assignmentId>".to_owned());
            }
            Ok(Command::Attests {
                identity: identity(flags)?,
                assignment_id: parsed.positional[1].clone(),
            })
        }
        "assignments" => {
            let targets = [
                nonempty(flags, "session").map(Target::Session),
                nonempty(flags, "role").map(Target::Role),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
            if parsed.positional.get(1).is_some() || targets.len() > 1 {
                return Err("usage: tightbeam assignments [--session <key> | --role <name>] [--state <state>]".to_owned());
            }
            Ok(Command::Assignments {
                identity: identity(flags)?,
                target: targets.into_iter().next(),
                state: nonempty(flags, "state"),
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
        "identity" => parse_identity_command(&parsed, flags),
        "onboard" => parse_onboard(&parsed, flags),
        "config" => parse_config(&parsed, flags),
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
                dry_run: flags.contains_key("dry-run"),
            }))
        }
        unknown => Err(format!(
            "unknown command: {unknown} — run 'tightbeam help' for usage. Commands: wake, cancel-wake, attest, attests, assign, assignments, dispatch, work-item-create, work-item-get, spawn, retire, list, identity, onboard, artifact-record, artifacts, config, doctor, assimilate, run-smoke, run-tests"
        )),
    }
}

fn parse_config(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    match (
        parsed.positional.get(1).map(String::as_str),
        parsed.positional.get(2).map(String::as_str),
        parsed.positional.get(3),
        parsed.positional.get(4),
    ) {
        (Some("get"), Some("default-archetype"), None, None) => Ok(Command::ConfigGet {
            identity: identity(flags)?,
            setting: "default-archetype".to_owned(),
        }),
        (Some("set"), Some("default-archetype"), Some(value), None) => Ok(Command::ConfigSet {
            identity: identity(flags)?,
            setting: "default-archetype".to_owned(),
            value: value.clone(),
        }),
        _ => Err(
            "usage: tightbeam config get default-archetype | config set default-archetype <name>"
                .to_owned(),
        ),
    }
}

fn parse_identity_command(
    parsed: &Flags,
    flags: &HashMap<String, String>,
) -> Result<Command, String> {
    match parsed.positional.get(1).map(String::as_str) {
        Some("edit") => {
            let archetype = parsed.positional.get(2).cloned().ok_or_else(|| {
                "usage: tightbeam identity edit <archetype> [--manifest | --skill <name> [--rm]] [--file <path>]".to_owned()
            })?;
            if parsed.positional.len() != 3 {
                return Err("usage: tightbeam identity edit <archetype> [--manifest | --skill <name> [--rm]] [--file <path>]".to_owned());
            }
            let manifest = flags.contains_key("manifest");
            let skill = nonempty(flags, "skill");
            let remove = flags.contains_key("rm");
            if manifest && skill.is_some() {
                return Err("--manifest and --skill are mutually exclusive".to_owned());
            }
            if remove && skill.is_none() {
                return Err("--rm requires --skill <name>".to_owned());
            }
            if remove && flags.contains_key("file") {
                return Err("--file is not valid with --rm".to_owned());
            }
            let content = if remove {
                None
            } else {
                Some(match nonempty(flags, "file") {
                    Some(path) => fs::read(path)
                        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
                        .map_err(|error| error.to_string())?,
                    None => {
                        use std::io::Read;
                        let mut content = String::new();
                        std::io::stdin()
                            .read_to_string(&mut content)
                            .map_err(|error| error.to_string())?;
                        content
                    }
                })
            };
            Ok(Command::IdentityEdit {
                identity: identity(flags)?,
                archetype,
                manifest,
                skill,
                remove,
                content,
            })
        }
        Some("status") if parsed.positional.len() <= 3 => Ok(Command::IdentityStatus {
            identity: identity(flags)?,
            archetype: parsed.positional.get(2).cloned(),
        }),
        Some("relearn") if parsed.positional.len() == 2 => {
            let actions = ["abort", "resolve"]
                .into_iter()
                .filter(|name| flags.contains_key(*name))
                .collect::<Vec<_>>();
            if actions.len() > 1 {
                return Err("--abort and --resolve are mutually exclusive".to_owned());
            }
            Ok(Command::IdentityRelearn {
                identity: identity(flags)?,
                action: actions.first().map(|value| (*value).to_owned()),
            })
        }
        Some("apply") => {
            let session_key = parsed.positional.get(2).cloned();
            let all = flags.contains_key("all");
            if parsed.positional.len() > 3 || all == session_key.is_some() {
                return Err(
                    "usage: tightbeam identity apply (<session> | --all)".to_owned(),
                );
            }
            Ok(Command::IdentityApply {
                identity: identity(flags)?,
                session_key,
                all,
            })
        }
        _ => Err("usage: tightbeam identity edit|status|relearn|apply ...".to_owned()),
    }
}

fn parse_onboard(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    if parsed.positional.len() != 2 {
        return Err("usage: tightbeam onboard openai|anthropic".to_owned());
    }
    let provider = parsed.positional[1].clone();
    if !matches!(provider.as_str(), "openai" | "anthropic") {
        return Err("provider must be openai or anthropic".to_owned());
    }
    Ok(Command::Onboard {
        identity: identity(flags)?,
        provider,
    })
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
    fn help_enumerates_exactly_cli_surface_v1() {
        let command_section = HELP
            .split_once("COMMANDS:\n")
            .unwrap()
            .1
            .split_once("\nDISCOVERY:")
            .unwrap()
            .0;
        let headings = command_section
            .lines()
            .filter_map(|line| {
                let line = line.strip_prefix("  ")?;
                if line.starts_with(' ') {
                    return None;
                }
                let command = line.split_whitespace().next()?;
                command
                    .bytes()
                    .next()
                    .is_some_and(|byte| byte.is_ascii_lowercase())
                    .then_some(command)
            })
            .collect::<std::collections::BTreeSet<_>>();

        assert_eq!(
            headings,
            [
                "assimilate",
                "assign",
                "assignments",
                "artifact-record",
                "artifacts",
                "attest",
                "attests",
                "cancel-wake",
                "config",
                "dispatch",
                "doctor",
                "identity",
                "list",
                "onboard",
                "retire",
                "run-smoke",
                "run-tests",
                "spawn",
                "wake",
                "work-item-create",
                "work-item-get",
            ]
            .into_iter()
            .collect()
        );
        for syntax in [
            "identity edit <archetype>",
            "identity relearn [--abort | --resolve]",
            "identity status [<archetype>]",
            "identity apply (<session> | --all)",
            "onboard openai|anthropic",
            "config get default-archetype",
            "config set default-archetype <name>",
        ] {
            assert!(HELP.contains(syntax), "missing HELP syntax: {syntax}");
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
            Err("unknown command: frobnicate — run 'tightbeam help' for usage. Commands: wake, cancel-wake, attest, attests, assign, assignments, dispatch, work-item-create, work-item-get, spawn, retire, list, identity, onboard, artifact-record, artifacts, config, doctor, assimilate, run-smoke, run-tests".to_owned())
        );
    }

    #[test]
    fn commands_outside_cli_surface_v1_are_not_exposed() {
        for command in [
            "rail-exec",
            "probe",
            "condition",
            "facts-read",
            "artifact-get",
            "rule",
            "waive",
            "revoke-waiver",
            "withdraw",
            "decision-requests",
            "decision-request",
            "critical",
            "adjudicate",
            "cancel-producer-job",
            "work-item-update",
            "work-item-list",
            "assignment-get",
            "revoke-assignment",
            "init",
            "setup",
            "role",
            "kungfu-scaffold",
            "approve-device",
            "deny-device",
            "revoke-device",
            "promote-user",
        ] {
            assert!(
                parse(strings(&[command]))
                    .unwrap_err()
                    .starts_with(&format!("unknown command: {command} —"))
            );
        }
    }

    #[test]
    fn doctor_parses_real_health_check_options_and_rejects_non_surface_shapes() {
        assert_eq!(
            parse(strings(&[
                "doctor",
                "--json",
                "--base-dir",
                "/tmp/tightbeam",
            ])),
            Ok(Command::Doctor {
                json: true,
                base_dir: Some("/tmp/tightbeam".to_owned()),
            })
        );
        for args in [
            strings(&["doctor", "extra"]),
            strings(&["doctor", "--unknown", "value"]),
            strings(&["doctor", "--base-dir"]),
        ] {
            assert_eq!(
                parse(args),
                Err("usage: tightbeam doctor [--json] [--base-dir DIR]".to_owned())
            );
        }
    }

    #[test]
    fn artifacts_accepts_only_work_item_and_session_filters() {
        assert!(
            parse(strings(&[
                "artifacts",
                "--work-item",
                "wi_1",
                "--session",
                "agent:writer:app",
                "--as-user",
                "flynn",
            ]))
            .is_ok()
        );

        for unsupported in ["kind", "after", "before", "since", "from", "to"] {
            assert_eq!(
                parse(strings(&[
                    "artifacts",
                    &format!("--{unsupported}"),
                    "value",
                    "--as-user",
                    "flynn",
                ])),
                Err(
                    "usage: tightbeam artifacts [--work-item <workItemId>] [--session <key>]"
                        .to_owned()
                )
            );
        }
    }

    #[test]
    fn restored_command_usage_rules_are_pinned() {
        assert!(
            parse(strings(&[
                "work-item-create",
                "--title",
                "x",
                "--spec-ref",
                "spec.md",
                "--as-user",
                "flynn",
            ]))
            .unwrap_err()
            .contains("supplied together")
        );

        assert_eq!(
            parse(strings(&[
                "attest",
                "asg_1",
                "--kind",
                "verdict",
                "--as-user",
                "flynn",
            ])),
            Err("--verdict is required when --kind is verdict".to_owned())
        );
        assert_eq!(
            parse(strings(&[
                "attest",
                "asg_1",
                "--kind",
                "progress",
                "--verdict",
                "reviewed",
                "--as-user",
                "flynn",
            ])),
            Err("--verdict is only valid when --kind is verdict".to_owned())
        );
    }

    #[test]
    fn parses_every_command_happy_shape_exactly() {
        let skill_path = std::env::temp_dir().join(format!(
            "tightbeam_skill_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&skill_path, "skill body").unwrap();
        let skill_path = skill_path.display().to_string();

        let commands = vec![
            (
                strings(&[
                    "wake", "--role", "reviewer", "--prompt", "go", "--after", "30s", "--at",
                    "123", "--as", "coder",
                ]),
                Command::Wake {
                    identity: Identity::Role("coder".to_owned()),
                    target: Target::Role("reviewer".to_owned()),
                    prompt: "go".to_owned(),
                    after_ms: Some("30000".to_owned()),
                    at: Some("123".to_owned()),
                },
            ),
            (
                strings(&[
                    "spawn",
                    "--display",
                    "Worker",
                    "--key",
                    "k",
                    "--archetype",
                    "worker",
                    "--harness",
                    "codex",
                    "--model",
                    "gpt",
                    "--name",
                    "reviewer",
                    "--host",
                    "eezo",
                    "--as-user",
                    "flynn",
                ]),
                Command::Spawn {
                    identity: Identity::User("flynn".to_owned()),
                    display_name: "Worker".to_owned(),
                    idempotency_key: "k".to_owned(),
                    archetype: Some("worker".to_owned()),
                    harness: Some("codex".to_owned()),
                    model: Some("gpt".to_owned()),
                    handle: Some("reviewer".to_owned()),
                    host: Some("eezo".to_owned()),
                },
            ),
            (
                strings(&["list", "--as-process", "cron"]),
                Command::List {
                    identity: Identity::Process("cron".to_owned()),
                },
            ),
            (
                strings(&[
                    "retire",
                    "--session",
                    "agent:x",
                    "--key",
                    "retire-k",
                    "--as",
                    "owner",
                ]),
                Command::Retire {
                    identity: Identity::Role("owner".to_owned()),
                    session_key: "agent:x".to_owned(),
                    idempotency_key: Some("retire-k".to_owned()),
                },
            ),
            (
                strings(&["cancel-wake", "w1", "--as-process", "cron"]),
                Command::CancelWake {
                    identity: Identity::Process("cron".to_owned()),
                    wake_id: "w1".to_owned(),
                },
            ),
            (
                strings(&["doctor", "--json", "--base-dir", "/tmp/tightbeam"]),
                Command::Doctor {
                    json: true,
                    base_dir: Some("/tmp/tightbeam".to_owned()),
                },
            ),
            (
                strings(&["identity", "status", "coder", "--as-user", "flynn"]),
                Command::IdentityStatus {
                    identity: Identity::User("flynn".to_owned()),
                    archetype: Some("coder".to_owned()),
                },
            ),
            (
                vec![
                    "identity".to_owned(),
                    "edit".to_owned(),
                    "coder".to_owned(),
                    "--skill".to_owned(),
                    "swift".to_owned(),
                    "--file".to_owned(),
                    skill_path.clone(),
                    "--as-user".to_owned(),
                    "flynn".to_owned(),
                ],
                Command::IdentityEdit {
                    identity: Identity::User("flynn".to_owned()),
                    archetype: "coder".to_owned(),
                    manifest: false,
                    skill: Some("swift".to_owned()),
                    remove: false,
                    content: Some("skill body".to_owned()),
                },
            ),
            (
                strings(&["identity", "apply", "--all", "--as-user", "flynn"]),
                Command::IdentityApply {
                    identity: Identity::User("flynn".to_owned()),
                    session_key: None,
                    all: true,
                },
            ),
            (
                strings(&["onboard", "openai", "--as-user", "flynn"]),
                Command::Onboard {
                    identity: Identity::User("flynn".to_owned()),
                    provider: "openai".to_owned(),
                },
            ),
            (
                strings(&[
                    "assimilate",
                    "flynn@host",
                    "--name",
                    "host",
                    "--base-dir",
                    "/srv/tightbeam",
                    "--harness",
                    "codex",
                    "--dry-run",
                    "--as-user",
                    "flynn",
                ]),
                Command::Assimilate(AssimilateArgs {
                    ssh_dest: "flynn@host".to_owned(),
                    as_user: "flynn".to_owned(),
                    name: Some("host".to_owned()),
                    base_dir: "/srv/tightbeam".to_owned(),
                    harnesses: vec!["codex".to_owned()],
                    dry_run: true,
                }),
            ),
        ];

        for (args, expected) in commands {
            assert_eq!(parse(args), Ok(expected));
        }

        fs::remove_file(skill_path).unwrap();
    }

    #[test]
    fn identity_edit_decodes_invalid_utf8_with_replacement_characters() {
        let skill_path = std::env::temp_dir().join(format!(
            "tightbeam_invalid_utf8_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&skill_path, [b'a', 0xff, b'b']).unwrap();
        let command = parse(vec![
            "identity".to_owned(),
            "edit".to_owned(),
            "coder".to_owned(),
            "--skill".to_owned(),
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
            Command::IdentityEdit { content: Some(content), .. } if content == "a\u{fffd}b"
        ));
    }
}
