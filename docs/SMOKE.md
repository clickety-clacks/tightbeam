# Smoke runbook — core user journeys

Run this after any change to prove core functionality is alive. It walks the
operator journeys end-to-end from a real client (the iOS simulator) against a
freshly-booted gateway; steps that are awkward to drive through the simulator
have a CLI fallback (marked ⌥). Every step names its PASS condition — an
observable frame, bubble, or row. The DB checks use
`sqlite3 <base_dir>/state.db`.

Conventions: GATEWAY = the gateway under test (fresh base_dir unless the run
says otherwise). First device to pair becomes the admin user. `tb` = the
reference CLI with TIGHTBEAM_URL/TIGHTBEAM_TOKEN pointed at GATEWAY (token
from `<base_dir>/gateway.json`).

## 0. Boot + pair

1. Boot the gateway (fresh base_dir; auth seeded for the claude harness).
   PASS: `GET /version` returns `{"protocolVersion":1,...}`.
2. In the client: set the server URL, pair with a claimed name.
   PASS: pair succeeds instantly (first user bootstrap), catalog shows one
   "Main" stream, `sync_complete` arrives (app leaves the connecting state).
   DB: one `allowlisted` device; one `users` row with `isAdmin=1`.

## 1. Converse (the fundamental loop)

3. Post "hello, who are you?" in Main.
   PASS: echo bubble immediately; typing indicator ON with live progress
   text (at minimum "Thinking…" flickers); assistant bubble arrives;
   indicator clears WITHOUT lingering. DB: turn row `delivered`.
4. Post a message that provokes tool use ("run `uname -a` and tell me what
   it says").
   PASS: progress label shows a tool title during the turn; assistant bubble
   reports the output; indicator clears.

## 2. Session lifecycle

5. Create a second session (client stream UI; ⌥ `tb spawn --display
   "Smoke" --as-user <admin>`).
   PASS: `stream_created` lands live — the new stream appears in the catalog
   WITHOUT reconnecting. Post in it; assistant replies. DB: sessions row,
   `origin` = the creator.
6. Rename it (client stream UI; ⌥ `tb`/PATCH via session sheet).
   PASS: `stream_updated` — name changes in the catalog live.
7. Delete it (client stream UI; ⌥ `tb retire <key> --as-user <admin>`).
   PASS: `stream_deleted` — gone from the catalog live. DB: sessions row
   `state='retired'` (soft — the row and its messages REMAIN).

## 3. Cancel

8. Post a long task in Main ("count to 200 slowly, one line per number").
   While the indicator is live, hit the client's stop control (⌥ `tb`
   /api/session-control `cancel_current_run`).
   PASS: turn-state `canceled` arrives (terminalState true); indicator and
   progress label clear; NO assistant bubble for that turn afterward.
   DB: turn row `canceled`. Post again — next turn runs normally (lane
   drained on).

## 4. Queueing — one lane, strict order

9. Post three messages back-to-back in Main without waiting: "say ONE",
   "say TWO", "say THREE".
   PASS: three echoes immediately; exactly one turn runs at a time (DB:
   never more than one `running` for the session); three assistant bubbles
   arrive IN ORDER; all three turn rows `delivered`. The indicator stays
   sane throughout (on while running, cleared at the end).

## 5. Concurrency — multiple chats in parallel

10. Create session "Smoke B". Post a slow prompt in Main ("write a haiku
    about each of 10 planets"), then IMMEDIATELY post in Smoke B ("what is
    2+2?"), then a third in Main ("now say DONE").
    PASS: Smoke B's reply arrives while Main's first turn is still running
    (different lanes run in parallel); Main's two turns complete in order;
    ALL turns reach `delivered` with assistant bubbles; no cross-talk
    (each reply in its own stream). DB: at peak, two `running` rows with
    DIFFERENT sessionKeys.

## 6. Slash commands (current contract)

The substrate interprets no message content: slash commands are delivered to
the model as ordinary text. The PASS condition is therefore: the turn
COMPLETES — assistant bubble, indicator clears, `delivered` row. A stuck
indicator on any slash command is a regression (this exact class shipped
once: a `/new` that died pre-model with `Session not found`).

11. `/new` — PASS: completes as above (model replies conversationally; no
    session rotation occurs — that mechanism is future `tune` work).
12. `/compact` — PASS: completes as above.
13. `/model` — PASS: completes as above. Then change the model for real via
    the client's picker (session-status → set_model; ⌥ POST
    /api/session-control `set_model`). PASS: `GET /api/session-status`
    shows the new ref; next turn still completes; AND the client's model
    FOOTER populates (this asserts the Swift decode contract, which raw
    JSON checks miss — a missing required field like sessionKey fails the
    whole decode and the footer silently never fills).

## 7. Restart resilience (deploy semantics)

14. Post a slow prompt; while the indicator is live, SIGTERM the gateway
    (plain `kill <pid>`), wait for exit, restart it.
    PASS: the gateway drains — either the turn completes before exit
    (assistant bubble, then restart is invisible beyond a reconnect blip)
    or, past the drain deadline, the client shows the turn FAILED with
    "interrupted: outcome unknown" after restart — never a silent stuck
    indicator. Client reconnects by itself; replay shows full history; a
    fresh post works and the model still has its context (same harness
    session re-adopted — pointer chain shows `loaded`, not `fallback`).
15. Queue two messages, SIGTERM before the first completes, restart.
    PASS: queued (not-yet-running) turns survive and run to `delivered`
    after the restart without re-sending.

## 8. Wakes (agent comms surface)

16. ⌥ `tb wake <mainKey> --prompt "reply with exactly: WAKE OK" --as-user
    <admin>`.
    PASS: the prompt appears in Main as a sender-tagged message; assistant
    replies "WAKE OK". Then `--after 15s` variant: fires after the delay
    (row visible in `tb list` until it fires).

## Recording results

Note gateway commit hash, client build, date, and any step's deviation in
docs/JOURNAL.md. A FAIL on any step blocks deploy of whatever changed.
