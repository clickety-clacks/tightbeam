# e2e run — 2026-08-03 @ ca91436 (post model-identity merge)

Operator: Claude (overnight, unattended) · Scope: eezo local tiers + one linux negative.
Trigger: Flynn — "get finished what you can and then run through the e2e. iterate until
clean" — the first full run after `model-identity` merged to main (3441879).

## Verdicts

| tier | verdict | note |
|---|---|---|
| T1 suites | PASS | mix 1241 + 9 doctests, cargo 205, zero failures, eezo AND shrdlu |
| T2a feature smoke | PASS | 26 checks, both legs, full parity |
| T2b client journeys | PASS | RUN VERDICT PASS, claude@eezo + codex@eezo |
| T0 V0 neutral seed | PASS | learn/unlearn round-trips to exactly the seed |
| T0 V3 ambient login | PASS | the open question is answered — see below |
| T4 soak | see final section | 60 min, running at time of writing |
| T3c N3 | PASS | boot refuses by name, binds no port |
| T3a/T3b/N1/N2 | SKIP (named) | shrdlu holds no codex credential; interactive onboarding needs Flynn |

**Run verdict: INCOMPLETE(scope)** — honest partial. T3's placement journeys never ran,
so satellite placement is UNPROVEN against this build. That is a scope gap, not a pass.

## Every tier was broken before it ran

None of T2a, T2b, or T4 could start. Each failed for a different reason, and every
failure blamed something other than its cause. Recorded because the pattern matters more
than the individual fixes: **a wire gate lands, and every client that is not the shipped
CLI goes stale silently, because nothing exercises them until someone runs the tier.**

- `42f7bd5` (2026-07-30) made the wire refuse a caller that will not state its version.
  `feature_smoke`, `soak`, and `SimClient` were never taught to send the header, so all
  three 426'd. T2a and T4 had been unrunnable for four days and nothing said so.
  SimClient hid longest: its websocket journeys passed and only the HTTP verbs (J8 wakes)
  reached the gate, so it read as a wake defect.
- A model and its effort are separate fields now, so passing `TIGHTBEAM_DEFAULT_MODEL`
  without `_EFFORT` is an incomplete selection: `client_e2e` and `soak` both booted
  NOT READY.
- The soak arena was four stale assumptions deep — see the findings.

Harness fixes are `2544f38`, `a8e27e1`, `4d966fd`, `ca91436`. All harness-only; no
product behavior was changed to make a test pass.

## Product findings (none fixed — recorded for Flynn)

1. **`warm_home` has never worked.** `claude.ex` invokes `claude -p ok --model sonnet
   --config-dir <home>`. Claude Code 2.1.220 has no `--config-dir` flag; the mechanism is
   the `CLAUDE_CONFIG_DIR` env var, which `prepare_launch` already uses correctly. The
   call is best-effort, so the failure is swallowed forever. The deadlock warm exists to
   break (cold home → subset catalog → nothing placeable → no session → cache never
   fills) is therefore not broken on a genuinely fresh install. It was masked because
   real turns populate the cache themselves. Affects the remote/ssh branch too — the
   satellite case that motivated `1489c6b`.

2. **Nothing refreshes an expired subscription token.** Only the `authorization_code`
   grant exists; no refresh grant, despite storing `refreshToken` and `expiresAt`. Tokens
   observed at ~8h. After that an idle install reports `catalog degraded 401` and offers
   zero models. Recovery verified by hand: the refresh grant works but **403s without a
   Claude Code User-Agent** — a naive implementation will read as a revoked credential.

3. **Readiness names the wrong cause.** With a tiered model and no effort, it says
   "default model claude-sonnet-5 is not in claude's live catalog". The model IS in the
   catalog; the tier is missing. Verified both directions on one org. This is the exact
   defect the model-identity branch fixed in adjudication (`unroutable/2` names three
   causes distinctly) surviving in a second place because it was not in the reviewed
   diff.

