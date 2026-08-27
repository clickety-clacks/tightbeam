//! Hand-parsed CLI arguments.
//!
//! Multiple explicit identity flags are rejected. Inside a session workdir,
//! omission lets the gateway derive the principal from the discovered session
//! credential.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::harnesses::HarnessCatalog;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Identity {
    Role(String),
    User(String),
    Process(String),
    Session,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Session(String),
    Role(String),
    User(String),
}

/// One tune invocation changes one control dimension. Encoding the legal forms
/// here keeps partial multi-control requests out of the gateway entirely.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TuneControl {
    Harness {
        harness: String,
        model: String,
        effort: Option<String>,
        context: Option<String>,
    },
    Model {
        model: String,
        effort: Option<String>,
        context: Option<String>,
    },
    Effort(String),
    Fast(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Help,
    /// Help for one named command: `tightbeam assimilate --help`, `tightbeam help
    /// assimilate`. Printing the whole manual in answer to a question about one
    /// command buries the answer it was asked for.
    CommandHelp(String),
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
    /// Substrate-reserved: the PreToolUse hook reporting that this session is
    /// about to run `artifact-record`. Carries no identity flag because the
    /// observation is the session's by definition — the gateway resolves the
    /// turn from the session token, so there is nothing for a flag to say.
    ToolCallObserved,
    /// Substrate-reserved: the GitHub PreToolUse hook guard. It reads the raw
    /// tool-call JSON from stdin and refuses only GitHub-dependent calls when
    /// this host's GitHub auth is not ready.
    GithubAuthCheck,
    Spawn {
        identity: Identity,
        display_name: String,
        idempotency_key: String,
        archetype: Option<String>,
        harness: Option<String>,
        /// A model field the operator NAMED. `None` is a flag they did not
        /// pass; `Some(None)` is one they passed empty — "the vendor's default
        /// window", "no tier" — which is a real selection and a different
        /// request from silence. Collapsing the two is how an explicit choice
        /// arrives downstream as an omission and gets inherited over.
        model: Option<Option<String>>,
        effort: Option<Option<String>>,
        context: Option<Option<String>>,
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
    Tune {
        identity: Identity,
        session_key: String,
        control: TuneControl,
    },
    Assign {
        identity: Identity,
        subject: String,
        target: Target,
        idempotency_key: Option<String>,
        work_item_id: Option<String>,
        reviews: Option<String>,
        effect_kind: Option<String>,
        files: Option<Vec<String>>,
    },
    Dispatch {
        identity: Identity,
        subject: String,
        holder: String,
        work_item_id: Option<String>,
        effect_kind: Option<String>,
        workdir_root: Option<String>,
        brief: String,
        idempotency_key: Option<String>,
    },
    EffortRule {
        identity: Identity,
        request_id: String,
        action: String,
    },
    OperatorAsk {
        identity: Identity,
        question: String,
        note: Option<String>,
        options: Option<Vec<String>>,
        assignment_id: Option<String>,
        deadline_ms: Option<String>,
        supersedes: Option<String>,
    },
    OperatorRule {
        identity: Identity,
        request_id: String,
        decision: Option<String>,
        response: Option<String>,
        rationale: Option<String>,
    },
    OperatorWithdraw {
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
    RevokeAssignment {
        identity: Identity,
        assignment_id: String,
    },
    WorkItemCreate {
        identity: Identity,
        title: String,
        spec_ref_name: Option<String>,
        spec_ref_sha256: Option<String>,
        idempotency_key: Option<String>,
    },
    WorkItemGet {
        identity: Identity,
        work_item_id: String,
    },
    WorkItemTrace {
        identity: Identity,
        work_item_id: String,
    },
    Attend {
        identity: Identity,
        high: bool,
    },
    Transcript {
        identity: Identity,
        session: Option<String>,
        name: Option<String>,
        before: Option<String>,
        after: Option<String>,
        limit: Option<String>,
    },
    Toplines {
        identity: Identity,
        filters: ToplineFilters,
        tree: bool,
    },
    Topline {
        identity: Identity,
        selection: ToplineSelection,
    },
    WorkItemIcebox {
        identity: Identity,
        work_item_id: String,
    },
    WorkItemReopen {
        identity: Identity,
        work_item_id: String,
    },
    WorkItemClose {
        identity: Identity,
        work_item_id: String,
    },
    WorkItemFail {
        identity: Identity,
        work_item_id: String,
        reason: Option<String>,
    },
    Attest {
        identity: Identity,
        assignment_id: String,
        kind: String,
        verdict: Option<String>,
        note: Option<String>,
        commit_refs: Option<Vec<serde_json::Value>>,
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
    IdentityRepoint {
        identity: Identity,
        session_key: String,
        archetype: String,
    },
    Learn {
        identity: Identity,
        name: String,
    },
    Unlearn {
        identity: Identity,
        name: String,
    },
    KungfuList {
        identity: Identity,
    },
    IdentityApply {
        identity: Identity,
        session_key: Option<String>,
        all: bool,
    },
    Onboard {
        identity: Identity,
        provider: String,
        api_key: bool,
        hostname: Option<String>,
        remote: Option<String>,
    },
    AddUser {
        identity: Identity,
        user_id: String,
        admin: bool,
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
    HostEnvSet {
        identity: Identity,
        host: String,
        harness: String,
        name: String,
        value: String,
    },
    HostEnvList {
        identity: Identity,
        host: Option<String>,
        harness: Option<String>,
    },
    HostEnvUnset {
        identity: Identity,
        host: String,
        harness: String,
        name: String,
    },
    HostToolchainSet {
        identity: Identity,
        host: String,
        dirs: Vec<String>,
    },
    HarnessProcesses {
        identity: Identity,
    },
    UpdateClients {
        as_user: String,
    },
    Assimilate(AssimilateArgs),
}

/// `topline`'s two selections. Assignment selection carries NO filters: the spec
/// scopes roster filters to the roster and `--under`, and assignment selection has
/// no filter surface at all. Making that a TYPE distinction rather than a runtime
/// check is deliberate — re-attaching filters to assignment mode is a compile
/// error, not a request that succeeds while quietly ignoring half of what was
/// asked (found in code review of the first cut, which sent filters the reader
/// then discarded).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToplineSelection {
    Under {
        work_item_id: String,
        filters: ToplineFilters,
    },
    Assignments(Vec<String>),
}

/// Roster filters, identical for `toplines` and `topline --under`. They select
/// which authorized nodes APPEAR; they never change authorization, edge
/// derivation, or causal reachability.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToplineFilters {
    pub origin: Option<String>,
    pub owner: Option<String>,
    pub state: Option<String>,
    pub quiet_over_ms: Option<String>,
    pub spec: Option<String>,
    pub spec_sha: Option<String>,
    pub session: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssimilateArgs {
    pub ssh_dest: String,
    pub as_user: String,
    pub name: Option<String>,
    pub base_dir: String,
    pub harnesses: Vec<String>,
    pub catalog: HarnessCatalog,
    pub dry_run: bool,
}

const HELP_TEMPLATE: &str = r#"tightbeam — coordinate with other agent sessions in this org.

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
                       condition facts ONLY — they cannot spawn, retire, or
                       administer.
  Pass at most ONE explicit identity. It is who the call is attributed to, NOT
  the target of the call. With no flag, the CLI walks up from the current
  directory for .tightbeam-session and the gateway derives the identity from
  that session credential.

TARGET (for commands that take one — pass exactly one):
  --session <key>      this exact session incarnation
  --role <name>        the office; falls back to its owner's Main if unstaffed
  --user <id>          that human's Main

COMMANDS:
  wake (--session <key> | --role <name> | --user <id>) --prompt "<text>"
       [--after 30s|5m|2h] [--at <epochMs>]
      Condition wake:
        tightbeam wake (--session <key> | --role <name> | --user <id>)
          --when-fact <kind> [--when-scope <scope>]
          (--fallback-after 30s|5m|2h | --at <epochMs>)
          --prompt "<text>" [--key <idempotencyKey>]
      Send a prompt to the selected target. Immediate = a direct message; with --after or
      --at = a scheduled wake that fires later. A wake ALWAYS carries a prompt —
      there is no content-free ping. This is how you DM or nudge another
      session (or yourself).
      A matching fact or fallback delivers a new notification turn.
      It never resumes or replays prior work. The fact stamp reports why the prompt arrived.
      The accountable agent re-reads durable state and decides the next action.
      The fallback timer detects silence only; it does not select an action.
      --prompt is the caller's explicit instruction override.
      Tightbeam carries it without rewriting it.
        tightbeam wake --role reviewer --prompt "review PR 12" --as coder
        tightbeam wake --session agent:coder:app --prompt "check CI" --after 5m --as coder
        tightbeam wake --role owner --when-fact build-finished --when-scope app \
          --fallback-after 2h --prompt "re-read the work and decide" --as-process ci

  condition --kind <kind> [--scope <scope>] [--key <idempotencyKey>]
      File an observable fact. Matching condition wakes receive the fact as a new
      notification turn; they never resume or replay prior work.

  artifact-record --kind <kind> --title <title> --path <originPath>
                  [--description <text>] [--work-item <workItemId>] [--sha256 <hex>]
      Record a deliberate artifact pointer for the calling session.
  artifacts [--work-item <workItemId>] [--session <key>]
      List artifact rows matching every supplied exact filter.

  spawn --display "<name>" [--name <role>] [--archetype <a>]
        [--harness {{HARNESSES_PIPE}}] [--model <model>] [--effort <level>]
        [--context <variant>] [--host <host>] [--key <idempotencyKey>]
      Hire a new session (a worker). --display is its human label; --name
      registers a role bound to the new session — do NOT confuse it with --as,
      which is YOUR identity. --key makes the spawn idempotent
      (same key returns the same session). Omitted fields inherit the
      archetype's defaults.
        tightbeam spawn --display "Reviewer" --name reviewer:x \
          --harness {{EXAMPLE_HARNESS}} --model <catalog-model> --effort <level> \
          --as orchestrator:news
      --host picks a machine WITHIN the archetype's allowed set (see list's
      archetypes/hosts); omitted, the archetype's default placement applies.
      A model is named by FIELDS, never one packed string: --model is the
      model itself, --effort its reasoning level, --context the vendor's
      context-window variant when it offers more than one. All must come from
      list's model catalog — never invent one.

  list
      Show the sessions you can address (with handles + provenance), the
      org's shape — archetypes (with allowed hosts), known hosts, and the
      valid model catalog per harness — and, for admins, pending devices.
        tightbeam list --as orchestrator:news

  retire --session <key> [--key <idempotencyKey>]
      End a session deliberately.

  tune --session <key> (--harness <harness> --model <model> |
       --model <model> | --effort <level> | --fast on|off)
       [--effort <level>] [--context <variant>]
      Change one runtime control on an existing session. Model identity remains
      separate fields. Same-harness model, effort, and Fast changes preserve the
      engine conversation; a harness change starts a fresh engine context while
      keeping the Tightbeam session, role, work, and graph position. Fast is
      ephemeral and uses only the resident adapter's live advertised option;
      unsupported sessions refuse it. Naming the resident harness again is a
      refusal: omit --harness for a same-harness model change.

  work-item-create --title "<title>" [--spec-ref <name> --spec-sha256 <hex>]
                   [--key <idempotencyKey>]
      File a work item. Unrouted, it becomes YOUR problem on a deadline: file
      it, then route it (assign/dispatch) or icebox it. --key makes create
      idempotent (same key returns the same item).
  work-item-get <workItemId>
  work-item-trace <workItemId>
  attend [--high]
      Elect the attention tier of the reply you are about to give, during your
      own turn. --high marks it high; without the flag it is normal, which is
      also what electing nothing gives you. Those two, no others: `low` is in
      the same vocabulary but is the substrate's election over its own ambient
      notices, never something a reply asks for.
  transcript (--session <key> | --name <displayName>)
             [--before <messageId> | --after <messageId>] [--limit <n>]
      Read a session's conversation from the substrate's own rows. --name is a
      LOOKUP: it returns candidate sessions to choose from, never content.
      No cursor reads the tail (newest first page, shown oldest-first); page
      back with --before <oldestId> and catch up with --after <newestId>, both
      ids the previous response handed you. --limit defaults to 50, caps at 500.
  toplines [--origin user|session|all] [--owner <userId>] [--state <state>]
           [--quiet-over <duration>] [--spec <name> [--spec-sha <sha>]]
           [--session <key>] [--tree]
      The work telemetry the substrate already knows: every work item you can
      see, with its assignment/job/attest/turn counts, who holds it, whether
      anything is running, and how long it has been quiet. --tree renders the
      causal forest instead of a flat roster. Parent edges are derived from the
      turn that was RUNNING when each item was created, so they record
      concurrency, not proven causality — every node states its own
      epistemic status (linked, from_turn, no_turn_observed, unrecorded).
      No percentages and no completion estimates: the rows do not support them.
        tightbeam toplines --origin user --state open --as-user flynn
        tightbeam toplines --quiet-over 2h --as-user flynn
  topline (--under <workItemId> [roster filters] | --assignments <id,...>)
      --under walks one item's causal subtree (the anchor plus its visible
      linked descendants). --assignments names an explicit assignment set and
      reports the items they resolve to; an assignment belonging to no item
      comes back in noItem rather than being silently dropped.
        tightbeam topline --under wi_abc123 --as-user flynn
  work-item-icebox <workItemId>
      Shelve an unstaffed item (open → iceboxed). Requires zero open
      assignments; work-item-reopen resumes it.
  work-item-reopen <workItemId>
  work-item-close <workItemId>
      Conclude an item (→ closed). Requires zero open assignments.
  work-item-fail <workItemId> [--reason <text>]
      Rule an item failed (→ failed); --reason is recorded on the item.
  assign --subject "<work>" (--session <key> | --role <name>)
         [--key <key>] [--work-item <workItemId>]
         [--reviews <assignmentId>] [--effect-kind <kind>]
         [--files '["lib/a.ex","test/a_test.exs"]']
      Open an obligation held by a session; a work item is the durable thread
      across assignments. --files is an advisory suggestion that others can see;
      it reserves no path and does not limit the assignment's work.
  dispatch (--to <sessionKey> | --holder <sessionKey>) --subject "<work>"
           --brief "<one sentence>" [--work-item <workItemId>]
           [--effect-kind <kind>] [--workdir-root <relativePath>] [--key <key>]
      Atomically open an assignment and wake its holder with the card id.
  effort-rule --request <decisionRequestId> --action continue|dismiss
      Rule an effort-without-effect check-in whose complete id you hold. The
      current expecter is the preferred responder, not an authorization gate.
  operator-ask --question <q> [--note <t>] [--options a,b,c]
               [--assignment <asgId>] [--deadline <dur>] [--supersedes <dr_id>]
      File an owner-scoped operator decision request.
  operator-rule <dr_id> (--decision <label> | --response <text>)
                [--rationale <text>]
      Record the operator's resolution. Main and presenting proxies never run this command.
  operator-withdraw <dr_id> --reason <text>
      Withdraw an operator decision request as its owner or original asker.
  decision-requests [--status open|ruled|consumed|withdrawn|superseded|all]
      List decision requests visible to your principal.
  decision-request --request <decisionRequestId>
      Read one effort request by complete id. Other request kinds keep their
      existing visibility rules.
  revoke-assignment <assignmentId>
      Revoke when the assignment handler already authorizes your principal.
  attest <assignmentId> --kind progress|completion|surrender|verdict
      [--commit-refs '[{"repo":"host:/abs/path","commit":"<commit>"}]']
         [--verdict <kind>] [--note "..."]
      File against an assignment. Verdicts on review cards require the review
      holder; producer-card verdicts may be filed by any session or user.
  attests <assignmentId>
      List every attest filed against an assignment.
  assignments [--session <key> | --role <name>] [--state open|closed|all]
      List assignments (open by default).

  cancel-wake <wakeId>
      Cancel a pending (scheduled) wake by its id (from the wake command's
      output).

  kungfu list
      List the kungfu bundles shipped with this Tightbeam build and each
      bundle's declared root archetype.

  ADMIN (require --as-user of an admin, or an admin-owned agent handle):
  identity edit <archetype> [--manifest | --skill <name> [--rm]]
                [--file <path>]
      Edit the served identity. Without --file, content is read from stdin.
  identity relearn [--abort | --resolve]
      Re-import and merge the neutral seed plus every learned kungfu bundle;
      resolve or abort a conflict.
  identity repoint <retired-session> <archetype>
      Repoint a retired session row to an installed archetype.
  learn <bundle>
      Install a shipped kungfu bundle. Available bundles ship with Tightbeam
      under priv/kungfu/; learning an installed bundle is a no-op.
  unlearn <bundle>
      Remove a learned kungfu bundle by its committed receipt.
  identity status [<archetype>]
      Report the live revision, session revisions, staleness, and conflicts.
  identity apply (<session> | --all)
      Refresh selected sessions from the current live identity revision.
  onboard openai|anthropic [--api-key]
      Run this machine's model-provider credential onboarding flow. Without
      --api-key this is the interactive subscription ceremony. With it the flow is
      non-interactive and the KEY is read from stdin -- never as an argument,
      which would put a secret in this machine's process table:
        printenv ANTHROPIC_API_KEY | tightbeam onboard anthropic --api-key
      The key is validated against the provider before it is banked, and it
      never leaves this machine.
  onboard github [--hostname github.com] [--remote URL]
      Prove or create this host's GitHub CLI browser/device login, then stamp
      non-secret capability metadata. The credential is banked file-backed
      (0600) in Tightbeam's own gh config dir and agents reach it via
      GH_CONFIG_DIR, because daemon-descended agent environments cannot read
      the OS login keychain. With --remote, also prove git can read that
      repository. This never asks an agent for a PAT.

  add-user <userId> [--admin]
      Add a user, optionally as an admin. An existing admin may run this over
      the ordinary gateway path. On an empty local org, the first user is
      created directly and becomes admin by the existing cold-start rule.
  config get default-archetype                   read the default spawn archetype
  config set default-archetype <name>            set the default spawn archetype
  host-env-set --host <host> --harness <harness> NAME=VALUE
      Set one host- and harness-scoped environment overlay. The result states
      when the adapter will observe the new value.
  host-env-list [--host <host>] [--harness <harness>]
      List environment overlays, optionally filtered by exact host and harness.
  host-env-unset --host <host> --harness <harness> NAME
      Remove one exact environment overlay.
  host-toolchain-set --host <host> --dirs '<json-array>'
      Replace the host's ordered toolchain directories. An empty array restores
      the inherited PATH. The result previews the PATH shape adapters will use.
  harness-process list
      List the durable harness launch ledger, newest launch first.

  doctor [--json] [--base-dir p]
      Check the local Tightbeam installation and report its health.

  assimilate <ssh-dest> [--name n] [--base-dir p] [--harness {{HARNESSES_CSV}}]
             [--dry-run]
      Prepare a machine to run agent harnesses and register it as a host
      (admin). Probes ssh, node, npm, rsync and the CLI of every harness
      being enabled, creates the base dir, installs the ACP adapters and
      this CLI, and records the host. --dry-run runs that probe for real
      and writes nothing else.
      HARNESS CLIs ARE YOURS TO INSTALL. Tight Beam installs its own
      plumbing on a satellite — adapters, CLI, base dir — never the
      vendors' software, and --harness <h> means "enable h here", which
      presupposes h's CLI is already there. The probe sees only what a
      non-interactive ssh session sees, so a binary reachable through a
      login shell profile alone does not count. Credentials never
      transit between machines; run `tightbeam onboard` independently on
      the assimilated host.
      After: add the host to an archetype's `where`.
        tightbeam assimilate work-1.local --as-user flynn

DISCOVERY: the CLI walks up from cwd for .tightbeam-session first, then uses
  TIGHTBEAM_URL + TIGHTBEAM_TOKEN, then
  <TIGHTBEAM_BASE_DIR|TIGHTBEAM_HOME|~/.tightbeam>/gateway.json.

DURATIONS (for --after and --fallback-after): <n>ms | <n>s | <n>m | <n>h
  (e.g. 30s, 5m, 2h).

  tightbeam help | --help | -h   show this text.
  tightbeam version | --version  print this CLI's version."#;

pub fn render_help(catalog: Option<&HarnessCatalog>) -> String {
    let names = catalog.map(HarnessCatalog::names).unwrap_or_default();
    let pointer = "<registered; run tightbeam doctor>";
    let pipe = if names.is_empty() {
        pointer.to_owned()
    } else {
        names.join("|")
    };
    let csv = if names.is_empty() {
        pointer.to_owned()
    } else {
        names.join(",")
    };
    HELP_TEMPLATE
        .replace("{{HARNESSES_PIPE}}", &pipe)
        .replace("{{HARNESSES_CSV}}", &csv)
        .replace(
            "{{EXAMPLE_HARNESS}}",
            names.first().map(String::as_str).unwrap_or(pointer),
        )
}

/// One command's own entry, lifted out of the single help text rather than written
/// twice. An entry is its syntax line (two-space indent) plus every line indented
/// under it, which is exactly how COMMANDS is laid out.
pub fn render_command_help(catalog: Option<&HarnessCatalog>, command: &str) -> Option<String> {
    let help = render_help(catalog);
    let mut lines = help.lines().skip_while(|line| !opens_entry(line, command));
    let first = lines.next()?.to_owned();
    let rest = lines
        .take_while(|line| line.starts_with("   "))
        .collect::<Vec<_>>();
    Some(
        std::iter::once(first.as_str())
            .chain(rest)
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

fn opens_entry(line: &str, command: &str) -> bool {
    line.strip_prefix("  ").is_some_and(|rest| {
        !rest.starts_with(' ')
            && rest
                .strip_prefix(command)
                .is_some_and(|tail| tail.is_empty() || tail.starts_with(' '))
    })
}

const BOOLEAN_FLAGS: &[&str] = &[
    "abort", "admin", "all", "api-key", "dry-run", "help", "json", "manifest", "resolve", "rm",
    "tree",
];

#[derive(Debug)]
struct Flags {
    positional: Vec<String>,
    flags: HashMap<String, String>,
    duplicates: HashSet<String>,
}

fn split_args(args: Vec<String>) -> Flags {
    let mut positional = Vec::new();
    let mut flags = HashMap::new();
    let mut duplicates = HashSet::new();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if let Some(name) = arg.strip_prefix("--") {
            if BOOLEAN_FLAGS.contains(&name) {
                if flags.insert(name.to_owned(), String::new()).is_some() {
                    duplicates.insert(name.to_owned());
                }
            } else {
                let value = args.get(index + 1).cloned().unwrap_or_default();
                if flags.insert(name.to_owned(), value).is_some() {
                    duplicates.insert(name.to_owned());
                }
                index += 1;
            }
        } else {
            positional.push(arg.clone());
        }
        index += 1;
    }
    Flags {
        positional,
        flags,
        duplicates,
    }
}

fn nonempty(flags: &HashMap<String, String>, name: &str) -> Option<String> {
    flags.get(name).filter(|value| !value.is_empty()).cloned()
}

fn complete_decision_request_id(value: &str) -> bool {
    let Some(uuid) = value.strip_prefix("dr_") else {
        return false;
    };
    let bytes = uuid.as_bytes();

    bytes.len() == 36
        && [8, 13, 18, 23]
            .into_iter()
            .all(|index| bytes[index] == b'-')
        && bytes[14] == b'4'
        && matches!(bytes[19], b'8' | b'9' | b'a' | b'b')
        && bytes.iter().enumerate().all(|(index, byte)| {
            matches!(index, 8 | 13 | 18 | 23)
                || byte.is_ascii_digit()
                || matches!(byte, b'a'..=b'f')
        })
}

/// PRESENCE, for the fields where an empty value means something. `nonempty`
/// answers "is there a value here", which silently merges "not passed" with
/// "passed empty"; a model selection needs those apart, because an empty
/// `--context` is the default window and an absent one is a question the
/// caller did not answer.
fn named(flags: &HashMap<String, String>, name: &str) -> Option<Option<String>> {
    flags.get(name).map(|value| {
        if value.is_empty() {
            None
        } else {
            Some(value.clone())
        }
    })
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
        [] => Ok(Identity::Session),
        _ => Err(
            "identity flags are mutually exclusive: pass exactly one of --as, --as-user, or --as-process"
                .to_owned(),
        ),
    }
}

pub fn parse_after(text: &str) -> Result<String, String> {
    parse_duration("after", text)
}

fn parse_duration(flag: &str, text: &str) -> Result<String, String> {
    let (digits, multiplier) = if let Some(value) = text.strip_suffix("ms") {
        (value, 1.0)
    } else if let Some(value) = text.strip_suffix('s') {
        (value, 1_000.0)
    } else if let Some(value) = text.strip_suffix('m') {
        (value, 60_000.0)
    } else if let Some(value) = text.strip_suffix('h') {
        (value, 3_600_000.0)
    } else {
        return Err(bad_duration(flag, text));
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(bad_duration(flag, text));
    }
    let value = digits
        .parse::<f64>()
        .expect("an ASCII digit sequence parses as a JavaScript number");
    Ok(js_number_json(value * multiplier))
}

const TOPLINES_USAGE: &str = "usage: tightbeam toplines [--origin user|session|all] [--owner <userId>] [--state <state>] [--quiet-over <duration>] [--spec <name> [--spec-sha <sha>]] [--session <key>] [--tree]";

const TOPLINE_USAGE: &str = "usage: tightbeam topline (--under <workItemId> | --assignments <id,...>) [the same roster filters]";

/// Every roster-filter flag, in one place, so the assignment-mode refusal and the
/// filter builder cannot drift apart.
const ROSTER_FILTER_FLAGS: &[&str] = &[
    "origin",
    "owner",
    "state",
    "quiet-over",
    "spec",
    "spec-sha",
    "session",
];

fn topline_filters(flags: &HashMap<String, String>) -> Result<ToplineFilters, String> {
    // The origin enum is closed HERE: the reader treats anything but user or
    // session as "all", so an unrecognised value must never reach it silently.
    let origin = nonempty(flags, "origin");
    if let Some(value) = &origin {
        if !matches!(value.as_str(), "user" | "session" | "all") {
            return Err(format!(
                "bad --origin value: {value} (use user, session, or all)"
            ));
        }
    }
    // --spec-sha narrows a --spec cohort; alone it selects nothing nameable.
    if flags.contains_key("spec-sha") && nonempty(flags, "spec").is_none() {
        return Err("--spec-sha requires --spec <name>".to_owned());
    }
    Ok(ToplineFilters {
        origin,
        owner: nonempty(flags, "owner"),
        state: nonempty(flags, "state"),
        quiet_over_ms: nonempty(flags, "quiet-over")
            .map(|value| parse_duration("quiet-over", &value))
            .transpose()?,
        spec: nonempty(flags, "spec"),
        spec_sha: nonempty(flags, "spec-sha"),
        session: nonempty(flags, "session"),
    })
}

fn bad_duration(flag: &str, text: &str) -> String {
    format!("bad --{flag} value: {text} (use e.g. 30s, 5m, 2h)")
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
    parse_with_optional_catalog(args, None)
}

#[cfg(test)]
pub fn parse_with_catalog(args: Vec<String>, catalog: &HarnessCatalog) -> Result<Command, String> {
    parse_with_optional_catalog(args, Some(catalog))
}

fn parse_with_optional_catalog(
    args: Vec<String>,
    supplied_catalog: Option<&HarnessCatalog>,
) -> Result<Command, String> {
    let parsed = split_args(args);
    let command = parsed.positional.first().map(String::as_str);
    // `-h` never becomes a flag: split_args only recognizes `--`-prefixed names, so it
    // arrives as a positional and the old `flags["h"]` test could never fire.
    let asked_for_help = parsed.flags.contains_key("help")
        || parsed.positional.iter().any(|value| value == "-h")
        || command.is_none();
    match command {
        None => return Ok(Command::Help),
        // `help <command>` and `<command> --help` are the same question.
        Some("help" | "-h") => {
            return Ok(match parsed.positional.get(1) {
                Some(topic) => Command::CommandHelp(topic.clone()),
                None => Command::Help,
            });
        }
        Some(named) if asked_for_help => return Ok(Command::CommandHelp(named.to_owned())),
        Some(_) => {}
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
        "harness-process" => parse_harness_process(&parsed, flags),
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
            for (name, error) in [
                ("when-fact", "--when-fact requires a non-empty kind"),
                ("when-scope", "--when-scope requires a non-empty scope"),
                (
                    "fallback-after",
                    "--fallback-after requires a non-empty duration",
                ),
            ] {
                if flags.get(name).is_some_and(String::is_empty) {
                    return Err(error.to_owned());
                }
            }
            let after_ms = nonempty(flags, "after")
                .map(|value| parse_after(&value))
                .transpose()?;
            let fallback_after_ms = nonempty(flags, "fallback-after")
                .map(|value| parse_duration("fallback-after", &value))
                .transpose()?;
            let at = nonempty(flags, "at").map(|value| js_number_json(number_coercion(&value)));
            let condition_kind = nonempty(flags, "when-fact");
            let condition_scope = nonempty(flags, "when-scope");

            if condition_scope.is_some() && condition_kind.is_none() {
                return Err("--when-scope requires --when-fact".to_owned());
            }
            if fallback_after_ms.is_some() && condition_kind.is_none() {
                return Err("--fallback-after requires --when-fact".to_owned());
            }
            if after_ms.is_some() && fallback_after_ms.is_some() {
                return Err("--after and --fallback-after are mutually exclusive".to_owned());
            }
            if condition_kind.is_some() && after_ms.is_some() {
                return Err("--after cannot be used with --when-fact".to_owned());
            }
            if condition_kind.is_some() && fallback_after_ms.is_none() && at.is_none() {
                return Err(
                    "a condition wake requires a fallback (--fallback-after / --at)".to_owned(),
                );
            }
            if fallback_after_ms.is_some() && at.is_some() {
                return Err("--fallback-after and --at are mutually exclusive".to_owned());
            }
            let idempotency_key = condition_kind.as_ref().and_then(|_| nonempty(flags, "key"));
            Ok(Command::Wake {
                identity: identity(flags)?,
                target: targets.into_iter().next().expect("exactly one target"),
                prompt,
                after_ms: fallback_after_ms.or(after_ms),
                at,
                condition_kind,
                condition_scope,
                idempotency_key,
            })
        }
        "condition" => {
            if parsed.positional.len() != 1 {
                return Err(
                    "usage: tightbeam condition --kind <kind> [--scope <scope>] [--key <idempotencyKey>]"
                        .to_owned(),
                );
            }
            Ok(Command::Condition {
                identity: identity(flags)?,
                kind: nonempty(flags, "kind").ok_or_else(|| {
                    "--kind is required (a condition fact requires a kind)".to_owned()
                })?,
                scope: nonempty(flags, "scope"),
                idempotency_key: nonempty(flags, "key"),
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
        "tool-call-observed" => {
            if parsed.positional.len() != 1 || !flags.is_empty() {
                return Err("usage: tightbeam tool-call-observed".to_owned());
            }
            Ok(Command::ToolCallObserved)
        }
        "github-auth-check" => {
            if parsed.positional.len() != 1 || !flags.is_empty() {
                return Err("usage: tightbeam github-auth-check".to_owned());
            }
            Ok(Command::GithubAuthCheck)
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
            let harness = nonempty(flags, "harness");
            if let Some(name) = harness.as_deref() {
                let catalog = match supplied_catalog {
                    Some(catalog) => catalog.clone(),
                    None => crate::harnesses::catalog()?,
                };
                if !catalog.contains(name) {
                    return Err(format!("unsupported harness: {name}"));
                }
            }
            Ok(Command::Spawn {
                identity: identity(flags)?,
                display_name,
                idempotency_key: nonempty(flags, "key").unwrap_or_else(generated_key),
                archetype: nonempty(flags, "archetype"),
                harness,
                model: named(flags, "model"),
                effort: named(flags, "effort"),
                context: named(flags, "context"),
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
        "tune" => parse_tune(&parsed, flags),
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
                effect_kind: nonempty(flags, "effect-kind"),
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
                effect_kind: nonempty(flags, "effect-kind"),
                workdir_root: nonempty(flags, "workdir-root"),
                brief,
                idempotency_key: nonempty(flags, "key"),
            })
        }
        "effort-rule" => {
            let request_id = nonempty(flags, "request");
            let action = nonempty(flags, "action");
            if parsed.positional.get(1).is_some() || request_id.is_none() || action.is_none() {
                return Err(
                    "usage: tightbeam effort-rule --request <id> --action continue|dismiss"
                        .to_owned(),
                );
            }
            let action = action.expect("checked above");
            if action != "continue" && action != "dismiss" {
                return Err("--action must be continue or dismiss".to_owned());
            }
            Ok(Command::EffortRule {
                identity: identity(flags)?,
                request_id: request_id.expect("checked above"),
                action,
            })
        }
        "operator-ask" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam operator-ask --question <q> [--note <t>] [--options a,b,c] [--assignment <asgId>] [--deadline <dur>] [--supersedes <dr_id>]".to_owned());
            }
            let question =
                nonempty(flags, "question").ok_or_else(|| "--question is required".to_owned())?;
            let options = flags
                .get("options")
                .map(|value| value.split(',').map(str::to_owned).collect::<Vec<_>>());
            let deadline_ms = flags
                .get("deadline")
                .map(|value| parse_duration("deadline", value))
                .transpose()?;
            Ok(Command::OperatorAsk {
                identity: identity(flags)?,
                question,
                note: nonempty(flags, "note"),
                options,
                assignment_id: nonempty(flags, "assignment"),
                deadline_ms,
                supersedes: nonempty(flags, "supersedes"),
            })
        }
        "operator-rule" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam operator-rule <dr_id> (--decision <label> | --response <text>) [--rationale <text>]".to_owned());
            }
            let decision = flags.get("decision").cloned();
            let response = flags.get("response").cloned();
            if decision.is_some() == response.is_some() {
                return Err(
                    "operator-rule requires exactly one of --decision or --response".to_owned(),
                );
            }
            Ok(Command::OperatorRule {
                identity: identity(flags)?,
                request_id: parsed.positional[1].clone(),
                decision,
                response,
                rationale: nonempty(flags, "rationale"),
            })
        }
        "operator-withdraw" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam operator-withdraw <dr_id> --reason <text>".to_owned());
            }
            Ok(Command::OperatorWithdraw {
                identity: identity(flags)?,
                request_id: parsed.positional[1].clone(),
                reason: nonempty(flags, "reason")
                    .ok_or_else(|| "--reason is required".to_owned())?,
            })
        }
        "decision-requests" => {
            if parsed.positional.len() != 1 {
                return Err(
                    "usage: tightbeam decision-requests [--status open|ruled|consumed|withdrawn|superseded|all]".to_owned(),
                );
            }
            Ok(Command::DecisionRequests {
                identity: identity(flags)?,
                status: nonempty(flags, "status"),
            })
        }
        "decision-request" => {
            const ALLOWED: &[&str] = &["request", "as", "as-user", "as-process"];
            let request_id = nonempty(flags, "request");
            if parsed.positional.len() != 1
                || !request_id
                    .as_deref()
                    .is_some_and(complete_decision_request_id)
                || parsed.duplicates.contains("request")
                || flags.keys().any(|flag| !ALLOWED.contains(&flag.as_str()))
            {
                return Err(
                    "usage: tightbeam decision-request --request <decisionRequestId>".to_owned(),
                );
            }
            Ok(Command::DecisionRequest {
                identity: identity(flags)?,
                request_id: request_id.expect("checked above"),
            })
        }
        "revoke-assignment" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam revoke-assignment <assignmentId>".to_owned());
            }
            Ok(Command::RevokeAssignment {
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
                idempotency_key: nonempty(flags, "key"),
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
        "work-item-trace" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam work-item-trace <workItemId>".to_owned());
            }
            Ok(Command::WorkItemTrace {
                identity: identity(flags)?,
                work_item_id: parsed.positional[1].clone(),
            })
        }
        "attend" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam attend [--high]".to_owned());
            }
            Ok(Command::Attend {
                identity: identity(flags)?,
                high: flags.contains_key("high"),
            })
        }
        "transcript" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam transcript (--session <key> | --name <displayName>) [--before <messageId> | --after <messageId>] [--limit <n>]".to_owned());
            }
            let session = nonempty(flags, "session");
            let name = nonempty(flags, "name");
            // A name resolves to a CHOICE, never to content, so the two flags
            // are separate and never guessed between.
            if session.is_some() == name.is_some() {
                return Err(
                    "transcript requires exactly one of --session <key> or --name <displayName>"
                        .to_owned(),
                );
            }
            let before = nonempty(flags, "before");
            let after = nonempty(flags, "after");
            if before.is_some() && after.is_some() {
                return Err("transcript takes at most one of --before or --after".to_owned());
            }
            Ok(Command::Transcript {
                identity: identity(flags)?,
                session,
                name,
                before,
                after,
                // Same numeric coercion the other numeric flags use, rendered as
                // a JSON number so the handler receives an integer, not a string.
                limit: nonempty(flags, "limit")
                    .map(|value| js_number_json(number_coercion(&value))),
            })
        }
        "toplines" => {
            if parsed.positional.len() != 1 {
                return Err(TOPLINES_USAGE.to_owned());
            }
            Ok(Command::Toplines {
                identity: identity(flags)?,
                filters: topline_filters(flags)?,
                tree: flags.contains_key("tree"),
            })
        }
        "topline" => {
            if parsed.positional.len() != 1 {
                return Err(TOPLINE_USAGE.to_owned());
            }
            let under = nonempty(flags, "under");
            // Two different selections, never guessed between: --under walks the
            // causal forest, --assignments names an explicit assignment set.
            let assignments = flags.get("assignments").map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|id| !id.is_empty())
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            });
            let selection = match (under, assignments) {
                (Some(_), Some(_)) | (None, None) => {
                    return Err(
                        "topline requires exactly one of --under <workItemId> or --assignments <id,...>"
                            .to_owned(),
                    )
                }
                // Empty input is a USAGE error, not an empty result: the caller
                // named a set and named nothing in it.
                (None, Some(ids)) if ids.is_empty() => {
                    return Err("--assignments requires at least one assignment id".to_owned())
                }
                (None, Some(ids)) => {
                    // Refuse EARLY and LOUDLY. Accepting a filter here and dropping
                    // it later would promise a narrowing the contract cannot make:
                    // `--assignments X --state closed` would happily return an OPEN
                    // item. Naming the offered flags beats a generic usage line.
                    let offered = ROSTER_FILTER_FLAGS
                        .iter()
                        .filter(|flag| flags.contains_key(**flag))
                        .map(|flag| format!("--{flag}"))
                        .collect::<Vec<_>>();
                    if !offered.is_empty() {
                        return Err(format!(
                            "--assignments selects an explicit assignment set and takes no roster filters; drop {}",
                            offered.join(", ")
                        ));
                    }
                    ToplineSelection::Assignments(ids)
                }
                (Some(work_item_id), None) => ToplineSelection::Under {
                    work_item_id,
                    filters: topline_filters(flags)?,
                },
            };
            Ok(Command::Topline {
                identity: identity(flags)?,
                selection,
            })
        }
        "work-item-icebox" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam work-item-icebox <workItemId>".to_owned());
            }
            Ok(Command::WorkItemIcebox {
                identity: identity(flags)?,
                work_item_id: parsed.positional[1].clone(),
            })
        }
        "work-item-reopen" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam work-item-reopen <workItemId>".to_owned());
            }
            Ok(Command::WorkItemReopen {
                identity: identity(flags)?,
                work_item_id: parsed.positional[1].clone(),
            })
        }
        "work-item-close" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam work-item-close <workItemId>".to_owned());
            }
            Ok(Command::WorkItemClose {
                identity: identity(flags)?,
                work_item_id: parsed.positional[1].clone(),
            })
        }
        "work-item-fail" => {
            if parsed.positional.len() != 2 {
                return Err(
                    "usage: tightbeam work-item-fail <workItemId> [--reason <text>]".to_owned(),
                );
            }
            Ok(Command::WorkItemFail {
                identity: identity(flags)?,
                work_item_id: parsed.positional[1].clone(),
                reason: nonempty(flags, "reason"),
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
            let commit_refs = nonempty(flags, "commit-refs")
                .map(|encoded| {
                    serde_json::from_str::<Vec<serde_json::Value>>(&encoded)
                        .map_err(|_| "--commit-refs must be a JSON array".to_owned())
                })
                .transpose()?;
            Ok(Command::Attest {
                identity: identity(flags)?,
                assignment_id,
                kind,
                verdict,
                note: nonempty(flags, "note"),
                commit_refs,
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
        "kungfu" => {
            if parsed.positional.as_slice() != ["kungfu", "list"] {
                return Err("usage: tightbeam kungfu list".to_owned());
            }
            Ok(Command::KungfuList {
                identity: identity(flags)?,
            })
        }
        "learn" | "unlearn" => {
            if parsed.positional.len() != 2 {
                return Err(format!(
                    "usage: tightbeam {} <bundle>",
                    parsed.positional[0]
                ));
            }
            let name = parsed.positional[1].clone();
            let identity = identity(flags)?;
            if parsed.positional[0] == "learn" {
                Ok(Command::Learn { identity, name })
            } else {
                Ok(Command::Unlearn { identity, name })
            }
        }
        "onboard" => parse_onboard(&parsed, flags),
        "add-user" => {
            let user_id = parsed
                .positional
                .get(1)
                .cloned()
                .ok_or_else(|| "usage: tightbeam add-user <userId> [--admin]".to_owned())?;
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam add-user <userId> [--admin]".to_owned());
            }
            Ok(Command::AddUser {
                identity: identity(flags)?,
                user_id,
                admin: flags.contains_key("admin"),
            })
        }
        "config" => parse_config(&parsed, flags),
        "host-env-set" => parse_host_env_set(&parsed, flags),
        "host-env-list" => parse_host_env_list(&parsed, flags),
        "host-env-unset" => parse_host_env_unset(&parsed, flags),
        "host-toolchain-set" => parse_host_toolchain_set(&parsed, flags),
        "update-clients" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam update-clients --as-user <adminUserId>".to_owned());
            }
            let Some(as_user) = nonempty(flags, "as-user") else {
                return Err("--as-user is required for update-clients (admin required)".to_owned());
            };
            let selected_identity = identity(flags)?;
            debug_assert_eq!(selected_identity, Identity::User(as_user.clone()));
            Ok(Command::UpdateClients { as_user })
        }
        "assimilate" => {
            let ssh_dest = parsed.positional.get(1).cloned().ok_or_else(|| {
                "usage: tightbeam assimilate <ssh-dest> --as-user <adminUserId>".to_owned()
            })?;
            let Some(as_user) = nonempty(flags, "as-user") else {
                return Err("--as-user is required for assimilate (admin required)".to_owned());
            };
            let selected_identity = identity(flags)?;
            debug_assert_eq!(selected_identity, Identity::User(as_user.clone()));
            let catalog = match supplied_catalog {
                Some(catalog) => catalog.clone(),
                None => crate::harnesses::catalog()?,
            };
            let harnesses = match nonempty(flags, "harness") {
                Some(value) => value.split(',').map(str::to_owned).collect::<Vec<_>>(),
                None => catalog.names(),
            };
            if let Some(name) = harnesses.iter().find(|name| !catalog.contains(name)) {
                return Err(format!("unsupported harness: {name}"));
            }
            Ok(Command::Assimilate(AssimilateArgs {
                ssh_dest,
                as_user,
                name: nonempty(flags, "name"),
                base_dir: nonempty(flags, "base-dir").unwrap_or_else(|| "~/.tightbeam".to_owned()),
                harnesses,
                catalog,
                dry_run: flags.contains_key("dry-run"),
            }))
        }
        unknown => Err(format!(
            "unknown command: {unknown} — run 'tightbeam help' for usage. Commands: wake, condition, cancel-wake, attest, attests, assign, assignments, dispatch, effort-rule, operator-ask, operator-rule, operator-withdraw, decision-requests, decision-request, revoke-assignment, work-item-create, work-item-get, attend, transcript, toplines, topline, work-item-trace, work-item-icebox, work-item-reopen, work-item-close, work-item-fail, spawn, retire, list, identity, kungfu, learn, unlearn, onboard, add-user, artifact-record, artifacts, config, host-env-set, host-env-list, host-env-unset, host-toolchain-set, doctor, assimilate, harness-process"
        )),
    }
}

