---
name: tightbeam-harnesses
description: Per-harness feature support matrix (Claude, Codex, and Pi) — what works where and by what mechanism. Consult before promising or relying on a harness-specific feature.
---

Per-harness feature support: FACTS, not guesses. Consult this before
promising any feature on a specific harness; a feature not listed here
diverges nowhere. Never say "probably" about a row below.

Canonical capability IDs (the full proof references live in
`harness-support.md`):

- CAP-001 sessions/turns/cancel/load: PARITY.
- CAP-002 model+effort: Codex and Pi PARITY; Pi uses provider/model values and
  `thought_level`. Claude
  `DIV-MODEL-CLAUDE-ENVIRONMENT` because its offered set can depend on cwd and
  settings. A refusal must preserve a loaded session.
- CAP-003 slash commands: PARITY passthrough. Claude `/clear /compact /model`
  are verified. Codex vocabulary is known:
  `/status /mcp /skills /review /review-branch /review-commit /compact
  /logout /new /clear`, plus configured skills. Pi exposes
  `/compact /autocompact /export /session /name /steering /follow-up
  /changelog`, plus its discovered commands and skills.
- CAP-004 projected identity: PARITY through Claude system-prompt metadata,
  Codex developer-instruction metadata, and Pi's Tightbeam-owned global
  `before_agent_start` extension reading the reserved per-cwd identity carrier.
- CAP-005 native skills: PARITY progressive disclosure under
  `.claude/skills` / `.codex/skills` / `.pi/skills`; Tightbeam owns
  `tightbeam__*` only.
- CAP-006 vendor-native skills/commands: PARITY and preserved additively.
- CAP-007 gate statutes: PARITY; Claude PreToolUse settings, Codex PreToolUse
  hooks, and Pi's Tightbeam-owned global `tool_call` extension all run the same
  compiled command hooks before execution and pass the fail-closed boot
  wiring-check.
- CAP-008 future block/check tiers: reserved named divergence on all three; do not
  claim allow/ask/rewrite support.
- CAP-009 credential file lifecycle: PARITY, including stopped-runtime harvest.
- CAP-010 token environment: PARITY mechanisms; no subscription-longevity
  equivalence is claimed.
- CAP-011 onboarding: PARITY through `tightbeam onboard <provider>`.
- CAP-012 progress: PARITY rich ACP updates.
- CAP-013 usage telemetry: Claude and Codex PARITY emission; Pi
  `DIV-USAGE-PI-UNPROJECTED` because pi-acp exposes session stats only through
  `/session`, not Tightbeam's usage event channel.
- CAP-014 compaction: Claude `DIV-COMPACTION-CLAUDE-ABSENT`; Codex emits a
  structured event but Tightbeam does not project it, so
  `DIV-COMPACTION-CODEX-UNPROJECTED` is an explicit Tightbeam gap. Pi supports
  `/compact` and `/autocompact`, but Tightbeam does not project their structured
  lifecycle, so `DIV-COMPACTION-PI-UNPROJECTED` is explicit too.
- CAP-015 hash-gated homes: PARITY preservation.
- CAP-016 harness switching: PARITY with the history barrier.
- CAP-017 auth-event classification: Claude
  `DIV-AUTH-CLAUDE-UNKNOWN` (always `:unknown`); Codex classifies terminal and
  transient account updates; Pi `DIV-PI-ACP-NO-AUTH-EVENT` because pi-acp emits
  no account event.
- CAP-018 credential liveness: PARITY through bounded authenticated calls.
  Claude calls `GET /v1/models?limit=1`; Codex calls
  `GET /backend-api/wham/accounts/check`; Pi makes a minimum-size
  `gpt-5.6-luna` Responses request with the banked OpenCode Go key.
  `:live` passes, `:dead` fails, and `:unknown` is always INCOMPLETE.

Pi also has `DIV-PI-ACP-NO-SUBAGENT-EVENT`: pi-acp does not emit the ACP
subagent start/stop envelopes Tightbeam's lineage recognizer consumes.

No capability may be described as unverified: a missing proof blocks the
claim. If reality disagrees with the canonical matrix, flag the operator and
amend the matrix, its negative test, and this mirror together.
