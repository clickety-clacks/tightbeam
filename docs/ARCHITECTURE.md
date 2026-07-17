# Architecture (Elixir gateway)

The tenets in the spec decide all arguments; this file only maps the code.

## Supervision tree (rest_for_one — DB first, dependents restart with it)

    Tightbeam.Supervisor (3 restarts / 30s)
    ├── Tightbeam.DB              single-writer SQLite owner; THE txn seam
    ├── Tightbeam.Boot            one-shot: schemas, boot epoch, recovery
    ├── Tightbeam.LaneRegistry    unique lane names (Elixir Registry)
    ├── Tightbeam.TurnTaskSupervisor  Task.Supervisor for turn work
    ├── Tightbeam.LaneSupervisor  DynamicSupervisor (50/10s) of SessionLanes
    └── (wire: Bandit + ConnRegistry + WakeScheduler + AdapterCoordinator
         join here as E2 completes; LaneManager is started by the composition
         root once a runner exists)

## Modules

    db.ex            single writer, pinned PRAGMAs, transaction/1, typed errors
    ledger.ex        THE turns ledger — ordering/one-per-session/CAS terminals/
                     wake dedupe/conservation, all enforced in SQL  ← EXEMPLAR
    event_log.ex     verb events, lifecycle events, boot epochs (dirty-exit
                     inference at next boot; clean stamp in prep_stop)
    projection.ex    messages projection (one-way cache); dedupe tri-state
    org.ex           session registry: wire identity + provenance + pointer
                     chains (owner-only for wire callers)
    conn_registry.ex socket registry: generation takeover, lifetime seq filter,
                     owner-scoped fan-out (publish in commit order!)
    session_lane.ex  per-session turn runner; Ledger is the queue; monitors,
                     never links; quarantine on failed_unknown
    lane_manager.ex  the Reconciler: boot+periodic scan IS the liveness
                     guarantee; doorbells are optimization
    acp/conn.ex      adapter Port owner; ndjson; async request protocol;
                     orphan quiescence signal
    acp/adapter.ex   harness session layer; fable-trap model rule
    application.ex   the tree; boot.ex the one-shot; id.ex shared ids

## The turn pipeline (the one flow to understand)

    post/wake → ONE transaction: Projection message + Ledger turn (seq =
    execution order) → LaneManager.ensure_lane/nudge → SessionLane claims
    (one-per-session in SQL) → TurnTask → Acp.Adapter.prompt → persist reply →
    ConnRegistry.publish (commit order) → Ledger CAS terminal → publishedAt.
    Crash anywhere: Reconciler recovers; running turns become failed_unknown,
    never auto-retried. Every accepted prompt reaches exactly one terminal
    state (the conservation law).