fn parse_host_env_set(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    let usage = "usage: tightbeam host-env-set --host <host> --harness <harness> NAME=VALUE";
    let assignment = parsed
        .positional
        .get(1)
        .filter(|_| parsed.positional.len() == 2)
        .ok_or_else(|| usage.to_owned())?;
    let (name, value) = assignment.split_once('=').ok_or_else(|| usage.to_owned())?;

    Ok(Command::HostEnvSet {
        identity: identity(flags)?,
        host: nonempty(flags, "host").ok_or_else(|| usage.to_owned())?,
        harness: nonempty(flags, "harness").ok_or_else(|| usage.to_owned())?,
        name: name.to_owned(),
        value: value.to_owned(),
    })
}

fn parse_host_env_list(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    if parsed.positional.len() != 1 {
        return Err(
            "usage: tightbeam host-env-list [--host <host>] [--harness <harness>]".to_owned(),
        );
    }

    Ok(Command::HostEnvList {
        identity: identity(flags)?,
        host: nonempty(flags, "host"),
        harness: nonempty(flags, "harness"),
    })
}

fn parse_host_env_unset(
    parsed: &Flags,
    flags: &HashMap<String, String>,
) -> Result<Command, String> {
    let usage = "usage: tightbeam host-env-unset --host <host> --harness <harness> NAME";
    let name = parsed
        .positional
        .get(1)
        .filter(|_| parsed.positional.len() == 2)
        .ok_or_else(|| usage.to_owned())?;

    Ok(Command::HostEnvUnset {
        identity: identity(flags)?,
        host: nonempty(flags, "host").ok_or_else(|| usage.to_owned())?,
        harness: nonempty(flags, "harness").ok_or_else(|| usage.to_owned())?,
        name: name.clone(),
    })
}