4. **A symlinked auth dir is silently ignored.** No catalog, and no log line of any kind.
   Copy vs symlink, same boot, is the entire difference. Codex with a genuinely missing
   credential says `{:needs_onboarding, :missing}`; claude with an unreadable store says
   nothing, so "store not scanned" is indistinguishable from "no catalog yet", and every
   spawn fails downstream blaming the catalog. Silence is the one behavior that cannot be
   right here — CLAUDE.md's own rule is report dirt, never accommodate it.

All four are the same class: **an absence representable as a success, or as a different
absence.** It is the class the merged branch spent five review rounds chasing, and it is
still the shape of every new defect this run surfaced.

## T0 — the first-run questions

**V0 neutral seed: PASS.** A fresh org's identity tree holds exactly
`archetypes/default.toml` and `guidance/operating-model.md`; first commit is
`seed: neutral-identity`; no rails or rules directories at all. `learn
agentic-engineering` installs 48 files and publishes; `unlearn` returns the tree to
**exactly** the two seed files (diffed). Credentials untouched throughout, confirming
learning never requires re-onboarding.

One stale line in `e2e-tier-map-v1`: V0 claims the default archetype "elects no skills and
includes no guidance". It elects `tightbeam-onboarding` and carries substantial guidance.
That is the *neutral is not ignorant* ruling superseding older tier-map wording — the tier
map should be updated or it will keep reading as a failure to future walkers.

**V3 ambient login: PASS**, and this was the open question: does the product SAY the
credentials are separate, or report "no credential" while `claude` works fine two commands
away? Both ambient stores are present on eezo. The fresh org borrowed neither, and boot
says so unprompted:

> Tightbeam has no credential for anthropic on eezo. It does not use or import your normal
> claude CLI login; Tightbeam keeps its own credential under `<base>/auth`.
> Run on eezo: `tightbeam onboard anthropic --as-user <userId>`

It names the isolation, the path, and the command. A first-run user cannot mistake it for
a bug. The adapter gap reads equally well.

## T3 — what blocks it

`shrdlu` has no codex credential, and the runbook is explicit that the gateway needs its
own onboarding for the leg's harness. Onboarding is interactive device auth. Copying from
eezo is forbidden (SATELLITE.md). So T3a/T3b/N1/N2 are blocked on one human step:

    # on shrdlu
    tightbeam onboard openai --as-user <id>

Preconditions otherwise hold: `clu@eurisko` reachable with codex auth and node v22.22.2,
`clu@eliza` reachable, merged main checked out at `~/src/tb-main-gate`, port 12100 free.

**N3 ran and passed.** Gateway booted from a PATH with no harness CLI: refuses by name,
exits 1, binds no port, leaves no partial daemon.

    Tight Beam cannot start because no registered harness CLI is installed. That is
    expected on a fresh machine. Install `claude` or `codex`, ensure it is on PATH, then
    start Tight Beam again. Run `tightbeam doctor` to check this machine.

Rails honored: hostname verified before every remote operation; both run roots created
under `~/.tightbeam-e2e-<runid>/` with `RUN_MARKER` and removed only after marker
verification; lock taken and released; teardown steps independent; protected OpenClaw
ports recorded before (18789:1, 18792:0, 18800:1) and **identical after**; no `pkill`, no
`sudo`, no unit operations.

## One retraction

I reported that recreating the database leaves harness homes unlinked, with a full causal
story. It was wrong: I had checked `base_dir/harness-homes/`, which is not the home root —
`Homes.home_path/3` is `base_dir/homes/<machine>/<harness>`, and those were correctly
linked all along. I found a plausible-looking directory, confirmed the credential was
absent from it, and built an explanation without checking the code path that names the
directory. Recorded because it is the same reason-instead-of-check failure this codebase
keeps punishing, committed while writing up someone else's instance of it.

## Soak

Started 04:07 local, 60 minutes, arena `~/.tightbeam-soak` against a borrowed eezo claude
credential. Self-check first: session spawn, adapter SIGKILL recovered in 95ms, gateway
SIGTERM 3927ms, gateway SIGKILL 1077ms, cancel_turn ok, `audit verdict=PASS`. Final
verdict appended below when the run lands.
