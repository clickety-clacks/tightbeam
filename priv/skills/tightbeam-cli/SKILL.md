---
name: tightbeam-cli
description: Work an assigned Tightbeam card through the tightbeam CLI. Use when an external agent holds a Tightbeam session credential in its worktree and must read its assignment, record results, ask its owner for decisions, or contact Main without a served Tightbeam identity.
---

# Work an assigned card through the Tightbeam CLI

Written for Tightbeam 0.1.15. Check `tightbeam --version` and command help against this
edition. If they differ, ask Main which edition applies before using the affected
operation. `tightbeam skill install` copies the installed CLI's bundled edition; do not
use it to overwrite a separately supplied reviewed skill without checking that choice.

Use Tightbeam as the record and coordination layer for the assignment. Run only the
operations that the assignment authorizes. Ask Main to perform broader organization work.
Main is the root session of the human who owns the work.

## Records

A work item is the outcome; an assignment is one session's obligation on it.
Attests record progress, judgments and completion; artifacts point to evidence.
Wakes deliver addressed prompts and decisions ask a named principal for judgment.
Use returned typed identifiers exactly; do not invent them. These records preserve
custody across lost context; recover from them before acting.

## Harklight follows

When the installed Tightbeam release includes `harklight-follow`, use `tightbeam
harklight-follow --message <id>` or `tightbeam harklight-follow --handle <handle>` to
receive wakes about another session's Tightbeam-sent message or conversation. Only
messages and conversations sent through `tightbeam harklight-send` can be followed.
A follow ends when the conversation is finished, or when its message is retracted or
superseded. Replies stay on raw `harklight-agent` commands.

## Start from the assignment

Run the CLI from the assignment worktree. Let it discover the nearest
`.tightbeam-session`. Do not print, parse, copy, replace, or commit that credential.
`tightbeam identity current` prints this session's key without the credential.

Before the first operation in a session, run `tightbeam --help`. Run it again whenever
you need command or flag syntax; `tightbeam help <command>` prints one command's entry.
The `tightbeam` executable writes JSON results to stdout. A nonzero exit writes the
failure to stderr.

Omit `--as`, `--as-user`, and `--as-process`; the gateway derives the authenticated
session principal from the credential whether the session holds zero, one, or several
roles. A role binding is not a prerequisite, and an attribution flag does not change
that principal or grant assignment authority. If authentication or identity resolution
fails, preserve the refusal and ask the owner or Main through the assignment's
non-Tightbeam contact channel. Do not guess a role, bind one, replace the credential, or
use `--as-user` to work around a refusal.

Recover the card in this order:

1. Take the assignment and work-item identifiers from the wake.
2. If either is absent, use `tightbeam assignments` to inspect visible open obligations.
   Stop and ask Main when more than one card could be intended.
3. Use `tightbeam work-item-get <work-item-id>` and read its returned assignments.
4. Use `tightbeam attests <assignment-id>` and `tightbeam artifacts --work-item
   <work-item-id>` to read the evidence already on record.
5. Use `tightbeam assignment-get <assignment-id>` when you need the assignment's current
   state or an open cannot-proceed block.
6. Use `tightbeam work-item-trace <work-item-id>` when you need the full durable timeline.
7. Use `tightbeam list` only to inspect the visible organization and current session
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

Discover mechanics from `tightbeam --help`. Do not guess a command, flag, model, role,
session, target, record shape, or identifier.

## External harness limits

The session credential authenticates CLI calls to the gateway; this skill supplies
instructions. Neither installs tool hooks or establishes that an externally started
Codex or Claude session has Tightbeam's managed harness wiring. Gateway rules still
apply to CLI requests, but do not intercept shell or other tool actions that bypass
the gateway. Tightbeam's managed harness hooks are a separate mechanism: command
matching can prevent covered mistakes, but is not a sandbox. Do not infer local tool
enforcement from a credential, an installed skill, or managed-harness support. If the
assignment depends on a fence whose wiring has not been established for this session,
ask Main to resolve that dependency before the affected action.

## Record the result

Use `tightbeam attest <assignment-id> --kind ... --note "..."` for the assignment result:

- File `progress` only for a new material result, exact refusal, or bounded checkpoint.
- File `completion` when the promised output exists, with the required evidence. Under
  the supported `completion-requires-review` remedy, the report can be recorded while
  the assignment stays open pending review and the accountable owner is notified. Read
  the returned assignment state: a recorded completion is not proof of closure. A
  qualifying clean review can close it later; address requested changes. Other refusals
  still require their named remedy; do not treat every refusal as pending review.
