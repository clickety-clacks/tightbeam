# tightbeam_ex — agent notes

## THIS LINE: 0.1.x — the maintenance line (split 2026-08-12 at cd72fe0)

Integrate 0.1.x work HERE, not main. main is now the 0.2 fabric program line
(PR-only, program authorization). Where older guidance, specs, or cards say
"merge to main", read "merge to 0.1.x" on this line. If a card names a
branch explicitly, the card wins.

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

## Report dirt, never accommodate it

Code that meets unexpected state — a database in an unknown shape, a missing table, a
file an older version wrote — must REFUSE LOUDLY and name what it found, never guess
and repair. Probing live state to deduce its shape (try-and-catch-duplicate ALTERs,
sniffing stored DDL, existence guards) is the tell; ~2,000 lines of exactly that were
deleted 2026-08-01. If a shape must be known, stamp it at write time; a missing or
unknown stamp is a refusal and a bug report, never an inference.