fn parse_host_toolchain_set(
    parsed: &Flags,
    flags: &HashMap<String, String>,
) -> Result<Command, String> {
    let usage = "usage: tightbeam host-toolchain-set --host <host> --dirs '<json-array>'";
    if parsed.positional.len() != 1 {
        return Err(usage.to_owned());
    }

    let encoded = nonempty(flags, "dirs").ok_or_else(|| usage.to_owned())?;
    let dirs = serde_json::from_str::<Vec<String>>(&encoded)
        .map_err(|_| "--dirs must be a JSON array of strings".to_owned())?;

    Ok(Command::HostToolchainSet {
        identity: identity(flags)?,
        host: nonempty(flags, "host").ok_or_else(|| usage.to_owned())?,
        dirs,
    })
}

fn parse_tune(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    const USAGE: &str = "usage: tightbeam tune --session <key> (--harness <harness> --model <model> [--effort <level>] [--context <variant>] | --model <model> [--effort <level>] [--context <variant>] | --effort <level> | --fast on|off)";
    const ALLOWED: &[&str] = &[
        "session",
        "harness",
        "model",
        "effort",
        "context",
        "fast",
        "as",
        "as-user",
        "as-process",
    ];

    if parsed.positional.len() != 1 || flags.keys().any(|name| !ALLOWED.contains(&name.as_str())) {
        return Err(USAGE.to_owned());
    }

    let required = |name: &str| {
        nonempty(flags, name).ok_or_else(|| format!("--{name} requires a non-empty value"))
    };
    let session_key = required("session")?;

    for name in ["harness", "model", "effort", "context", "fast"] {
        if flags.contains_key(name) && nonempty(flags, name).is_none() {
            return Err(format!("--{name} requires a non-empty value"));
        }
    }

    let harness = nonempty(flags, "harness");
    let model = nonempty(flags, "model");
    let effort = nonempty(flags, "effort");
    let context = nonempty(flags, "context");
    let fast = nonempty(flags, "fast");

    if model.as_deref().is_some_and(has_packed_effort) {
        return Err("--model must not pack an effort; pass --effort separately".to_owned());
    }

    let control = match (harness, model, effort, context, fast) {
        (Some(harness), Some(model), effort, context, None) => TuneControl::Harness {
            harness,
            model,
            effort,
            context,
        },
        (None, Some(model), effort, context, None) => TuneControl::Model {
            model,
            effort,
            context,
        },
        (None, None, Some(effort), None, None) => TuneControl::Effort(effort),
        (None, None, None, None, Some(fast)) if fast == "on" || fast == "off" => {
            TuneControl::Fast(fast)
        }
        (None, None, None, None, Some(_)) => return Err("--fast must be on or off".to_owned()),
        (Some(_), None, _, _, None) => return Err("--harness requires --model".to_owned()),
        (None, None, None, Some(_), None) => return Err("--context requires --model".to_owned()),
        (_, _, _, _, Some(_)) => {
            return Err(
                "--fast is mutually exclusive with --harness, --model, --effort, and --context"
                    .to_owned(),
            );
        }
        _ => return Err(USAGE.to_owned()),
    };

    Ok(Command::Tune {
        identity: identity(flags)?,
        session_key,
        control,
    })
}