- File `cannot-proceed` with the exact reason when the obligation cannot move under current
  authority. The card stays open, you retain custody, and one decision routes to its
  opener. Do not file it merely because an accepted completion is pending review.
- File a `verdict` only when the assignment authorizes that review judgment. A verdict note
  is capped at 2,000 characters; record a longer judgment as an artifact and cite it.

A standing `cannot-proceed` blocks completion. Its configured release fact must match
kind, scope and principal, or the block must settle through a supported disposition,
such as an accepted `answer` on its decision request, opener revocation, or qualifying
review closure of an already recorded completion. A chat reply, wake, or `cleared`
verdict alone does not settle it. Read `assignment-get` and its `cannotProceed` state
before resuming; settlement does not prove the promised work is done. When specifying
a release fact, supply all three `--release-fact-*` flags from command help together,
using the existing fact contract; ask Main if that contract is unknown.

Name the operation, observed result, relevant identifiers, and non-secret evidence. Do not
claim success from process output alone when the durable row should show the effect. Read
the assignment again after a mutation when the effect matters. Pass `--commit-refs` when
the result is a commit that the record must name.

Use `tightbeam artifact-record` when required evidence lives outside the assignment
worktree. Record the evidence kind, title, absolute host path, work-item identifier, and
SHA-256 digest; add `--produced-by-assignment <assignment-id>` when this assignment
produced it. Keep the file in the custody location that the assignment requires. Use
`tightbeam artifacts` to recover its pointer later.

Keep tokens and session-file contents out of prose, stdout, stderr, transcripts, committed
files, artifact descriptions, process arguments, and request data.

## Contact Main and request decisions

Read the owner's exact user identifier from `workItem.ownerUserId`. Use that value with a
user-targeted `tightbeam wake` when Main must act. Include the work-item and assignment
identifiers and one bounded request. Do not infer the owner from `tightbeam list`.

Target another agent by role when its office should answer. Target a session only when that
exact session incarnation matters. A wake carries a prompt; it is not an empty notification.
Send a wake only when no record already carries the fact to the recipient; every wake costs
its recipient a turn. `--class` labels urgency for the recipient's batch; it does not make
the recipient run sooner. When your instruction to an assignment's holder changes, send the
correction with `--assignment <assignment-id> --replace-queued`, or withdraw a pending wake
with `tightbeam cancel-wake <wake-id>`.

Use `tightbeam operator-ask --question "..." --note "..." --assignment <assignment-id>`
when work needs an owner decision:
the question contains everything needed to understand the choice; the note holds
supporting technical detail and references. For example, substitute the actual
assignment and supporting references in this illustrative product choice:

```sh
tightbeam operator-ask \
  --assignment '<assignment-id>' \
  --question 'Garden Planner helps households schedule garden work. Weather alerts are ready, but sending them by email would cost ten dollars per month. Should we add email alerts at that cost, or keep alerts inside the app at no extra cost? I recommend keeping them in the app until users ask for email. Email would reach people while the app is closed; in-app alerts appear when they open it. While you decide, the existing garden schedule remains available and email delivery stays off.' \
  --note 'Email delivery would use an external delivery service; in-app alerts use the existing notification store. Supporting evaluation: <evaluation-report>. Cost estimate: <cost-estimate>.'
```

The CLI derives the owner from this session and returns a `dr_...`
identifier for the durable decision request. Use `tightbeam decision-requests` to read its
answer. Do not bury a decision need in an attest or poll a human.

## Wait on the real boundary

Choose the wait instrument by what can observe the event:

1. For an in-organization row, subscribe with a condition wake that names the existing fact
   kind and scope (`--when-fact <kind> --when-scope <scope>`), or a dependency wait
   (`--assignment <assignment-id> --predicate '<JSON>'`). Supply a fallback; three hours
   (`--fallback-after 3h`) is the usual default. Do not poll the row on a timer. Ask Main
   when no established fact names the event.
2. For an external system that Tightbeam cannot observe, schedule a timed wake to this
   session with the exact probe to run. Record each probe result. After three unchanged
   probes, report the stuck boundary to the assignment opener.
3. For a human answer, use a decision request. Do not schedule a human poll.
4. To resume your own work, wake this session: `--after-turn` continues as soon as the
   current turn ends, and `--after <duration>` resumes at a chosen time.

Before a turn ends with the assignment open, leave one valid liveness receipt: a material
progress row, a bounded checkpoint, a completion, a cannot-proceed filing, or a concrete continuation
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
