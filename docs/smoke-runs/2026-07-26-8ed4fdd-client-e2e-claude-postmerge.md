# Client-e2e scorecard — 2026-07-26 @ 8ed4fdd

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
| 13b model change | FAIL | claude: session-status reports "claude-sonnet-5", expected "claude-opus-5" |
| 13c model footer | MANUAL | claude: rendered-footer assertion is app-side: ClawlineTests/SessionStatusDecodeResilienceTests.swift plus the chat_footer_model_picker / chat_footer_label identifiers; the wire half is row 13b |
| 14 restart resilience | PASS | claude: pid 2542 → 62717; interrupted turn delivered; harness pointer "loaded" |
| 15 restart queue survival | PASS |  |
| 16 wakes | PASS |  |
| 16b scheduled wake | PASS |  |

## Leg verdicts

- claude@eezo: FAIL

RUN VERDICT: FAIL
