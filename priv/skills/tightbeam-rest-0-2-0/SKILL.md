---
name: tightbeam-rest-0-2-0
description: Operate an existing Tightbeam 0.2.0 organization through its authenticated HTTP dispatch interface. Use when an external agent must read assigned work, record results, or contact Main without invoking the Tightbeam CLI.
---

# Operate Tightbeam through REST 0.2.0

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
- **Attest:** an attributed progress, completion, cannot-proceed, or review-verdict row on one
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

## Establish the compatible endpoint

Find the nearest `.tightbeam-session` by walking from the assignment worktree toward the
filesystem root. Read its `token`, `url`, and `sessionKey` in memory. Do not emit the file,
its token, or an authorization header.

Normalize only the URL scheme:

- Convert a leading `ws://` to `http://`.
- Convert a leading `wss://` to `https://`.
- Preserve a leading `http://` or `https://`.

Send an unauthenticated `GET /version` to the normalized gateway URL. Continue only when
the response contains `protocolVersion: 1` and `version: "0.2.0"`. Stop and report version
skew or a malformed response.

Use a session credential whose session holds exactly one role. Omit `as`, `asUser`, and
`asProcess`; the gateway derives the session principal and its one role. If the gateway
returns `no_role` or `ambiguous_identity`, stop. Use the assignment's non-Tightbeam contact
channel to ask the owner or Main for a correctly provisioned single-role session
credential. Do not guess a role, bind a role, change identity, or follow a refusal's
suggestion to use `asUser`.

## Send authenticated dispatch requests

Send each operation to `POST /agent/dispatch` with these headers:

```text
Authorization: Bearer <session token>
Content-Type: application/json
x-tightbeam-cli-version: 0.2.0
```

Construct the secret header in memory. Configure the HTTP tool not to emit request headers.
Never put the token in body JSON, prose, stdout, stderr, transcripts, committed files,
artifact descriptions, or process arguments.

Use these exact request shapes. Substitute values from the assignment wake, source files,
or prior Tightbeam results:

```json
{"verb":"inspect","params":{}}
{"verb":"assignments","params":{"state":"open"}}
{"verb":"work-item-get","params":{"workItemId":"wi_example"}}
{"verb":"work-item-trace","params":{"workItemId":"wi_example"}}
{"verb":"attests","params":{"assignmentId":"asg_example"}}
{"verb":"artifacts","params":{"workItemId":"wi_example"}}
{"verb":"attest","params":{"assignmentId":"asg_example","kind":"progress","note":"material result"}}
{"verb":"artifact-record","params":{"kind":"report","title":"result evidence","originPath":"host:/absolute/path","workItemId":"wi_example","contentSha256":"0000000000000000000000000000000000000000000000000000000000000000"}}
{"verb":"wake","userId":"owner-id","params":{"prompt":"Main action requested with the assignment and work-item ids"}}
{"verb":"ask","userId":"owner-id","params":{"question":"decision needed and what depends on it","assignmentId":"asg_example"}}
{"verb":"wake","sessionKey":"current-session-key","params":{"prompt":"re-read the named row and continue","afterMs":7200000,"conditionKind":"existing-fact-kind","conditionScope":"existing-fact-scope"}}
{"verb":"wake","sessionKey":"current-session-key","params":{"prompt":"probe the named external system and record the result","afterMs":1200000}}
```

Treat `wi_example`, `asg_example`, `owner-id`, `current-session-key`, the fact names, note,
prompt, question, path, title, and digest as placeholders. Obtain `owner-id` specifically
from `workItem.ownerUserId` in the named work item's `work-item-get` result. Obtain
`current-session-key` from the in-memory session credential. Do not invent record
identifiers or fact names.

Ask Main when you need a verb or parameter shape that this skill does not list. Do not
guess a route, request shape, private endpoint, or principal override.

## Recover and perform the assignment

Recover the card in this order:

