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
- **[A] affordance** — whether the **product** makes its own path findable. Observed
  through model behaviour, but the subject is what we shipped, not what the model
  knows: the agent fails an [A] criterion by not finding something we published.
  Produces **FINDINGS**, and **never gates** — one model's behaviour is too noisy to
  fail a run on. Filing these under [E] would bury them as model mood and make them
  unactionable; that is the exact mistake this marker exists to prevent. An [A]
  finding is a bug against guidance, skills, or CLI help, and is filed there.

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
| M4 | satellite A | satellite B | neither endpoint is the gateway; also carries the affordance probe (E) |

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
autonomously replies *back* to Alpha with `wake --role alpha`. Record it. A model that
declines is not a substrate failure — see SMOKE.md step 29. Whether Bravo could
*find* the reply spelling at all is a different question and belongs to §E, which
asks it deliberately; do not conflate a decline with a failure to discover.

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

### E. M4 only — is the built-in path the obvious one?

M4 is where an agent is most tempted to improvise: two satellites, each plainly
reachable from the other by ssh, and the built-in path runs through a third machine.
So this row carries one substrate check and an **affordance probe** — can an agent
*find* what we shipped, without being told.

> **RESOLVED (was Q2).** Isolation between two satellites is deliberately **not** the
> property under test. Flynn's ruling: it does not matter whether an agent could find
> some other way to reach a peer — what matters is that our way is easy and
> conspicuous enough that it never burns tokens inventing one. The gateway-down
> negative check that used to sit here is **withdrawn**; proving absence of a direct
> path would need traffic capture, and malicious circumvention is out of scope by
> standing ruling.

**1. [S] The exchange is durable on the gateway.** Satellite A wakes Satellite B.
Every durable row for the exchange exists **in the gateway's `state.db`** — the wake,
the turn on B, the message. There is no satellite-side ledger; agents on a satellite
reach the gateway through the injected `TIGHTBEAM_URL` / `TIGHTBEAM_TOKEN`.

**2. [A] Discoverability — the cold ask.** From Satellite A's agent, give a task that
plainly requires reaching another agent and **do not name the command, the CLI, or
the verb**:

```
"Bravo, on <B's host>, has the <thing>. Get it from Bravo and report back."
```

Record, **verbatim, not paraphrased**:

- the agent's **first action** after the prompt — the exact command line or tool call.
  A paraphrase destroys the signal; this line is the finding.
- what it consulted before acting: `tightbeam help`? `--help` on a subcommand? a
  skill it went and read? guidance already in its context? nothing at all?
- whether it arrived at `tightbeam wake --role bravo --prompt "…"`, and how many
  actions it took to get there.

Reaching the built-in path within the first two actions is the shape we want.
Anything else is a FINDING, recorded with the first attempt quoted.

**3. [A] The reply affordance.** Bravo receives the prompt with a first line
`[from agent:alpha]` (stamped at `gateway.ex:826`; `wire/payloads.ex:20-26` states the
stamp's job normatively — it is "the model's return address"). Ask Bravo to answer
and, again, **do not spell the command**.

The question is whether the stamp alone yields the reply spelling. It is not a pure
substitution: the stamp carries the origin class and handle, `agent:alpha`, while the
reply is `wake --role alpha` — the agent must drop the class prefix and pick the
matching target flag. Record whether Bravo makes that translation, and record any
wrong surface it reaches for instead (writing a file, answering into its own
transcript and expecting delivery, guessing a `--session` key).

**4. [A] Cost.** Roughly how much work happened before the built-in path was found:
actions taken, files or help pages read, turns consumed. "Reached for it directly"
and "found it after eleven actions" are different products, and the scorecard should
be able to tell them apart.

**5. Improvisation is the finding, not the fault.** If the agent invents its own
channel — ssh into the other host, a shared file, polling a directory, writing into a
repo — that is a **FINDING about conspicuousness**, not agent misbehaviour, and it is
never scored as an [E] failure. Do not correct the agent mid-run; let it finish and
record the whole path it took. An agent that reaches for ssh on M4 has told us the
product's own path was not visible from where it was standing.

> **Known gap — the live hypothesis this probe exists to check.** The shrdlu run
> (`docs/smoke-runs/2026-07-28-91901ff-shrdlu-prod-service.md`, step 29) found
> **zero** occurrences of `wake --user`, `wake --role` or `[from …]` in the probe
> session's composed guidance. Reading the source, that is the shape of composition,
> not a packaging accident:
>
> - The reply spelling **is** written down in `priv/guidance/operating-manual.md:31-32`
>   — but that fragment reaches an agent only if its archetype `#include`s
>   `operating-manual.md`, and **no shipped archetype does**
>   (`priv/archetypes/default.toml`, `priv/kungfu/agentic-engineering/archetypes/*.toml`).
>   `Identity.snapshot_at!` (`lib/tightbeam/identity.ex:119-125`) composes the
>   archetype's own guidance plus `operating-model.md` — a *different* document, about
>   the served-identity seam, which never mentions wake.
> - The `default` archetype elects **no skills at all**
>   (`priv/kungfu/agentic-engineering/archetypes/default.toml`), so a default-archetype
>   agent carries neither `tightbeam-dispatching` nor any bundle skill.
> - `tightbeam-dispatching` (`priv/skills/tightbeam-dispatching/SKILL.md:11`) teaches
>   the **dispatch** wake, `tightbeam wake --role <name> --prompt "…"`. It never
>   mentions `--user` and never mentions the `[from …]` stamp — it is not where an
>   agent learns to *reply*.
> - `wake --user <id>` appears only in bundle skills (`feature-cycle` SKILL.md:26,68;
>   `spec-handoff`:17,47; `unblocking`:36), elected by the orchestrator and spec-writer
>   archetypes and no others.
>
> But the affordance is **not** absent from the product: `tightbeam help` carries it
> prominently, under IDENTITY, before any command
> (`cli/src/args.rs:265-300`) — *"To reply to [from user:mike], use wake --user mike;
> to reply to [from agent:notetaker], use wake --role notetaker. [from process:x]
> cannot be woken."* — and a malformed wake answers `usage: tightbeam wake exactly one
> of --session <key>, --role <name>, --user <id> --prompt ...` (`cli/src/args.rs:749`).
>
> So the sharp question this probe asks is: **does the agent think to run `tightbeam
> help`?** One command away is either conspicuous or invisible, and only the cold ask
> settles it. **Record the archetype every probe session carries** — discoverability is
> archetype-dependent, and a result without the archetype is unreadable.
>
> **OPEN — inconsistent origin spelling.** `operating-manual.md:32` instructs
> "tagged `[from role:notetaker]`, run `wake --role notetaker`", but `role:` is not an
> origin class: `wire/payloads.ex:13-14` fixes the closed set as `user:<id>`,
> `agent:<handle>`, `process:<name>`, and the live stamp is `[from agent:…]`
> (shrdlu step 29 observed `[from agent:probe-office]`). An agent following the manual
> literally would be looking for a tag that never appears. Whether the manual or the
> wire contract is wrong is not this runbook's call — file it.

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
- Any **[A]** observation that misses is a **FINDING** against guidance, skills, or CLI
  help — named, with the agent's first attempt quoted. It **never** produces a FAIL: a
  single model's behaviour cannot gate a run. A run can pass carrying [A] findings.
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
participating host and its role, the **archetype and model each probe session
carried** (§E is unreadable without them), and which cells were waived.

**Record turns consumed per row.** Turn count per step is otherwise unrecoverable
after the fact, and a step that silently stops exercising anything is invisible
without it.
