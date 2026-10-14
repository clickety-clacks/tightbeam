# tightbeam_ex — agent notes

## THIS LINE: highest 0.1.* branch (currently 0.1.9) — see CONTRIBUTING.md on main

The branch and release ruling for both product lines is in
[CONTRIBUTING.md on main](https://github.com/clickety-clacks/tightbeam/blob/main/CONTRIBUTING.md).
Integrate maintenance work into the highest `0.1.*` branch (currently `0.1.9`),
not main. main is now the 0.2 fabric program line — never target it from this
line; fixes cross to it only by Mike-authorized cherry-pick election. Where
older guidance, specs, or cards name another default integration branch, read
"highest `0.1.*` branch" on this line. If a card names a branch explicitly, the
card wins.

## Keep the substrate neutral

The substrate (`priv/seed`, `priv/guidance`, `priv/skills`, and Main's default
archetype) stays neutral. Put ways of working — such as PO/PDO roles, delivery
and review process, and how to build a product org — in the applicable kungfu
bundle, never in substrate guidance.

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
  artifact, refuted 2026-07-23). The same core engine serves every frontend. A
  hook handler arms only if trusted or `bypass_hook_trust` is set; that key is a
  thread/start REQUEST override only, not config.toml or an app-server CLI flag.
  tightbeam delivers it via `CODEX_CONFIG={"bypass_hook_trust":true}`
  on the adapter spawn, which codex-acp spreads into every thread/start config map.
  Verified at rust-v0.145.0: PreToolUse fires for shell + unified_exec (tool "Bash",
  full command text) and deny actually blocks. Two prerequisites: CODEX_PATH must pin
  the binary (codex-acp otherwise runs a stale bundled 0.144.5), and the boot
  wiring-check prompt must ask the probe model to echo the refusal verbatim (codex
  surfaces a block as a tool result, not agent text). See specs permission-seam-spike.md.

## Change only what the task requires

A change to EXISTING OBSERVABLE BEHAVIOR needs named, LIVE authority: a clause in a
current (non-archived) spec, an explicit directive, or a confirmed bug. Verify the
clause's currency — a clause's existence is not its authority (a retired spec's ghost
clause once silently killed session-implied CLI identity). Conformance sweeps,
port-fidelity mandates, refactors, and tidiness NEVER authorize behavior changes: when
a clause you're implementing demands one, STOP and report it as a finding for
adjudication. Parity refactors owe byte-parity except changes the spec names as
intentional.

## Verification

- The Evidence section of
  `priv/kungfu/agentic-engineering/guidance/engineering-core.md` decides which
  tests to add or require. Established tests and gates, including CI
  configuration, stay; take one you believe is wrong to its owner through the
  authorized source path. Adding a gate, check or process step needs the user's
  approval through a decision request.
- Repository commands. Run those whose checks that rule keeps:
  - Elixir: `mix format --check-formatted` and `scripts/verify_mix.sh`.
  - Rust, from `cli/`: `cargo fmt --check` and `cargo test`.
- The canonical gate handles environment hygiene. For ad-hoc Mix runs outside the
  script, such as `mix test path/to/file.exs`, use `env -u NAME` to remove every
  inherited `TIGHTBEAM_*` and `RELEASE_*` variable.
  After `wi_8f90c5b3` merges, the suite is immune to the
  known `TIGHTBEAM_*` config leaks. Keep stripping both prefixes: that proof covers
  only config, while `RELEASE_ROOT` is read directly from the environment in `lib/`.
- Make the requested change first, then run the focused checks that exercise it.
  Do not run a full-suite baseline before writing code; an untouched-tree replay
  delays the change without proving its result.
- For a change to shipped documentation, use `sh packaging/assemble.sh` when
  package inclusion or assembly is the behavior under examination; documentation
  alone does not require a build or full suite.

## Tests — a green run is not the goal, a correct one is

**Green tests < correct tests.** A suite that passes because its assertions were removed is
worse than a red one: it reports safety it does not have, and it hides the regression from
everyone downstream.

- Preserve tests of required behavior; removing or weakening their assertions to
  hide a defect is not a passing result. Remove a test or gate only through its
  owner. Removing a feature or module
  still needs authority for that behavior change.
- **Never stub a test out** — no `assert true`, no emptied body, no permanent skip/tag, no
  assertion weakened until it stops failing. A test that asserts nothing is a lie.
- **Reconcile instead.** When a test fails, first decide which side is wrong. If the code is
  wrong, fix the code. If the test encodes behavior the spec has since changed, rewrite it to
  assert the NEW correct behavior — the test keeps its subject and its teeth.
- **Make sure the test is real.** It must be able to fail: it exercises the actual subject, it
  asserts a specific observable outcome, and breaking the code it covers turns it red. If you
  cannot state what regression it would catch, it is not a test yet.
- **A mock that diverges from the real harness tests fake shit.** (Flynn, 2026-07-26, after
  merge ff4b64b passed 730 mocked tests and then killed every LIVE claude turn — reverted.)
  Mocks are valid ONLY for properties that live entirely on OUR side of the ACP seam
  (durability, ordering, races, SQL — stage pathologies freely). Any test whose property
  depends on what the OTHER side actually does is circular through a mock: it verifies our
  handling of a reply we authored. Every boundary assumption a mock encodes (which methods
  exist, what replies carry, which config options a harness declares) must be backed by
  recorded real responses or applicable live evidence. Choose the `feature_smoke` cases
  that exercise the affected adapter behavior; touching the adapter seam alone does not
  require the full matrix.

## Report dirt, never accommodate it

Code that meets unexpected state — a database in an unknown shape, a missing table, a
file an older version wrote — must REFUSE LOUDLY and name what it found, never guess
and repair. Probing live state to deduce its shape (try-and-catch-duplicate ALTERs,
sniffing stored DDL, existence guards) is the tell; ~2,000 lines of exactly that were
deleted 2026-08-01. If a shape must be known, stamp it at write time; a missing or
unknown stamp is a refusal and a bug report, never an inference.
