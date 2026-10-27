---
name: tightbeam-operator
description: Operate a Tightbeam organization from outside it on behalf of a named user. Use when an agent that is not a Tightbeam session must inspect work, present or rule on decision requests, file and route work to a delivery owner, or wake sessions through the tightbeam CLI.
---

# Operate a Tightbeam organization as an outside operator

Written for Tightbeam 0.1.12. If `tightbeam --version` prints a different version, run
`tightbeam skill install` to replace this skill with the edition that ships with the
installed CLI, then start a fresh agent session.

You are not a Tightbeam session. You act for one human user of the organization and
reach it only through the `tightbeam` CLI. Use this skill when the person asks about
Tightbeam work, decision requests, agent sessions, or messages to a session.

## Identity and authority

Pass `--as-user <userId>` on every command, with the user identifier the person gave
you. Never guess it. Everything you run is attributed to that person, so make only the
changes they asked for. Reading is normally fine.

Creating work, waking sessions, ruling or withdrawing decisions, revoking or reopening
assignments, spawning, retiring or tuning sessions, onboarding credentials, learning
kungfu, editing identity, and host or user administration each need the person's
instruction for that operation. When the CLI refuses an action, report the exact code
and message. Do not work around a refusal, and do not switch identity to get past one.

## Reach the right organization

Run the CLI on a machine that reaches the gateway holding the state the person means.
When they name a machine or organization, use that one. The CLI finds its gateway as
`tightbeam --help` describes under DISCOVERY.

- `tightbeam --help` is the command contract for the installed release. Read it before
  relying on an exact command or flag; `tightbeam help <command>` prints one entry.
- `tightbeam doctor --as-user <userId>` reports the local installation's health when a
  command fails to reach the gateway.
- Do not read `.tightbeam-session`, `gateway.json`, or Tightbeam's credential
  directories, and do not call the gateway's HTTP interface yourself. The CLI is the
  interface.
- Starting, stopping, or upgrading the gateway changes the whole organization. Report a
  gateway that is down; change its state only when the person asks.

## Records

A work item is one intended outcome; its `deliveryOwnerSessionKey` names the session
accountable for delivering it. An assignment is one obligation on a work item, held by
one session and owed to its opener. An attest records what happened against an
assignment. An artifact points to a file someone may need again. A decision request asks
a named principal for a judgment. A wake is a prompt with a delivery time or condition.
Use returned identifiers exactly; never invent one.

Records show the state of the work; they do not prove it was done. A completion attest
is a claim to inspect. A running turn is not proof that anything is executing. Read the
assignment, its attests, the work-item trace, and the session transcript before you tell
the person that work is done, stuck, or still pending.

## Read the organization

Use the smallest read that answers the question:

```sh
tightbeam list --as-user <userId>
tightbeam execution-map --origin user --state open --as-user <userId>
tightbeam execution-map --quiet-over 2h --as-user <userId>
tightbeam toplines --as-user <userId>
tightbeam work-item-get <workItemId> --as-user <userId>
tightbeam work-item-trace <workItemId> --as-user <userId>
tightbeam assignments --state open --as-user <userId>
tightbeam assignment-get <assignmentId> --as-user <userId>
tightbeam attests <assignmentId> --as-user <userId>
tightbeam artifacts --work-item <workItemId> --as-user <userId>
tightbeam transcript --session <sessionKey> --as-user <userId>
```

`list` shows the sessions you can address, archetypes, hosts, and the model catalog.
`execution-map` shows every visible work item with who holds it, whether anything is
running, and how long it has been quiet; add `--tree` for the causal forest.
`transcript --name <displayName>` returns candidate sessions, never content.

Report at the level the person asked about: what works, what is blocked, and what
needs their decision. Keep identifiers as supporting detail and say what each one is.

## Decision requests

Start from the open list:

```sh
tightbeam decision-requests --status open --as-user <userId>
```

Each request has a kind:

- `operator`: a choice that belongs to the person. Before you present it, read its
  linked assignment and attests. If the assignment is closed or revoked, or later
  records already settle the question, say so instead of presenting it as live.
