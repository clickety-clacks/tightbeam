# Client-e2e scorecard — 2026-07-26 @ 885f260 DIRTY (diff 119db726c926)

Client build: sim-client (driver)

| Step | codex@eezo | notes |
|---|---|---|
| P-codex auth codex | PASS | codex: credential store ready; authenticated liveness probe returned :live |
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
| 13b model change | PASS | codex: applied gpt-5.6-terra |
| 13c model footer | MANUAL | codex: rendered-footer assertion is app-side: ClawlineTests/SessionStatusDecodeResilienceTests.swift plus the chat_footer_model_picker / chat_footer_label identifiers; the wire half is row 13b |
| 14 restart resilience | PASS | codex: pid 22813 → 45016; interrupted turn delivered; harness pointer "loaded" |
| 15 restart queue survival | PASS |  |
| 16 wakes | PASS |  |
| 16b scheduled wake | PASS |  |

## Leg verdicts

- codex@eezo: PASS

RUN VERDICT: INCOMPLETE(harness parity: no leg for claude)
