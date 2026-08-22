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
