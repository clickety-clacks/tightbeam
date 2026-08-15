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

## Stuck-indicator fix (Fable) — terminals now reach the wire after crashes

Live-fire find (Flynn): gateway bounce killed an in-flight turn; boot
recovery marked it failed_unknown but the "re-publish" step only stamped
publishedAt — NO wire frames — so the client's typing indicator stuck until
its own timeout ("agent progress interrupted"). Same hole on the lane's
task-crash path (runner died before returning its terminal_publish
closure). Fix: a real terminal publisher (built in Gateway, closure over
db) is injected into LaneManager (reconciler republish path) and
SessionLane (no-closure finalize path): terminal prompt_turn_state with the
recorded reason ("interrupted: outcome unknown" for failed_unknown),
typing/activity cleared, progress label cleared. Ledger.unpublished_terminals
now carries the error column. Also fixed a silent test-hygiene miss:
persistent_term cleanup in archetypes tests targeted a stale setup literal
and never applied (Python replace without assert — the lesson is asserted
replaces from now on).

## Graceful drain (Fable) — deploys must not eat turns

Flynn, after the deploy-broke-comms incident: a bounce's designed cost was
still "in-flight turns die failed_unknown". Now: prep_stop flips a draining
flag (lanes claim nothing new; queued turns stay durable and run next boot)
and waits — bounded by :drain_timeout_ms, default 90s — for running turns
to finish. Past the deadline, remaining turns die exactly as a crash: the
graceful path is an optimization, the crash path remains the guarantee.
SIGTERM (kill <pid>) triggers it; kill -9 skips it by nature, covered by
recovery + terminal publisher. Deploy SOP: plain kill, wait for exit, start.

## Smoke run #1 — sim (eezo) vs BEAM gateway on SHRDLU (Fable)

First execution of docs/SMOKE.md, and the first fully cross-machine
deployment: gateway + adapter + agent shell on shrdlu (Ubuntu x86_64,
Erlang/Elixir via mise), driven by the real Clawline iOS client in the eezo
simulator. Gateway @ dc7a788+; client build Jul 15.

PASS: §0 pair/first-user-admin; §1 converse + tool use (assistant quoted
"Linux shrdlu 6.8.0-134-generic" — the agent's hands demonstrably on the
work machine); §2 spawn (org-shape discovery incl archetypes/hosts/models)
+ rename + retire (soft; messages survive); §3 cancel mid-turn (verb path;
this client build has no stop control — ⌥); §4 queueing ONE/TWO/THREE in
order, one-at-a-time; §5 concurrency (Smoke B's turn started AND finished
inside Main's running turn; Main's next turn started 1ms after its prior);
§6 /new /compact /model all delivered, zero stuck indicators (regression
class dead); §7 drain (SIGTERM waited through a real 45s tool turn, then
exited; instant exit when idle) + durable work across death (wake scheduled
→ killed → restarted → fired → "PHOENIX"); §8 wakes immediate + delayed.

Findings for follow-up:
- cliToken re-mints every boot; should persist (agents/operators hold stale
  tokens across restarts).
- Client (Jul 15 build): posts sent while the socket is down are silently
  dropped, not queued for resend — Clawline-upgrade list.
- Mid-turn progress label not visually captured (turns too fast for
  snapshot cadence); frames verified by tests. Sim autocorrect mangles
  typed commands ("uname"→"inane" — which the agent then correctly ran and
  reported as not found, inadvertently proving tool execution).
- OTP 28.0.2 on shrdlu logs a "use 28.1+" warning at boot — upgrade when
  convenient. pgrep-based process watching self-matches; use port/pid.

Correction to smoke run #1: the "client silently drops posts while socket
is down" finding is RETRACTED — the drain-window message never left the
compose field (the automation's Send tap didn't register); the client
neither sent nor dropped anything. What remains as fact: the client's
offline story is failed-bubble + MANUAL tap-to-retry (resendFailedMessage);
no automatic outbox replay on reconnect — an observation for the Clawline
upgrade, not a bug. Also still true: this build exposes no stop/cancel
control. Lesson recorded: verify the failure is real before attributing —
a blocked UI tap looks identical to a network drop from the DB's side.

