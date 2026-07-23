# tightbeam_ex — agent notes

## ACP / harness facts (for anyone touching the adapter layer)

- **Zed is the ACP reference implementation.** For ANY protocol capability/semantics
  question (session lifecycle, methods, update shapes): read
  github.com/zed-industries/agent-client-protocol and the zed source BEFORE concluding
  a capability exists or is missing. Two stale conclusions were already overturned by
  it (per-session unload EXISTS as session/close; hook semantics).
- **Harness CLIs auto-update under us** (codex 0.144.5→0.144.6→0.145.0 in two days).
  Pin binaries explicitly (CODEX_PATH); re-probe behavior per version; never trust
  yesterday's diagnosis against today's binary.
- **codex hooks are TRUST-GATED, not inert, under `codex app-server`** (established
  2026-07-23, reversing the earlier "exec-only" conclusion — that was a bundled-binary
  + untrusted-state artifact at 0.144.x). Hooks run through the same core engine in
  every frontend; a handler arms only if trusted or `bypass_hook_trust` is set, and
  that key is a thread/start REQUEST override only (not config.toml, not a CLI flag on
  the app-server subcommand). Delivery: the `CODEX_CONFIG` env JSON on codex-acp is
  spread into every thread/start config map. PreToolUse fires for shell/unified_exec
  (tool name "Bash", full command text) and deny actually blocks — verified at
  rust-v0.145.0. See shared specs permission-seam-spike.md.
