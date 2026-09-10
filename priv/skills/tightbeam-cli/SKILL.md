---
name: tightbeam-cli
description: Operate an existing Tightbeam organization through its current-line CLI. Use when an external agent has the tightbeam executable and must read assigned work, record results, or contact Main without a served Tightbeam identity.
---

# Operate Tightbeam through the CLI

Use Tightbeam as the record and coordination layer for the assignment. Run only the
operations that the assignment authorizes. Ask Main to perform broader organization work.

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
- **Main:** the owner's general Tightbeam session. A user-targeted wake routes to that
  owner's Main.
- **Wake:** a durable prompt delivered now, later, or when a named condition fact arrives.
- **Attest:** an attributed progress, completion, surrender, or review-verdict row on one
  assignment.
- **Artifact:** a pointer to evidence outside the assignment worktree. The pointer records
  location and digest; it does not take custody of the file.
- **Decision request:** a durable question for a named principal. It is not a ruling and
  does not pause the assignment by itself.
- **Condition fact:** an observable event that can release a subscribed wake.
- **Kungfu:** a shipped bundle of practiced organizational behavior: guidance, skills,
  rails, rules, and bundle metadata. Do not operate a kungfu bundle from this skill.

Treat every returned `wi_...`, `asg_...`, `art_...`, `att_...`, `dr_...`, `w_...`, role,
user, and session value as a typed identifier. Reuse identifiers from the assignment wake
or Tightbeam results. Never invent one.

## Start from the assignment

Run the CLI from the assignment worktree. Let it discover the nearest
`.tightbeam-session`. Do not print, parse, copy, replace, or commit that credential.

Before the first operation in a session, run `tightbeam --help`. Run it again whenever
you need command or flag syntax. The `tightbeam` executable writes JSON results to stdout.
A nonzero exit writes the failure to stderr.

Use a session credential whose session holds exactly one role. Omit `--as`, `--as-user`,
and `--as-process`; the CLI and gateway derive the session principal and its one role. If
the gateway returns `no_role` or `ambiguous_identity`, stop. Use the assignment's
non-Tightbeam contact channel to ask the owner or Main for a correctly provisioned
single-role session credential. Do not guess a role, bind a role, change identity, or
follow a refusal's suggestion to use `--as-user`.

Recover the card in this order:

1. Take the assignment and work-item identifiers from the wake.
2. If either is absent, use `tightbeam assignments` to inspect visible open obligations.
   Stop and ask Main when more than one card could be intended.
3. Use `tightbeam work-item-get <work-item-id>` and read its returned assignments.
4. Use `tightbeam attests <assignment-id>` and `tightbeam artifacts --work-item
   <work-item-id>` to read the evidence already on record.
5. Use `tightbeam work-item-trace <work-item-id>` when you need the full durable timeline.
6. Use `tightbeam list` only to inspect the visible organization and current session
   context. Do not derive the owner from it. Read `workItem.ownerUserId` from the named
   `work-item-get` result.

After context loss, repeat this recovery from rows. Do not reconstruct state from chat
memory.

## Perform only the obligation

Read the assignment subject, its attests, the work item, and the named artifacts before
acting. Keep every action inside the assigned outcome and the authority of this session.
Preserve unrelated repository changes and external files.

Do not create or route new work unless the assignment grants coordination authority. Send
new scope to Main with the current work-item and assignment identifiers. Delegate session
spawning and retirement, identity and configuration changes, credential work, kungfu
operation, target choice, integration, merge, release, deployment, and live administration
to Main unless the assignment grants that exact operation.

you should probably get main to do what you need it to instead of trying to do it yourself since main knows how to operate tightbeam.

Discover mechanics from `tightbeam --help`. Do not guess a command, flag, model, role,
session, target, record shape, or identifier.

## Record the result

Use `tightbeam attest <assignment-id> --kind ... --note "..."` for the assignment result:

- File `progress` only for a new material result, exact refusal, or bounded checkpoint.
- File `completion` only when the obligation is complete and its required gates allow the
  assignment to close.
- File `surrender` when the obligation cannot be completed under the current authority.
- File a `verdict` only when the assignment authorizes that review judgment.

Name the operation, observed result, relevant identifiers, and non-secret evidence. Do not
claim success from process output alone when the durable row should show the effect. Read
the assignment again after a mutation when the effect matters.

Use `tightbeam artifact-record` when required evidence lives outside the assignment
worktree. Record the evidence kind, title, absolute host path, work-item identifier, and
SHA-256 digest. Keep the file in the custody location that the assignment requires. Use
`tightbeam artifacts` to recover its pointer later.

Keep tokens and session-file contents out of prose, stdout, stderr, transcripts, committed
files, artifact descriptions, process arguments, and request data.

## Contact Main and request decisions

Read the owner's exact user identifier from `workItem.ownerUserId`. Use that value with a
user-targeted `tightbeam wake` when Main must act. Include the work-item and assignment
identifiers and one bounded request. Do not infer the owner from `tightbeam list`.

Target another agent by role when its office should answer. Target a session only when that
exact session incarnation matters. A wake carries a prompt; it is not an empty notification.

Use `tightbeam operator-ask --question "..." --assignment <assignment-id>` when work needs
an owner decision. The CLI derives the owner from this session and returns a `dr_...`
identifier for the durable decision request. Use `tightbeam decision-requests` to read its
answer. Do not bury a decision need in an attest or poll a human.

## Wait on the real boundary

Choose the wait instrument by what can observe the event:

1. For an in-organization row, subscribe with a condition wake that names the existing fact
   kind and scope. Supply a fallback. Do not poll the row on a timer. Ask Main when no
   established fact names the event.
2. For an external system that Tightbeam cannot observe, schedule a timed wake to this
   session with the exact probe to run. Record each probe result. After three unchanged
   probes, report the stuck boundary to the assignment opener.
3. For a human answer, use a decision request. Do not schedule a human poll.
4. To resume your own work at a chosen time, schedule a timed wake to this session.

Before a turn ends with the assignment open, leave one valid liveness receipt: a material
progress row, a bounded checkpoint, a completion, a surrender, or a concrete continuation
wake. Do not file empty status prose.

## Stop on visible failure

Stop on a nonzero CLI exit, malformed JSON, authentication failure, version refusal,
gateway unavailability, `no_role`, `ambiguous_identity`, or any named refusal that blocks
the requested effect. Treat `decision_pending` as a halted operation with the returned
decision request still open; do not claim the requested effect. Preserve the error code and
message with secrets removed. Do not retry a mutation unless the durable rows prove it did
not happen or the operation has a documented idempotency key.

Never write directly to a Tightbeam database, identity tree, credential store, or generated
projection. Never claim an effect that the returned result and durable rows do not show.
