---
name: tightbeam-harnesses
description: Per-harness feature support matrix — what works on Claude, Codex, and Cursor, and by what mechanism. Consult before promising or relying on a harness-specific feature.
---

Consult this matrix before promising a harness feature. Treat every Cursor parity
claim as contract-level proof unless the row says otherwise. No live Cursor turn
or feature-smoke leg has run yet.

The full proof table lives in `harness-support.md`.

- CAP-001 sessions/turns/cancel/load: PARITY through ACP.
- CAP-002 model+effort: Codex PARITY; Claude
  `DIV-MODEL-CLAUDE-ENVIRONMENT`; Cursor preserves the fields but its production
  catalog fails loud as `DIV-CATALOG-CURSOR-SOURCE-UNWIRED`. Injected catalog
  vectors do not prove a live offered model.
- CAP-003 slash commands: PARITY ACP passthrough. Do not promise a Cursor vendor
  command; its vocabulary is not enumerated.
- CAP-004 projected identity: PARITY through harness instruction metadata.
- CAP-005 native skills: PARITY under `.claude/skills`, `.codex/skills`, or
  `.cursor/skills`; Tightbeam owns `tightbeam__*` only.
- CAP-006 vendor-native skills/commands: PARITY additive preservation; Cursor
  reconciliation sentinels prove leaves outside its owned set survive.
- CAP-007 gate statutes: Claude and Codex PARITY. Cursor compiles faithful
  before hooks, but negatively refuses MCP and every matcher with no enforcing
  before-event as `DIV-RAILS-CURSOR-UNMAPPABLE-BEFORE-HOOK`.
- CAP-008 future block/check tiers: reserved divergence on every harness.
- CAP-009 credential lifecycle: Claude and Codex include stopped-runtime
  harvest. Cursor has API-key readiness/rotation parity and harvests nothing.
- CAP-010 token environment: PARITY mechanisms; Cursor injects only
  `CURSOR_API_KEY`. No subscription-longevity equivalence is claimed.
- CAP-011 onboarding: Cursor is API-key-only `DIV-CURSOR-API-KEY-ONLY`.
  Subscription vectors are explicitly unsupported, fail closed, and inject no key.
- CAP-012 progress: PARITY ACP contract; no live Cursor run is claimed.
- CAP-013 usage telemetry: PARITY ACP contract; no live Cursor run is claimed.
- CAP-014 compaction: Claude `DIV-COMPACTION-CLAUDE-ABSENT`; Codex
  `DIV-COMPACTION-CODEX-UNPROJECTED`; Cursor
  `DIV-COMPACTION-CURSOR-UNPROJECTED`.
- CAP-015 hash-gated homes: PARITY; Cursor owns only `cli-config.json` and
  compiled `hooks.json`.
- CAP-016 harness switching: PARITY with the generic history barrier.
- CAP-017 auth-event classification: Claude `DIV-AUTH-CLAUDE-UNKNOWN`; Codex
  classifies account updates; Cursor is negative-tested as always unknown under
  `DIV-AUTH-CURSOR-UNSUPPORTED`.
- CAP-018 credential liveness: Claude and Codex use bounded authenticated probes.
  Cursor has no captured live/dead fixture pair and returns unknown under
  `DIV-CREDENTIAL-LIVE-CURSOR-NO-FIXTURES`; unknown is INCOMPLETE.

Cursor subagent start/stop envelopes are negative-tested as
`DIV-SUBAGENT-CURSOR-UNSUPPORTED`; Tightbeam skips them and must not predicate
obligations on them.

If reality disagrees, flag the operator and amend the proof table, its negative
test, and this mirror together.
