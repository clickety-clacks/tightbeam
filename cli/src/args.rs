//! Hand-parsed CLI arguments.
//!
//! Unlike the TypeScript reference CLI, this shipped Rust CLI rejects multiple
//! identity flags and permits omission when session-file discovery proves the
//! caller; the gateway remains the identity authority.

use std::collections::HashMap;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Identity {
    Role(String),
    User(String),
    Process(String),
    Omitted,
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
    Probe {
        json: bool,
        base_dir: Option<String>,
    },
    Wake {
        identity: Identity,
        target: Target,
        prompt: String,
        after_ms: Option<String>,
        at: Option<String>,
        condition_kind: Option<String>,
        condition_scope: Option<String>,
        idempotency_key: Option<String>,
    },
    Condition {
        identity: Identity,
        kind: String,
        scope: Option<String>,
        idempotency_key: Option<String>,
    },
    Rule {
        identity: Identity,
        request_id: String,
        decision: String,
        rationale: Option<String>,
    },
    Waive {
        identity: Identity,
        request_id: Option<String>,
        session_key: Option<String>,
        statute_name: Option<String>,
        reason: Option<String>,
    },
    RevokeWaiver {
        identity: Identity,
        waiver_id: String,
        reason: Option<String>,
    },
    Withdraw {
        identity: Identity,
        request_id: String,
        reason: String,
    },
    DecisionRequests {
        identity: Identity,
        status: Option<String>,
    },
    DecisionRequest {
        identity: Identity,
        request_id: String,
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
    Adjudicate {
        identity: Identity,
        episode: String,
        action: String,
        model: Option<String>,
        reason: Option<String>,
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
    RunTests {
        identity: Identity,
        assignment_id: String,
    },
    RunSmoke {
        identity: Identity,
        assignment_id: String,
    },
    CancelProducerJob {
        identity: Identity,
        job_id: String,
    },
    WorkItemCreate {
        identity: Identity,
        title: String,
        spec_ref_name: Option<String>,
        spec_ref_sha256: Option<String>,
    },
    WorkItemUpdate {
        identity: Identity,
        work_item_id: String,
        title: Option<String>,
        spec_ref_name: Option<String>,
        spec_ref_sha256: Option<String>,
        clear_spec_ref: bool,
    },
    WorkItemGet {
        identity: Identity,
        work_item_id: String,
    },
    WorkItemList {
        identity: Identity,
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
    RevokeAssignment {
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
    Init(InitArgs),
    Setup(SetupArgs),
    Assimilate(AssimilateArgs),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InitArgs {
    pub base_dir: Option<String>,
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

IDENTITY (optional inside a session workdir; otherwise required):
  --as <role>          act as a role you currently hold. Use this when YOU (an
                       agent) run the command. The role must be bound to your
                       active session.
                       To reply to [from user:mike], use wake --user mike; to
                       reply to [from agent:notetaker], use wake --role
                       notetaker. [from process:x] cannot be woken.
  --as-user <userId>   act as a human user (e.g. "flynn"). Use this for
                       operator/admin actions or when no agent identity applies.
  --as-process <name>  act as automation (cron, CI, a webhook — e.g.
                       "cron"). Processes may wake, cancel-wake, and file
                       conditions ONLY — they cannot spawn, retire, or administer.
  Pass at most ONE identity. It is who the call is attributed to, NOT the
  target of the call. Inside a session workdir, omission lets the gateway
  derive the session's identity from its credential.

TARGET (for commands that take one — pass exactly one):
  --session <key>      this exact session incarnation
  --role <name>        the office; falls back to its owner's Main if unstaffed
  --user <id>          that human's Main

COMMANDS:
  wake (--session <key> | --role <name> | --user <id>) --prompt "<text>"
       [--after 30s|5m|2h] [--at <epochMs>] [--key <idempotencyKey>]
       [--when-fact <kind> [--when-scope <scope>] --fallback-after 30s|5m|2h]
      Send a prompt to the selected target. Immediate = a direct message; with --after or
      --at = a scheduled wake that fires later. A wake ALWAYS carries a prompt —
      there is no content-free ping. This is how you DM or nudge another
      session (or yourself).
        tightbeam wake --role reviewer --prompt "review PR 12" --as coder
        tightbeam wake --session agent:coder:app --prompt "check CI" --after 5m --as coder

  condition --kind <kind> [--scope <scope>] [--key <idempotencyKey>]
      File an org/product condition fact. Reserved substrate kinds cannot be
      filed through this command.
        tightbeam condition --kind deploy-succeeded --scope prod --key deploy-8f2a

  rule --request <id> --decision <allow|deny|option> [--rationale "..."]
      Resolve one open decision request.
  waive (--request <id> | --session <key> --statute <name>) [--reason "..."]
      Grant a raiser-scoped statute waiver.
  revoke-waiver --waiver <id> [--reason "..."]
      Revoke a waiver prospectively.
  withdraw --request <id> --reason "..."
      Retract your own open decision request.
  decision-requests [--status <status>]
      List visible decision requests (open by default).
  decision-request <id>
      Read one visible decision request with its halted-call context.

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

  adjudicate --episode <correlationKey> --action park|swap|respawn|stop
             [--model <ref>] [--reason <text>]
      Rule on a model-adjudication episode currently owned by this session.

  work-item-create --title "<title>" [--spec-ref <name> --spec-sha256 <hex>]
  work-item-update <workItemId> [--title "<title>"] [--spec-ref <name>]
                   [--spec-sha256 <hex>] [--clear-spec-ref]
  work-item-get <workItemId>
  work-item-list
  assign --subject "<work>" (--session <key> | --role <name>)
         [--idempotency-key <key>] [--work-item <workItemId>]
         [--reviews <assignmentId>] [--files '["lib/a.ex","test/a_test.exs"]']
      Open an obligation held by a session; a work item is the durable thread
      across assignments.
  run-tests <assignmentId>
  run-smoke <assignmentId>
      Queue the committed mechanical producer for an assignment.
  cancel-producer-job <jobId>
      Cancel a queued or running producer job.
  attest <assignmentId> --kind progress|completion|surrender|verdict
         [--verdict <kind>] [--note "..."]
      File against an assignment. Verdicts require --verdict and may be filed
      by any session or user; lifecycle attests remain holder-filed.
  attests <assignmentId>
      List every attest filed against an assignment.
  revoke-assignment <assignmentId>
      Revoke an open assignment (admin or its opener).
  assignments [--session <key> | --role <name>] [--state open|closed|all]
      List assignments (open by default).

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

  init [--base-dir p]
      Seed the identity working tree and create its git repository. Re-running
      against an initialized identity repository is a no-op.

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

  probe [--json] [--base-dir DIR]
      Report local lineage claims, adapter candidates, and machine facts.

DISCOVERY: the CLI walks up from cwd for .tightbeam-session first, then uses
  TIGHTBEAM_URL + TIGHTBEAM_TOKEN, else <TIGHTBEAM_HOME|~/.tightbeam>/gateway.json.

DURATIONS (for --after/--fallback-after): <n>ms | <n>s | <n>m | <n>h
  (e.g. 30s, 5m, 2h).

  tightbeam help | --help | -h    show this text."#;

const BOOLEAN_FLAGS: &[&str] = &[
    "clear-spec-ref",
    "demote",
    "dry-run",
    "force",
    "help",
    "json",
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
        [] => Ok(Identity::Omitted),
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
        "probe" => {
            if parsed.positional.len() != 1
                || flags
                    .keys()
                    .any(|flag| !matches!(flag.as_str(), "json" | "base-dir"))
                || flags.get("base-dir").is_some_and(String::is_empty)
            {
                return Err("usage: tightbeam probe [--json] [--base-dir DIR]".to_owned());
            }
            Ok(Command::Probe {
                json: flags.contains_key("json"),
                base_dir: nonempty(flags, "base-dir"),
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
            let fallback_after_ms = nonempty(flags, "fallback-after")
                .map(|value| parse_after(&value))
                .transpose()?;
            if after_ms.is_some() && fallback_after_ms.is_some() {
                return Err("pass only one of --after or --fallback-after".to_owned());
            }
            let at = nonempty(flags, "at").map(|value| js_number_json(number_coercion(&value)));
            Ok(Command::Wake {
                identity: identity(flags)?,
                target: targets.into_iter().next().expect("exactly one target"),
                prompt,
                after_ms: fallback_after_ms.or(after_ms),
                at,
                condition_kind: nonempty(flags, "when-fact"),
                condition_scope: nonempty(flags, "when-scope"),
                idempotency_key: nonempty(flags, "key"),
            })
        }
        "condition" => {
            if parsed.positional.get(1).is_some() {
                return Err("usage: tightbeam condition --kind <kind> [--scope <scope>] [--key <idempotencyKey>]".to_owned());
            }
            let kind = nonempty(flags, "kind").ok_or_else(|| "--kind is required".to_owned())?;
            Ok(Command::Condition {
                identity: identity(flags)?,
                kind,
                scope: nonempty(flags, "scope"),
                idempotency_key: nonempty(flags, "key"),
            })
        }
        "rule" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam rule --request <id> --decision <allow|deny|option> [--rationale ...]".to_owned());
            }
            Ok(Command::Rule {
                identity: identity(flags)?,
                request_id: nonempty(flags, "request")
                    .ok_or_else(|| "--request is required".to_owned())?,
                decision: nonempty(flags, "decision")
                    .ok_or_else(|| "--decision is required".to_owned())?,
                rationale: nonempty(flags, "rationale"),
            })
        }
        "waive" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam waive (--request <id> | --session <key> --statute <name>) [--reason ...]".to_owned());
            }
            let request_id = nonempty(flags, "request");
            let session_key = nonempty(flags, "session");
            let statute_name = nonempty(flags, "statute");
            let request_form =
                request_id.is_some() && session_key.is_none() && statute_name.is_none();
            let preemptive_form =
                request_id.is_none() && session_key.is_some() && statute_name.is_some();
            if !request_form && !preemptive_form {
                return Err("usage: tightbeam waive (--request <id> | --session <key> --statute <name>) [--reason ...]".to_owned());
            }
            Ok(Command::Waive {
                identity: identity(flags)?,
                request_id,
                session_key,
                statute_name,
                reason: nonempty(flags, "reason"),
            })
        }
        "revoke-waiver" => {
            if parsed.positional.len() != 1 {
                return Err(
                    "usage: tightbeam revoke-waiver --waiver <id> [--reason ...]".to_owned(),
                );
            }
            Ok(Command::RevokeWaiver {
                identity: identity(flags)?,
                waiver_id: nonempty(flags, "waiver")
                    .ok_or_else(|| "--waiver is required".to_owned())?,
                reason: nonempty(flags, "reason"),
            })
        }
        "withdraw" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam withdraw --request <id> --reason ...".to_owned());
            }
            Ok(Command::Withdraw {
                identity: identity(flags)?,
                request_id: nonempty(flags, "request")
                    .ok_or_else(|| "--request is required".to_owned())?,
                reason: nonempty(flags, "reason")
                    .ok_or_else(|| "--reason is required".to_owned())?,
            })
        }
        "decision-requests" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam decision-requests [--status <status>]".to_owned());
            }
            Ok(Command::DecisionRequests {
                identity: identity(flags)?,
                status: nonempty(flags, "status"),
            })
        }
        "decision-request" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam decision-request <id>".to_owned());
            }
            Ok(Command::DecisionRequest {
                identity: identity(flags)?,
                request_id: parsed.positional[1].clone(),
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
        "adjudicate" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam adjudicate --episode <key> --action park|swap|respawn|stop [--model <ref>] [--reason <text>]".to_owned());
            }
            let episode =
                nonempty(flags, "episode").ok_or_else(|| "--episode is required".to_owned())?;
            let action =
                nonempty(flags, "action").ok_or_else(|| "--action is required".to_owned())?;
            if !matches!(action.as_str(), "park" | "swap" | "respawn" | "stop") {
                return Err("--action must be park, swap, respawn, or stop".to_owned());
            }
            Ok(Command::Adjudicate {
                identity: identity(flags)?,
                episode,
                action,
                model: nonempty(flags, "model"),
                reason: nonempty(flags, "reason"),
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
                idempotency_key: nonempty(flags, "idempotency-key"),
                work_item_id: nonempty(flags, "work-item"),
                reviews: nonempty(flags, "reviews"),
                files,
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
        "cancel-producer-job" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam cancel-producer-job <jobId>".to_owned());
            }
            Ok(Command::CancelProducerJob {
                identity: identity(flags)?,
                job_id: parsed.positional[1].clone(),
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
        "work-item-update" => {
            let work_item_id = parsed.positional.get(1).cloned().ok_or_else(|| {
                "usage: tightbeam work-item-update <workItemId> [patch flags]".to_owned()
            })?;
            if parsed.positional.len() != 2 {
                return Err(
                    "usage: tightbeam work-item-update <workItemId> [patch flags]".to_owned(),
                );
            }
            let clear_spec_ref = flags.contains_key("clear-spec-ref");
            let spec_ref_name = nonempty(flags, "spec-ref");
            let spec_ref_sha256 = nonempty(flags, "spec-sha256");
            if clear_spec_ref
                && (flags.contains_key("spec-ref") || flags.contains_key("spec-sha256"))
            {
                return Err(
                    "usage: --clear-spec-ref conflicts with --spec-ref and --spec-sha256"
                        .to_owned(),
                );
            }
            Ok(Command::WorkItemUpdate {
                identity: identity(flags)?,
                work_item_id,
                title: nonempty(flags, "title"),
                spec_ref_name,
                spec_ref_sha256,
                clear_spec_ref,
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
        "work-item-list" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam work-item-list".to_owned());
            }
            Ok(Command::WorkItemList {
                identity: identity(flags)?,
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
        "revoke-assignment" => {
            let assignment_id =
                parsed.positional.get(1).cloned().ok_or_else(|| {
                    "usage: tightbeam revoke-assignment <assignmentId>".to_owned()
                })?;
            Ok(Command::RevokeAssignment {
                identity: identity(flags)?,
                assignment_id,
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
        "init" => {
            if parsed.positional.len() != 1
                || flags.keys().any(|flag| flag != "base-dir")
                || flags.get("base-dir").is_some_and(String::is_empty)
            {
                return Err("usage: tightbeam init [--base-dir DIR]".to_owned());
            }
            Ok(Command::Init(InitArgs {
                base_dir: nonempty(flags, "base-dir"),
            }))
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
            "unknown command: {unknown} — run 'tightbeam help' for usage. Commands: wake, condition, rule, waive, revoke-waiver, withdraw, decision-requests, decision-request, spawn, list, retire, work-item-create, work-item-update, work-item-get, work-item-list, assign, run-tests, run-smoke, cancel-producer-job, attest, attests, revoke-assignment, assignments, cancel-wake, role, skill, approve-device, deny-device, revoke-device, promote-user, init, setup, assimilate, probe"
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
    fn permits_missing_and_rejects_multiple_identity() {
        assert_eq!(
            parse(strings(&["list"])),
            Ok(Command::List {
                identity: Identity::Omitted
            })
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
            Err("unknown command: frobnicate — run 'tightbeam help' for usage. Commands: wake, condition, rule, waive, revoke-waiver, withdraw, decision-requests, decision-request, spawn, list, retire, work-item-create, work-item-update, work-item-get, work-item-list, assign, run-tests, run-smoke, cancel-producer-job, attest, attests, revoke-assignment, assignments, cancel-wake, role, skill, approve-device, deny-device, revoke-device, promote-user, init, setup, assimilate, probe".to_owned())
        );
    }

    #[test]
    fn escalation_command_shapes_and_required_flags_are_pinned() {
        assert!(matches!(
            parse(strings(&[
                "rule",
                "--request",
                "dr_1",
                "--decision",
                "allow",
                "--as-user",
                "flynn"
            ])),
            Ok(Command::Rule { .. })
        ));
        assert!(matches!(
            parse(strings(&[
                "waive",
                "--session",
                "s1",
                "--statute",
                "review",
                "--as-user",
                "flynn"
            ])),
            Ok(Command::Waive { .. })
        ));
        assert!(parse(strings(&["rule", "--request", "dr_1"])).is_err());
        assert!(parse(strings(&["withdraw", "--request", "dr_1"])).is_err());
        assert!(parse(strings(&["waive", "--request", "dr_1", "--session", "s1"])).is_err());
        assert!(HELP.contains("decision-requests [--status <status>]"));
    }

    #[test]
    fn work_item_cli_usage_rules_are_pinned() {
        assert!(
            parse(strings(&[
                "work-item-create",
                "--title",
                "x",
                "--spec-ref",
                "spec.md"
            ]))
            .unwrap_err()
            .contains("supplied together")
        );

        assert!(
            parse(strings(&[
                "work-item-update",
                "wi_1",
                "--clear-spec-ref",
                "--spec-ref",
                "spec.md"
            ]))
            .unwrap_err()
            .contains("conflicts")
        );

        for args in [
            strings(&["work-item-create", "--title", "x"]),
            strings(&["work-item-update", "wi_1", "--title", "y"]),
            strings(&["work-item-get", "wi_1"]),
            strings(&["work-item-list"]),
        ] {
            assert!(parse(args).is_ok());
        }
    }

    #[test]
    fn verdict_flag_is_required_iff_kind_is_verdict() {
        assert_eq!(
            parse(strings(&["attest", "asg_1", "--kind", "verdict"])),
            Err("--verdict is required when --kind is verdict".to_owned())
        );
        assert_eq!(
            parse(strings(&[
                "attest",
                "asg_1",
                "--kind",
                "progress",
                "--verdict",
                "reviewed"
            ])),
            Err("--verdict is only valid when --kind is verdict".to_owned())
        );
    }

    #[test]
    fn parses_every_command_happy_shape() {
        let commands = [
            strings(&[
                "wake", "--role", "reviewer", "--prompt", "go", "--as", "coder",
            ]),
            strings(&[
                "condition",
                "--kind",
                "deploy-succeeded",
                "--scope",
                "prod",
                "--key",
                "k",
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
            strings(&[
                "adjudicate",
                "--episode",
                "adj_1",
                "--action",
                "swap",
                "--model",
                "gpt-5.6-sol[high]",
                "--as",
                "owner",
            ]),
            strings(&["cancel-wake", "w1", "--as-process", "cron"]),
            strings(&["run-tests", "asg_1", "--as", "builder"]),
            strings(&["run-smoke", "asg_1", "--as-user", "flynn"]),
            strings(&["cancel-producer-job", "pj_1", "--as", "builder"]),
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
            strings(&["init"]),
            strings(&["init", "--base-dir", "/tmp/tb"]),
            strings(&["setup"]),
            strings(&["assimilate", "host", "--as-user", "flynn"]),
            strings(&["probe"]),
            strings(&["probe", "--json", "--base-dir", "/tmp/tb"]),
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
    fn probe_rejects_positionals_unknown_flags_and_missing_base_dir() {
        for values in [
            strings(&["probe", "extra"]),
            strings(&["probe", "--bogus"]),
            strings(&["probe", "--base-dir"]),
        ] {
            assert_eq!(
                parse(values),
                Err("usage: tightbeam probe [--json] [--base-dir DIR]".to_owned())
            );
        }
        assert!(HELP.contains("probe [--json] [--base-dir DIR]"));
    }

    #[test]
    fn init_rejects_positionals_unknown_flags_and_missing_base_dir() {
        for values in [
            strings(&["init", "extra"]),
            strings(&["init", "--bogus"]),
            strings(&["init", "--base-dir"]),
        ] {
            assert_eq!(
                parse(values),
                Err("usage: tightbeam init [--base-dir DIR]".to_owned())
            );
        }
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
