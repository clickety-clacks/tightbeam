# Inter-node agent communication runbook

Proves that genuine agents, running on different machines, talk to each other
**through the substrate** — with durable attribution, no cross-talk, and delivery
that survives restarts. Requires a satellite assimilated per
`docs/ASSIMILATION-E2E.md`.

This replaces SMOKE.md step 24's satellite propagation check, which was a single
manual line with no commands and no rows. Step 24 now points here.

## What a turn is, because it decides what can be proven

A turn is **one accepted prompt and everything the agent does until it relinquishes
control** — one row in `turns`, `queued → running → (delivered | canceled | failed |
failed_unknown)`, with `claim_next/2` refusing while a running row exists. Tool
calls happen *inside* a turn and are not separately durable.

So the substrate can prove **delivery, attribution, correlation and isolation** at
turn granularity. It cannot prove what the model did in between. Every criterion
below is therefore marked:

- **[S] substrate** — an observable row or frame. Gates the verdict.
- **[E] effectiveness** — whether a model chose to do the apt thing. Recorded,
  **never gates**. This is evals' domain (#11), not this runbook's.

Conflating these is how a runbook starts failing on model mood.

## The dispatch surface

Agents use the same verbs the operator does, over `POST /agent/dispatch`
(cliToken auth). The `tightbeam` CLI is a facade over it. Body shape:

```json
{"as":"<role>","verb":"wake","sessionKey":"agent:coder:app","params":{"prompt":"…","afterMs":30000}}
```

Identity is exactly one of `as` (role), `asUser`, `asProcess` — **who the call is
attributed to**, not its target. Target is exactly one of `sessionKey`, `role`,
`userId`. Inside a session workdir the CLI walks up for `.tightbeam-session` and the
gateway derives identity from that credential, which is the path a real agent takes.

**There is no agent `post`.** `wire/router.ex` excludes it deliberately: an agent DM
IS a wake-with-prompt. So the two paths this runbook exercises are **immediate wake**
(a direct message) and **scheduled wake** (`--after` / `--at`), not post-vs-wake.

> **OPEN QUESTION (Q1).** Flynn asked for "post and wake paths". If an agent-facing
> `post` is intended to exist, that is a product gap to file — this runbook covers
> what the code offers and does not invent a second surface.

## Prerequisites

- Gateway healthy, READY for every harness under test.
- At least one satellite assimilated and credentialled per harness under test
  (`ASSIMILATION-E2E.md` §4). **Satellite-to-satellite rows require two.**
- Each participating session's harness has a live catalog on the gateway.
- Clocks roughly aligned across hosts — scheduled-wake evidence is timestamped.

> **OPEN QUESTION (Q3).** A full placement × harness matrix needs one credentialled
> harness per participating host per harness under test. Which cells are in scope —
> and therefore how many interactive authorizations are required — is an operator
> decision. Cells not in scope are **WAIVED by name**, not skipped silently.

## Cast

Create genuine agent sessions, each bound to a role so it has an agent identity:

```
tightbeam spawn --display "Alpha" --name alpha --archetype <a> --harness <h> --as-user <admin>
tightbeam spawn --display "Bravo" --name bravo --archetype <a> --harness <h> --as-user <admin>
tightbeam spawn --display "Charlie" --name charlie --archetype <a> --harness <h> --as-user <admin>
```

Charlie is the **isolation control** and is never addressed. Placement per row
below; `--archetype` must admit the intended host, and `tune set_host` moves an
existing session among a `where` set.

## The placement matrix

Run each row. Same-harness first; repeat cross-harness where both are credentialled
on the relevant hosts.

| # | from | to | note |
|---|---|---|---|
| M1 | local | local | baseline; isolates substrate faults from transport faults |
| M2 | local | satellite | gateway-resident sender |
| M3 | satellite | local | the return path — an agent on a satellite must reach the gateway |
| M4 | satellite A | satellite B | neither endpoint is the gateway |

M1 first, always. A failure that reproduces on M1 is not an inter-node problem.

## Per-row procedure

### A. Immediate wake — the direct message

From Alpha, addressed to Bravo. Run from inside Alpha's session workdir so identity
is session-implied (the real agent path), or with `--as alpha`:

```
tightbeam wake --role bravo --prompt "<unique-token> report your host"
```

Use a fresh unguessable `<unique-token>` per row. It is what makes cross-talk
checks decisive.

**[S] PASS**, all of:

1. `wakes` row: `origin` = `agent:alpha`, `targetRole` = `bravo`, `state` `pending →
   fired`, `creatorSessionKey` = Alpha's key, `consumer` = `prompt`.