fn has_packed_effort(model: &str) -> bool {
    model
        .rsplit_once('[')
        .and_then(|(_, suffix)| suffix.strip_suffix(']'))
        .is_some_and(|suffix| matches!(suffix, "low" | "medium" | "high" | "xhigh" | "max"))
}

fn parse_harness_process(
    parsed: &Flags,
    flags: &HashMap<String, String>,
) -> Result<Command, String> {
    match (
        parsed.positional.get(1).map(String::as_str),
        parsed.positional.get(2),
        parsed.positional.get(3),
    ) {
        (Some("list"), None, None) => Ok(Command::HarnessProcesses {
            identity: identity(flags)?,
        }),
        _ => Err("usage: tightbeam harness-process list".to_owned()),
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
        Some("repoint") if parsed.positional.len() == 4 => Ok(Command::IdentityRepoint {
            identity: identity(flags)?,
            session_key: parsed.positional[2].clone(),
            archetype: parsed.positional[3].clone(),
        }),
        Some("apply") => {
            let session_key = parsed.positional.get(2).cloned();
            let all = flags.contains_key("all");
            if parsed.positional.len() > 3 || all == session_key.is_some() {
                return Err("usage: tightbeam identity apply (<session> | --all)".to_owned());
            }
            Ok(Command::IdentityApply {
                identity: identity(flags)?,
                session_key,
                all,
            })
        }
        _ => Err("usage: tightbeam identity edit|status|relearn|repoint|apply ...".to_owned()),
    }
}

