---
name: tightbeam-harnesses
description: Per-harness feature support matrix (claude vs codex) — what works where and by what mechanism. Consult before promising or relying on a harness-specific feature.
---

Per-harness feature support: FACTS, not guesses. Consult this before
promising any feature on a specific harness; a feature not listed here
diverges nowhere. Never say "probably" about a row below.

claude (via claude-agent-acp):
- Skills: NATIVE — discovered from the session cwd's `.claude/skills/`, invoked via
  the Skill tool.
- Rails gates: ENFORCED — PreToolUse hooks refuse matching tool calls
  before execution; a refusal quoting "[gate: <name>]" is the runtime
  acting, not the model declining.
- Credentials: REQUIRED long-lived setup-token grant injected through
  `CLAUDE_CODE_OAUTH_TOKEN`; rotating `.credentials.json` is not used.
- Slash commands: /clear /compact /model verified as passthrough.
- Emits per-turn context-usage telemetry.
- Subagent starts and true task settlement are observable as parent-attributed
  markers; wake-on-stop resolves the parent's Agent/Task tool-call id.

codex (via codex-acp):
- Skills: discovered from the session cwd's `.codex/skills/` under the
  reserved `tightbeam__*` namespace.
- Rails gates: ENFORCED through Codex PreToolUse hooks after the adapter's
  boot wiring-check passes.
- Credentials: one shared `auth.json`; the one shared Codex runtime is its
  sole refresher/writer while live.
- Slash-command vocabulary differs from claude and is unverified — do
  not promise specific commands.
- Verified working: turns, tool use, developer-instruction identity,
  per-session skills, gpt-5.6-sol model selection. Headless login
  exists: codex login --device-auth.
- Subagent starts and child-thread settlement are observable as
  parent-attributed markers; wake-on-stop resolves the parent's spawn
  tool-call id.

Both: sessions/turns/cancel/load, model+effort selection, served instruction
identity, generic shared homes with surviving session state, and harness
switching with the history barrier. Neither:
structured compaction events — compaction is invisible to the substrate
today. The full matrix with mechanisms lives in the spec repo
(harness-support.md); if reality disagrees with this skill, say so and
flag the operator — this file is maintained law, not folklore.
