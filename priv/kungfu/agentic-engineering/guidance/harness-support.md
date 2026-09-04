# Harness support

Cursor is gateway-local only. Do not promise remote placement or parity with
Claude or Codex. Its column states only a local contract or a named divergence.

| Capability | claude | codex | cursor | Mechanism / proof boundary |
|---|---|---|---|---|
| CAP-001 sessions/turns/cancel/load | parity | parity | local ACP contract | Shared ACP session seam. |
| CAP-002 model + effort | `DIV-MODEL-CLAUDE-ENVIRONMENT` | parity | local authenticated inventory; no separate effort | Cursor advertises only the intersection of its authenticated inventory and ACP-selectable refs. |
| CAP-003 slash commands | parity | parity | ACP passthrough only | Cursor vendor vocabulary is not enumerated or promised. |
| CAP-004 projected identity | parity | parity | local instruction projection | Cursor instruction metadata is pinned by its session-config vector. |
| CAP-005 native skills | parity | parity | local `.cursor/skills` projection | Cursor materializes the reserved namespace under `.cursor/skills`. |
| CAP-006 vendor-native skills/commands | parity | parity | local additive preservation | Cursor reconciliation sentinel vectors prove additive preservation. |
| CAP-007 gate statutes | parity | parity | `DIV-RAILS-CURSOR-UNMAPPABLE-BEFORE-HOOK` | `CursorRails` compiles faithful before hooks and negatively tests refusal of MCP and matchers without an enforcing before-event. |
| CAP-008 future block/check tiers | reserved divergence | reserved divergence | reserved divergence | No allow/ask/rewrite support is claimed. |
| CAP-009 credential lifecycle | parity | parity | local API-key readiness; no harvest | Readiness/rotation vectors use `auth/cursor/api-key`; harvest is pinned to `nil`. |
| CAP-010 token environment | parity | parity | local API-key injection | Cursor injects only `CURSOR_API_KEY`; no subscription longevity is claimed. |
| CAP-011 onboarding | parity | parity | `DIV-CURSOR-API-KEY-ONLY` | CLI requires `--api-key`; four subscription launch vectors are unsupported and inject no key. |
| CAP-012 progress | parity | parity | local ACP contract | Shared ACP seam; no live Cursor run is claimed. |
| CAP-013 usage telemetry | parity | parity | local ACP contract | Shared ACP seam; no live Cursor run is claimed. |
| CAP-014 compaction | `DIV-COMPACTION-CLAUDE-ABSENT` | `DIV-COMPACTION-CODEX-UNPROJECTED` | `DIV-COMPACTION-CURSOR-UNPROJECTED` | Cursor exposes no projected compaction event. |
| CAP-015 hash-gated homes | parity | parity | local home projection | Cursor owns only `cli-config.json` and compiled `hooks.json`; write-set vectors prove preservation. |
| CAP-016 harness switching | parity | parity | local history barrier | Generic history barrier applies to every registry harness. |
| CAP-017 auth-event classification | `DIV-AUTH-CLAUDE-UNKNOWN` | parity | `DIV-AUTH-CURSOR-UNSUPPORTED` | Cursor positive and negative envelopes are negative-tested as exact `:unknown`. |
| CAP-018 credential liveness | parity | parity | `DIV-CREDENTIAL-LIVE-CURSOR-NO-FIXTURES` | Cursor returns `{:unknown, :no_captured_cursor_liveness_fixtures}`; unknown is INCOMPLETE. |
| Parent-attributed subagent markers | parity | parity | `DIV-SUBAGENT-CURSOR-UNSUPPORTED` | Cursor start/stop envelopes are negative-tested as `:skip`; never predicate obligations on them. |

All Cursor support above is local-only. No live Cursor turn or feature-smoke leg
has run yet.
