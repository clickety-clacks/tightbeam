# tightbeam_ex — agent notes

## THIS LINE: main = the 0.2 fabric program (flipped 2026-08-12)

The pre-flip tip lives on branch 0.1.x — the maintenance line the live org
patches. THE GIT PROCESS ON THIS LINE (intent restated by Mike, 2026-08-22 —
decisions ledger): NO DOOR means NO PR CEREMONY — nothing else. It
assumes your branch is READY TO MERGE and the tests PASS. Work on your
own branch in your own workspace; when the full verification gate is
GREEN on your branch, merge to main — no PR, no review theater, just a
clean merge of finished work. Main is never worked in directly, and a
red suite is never merged; "pre-existing failure" is not a pass, it is a
stop — fix it or surface it to the owner before anything merges. And the mirror rule at the START of work (Mike, 2026-08-22): branch
only FROM a green main — never start work on a red base, where your own
breakage and inherited breakage are indistinguishable; if main is red,
fixing it comes first. Review
evidence lands in the specs repo first. If your assignment card names a different integration branch,
the card wins. If you are a 0.1.x-org agent reading this: your line is
0.1.x and this checkout is the wrong one — do not push here. Fixes cross
0.1.x -> main by cherry-pick election only, Mike-authorized.

## THE PHILOSOPHY GATE — run it before you design, again before you ship

Tightbeam is agent-first: agents run the org; the substrate records truth,
prods, and executes named org-authored law — it NEVER judges and NEVER seizes
(adjudication deletion ruling, 2026-08-05, shared specs tightbeam-decisions.md).
Every spec and every change answers these ten. A "no" is a FINDING to report,
not a style nit — the "hey, that's not what we're about" moment is this list
doing its job. Layer vocabulary: PHYSICS = substrate mechanism (invariant,
judgment-free); ANATOMY = neutral seed (shipped shape, org-reshapeable);
CULTURE = kungfu (domain). See shared specs coordination-fabric-v1.md.

1. **Who judges?** If the substrate is making a judgment call, move it to an
   agent or delete it. The substrate owes truth, a named failure, and a record
   — nothing else.
2. **Can an agent say no?** Every mechanism is a default with a nameable
   inhibition seam. If you cannot name where an agent overrides it, you built
   a cage.
3. **What's the exit?** No state whose exit condition is someone else's
   decision — every wait ends on time, a turn boundary, or the waiter's own
   choice. And every state has a lawful AGENT-reachable repair verb: if repair
   requires an admin at a database console, the design is incomplete
   (completion-selection wedge, wi_1b0237fe, 2026-08-12).
4. **Does failure correlate?** A wrong deterministic rule wrongs every case
   identically and silently — correlated failure is what brittleness IS. Keep
   rules small and boring, and put a mind above them.
5. **Interruption or information?** Shape WHEN attention is spent, never WHAT
   is recorded. An optimization that loses rows is wrong, full stop.
6. **Which layer?** Mentions the domain → culture. An org could sanely
   reshape it → not physics. Judgment content → never physics.
7. **Decimation test.** Kill any one session, or the gateway, mid-flight: does
   the org degrade to a topology that already works?
8. **Is the discipline a bone yet?** Anything agents must remember to do every
   time is a deterministic reflex waiting to be extracted. Inverse holds:
   anything requiring judgment every time must never be extracted.
9. **Does a status question reach a mind?** A question answerable from rows is
   answered by rows.
10. **Can you say it as a maxim?** If the mechanism's purpose will not
    compress to one load-bearing sentence consistent with the nine above, be
    suspicious of the mechanism.

## WHERE THE SPECS LIVE (read before designing anything)

The spec commons is its own repo: github.com/clickety-clacks/tightbeam-specs
(gibson clone ~/src/tightbeam-specs; canonical checkout on the NFS at
eezo:~/shared-workspace/shared/specs/tightbeam). For 0.2 work start with:
- `v0.2-program-2026-08-12.md` — the program: rulings, staffing, phases,
  election ledgers, org-pause state. The record of every decision.
- `coordination-fabric-v1.md` — the design authority for the fabric.
- `0.2-build-ledger.md` — one entry per landing on main; review evidence
  goes there BEFORE the push.
- `0.2-orchestrator-handoff.md` — full context transfer incl. environment
  map and working norms. Read it before doing ANY 0.2 program work.
- `tightbeam.md` — the spec hub for the wider corpus; `tightbeam-decisions.md`
  — the decisions ledger.
The 0.2 orchestrator runs in tmux session `tb02` on gibson
(`tmux attach -t tb02`) — coordinate 0.2 work through it, don't duplicate it.

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

- `.github/workflows/ci.yml` defines the verification gate. When it and this
  section disagree, `ci.yml` is right and this section is a bug.
- Run the halves your change touches; run both when unsure. Run each applicable half
  exactly as CI defines it:
  - Elixir: `mix format --check-formatted && scripts/verify_mix.sh`.
  - Rust, from `cli/`: `cargo fmt --check && cargo test`.
- The canonical gate handles environment hygiene. For ad-hoc Mix runs outside the
  script, such as `mix test path/to/file.exs`, use `env -u NAME` to remove every
  inherited `TIGHTBEAM_*` and `RELEASE_*` variable.
  After `wi_8f90c5b3` merges, the suite is immune to the
  known `TIGHTBEAM_*` config leaks. Keep stripping both prefixes: that proof covers
  only config, while `RELEASE_ROOT` is read directly from the environment in `lib/`.
- First run the applicable gates on an unmodified tree in a clean environment and
  record the counts on the card. Repeat after the change and record those counts too.
  Accept only a green gate with both records; `tests pass` without a baseline is a
  claim a reviewer cannot check.
- A docs-only change (`*.md`) skips these gates. Run `sh packaging/assemble.sh`
  instead; it must succeed.

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
- **A mock that diverges from the real harness tests fake shit.** (Flynn, 2026-07-26, after
  merge ff4b64b passed 730 mocked tests and then killed every LIVE claude turn — reverted.)
  Mocks are valid ONLY for properties that live entirely on OUR side of the ACP seam
  (durability, ordering, races, SQL — stage pathologies freely). Any test whose property
  depends on what the OTHER side actually does is circular through a mock: it verifies our
  handling of a reply we authored. Every boundary assumption a mock encodes (which methods
  exist, what replies carry, which config options a harness declares) must be backed by
  recorded real responses (re-capture fixtures) or a live gate. Any lane that touches the
  adapter seam runs the LIVE feature_smoke matrix (both harnesses, fresh org) as part of its
  own gates — before merge, not after.

## Report dirt, never accommodate it

Code that meets unexpected state — a database in an unknown shape, a missing table, a
file an older version wrote — must REFUSE LOUDLY and name what it found, never guess
and repair. Probing live state to deduce its shape (try-and-catch-duplicate ALTERs,
sniffing stored DDL, existence guards) is the tell; ~2,000 lines of exactly that were
deleted 2026-08-01. If a shape must be known, stamp it at write time; a missing or
unknown stamp is a refusal and a bug report, never an inference.
