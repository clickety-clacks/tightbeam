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
