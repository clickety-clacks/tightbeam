---
name: tightbeam-harnesses
description: Per-harness feature support matrix (claude vs codex) — what works where and by what mechanism. Consult before promising or relying on a harness-specific feature.
---

Per-harness feature support: FACTS, not guesses. Consult this before
promising any feature on a specific harness; a feature not listed here
diverges nowhere. Never say "probably" about a row below.

Canonical capability IDs (the full proof references live in
`harness-support.md`):

- CAP-001 sessions/turns/cancel/load: PARITY.
- CAP-002 model+effort: Codex PARITY; Claude
  `DIV-MODEL-CLAUDE-ENVIRONMENT` because its offered set can depend on cwd and
  settings. A refusal must preserve a loaded session.
- CAP-003 slash commands: PARITY passthrough. Claude `/clear /compact /model`
  are verified. Codex vocabulary is known:
  `/status /mcp /skills /review /review-branch /review-commit /compact
  /logout /new /clear`, plus configured skills.
- CAP-004 projected identity: PARITY through Claude system-prompt metadata and
  Codex developer-instruction metadata.
- CAP-005 native skills: PARITY progressive disclosure under
  `.claude/skills` / `.codex/skills`; Tightbeam owns `tightbeam__*` only.
- CAP-006 vendor-native skills/commands: PARITY and preserved additively.
- CAP-007 gate statutes: PARITY; Claude PreToolUse settings and Codex
  PreToolUse hooks after the fail-closed boot wiring-check.
- CAP-008 future block/check tiers: reserved named divergence on both; do not
  claim allow/ask/rewrite support.
- CAP-009 harness-home credential lifecycle: PARITY, with no cross-home copy or harvest.
- CAP-010 token environment: PARITY mechanisms; no subscription-longevity
  equivalence is claimed.
- CAP-011 onboarding: PARITY through `tightbeam onboard <provider>`.
- CAP-012 progress: PARITY rich ACP updates.
- CAP-013 usage telemetry: PARITY emission.
- CAP-014 compaction: Claude `DIV-COMPACTION-CLAUDE-ABSENT`; Codex emits a
  structured event but Tightbeam does not project it, so
  `DIV-COMPACTION-CODEX-UNPROJECTED` is an explicit Tightbeam gap.
- CAP-015 hash-gated homes: PARITY preservation.
- CAP-016 harness switching: PARITY with the history barrier.
- CAP-017 auth-event classification: Claude
  `DIV-AUTH-CLAUDE-UNKNOWN` (always `:unknown`); Codex classifies terminal and
  transient account updates.
- CAP-018 credential liveness: PARITY through bounded authenticated calls.
  Claude calls `GET /v1/models?limit=1`; Codex calls
  `GET /backend-api/wham/accounts/check`. `:live` passes, `:dead` fails, and
  `:unknown` is always INCOMPLETE.

No capability may be described as unverified: a missing proof blocks the
claim. If reality disagrees with the canonical matrix, flag the operator and
amend the matrix, its negative test, and this mirror together.
