---
name: tightbeam-harnesses
description: Per-harness capability support matrix — what works on Claude, Codex, and Cursor, and by what mechanism. Consult before promising or relying on a harness-specific capability.
---

Per-harness capability support: FACTS, not guesses. Consult this before
promising any capability on a specific harness; a capability not listed here
diverges nowhere. Never say "probably" about a row below.

Cursor is gateway-local only. Do not promise remote placement or parity with
Claude or Codex. The Cursor rows below state only a local contract or a named
divergence. No live Cursor turn or recorded smoke leg has run yet.

The full proof table lives in `harness-support.md`.

- CAP-001 sessions/turns/cancel/load: Claude and Codex PARITY; Cursor has a local
  ACP contract.
- CAP-002 model+effort: Codex PARITY; Claude
  `DIV-MODEL-CLAUDE-ENVIRONMENT` because its offered set can depend on cwd and
  settings. A refusal must preserve a loaded session. Cursor's local
  authenticated inventory is intersected with its ACP-selectable refs. Cursor
  exposes no separate effort.
- CAP-003 slash commands: PARITY passthrough for Claude and Codex. Claude
  `/clear /compact /model` are verified. Codex vocabulary includes `/status
  /mcp /skills /review /compact /logout /new /clear`, plus configured skills
  and domain commands. Cursor has local ACP passthrough, but its vendor
  vocabulary is not enumerated or promised.
- CAP-004 projected identity: keep Claude system-prompt append metadata and
  Codex developer-instruction metadata. Apply changed Claude guidance at the
  next cold load; do not claim guidance-only warm refresh. Retain the dr4409
  Codex new/resume/load transport anchors until an equivalent channel is
  accepted. Keep session guidance separate from skill materialization and
  shared homes. A malformed, missing, or wrong-session identity must fail
  closed; do not use hook source inspection as proof of authenticated
  first-request delivery. Cursor has local harness instruction metadata.
- CAP-005 native skills: Claude and Codex use progressive disclosure under
  `.claude/skills` / `.codex/skills`. Cursor materializes local skills under
  `.cursor/skills`; Tightbeam owns `tightbeam__*` only.
- CAP-006 vendor-native skills/commands: preserved additively. Cursor local
  reconciliation sentinels prove leaves outside its owned set survive.
- CAP-007 gate statutes: Claude uses PreToolUse settings and Codex uses
  PreToolUse hooks after the fail-closed boot wiring-check. Cursor compiles faithful
  before hooks, but negatively refuses MCP and every matcher with no enforcing
  before-event as `DIV-RAILS-CURSOR-UNMAPPABLE-BEFORE-HOOK`.
- CAP-008 future block/check tiers: reserved named divergence on every harness;
  do not claim allow/ask/rewrite support.
- CAP-009 harness-home credential ownership: use one regular credential file
  per exact machine/harness home for Claude and Codex. Reconciliation must not
  copy, link, or harvest it. Preserve the non-rotating Claude setup-token
  contract and the single Codex refresher; do not claim rotation or
  provider-longevity parity. Cursor instead has a local owner-only API-key bank,
  projects only non-secret preferences, and harvests nothing.
- CAP-010 token environment: Claude and Codex retain their current mechanisms.
  Cursor locally injects only `CURSOR_API_KEY`. No subscription-longevity
  equivalence is claimed.
- CAP-011 onboarding: Cursor is API-key-only `DIV-CURSOR-API-KEY-ONLY`.
  Subscription vectors are explicitly unsupported, fail closed, and inject no key.
- CAP-012 progress: Claude and Codex provide rich ACP updates. Cursor has a local
  ACP contract; no live Cursor run is claimed.
- CAP-013 usage telemetry: Claude and Codex emit usage. Cursor has a local
  ACP contract; no live Cursor run is claimed.
- CAP-014 compaction: Claude `DIV-COMPACTION-CLAUDE-ABSENT`; Codex
  `DIV-COMPACTION-CODEX-UNPROJECTED`; Cursor
  `DIV-COMPACTION-CURSOR-UNPROJECTED`.
- CAP-015 hash-gated homes: Claude and Codex preserve their owned entries. Cursor has a
  local contract and owns only `cli-config.json` and compiled `hooks.json`.
- CAP-016 harness switching: Claude and Codex retain the history barrier;
  the generic history barrier applies to Cursor locally.
- CAP-017 auth-event classification: Claude `DIV-AUTH-CLAUDE-UNKNOWN`; Codex
  classifies account updates; Cursor is negative-tested as always unknown under
  `DIV-AUTH-CURSOR-UNSUPPORTED`.
- CAP-018 credential liveness: Claude and Codex use bounded authenticated probes.
  Claude calls `GET /v1/models?limit=1`; Codex calls
  `GET /backend-api/wham/accounts/check`. `:live` passes, `:dead` fails, and
  `:unknown` is always INCOMPLETE.
  Cursor has no captured live/dead fixture pair and returns unknown under
  `DIV-CREDENTIAL-LIVE-CURSOR-NO-FIXTURES`; unknown is INCOMPLETE.

Cursor subagent start/stop envelopes are negative-tested as
`DIV-SUBAGENT-CURSOR-UNSUPPORTED`; Tightbeam skips them and must not predicate
obligations on them.

If reality disagrees, flag the operator and amend the proof table, its negative
test, and this mirror together.
