---
name: tightbeam-harnesses
description: Per-harness feature support matrix (claude vs codex) — what works where and by what mechanism. Consult before promising or relying on a harness-specific feature.
---

Per-harness feature support: FACTS, not guesses. Consult this before
promising any feature on a specific harness; a feature not listed here
diverges nowhere. Never say "probably" about a row below.

claude (via claude-agent-acp):
- Skills: NATIVE — discovered from your home's skills/ dir, invoked via
  the Skill tool.
- Rails gates: ENFORCED — PreToolUse hooks refuse matching tool calls
  before execution; a refusal quoting "[gate: <name>]" is the runtime
  acting, not the model declining.
- Credentials: .credentials.json file OR a long-lived setup-token grant
  injected as env (the rotation-proof form).
- Slash commands: /clear /compact /model verified as passthrough.
- Emits per-turn context-usage telemetry.

codex (via codex-acp):
- Skills: NO native discovery — the same skill files exist at the same
  paths in your home; READ them when the operator asks (the Operations
  pointer names the path).
- Rails gates: NOT YET WIRED here. Codex 0.144+ DOES have a hook
  surface (Claude-compatible), but tightbeam does not compile gates for
  it yet — so today, never claim a gate protects a codex session; the
  gap is tightbeam projection work, no longer the vendor.
- Credentials: auth.json via codex login only; no token-env equivalent,
  so the rotation caveat applies to shared logins.
- Slash-command vocabulary differs from claude and is unverified — do
  not promise specific commands.
- Verified working (2026-07-18): turns, tool use, AGENTS.md identity,
  read-on-demand skills, gpt-5.6-sol model selection. Headless login
  exists: codex login --device-auth.

Both: sessions/turns/cancel/load, model+effort selection, projected
identity (CLAUDE.md vs AGENTS.md), hash-gated homes with surviving
session state, harness switching with the history barrier. Neither:
structured compaction events — compaction is invisible to the substrate
today. The full matrix with mechanisms lives in the spec repo
(harness-support.md); if reality disagrees with this skill, say so and
flag the operator — this file is maintained law, not folklore.
