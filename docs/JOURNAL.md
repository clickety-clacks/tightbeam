# Journal — append-only; newest LAST.

## E1a — Fable — DB owner + turns ledger

Done: Tightbeam.DB (single-writer GenServer over exqlite; pinned PRAGMAs
WAL/FK/NORMAL/busy_timeout=5000; transaction/1 with rollback; error tuples
converted to raised Tightbeam.DB.Error — exqlite step/bind return {:error,_}
rather than raising). Tightbeam.Ledger (turns DDL incl. status-leading
partial index + owner/adapterGen/requestRef columns per review-3; enqueue_in_
txn; claim_next with one-per-session enforced in SQL; finish CAS; recover_
running→failed_unknown; pending_sessions reconciler feed; unpublished_
terminals publication feed; conservation audit). 10 tests green.

Next: EventLog (events + lifecycle_events + boot_epochs w/ dirty-exit
inference), then Acp.Conn (Port owner, ndjson binary-mode hand-buffered
framing, async request protocol — NO blocking calls), then SessionLane +
LaneManager reconciler, then the E1 vertical slice against a real adapter.

## E1c — Fable — Acp.Conn (Port owner, async protocol)

Done: Tightbeam.Acp.Conn — binary-mode Port w/ hand-buffered ndjson framing
(built-in JSON module, no dep); NEVER blocks its own loop (noreply+from, per-
request send_after timeouts); requester monitoring → session/cancel on caller
death; pending entries RETAINED past timeout/orphan until the adapter answers
— that answer emits {:acp_orphan_resolved, session_id}, the QUIESCENCE signal
review-3 demanded; permission requests auto-allowed (allow-kind preferred);
stderr via sh 2>> redirect; port exit fails pending + emits acp_exit. Fake
adapter is the same node -e protocol as the TS test fakes. 6 tests (18 total).

Next: SessionLane (claims from Ledger, runs TurnTask via Task.Supervisor
async_nolink + mutual monitors, quarantine on failed_unknown until
orphan_resolved or generation recycle) + LaneManager (Registry-named lanes,
boot+5s reconciler over Ledger.pending_sessions, unpublished-terminal
re-publish). Then Adapter (initialize/session lifecycle over Conn) + the E1
vertical slice against the real claude adapter.

## E1f — Fable — VERTICAL SLICE (E1 EXIT) ✅

scripts/e1_first_light.exs: a prompt round-trips through the SUPERVISED spine
(DB + Ledger + LaneManager reconciler + SessionLane + Acp.Adapter) to a REAL
claude-agent-acp adapter. PASS: reply "ELIXIR FIRST LIGHT", ledger row
delivered+published, conservation audit []. The turn was picked up by the
RECONCILER path (ensure_lane), executed one-per-session, terminal-transitioned
via CAS. This is E1 done — the review defects that could not be proven in prose
are now proven in code + 25 unit tests.

E1 modules: DB (single-writer), Ledger (all invariants in SQL), EventLog
(+epochs), Acp.Conn (async Port, quiescence signal), Acp.Adapter (fable-trap
model rule), SessionLane (monitors-not-links), LaneManager (reconciler).

Next (E2): Application supervision tree wiring these under one root w/ the
review-specified restart intensities; then the wire (Bandit WS+HTTP +
ConnRegistry w/ per-connection seq filter + generation takeover) driven by the
E0 black-box drivers (sol building those now).

## E2 status + wire handoff (Fable)

