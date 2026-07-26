# Smoke scorecard — <date> @ <gateway short-sha>

Client build: <n> · Operator: <who> · Scope: {harness x host} legs listed below.

## Row schema (v1 — client-e2e-v1 §Architecture)

One row per SMOKE.md step, per leg. Cell values:

| value | meaning |
|---|---|
| `PASS` | both oracle columns held (the client assertion AND the substrate assertion) |
| `PASS (divergence <matrix row id>)` | the leg diverges and the divergence was NEGATIVE PROVED; cite the `harness-support.md` row. An uncited divergence is a runner-local waiver and is not a pass |
| `FAIL(note)` | an oracle did not hold |
| `INCOMPLETE(blocker)` | the step could not be driven to a verdict; the blocker is required |
| `MANUAL(reason)` | outside v1 automation scope, run by hand — VERDICT-NEUTRAL |
| `N/A[harness-only]` | the step does not exist on this harness |

Preflight rows are AUTOMATED rows and take PASS/FAIL like any other. The driver
names them `P-<harness>` rather than SMOKE's P1/P2 so the harness REGISTRY stays
the authority on which legs exist; a new harness gets a preflight row without an
edit here.

Leg verdict: `PASS` iff every applicable preflight row and every automated
(non-`MANUAL`) row is `PASS`; any `FAIL` → `FAIL`; else any `INCOMPLETE` →
`INCOMPLETE(blockers)`. A leg whose rows are ALL manual is `INCOMPLETE`, never
a pass — a leg that ran nothing is the shape of a vacuous pass.

Run verdict: the WORST leg verdict, and `INCOMPLETE` unless every registered
harness has a leg (T-PARITY: a single-harness run is not a smoke run).

The algebra is implemented and tested in `Tightbeam.ClientE2E.Scorecard`; the
driver emits this table directly (`TIGHTBEAM_CLIENT_E2E_OUT=<this file>`).

| Step | claude@<host> | codex@<host> | notes |
|---|---|---|---|
| P-claude auth | | N/A | |
| P-codex auth | N/A | | |
| 1 boot [J0] | | | |
| 2 pair [J0] | | | |
| 3 converse [J1] | | | |
| 4 tool use [J1] | | | |
| 5 create stream [J2] | | | |
| 6 rename stream [J2] | | | |
| 7 retire stream [J2] | | | |
| 8 cancel [J3] | | | |
| 9 queueing [J4] | | | |
| 10 concurrency [J5] | | | |
| 11 /new [J6] | | | |
| 12 /compact [J6] | | | |
| 13a /model [J6] | | | |
| 13b model change [J6] | | | |
| 13c model footer | | | rendered-footer assertion is app-side |
| 14 restart resilience [J7] | | | |
| 15 restart queue survival [J7] | | | |
| 16 wakes [J8] | | | |
| 16b scheduled wake [J8] | | | |
| 17-23 rails | | N/A per step (negative checks only) | |
| 24 satellite propagation | | | |
| 25-33 roles | | | |

## Matrix rows exercised this run

| harness-support.md row | leg | verdict |
|---|---|---|
| | | |

## Leg verdicts

- claude@<host>: 
- codex@<host>: 

RUN VERDICT: 

## Deviations / findings
- 
