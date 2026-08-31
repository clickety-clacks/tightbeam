//! Hand-parsed CLI arguments.
//!
//! Multiple explicit identity flags are rejected. Inside a session workdir,
//! omission lets the gateway derive the principal from the discovered session
//! credential.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::harnesses::HarnessCatalog;
use serde_json::Value;

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

#[derive(Debug, Clone, PartialEq)]
pub enum ActivationCommand {
    Declare {
        assignment: String,
        owner: String,
        domain: String,
        correlation: String,
        input: Value,
        target: Value,
        prior: Option<String>,
        relation: Option<String>,
        key: String,
    },
    Authority {
        activation: String,
        after: String,
        assignment: Option<String>,
        authorizer: Value,
        basis: Value,
        decision: Value,
        key: String,
    },
    Attempt {
        activation: String,
        after: String,
        assignment: String,
        authority_events: Vec<String>,
        executor: Value,
        external_attempt: Value,
        target_state_before: Value,
        key: String,
    },
    Observe {
        activation: String,
        after: String,
        assignment: Option<String>,
        attempt: String,
        certainty: String,
        result: Value,
        target_state_after: Value,
        outputs: Value,
        evidence: Value,
        external_occurred_at: Value,
        key: String,
    },
    Reconcile {
        activation: String,
        after: String,
        assignment: Option<String>,
        observation: String,
        certainty: String,
        result: Value,
        target_state_after: Value,
        outputs: Value,
        evidence: Value,
        external_occurred_at: Value,
        key: String,
    },
    Withdraw {
        activation: String,
        after: String,
        assignment: Option<String>,
        reason: Value,
        basis: Value,
        key: String,
    },
    Renotify {
        activation: String,
        after: String,
        noticed_event: String,
        replaces_wake: String,
        key: String,
    },
    Ack {
        activation: String,
        after: String,
        noticed_event: String,
        wake: String,
        key: String,
    },
    Status {
        activation: String,
    },
    List {
        assignment: Option<String>,
        work_item: Option<String>,
        correlation: Option<String>,
    },
}