DONE and green (30 tests): E1 full spine (DB, Ledger, EventLog, Acp.Conn,
Acp.Adapter, SessionLane, LaneManager) + E1 vertical slice vs real adapter;
E2a Application supervision tree (rest_for_one, Boot one-shot); ConnRegistry
(generation takeover + per-connection seq filter — review #5). E0 referee
black-box drivers pass in the TS repo.

IN FLIGHT: sol porting Projection (store.ts) + Org (registry.ts) — E2b.

REMAINING for E2 exit (black-box wire driver green vs BEAM), patterns all
established — port each module imitating existing lib/ + tests:
- Tightbeam.Devices (from devices.ts): users+devices tables, user-scoped
  admin, approve/deny/revoke/promote, pairing.
- Tightbeam.Wire.Payloads (from payloads.ts): pure builders, field-for-field
  (iOS decoders are strict — echo deviceId+clientMessageId; assistant
  replyTo*+sender; prompt_turn_state event; sessionKeys[] not sessions[]).
- Tightbeam.Dispatch: the verb chokepoint (guard hook allow-all in E2; append
  event post-dispatch) — the rails groove.
- Verb handlers (post/wake/spawn/cancel/tune/retire/inspect/approve-device/
  ...) composed in Tightbeam.Gateway (composition root): post/wake share a
  deliverPrompt that persists via Projection + enqueues via Ledger (SAME
  transaction: message+turn commit together) then LaneManager.ensure_lane;
  the SessionLane runner = Acp.Adapter.prompt + persist assistant reply +
  ConnRegistry.publish_message + Ledger terminal/publish.
- Wire front: Bandit (add dep) — Plug.Router for HTTP (/version, /agent/
  dispatch, /upload, /download, /api/*), WebSock handler per connection for
  /ws (pair/auth/message/stream_read/typing; keepalive; global device rate
  limits in ConnRegistry; auth registers w/ ConnRegistry, replays via
  Projection.list_after advancing note_replayed, then sync_complete).
- Tightbeam.WakeScheduler (from wakes.ts): durable, delivers by executing the
  deliverPrompt transaction with wakeId (Ledger dedupe), timer + boot scan.
- AdapterCoordinator: generation per (harness,archetype); lazy session/load
  re-adoption bounded; circuit breaker; wire the SessionLane quarantine to
  observed Acp.Conn quiescence / generation recycle.

E2 EXIT: scripts/blackbox/{wire,dm,agent-uses-cli} (the TS referee binaries)
pass against the BEAM gateway on a real adapter. Then E3 (adopt-in-place, sim
E2E, soak) + cutover.

## E2b — sol — Projection + Org

Ported Tightbeam.Projection from store.ts: messages/read_states schemas,
transactional append with client-message duplicate/conflict semantics,
provider-visible message ids, JSON attachments, cursor replay, tails, and read
state upserts. Ported registry.ts as Tightbeam.Org (avoiding Elixir Registry):
sessions/harness_pointers schemas, user/admin active catalogs, mutations,
append-only pointer chains, and personal/custom session-key helpers. SQL keeps
the TypeScript camelCase schema exactly; Elixir context inputs and returned maps
use snake_case consistently with the existing modules. 44 tests + 1 doctest
green.


## Review pass — Fable (post model-drift audit)

Read all 1,911 lines as committed (every module + test) against the port
spec, the tenets, and OTP semantics, after Flynn flagged that some impl
happened under Opus. Verdict: sol ports (Projection/Org) faithful and
pattern-conformant; E1 spine sound. Four fixes applied:
1. BUG (Fable E2a): clean-shutdown stamp moved stop/1 -> prep_stop/1 —
   stop runs after the tree (and DB) is down, so every shutdown would have
   been inferred dirty, destroying the dirty-exit signal.
2. Projection.after -> list_after (reserved-word unquote trick was un-boring;
   T6).
3. uuid4 deduplicated into Tightbeam.Id.
4. Org.list_for_user documented: wire callers MUST pass is_admin=false
   (owner-only catalogs; admin is powers, not a merged feed).

## Docs layer — Fable authoring pass

Sol's mechanical sweep was reverted per Flynn: the documentation layer encodes
invariants, so it is pattern-establishment work and Fable authors it. Every
public function in every module now carries @doc (what + invariant) and @spec;
shared shapes are @type'd (DB.row, Projection.message, Org.session/pointer,
EventLog.verb_event/lifecycle_event, ConnRegistry.deliver, Adapter.model_ref);
pure helpers (Org.personal_session_key, Adapter.parse_model_ref) have running
doctests; DB.Txn is now documented (it is a cross-module contract, not private);
all internal review-round citations in moduledocs replaced with the property
they named. Gate: mix test green (3 doctests + 43 tests), mix docs zero
warnings.

## E2a — sol: store layer

Implemented the authored Devices, Idempotency, Wakes/WakeScheduler,
Wire.Payloads, and Dispatch skeletons, plus their ExUnit acceptance coverage.

TS-vs-skeleton discrepancies implemented in favor of the skeleton as directed:
- wakes.ts delivers a due wake before changing it to fired, leaves failed
  deliveries pending for retry, and stores firedAt. The skeleton instead
  requires a transactional pending/due CAS to fired before delivery and has no
  firedAt column.
- wakes.ts listPending optionally filters by sessionKey and accepts an injected
  clock. The skeleton exposes only unscoped list_pending/1 and uses system time.
- payloads.ts includes sessionInfo and streamTailState builders, but the
  skeleton defines no signatures for them, so no extra public functions were
  added.
- devices.ts makes platform/model optional and payloads.ts makes prompt-state
  error optional. The skeleton map specs require those keys with nullable
  values, so the Elixir functions require the keys and omit only nil wire keys.
- dispatch.ts uses a mutable registry and guard, throws on unknown/denied calls,
  and appends no event for unknown verbs or handler failures. The skeleton uses
  an immutable handler map and requires error tuples plus exactly one denied or
  verb event for every outcome.

Review (Fable): sol correctly flagged the wakes.ts discrepancy above — the
skeleton was wrong, not the port. wakes.ts order (deliver → mark fired on
success; failures stay pending for retry) is load-bearing for the kill
matrix, so Wakes was corrected to deliver-then-mark, firedAt restored (E3
adopt-in-place needs TS-compatible schema), the wakes_due index made
non-partial to match TS, and a failed-delivery-retries test added. All other
E2a modules accepted as implemented.

## E2b — sol: wire/composition

Implemented the authored WebSock wire handler, Plug control-plane router,
adapter lifecycle/load coordinator, and Gateway composition root. The gateway
now composes the E2 stores with the durable Ledger/Lane pipeline, creates the
gateway-owned CLI credential/discovery file, exposes the closed verb table,
and publishes the canonical turn frames in golden order. Added direct WebSock,
Plug, coordinator, transactional delivery/dedupe, and fake-adapter golden-turn
coverage.

Skeleton-vs-TS discrepancies implemented in favor of the skeleton as directed:
- http.ts exposes the client routes as `/api/streams`, `/api/session-status`,
  and `/api/session-control`; the Router skeleton instead specifies `/streams`,
  `/sessions/:key/status`, and `/sessions/:key/control`, so only the authored
  skeleton paths were implemented.
- gateway.ts appends the echo and enqueues its FIFO turn as separate writes;
  the Gateway skeleton requires Projection insert + Ledger enqueue in ONE DB
  transaction, so the Elixir path is atomic and wake UNIQUE rollback removes a
  second echo as well as the duplicate turn.
- server.ts performs device takeover in its wire-server connection set. The
  authored ConnRegistry API returns only the replaced connection reference,
  not its pid, although Socket's moduledoc says the socket sends the old pid
  `{:takeover_close}`. ConnRegistry therefore captures the old pid and sends
  the close notification only after installing the new generation; Socket
  still owns the close frame/termination behavior.

Documented E2b stubs:
- `cancel` returns `%{code: "not_running"}` until turn-task kill wiring lands,
  as explicitly required by the E2b task. Session status continues to advertise
  the TS-compatible cancel capability.
- `/upload` returns `{"error":{"code":"not_implemented"}}`; Assets is E3.

Genuinely required engine seams added for the authored composition contract:
- Projection gained `append_in_txn/2`; without a transaction-handle entry point,
  Gateway could not atomically commit the echo with `Ledger.enqueue_in_txn/2`.
- Ledger gained adapter-generation stamp/prior-generation queries, and
  SessionLane now includes its owned session key in the runner input. The
  existing claimed-turn map omitted the session key, while the authored runner
  must resolve Org and lazily reload only after a generation change.
- SessionLane recognizes a runner terminal-publication callback and invokes it
  only after winning Ledger.finish CAS. The prior runner contract had no seam
  capable of producing the documented assistant → terminal → typing-off →
  activity-off order after durable terminal transition.
- ConnRegistry gained the documented global per-device sliding windows for
  pair and typing limits; per-socket state would reset on reconnect and violate
  Socket's binding invariant.

Review (Fable, E2b): sol implementation accepted with three fixes applied.
1. SKELETON BUG (mine, sol flagged it): the Router skeleton invented cleaner
   paths; the wire contract is the TS as-built surface. Routes corrected to
   /api/streams, PATCH|DELETE /api/streams/:key, /api/session-status?sessionKey=,
   /api/session-control, /api/trackable-sessions, /download stub — paths are
   contract, never rename.
2. RACE (real, in the drain): a message published between ConnRegistry.register
   and note_replayed passes the registry filter (watermark 0) AND is in the
   replay window → duplicate after unfiltered drain. Message pushes now arrive
   as {:push_message, key, seq, payload}; the socket tracks replay watermarks
   and drains THROUGH them; regression test added.
3. RACE (narrow): stale :DOWN after adapter_for restarted a dead-but-unreaped
   adapter would nil the fresh pid and schedule a spurious restart (leak).
   Coordinator now ignores :DOWN whose ref is not the entry's current monitor.
Sol's engine seams (append_in_txn, generation stamps, terminal-publish
callback, registry-owned takeover, global rate windows) all accepted —
registry-owned takeover judged MORE atomic than the skeleton's socket-owned
variant.

## E2c — sol: homes projection + runtime config

Ported the disposable harness-home projection from `src/homes/project.ts`:
homes are rebuilt at `homes/<archetype>/<harness>`, receive the harness-specific
guidance file and optional extra files, and symlink operator-owned credentials
from `auth/<harness>` without copying or modifying the auth source. Gateway
adapter startup now projects those homes with the verbatim scheduling-wakes
guidance and archetype header from `gateway.ts`. Added runtime environment
projection for the six requested `TIGHTBEAM_*` settings without changing code
defaults.

## E2 EXIT — black-box drivers pass on BEAM (Fable)

One more contract fix found by the driver itself: the TS reference upgrades
WebSocket on ANY path (client connects at "/"); the router upgraded only at
/ws. Root upgrade added (guarded on the upgrade header; /ws kept as alias).

Then, against a live BEAM gateway (mix run, env config, real
claude-agent-acp adapter, haiku):
- wire-first-light  ✅ pair→auth→sync→post→echo→accepted→running→real
  assistant reply→delivered + /version /api/streams /api/session-status.
- dm-first-light    ✅ CLI spawn (stream_created broadcast), agent-origin
  immediate wake DM (assistant "DM ACK"), durable 2s delayed wake
  ("DELAYED ACK" after ~4s incl. turn time), inspect from the agent's seat.
- agent-uses-cli    ✅ a real harness agent ran the tightbeam CLI from its
  own shell (TIGHTBEAM_HOME discovery + PATH bin from the home projection)
  and reported COUNT=3 through its own turn.
Note: drivers each need a FRESH base_dir (first-user bootstrap); running two
against one substrate correctly yields pair_pending → auth denied.
Remaining acceptance wall (E3): golden-trace comparator, ExUnit additions
(kill matrix, replay-under-write over a real socket), adopt-in-place, sim
E2E, soak.

## Defect fix — projection wiped harness conversation memory (Fable)

Found while answering "where do agent folders materialize": harnesses nest
their session state (transcripts/sessions) INSIDE the config dir we project,
and Homes.project (faithfully porting project.ts) rm_rf'd the home on every
adapter start — so every gateway reboot silently destroyed all sessions'
model-side memory and session/load would fall back to fresh sessions. The
bible already said "regenerated on identity change"; both implementations
over-triggered. Fix: projection is now idempotent, gated on a manifest hash
stamped into the home (.tightbeam-manifest). Unchanged manifest → home left
alone, missing auth symlinks topped up; changed manifest → full delete +
reassemble (identity change forfeits nested state by design). Test added
(nested state survives restart; new auth topped up; identity change still
wipes). NOTE: the TS reference has the same defect (projectHome rm -rf on
every adapterFor); TS repo is feature-frozen during the port — record only.

## Isolation fix — admin devices no longer receive foreign content (Fable)

Found auditing isolation for Flynn: the ConnRegistry skeleton said fan-out =
"owner + admins" and sol built+tested that — but the TS reference fans out
strictly to the owner, and the admin ruling is powers-not-merged-feed. The
Elixir gateway was pushing other users' message/turn/typing bytes to admin
devices (client-invisible, but bytes crossed the wire). Fan-out is now
owner-only in both publish_message and broadcast; test inverted to pin it.
Skeleton bug (Fable), third of its kind — TS-as-built remains the oracle for
every observable surface.

## E4 skeleton (Fable): placement + minimal archetype manifests

Realizes the placement/identity design ruled this week (spec §Placement,
§Agent identity references; decisions ledger 2026-07-17 entries). Authored:
- Tightbeam.Archetypes (skeleton): TOML manifests (name/where/defaults/
  references/guidance) under identity/archetypes/, boot-time load into
  :persistent_term, fail-boot on malformed law; guidance compilation owns
  the wakes skill + renders references as "## Your materials". Deliberately
  NOT the full identity compiler (fragments/skills/MCP/hash-homes remain
  the later milestone). Built-in default archetype (where ["local"]).
- Tightbeam.Placement (skeleton): the ONE module that knows hosts exist.
  Hosts = instance config ("local" reserved); resolve/3 = constitutional
  set-membership with deny-and-explain; adapter_opts/2 = ssh-wrapped cmd
  with ALL agent env embedded remotely (advertised_url for TIGHTBEAM_URL);
  deliver_home/3 = local Homes.project | stage-without-auth → remote stamp
  compare → rsync (never --delete) → remote auth ln -s loop; injectable :sh.
- Org: host column (additive migration, adopt-safe: DEFAULT 'local'),
  host in create/select/mapper, set_host/3 (implemented, not skeleton).
- Gateway wiring (implemented): Archetypes.load! at composition; adapter
  keys widened to {harness, archetype, host} end-to-end; spawn goes
  archetype-exists → Placement.resolve → create with host (archetype
  defaults slot between explicit params and global defaults); tune gains
  set_host (fresh-context move; transcript carry-over journaled as later).
- Decisions: minimal manifests now / full compiler later; "local" reserved;
  moves are fresh-context this increment; hosts via TIGHTBEAM_HOSTS JSON +
  TIGHTBEAM_ADVERTISED_URL; deps + toml (~> 0.7).
- Tightbeam.Skeleton.todo!/1: compile-honest stub (typed term()) so the
  composition root compiles under --warnings-as-errors against unfilled
  bodies. Golden-turn test @tag :skip pending E4a (sol un-skips).

## E4a — sol: placement/archetype bodies

Implemented the authored Archetypes and Placement skeleton bodies, added their
acceptance coverage, removed the compile-honest skeleton helper, and unskipped
the local golden-turn test.

Flag: the remote ACP adapter binary location is config-shaped and provisional.
A host may supply `:adapter_bin_dir`; absent that, Placement applies the existing
`../tightbeam/node_modules/.bin/<adapter>` convention relative to the remote
host's `base_dir`. The correct fleet-wide installation location remains an
operator/configuration decision rather than topology embedded in Placement.

Review (Fable, E4a): sol bodies accepted as implemented — resolve/hosts
exact to contract; the remote env PATH=$PATH trick is correct (ssh re-parses
the command string, so $PATH expands in the REMOTE shell); stamp-check
tolerates cat's exit 1; rsync without --delete verified; staging carries no
auth. One live-fire find was MINE: the coordinator's health/1 and key_name/1
destructured two-tuple keys after I widened keys to three — /version crashed
the coordinator on the first post-E4 boot. Fixed (key_name now
"harness:archetype@host", health maps via key_name; coordinator tests
updated). Provisional flags standing: remote adapter binary location
(host config :adapter_bin_dir, else base_dir-relative convention); remote
session cwd is config.cwd verbatim (per-archetype workdirs later); stderr
log path not yet host-keyed. wire-first-light re-run PASS against the
post-E4 gateway (local-path parity proven end to end).

## Host onboarding (Fable): register-host verb + hosts.json registry

Per Flynn: satellite onboarding must be a CLI command, not a runbook. Design
(now in spec §Placement): the ceremony lives in the CLIENT (`tightbeam
assimilate <ssh-dest>` — prepares the machine over ssh), the FACT lives in
the substrate (admin-gated register-host verb writing base_dir/hosts.json).
Placement.hosts/1 merge order: hosts.json < env :tightbeam,:hosts < reserved
"local". Credentials are HARVESTED from the satellite's own harness logins
by default; pushing is an explicit flag. The substrate performs no remote
setup — an incompletely assimilated host degrades as a failing adapter.
Verb added to router AGENT_VERBS. CLI assimilate implementation dispatched
to sol (TS repo — freeze exception journaled there: CLI is shared surface,
placement-critical).

## Guidance fragments + #include (Fable)

Per Flynn: shared guidance across archetypes with an include mechanism.
Implemented (spec §Agent identity amended): fragment library at
identity/guidance/*.md; a line of exactly `#include "fragment.md"` resolves
recursively at compile (cycle + missing fragment fail the BOOT via load!
whole-set validation — bad law stops the factory); depth-capped; includes
only, never variables/conditionals ("a template that can compute is an
agent that can't be audited"). Built-in fragments preamble.md and
scheduling-wakes.md ship in code and are overridable by same-named operator
files — so every session already carries CLI operating knowledge at spawn
without running help. Default compiled output byte-identical to
pre-fragment guidance (projection hashes unchanged). Base skills answer:
the wakes skill IS baked into every home; a richer shared skills library
(SKILL.md dirs chosen by name) remains the full-compiler milestone.

## E4b — sol: CLI assimilate (reviewed Fable)

Implemented `tightbeam assimilate <ssh-dest>` in the reference CLI per
contract (freeze exception, journaled above): BatchMode ssh probe with
diagnostic failures (keys/node/rsync named), remote mkdirs + ~-resolution,
HARVEST-by-default credentials (remote-side cp; --push-credentials scp's
local creds with a loud line), npm adapter install under <base>/adapters,
single-file CLI ship + sh shim, then the register-host verb through the
normal dispatch facade. --dry-run prints every command (cannot resolve
remote ~ or credential state without executing — reported as such; sol
flag, accepted). Also introduced proper boolean flags in the arg parser
(fixes latent --demote arg-swallowing). Review: contract-faithful; quoted-
heredoc shim correct; argv-only exec throughout. Gate outside sol's sandbox:
tsc clean, 84/84 TS tests pass, help entry verified, dry-run smoke against
a REAL remote (tars) emitted the exact command sequence. TS repo commit
89c3063 (repo is local-only; no remote configured).

## where wildcard (Fable)

Per Flynn: `where = ["*"]` (alone) grants any CONFIGURED host; nil-host
under "*" resolves to "local". Empty where remains a load error — law fails
closed; in set logic an empty where is nowhere, and a typo must never be
the most permissive value. "*" mixed with names rejected as incoherent.
Spec §Placement amended.

## Dead-host hardening (Fable)

Deficit audit prompted by Flynn's disconnected-host question. Three fixes:
1. ARCHITECTURAL: adapter boot made lazy (init → handle_continue). Opts
   building — including remote home delivery over ssh — previously ran in
   the AdapterCoordinator's loop, so one slow/dead host could stall every
   session's checkout and /version for seconds-to-minutes. Boot now runs in
   the adapter's own process; a boot failure is an ordinary adapter crash on
   the uniform :DOWN → backoff → circuit path. Corollary fixed in review:
   under lazy boot a spawned pid proves nothing, so the circuit no longer
   closes on spawn — only on {:adapter_ready} (boot completed), via a new
   on_ready callback. Backoff base made injectable for tests.
2. ssh hardening: BatchMode=yes + ConnectTimeout=5 on the adapter ssh wrap
   and every deliver_home ssh/rsync (-e) call — dead hosts fail in seconds
   with a reason; a password prompt can never hang an adapter.
3. UX: circuit-open turns now fail with a readable reason naming the
   harness/archetype/host and pointing at /version, not the atom :degraded.
Gate: 92 tests + 3 doctests green; wire-first-light re-PASS on the
lazy-boot gateway.

## Real cancel (Fable)

Replaced the E2b cancel stub. The LANE owns the kill: cancel_current does a
CAS terminal transition to "canceled" FIRST (if the TurnTask completes in
the same instant the CAS decides the winner — exactly one terminal state
either way), then kills the task; the killed task's :DOWN finalize hits
:already_terminal, no double publish, and the lane drains on immediately.
The gateway's cancel handler broadcasts canceled turn-state + typing/
activity-off and best-effort notifies the harness via ACP session/cancel
(fire-and-forget — the ledger row is the truth regardless). Lane test added;
the drain-races-second-cancel window is documented in the test.

## E5 — sol: assets

Ported the final attachments wire gap from `assets.ts` and `http.ts`: camelCase
adopt-in-place SQLite metadata, flat `assets/a_<uuid>` blob layout, request-
process file I/O with no Assets process, 32 MiB multipart upload handling, and
owner-or-admin downloads via file streaming. The live upload response remains
the TS `{assetId, mimeType, size}` contract.

TS discrepancy: Plug's multipart limit counts multipart headers and fields,
where Busboy's `fileSize` limit counts only file bytes. The parser therefore
gets Busboy's default 1,000,000-byte non-file allowance beyond the 32 MiB file
cap, and the parsed `Plug.Upload` file itself is checked against exactly 32 MiB.

## Live-fire feedback round 1 (Fable) — discovery + orientation

First real resident conversation (Flynn ↔ fable on the BEAM gateway)
surfaced three deficits, all confirmed against code:
1. inspect exposed sessions+wakes but not the ORG SHAPE — agents could not
   discover archetypes (or their WHERE), known hosts, or valid model refs,
   so the resident guessed a nonexistent model. inspect now returns
   archetypes/hosts/models ("discovery beats documentation"); the CLI's
   list renders them via its JSON passthrough.
2. CLI spawn had no --host though the verb supports it. Added + help.
3. Guidance taught operation, not orientation. New built-in overridable
   fragment orientation.md ("## Orientation" section in every home): what
   the substrate is, the nouns, discovery-first/never-guess-model-refs,
   placement, refusals-name-rules. NOTE: this changes the default manifest
   hash → homes regenerate on next adapter start (identity change wipes
   nested harness session state by design).

## De-branding + called-into-being orientation (Fable)

Per Flynn: "dark factory" swept from the bible and ALL agent-facing text —
it is one use of the substrate, not its identity (the substrate carries no
ticketing/workflow machinery). Bible §Spirit/§What-it-is reworded; CLI help
"in this factory" → "in this org". Orientation rewritten from the
called-into-being POV: the agent doesn't live in Tightbeam — Tightbeam
summoned it ("Between turns you are not running; you are woken. That is not
a limitation. It is how you persist."). Guidance hash changes again →
default homes regenerate on next adapter start.

## Live-fire round 2 (Fable): typing-indicator progress + operational authority

1. agent_progress frames (the client's existing AgentProgressEvent contract,
   never sent by TS): the Adapter maps ACP session/updates to status lines
   (thought chunk → "Thinking…", tool_call → its title) via pure
   progress_status/1 (doctested), deduped on text change, relayed through a
   per-turn progress fun into an owner-scoped broadcast with the turn's
   correlation id — so the assistant final clears the label (client-side
   contract), and failed turns clear it explicitly (state "failed"). Success
   path emits no terminal frame: golden frame order unchanged.
2. Operations fragment (builtin, overridable): authoritative ops facts —
   spawn flags incl --host + the placement rule, catalog-only model refs,
   wake/DM semantics incl reply-lands-in-your-stream, tune/retire/
   cancel-wake, assimilate, attribution — prefixed with the norm: consult
   list, then answer definitively, never "probably" (Flynn: agents must
   speak with authority on tightbeam operations).
