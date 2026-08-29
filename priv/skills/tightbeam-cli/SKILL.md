---
name: tightbeam-cli
description: Operate an existing Tightbeam organization through its current-line CLI. Use when an external agent must inspect or direct the organization on a user's behalf without a served Tightbeam identity.
---

# Operate Tightbeam through the CLI

Direct the organization for the user. Do not take over the product owner's work.
Use Tightbeam as the durable record and coordination layer. Run only operations that
the user authorizes.

## Ground the records

Use these meanings consistently:

- **Tightbeam:** the service that coordinates agent sessions for a human owner and keeps
  work, obligations, communication, and evidence in durable rows.
- **Work item:** the durable thread for one feature or bug.
- **Assignment:** an obligation on that work held by a session.
- **Card:** a work item that is staffed and moving, in the kanban sense.
- **Session:** one running or retained agent identity with a Tightbeam session key and an
  owner. One work item can carry several assignments. One assignment names one obligation
  held by one session.
- **Product owner:** the agent session that owns product routing, assignment, staffing,
  and disposal of completed work.
- **Main:** the owner's general Tightbeam session. A user-targeted wake routes to that
  owner's Main.
- **Wake:** a durable prompt delivered to a user, role, or exact session.
- **Attest:** an attributed progress, completion, surrender, or verdict row on one
  assignment.
- **Artifact:** a pointer to evidence outside the assignment worktree. The pointer records
  location and digest; it does not take custody of the file.
- **Decision request:** a durable question for a named principal. It is not a ruling and
  does not pause work by itself.
- **Kungfu:** a shipped bundle of practiced organizational behavior: guidance, skills,
  rails, rules, and bundle metadata. Do not operate a kungfu bundle from this skill.

Treat every returned `wi_...`, `asg_...`, `art_...`, `att_...`, `dr_...`, `w_...`, role,
user, and session value as a typed identifier. Reuse identifiers from Tightbeam results.
Never invent one.

## Establish authority before action

Before the first operation, run `tightbeam --help`. Run it again when an exact verb or
option matters. The compiled help is the command contract. The CLI writes JSON results to
stdout. A nonzero exit writes the refusal to stderr.

Use the user identity that the person gave you, for example `--as-user <user>`. Never
guess it. The flag attributes the operation to that person; it does not target that person.

Default to read-only inspection. Creating work, waking agents, ruling decisions, or
changing any durable row requires the user's corresponding authority. Never infer mutation
authority from read access or from a record that appears incomplete.

Never read credentials. Do not print, parse, copy, replace, or expose a token or session
credential. Use only the CLI. Never call the gateway directly or write to a Tightbeam
database, identity tree, credential store, or generated projection.

## Read the current organization state

Use the smallest record that answers the question:

```sh
tightbeam list --as-user <user>
tightbeam toplines --as-user <user>
tightbeam work-item-get <work-item-id> --as-user <user>
tightbeam work-item-trace <work-item-id> --as-user <user>
tightbeam assignments --state all --as-user <user>
tightbeam attests <assignment-id> --as-user <user>
tightbeam artifacts --work-item <work-item-id> --as-user <user>
tightbeam decision-requests --status open --as-user <user>
```

Treat completion claims as evidence to inspect, not as status by themselves. Read the
assignment, its attests, and its work-item trace when a decision depends on whether work
is pending. After context loss, repeat this recovery from rows instead of reconstructing
state from chat memory.

## Direct the organization; do not run it

You may file a work item when a durable statement of need helps:

```sh
tightbeam work-item-create --title "<outcome>" --as-user <user>
```

Then ask a product-owner session to assign and staff it. Use the exact role or session that
the user or current organization state identifies:

```sh
tightbeam wake --role <product-owner-role> --prompt "Route and staff <work-item-id>." --as-user <user>
```

Assigning and staffing belong to the product owner because parentage is mechanical. An
assignment opened with `--as-user` alone records `openedBySession` as `(none)`. Its holder
can complete correctly, but no parent session receives the completion and no opener must
dispose of the result. The work can silently stop.

The durable specimen is `wi_32ff8f5c`: its strategy assignment completed reviewed-clean,
but the five implementation cards named by the strategy remained uncut for 21 hours. The
external operator had opened the assignment without a parent session, so completion woke
nobody.

Do not run `assign`, `dispatch`, or `spawn` as the external operator. Wake the product
owner with the outcome and the work-item identifier. The product owner opens the assignment
and staffs it, which gives completion a parent and a disposal path.

## Require custody after a plan

A plan is not progress. A document deliverable must name its successor card and confirm
that an agent holds that card. Before reporting the document complete:

1. Read the document's named next action.
2. Read the successor work item and assignment.
3. Confirm that the successor assignment is open and held by a session.
4. Ask the product owner to create or staff the successor when that custody is absent.

Do not treat an unstaffed implementation list as forward motion.

## Present owner decisions

Start with `tightbeam decision-requests --status open --as-user <user>`. Distinguish the
request kinds:

- An `operator` request asks for an owner choice. Inspect its linked assignment and attests.
  Present its exact options, consequences, and current evidence. Do not choose for the user.
- An `effort` request is an automated zero-effect check-in. Use
  `tightbeam effort-rule --request <decision-request-id> --action continue|dismiss
  --as-user <user>` only after the user chooses that action.

Main and presenting proxies never run `tightbeam operator-rule`. Return the user's exact
choice together with the decision-request identifier. A non-presenting relay may record the
choice only after the operator gives an explicit instruction that names that identifier.

## Record only authorized results

When the user authorizes an assignment record, use
`tightbeam attest <assignment-id> --kind <kind> --note "<evidence>" --as-user <user>`.
Use `tightbeam artifact-record` only for a deliberate pointer to evidence outside the
assignment worktree. Never claim an effect that the returned result and durable rows do
not show.

## Stop on visible failure

Stop on a nonzero exit, malformed JSON, authentication failure, version refusal, gateway
unavailability, or any named refusal that blocks the requested effect. Report the exact
error code and message with secrets removed. Never bypass the refusal through another
identity, transport, database, or hand edit.

Treat `decision_pending` as a halted operation with its returned decision request still
open. Do not claim that the requested effect happened.

Do not retry a mutation unless durable rows prove it did not happen or the command has a
documented idempotency key. Never expose secrets in prompts, command arguments, prose,
logs, transcripts, committed files, or artifact descriptions.
