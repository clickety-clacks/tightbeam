# Client-e2e scorecard — 2026-07-26 @ fe7383f

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
| 13b model change | PASS | claude: applied claude-opus-4-8 |
| 13c model footer | MANUAL | claude: rendered-footer assertion is app-side: ClawlineTests/SessionStatusDecodeResilienceTests.swift plus the chat_footer_model_picker / chat_footer_label identifiers; the wire half is row 13b |
| 14 restart resilience | PASS | claude: pid 43298 → 13331; interrupted turn delivered; harness pointer "loaded" |
| 15 restart queue survival | PASS |  |
| 16 wakes | PASS |  |
| 16b scheduled wake | PASS |  |

## Leg verdicts

- claude@eezo: PASS

RUN VERDICT: INCOMPLETE(harness parity: no leg for codex)

Run: `TIGHTBEAM_CLIENT_E2E_TEMPLATE=~/.tightbeam-smoke-9a84163
TIGHTBEAM_CLIENT_E2E_PORT=14400 TIGHTBEAM_CLIENT_E2E_HARNESSES=claude
TIGHTBEAM_SMOKE_MODEL_CLAUDE='claude-sonnet-5[medium]' mix run --no-start
scripts/client_e2e.exs`. Anchored: the runner refuses a dirty tree, and
`fe7383f` is POST-MERGE of main (job-trace + assimilate-harness). Preflight
before boot; teardown clean, no warnings, no leftover directory and no
orphaned adapter.

CLAUDE LEG ONLY, deliberately: the codex leg is a known FAIL on task #20 (the
cold-adapter `knows_session?` race after restart), so the run verdict is
INCOMPLETE on harness parity rather than PASS. A single-harness run is not a
smoke run.

## Matrix rows exercised this run

| harness-support.md row | leg | verdict |
|---|---|---|
| CAP-012 typing-indicator progress (proof: SMOKE step 4) | claude@eezo | verified — step 4 PASS |

## Deviations / findings

- All 19 automated rows PASS under the round-3 oracles, which are strictly
  harder than any previous PASS was measured against: step 14 checks history
  durability by ROW IDENTITY captured before the interrupted post and now
  REQUIRES the harness pointer to read `loaded` (noted in the row:
  `harness pointer "loaded"`, so the model kept its context across the
  restart); step 15 accepts only a turn observed in `queued`; steps 16/16b
  follow one chain from the dispatched wakeId through the turn row's own
  messageId; step 10 tests opportunity by ENQUEUE time with strict interval
  boundaries.
- **13b's note reads `applied claude-opus-4-8`, and that is the point.** On a
  RESIDENT session the gateway applies a tune to the live harness session and
  answers `ok: false` when the grant is not entitled to the requested model,
  leaving the session alone — main's job-trace merge made that path loud. The
  first post-merge run FAILED here because the oracle read only the HTTP status
  and asserted the model had changed regardless; it was failing the substrate
  for being correct. The step now tries catalog candidates, requires `ok: true`
  to change the model and `ok: false` to leave it alone (a refusal that mutated
  the session anyway is its own FAIL), and reports INCOMPLETE if nothing on
  offer can be applied. opus-5 and fable-5 are refused on this grant; opus-4-8
  applies.
- Teardown now reaps the gateway's DESCENDANT tree. Eight orphaned harness
  adapters had accumulated across the afternoon holding four leg directories
  open, which is what had been defeating removal and re-creating directories
  after deletion. This run left nothing behind.
- 13c remains the only MANUAL row: a rendered footer is not observable at the
  wire.