/// The ONE runtime control a `tune` call changes.
///
/// A model is named by FIELDS — harness, model, effort, context — never by one
/// packed string, and these variants are how the CLI makes a partial naming
/// unrepresentable rather than merely discouraged. There is no state here
/// holding a `--context` with no model for it to qualify, or an effort tier
/// with nothing to apply it to: each variant is a complete election the
/// gateway can answer against the destination host's catalog.
///
/// Every field the caller does not name is left for the CATALOG to complete,
/// never for the CLI to invent — which is why the model fields are
/// `Option<Option<String>>` (see `Command::Spawn`): a flag not passed and a
/// flag passed empty are different requests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TuneControl {
    /// A different HARNESS. The engine changes, so the engine's conversation
    /// cannot come with it — Tightbeam's session, role, work, and graph
    /// position do. `model` is REQUIRED (v0.2 program §4: the substrate
    /// never elects) — the SOURCE model and its effort tier are never
    /// inherited across the boundary either, because a tier is vocabulary
    /// the destination may not have, so an omitted `--effort` on a model
    /// that offers tiers is refused rather than guessed.
    Harness {
        harness: String,
        model: String,
        effort: Option<Option<String>>,
        context: Option<Option<String>>,
    },
    /// A different MODEL on the resident harness. The conversation survives.
    Model {
        model: String,
        effort: Option<Option<String>>,
        context: Option<Option<String>>,
    },
    /// A different reasoning tier for the resident model.
    Effort(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Help,
    /// Help for one named command: `tightbeam assimilate --help`, `tightbeam help
    /// assimilate`. Printing the whole manual in answer to a question about one
    /// command buries the answer it was asked for.
    CommandHelp(String),
    /// Print only the nearest session credential's session key.
    IdentityCurrent,
    Doctor {
        json: bool,
        base_dir: Option<String>,
    },
    VisitorKeyringInit {
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
        /// The coordination class the SENDER elects (fabric v1 §7). Deliberately
        /// an unvalidated string: a kungfu may extend the vocabulary, and the
        /// substrate answers an unknown class with `fyi` delivery plus a named
        /// skew row, never a refusal.
        class: Option<String>,
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
    Activation {
        identity: Identity,
        command: ActivationCommand,
    },
    /// Substrate-reserved: the PreToolUse hook reporting that this session is
    /// about to run `artifact-record`. Carries no identity flag because the
    /// observation is the session's by definition — the gateway resolves the
    /// turn from the session token, so there is nothing for a flag to say.
    ToolCallObserved,
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
    /// Change one runtime control on a LIVE session. This is an ELECTION by
    /// the caller: nothing in Tightbeam re-engines a session on its own, so
    /// there is no form of this command that asks the substrate to choose.
    Tune {
        identity: Identity,
        session_key: String,
        control: TuneControl,
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
        effect_kind: Option<String>,
        files: Option<Vec<String>>,
        report_to: Option<String>,
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
        report_to: Option<String>,
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
    /// File one question at a named principal (coordination-fabric-v1 §7
    /// `input-needed` carrier). The row is data its asker chooses to honor:
    /// filing it blocks nothing, here or on the gateway.
    Ask {
        identity: Identity,
        target: Target,
        question: String,
        about: Option<String>,
    },
    Answer {
        identity: Identity,
        request_id: String,
        answer: String,
    },
    ReturnRequest {
        identity: Identity,
        request_id: String,
        reason: String,
    },
    RevokeAssignment {
        identity: Identity,
        assignment_id: String,
        reason: String,
    },
    ReopenAssignment {
        identity: Identity,
        assignment_id: String,
        reason: String,
    },
    RepairAssignment {
        identity: Identity,
        assignment_id: String,
        action: String,
        model: Option<String>,
        effort: Option<String>,
        context: Option<String>,
        outcome: Option<String>,
        turn_seq: Option<String>,
        idempotency_key: String,
    },
    WorkItemCreate {
        identity: Identity,
        title: String,
        spec_ref_name: Option<String>,
        spec_ref_sha256: Option<String>,
        priority: Option<String>,
        idempotency_key: Option<String>,
    },
    WorkItemUpdate {
        identity: Identity,
        work_item_id: String,
        title: Option<String>,
        spec_ref_name: Option<String>,
        spec_ref_sha256: Option<String>,
        clear_spec_ref: bool,
        priority: Option<String>,
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
    TurnTrace {
        identity: Identity,
        session: String,
        seq: String,
    },
    Toplines {
        identity: Identity,
        filters: ToplineFilters,
        tree: bool,
        /// Keyset cursor: the work item id the previous page ended on.
        after: Option<String>,
        limit: Option<String>,
    },
    Topline {
        identity: Identity,
        selection: ToplineSelection,
    },
    ToplineMutation {
        identity: Identity,
        verb: String,
        params: Vec<(String, String)>,
    },
    DurableToplines {
        identity: Identity,
        state: Option<String>,
    },
    DurableTopline {
        identity: Identity,
        topline_id: String,
        history: bool,
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
        release_fact_kind: Option<String>,
        release_fact_scope: Option<String>,
        release_fact_principal_ref: Option<String>,
    },
    Attests {
        identity: Identity,
        assignment_id: String,
        /// Keyset cursor: the attest id the previous page ended on.
        after: Option<String>,
        /// Page size, rendered as a JSON number. No default — an audit list that
        /// silently shortens itself is worse than a long one.
        limit: Option<String>,
    },
    CoordinationShare {
        identity: Identity,
        session: String,
        from: String,
        to: String,
    },
    DigestMembers {
        identity: Identity,
        wake_id: String,
    },
    Assignments {
        identity: Identity,
        target: Option<Target>,
        state: Option<String>,
    },
    CompletionNotices {
        identity: Identity,
        status: String,
        session_key: Option<String>,
    },
    CompletionDisposition {
        identity: Identity,
        completion_id: String,
        decision: String,
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
       [--class fyi|status-query|input-needed|blocker|algedonic]
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
      --class says how URGENT this is for the receiver, and you elect it: fyi and
      status-query and input-needed are batched into one digest turn at the
      receiver's next turn boundary (or their class ceiling — 4h, 30m, 30m —
      whichever comes first); blocker delivers immediately; algedonic bypasses
      batching entirely and is for genuine pain only. Without --class the wake
      delivers exactly as it always has. --after/--at is your own delivery
      election and always wins over batching. Every batched digest names the
      rule that produced it, so you can see what held your message.
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

  activation-declare --assignment A --owner U --domain N --correlation C
      --input RESOURCE_JSON --target RESOURCE_JSON
      [--prior ACT --relation retry-of|compensates|supersedes] --key K
  activation-authority --activation ACT --after EVENT [--assignment A]
      --authorizer IDENTITY_JSON --basis RESOURCE_JSON --decision CODE_JSON --key K
  activation-attempt --activation ACT --after EVENT --assignment A
      --authority-events ID[,ID...] --executor IDENTITY_JSON
      --external-attempt RESOURCE_JSON --target-state-before RESOURCE_JSON|null --key K
  activation-observe --activation ACT --after EVENT [--assignment A]
      --attempt EVENT --certainty determinate|indeterminate --result CODE_JSON
      --target-state-after RESOURCE_JSON|null --outputs RESOURCE_JSON_ARRAY
      --evidence RESOURCE_JSON --external-occurred-at MS|null --key K
  activation-reconcile --activation ACT --after EVENT [--assignment A]
      --observation EVENT --certainty determinate|irrecoverable --result CODE_JSON
      --target-state-after RESOURCE_JSON|null --outputs RESOURCE_JSON_ARRAY
      --evidence RESOURCE_JSON --external-occurred-at MS|null --key K
  activation-withdraw --activation ACT --after EVENT [--assignment A]
      --reason CODE_JSON --basis RESOURCE_JSON --key K
  activation-renotify --activation ACT --after EVENT --noticed-event EVENT
      --replaces-wake W --key K
  activation-ack --activation ACT --after EVENT --noticed-event EVENT --wake W --key K
  activation-status --activation ACT
  activations [--assignment A | --work-item WI | --correlation C]

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

  tune --session <key> (--harness {{HARNESSES_PIPE}} --model <model> |
       --model <model> | --effort <level>)
       [--effort <level>] [--context <variant>]
      Change ONE runtime control on a session that is already running. Model
      identity remains separate fields, exactly as in spawn, and every field is
      answered against that host's catalog — an invented harness or model is
      refused by name, never substituted.
        tightbeam tune --session "agent:coder:x s_1" \
          --harness {{EXAMPLE_HARNESS}} --model <catalog-model> --as orchestrator:news
      --model on its own retunes the model on the RESIDENT harness and the
      engine's conversation survives. --harness changes the engine, so its
      conversation cannot come along: the visible transcript restarts from an
      [engine swap] marker (earlier rows are retained, not deleted) while the
      Tightbeam session, its role, its work, and its graph position stay put.
      Naming the resident harness again is refused — omit --harness for a
      same-harness model change. --harness REQUIRES --model: crossing an
      engine boundary is a model election, and Tightbeam never elects on
      your behalf (omitting it is refused as model_required). The source
      model and its effort tier are never carried across the boundary.
      A switch is YOUR election and lands only at a turn boundary: while the
      session has a running or queued turn the call is refused with
      turn_in_progress and nothing changes. Retry once the turn finishes —
      Tightbeam will not queue the switch behind it, and never re-engines a
      session on its own initiative.

  list
      Show the sessions you can address (with handles + provenance), the
      org's shape — archetypes (with allowed hosts), known hosts, and the
      valid model catalog per harness — and, for admins, pending devices.
        tightbeam list --as orchestrator:news

  retire --session <key> [--key <idempotencyKey>]
      End a session deliberately.

  work-item-create --title "<title>" [--spec-ref <name> --spec-sha256 <hex>]
                   [--priority <0..8>] [--key <idempotencyKey>]
      File a work item. Unrouted, it becomes YOUR problem on a deadline: file
      it, then route it (assign/dispatch) or icebox it. --key makes create
      idempotent (same key returns the same item).
  work-item-update <workItemId> [--title "<title>"] [--spec-ref <name>]
                   [--spec-sha256 <hex>] [--clear-spec-ref] [--priority <0..8>]
      Patch an item's title, current governing spec, or priority. Omitted fields
      stay unchanged; --clear-spec-ref clears both spec-ref fields. Open cards
      inherit priority changes.
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
  turn-trace --session <key> --seq <turnSeq>
      Read the ordered lifecycle boundaries for one turn. The same owner-or-
      admin visibility rule as transcript applies; hidden and unknown turns
      both return not_found.
  execution-map [--origin user|session|all] [--owner <userId>] [--state <state>]
           [--quiet-over <duration>] [--spec <name> [--spec-sha <sha>]]
           [--session <key>] [--tree] [--after <workItemId>] [--limit <n>]
      The work telemetry the substrate already knows: every work item you can
      see, with its assignment/job/attest/turn counts, who holds it, whether
      anything is running, and how long it has been quiet. --tree renders the
      causal forest instead of a flat roster. Parent edges are derived from the
      turn that was RUNNING when each item was created, so they record
      concurrency, not proven causality — every node states its own
      epistemic status (linked, from_turn, no_turn_observed, unrecorded).
      No percentages and no completion estimates: the rows do not support them.
        tightbeam execution-map --origin user --state open --as-user flynn
      --after/--limit page the FLAT roster on a stable (createdAt, id) cursor;
      the response carries nextAfter and hasMoreAfter. They bound the RESPONSE,
      not the gateway's work — the reader still computes telemetry over every
      item you can see. They are refused with --tree, because a forest has no
      page boundary that is not also a wrong answer.
        tightbeam execution-map --quiet-over 2h --as-user flynn
        tightbeam execution-map --limit 25 --after wi_abc123 --as-user flynn
  execution-map-select (--under <workItemId> [roster filters] | --assignments <id,...>)
      --under walks one item's causal subtree (the anchor plus its visible
      linked descendants). --assignments names an explicit assignment set and
      reports the items they resolve to; an assignment belonging to no item
      comes back in noItem rather than being silently dropped.
        tightbeam execution-map-select --under wi_abc123 --as-user flynn
  toplines [--state open|closed|all]
      List your visible durable Toplines.
  topline <toplineId> [--history]
      Read one visible durable Topline; --history includes its event history.
  topline-create --title <text> --key <idempotencyKey>
  topline-update <toplineId> --title <text> --reason <text> --key <idempotencyKey>
  topline-close <toplineId> --reason <text> --key <idempotencyKey>
  topline-reopen <toplineId> --reason <text> --key <idempotencyKey>
  topline-link-work <toplineId> <workItemId> --reason <text> --key <idempotencyKey>
  topline-unlink-work <membershipId> --reason <text> --key <idempotencyKey>
  topline-concern-create <toplineId> --title <text> --key <idempotencyKey>
  topline-concern-update <concernId> --title <text> --reason <text> --key <idempotencyKey>
  topline-concern-resolve <concernId> --reason <text> --key <idempotencyKey>
  topline-concern-reopen <concernId> --reason <text> --key <idempotencyKey>
  topline-concern-link-work <concernId> <membershipId> --reason <text> --key <idempotencyKey>
  topline-concern-unlink-work <concernRefId> --reason <text> --key <idempotencyKey>
  topline-work-leave-unlinked <workItemId> --reason <text> --key <idempotencyKey>
  topline-placement-list [--state pending|resolved|all]
  coordination-share --session <key> --from <epochMs> --to <epochMs>
      What share of a session's turns were spent on coordination traffic over a
      window — every turn a wake materialized, classed or not, except an
      algedonic alarm or a deliberate summon, against all its turns. Counts
      rows and names no threshold; a window with no turns reports a null
      share, not zero.
        tightbeam coordination-share --session agent:po --from 1 --to 2 --as-user flynn
  digest-members <wakeId>
      Every source wake a digest carries, oldest first — the C4/acceptance-2
      audit as a status question, answerable from rows. Refuses by name if
      the id is unknown, is not a digest carrier, or names a carrier you
      cannot see — the same not_found either way.
        tightbeam digest-members w_abc123 --as-user flynn
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
         [--files '["lib/a.ex","test/a_test.exs"]'] [--report-to <sessionKey>]
      Open an obligation held by a session; a work item is the durable thread
      across assignments.
  dispatch (--to <sessionKey> | --holder <sessionKey>) --subject "<work>"
           --brief "<one sentence>" [--work-item <workItemId>]
           [--effect-kind <kind>] [--workdir-root <relativePath>] [--key <key>]
           [--report-to <sessionKey>]
      Atomically open an assignment and wake its holder with the card id.
  completion-notices --status open|all [--session <childSessionKey>]
      List visible completion notices, optionally for one exact child session.
  completion-disposition <completionId> --decision retain|park|retire
      Apply one authorized lifecycle disposition to an open completion request.
  effort-rule --request <decisionRequestId> --action continue|dismiss
      Rule an effort-without-effect check-in whose complete id you hold. The
      current expecter is the preferred responder, not an authorization gate.
  operator-ask --question <q> [--note <t>] [--options a,b,c]
               [--assignment <asgId>] [--deadline <dur>] [--supersedes <dr_id>]
      File an owner-scoped operator decision request.
  operator-rule <dr_id> (--decision <label> | --response <text>)
                [--rationale <text>]
      Record the operator's resolution. A session that presented the request runs it
      only on the operator's explicit delegation, quoted in --rationale.
  operator-withdraw <dr_id> --reason <text>
      Withdraw an operator decision request as its owner or original asker.
  decision-requests [--status open|ruled|consumed|withdrawn|superseded|returned|all]
      List decision requests visible to your principal.
  decision-request --request <decisionRequestId>
      Read one agent question or effort request by its complete id. For an
      agent session, the id is a reference: the request's expecter is the
      preferred responder, not an authorization gate. Reading a request is
      not an instruction to respond.
  ask (--session <key> | --role <name> | --user <id>) --question "<text>"
      [--about <assignmentId>]
      Put one question to another principal and get back its id. THE QUESTION
      HOLDS NOTHING: filing it does not pause your assignment, your turn, or
      anything else — you still owe what you owed, and you choose whether to
      wait for the answer, work something else, or file cannot-proceed with a reason. Read the
      answer with decision-requests / decision-request, take the question back
      with withdraw --request <id> --reason "...". The person you asked gets it
      at their next turn boundary, or within 30 minutes, whichever is first.
        tightbeam ask --role owner --question "ship behind a flag or block?" --as coder
  answer --request <decisionRequestId> --answer "<text>"
      Answer a question whose complete id you hold. It is an answer, not a
      ruling: it authorizes nothing and unblocks nothing on its own. The named
      expecter is the preferred responder, not an authorization gate.
  return --request <decisionRequestId> --reason "<text>"
      Return an open question whose complete id you hold for insufficient
      information. The original row and reason remain in history, it leaves
      the open queue, and its asker must revise or replace it with a new request
      if an answer is still needed.
  revoke-assignment <assignmentId> --reason "..."
      Revoke with a durable reason when the assignment handler authorizes your principal.
  reopen-assignment <assignmentId> --reason "..."
      Move a CLOSED assignment back to open so its holder can file the verdict
      or lifecycle row the card still owes — the agent-reachable repair for a
      card that closed carrying the wrong judgment. The prior close is kept on
      the record. Refuses by name when the card is already open, its holder is
      retired, its work item is not open, or its files collide.
  repair-assignment <assignmentId> --action tune|restart|rerun|resume|relaunch --key <key>
      Repair a failed or never-launched holder without revoking its work.
      tune also requires --model; rerun requires --outcome not-completed.
  attest <assignmentId> --kind progress|completion|cannot-proceed|verdict
      [--commit-refs '[{"repo":"host:/abs/path","commit":"<commit>"}]']
         [--verdict <kind>] [--note "..."]
         [--release-fact-kind <kind> --release-fact-scope <scope>
          --release-fact-principal-ref <principal>]
      File against an assignment. Verdicts on review cards require the review
      holder; producer-card verdicts may be filed by any session or user.
      cannot-proceed requires a non-empty --note, keeps the card open, and
      accepts the three release-fact flags only as one complete tuple.
  attests <assignmentId> [--after <attestId>] [--limit <n>]
      List every attest filed against an assignment. Without --limit you get
      all of them: an audit list that shortens itself silently is worse than a
      long one. --after <attestId> resumes strictly after the attest you name,
      so you can walk a long trail without re-reading it; the response carries
      nextAfter and hasMoreAfter to drive the next call.
        tightbeam attests as_abc --limit 50 --as-user flynn
  assignments [--session <key> | --role <name>] [--state open|closed|all]
      List assignments (open by default).

  cancel-wake <wakeId>
      Cancel a pending (scheduled) wake by its id (from the wake command's
      output).

  kungfu list
      List the kungfu bundles shipped with this Tightbeam build and each
      bundle's declared root archetype.

  identity current
      Print this session's key without printing its bearer credential.

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
      Run this machine's credential onboarding flow. Without --api-key this is
      the interactive subscription ceremony. With it the flow is
      non-interactive and the KEY is read from stdin -- never as an argument,
      which would put a secret in this machine's process table:
        printenv ANTHROPIC_API_KEY | tightbeam onboard anthropic --api-key
      The key is validated against the provider before it is banked, and it
      never leaves this machine.

  add-user <userId> [--admin]
      Add a user, optionally as an admin. An existing admin may run this over
      the ordinary gateway path. On an empty local org, the first user is
      created directly and becomes admin by the existing cold-start rule.
  config get default-archetype|default-priority  read an organization default
  config set default-archetype <name>            set the default spawn archetype
  config set default-priority <0..8>              set the default card priority
  host-env-set --host <host> --harness <harness> NAME=VALUE
      Set one host- and harness-scoped environment overlay. The result states
      when the adapter will observe the new value.
  host-env-list [--host <host>] [--harness <harness>]
      List environment overlays, optionally filtered by exact host and harness.
  host-env-unset --host <host> --harness <harness> NAME
      Remove one exact environment overlay.
  harness-process list
      List the durable harness launch ledger, newest launch first.

  doctor [--json] [--base-dir p]
      Check the local Tightbeam installation and report its health.

  visitor keyring-init [--base-dir p]
      Provision the local visitor credential keyring through locked,
      same-directory, atomic no-replace publication. Prints only the final
      path and active key ids after the keyring is durable and verified.

  assimilate <ssh-dest> [--name n] [--base-dir p] [--harness {{HARNESSES_CSV}}]
             [--dry-run]
      Prepare a machine to run agent harnesses and register it as a host
      (admin). Probes ssh, node, npm, rsync and the CLI of every harness
      being enabled, creates the base dir, installs the ACP adapters and
      this CLI, and records the host. --dry-run runs that probe for real
      and writes nothing else.
      HARNESS CLIs ARE YOURS TO INSTALL. Tightbeam installs its own
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
    "abort",
    "admin",
    "all",
    "api-key",
    "clear-spec-ref",
    "dry-run",
    "help",
    "history",
    "json",
    "manifest",
    "resolve",
    "rm",
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

const TUNE_USAGE: &str = "usage: tightbeam tune --session <key> (--harness <harness> --model <model> | --model <model> | --effort <level>) [--effort <level>] [--context <variant>]";

/// TIGHTBEAM'S FIELDS ARE NEVER PACKED INTO ONE STRING.
///
/// `--model`, `--effort`, and `--context` are separate flags for a reason:
/// Tightbeam once spelled a reasoning tier `gpt-5.6-sol[high]`, colliding with
/// the vendor's own context-variant syntax (`claude-fable-5[1m]`), and a
/// catalog read the vendor's bracket as ours — the 1M-context model silently
/// ceased to exist.
///
/// This function used to allow the vendor's syntax through by checking the
/// bracket's CONTENTS against a hardcoded list of Tightbeam's own tier words
/// (`low`/`medium`/`high`/`xhigh`/`max`). That list already went stale once —
/// the reviewed catalog offers `ultra` too (`test/model_catalog_test.exs`) —
/// and a fixed vocabulary can never keep up with a PER-MODEL catalog this
/// binary does not always carry at parse time (F7, Sol xhigh review). So the
/// check no longer inspects what is inside the brackets at all: ANY bracketed
/// suffix on `--model` is packed form and is refused, naming where the field
/// actually belongs. A caller who wants a vendor context variant passes it as
/// `--context`, the field that exists for exactly that.
fn has_packed_effort(model: &str) -> bool {
    model.ends_with(']') && model.contains('[')
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

const ATTESTS_USAGE: &str =
    "usage: tightbeam attests <assignmentId> [--after <attestId>] [--limit <n>]";

// `--after`/`--limit` are shared by `attests` and `toplines` (seam ④), so the
// two flags are parsed once. An EMPTY value is a refusal rather than "no
// cursor": a caller that typed the flag meant something by it, and quietly
// dropping it would return page one while the caller believes it holds page two.
fn cursor_flag(
    flags: &HashMap<String, String>,
    name: &str,
    expects: &str,
) -> Result<Option<String>, String> {
    if flags.get(name).is_some_and(String::is_empty) {
        return Err(format!("--{name} requires {expects}"));
    }
    Ok(nonempty(flags, name))
}

fn page_limit(flags: &HashMap<String, String>) -> Result<Option<String>, String> {
    match nonempty(flags, "limit") {
        None if flags.contains_key("limit") => {
            Err("--limit requires a positive integer".to_owned())
        }
        None => Ok(None),
        Some(text) => match text.parse::<u32>() {
            Ok(value) if value > 0 => Ok(Some(value.to_string())),
            _ => Err("--limit requires a positive integer".to_owned()),
        },
    }
}

const ASK_USAGE: &str = "usage: tightbeam ask (--session <key> | --role <name> | --user <id>) --question \"<text>\" [--about <assignmentId>]";

const ANSWER_USAGE: &str =
    "usage: tightbeam answer --request <decisionRequestId> --answer \"<text>\"";
const RETURN_USAGE: &str =
    "usage: tightbeam return --request <decisionRequestId> --reason \"<text>\"";

const COORDINATION_SHARE_USAGE: &str =
    "usage: tightbeam coordination-share --session <key> --from <epochMs> --to <epochMs>";

const TOPLINES_USAGE: &str = "usage: tightbeam execution-map [--origin user|session|all] [--owner <userId>] [--state <state>] [--quiet-over <duration>] [--spec <name> [--spec-sha <sha>]] [--session <key>] [--tree]";

const TOPLINE_USAGE: &str = "usage: tightbeam execution-map-select (--under <workItemId> | --assignments <id,...>) [the same roster filters]";
const DURABLE_TOPLINES_USAGE: &str = "usage: tightbeam toplines [--state open|closed|all]";
const DURABLE_TOPLINE_USAGE: &str = "usage: tightbeam topline <toplineId> [--history]";

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

fn topline_mutation(
    verb: &str,
    positional: &[String],
    flags: &HashMap<String, String>,
) -> Result<Command, String> {
    let required = |name| nonempty(flags, name).ok_or_else(|| format!("{verb} requires --{name}"));
    let exact = |count| {
        if positional.len() == count {
            Ok(())
        } else {
            Err(format!(
                "usage: tightbeam {verb} has an invalid argument count"
            ))
        }
    };
    let key = || required("key").map(|value| ("idempotencyKey".to_owned(), value));
    let reason = || required("reason").map(|value| ("reason".to_owned(), value));
    let title = || required("title").map(|value| ("title".to_owned(), value));

    let params = match verb {
        "topline-create" => {
            exact(1)?;
            vec![title()?, key()?]
        }
        "topline-update" => {
            exact(2)?;
            vec![
                ("toplineId".to_owned(), positional[1].clone()),
                title()?,
                reason()?,
                key()?,
            ]
        }
        "topline-close" | "topline-reopen" => {
            exact(2)?;
            vec![
                ("toplineId".to_owned(), positional[1].clone()),
                reason()?,
                key()?,
            ]
        }
        "topline-link-work" => {
            exact(3)?;
            vec![
                ("toplineId".to_owned(), positional[1].clone()),
                ("workItemId".to_owned(), positional[2].clone()),
                reason()?,
                key()?,
            ]
        }
        "topline-unlink-work" => {
            exact(2)?;
            vec![
                ("membershipId".to_owned(), positional[1].clone()),
                reason()?,
                key()?,
            ]
        }
        "topline-concern-create" => {
            exact(2)?;
            vec![
                ("toplineId".to_owned(), positional[1].clone()),
                title()?,
                key()?,
            ]
        }
        "topline-concern-update" => {
            exact(2)?;
            vec![
                ("concernId".to_owned(), positional[1].clone()),
                title()?,
                reason()?,
                key()?,
            ]
        }
        "topline-concern-resolve" | "topline-concern-reopen" => {
            exact(2)?;
            vec![
                ("concernId".to_owned(), positional[1].clone()),
                reason()?,
                key()?,
            ]
        }
        "topline-concern-link-work" => {
            exact(3)?;
            vec![
                ("concernId".to_owned(), positional[1].clone()),
                ("membershipId".to_owned(), positional[2].clone()),
                reason()?,
                key()?,
            ]
        }
        "topline-concern-unlink-work" => {
            exact(2)?;
            vec![
                ("concernRefId".to_owned(), positional[1].clone()),
                reason()?,
                key()?,
            ]
        }
        "topline-work-leave-unlinked" => {
            exact(2)?;
            vec![
                ("workItemId".to_owned(), positional[1].clone()),
                reason()?,
                key()?,
            ]
        }
        _ => return Err(format!("unknown Topline operation: {verb}")),
    };

    Ok(Command::ToplineMutation {
        identity: identity(flags)?,
        verb: verb.to_owned(),
        params,
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

fn activation_json(flags: &HashMap<String, String>, name: &str) -> Result<Value, String> {
    let encoded = nonempty(flags, name).ok_or_else(|| format!("--{name} is required"))?;
    serde_json::from_str(&encoded).map_err(|_| format!("--{name} requires JSON"))
}

fn activation_required(flags: &HashMap<String, String>, name: &str) -> Result<String, String> {
    nonempty(flags, name).ok_or_else(|| format!("--{name} is required"))
}

fn parse_activation(
    name: &str,
    parsed: &Flags,
    flags: &HashMap<String, String>,
) -> Result<Command, String> {
    if parsed.positional.len() != 1 {
        return Err(format!("usage: tightbeam {name} [flags]"));
    }

    let command_flags: &[&str] = match name {
        "activation-declare" => &[
            "assignment",
            "owner",
            "domain",
            "correlation",
            "input",
            "target",
            "prior",
            "relation",
            "key",
        ],
        "activation-authority" => &[
            "activation",
            "after",
            "assignment",
            "authorizer",
            "basis",
            "decision",
            "key",
        ],
        "activation-attempt" => &[
            "activation",
            "after",
            "assignment",
            "authority-events",
            "executor",
            "external-attempt",
            "target-state-before",
            "key",
        ],
        "activation-observe" => &[
            "activation",
            "after",
            "assignment",
            "attempt",
            "certainty",
            "result",
            "target-state-after",
            "outputs",
            "evidence",
            "external-occurred-at",
            "key",
        ],
        "activation-reconcile" => &[
            "activation",
            "after",
            "assignment",
            "observation",
            "certainty",
            "result",
            "target-state-after",
            "outputs",
            "evidence",
            "external-occurred-at",
            "key",
        ],
        "activation-withdraw" => &[
            "activation",
            "after",
            "assignment",
            "reason",
            "basis",
            "key",
        ],
        "activation-renotify" => &[
            "activation",
            "after",
            "noticed-event",
            "replaces-wake",
            "key",
        ],
        "activation-ack" => &["activation", "after", "noticed-event", "wake", "key"],
        "activation-status" => &["activation"],
        "activations" => &["assignment", "work-item", "correlation"],
        _ => unreachable!("closed activation command set"),
    };
    if flags.keys().any(|flag| {
        !command_flags.contains(&flag.as_str())
            && !matches!(flag.as_str(), "as" | "as-user" | "as-process")
    }) {
        return Err(format!("usage: tightbeam {name} [flags]"));
    }

    let identity = identity(flags)?;
    let command = match name {
        "activation-declare" => {
            let prior = nonempty(flags, "prior");
            let relation = nonempty(flags, "relation");
            if prior.is_some() != relation.is_some()
                || relation.as_deref().is_some_and(|value| {
                    !matches!(value, "retry-of" | "compensates" | "supersedes")
                })
            {
                return Err("--prior and --relation must be supplied together; relation is retry-of, compensates, or supersedes".to_owned());
            }
            ActivationCommand::Declare {
                assignment: activation_required(flags, "assignment")?,
                owner: activation_required(flags, "owner")?,
                domain: activation_required(flags, "domain")?,
                correlation: activation_required(flags, "correlation")?,
                input: activation_json(flags, "input")?,
                target: activation_json(flags, "target")?,
                prior,
                relation,
                key: activation_required(flags, "key")?,
            }
        }
        "activation-authority" => ActivationCommand::Authority {
            activation: activation_required(flags, "activation")?,
            after: activation_required(flags, "after")?,
            assignment: nonempty(flags, "assignment"),
            authorizer: activation_json(flags, "authorizer")?,
            basis: activation_json(flags, "basis")?,
            decision: activation_json(flags, "decision")?,
            key: activation_required(flags, "key")?,
        },
        "activation-attempt" => {
            let authority_events = activation_required(flags, "authority-events")?
                .split(',')
                .map(str::to_owned)
                .collect::<Vec<_>>();
            if authority_events.iter().any(String::is_empty) {
                return Err(
                    "--authority-events requires a non-empty comma-separated list".to_owned(),
                );
            }
            ActivationCommand::Attempt {
                activation: activation_required(flags, "activation")?,
                after: activation_required(flags, "after")?,
                assignment: activation_required(flags, "assignment")?,
                authority_events,
                executor: activation_json(flags, "executor")?,
                external_attempt: activation_json(flags, "external-attempt")?,
                target_state_before: activation_json(flags, "target-state-before")?,
                key: activation_required(flags, "key")?,
            }
        }
        "activation-observe" | "activation-reconcile" => {
            let certainty = activation_required(flags, "certainty")?;
            let external_occurred_at = activation_json(flags, "external-occurred-at")?;
            if !external_occurred_at.is_null()
                && external_occurred_at
                    .as_u64()
                    .is_none_or(|value| value > i64::MAX as u64)
            {
                return Err("--external-occurred-at requires an integer from 0 through 9223372036854775807 or null".to_owned());
            }
            let common = (
                activation_required(flags, "activation")?,
                activation_required(flags, "after")?,
                nonempty(flags, "assignment"),
                certainty,
                activation_json(flags, "result")?,
                activation_json(flags, "target-state-after")?,
                activation_json(flags, "outputs")?,
                activation_json(flags, "evidence")?,
                external_occurred_at,
                activation_required(flags, "key")?,
            );
            if name == "activation-observe" {
                ActivationCommand::Observe {
                    activation: common.0,
                    after: common.1,
                    assignment: common.2,
                    attempt: activation_required(flags, "attempt")?,
                    certainty: common.3,
                    result: common.4,
                    target_state_after: common.5,
                    outputs: common.6,
                    evidence: common.7,
                    external_occurred_at: common.8,
                    key: common.9,
                }
            } else {
                ActivationCommand::Reconcile {
                    activation: common.0,
                    after: common.1,
                    assignment: common.2,
                    observation: activation_required(flags, "observation")?,
                    certainty: common.3,
                    result: common.4,
                    target_state_after: common.5,
                    outputs: common.6,
                    evidence: common.7,
                    external_occurred_at: common.8,
                    key: common.9,
                }
            }
        }
        "activation-withdraw" => ActivationCommand::Withdraw {
            activation: activation_required(flags, "activation")?,
            after: activation_required(flags, "after")?,
            assignment: nonempty(flags, "assignment"),
            reason: activation_json(flags, "reason")?,
            basis: activation_json(flags, "basis")?,
            key: activation_required(flags, "key")?,
        },
        "activation-renotify" => ActivationCommand::Renotify {
            activation: activation_required(flags, "activation")?,
            after: activation_required(flags, "after")?,
            noticed_event: activation_required(flags, "noticed-event")?,
            replaces_wake: activation_required(flags, "replaces-wake")?,
            key: activation_required(flags, "key")?,
        },
        "activation-ack" => ActivationCommand::Ack {
            activation: activation_required(flags, "activation")?,
            after: activation_required(flags, "after")?,
            noticed_event: activation_required(flags, "noticed-event")?,
            wake: activation_required(flags, "wake")?,
            key: activation_required(flags, "key")?,
        },
        "activation-status" => ActivationCommand::Status {
            activation: activation_required(flags, "activation")?,
        },
        "activations" => {
            let assignment = nonempty(flags, "assignment");
            let work_item = nonempty(flags, "work-item");
            let correlation = nonempty(flags, "correlation");
            if [
                assignment.as_ref(),
                work_item.as_ref(),
                correlation.as_ref(),
            ]
            .into_iter()
            .flatten()
            .count()
                > 1
            {
                return Err("activations accepts at most one filter".to_owned());
            }
            ActivationCommand::List {
                assignment,
                work_item,
                correlation,
            }
        }
        _ => unreachable!("closed activation command set"),
    };
    Ok(Command::Activation { identity, command })
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
    if flags.contains_key("report-to") && !matches!(command, Some("assign" | "dispatch")) {
        return Err("--report-to is valid only with assign or dispatch".to_owned());
    }
    if matches!(flags.get("report-to"), Some(value) if value.is_empty()) {
        return Err("--report-to requires a non-empty session key".to_owned());
    }

    match command.expect("checked above") {
        name @ ("activation-declare"
        | "activation-authority"
        | "activation-attempt"
        | "activation-observe"
        | "activation-reconcile"
        | "activation-withdraw"
        | "activation-renotify"
        | "activation-ack"
        | "activation-status"
        | "activations") => parse_activation(name, &parsed, flags),
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
        "visitor" => {
            let base_dir = nonempty(flags, "base-dir");
            if parsed.positional.get(1).map(String::as_str) != Some("keyring-init")
                || parsed.positional.len() != 2
                || flags.keys().any(|flag| flag != "base-dir")
                || (flags.contains_key("base-dir") && base_dir.is_none())
            {
                return Err("usage: tightbeam visitor keyring-init [--base-dir DIR]".to_owned());
            }
            Ok(Command::VisitorKeyringInit { base_dir })
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
            if flags.get("class").is_some_and(String::is_empty) {
                return Err("--class requires a class name".to_owned());
            }
            Ok(Command::Wake {
                identity: identity(flags)?,
                target: targets.into_iter().next().expect("exactly one target"),
                prompt,
                after_ms: fallback_after_ms.or(after_ms),
                at,
                condition_kind,
                condition_scope,
                idempotency_key,
                class: nonempty(flags, "class"),
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
        "tune" => {
            // A CLOSED flag set, unlike most commands. On every other verb an
            // unrecognised flag is inert; here it is dangerous — `--modle
            // claude-opus-5` would drop the model the caller named and switch
            // the session to the destination harness's default instead, and
            // the caller would read "ok: true" and believe otherwise.
            const ALLOWED: &[&str] = &[
                "session",
                "harness",
                "model",
                "effort",
                "context",
                "as",
                "as-user",
                "as-process",
            ];

            // A live switch names ONE session. `--role`/`--user` are refused
            // rather than resolved: re-engining "whoever currently holds
            // reviewer" is a different act from re-engining a session, and
            // which session that is must be the caller's own answer.
            if parsed.positional.get(1).is_some()
                || flags.keys().any(|flag| !ALLOWED.contains(&flag.as_str()))
            {
                return Err(TUNE_USAGE.to_owned());
            }
            // PRESENT-BUT-EMPTY is a real answer for `--effort` and
            // `--context` — "no tier", "the vendor's default window" — and is
            // carried through as one. It is not an answer for the other three:
            // there is no session named "", no engine named "", no model
            // named "".
            for name in ["session", "harness", "model"] {
                if flags.get(name).is_some_and(String::is_empty) {
                    return Err(format!("--{name} requires a non-empty value"));
                }
            }
            let session_key = nonempty(flags, "session").ok_or_else(|| TUNE_USAGE.to_owned())?;
            let harness = nonempty(flags, "harness");
            let model = nonempty(flags, "model");
            let effort = named(flags, "effort");
            let context = named(flags, "context");

            if model.as_deref().is_some_and(has_packed_effort) {
                return Err(
                    "--model must not carry a bracketed suffix; pass --effort or --context \
                     separately"
                        .to_owned(),
                );
            }
            if let Some(name) = harness.as_deref() {
                let catalog = match supplied_catalog {
                    Some(catalog) => catalog.clone(),
                    None => crate::harnesses::catalog()?,
                };
                if !catalog.contains(name) {
                    return Err(format!("unsupported harness: {name}"));
                }
            }

            // THE SUBSTRATE NEVER ELECTS (v0.2 program §4). A harness swap
            // re-engines the mind answering a session; the CLI does not let
            // that request leave with no model named and trust the far side
            // to pick one, the same way it does not let `--context` (a
            // QUALIFIER of a model) leave with no model for it to qualify.
            // Both are refused BY NAME here, and the gateway enforces the
            // same two rules independently — the server is the contract,
            // this is only its earliest, friendliest echo.
            let control = match (harness, model, effort, context) {
                (Some(harness), Some(model), effort, context) => TuneControl::Harness {
                    harness,
                    model,
                    effort,
                    context,
                },
                (Some(_), None, _, Some(_)) => {
                    return Err(
                        "--context qualifies a --model; name one, or drop --context \
                         (context_requires_model)"
                            .to_owned(),
                    );
                }
                (Some(_), None, _, None) => {
                    return Err(
                        "--harness requires --model: the substrate does not choose one \
                         (model_required)"
                            .to_owned(),
                    );
                }
                (None, Some(model), effort, context) => TuneControl::Model {
                    model,
                    effort,
                    context,
                },
                // An effort alone retunes the resident model's tier. A context
                // alone qualifies nothing — there is no model in the request
                // for it to be a variant OF — and an empty effort alone elects
                // "no tier" on a model nobody named. Both are usage errors
                // rather than a guess.
                (None, None, Some(Some(effort)), None) => TuneControl::Effort(effort),
                (None, None, _, Some(_)) => {
                    return Err(
                        "--context qualifies a --model; name one, or drop --context \
                         (context_requires_model)"
                            .to_owned(),
                    );
                }
                (None, None, _, _) => return Err(TUNE_USAGE.to_owned()),
            };

            Ok(Command::Tune {
                identity: identity(flags)?,
                session_key,
                control,
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
                effect_kind: nonempty(flags, "effect-kind"),
                files,
                report_to: nonempty(flags, "report-to"),
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
                report_to: nonempty(flags, "report-to"),
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
                    "usage: tightbeam decision-requests [--status open|ruled|consumed|withdrawn|superseded|returned|all]".to_owned(),
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
        "ask" => {
            let targets = [
                nonempty(flags, "session").map(Target::Session),
                nonempty(flags, "role").map(Target::Role),
                nonempty(flags, "user").map(Target::User),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
            if parsed.positional.get(1).is_some() || targets.len() != 1 {
                return Err(ASK_USAGE.to_owned());
            }
            let question = nonempty(flags, "question").ok_or_else(|| ASK_USAGE.to_owned())?;
            if flags.get("about").is_some_and(String::is_empty) {
                return Err("--about requires an assignment id".to_owned());
            }
            Ok(Command::Ask {
                identity: identity(flags)?,
                target: targets.into_iter().next().expect("exactly one target"),
                question,
                about: nonempty(flags, "about"),
            })
        }
        "answer" => {
            let request_id = nonempty(flags, "request");
            let answer = nonempty(flags, "answer");
            if parsed.positional.get(1).is_some() || request_id.is_none() || answer.is_none() {
                return Err(ANSWER_USAGE.to_owned());
            }
            Ok(Command::Answer {
                identity: identity(flags)?,
                request_id: request_id.expect("checked above"),
                answer: answer.expect("checked above"),
            })
        }
        "return" => {
            let request_id = nonempty(flags, "request");
            let reason = nonempty(flags, "reason");
            if parsed.positional.get(1).is_some() || request_id.is_none() || reason.is_none() {
                return Err(RETURN_USAGE.to_owned());
            }
            Ok(Command::ReturnRequest {
                identity: identity(flags)?,
                request_id: request_id.expect("checked above"),
                reason: reason.expect("checked above"),
            })
        }
        "revoke-assignment" => {
            if parsed.positional.len() != 2 || parsed.duplicates.contains("reason") {
                return Err(
                    "usage: tightbeam revoke-assignment <assignmentId> --reason \"...\"".to_owned(),
                );
            }
            let Some(reason) = nonempty(flags, "reason") else {
                return Err(
                    "usage: tightbeam revoke-assignment <assignmentId> --reason \"...\"".to_owned(),
                );
            };
            Ok(Command::RevokeAssignment {
                identity: identity(flags)?,
                assignment_id: parsed.positional[1].clone(),
                reason,
            })
        }
        "reopen-assignment" => {
            if parsed.positional.len() != 2 {
                return Err(
                    "usage: tightbeam reopen-assignment <assignmentId> --reason \"...\"".to_owned(),
                );
            }
            let Some(reason) = nonempty(flags, "reason") else {
                return Err(
                    "usage: tightbeam reopen-assignment <assignmentId> --reason \"...\"".to_owned(),
                );
            };
            Ok(Command::ReopenAssignment {
                identity: identity(flags)?,
                assignment_id: parsed.positional[1].clone(),
                reason,
            })
        }
        "repair-assignment" => {
            let usage = "usage: tightbeam repair-assignment <assignmentId> --action tune|restart|rerun|resume|relaunch --key <key> [--model <model> --effort <tier> --context <window>] [--outcome not-completed] [--turn <seq>]";
            let action = nonempty(flags, "action");
            let key = nonempty(flags, "key");
            let allowed = ["tune", "restart", "rerun", "resume", "relaunch"];
            if parsed.positional.len() != 2
                || action
                    .as_ref()
                    .is_none_or(|value| !allowed.contains(&value.as_str()))
                || key.is_none()
            {
                return Err(usage.to_owned());
            }
            if nonempty(flags, "outcome").is_some_and(|value| value != "not-completed") {
                return Err("--outcome must be not-completed".to_owned());
            }
            Ok(Command::RepairAssignment {
                identity: identity(flags)?,
                assignment_id: parsed.positional[1].clone(),
                action: action.expect("checked above"),
                model: nonempty(flags, "model"),
                effort: nonempty(flags, "effort"),
                context: nonempty(flags, "context"),
                outcome: nonempty(flags, "outcome"),
                turn_seq: nonempty(flags, "turn")
                    .map(|value| js_number_json(number_coercion(&value))),
                idempotency_key: key.expect("checked above"),
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
                priority: priority_flag(flags)?,
                idempotency_key: nonempty(flags, "key"),
            })
        }
        "work-item-update" => {
            const ALLOWED: &[&str] = &[
                "title",
                "spec-ref",
                "spec-sha256",
                "clear-spec-ref",
                "priority",
                "as",
                "as-user",
                "as-process",
            ];

            if parsed.positional.len() != 2
                || flags.keys().any(|flag| !ALLOWED.contains(&flag.as_str()))
            {
                return Err("usage: tightbeam work-item-update <workItemId> [--title \"...\"] [--spec-ref <name>] [--spec-sha256 <hex>] [--clear-spec-ref] [--priority <0..8>]".to_owned());
            }

            let clear_spec_ref = flags.contains_key("clear-spec-ref");
            let spec_ref_present = flags.contains_key("spec-ref");
            let spec_sha_present = flags.contains_key("spec-sha256");

            if clear_spec_ref && (spec_ref_present || spec_sha_present) {
                return Err(
                    "usage: --clear-spec-ref conflicts with --spec-ref and --spec-sha256"
                        .to_owned(),
                );
            }

            Ok(Command::WorkItemUpdate {
                identity: identity(flags)?,
                work_item_id: parsed.positional[1].clone(),
                title: flags.get("title").cloned(),
                spec_ref_name: flags.get("spec-ref").cloned(),
                spec_ref_sha256: flags.get("spec-sha256").cloned(),
                clear_spec_ref,
                priority: priority_flag(flags)?,
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
        "turn-trace" => {
            if parsed.positional.len() != 1 {
                return Err(
                    "usage: tightbeam turn-trace --session <key> --seq <turnSeq>".to_owned(),
                );
            }
            Ok(Command::TurnTrace {
                identity: identity(flags)?,
                session: nonempty(flags, "session")
                    .ok_or_else(|| "turn-trace requires --session <key>".to_owned())?,
                seq: nonempty(flags, "seq")
                    .map(|value| js_number_json(number_coercion(&value)))
                    .ok_or_else(|| "turn-trace requires --seq <turnSeq>".to_owned())?,
            })
        }
        "execution-map" => {
            if parsed.positional.len() != 1 {
                return Err(TOPLINES_USAGE.to_owned());
            }
            let after = cursor_flag(flags, "after", "a work item id")?;
            let limit = page_limit(flags)?;
            // Refused HERE as well as at the gateway. A forest has no page
            // boundary that is not also a wrong answer, and finding that out
            // after a round trip is worse than finding it out on the command
            // line (coordination-fabric-v1 §13 seam ④).
            if flags.contains_key("tree") && (after.is_some() || limit.is_some()) {
                return Err(
                    "--after/--limit page the flat roster; --tree returns a forest".to_owned(),
                );
            }
            Ok(Command::Toplines {
                identity: identity(flags)?,
                filters: topline_filters(flags)?,
                tree: flags.contains_key("tree"),
                after,
                limit,
            })
        }
        "execution-map-select" => {
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
                        "execution-map-select requires exactly one of --under <workItemId> or --assignments <id,...>"
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
        "toplines" => {
            if parsed.positional.len() != 1 {
                return Err(DURABLE_TOPLINES_USAGE.to_owned());
            }
            let state = nonempty(flags, "state");
            if let Some(value) = &state {
                if !matches!(value.as_str(), "open" | "closed" | "all") {
                    return Err(DURABLE_TOPLINES_USAGE.to_owned());
                }
            }
            Ok(Command::DurableToplines {
                identity: identity(flags)?,
                state,
            })
        }
        "topline" => {
            if parsed.positional.len() != 2 {
                return Err(DURABLE_TOPLINE_USAGE.to_owned());
            }
            Ok(Command::DurableTopline {
                identity: identity(flags)?,
                topline_id: parsed.positional[1].clone(),
                history: flags.contains_key("history"),
            })
        }
        verb @ ("topline-create"
        | "topline-update"
        | "topline-close"
        | "topline-reopen"
        | "topline-link-work"
        | "topline-unlink-work"
        | "topline-concern-create"
        | "topline-concern-update"
        | "topline-concern-resolve"
        | "topline-concern-reopen"
        | "topline-concern-link-work"
        | "topline-concern-unlink-work"
        | "topline-work-leave-unlinked") => topline_mutation(verb, &parsed.positional, flags),
        "topline-placement-list" => {
            if parsed.positional.len() != 1 {
                return Err(
                    "usage: tightbeam topline-placement-list [--state pending|resolved|all]"
                        .to_owned(),
                );
            }
            let state = nonempty(flags, "state");
            if !matches!(
                state.as_deref(),
                None | Some("pending" | "resolved" | "all")
            ) {
                return Err(
                    "usage: tightbeam topline-placement-list [--state pending|resolved|all]"
                        .to_owned(),
                );
            }
            Ok(Command::ToplineMutation {
                identity: identity(flags)?,
                verb: "topline-placement-list".to_owned(),
                params: state
                    .map(|value| vec![("state".to_owned(), value)])
                    .unwrap_or_default(),
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
            let release_fact_kind = nonempty(flags, "release-fact-kind");
            let release_fact_scope = nonempty(flags, "release-fact-scope");
            let release_fact_principal_ref = nonempty(flags, "release-fact-principal-ref");
            let release_count = [
                release_fact_kind.as_ref(),
                release_fact_scope.as_ref(),
                release_fact_principal_ref.as_ref(),
            ]
            .iter()
            .filter(|value| value.is_some())
            .count();
            if release_count != 0 && release_count != 3 {
                return Err("--release-fact-kind, --release-fact-scope, and --release-fact-principal-ref must be supplied together".to_owned());
            }
            if kind != "cannot-proceed" && release_count != 0 {
                return Err(
                    "release fact flags are only valid when --kind is cannot-proceed".to_owned(),
                );
            }
            let note = nonempty(flags, "note");
            if kind == "cannot-proceed" && note.is_none() {
                return Err("--note is required when --kind is cannot-proceed".to_owned());
            }
            Ok(Command::Attest {
                identity: identity(flags)?,
                assignment_id,
                kind,
                verdict,
                note,
                commit_refs,
                release_fact_kind,
                release_fact_scope,
                release_fact_principal_ref,
            })
        }
        "coordination-share" => {
            if parsed.positional.len() != 1 {
                return Err(COORDINATION_SHARE_USAGE.to_owned());
            }
            let session =
                nonempty(flags, "session").ok_or_else(|| COORDINATION_SHARE_USAGE.to_owned())?;
            let from =
                nonempty(flags, "from").ok_or_else(|| COORDINATION_SHARE_USAGE.to_owned())?;
            let to = nonempty(flags, "to").ok_or_else(|| COORDINATION_SHARE_USAGE.to_owned())?;
            Ok(Command::CoordinationShare {
                identity: identity(flags)?,
                session,
                // The same numeric coercion transcript's --limit uses, rendered
                // as a JSON number so the handler receives epoch integers.
                from: js_number_json(number_coercion(&from)),
                to: js_number_json(number_coercion(&to)),
            })
        }
        "digest-members" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam digest-members <wakeId>".to_owned());
            }
            Ok(Command::DigestMembers {
                identity: identity(flags)?,
                wake_id: parsed.positional[1].clone(),
            })
        }
        "attests" => {
            if parsed.positional.len() != 2 {
                return Err(ATTESTS_USAGE.to_owned());
            }
            Ok(Command::Attests {
                identity: identity(flags)?,
                assignment_id: parsed.positional[1].clone(),
                after: cursor_flag(flags, "after", "an attest id")?,
                limit: page_limit(flags)?,
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
        "completion-notices" => {
            if parsed.positional.len() != 1 {
                return Err("usage: tightbeam completion-notices --status open|all [--session <childSessionKey>]".to_owned());
            }
            let status = nonempty(flags, "status").ok_or_else(|| {
                "usage: tightbeam completion-notices --status open|all [--session <childSessionKey>]".to_owned()
            })?;
            if !matches!(status.as_str(), "open" | "all") {
                return Err("--status must be open or all".to_owned());
            }
            Ok(Command::CompletionNotices {
                identity: identity(flags)?,
                status,
                session_key: nonempty(flags, "session"),
            })
        }
        "completion-disposition" => {
            if parsed.positional.len() != 2 {
                return Err("usage: tightbeam completion-disposition <completionId> --decision retain|park|retire".to_owned());
            }
            let decision = nonempty(flags, "decision").ok_or_else(|| {
                "usage: tightbeam completion-disposition <completionId> --decision retain|park|retire".to_owned()
            })?;
            if !matches!(decision.as_str(), "retain" | "park" | "retire") {
                return Err("--decision must be retain, park, or retire".to_owned());
            }
            Ok(Command::CompletionDisposition {
                identity: identity(flags)?,
                completion_id: parsed.positional[1].clone(),
                decision,
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
            "unknown command: {unknown} — run 'tightbeam help' for usage. Commands: wake, condition, cancel-wake, attest, attests, assign, assignments, dispatch, completion-notices, completion-disposition, effort-rule, operator-ask, operator-rule, operator-withdraw, decision-requests, decision-request, ask, answer, return, revoke-assignment, reopen-assignment, repair-assignment, work-item-create, work-item-update, work-item-get, attend, transcript, turn-trace, execution-map, execution-map-select, toplines, topline, topline-create, topline-update, topline-close, topline-reopen, topline-link-work, topline-unlink-work, topline-concern-create, topline-concern-update, topline-concern-resolve, topline-concern-reopen, topline-concern-link-work, topline-concern-unlink-work, topline-work-leave-unlinked, topline-placement-list, coordination-share, work-item-trace, work-item-icebox, work-item-reopen, work-item-close, work-item-fail, spawn, tune, retire, list, identity, kungfu, learn, unlearn, onboard, add-user, artifact-record, artifacts, activation-declare, activation-authority, activation-attempt, activation-observe, activation-reconcile, activation-withdraw, activation-renotify, activation-ack, activation-status, activations, config, host-env-set, host-env-list, host-env-unset, doctor, visitor, assimilate, harness-process"
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

fn priority_flag(flags: &HashMap<String, String>) -> Result<Option<String>, String> {
    nonempty(flags, "priority")
        .map(|value| {
            let priority = value.parse::<u8>().ok();
            if priority.is_some_and(|priority| priority <= 8) {
                Ok(value)
            } else {
                Err("priority must be an integer from 0 through 8".to_owned())
            }
        })
        .transpose()
}

fn parse_config(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    match (
        parsed.positional.get(1).map(String::as_str),
        parsed.positional.get(2).map(String::as_str),
        parsed.positional.get(3),
        parsed.positional.get(4),
    ) {
        (Some("get"), Some(setting @ ("default-archetype" | "default-priority")), None, None) => Ok(Command::ConfigGet {
            identity: identity(flags)?,
            setting: setting.to_owned(),
        }),
        (Some("set"), Some("default-archetype"), Some(value), None) => Ok(Command::ConfigSet {
            identity: identity(flags)?,
            setting: "default-archetype".to_owned(),
            value: value.clone(),
        }),
        (Some("set"), Some("default-priority"), Some(value), None) => {
            let priority = value.parse::<u8>().ok();
            if priority.is_none_or(|priority| priority > 8) {
                return Err("default-priority must be an integer from 0 through 8".to_owned());
            }
            Ok(Command::ConfigSet {
                identity: identity(flags)?,
                setting: "default-priority".to_owned(),
                value: value.clone(),
            })
        }
        _ => Err(
            "usage: tightbeam config get default-archetype|default-priority | config set default-archetype <name> | config set default-priority <0..8>"
                .to_owned(),
        ),
    }
}

fn parse_identity_command(
    parsed: &Flags,
    flags: &HashMap<String, String>,
) -> Result<Command, String> {
    match parsed.positional.get(1).map(String::as_str) {
        Some("current") if parsed.positional.len() == 2 && flags.is_empty() => {
            Ok(Command::IdentityCurrent)
        }
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
        _ => Err(
            "usage: tightbeam identity current|edit|status|relearn|repoint|apply ...".to_owned(),
        ),
    }
}

fn parse_onboard(parsed: &Flags, flags: &HashMap<String, String>) -> Result<Command, String> {
    if parsed.positional.len() != 2 {
        return Err("usage: tightbeam onboard <provider> [--api-key]".to_owned());
    }
    let provider = parsed.positional[1].clone();
    let fixture_provider = cfg!(test) && provider == "fixture-provider";
    if !matches!(provider.as_str(), "openai" | "anthropic") && !fixture_provider {
        return Err("provider must be openai or anthropic".to_owned());
    }
    Ok(Command::Onboard {
        identity: identity(flags)?,
        provider,
        // A BOOLEAN flag, deliberately. `--api-key <value>` would put the key in
        // this process's argv, where anyone on the box can read it out of the
        // process table. The key arrives on stdin instead.
        api_key: flags.contains_key("api-key"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn completion_commands_and_report_to_parse_exactly() {
        assert_eq!(
            parse(strings(&[
                "completion-notices",
                "--status",
                "open",
                "--session",
                "child",
                "--as",
                "parent",
            ])),
            Ok(Command::CompletionNotices {
                identity: Identity::Role("parent".to_owned()),
                status: "open".to_owned(),
                session_key: Some("child".to_owned()),
            })
        );
        assert_eq!(
            parse(strings(&[
                "completion-disposition",
                "cn_1",
                "--decision",
                "retain",
                "--as-user",
                "flynn",
            ])),
            Ok(Command::CompletionDisposition {
                identity: Identity::User("flynn".to_owned()),
                completion_id: "cn_1".to_owned(),
                decision: "retain".to_owned(),
            })
        );
        assert!(matches!(
            parse(strings(&[
                "assign",
                "--subject",
                "work",
                "--session",
                "child",
                "--report-to",
                "report",
                "--as-user",
                "flynn",
            ])),
            Ok(Command::Assign {
                report_to: Some(value),
                ..
            }) if value == "report"
        ));
        assert_eq!(
            parse(strings(&[
                "completion-notices",
                "--status",
                "closed",
                "--as-user",
                "flynn",
            ])),
            Err("--status must be open or all".to_owned())
        );
        assert_eq!(
            parse(strings(&[
                "attest",
                "asg_1",
                "--kind",
                "completion",
                "--report-to",
                "report"
            ])),
            Err("--report-to is valid only with assign or dispatch".to_owned())
        );
        assert_eq!(
            parse(strings(&[
                "assign",
                "--subject",
                "work",
                "--session",
                "child",
                "--report-to",
                "",
            ])),
            Err("--report-to requires a non-empty session key".to_owned())
        );
        assert_eq!(
            parse(strings(&[
                "completion-disposition",
                "cn_1",
                "--decision",
                "delete",
                "--as-user",
                "flynn",
            ])),
            Err("--decision must be retain, park, or retire".to_owned())
        );
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
    fn activation_commands_parse_closed_json_and_relation_shapes() {
        assert!(matches!(
            parse(strings(&[
                "activation-declare",
                "--assignment", "asg_1",
                "--owner", "owner",
                "--domain", "example",
                "--correlation", "c1",
                "--input", r#"{"namespace":"x","id":"i","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
                "--target", r#"{"namespace":"x","id":"t","sha256":null}"#,
                "--key", "k1",
                "--as", "coder"
            ])),
            Ok(Command::Activation {
                identity: Identity::Role(role),
                command: ActivationCommand::Declare { assignment, domain, .. }
            }) if role == "coder" && assignment == "asg_1" && domain == "example"
        ));

        assert!(
            parse(strings(&[
                "activation-declare",
                "--assignment",
                "a",
                "--owner",
                "u",
                "--domain",
                "d",
                "--correlation",
                "c",
                "--input",
                "not-json",
                "--target",
                "null",
                "--key",
                "k"
            ]))
            .is_err()
        );
        assert!(
            parse(strings(&[
                "activation-status",
                "--activation",
                "act_1",
                "--event-id",
                "forged"
            ]))
            .is_err()
        );
        assert!(
            parse(strings(&[
                "activations",
                "--assignment",
                "a",
                "--work-item",
                "wi"
            ]))
            .is_err()
        );
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
            })
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

    /// The catalog every tune test validates `--harness` against.
    fn tune_catalog() -> crate::harnesses::HarnessCatalog {
        crate::harnesses::HarnessCatalog {
            harnesses: vec![
                crate::harnesses::HarnessProjection {
                    wire_name: "fixture".to_owned(),
                    install_package: "fixture-package".to_owned(),
                    cli_binary: "fixture".to_owned(),
                    process_markers: vec!["fixture-acp".to_owned()],
                },
                crate::harnesses::HarnessProjection {
                    wire_name: "codex".to_owned(),
                    install_package: "codex-package".to_owned(),
                    cli_binary: "codex".to_owned(),
                    process_markers: vec!["codex-acp".to_owned()],
                },
            ],
        }
    }

    fn tune(args: &[&str]) -> Result<Command, String> {
        parse_with_catalog(strings(args), &tune_catalog())
    }

    #[test]
    fn tune_names_one_control_and_a_model_by_fields() {
        // A HARNESS switch. The model fields ride along as fields; none of
        // them is packed into the harness or into each other.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--harness",
                "codex",
                "--model",
                "gpt-5.6-sol",
                "--effort",
                "high",
                "--as-user",
                "flynn",
            ]),
            Ok(Command::Tune {
                identity: Identity::User("flynn".to_owned()),
                session_key: "s_1".to_owned(),
                control: TuneControl::Harness {
                    harness: "codex".to_owned(),
                    model: "gpt-5.6-sol".to_owned(),
                    effort: Some(Some("high".to_owned())),
                    context: None,
                },
            })
        );

        // A harness switch with NO model is REFUSED (v0.2 program §4): the
        // substrate does not compose the destination's own default, and the
        // CLI does not invent one either — it does not know what the
        // destination host offers, and inventing one is the whole failure
        // this design exists to prevent.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--harness",
                "codex",
                "--as-user",
                "flynn"
            ]),
            Err(
                "--harness requires --model: the substrate does not choose one \
                 (model_required)"
                    .to_owned()
            )
        );

        // `--context` with no `--model` for it to qualify — even alongside
        // `--harness` — is refused by the more specific name: the caller's
        // actual mistake is the stray `--context`, not a bare missing model.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--harness",
                "codex",
                "--context",
                "1m",
                "--as-user",
                "flynn"
            ]),
            Err(
                "--context qualifies a --model; name one, or drop --context \
                 (context_requires_model)"
                    .to_owned()
            )
        );

        // A same-harness MODEL retune.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--model",
                "claude-fable-5",
                "--context",
                "1m",
                "--as-user",
                "flynn",
            ]),
            Ok(Command::Tune {
                identity: Identity::User("flynn".to_owned()),
                session_key: "s_1".to_owned(),
                control: TuneControl::Model {
                    model: "claude-fable-5".to_owned(),
                    effort: None,
                    context: Some(Some("1m".to_owned())),
                },
            })
        );

        // An EFFORT alone retunes the resident model's tier.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--effort",
                "xhigh",
                "--as-user",
                "flynn"
            ]),
            Ok(Command::Tune {
                identity: Identity::User("flynn".to_owned()),
                session_key: "s_1".to_owned(),
                control: TuneControl::Effort("xhigh".to_owned()),
            })
        );

        // NAMED EMPTY survives as a named empty: `--context ""` is the
        // vendor's default window, a real selection, and it must reach the
        // gateway as one rather than as silence to be inherited over.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--model",
                "claude-fable-5",
                "--context",
                "",
                "--as-user",
                "flynn",
            ]),
            Ok(Command::Tune {
                identity: Identity::User("flynn".to_owned()),
                session_key: "s_1".to_owned(),
                control: TuneControl::Model {
                    model: "claude-fable-5".to_owned(),
                    effort: None,
                    context: Some(None),
                },
            })
        );
    }

    #[test]
    fn tune_refuses_a_packed_model_an_invented_harness_and_a_partial_naming() {
        // OUR effort word packed into the model string. Refused, and told
        // where the field actually lives.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--model",
                "gpt-5.6-sol[high]",
                "--as-user",
                "flynn",
            ]),
            Err(
                "--model must not carry a bracketed suffix; pass --effort or --context \
                 separately"
                    .to_owned()
            )
        );

        // F7 (Sol xhigh review): the VENDOR's context variant in the same
        // syntax is ALSO refused now — a hardcoded list of Tightbeam's own
        // tier words already went stale once (the catalog offers `ultra`
        // too), and a per-model catalog is not always available to check
        // against at CLI parse time. Any bracket is packed form; a context
        // variant is named through `--context`, the field that exists for
        // it.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--model",
                "claude-fable-5[1m]",
                "--as-user",
                "flynn",
            ]),
            Err(
                "--model must not carry a bracketed suffix; pass --effort or --context \
                 separately"
                    .to_owned()
            )
        );

        // An engine this build does not carry is refused by name at the CLI,
        // before a session is ever addressed.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--harness",
                "gemini",
                "--as-user",
                "flynn"
            ]),
            Err("unsupported harness: gemini".to_owned())
        );

        // A context qualifies a MODEL. Alone it qualifies nothing, and the
        // CLI does not guess which model the caller meant — named by the
        // more specific cause rather than the generic usage line.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--context",
                "1m",
                "--as-user",
                "flynn"
            ]),
            Err(
                "--context qualifies a --model; name one, or drop --context \
                 (context_requires_model)"
                    .to_owned()
            )
        );

        // No control named at all.
        assert_eq!(
            tune(&["tune", "--session", "s_1", "--as-user", "flynn"]),
            Err(TUNE_USAGE.to_owned())
        );

        // No session named.
        assert_eq!(
            tune(&["tune", "--model", "claude-fable-5", "--as-user", "flynn"]),
            Err(TUNE_USAGE.to_owned())
        );

        // A live switch names ONE session. Re-engining "whoever holds
        // reviewer" is a different act and is not spelled here.
        assert_eq!(
            tune(&[
                "tune",
                "--role",
                "reviewer",
                "--model",
                "m",
                "--as-user",
                "flynn"
            ]),
            Err(TUNE_USAGE.to_owned())
        );

        // A MISTYPED flag is the dangerous case: silently ignored, `--modle`
        // would switch the session to the destination default and report
        // success. The flag set is closed so it cannot.
        assert_eq!(
            tune(&[
                "tune",
                "--session",
                "s_1",
                "--harness",
                "codex",
                "--modle",
                "gpt-5.6-sol",
                "--as-user",
                "flynn",
            ]),
            Err(TUNE_USAGE.to_owned())
        );

        // Empty values for the three fields that have no meaningful empty.
        for name in ["session", "harness", "model"] {
            let flag = format!("--{name}");
            assert_eq!(
                tune(&[
                    "tune",
                    "--session",
                    "s_1",
                    flag.as_str(),
                    "",
                    "--as-user",
                    "flynn",
                ]),
                Err(format!("--{name} requires a non-empty value"))
            );
        }
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
                "answer",
                "activation-ack",
                "activation-attempt",
                "activation-authority",
                "activation-declare",
                "activation-observe",
                "activation-reconcile",
                "activation-renotify",
                "activation-status",
                "activation-withdraw",
                "activations",
                "ask",
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
                "completion-disposition",
                "completion-notices",
                "config",
                "coordination-share",
                "decision-request",
                "decision-requests",
                "digest-members",
                "dispatch",
                "doctor",
                "effort-rule",
                "harness-process",
                "host-env-list",
                "host-env-set",
                "host-env-unset",
                "identity",
                "kungfu",
                "learn",
                "list",
                "onboard",
                "operator-ask",
                "operator-rule",
                "operator-withdraw",
                "retire",
                "return",
                "reopen-assignment",
                "repair-assignment",
                "revoke-assignment",
                "spawn",
                "tune",
                "wake",
                "work-item-close",
                "work-item-create",
                "work-item-fail",
                "work-item-get",
                "work-item-update",
                "attend",
                "transcript",
                "turn-trace",
                "unlearn",
                "visitor",
                "execution-map",
                "execution-map-select",
                "toplines",
                "topline",
                "topline-create",
                "topline-update",
                "topline-close",
                "topline-reopen",
                "topline-link-work",
                "topline-unlink-work",
                "topline-concern-create",
                "topline-concern-update",
                "topline-concern-resolve",
                "topline-concern-reopen",
                "topline-concern-link-work",
                "topline-concern-unlink-work",
                "topline-work-leave-unlinked",
                "topline-placement-list",
                "work-item-trace",
                "work-item-icebox",
                "work-item-reopen",
            ]
            .into_iter()
            .collect()
        );
        for syntax in [
            "identity current",
            "identity edit <archetype>",
            "identity relearn [--abort | --resolve]",
            "identity repoint <retired-session> <archetype>",
            "identity status [<archetype>]",
            "identity apply (<session> | --all)",
            "onboard openai|anthropic [--api-key]",
            "add-user <userId> [--admin]",
            "config get default-archetype|default-priority",
            "config set default-archetype <name>",
            "config set default-priority <0..8>",
            "host-env-set --host <host> --harness <harness> NAME=VALUE",
            "host-env-list [--host <host>] [--harness <harness>]",
            "host-env-unset --host <host> --harness <harness> NAME",
            "harness-process list",
            "kungfu list",
            "visitor keyring-init [--base-dir p]",
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
                "execution-map-select",
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
            "execution-map-select",
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
            "execution-map-select",
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
                class: None,
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
                class: None,
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
    fn identity_current_is_local_and_takes_no_identity_override() {
        assert_eq!(
            parse(strings(&["identity", "current"])),
            Ok(Command::IdentityCurrent)
        );
        assert_eq!(
            parse(strings(&["identity", "current", "--as", "coder"])),
            Err(
                "usage: tightbeam identity current|edit|status|relearn|repoint|apply ..."
                    .to_owned()
            )
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

    // The repair verb names its reason or it does not run: an unexplained
    // reopen is exactly the unrecorded repair the papertrail exists to prevent.
    #[test]
    fn reopen_assignment_requires_an_id_and_a_reason() {
        for args in [
            strings(&["reopen-assignment", "--as-user", "flynn"]),
            strings(&["reopen-assignment", "asg_1", "asg_2", "--as-user", "flynn"]),
            strings(&["reopen-assignment", "asg_1", "--as-user", "flynn"]),
        ] {
            assert_eq!(
                parse(args),
                Err(
                    "usage: tightbeam reopen-assignment <assignmentId> --reason \"...\"".to_owned()
                )
            );
        }

        assert!(matches!(
            parse(strings(&[
                "reopen-assignment",
                "asg_1",
                "--reason",
                "stale verdict",
                "--as-user",
                "flynn",
            ]))
            .unwrap(),
            Command::ReopenAssignment {
                assignment_id,
                reason,
                ..
            } if assignment_id == "asg_1" && reason == "stale verdict"
        ));
    }

    #[test]
    fn revoke_assignment_requires_exactly_one_reason() {
        assert_eq!(
            parse(strings(&[
                "revoke-assignment",
                "asg_1",
                "--reason",
                "first",
                "--reason",
                "second",
                "--as-user",
                "flynn",
            ])),
            Err("usage: tightbeam revoke-assignment <assignmentId> --reason \"...\"".to_owned())
        );
    }

    #[test]
    fn unknown_command_matches_reference_text() {
        assert_eq!(
            parse(strings(&["frobnicate", "--as-user", "flynn"])),
            Err("unknown command: frobnicate — run 'tightbeam help' for usage. Commands: wake, condition, cancel-wake, attest, attests, assign, assignments, dispatch, completion-notices, completion-disposition, effort-rule, operator-ask, operator-rule, operator-withdraw, decision-requests, decision-request, ask, answer, return, revoke-assignment, reopen-assignment, repair-assignment, work-item-create, work-item-update, work-item-get, attend, transcript, turn-trace, execution-map, execution-map-select, toplines, topline, topline-create, topline-update, topline-close, topline-reopen, topline-link-work, topline-unlink-work, topline-concern-create, topline-concern-update, topline-concern-resolve, topline-concern-reopen, topline-concern-link-work, topline-concern-unlink-work, topline-work-leave-unlinked, topline-placement-list, coordination-share, work-item-trace, work-item-icebox, work-item-reopen, work-item-close, work-item-fail, spawn, tune, retire, list, identity, kungfu, learn, unlearn, onboard, add-user, artifact-record, artifacts, activation-declare, activation-authority, activation-attempt, activation-observe, activation-reconcile, activation-withdraw, activation-renotify, activation-ack, activation-status, activations, config, host-env-set, host-env-list, host-env-unset, doctor, visitor, assimilate, harness-process".to_owned())
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
    fn turn_trace_requires_one_session_and_a_numeric_sequence() {
        assert_eq!(
            parse(strings(&[
                "turn-trace",
                "--session",
                "agent:coder:x s_1",
                "--seq",
                "17",
                "--as-user",
                "flynn",
            ])),
            Ok(Command::TurnTrace {
                identity: Identity::User("flynn".to_owned()),
                session: "agent:coder:x s_1".to_owned(),
                seq: "17".to_owned(),
            })
        );

        assert_eq!(
            parse(strings(&[
                "turn-trace",
                "--seq",
                "17",
                "--as-user",
                "flynn"
            ])),
            Err("turn-trace requires --session <key>".to_owned())
        );
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
            "critical",
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
    fn visitor_keyring_init_is_a_closed_local_command_shape() {
        let help = render_command_help(None, "visitor").unwrap();
        assert!(help.starts_with("  visitor keyring-init [--base-dir p]"));
        assert!(help.contains("no-replace publication"));
        assert!(!help.contains("  assimilate "));

        assert_eq!(
            parse(strings(&[
                "visitor",
                "keyring-init",
                "--base-dir",
                "/srv/tightbeam",
            ])),
            Ok(Command::VisitorKeyringInit {
                base_dir: Some("/srv/tightbeam".to_owned()),
            })
        );
        assert_eq!(
            parse(strings(&["visitor", "keyring-init"])),
            Ok(Command::VisitorKeyringInit { base_dir: None })
        );

        for args in [
            strings(&["visitor"]),
            strings(&["visitor", "other"]),
            strings(&["visitor", "keyring-init", "extra"]),
            strings(&["visitor", "keyring-init", "--base-dir"]),
            strings(&["visitor", "keyring-init", "--unknown", "value"]),
        ] {
            assert_eq!(
                parse(args),
                Err("usage: tightbeam visitor keyring-init [--base-dir DIR]".to_owned())
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

        assert!(matches!(
            parse(strings(&[
                "work-item-update",
                "wi_1",
                "--spec-sha256",
                "abc",
                "--as-user",
                "flynn",
            ])),
            Ok(Command::WorkItemUpdate {
                work_item_id,
                spec_ref_name: None,
                spec_ref_sha256: Some(sha),
                clear_spec_ref: false,
                ..
            }) if work_item_id == "wi_1" && sha == "abc"
        ));

        assert!(matches!(
            parse(strings(&[
                "work-item-update",
                "wi_1",
                "--title",
                "Retitled",
                "--spec-ref",
                "governing.md",
                "--spec-sha256",
                "abc",
                "--priority",
                "6",
                "--as-user",
                "flynn",
            ])),
            Ok(Command::WorkItemUpdate {
                work_item_id,
                title: Some(title),
                spec_ref_name: Some(spec_ref_name),
                spec_ref_sha256: Some(sha),
                clear_spec_ref: false,
                priority: Some(priority),
                ..
            }) if work_item_id == "wi_1"
                && title == "Retitled"
                && spec_ref_name == "governing.md"
                && sha == "abc"
                && priority == "6"
        ));

        assert!(
            parse(strings(&[
                "work-item-update",
                "wi_1",
                "--clear-spec-ref",
                "--spec-ref",
                "spec.md",
                "--as-user",
                "flynn",
            ]))
            .unwrap_err()
            .contains("conflicts")
        );

        assert!(
            parse(strings(&[
                "work-item-update",
                "wi_1",
                "--is-bug",
                "true",
                "--as-user",
                "flynn",
            ]))
            .unwrap_err()
            .starts_with("usage: tightbeam work-item-update")
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
    fn cannot_proceed_requires_a_reason_and_an_all_or_none_release_tuple() {
        assert_eq!(
            parse(strings(&["attest", "asg_1", "--kind", "cannot-proceed"])),
            Err("--note is required when --kind is cannot-proceed".to_owned())
        );

        assert!(
            parse(strings(&[
                "attest",
                "asg_1",
                "--kind",
                "cannot-proceed",
                "--note",
                "waiting",
                "--release-fact-kind",
                "ready",
            ]))
            .unwrap_err()
            .contains("must be supplied together")
        );

        assert!(
            parse(strings(&[
                "attest",
                "asg_1",
                "--kind",
                "progress",
                "--release-fact-kind",
                "ready",
                "--release-fact-scope",
                "asg_1",
                "--release-fact-principal-ref",
                "agent:holder",
            ]))
            .unwrap_err()
            .contains("only valid when --kind is cannot-proceed")
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
                    class: None,
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
            (strings(&["identity", "current"]), Command::IdentityCurrent),
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
