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