## Footer saga + set_harness (Fable)

Flynn: footer stuck on "unavailable" even after the sessionKey fix. Root
cause found DEFINITIVELY by compiling the client's own SessionStatus.swift
into a CLI decoder and feeding it the live payload: modelCatalog.models[*]
REQUIRES an `id` key (we sent ref/name/provider). Swift decode fails the
whole document per missing key, and the client's failure state renders as
"unavailable" — invisible server-side (200 + valid JSON every time). Fixed
(id = ref), deployed, decoder now prints DECODE OK. LESSON, now practice:
wire-contract checks against Swift clients must run the client's decoder,
not eyeball JSON — harness kept at scripts/decode-status.swift (compile
with the app's SessionStatus.swift + JSONValue.swift).

Also landed: tune set_harness — engine swap on a live session (same
identity, different harness; provider+model updated, model from the target
harness's catalog when unspecified; old harness session can't load on the
new engine so the existing fallback pointer path yields a fresh model
context, chat history untouched). The spec's "swaps the engine underneath a
stable identity" is now an actual verb.

## DM return address (Fable)

Flynn's question exposed it: the wake's origin reached the UI (sender tag)
but NOT the model — prompts were delivered raw, so a DM'd agent could not
know whom to wake back (inherited from the TS reference). Fix: wake-
delivered prompts (any deliver_prompt with :sender) are stamped
`[from <origin>]` in the MODEL-visible prompt only; the stream message
stays clean (UI already shows sender). Fact-stamping — mechanical
provenance, like a mail header — not content fabrication. Operations
guidance updated: the stamp is the return address; a stamp bearing your own
handle is your scheduled self (act, don't reply). Delivery mechanics
confirmed unchanged and documented: a DM IS a turn (content delivered
directly into context, no go-look pointer), and the lane serializes it
behind any in-flight user turn — DMs never interrupt, they queue.

## 2026-07-18 — deploy amnesia: loaded sessions abandoned over a refused model re-assert

Flynn: mike:main "doesn't remember my earlier messages" with no /new issued.
Pointer chain read 1 created + 10 fallbacks — every fallback a fresh harness
session, model context gone (chat history intact substrate-side).

Two contributing causes, one mechanism:
1. Earlier in the evening: guidance churn changed the manifest hash, and the
   hash-gated home projection correctly wiped the home — identity change
   forfeits nested harness state by design. Those losses were expected.
2. The recurring one: on the load path, `apply_model` re-asserts the
   session's model after `session/load`. claude-agent-acp's valid-value set
   for the model option is populated ASYNCHRONOUSLY and can lag adapter
   boot — both live refusals ("Invalid value for config option model:
   fable") landed within ~5s of adapter spawn; direct ACP probes minutes
   later accepted the same value (and showed the valid list itself
   shifting: `claude-fable-5` vs `claude-fable-5[1m]`). So the first turn
   after every deploy could hit load → refused re-assert → fallback →
   amnesia. Deploys drained turns cleanly and still cost memory.

Fixes:
- Adapter load path: apply_model after a successful load is BEST-EFFORT. A
  loaded session already has a model; a refused config re-assert must never
  cost the session's memory — continuity outranks the option. (This also
  removes a residual `:ok = apply_model` match-raise the hardening pass had
  missed on the load success branch.)
- Gateway fallback branch: every fallback now records a `pointer_fallback`
  lifecycle event carrying the load error — memory loss always has a row
  and a reason (T5). Tonight's fallbacks were undiagnosable precisely
  because the hardened path failed silently.

Verification: deploy → turn → pointer reason `loaded` (SMOKE §7 step 14
condition), and the session remembers pre-deploy turns.

Followup, same night: the new pointer_fallback event exposed the TRUE root
cause on its first firing — session/load was rejected with -32602
"mcpServers: Required value is missing". The gateway's load request sent
only {sessionId, cwd}; claude-agent-acp requires mcpServers (the direct ACP
probe passed [], which is why probe loads succeeded while gateway loads
never did). Every load since the field became required failed on protocol
shape — the "lost session" was never lost. Fix: mcpServers: [] on
session/load, matching session/new. The model-refusal observed at 23:20 was
a secondary symptom on the same path. Note: the agent aced the continuity
check even on a fallback because it had written itself a memory file — nice
validation of agent-side memory, but the pointer reason is the truth.

## 2026-07-18 — context-reset marker; credential rotation war

Flynn (UX): a fallback is invisible in the client — "i dunno where that
line is and it looks like a bug." Added the [context reset] MARKER MESSAGE:
on fallback the substrate appends an ordinary message at the reset point
(role assistant, sender "process:tightbeam", bracketed first line), so it
rides replay/live-push with no new frame type. Anti-forgery: model output
always commits with sender "tightbeam", so no session can emit a marker by
typing one. Convention documented normatively in Payloads (§MARKER
MESSAGES); bible §source-of-truth updated: the log is the operator's
record, the context is the model's working set — history is never trimmed
to match model memory. Test: fallback turn's golden order shows marker
between echo and reply.

Separately, live: mike:main turn failed "OAuth session expired and could
not be refreshed." Cause: the harvested credential copy shares one OAuth
grant with the operator's interactive ~/.claude login; refresh tokens
rotate on use, so the two stores race — ~/.claude refreshed 00:07, the
gateway's copy tried at 00:09 with the now-dead token. Also found: harness
refresh replaces our auth symlink via rename, so the home holds the only
live lineage; a home wipe then bricks the login. Fixes: (a) re-harvested
fresh creds (unstick); (b) Homes now harvests regular-file auth entries
back to the store BEFORE a wipe. Open risk, flagged to Flynn: sharing the
grant with an interactive login will race again — the durable fix is a
dedicated harness login for tightbeam's auth store (needs Flynn's browser).

Same night, second marker kind: [turn failed]. Flynn: "the failed oauth
should return at least a synthesized assistant message... an error bubble."
A terminal failure existed only as a prompt_turn_state frame, which the
client ignores — the prompt silently vanished. Now both failure routes
append a marker where the reply would have been: the runner's in-band
failure path (raw ACP error humanized via message/details) and
terminal_publisher's crash-recovery path ("interrupted: outcome unknown").
Exactly-once by construction: both routes are already gated on the
ledger's CAS / unpublished-terminal scan. Payloads §MARKER MESSAGES now
lists both kinds; bible updated. Tests: failed-turn marker with humanized
reason; fallback marker golden order.

## 2026-07-18 — assimilation as shipped guidance

Flynn live-fired assimilation from Clawline; the agent got there, but by
archaeology: source-dove ~/src/tightbeam_ex to learn archetypes are TOML,
guessed the where format, and discovered by accident that manifests load
at boot. Everything it had to excavate is now a builtin guidance fragment
(assimilation.md, its own ## Assimilation section in every archetype's
composed identity): the full ceremony — command + flags, credential
doctrine (relay the printed login commands to the operator VERBATIM;
"missing" is degraded-not-failed; never --push-credentials uninvited),
default.toml override recipe with the where edit called out as
memory-safe, the restart-to-apply rule stated as a reporting obligation,
and the verify step. Guidance change = manifest hash change → homes
regenerate on next adapter boot → sessions fall back (visible via the
[context reset] marker — the cost of an identity change, by design).

Same morning, refined per Flynn: assimilation guidance must not be
always-loaded, and skills are first-class — not extra_files freight. Built
the spec's skills library for real: identity/skills/<name>/SKILL.md, manifest
`skills` election (omitted = builtin set; unknown fails boot), builtins
materialized only-if-absent (operator edits win), projection by reference —
symlink locally (content edits propagate live, hash unaffected), copy into
staged homes for satellites. Election is in the manifest hash; content is
not. Composed guidance now carries only a one-line Operations pointer at
the skill. Tests: election validation, materialization precedence, link
live-update with stamp intact, copy refresh, election-change regeneration.

Continued: skill trees + replicated library + skill verbs (Flynn design
session). Trees are a CONVENTION carried by existing mechanism — subject
dir, root SKILL.md as routing manifest, techniques nested; election atomic
at roots (nested names simply don't exist as electable). Killed the
link-vs-copy special case: every host now holds a library replica at
identity/skills/, homes always symlink into their OWN host's replica
(staged links dangle by design, resolve on arrival), and deliver_home
syncs elected roots to the satellite replica as catch-up. New chokepoint
surface: skill-put / skill-rm / skill-list verbs (admin, audited) + CLI
`tightbeam skill ...`; put pushes all remote replicas immediately
(--delete rsync so tree prunes propagate), rm refuses elected roots,
per-host push results degrade visibly instead of raising. 106 tests.

Flynn: "this skill api has a skill for its operation?" — it didn't; now it
does. Second builtin: tightbeam-skills (the skill about skills) — library
shapes, tree-authoring convention (parent routes, never teaches),
verbs/CLI, propagation semantics (immediate push, per-host degradation,
delivery catch-up), election atomicity + the two facts to always report on
election changes (restart-to-apply; homes regenerate = memory cost).
Operations gains the one-line pointer. Default election is now both
builtins — an election change, so deployed homes regenerate once.

E2E assembly probe (Flynn: "you tested in a new session that these skills
and guidance are assembled correctly and tested custom sample skills and
guidance fragments?"). Authored operator material: custom fragment with a
RECURSIVE #include (probe-fragment → probe-inner), a custom skill TREE via
skill-put (probe-subject + probe-subject/technique, both pushed to tars),
and a probe.toml archetype electing [probe-subject, tightbeam-skills] with
#include in its [guidance]. Restart → spawn fresh "Assembly Probe" session
→ quiz. ALL PASS: both fragment markers quoted from context (recursive
include composed); election exact (tightbeam-assimilate correctly ABSENT);
nested tree file read from inside the home and its marker quoted. Home
bytes confirmed both markers; skills dir linked exactly the elected two.
Observation: the harness surfaces its OWN built-in skill set (init,
review, security-review, deep-research, ...) alongside ours — harness-
native, NOT a leak of eezo's personal ~/.claude skills (none of those
appeared). Probe artifacts fully cleaned after (retire, rm skill w/ tars
push, fragments+toml deleted, restart).

Rails v1 shipped and live-fired on SHRDLU (per Flynn: testing belongs
there, not on mike:main). Build: sol (gpt-5.6-sol high) against
shared/specs/tightbeam/rails-v1-implementation.md — one dispatch, all six
authorized files, gate green in well under the ceiling; review found one
defect IN THE SPEC (byte-pinned stop_hook_active guard assumed compact
JSON — a vendor formatting change would have left turns unable to end;
guard made whitespace-tolerant in code/tests/spec). Shrdlu verification:
fresh gateway + statutes.toml; claude home settings.json carries both
hooks byte-correct; CLAUDE.md and codex AGENTS.md carry Standing law;
codex gets no settings.json. Native claude -p inside the projected home:
UserPromptSubmit injection CONFIRMED in the user turn (model quoted
"[standing law: announce-new-work] ..." verbatim, named the mechanism);
Stop hook bounced once, model addressed ticket-on-done, turn ENDED (loop
guard released). Bonus: [turn failed] markers fired on shrdlu too. Found
in the wild again: shrdlu's harvested smoke-era claude creds are DEAD —
the leftover smoke gateways rotated the lineage (the rotation war,
sighting #2); ACP turns failed with auth-masked "Invalid value for config
option model" until a transient env token was used. Shrdlu needs the
setup ceremony before becoming a real host. All my shrdlu test gateways
stopped after the run.

RAILS CORRECTED PER FLYNN — THE INVARIANT. On seeing the remind tier:
inference-governance being IGNORED is the entire impetus; a system that
makes more ignorable guidance is "process masturbation," and injections
additionally pollute context and perturb behavior. Ruling (now bible
§rails): rails never add guidance — zero bytes to any model's context;
deterministic guardrails only; sole sanctioned emission is the refusal
reason when a rail fires. Remind tier REMOVED (standing law, prompt
injection, stop bounces); mode="remind" refused with an error that
teaches the invariant; codex gets nothing for unenforceable gates.

Gate tier shipped (hand-built after a sol dispatch stalled 31min with
zero edits — killed per the check-in rule): statutes compile to
PreToolUse hooks; the harness refuses matching tool calls BEFORE
execution. Pinned torture test caught a real bug: backslash must be
escaped first or \$HOME in a pattern expands at hook runtime. Invariant
test pins guidance byte-identical with/without statutes.

SHRDLU LIVE FIRE, the proof: model with --dangerously-skip-permissions
ordered to run `git reset --hard HEAD` — the RUNTIME refused it
(PreToolUse exit 2), the model received "[gate: no-history-rewrites]..."
as the denial reason and reported "The command was refused by a pre-tool
hook, not by me"; git status then ran normally; the repo was untouched.
Deterministic enforcement, no inference in the loop. 115 tests.

REMOTE PLACEMENT VALIDATED (loopback satellite — Flynn: tars is not a code
blocker). Scratch gateway on eezo placing a session on "loopsat" (ssh to
self, distinct base_dir): home staged+rsync'd, skills replica synced, auth
linked, adapter ssh-wrapped, satellite token env expanded remotely, turn
DELIVERED from the satellite workdir with the satellite home's identity.
The live-fire caught two real bugs invisible to injected-sh tests:
(1) the remote auth-link script was passed unquoted — ssh joins argv and
the remote shell re-parses, so `sh -c` received one word; now
shell-quoted for the second parse. (2) the TIGHTBEAM_HOSTS env parser
predates adapter_bin_dir and silently dropped it, breaking remote binary
resolution. Also isolated the fable mystery: the harness's OFFERED model
list is environment-dependent — same home/auth offers fable at cwd=$HOME
(where the operator's settings.json pins claude-fable-5[1m]) but not at a
fresh workdir; every "intermittent" fable refusal tonight was this.
Documented in harness-support.md as an open investigation; loopback
completed on opus to keep vendor flakiness out of the machinery verdict.

CODEX ONBOARDED + FIRST CODEX LEG (Flynn provided the grant). Login driven
headlessly: codex login's localhost:1455 callback reverse-tunneled to
serenity's browser (ssh -R); grant landed in the org store (auth.json,
0600); discovered codex login --device-auth exists (hidden from --help) —
matrix corrected, codex onboarding now ✅ headless. First codex session
through the entire system: spawn (gpt-5.6-sol[medium]) → turn DELIVERED —
tool use (uname), projected AGENTS.md identity, and the read-on-demand
skill path (it read tightbeam-harnesses by path and quoted the bullet
describing that exact mechanism). Matrix rows upgraded to verified;
remaining codex-unverified rows enumerated. Note: the skill content
update propagated LIVE through the library symlink — no home regen, no
memory cost — the skills-replication design paying off in the field.

OPS HARDENING V1 (sol against ops-hardening-v1.md; reviewed). Six
sections: cliToken persists across boots; wake targets accept user ids
(bare or user:<id>, resolving to the Main via derivation — interim until
the roles registry subsumes it); claude homes pin their default model in
settings.json (the fable fix — TIGHTBEAM_MODEL_PINS, fable →
claude-fable-5[1m]; one-time home regen on deploy); host-keyed stderr
logs; external wake seam formalized (wake idempotency_key, process-origin
inspect lists own wakes, cancel scoped); workdir follows tune set_host
across all four topologies with fail-closed denial (workdir_move_failed —
silent memory loss never acceptable). Review found: sol stored wake
idempotency under operation "spawn" because the table CHECK didn't allow
'wake' — a constraint-driven workaround where the spec's STOP-and-report
rule should have fired; fixed properly (operation "wake" + CHECK widened
via rename-rebuild migration). 130 tests.

ROLES REGISTRY V1 shipped and live-verified. Two parallel sol lanes
(Elixir high / TS CLI medium) against roles-registry-v1.md — first
two-lane parallel dispatch; both green first pass, review found no
defects (the invariants-first spec format works). Live arc on prod:
role-create notetaker → wake while UNSTAFFED delivered to mike's Main
with roleFallback=1 → role-bind to the codex session → wake again
delivered to the office-holder with roleFallback=0; turn rows carry
roleRef + resolution both times ("late-bind the future, pin the past"
observed in the ledger). Bible gains the roles paragraph in §Primitives;
handles subsumed (migration ran; empty — no handles existed in prod).
138 Elixir tests, 14 CLI tests.

TYPED TARGET SEAM (Flynn ruling: "it's either a userid, role, session
key, never a union — basic tenet of typed apis"). The prefix-classified
`target` string — a tagged-union-by-convention, and root of both
adversarial findings — is gone. Verbs take exactly one of sessionKey |
role | userId (modeled on the as/asUser/asProcess seam, which was always
right); retire is sessionKey-only; the retired `target` field errors
teaching the seam; CLI wake/retire take --session/--role/--user. Lane C
by sol (20/20); lane E hand-built after a second zero-edit sol stall
(killed at check-in per the rule). Overengineering review (Flynn asked):
TransactionError raise/catch is the legitimate price of spawn atomicity —
kept; migrate_handle duplicates create!'s insert for a one-time
migration — noted, not churned; a stale classification-era comment on the
name lexicon corrected (reservation kept for human-hostility, not
parsing). Guidance rewritten to typed flags (identity change, homes
regenerate once). SMOKE §10 steps updated to the flag forms.

SOAK DRIVER'S FIRST CATCH — the acp_exit wedge. The self-check's A3 audit
failed: an adapter SIGKILL left ZERO substrate records. Root cause: Conn
survives its OS process's death (closed, failing pendings) and emits
{:acp_exit, status} — which NOTHING consumed. The Adapter GenServer lived
on with a dead conn; the coordinator's monitor never fired; no
adapter_down row, no generation bump, no circuit (boot-failures only) —
every future turn fails until a deploy. The "near-impossible in Elixir"
wedge class, again, and only a chaos audit found it (all prior adapter
death tests killed the GENSERVER, not the OS process). Fix: the adapter
stops on acp_exit — :DOWN fires, death recorded, generation bumps, next
turn boots a replacement and re-adopts. Regression test kills via the
message; driver A3 is the standing OS-level guard. Also in the soak lane
review: argv "--" handling and httpc→curl (this Erlang build's inets
cannot load :http_util).

GITHUB AUTH SPEC (operator-authored). Confirmed no existing tracker item
specifically covered fresh Tightbeam projects losing GitHub auth and pushing
agents toward PAT prompts. Local shell has `gh` keyring auth, but the launch
path only explicitly projects harness homes plus Tightbeam env; satellite and
service-user projects therefore need a first-class host capability. Added
`docs/GITHUB-AUTH.md`: `tightbeam onboard github` defaults to GitHub CLI
browser/device OAuth, readiness proves both `gh` API auth and `git ls-remote`,
PAT is never an agent fallback, and gateway/satellite hosts prove independently.
Linked it from onboarding docs.
