# Client-e2e scorecard — 2026-07-26 @ d251b03

Client build: sim-client (driver)

| Step | claude@eezo | notes |
|---|---|---|
| P-claude auth claude | PASS | claude: credential store ready; catalog fetch is credential-gated, so the grant is LIVE |
| 1 boot | PASS |  |
| 2 pair | PASS |  |
| 3 converse | PASS |  |
| 4 tool use | PASS |  |
| 5 create stream | PASS |  |
| 6 rename stream | PASS |  |
| 7 retire stream | PASS |  |
| 8 cancel | PASS |  |
| 9 queueing | PASS |  |
| 10 concurrency | PASS |  |
| 11 /new | PASS |  |
| 12 /compact | PASS |  |
| 13a /model | PASS |  |
| 13b model change | PASS |  |
| 13c model footer | MANUAL | claude: rendered-footer assertion is app-side: ClawlineTests/SessionStatusDecodeResilienceTests.swift plus the chat_footer_model_picker / chat_footer_label identifiers; the wire half is row 13b |
| 14 restart resilience | PASS | claude: pid 13788 → 75529; interrupted turn delivered; harness pointer "loaded" |
| 15 restart queue survival | PASS |  |
| 16 wakes | PASS |  |
| 16b scheduled wake | PASS |  |

## Leg verdicts

- claude@eezo: PASS

RUN VERDICT: INCOMPLETE(harness parity: no leg for codex)

Run: `TIGHTBEAM_CLIENT_E2E_TEMPLATE=~/.tightbeam-smoke-9a84163
TIGHTBEAM_CLIENT_E2E_PORT=13900 TIGHTBEAM_CLIENT_E2E_HARNESSES=claude
TIGHTBEAM_SMOKE_MODEL_CLAUDE='claude-sonnet-5[medium]' mix run --no-start
scripts/client_e2e.exs`. Anchored at a clean tree (the runner refuses a dirty
one). Preflight before boot; teardown clean, no warnings, nothing left behind.

CLAUDE LEG ONLY, deliberately: the codex leg is a KNOWN FAIL on task #20 (the
cold-adapter `knows_session?` race after restart), so the run verdict is
INCOMPLETE on harness parity rather than PASS. That is the algebra working —
a single-harness run is not a smoke run.

## Matrix rows exercised this run

| harness-support.md row | leg | verdict |
|---|---|---|
| CAP-012 typing-indicator progress (proof: SMOKE step 4) | claude@eezo | verified — step 4 PASS |

## Deviations / findings

- First run under the round-3 oracles, all of which are strictly harder than
  the ones the previous PASS was measured against:
  - step 14 proves history durability by ROW IDENTITY captured before the
    interrupted post (a count there is satisfied by that turn's own new rows),
    requires every pre-restart id back in replay, and now REQUIRES the harness
    pointer to read `loaded` — recorded in the row note as
    `harness pointer "loaded"`, so the model kept its context across the restart
    rather than silently falling back;
  - step 15 accepts only a turn observed in `queued`, never one already
    `running`;
  - steps 16/16b follow a single chain from the dispatched wakeId through the
    turn row's own messageId to the correlated reply, so one wake's delivery
    cannot vouch for another's;
  - step 10's opportunity test uses B's ENQUEUE time, and interval overlap is
    strict at the boundary.
- 13c remains the only MANUAL row: a rendered footer is not observable at the
  wire, and its assertion lives in the app's own tests plus the two
  accessibility identifiers.
- P-claude PASSES as a genuine liveness proof because the measured probe finds
  claude's catalog fetch credential-gated. The codex equivalent is
  presence-only and is INCOMPLETE by design (task #15) — visible in the
  two-leg run at 7e7b7c6.
