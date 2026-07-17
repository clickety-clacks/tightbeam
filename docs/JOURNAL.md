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