fn parse_onboard(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    if parsed.positional.len() != 2 {
        return Err("usage: tightbeam onboard <provider> [--api-key] [--hostname HOST]".to_owned());
    }
    let provider = parsed.positional[1].clone();
    let fixture_provider = cfg!(test) && provider == "fixture-provider";
    if !matches!(provider.as_str(), "openai" | "anthropic" | "github") && !fixture_provider {
        return Err("provider must be openai, anthropic, or github".to_owned());
    }
    let allowed = [
        "api-key",
        "hostname",
        "remote",
        "as",
        "as-user",
        "as-process",
    ];
    if flags.keys().any(|flag| !allowed.contains(&flag.as_str())) {
        return Err("usage: tightbeam onboard <provider> [--api-key] [--hostname HOST]".to_owned());
    }
    let hostname = nonempty(flags, "hostname");
    let remote = nonempty(flags, "remote");
    if provider == "github" && flags.contains_key("api-key") {
        return Err(
            "tightbeam onboard github does not accept --api-key; use GitHub CLI browser/device auth"
                .to_owned(),
        );
    }
    if provider == "github"
        && ["as", "as-user", "as-process"]
            .iter()
            .any(|flag| flags.contains_key(*flag))
    {
        return Err(
            "tightbeam onboard github is host-local and does not accept identity flags".to_owned(),
        );
    }
    if provider != "github" && hostname.is_some() {
        return Err("--hostname is only valid for tightbeam onboard github".to_owned());
    }
    if provider != "github" && remote.is_some() {
        return Err("--remote is only valid for tightbeam onboard github".to_owned());
    }
    Ok(Command::Onboard {
        identity: identity(flags)?,
        provider,
        // A BOOLEAN flag, deliberately. `--api-key <value>` would put the key in
        // this process's argv, where anyone on the box can read it out of the
        // process table. The key arrives on stdin instead.
        api_key: flags.contains_key("api-key"),
        hostname,
        remote,
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
    fn harness_process_operator_command_lists_launches() {
        assert_eq!(
            parse(strings(&["harness-process", "list", "--as-user", "flynn"])),
            Ok(Command::HarnessProcesses {
                identity: Identity::User("flynn".to_owned()),
            })
        );
    }

    #[test]
    fn host_env_commands_parse_exact_keys_and_preserve_values() {
        assert_eq!(
            parse(strings(&[
                "host-env-set",
                "--host",
                "gibson",
                "--harness",
                "claude",
                "EXAMPLE_OVERLAY_VAR=value=with=equals",
                "--as",
                "operator",
            ])),
            Ok(Command::HostEnvSet {
                identity: Identity::Role("operator".to_owned()),
                host: "gibson".to_owned(),
                harness: "claude".to_owned(),
                name: "EXAMPLE_OVERLAY_VAR".to_owned(),
                value: "value=with=equals".to_owned(),
            })
        );

        assert_eq!(
            parse(strings(&[
                "host-env-list",
                "--host",
                "gibson",
                "--harness",
                "claude",
                "--as-user",
                "flynn",
            ])),
            Ok(Command::HostEnvList {
                identity: Identity::User("flynn".to_owned()),
                host: Some("gibson".to_owned()),
                harness: Some("claude".to_owned()),
            })
        );

        assert_eq!(
            parse(strings(&[
                "host-env-unset",
                "--host",
                "gibson",
                "--harness",
                "claude",
                "EXAMPLE_OVERLAY_VAR",
                "--as-user",
                "flynn",
            ])),
            Ok(Command::HostEnvUnset {
                identity: Identity::User("flynn".to_owned()),
                host: "gibson".to_owned(),
                harness: "claude".to_owned(),
                name: "EXAMPLE_OVERLAY_VAR".to_owned(),
            })
        );
    }

    #[test]
    fn host_env_set_requires_host_harness_and_assignment() {
        for args in [
            strings(&["host-env-set", "EXAMPLE_OVERLAY_VAR=value"]),
            strings(&[
                "host-env-set",
                "--host",
                "gibson",
                "EXAMPLE_OVERLAY_VAR=value",
            ]),
            strings(&[
                "host-env-set",
                "--host",
                "gibson",
                "--harness",
                "claude",
                "EXAMPLE_OVERLAY_VAR",
            ]),
        ] {
            assert_eq!(
                parse(args),
                Err(
                    "usage: tightbeam host-env-set --host <host> --harness <harness> NAME=VALUE"
                        .to_owned()
                )
            );
        }
    }

    #[test]
    fn host_toolchain_set_parses_an_ordered_json_array_and_allows_the_empty_exit() {
        assert_eq!(
            parse(strings(&[
                "host-toolchain-set",
                "--host",
                "gibson",
                "--dirs",
                r#"["/tools/one","/tools/two"]"#,
                "--as-user",
                "flynn",
            ])),
            Ok(Command::HostToolchainSet {
                identity: Identity::User("flynn".to_owned()),
                host: "gibson".to_owned(),
                dirs: vec!["/tools/one".to_owned(), "/tools/two".to_owned()],
            })
        );

        assert_eq!(
            parse(strings(&[
                "host-toolchain-set",
                "--host",
                "gibson",
                "--dirs",
                "[]",
            ])),
            Ok(Command::HostToolchainSet {
                identity: Identity::Session,
                host: "gibson".to_owned(),
                dirs: vec![],
            })
        );
    }

    #[test]
    fn host_toolchain_set_refuses_missing_or_non_string_directory_lists() {
        let usage =
            "usage: tightbeam host-toolchain-set --host <host> --dirs '<json-array>'".to_owned();

        assert_eq!(
            parse(strings(&["host-toolchain-set", "--host", "gibson"])),
            Err(usage.clone())
        );
        assert_eq!(
            parse(strings(&["host-toolchain-set", "--dirs", r#"["/tools"]"#,])),
            Err(usage)
        );
        assert_eq!(
            parse(strings(&[
                "host-toolchain-set",
                "--host",
                "gibson",
                "--dirs",
                r#"[1]"#,
            ])),
            Err("--dirs must be a JSON array of strings".to_owned())
        );
    }

    /// `--help` was consumed before the command was ever looked at, so every
    /// subcommand answered with the whole manual — the operator asking about one
    /// command got 150 lines and had to find the answer themselves.
    #[test]
    fn a_named_command_gets_its_own_help_not_the_manual() {
        for args in [
            strings(&["assimilate", "--help"]),
            strings(&["assimilate", "-h"]),
            strings(&["help", "assimilate"]),
        ] {
            assert_eq!(
                parse(args),
                Ok(Command::CommandHelp("assimilate".to_owned()))
            );
        }
    }

    #[test]
    fn command_help_is_that_command_and_its_indented_lines_only() {
        let entry =
            render_command_help(Some(&crate::harnesses::catalog().unwrap()), "assimilate").unwrap();

        assert!(entry.starts_with("  assimilate <ssh-dest>"));
        assert!(entry.contains("[--dry-run]"), "{entry}");
        assert!(entry.contains("node, npm, rsync"), "{entry}");
        assert!(
            entry.contains("HARNESS CLIs ARE YOURS TO INSTALL"),
            "{entry}"
        );
        assert!(
            !entry.contains("DISCOVERY:") && !entry.contains("  doctor "),
            "the entry must stop at its own last line: {entry}"
        );
    }

    #[test]
    fn assign_help_calls_files_advisory_not_a_reservation_or_limit() {
        let entry = render_command_help(None, "assign").unwrap();

        for required in [
            "--files",
            "advisory suggestion",
            "others can see",
            "reserves no path",
            "does not limit",
        ] {
            assert!(
                entry.contains(required),
                "missing {required:?} from:\n{entry}"
            );
        }
    }

    #[test]
    fn wake_help_preserves_agent_agency_at_the_notification_boundary() {
        let entry = render_command_help(None, "wake").unwrap();

        for required in [
            "--when-fact <kind>",
            "new notification turn",
            "never resumes or replays prior work",
            "re-reads durable state and decides the next action",
            "fallback timer detects silence only",
            "caller's explicit instruction override",
            "without rewriting it",
        ] {
            assert!(
                entry.contains(required),
                "missing {required:?} from:\n{entry}"
            );
        }

        let manual = render_help(None);
        assert!(
            manual.contains("Processes may wake, cancel-wake, and file\n                       condition facts ONLY"),
            "{manual}"
        );
        assert!(!manual.contains("Processes may wake and cancel-wake ONLY"));
    }

    #[test]
    fn an_unknown_command_has_no_entry_to_print() {
        assert_eq!(
            render_command_help(Some(&crate::harnesses::catalog().unwrap()), "frobnicate"),
            None
        );
    }

    #[test]
    fn tune_legal_forms_are_typed_as_one_control_and_dispatch_separate_fields() {
        let cases = [
            (
                strings(&[
                    "tune",
                    "--session",
                    "agent:coder:x s_1",
                    "--harness",
                    "codex",
                    "--model",
                    "gpt-5.6-sol",
                    "--effort",
                    "high",
                    "--context",
                    "1m",
                    "--as",
                    "owner",
                ]),
                serde_json::json!({
                    "as": "owner",
                    "verb": "tune",
                    "sessionKey": "agent:coder:x s_1",
                    "params": {
                        "setting": "set_harness",
                        "harness": "codex",
                        "model": "gpt-5.6-sol",
                        "effort": "high",
                        "context": "1m"
                    }
                }),
            ),
            (
                strings(&[
                    "tune",
                    "--session",
                    "agent:coder:x s_1",
                    "--model",
                    "claude-fable-5[1m]",
                    "--effort",
                    "high",
                    "--as-user",
                    "mike",
                ]),
                serde_json::json!({
                    "asUser": "mike",
                    "verb": "tune",
                    "sessionKey": "agent:coder:x s_1",
                    "params": {
                        "setting": "set_model",
                        "model": "claude-fable-5[1m]",
                        "effort": "high"
                    }
                }),
            ),
            (
                strings(&[
                    "tune",
                    "--session",
                    "agent:coder:x s_1",
                    "--effort",
                    "xhigh",
                ]),
                serde_json::json!({
                    "verb": "tune",
                    "sessionKey": "agent:coder:x s_1",
                    "params": {"setting": "set_reasoning", "reasoningLevel": "xhigh"}
                }),
            ),
            (
                strings(&["tune", "--session", "agent:coder:x s_1", "--fast", "on"]),
                serde_json::json!({
                    "verb": "tune",
                    "sessionKey": "agent:coder:x s_1",
                    "params": {"setting": "set_fast_mode", "fastMode": "on"}
                }),
            ),
        ];

        for (args, expected) in cases {
            let command = parse(args).expect("legal tune form parses");
            let request = crate::dispatch::build_request(&command).expect("tune dispatches");
            assert_eq!(request.path, "/agent/dispatch");
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&request.body_json).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn tune_rejects_illegal_combinations_before_dispatch() {
        for args in [
            strings(&["tune", "--model", "gpt-5.6-sol"]),
            strings(&["tune", "--session", "s_1"]),
            strings(&["tune", "--session", "s_1", "--harness", "codex"]),
            strings(&["tune", "--session", "s_1", "--context", "1m"]),
            strings(&[
                "tune",
                "--session",
                "s_1",
                "--model",
                "gpt-5.6-sol",
                "--fast",
                "on",
            ]),
            strings(&["tune", "--session", "s_1", "--fast", "yes"]),
            strings(&["tune", "--session", "s_1", "--model", "gpt-5.6-sol[high]"]),
            strings(&["tune", "--session", "s_1", "--model", ""]),
            strings(&[
                "tune",
                "--session",
                "s_1",
                "--effort",
                "high",
                "--unknown",
                "value",
            ]),
        ] {
            assert!(parse(args).is_err());
        }
    }

    #[test]
    fn tune_help_names_continuity_and_live_fast_limit() {
        let entry = render_command_help(None, "tune").expect("tune has help");
        let prose = entry.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(prose.contains("one runtime control"), "{entry}");
        assert!(
            prose.contains("preserve the engine conversation"),
            "{entry}"
        );
        assert!(prose.contains("fresh engine context"), "{entry}");
        assert!(prose.contains("live advertised option"), "{entry}");
        assert!(prose.contains("ephemeral"), "{entry}");
        assert!(prose.contains("omit --harness"), "{entry}");
    }

    #[test]
    fn fixture_provider_is_additive_inside_the_test_provider_bundle() {
        assert_eq!(
            parse(strings(&[
                "onboard",
                "fixture-provider",
                "--as-user",
                "flynn"
            ])),
            Ok(Command::Onboard {
                identity: Identity::User("flynn".to_owned()),
                provider: "fixture-provider".to_owned(),
                api_key: false,
                hostname: None,
                remote: None,
            })
        );
    }

    #[test]
    fn github_onboard_is_host_local_and_has_no_api_key_path() {
        assert_eq!(
            parse(strings(&[
                "onboard",
                "github",
                "--hostname",
                "github.example"
            ])),
            Ok(Command::Onboard {
                identity: Identity::Session,
                provider: "github".to_owned(),
                api_key: false,
                hostname: Some("github.example".to_owned()),
                remote: None,
            })
        );
        assert_eq!(
            parse(strings(&[
                "onboard",
                "github",
                "--remote",
                "https://github.com/example/project.git"
            ])),
            Ok(Command::Onboard {
                identity: Identity::Session,
                provider: "github".to_owned(),
                api_key: false,
                hostname: None,
                remote: Some("https://github.com/example/project.git".to_owned()),
            })
        );
        assert_eq!(
            parse(strings(&["onboard", "github", "--as-user", "flynn"])),
            Err(
                "tightbeam onboard github is host-local and does not accept identity flags"
                    .to_owned()
            )
        );
        assert_eq!(
            parse(strings(&["onboard", "github", "--api-key"])),
            Err(
                "tightbeam onboard github does not accept --api-key; use GitHub CLI browser/device auth"
                    .to_owned()
            )
        );
        assert_eq!(
            parse(strings(&["onboard", "openai", "--hostname", "github.com"])),
            Err("--hostname is only valid for tightbeam onboard github".to_owned())
        );
    }

    #[test]
    fn update_clients_is_an_admin_fleet_ceremony() {
        assert_eq!(
            parse(strings(&["update-clients", "--as-user", "flynn"])),
            Ok(Command::UpdateClients {
                as_user: "flynn".to_owned()
            })
        );
        assert_eq!(
            parse(strings(&["update-clients"])),
            Err("--as-user is required for update-clients (admin required)".to_owned())
        );
    }

    #[test]
    fn add_user_names_the_target_separately_from_the_caller() {
        assert_eq!(
            parse(strings(&[
                "add-user",
                "guest",
                "--admin",
                "--as-user",
                "flynn"
            ])),
            Ok(Command::AddUser {
                identity: Identity::User("flynn".to_owned()),
                user_id: "guest".to_owned(),
                admin: true
            })
        );
        assert_eq!(
            parse(strings(&["add-user", "guest"])),
            Ok(Command::AddUser {
                identity: Identity::Session,
                user_id: "guest".to_owned(),
                admin: false
            })
        );
    }

    #[test]
    fn help_enumerates_exactly_cli_surface_v1() {
        let help = render_help(Some(&crate::harnesses::catalog().unwrap()));
        assert!(
            help.find("  kungfu list").unwrap() < help.find("  ADMIN (").unwrap(),
            "kungfu list is ungated discovery and must not appear under ADMIN"
        );
        let command_section = help
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
                "add-user",
                "cancel-wake",
                "condition",
                "config",
                "decision-request",
                "decision-requests",
                "dispatch",
                "doctor",
                "effort-rule",
                "harness-process",
                "host-env-list",
                "host-env-set",
                "host-env-unset",
                "host-toolchain-set",
                "identity",
                "kungfu",
                "learn",
                "list",
                "onboard",
                "operator-ask",
                "operator-rule",
                "operator-withdraw",
                "retire",
                "revoke-assignment",
                "spawn",
                "wake",
                "work-item-close",
                "work-item-create",
                "work-item-fail",
                "work-item-get",
                "attend",
                "transcript",
                "tune",
                "unlearn",
                "topline",
                "toplines",
                "work-item-trace",
                "work-item-icebox",
                "work-item-reopen",
            ]
            .into_iter()
            .collect()
        );
        for syntax in [
            "identity edit <archetype>",
            "identity relearn [--abort | --resolve]",
            "identity repoint <retired-session> <archetype>",
            "identity status [<archetype>]",
            "identity apply (<session> | --all)",
            "onboard openai|anthropic [--api-key]",
            "onboard github [--hostname github.com] [--remote URL]",
            "add-user <userId> [--admin]",
            "config get default-archetype",
            "config set default-archetype <name>",
            "host-env-set --host <host> --harness <harness> NAME=VALUE",
            "host-env-list [--host <host>] [--harness <harness>]",
            "host-env-unset --host <host> --harness <harness> NAME",
            "host-toolchain-set --host <host> --dirs '<json-array>'",
            "harness-process list",
            "kungfu list",
        ] {
            assert!(help.contains(syntax), "missing HELP syntax: {syntax}");
        }
    }

    #[test]
    fn help_uses_only_supplied_projection_names() {
        let catalog = HarnessCatalog {
            harnesses: vec![crate::harnesses::HarnessProjection {
                wire_name: "third".to_owned(),
                install_package: "third-package".to_owned(),
                cli_binary: "third-cli".to_owned(),
                process_markers: vec!["third-marker".to_owned()],
            }],
        };
        let help = render_help(Some(&catalog));
        assert!(help.contains("third"));
        assert!(!help.contains("claude"));
        assert!(!help.contains("codex"));
    }

    #[test]
    fn fixture_projection_drives_spawn_validation_and_assimilation_defaults() {
        let catalog = HarnessCatalog {
            harnesses: vec![crate::harnesses::HarnessProjection {
                wire_name: "fixture".to_owned(),
                install_package: "fixture-package".to_owned(),
                cli_binary: "fixture".to_owned(),
                process_markers: vec!["fixture-acp".to_owned()],
            }],
        };
        assert!(matches!(
            parse_with_catalog(strings(&[
                "spawn",
                "--display",
                "Fixture",
                "--key",
                "fixture-key",
                "--harness",
                "fixture",
                "--model",
                "fixture-model",
                "--as-user",
                "flynn",
            ]), &catalog),
            Ok(Command::Spawn {
                harness: Some(ref harness),
                ..
            }) if harness == "fixture"
        ));

        assert_eq!(
            parse_with_catalog(
                strings(&[
                    "spawn",
                    "--display",
                    "Unknown",
                    "--key",
                    "unknown-key",
                    "--harness",
                    "codex",
                    "--as-user",
                    "flynn",
                ]),
                &catalog
            ),
            Err("unsupported harness: codex".to_owned())
        );

        assert!(matches!(
            parse_with_catalog(strings(&[
                "assimilate",
                "flynn@host",
                "--as-user",
                "flynn",
            ]), &catalog),
            Ok(Command::Assimilate(AssimilateArgs { harnesses, catalog: parsed_catalog, .. }))
                if harnesses == vec!["fixture".to_owned()]
                    && parsed_catalog == catalog
        ));
    }

    // The blocking code-review finding on the first cut: the CLI attached roster
    // filters to BOTH topline modes and sent them, while the reader selects solely
    // by assignment id — so `--assignments X --state closed` could return an OPEN
    // item after the CLI had promised the filter was applied.
    #[test]
    fn assignment_selection_refuses_every_roster_filter() {
        for (flag, value) in [
            ("origin", "user"),
            ("owner", "flynn"),
            ("state", "closed"),
            ("quiet-over", "2h"),
            ("spec", "topline-map-v1"),
            ("spec-sha", &"a".repeat(64)[..]),
            ("session", "agent:coder:app"),
        ] {
            let error = parse(strings(&[
                "topline",
                "--assignments",
                "asg_x",
                &format!("--{flag}"),
                value,
                "--as-user",
                "flynn",
            ]))
            .expect_err(&format!("--{flag} must be refused in assignment mode"));

            assert!(
                error.contains("takes no roster filters") && error.contains(&format!("--{flag}")),
                "refusal must NAME the offered flag, got: {error}"
            );
        }
    }

    // The structural half: assignment selection has no filters field, so nothing
    // can be attached to it, and the built request carries only the id list. This
    // is what fails if someone re-attaches filters to this mode.
    #[test]
    fn assignment_selection_sends_only_the_id_list() {
        let command = parse(strings(&[
            "topline",
            "--assignments",
            "asg_a,asg_b",
            "--as-user",
            "flynn",
        ]))
        .expect("bare assignment selection parses");

        assert_eq!(
            command,
            Command::Topline {
                identity: Identity::User("flynn".to_owned()),
                selection: ToplineSelection::Assignments(vec![
                    "asg_a".to_owned(),
                    "asg_b".to_owned()
                ]),
            }
        );

        let body = crate::dispatch::build_request(&command)
            .expect("assignment selection dispatches")
            .body_json;

        assert!(
            body.contains(r#""assignments":["asg_a","asg_b"]"#),
            "got {body}"
        );

        for absent in [
            "origin",
            "owner",
            "state",
            "quietOver",
            "spec",
            "specSha",
            "session",
        ] {
            assert!(
                !body.contains(&format!("\"{absent}\"")),
                "assignment mode must send no roster filter, found {absent} in {body}"
            );
        }
    }

    // --under keeps its filters: the fix narrows assignment mode ONLY.
    #[test]
    fn under_selection_still_carries_roster_filters() {
        let command = parse(strings(&[
            "topline",
            "--under",
            "wi_abc",
            "--state",
            "closed",
            "--origin",
            "user",
            "--as-user",
            "flynn",
        ]))
        .expect("--under with filters parses");

        match &command {
            Command::Topline {
                selection: ToplineSelection::Under { filters, .. },
                ..
            } => {
                assert_eq!(filters.state.as_deref(), Some("closed"));
                assert_eq!(filters.origin.as_deref(), Some("user"));
            }
            other => panic!("expected --under selection, got {other:?}"),
        }

        let body = crate::dispatch::build_request(&command)
            .expect("under selection dispatches")
            .body_json;

        assert!(body.contains(r#""under":"wi_abc""#), "got {body}");
        assert!(body.contains(r#""state":"closed""#), "got {body}");
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
    fn parses_condition_wakes_and_condition_facts_with_optional_fields() {
        assert_eq!(
            parse(strings(&[
                "wake",
                "--role",
                "owner",
                "--when-fact",
                "build-finished",
                "--when-scope",
                "app",
                "--fallback-after",
                "2h",
                "--prompt",
                "re-read durable state",
                "--key",
                "wake-1",
                "--as-process",
                "ci",
            ])),
            Ok(Command::Wake {
                identity: Identity::Process("ci".to_owned()),
                target: Target::Role("owner".to_owned()),
                prompt: "re-read durable state".to_owned(),
                after_ms: Some("7200000".to_owned()),
                at: None,
                condition_kind: Some("build-finished".to_owned()),
                condition_scope: Some("app".to_owned()),
                idempotency_key: Some("wake-1".to_owned()),
            })
        );
        assert_eq!(
            parse(strings(&[
                "wake",
                "--session",
                "agent:owner",
                "--when-fact",
                "review-landed",
                "--at",
                "123",
                "--prompt",
                "decide what follows",
                "--as",
                "worker",
            ])),
            Ok(Command::Wake {
                identity: Identity::Role("worker".to_owned()),
                target: Target::Session("agent:owner".to_owned()),
                prompt: "decide what follows".to_owned(),
                after_ms: None,
                at: Some("123".to_owned()),
                condition_kind: Some("review-landed".to_owned()),
                condition_scope: None,
                idempotency_key: None,
            })
        );
        assert_eq!(
            parse(strings(&[
                "condition",
                "--kind",
                "review-landed",
                "--as-process",
                "review-hook",
            ])),
            Ok(Command::Condition {
                identity: Identity::Process("review-hook".to_owned()),
                kind: "review-landed".to_owned(),
                scope: None,
                idempotency_key: None,
            })
        );
    }

    #[test]
    fn refuses_invalid_condition_wake_and_fact_shapes_with_specific_messages() {
        for (args, expected) in [
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-scope",
                    "app",
                    "--prompt",
                    "decide",
                ]),
                "--when-scope requires --when-fact",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-fact",
                    "build-finished",
                    "--prompt",
                    "decide",
                ]),
                "a condition wake requires a fallback (--fallback-after / --at)",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--fallback-after",
                    "5m",
                    "--prompt",
                    "decide",
                ]),
                "--fallback-after requires --when-fact",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-fact",
                    "build-finished",
                    "--after",
                    "1m",
                    "--fallback-after",
                    "5m",
                    "--prompt",
                    "decide",
                ]),
                "--after and --fallback-after are mutually exclusive",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-fact",
                    "build-finished",
                    "--fallback-after",
                    "5m",
                    "--at",
                    "123",
                    "--prompt",
                    "decide",
                ]),
                "--fallback-after and --at are mutually exclusive",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-fact",
                    "build-finished",
                    "--after",
                    "1m",
                    "--prompt",
                    "decide",
                ]),
                "--after cannot be used with --when-fact",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-fact",
                    "build-finished",
                    "--after",
                    "1m",
                    "--at",
                    "123",
                    "--prompt",
                    "decide",
                ]),
                "--after cannot be used with --when-fact",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-fact",
                    "build-finished",
                    "--at",
                    "123",
                ]),
                "--prompt is required (a wake must carry a prompt)",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-fact",
                    "",
                    "--at",
                    "123",
                    "--prompt",
                    "decide",
                ]),
                "--when-fact requires a non-empty kind",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--when-scope",
                    "",
                    "--prompt",
                    "decide",
                ]),
                "--when-scope requires a non-empty scope",
            ),
            (
                strings(&[
                    "wake",
                    "--role",
                    "owner",
                    "--fallback-after",
                    "",
                    "--prompt",
                    "decide",
                ]),
                "--fallback-after requires a non-empty duration",
            ),
            (
                strings(&["condition", "--as-process", "ci"]),
                "--kind is required (a condition fact requires a kind)",
            ),
        ] {
            assert_eq!(parse(args), Err(expected.to_owned()));
        }
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
                identity: Identity::Session
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
            Err("unknown command: frobnicate — run 'tightbeam help' for usage. Commands: wake, condition, cancel-wake, attest, attests, assign, assignments, dispatch, effort-rule, operator-ask, operator-rule, operator-withdraw, decision-requests, decision-request, revoke-assignment, work-item-create, work-item-get, attend, transcript, toplines, topline, work-item-trace, work-item-icebox, work-item-reopen, work-item-close, work-item-fail, spawn, retire, list, identity, kungfu, learn, unlearn, onboard, add-user, artifact-record, artifacts, config, host-env-set, host-env-list, host-env-unset, host-toolchain-set, doctor, assimilate, harness-process".to_owned())
        );
    }

    #[test]
    fn operator_decision_commands_parse_the_exact_surface() {
        assert_eq!(
            parse(strings(&[
                "operator-ask",
                "--question",
                "ship window?",
                "--note",
                "release train",
                "--options",
                "accept,wait",
                "--assignment",
                "asg_1",
                "--deadline",
                "2h",
                "--supersedes",
                "dr_old",
                "--as",
                "coder:release",
            ])),
            Ok(Command::OperatorAsk {
                identity: Identity::Role("coder:release".to_owned()),
                question: "ship window?".to_owned(),
                note: Some("release train".to_owned()),
                options: Some(vec!["accept".to_owned(), "wait".to_owned()]),
                assignment_id: Some("asg_1".to_owned()),
                deadline_ms: Some("7200000".to_owned()),
                supersedes: Some("dr_old".to_owned()),
            })
        );

        assert_eq!(
            parse(strings(&[
                "operator-rule",
                "dr_1",
                "--response",
                "ship after 013",
                "--rationale",
                "dependency first",
                "--as-user",
                "mike",
            ])),
            Ok(Command::OperatorRule {
                identity: Identity::User("mike".to_owned()),
                request_id: "dr_1".to_owned(),
                decision: None,
                response: Some("ship after 013".to_owned()),
                rationale: Some("dependency first".to_owned()),
            })
        );

        assert_eq!(
            parse(strings(&[
                "operator-withdraw",
                "dr_2",
                "--reason",
                "moot after 013",
            ])),
            Ok(Command::OperatorWithdraw {
                identity: Identity::Session,
                request_id: "dr_2".to_owned(),
                reason: "moot after 013".to_owned(),
            })
        );
    }

    #[test]
    fn operator_rule_requires_one_answer_form() {
        for args in [
            strings(&["operator-rule", "dr_1"]),
            strings(&[
                "operator-rule",
                "dr_1",
                "--decision",
                "accept",
                "--response",
                "yes",
            ]),
        ] {
            assert_eq!(
                parse(args),
                Err("operator-rule requires exactly one of --decision or --response".to_owned())
            );
        }
    }

    #[test]
    fn decision_request_requires_one_exact_request_flag_and_closed_identity_flags() {
        let request_id = "dr_12345678-1234-4234-9234-123456789abc";

        assert_eq!(
            parse(strings(&[
                "decision-request",
                "--request",
                request_id,
                "--as",
                "reviewer",
            ])),
            Ok(Command::DecisionRequest {
                identity: Identity::Role("reviewer".to_owned()),
                request_id: request_id.to_owned(),
            })
        );

        for args in [
            strings(&["decision-request"]),
            strings(&["decision-request", request_id]),
            strings(&["decision-request", "--request", ""]),
            strings(&["decision-request", "--request", "dr_12345678"]),
            strings(&[
                "decision-request",
                "--request",
                request_id,
                "--request",
                "dr_87654321-4321-4321-8321-cba987654321",
            ]),
            strings(&[
                "decision-request",
                "--request",
                request_id,
                "--target",
                "main",
            ]),
        ] {
            assert_eq!(
                parse(args),
                Err("usage: tightbeam decision-request --request <decisionRequestId>".to_owned())
            );
        }
    }

    #[test]
    fn commands_outside_cli_surface_v1_are_not_exposed() {
        for command in [
            "rail-exec",
            "probe",
            "facts-read",
            "artifact-get",
            "rule",
            "waive",
            "revoke-waiver",
            "withdraw",
            "operator-supersede",
            "critical",
            "work-item-update",
            "work-item-list",
            "assignment-get",
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
                    condition_kind: None,
                    condition_scope: None,
                    idempotency_key: None,
                },
            ),
            (
                strings(&[
                    "condition",
                    "--kind",
                    "build-finished",
                    "--scope",
                    "app",
                    "--key",
                    "fact-1",
                    "--as-process",
                    "ci",
                ]),
                Command::Condition {
                    identity: Identity::Process("ci".to_owned()),
                    kind: "build-finished".to_owned(),
                    scope: Some("app".to_owned()),
                    idempotency_key: Some("fact-1".to_owned()),
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
                    "--effort",
                    "high",
                    "--context",
                    "1m",
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
                    model: Some(Some("gpt".to_owned())),
                    effort: Some(Some("high".to_owned())),
                    context: Some(Some("1m".to_owned())),
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
                strings(&[
                    "identity",
                    "repoint",
                    "agent:retired",
                    "default",
                    "--as-user",
                    "flynn",
                ]),
                Command::IdentityRepoint {
                    identity: Identity::User("flynn".to_owned()),
                    session_key: "agent:retired".to_owned(),
                    archetype: "default".to_owned(),
                },
            ),
            (
                strings(&["kungfu", "list", "--as-user", "flynn"]),
                Command::KungfuList {
                    identity: Identity::User("flynn".to_owned()),
                },
            ),
            (
                strings(&["learn", "agentic-engineering", "--as-user", "flynn"]),
                Command::Learn {
                    identity: Identity::User("flynn".to_owned()),
                    name: "agentic-engineering".to_owned(),
                },
            ),
            (
                strings(&["unlearn", "agentic-engineering", "--as-user", "flynn"]),
                Command::Unlearn {
                    identity: Identity::User("flynn".to_owned()),
                    name: "agentic-engineering".to_owned(),
                },
            ),
            (
                strings(&["onboard", "openai", "--as-user", "flynn"]),
                Command::Onboard {
                    identity: Identity::User("flynn".to_owned()),
                    provider: "openai".to_owned(),
                    api_key: false,
                    hostname: None,
                    remote: None,
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
                    catalog: crate::harnesses::catalog().unwrap(),
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
