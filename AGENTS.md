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
- **codex hooks run under `codex app-server` (the adapter path), TRUST-GATED** — not
  inert (that earlier conclusion was a 0.144.x bundled-binary + untrusted-state
  artifact, refuted 2026-07-23). A hook handler arms only if trusted or
  `bypass_hook_trust` is set; that key is a thread/start REQUEST override only (not
  config.toml, not a CLI flag). tightbeam delivers it via `CODEX_CONFIG={"bypass_hook_trust":true}`
  on the adapter spawn, which codex-acp spreads into every thread/start config map.
  Verified at rust-v0.145.0: PreToolUse fires for shell + unified_exec (tool "Bash",
  full command text) and deny actually blocks. Two prerequisites: CODEX_PATH must pin
  the binary (codex-acp otherwise runs a stale bundled 0.144.5), and the boot
  wiring-check prompt must ask the probe model to echo the refusal verbatim (codex
  surfaces a block as a tool result, not agent text). See specs permission-seam-spike.md.

## Tests — a green run is not the goal, a correct one is

**Green tests < correct tests.** A suite that passes because its assertions were removed is
worse than a red one: it reports safety it does not have, and it hides the regression from
everyone downstream.

- **Never delete a test to make a run pass.** Not the file, not the case, not the assertion.
- **Never stub a test out** — no `assert true`, no emptied body, no permanent skip/tag, no
  assertion weakened until it stops failing. A test that asserts nothing is a lie.
- **Reconcile instead.** When a test fails, first decide which side is wrong. If the code is
  wrong, fix the code. If the test encodes behavior the spec has since changed, rewrite it to
  assert the NEW correct behavior — the test keeps its subject and its teeth.
- **Deletion is a proposal, not an action.** If you believe a test or a feature genuinely
  should go — its subject is gone, it duplicates another, the spec retired it — say so as a
  finding in your report and leave the code in place. Someone reviews that call. This applies
  to features and modules as much as to tests: removing something that merely conflicts with
  the new shape is how invariants get silently gutted while the suite stays green.
- **Make sure the test is real.** It must be able to fail: it exercises the actual subject, it
  asserts a specific observable outcome, and breaking the code it covers turns it red. If you
  cannot state what regression it would catch, it is not a test yet.
