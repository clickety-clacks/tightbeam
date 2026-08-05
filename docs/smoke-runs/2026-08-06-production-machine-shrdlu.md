# e2e smoke: production-machine-v1 on shrdlu — 2026-08-06

Branch production-machine-v1 at 11e1908. Real application boot
(`Application.ensure_all_started`, operator-shaped env: TIGHTBEAM_BASE_DIR
fresh, TIGHTBEAM_PORT=11473) on shrdlu (gating Linux platform), real lanes,
real adapter coordinator. Cause failure is the natural production one: a
claude session with no onboarded anthropic credential — the exact case
gibson hit in its first week.

Driver: scripts/pm_smoke.exs (asserts raise; a red run cannot pass).

| # | Observation | Result |
|---|---|---|
| 1 | cause turn fails with the onboarding refusal naming the credential | PASS |
| 2 | notice turn enqueued to parent, requestRef `bubble:<cause_seq>`, origin process:tightbeam | PASS |
| 3 | parent's notice fails (same wall) → same cause climbs to the main session | PASS |
| 4 | main's notice fails → `[no agent can act]` wire message in main stream naming the child; `user-alerted` standing for the OWNER | PASS |
| 5 | fresh failure under the alerted owner: no re-climb, still exactly one notice | PASS |
| 6 | seams: ConditionFacts refuses process:tightbeam filing work-blocked (agent_only_kind); verb denies self-assert (not_authorized); verb accepts parent-over-child | PASS |
| 7 | a delivered turn under the owner clears the alert (user-alert-cleared filed, standing? false) | PASS |

Also on shrdlu, same tree: full suite 1292 tests / 0 failures (with the
release CLI built — the suite preflight refused to run without it and was
given it, not worked around). Platforms this cycle: eezo (macOS) 1292/0,
shrdlu (Linux) 1292/0.

Seam note from run 1: through the CONDITION VERB a process:tightbeam origin
dies at the authority check (not_authorized) before reaching ConditionFacts'
agent_only_kind refusal — two doors, both closed, different codes. The smoke
tests each seam at its own door.

## Re-run after review revision (7ecf02a)

Opus 5 code review returned REVISE (3 blocking, 3 medium, 8 nits — all
addressed; see the revision commit). Re-gated on shrdlu: suite 1297/0, smoke
7/7 PASS. This run exercises the revised architecture live: recognition rides
the BubbleSweeper's cast edge and durable cursor — the wiring whose absence
from coverage was blocking finding B1 — not hand-called recognition.

## Post-merge sim on eezo (main at 00b52ef)

Merged to main (review cleared: Fable spec + distinct Opus 5 code, both
REVISE rounds addressed). Same driver, macOS platform, real application
boot, port 11474, fresh base dir: SMOKE PASS 7/7. The scenario has now run
green on both OSes, pre- and post-merge.

## Expanded to SMOKE §11 (main at a74bcfb)

The 7-observation script was one scenario, not an e2e suite. It is now SMOKE
§11 (steps 34-41) with the driver expanded to 10 observations, adding the
paths the first cut skipped: a REAL retire canceling a queued notice (the
climb survives the messenger's cancellation), the prod production's live
match/no-match around a verb-asserted work-blocked fact, and a full
application stop/restart mid-climb converging to the alert through the
sweeper's cursor — review B1's boot path, run for real. 10/10 on eezo and
shrdlu. Step 41 (credentialed leg: a parent actually RUNS its notice turn
and acts on model-policy guidance) is WAIVED by name on both hosts: no
onboarded harness.

## Step 41 — the credentialed leg, CLOSED on eezo (main at ceea0b9)

Onboarded anthropic via the real CLI (`onboard anthropic --api-key`, key on
stdin from ~/tb-test-keys, ephemeral: base dir and banked copy deleted after
the run). Parent session on claude with the live credential; child on codex
with none. The child's turn failed for real; the bubble's notice reached the
parent; a LIVE claude ran the notice turn to `delivered`; the climb ended;
no alert filed. The parent's actual behavior closed the loop the rulings
describe: it read the failure, attempted `onboard openai` itself, hit the
interactive-OAuth wall, and escalated exactly that to Flynn — model-policy
move 3, chosen by inference. Step 41: PASS on eezo. (Still waived on
shrdlu: no key there, and one credentialed pass proves the leg.)

§11 scorecard: 34-40 PASS on eezo+shrdlu; 41 PASS on eezo, WAIVED(shrdlu).

## Steps 42-43 added and green (main at bf0128b)

Each new step caught real defects on its first runs:
- 42 (prod lifecycle over live ticks): a prod wake scheduled pre-block fired
  post-block — the prodder's true act time is the wake FIRE; recognition now
  rides it (supervision-owned wakes only, consumed as canceled with the
  reason named). 42 PASS both platforms after the fix.
- 43 (real SIGKILL mid-turn): run 1 exposed shared-adapters npm churn →
  single-flight provisioning (Spinup.Flight) + launch-awaits-flight; run 2
  exposed the never-launched-row-as-kill_failed fence that permanently
  disabled a harness on reboot → reconciliation now resolves a launch that
  demonstrably never minted a process, everything else keeps the refusal.
  Dispatched investigator disproved the park-vs-live-turn hypothesis by live
  instrumentation. 43 PASS on eezo (credentialed), WAIVED(shrdlu: no key).

## Production deploy (2a09afe) — both hosts verified

gibson: e499123 -> 2a09afe. Reboot-orphan fence self-resolved at boot; live
turn DELIVERED ("ALIVE", ~5s) on Flynn's main session — OAuth refresh valid,
adapter circuit closed/healthy. tars: e499123 -> 2a09afe, boot clean (empty
org, no turn test; graceful-stop gap filed — macOS build ignores SIGTERM).
Deploy artifacts: CI run 31046745837. The day's arc closed: the harness that
was silently down since the morning reboot is serving again, unbricked by
recognition, not surgery.