2. `turns` row **on Bravo's session**: `wakeId` equal to the dispatched wake id
   (the column is UNIQUE — at-least-once delivery yields exactly-once enqueue),
   `origin` = `agent:alpha`, `roleRef` = `bravo`, `roleFallback` = 0 (Bravo is
   staffed), reaching `delivered`.
3. The delivered prompt is **sender-stamped** `[from agent:alpha]` (prefix applied
   at `gateway.ex:826`) and contains `<unique-token>`.
4. `messages`: Bravo's assistant reply carries `replyToMessageId` correlating to the
   delivered message.
5. **Isolation**: Charlie has **zero** turns and **zero** messages carrying
   `<unique-token>` or that `wakeId`. Alpha's own session has no turn for it either
   — a wake is not echoed to its sender.

**[E] recorded, non-gating**: whether Bravo's reply is responsive, and whether Bravo
autonomously replies *back* to Alpha with `wake --role alpha` per its dispatching
skill. Record it. A model that declines is not a substrate failure — see SMOKE.md
step 29, and note the reply spelling lives in the `tightbeam-dispatching` skill, not
in composed guidance.

### B. Scheduled wake

```
tightbeam wake --role bravo --prompt "<unique-token-2> …" --after 30s
```

**[S] PASS**: `wakes.state = pending` and visible in a listing before `dueAt`; then
`fired` with `firedAt` set; a turn appears on Bravo carrying that `wakeId`; the
`[from agent:alpha]` stamp is present. Isolation as in A.

### C. Delivery survives a restart

Schedule as in B, then **before it fires**, restart the gateway. Separately, with a
turn `running` and another `queued` on Bravo, restart again.

**[S] PASS**: the scheduled wake still fires after the restart; the queued turn
delivers **without being re-sent**; the harness pointer reads `loaded`, never
`fallback`. For satellite rows, the satellite session reconnects with no operator
action.

Repeat with an **adapter** restart rather than a gateway restart where the row's
target is remote — an adapter fault must not lose a durable wake.

### D. Bounded behaviour under loss — satellite rows only

With a wake in flight to a satellite target, make that satellite unreachable
(record the method).

**[S] PASS**: the turn fails **fast with a reason**, or remains durably queued —
never hangs and never silently disappears. Backoff and circuit state are visible in
`/version`. Restore reachability: the circuit closes on the next successful start,
and any durable wake still due fires.

### E. M4 only — proof it routes through the substrate

Satellite A wakes Satellite B. Two checks:

1. **Positive**: every durable row for the exchange exists **in the gateway's
   `state.db`** — the wake, the turn on B, the message. There is no satellite-side
   ledger; agents on a satellite reach the gateway through the injected
   `TIGHTBEAM_URL` / `TIGHTBEAM_TOKEN`.
2. **Negative**: stop the gateway. Attempt the same A→B wake. **PASS: it cannot be
   delivered** — the CLI fails to reach a gateway and no state changes anywhere.
   Restart the gateway; a wake issued after recovery delivers normally.

> **OPEN QUESTION (Q2).** The negative check proves routing goes *through* the
> substrate. It does not prove two satellites *could not* communicate by some other
> means; only traffic capture would, and per standing ruling malicious circumvention
> is out of scope. Confirm this is the intended bar.

## Cross-harness

Repeat A on each placement row with sender and recipient on **different harnesses**
(claude → codex and codex → claude). **[S] PASS**: identical row evidence; the
recipient's turn records its own `harness`, and the sender's harness is irrelevant
to delivery. Attribution and stamping must not vary by harness — a divergence here
is a FINDING and belongs in the harness-support matrix.

## Verdict

Per row and per harness combination: PASS / FAIL(note) / WAIVED(blocker) / NOT
VERIFIED(reason) / BLOCKED(blocker).

- Any **[S]** criterion failing is a FAIL.
- Any **[E]** observation is recorded and **never** produces a FAIL.
- An out-of-scope cell is WAIVED by name with its blocker. The run is INCOMPLETE —
  not passed — while any cell is waived.

## Cleanup — preserves the installs

Retire the probe sessions (soft delete; rows and messages remain, by design) and
remove the probe roles. **Do not** uninstall the gateway or de-assimilate the
satellite: both are retained per `docs/TEST-HOSTS.md` §5. Remove only temporary
artifacts outside the base dirs. Re-verify unrelated workloads active on every
participating host.

## Scorecard

`docs/smoke-runs/<date>-<short-sha>-inter-node-comms.md`. One row per {placement ×
harness-pair × path}, columns for A–E. Header carries gateway commit, every
participating host and its role, and which cells were waived.

**Record turns consumed per row.** Turn count per step is otherwise unrecoverable
after the fact, and a step that silently stops exercising anything is invisible
without it.