- `effort`: an automated check-in raised when a session spent effort without a recorded
  effect. It is not a product decision. Read one with
  `tightbeam decision-request --request <id>` and rule it with
  `tightbeam effort-rule --request <id> --action continue|dismiss` only when the person
  chooses that disposition.
- `agent`: a question an agent asked through `tightbeam ask`. Reply with
  `tightbeam answer --request <id> --answer "<text>"`, or send it back with
  `tightbeam return --request <id> --reason "<text>"`, only with the person's answer.

For each live operator request, tell the person the background in plain words, the
choice being asked, what each option would change, and the evidence on record. Do not
add options and do not make the choice yourself.

Record the person's choice with its exact option label, or their own words when the
request has no options or they answered freely:

```sh
tightbeam operator-rule <decisionRequestId> --decision "<exact label>" --as-user <userId>
tightbeam operator-rule <decisionRequestId> --response "<their answer>" --as-user <userId>
```

Add `--rationale "<text>"` to carry the person's reasoning or their exact delegation.
Withdraw a request that is no longer needed only with the person's instruction:
`tightbeam operator-withdraw <decisionRequestId> --reason "<text>"`. A ruling wakes the
session that raised the request; do not send a second wake to repeat it.

## File and route work

Send new work to the session that owns delivery for that product, and let it staff the
work. Find that session from an existing work item's `deliveryOwnerSessionKey`, from
`tightbeam list`, or by asking the person. Do not spawn or assign workers yourself unless
the person tells you to staff the work directly.

Hand off in one operation:

```sh
tightbeam work-item-handoff --title "<outcome>" \
  --delivery-owner <sessionKey> --brief "<full brief>" --as-user <userId>
```

This creates the work item, records the delivery owner, and sends the brief. Use
`--work-item <workItemId>` instead of `--title` to hand off an item that already exists.
Write the brief for a reader who knows nothing of the conversation: the outcome in the
person's words, the facts, the constraints, the authority granted, and what done looks
like. A title and a pointer do not brief anyone.

To file without routing, use `tightbeam work-item-create --title "<outcome>"
--key <idempotencyKey>` and put the full text on it with
`tightbeam work-item-update <workItemId> --body "<text>"`. An unrouted item is still
owed a route or an icebox. `tightbeam dispatch --to <sessionKey> --subject "<work>"
--brief "<one sentence>" --work-item <workItemId>` opens an assignment on an existing
item and wakes its holder in one step.

Pass `--key` on any create you might retry. The record is the trigger: do not also wake
the delivery owner to repeat what the work item says.

## Wake sessions

Send a wake for what no record carries: a question, a correction, a fact that changes
what someone must do now.

```sh
tightbeam wake --session <sessionKey> --prompt "<text>" --as-user <userId>
tightbeam wake --role <role> --prompt "<text>" --as-user <userId>
```

Target a session when that exact session matters; a role falls back to its owner's Main
when it is unstaffed. Every wake costs its recipient a turn, so do not send status
requests or acknowledgments. `--class fyi|status-query|input-needed|blocker|algedonic`
labels urgency within the recipient's batch; it does not interrupt a running turn or make
the recipient run sooner. Reserve `algedonic` for a real emergency.

`tightbeam cancel-wake <wakeId>` withdraws a pending wake that has not been delivered.
Replacing queued messages with `--replace-queued` requires a session sender, so as a
user send a clear correction instead. `tightbeam cancel-turn --session <sessionKey>`
stops a running turn in a session the user owns; use it only when the person asks.

## Stop on visible failure

Stop on a nonzero exit, malformed JSON, an authentication or version refusal, an
unreachable gateway, or any named refusal. Report the code and message with secrets
removed. Retry a mutation only when the records show it did not happen or you passed an
idempotency key.

Never write to a Tightbeam database, identity tree, credential store, or generated file
directly. Never put a secret in a prompt, note, or command argument; when a command
takes a secret, pipe it on stdin as `tightbeam --help` directs.
