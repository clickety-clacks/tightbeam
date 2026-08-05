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
