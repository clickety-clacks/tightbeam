# Handoff — cold-start guide for a contributing agent

Read in this order:
1. `~/src/shared-workspace/shared/specs/tightbeam.md` — THE spec. Tenets
   first; hold every change against the eight-question test.
2. `~/src/shared-workspace/shared/specs/tightbeam-elixir-port.md` — the port
   plan: invariants, turn pipeline, supervision design, acceptance wall.
3. `docs/ARCHITECTURE.md` (this repo) — module map + supervision tree.
4. `docs/PATTERNS.md` — binding conventions, including documentation rules.
5. `docs/JOURNAL.md` — LAST entry = current state + next step.

Reference implementation: the TypeScript gateway at `~/src/tightbeam`
(read-only; its tests and scripts/blackbox drivers are the behavioral
oracle). Exemplar Elixir module for style/specs/docs: `lib/tightbeam/ledger.ex`.

Rules: `mix test` green before every commit; commit to main, never branch or
push; append to JOURNAL.md before ending a session; new deps need a journal
justification; cross-provider review per the SOP.
