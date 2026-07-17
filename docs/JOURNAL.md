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
