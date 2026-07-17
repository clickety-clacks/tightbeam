# Patterns — Elixir port (binding conventions)

Read the spec (tightbeam.md — Tenets first) and the port spec
(tightbeam-elixir-port.md) before writing code. The TS repo
(~/src/tightbeam) is the behavioral reference; its tests and E2E scripts are
the oracle.

- Invariants live in SQL, not in callers: ordering (seq), one-turn-per-
  session, CAS terminals, wake dedupe are Ledger properties. Callers cannot
  break them by racing.
- Single writer: ALL writes via Tightbeam.DB.transaction/1. Never open a
  second write connection.
- Monitors, never links, across component boundaries (lane↔task↔adapter).
  No blocking GenServer.call in the turn path; use noreply+from or async
  request/receive protocols.
- Every crash-recovery path is terminal-and-visible: failed_unknown, never
  auto-retry, always publishable (unpublished_terminals feed).
- Tests: ExUnit per module, :memory: DB via start_supervised! with unique
  names; assert BOTH behavior and ledger side effects. Error paths raise
  Tightbeam.DB.Error (exqlite returns error tuples — DB layer converts).
- mix test must pass before every commit. No new deps without a journal note.