1. Take the assignment and work-item identifiers from the wake.
2. If either is absent, inspect visible open assignments. Stop and ask Main through the
   assignment's non-Tightbeam contact channel when more than one card could be intended.
3. Read the named work item, its returned assignments, the assignment attests, and the
   work-item artifacts.
4. Read the work-item trace when you need the full durable timeline.
5. Read the visible organization only for session context. Do not derive the owner from it.
   Read `workItem.ownerUserId` from the named work-item result.

After context loss, repeat this recovery from rows. Do not reconstruct state from chat
memory.

Read the assignment subject and existing evidence before acting. Keep every action inside
the assigned outcome and the authority of this session. Preserve unrelated repository
changes and external files.

Do not create or route new work unless the assignment grants coordination authority. Send
new scope to Main with the current work-item and assignment identifiers. Delegate session
spawning and retirement, identity and configuration changes, credential work, kungfu
operation, target choice, integration, merge, release, deployment, and live administration
to Main unless the assignment grants that exact operation.

you should probably get main to do what you need it to instead of trying to do it yourself since main knows how to operate tightbeam.

## Record the result

Use the `attest` request for the assignment result. Set `kind` to `progress` only for a new
material result, exact refusal, or bounded checkpoint. Use `completion` only when the
obligation is complete and its gates allow closure. Use `cannot-proceed` with the exact reason
when the obligation cannot move under current authority; the card stays open and routes one
decision to its opener. Use `verdict` only when the assignment grants
that review judgment.

Name the operation, observed result, relevant identifiers, and non-secret evidence. Do not
claim success from an HTTP status alone when the durable row should show the effect. Read
the assignment again after a mutation when the effect matters.

Use `artifact-record` when required evidence lives outside the assignment worktree. Record
the evidence kind, title, absolute host path, work-item identifier, and SHA-256 digest. Keep
the file in the custody location that the assignment requires. The artifact row is a
pointer, not custody.

## Contact Main, decide, and wait

Read the owner's exact user identifier from `workItem.ownerUserId`. Use the user-targeted
`wake` request when Main must act. Include the work-item and assignment identifiers and one
bounded request. Ask Main to contact another agent by role or exact session because this
edition does not list those typed target shapes.

Use the `ask` request when work needs an owner decision. The returned `dr_...` identifies
the durable decision request. Ask Main to read or withdraw the request when this skill lacks
the required request shape. Do not bury a decision need in an attest or poll a human.

Choose the wait instrument by what can observe the event:

1. For an in-organization row, send a condition wake to this session with an existing fact
   kind and scope plus a fallback. Do not poll the row on a timer. Ask Main when no
   established fact names the event.
2. For an external system that Tightbeam cannot observe, send a timed wake to this session
   with the exact probe to run. Record each probe result. After three unchanged probes,
   report the stuck boundary to the assignment opener.
3. For a human answer, use a decision request. Do not schedule a human poll.
4. To resume your own work at a chosen time, send a timed wake to this session.

Before a turn ends with the assignment open, leave one valid liveness receipt: a material
progress row, a bounded checkpoint, a completion, a cannot-proceed filing, or a concrete continuation
wake. Do not file empty status prose.

## Classify every response

Treat the HTTP envelope, not its prose, as the operation boundary:

- A 200 response with `result` is the operation result.
- A 202 response with `decisionPending` means the operation halted and its named decision
  request remains open. Record or report that boundary. Do not claim the requested effect.
- A non-2xx response with `error.code` is a named refusal or fault. Preserve the code and
  message with secrets removed.
- Any other response is malformed. Stop and report the raw envelope after removing the
  credential and authorization header.

Stop on transport failure, authentication failure, version refusal, gateway unavailability,
`no_role`, `ambiguous_identity`, or any named refusal that blocks the requested effect. Do
not replay a mutation unless the durable rows prove it did not happen or the request uses a
documented idempotency key.

Never write directly to a Tightbeam database, identity tree, credential store, or generated
projection. Never claim an effect that the returned result and durable rows do not show.
