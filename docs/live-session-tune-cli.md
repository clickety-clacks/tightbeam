# Live-session tune CLI

Status: implementation authority for `wi_6435c199-16aa-480e-8381-4c471e2ed35a`.
This revision supersedes commits `f031a51e84579d23daa25aea201974b9be007847`,
`413ea350d54375912e0b97ab3cbb794d215badfa`, and
`4cef7773c1bafd9339cf5f23a8881dccca16b42f`, plus consolidated commit
`057a4940d468e82ddd8e09e75175a1fbf6dd26a4` and their authority addenda, where
they conflict. This revision removes assumptions about lifecycle mechanisms that the
repository does not contain.

## Spirit

An owner or administrator can deliberately change one runtime control on an active
Tightbeam session through the supported CLI. The Tightbeam session keeps its identity,
roles, work, lineage, and graph position. The command reports only state that the live
harness accepted, or a named failure that states what Tightbeam knows.

Correctness, security, reliability, and observability are hard requirements. A slower
verified change is preferable to an unverified success. Compatibility covers the live
installed adapter versions captured by the reality gate. This slice does not optimize
throughput or generalize unrelated model-selection code.

## Goal

The supported `tune` command changes one requested runtime control on an existing
Tightbeam session while preserving its durable identity and relationships.

Success has four observable outcomes:

1. The operator can change the harness, model, thinking effort, or Fast setting.
2. The operator can tell whether the runtime changed and whether Tightbeam stored the
   verified projection.
3. A cross-harness change keeps the source engine active until a verified destination
   replaces it.
4. Authorization, turn ordering, and non-identifying refusals remain intact.

## Non-Goals

- Automatic fallback, host movement, role rebinding, succession, or broad picker work.
- Conversation continuity across different harnesses.
- Fast persistence across adapter or gateway restart.
- Fast retention across a model or harness change.
- A rollback engine for an in-place runtime change.
- Static catalog guesses about live harness capabilities.

## Invariants

1. One invocation changes one control dimension.
2. The live harness owns runtime vocabulary. Exact readback owns success.
3. The session key and every substrate relationship survive each successful change.
4. Authorization occurs before target existence, readiness, or mutation becomes visible.
5. A queued or running turn prevents mutation.
6. A cross-harness database commit never occurs before destination verification.
7. A failure never claims that the prior runtime remains active after an in-place change
   may have reached the harness.
8. Fast uses the live option advertised by the resident adapter and has no stored intent.
9. A possible unverified model mutation makes the stored projection durably non-authoritative
   before another turn, status response, or tune can use it.
10. Every managed-runtime cleanup attempt has one durable owner, cause, principal, deadline,
    and retry identity before Tightbeam can lose the runtime reference.

## Terms

- **Tightbeam session**: the durable session key and its substrate relationships.
- **Engine context**: one harness's private conversation state behind that key.
- **Runtime configuration**: the model, context variant, effort, and live Fast value
  reported by the resident harness.
- **Stored projection**: Tightbeam's database fields that describe verified runtime
  state.
- **Runtime verification state**: the durable `verified`, `mutating`, or `unknown` marker,
  cause, principal, and update time that state whether the stored model projection is
  authoritative and why it changed.
- **Candidate runtime**: a destination harness session prepared before a cross-harness
  swap.
- **Cleanup obligation**: a durable record that owns closure of one candidate or superseded
  harness session until closure is verified or operator action is required.
- **Control fence**: the existing per-session lane boundary while a tune operation
  checks queued work and mutates runtime state.
- **Eligible catalog snapshot**: a prior live catalog result for the same host, harness,
  adapter version, and credential scope that contains the exact requested model row.

## Assumptions

1. The same-harness switch or fork path can return exact live model and effort readback.
2. A candidate session id is available after successful external creation, and a source
   session id is known before the database swaps the current pointer.
3. The gateway can report a verified runtime value when a later projection commit fails.
4. Each resident adapter can identify a live-advertised Fast option and map its advertised
   values to Tightbeam `on` and `off` without a fixed harness-name table in the gateway.
5. The session lane can hold a control fence while it inspects durable queued work.

If code or live smoke disproves an assumption, the producer pauses and files the exact
evidence. The producer does not invent a second lifecycle, queue, or rollback mechanism.

## Architecture

### Subtraction rulings

- Keep the native gateway `tune` verb. Deleting it loses the supported operator surface;
  accepting client-only control would split authority.
- Add no rollback engine. Context preservation requires in-place writes, so one durable
  verification marker and exact recovery are smaller and more honest. Deleting in-place
  changes loses same-harness context; accepting an old stored projection would lie.
- Use the existing session lane for ordering. Deleting queued-work protection lets tune
  jump ahead of filed work; accepting that race violates the session contract.
- Add one durable cleanup-obligation seam because no existing component owns candidate or
  superseded harness sessions. Deleting cross-harness replacement misses the requested
  harness outcome; accepting an unmanaged leak violates reliability and observability.
- Translate only a live-advertised Fast option at the adapter boundary. Deleting Fast
  misses the requested outcome; accepting one fixed id lies on the other harness.

### Supported command

The public verb is `tune`:

```text
tightbeam tune --session <key> --harness <harness> --model <model>
               [--effort <level>] [--context <variant>]

tightbeam tune --session <key> --model <model>
               [--effort <level>] [--context <variant>]

tightbeam tune --session <key> --effort <level>

tightbeam tune --session <key> --fast on|off
```

The normal identity flags apply: `--as <role>` and `--as-user <id>`. Session credential
discovery applies when the caller omits an identity flag.

One invocation changes one control dimension. A model's `model`, `effort`, and `context`
fields form one dimension. A harness change includes its destination model. Fast is a
separate dimension. The CLI parser refuses invalid combinations before network I/O.

The parser rules are:

1. `--session` is required and targets one exact active session key.
2. `--harness` requires `--model`. It may include `--effort` and `--context`.
3. `--model` may include `--effort` and `--context`.
4. `--effort` may appear alone and applies to the current model.
5. `--context` never appears without `--model`.
6. `--fast` accepts only `on` or `off` and is mutually exclusive with all model fields.
7. The CLI does not accept packed `model[effort]` syntax.
8. At least one control is required. Unknown flags and empty required values are usage
   errors.

If `--harness` names the current harness, the gateway returns `same_harness`. The operator
uses the same-harness model form without `--harness`. This refusal avoids ambiguous engine
context and creates no pointer, barrier, or tombstone.

### Field meanings

- `--model` selects the vendor model family.
- `--context` selects the vendor context-window variant. Omission selects the issuing
  catalog row's default variant for a newly named model.
- `--effort` is Tightbeam's name for the thinking or reasoning level. The adapter
  translates it to the harness-owned config option.
- `--fast` is Tightbeam's harness-neutral on/off control. The resident adapter normalizes
  the live advertised Fast capability. The current Claude adapter maps `fast`; the current
  Codex adapter maps `fast-mode`. The gateway never guesses an option id from the harness
  name and never stores Fast as a model, effort, catalog, or durable intent field.

### Authority and privacy seam

The gateway resolves the caller before it probes or mutates the target. The caller's user
must own the target session, or the caller must be an administrator. A process identity
cannot tune a session.

For `tune`, `/agent/dispatch` parses the typed target but defers session-key resolution to
the gateway authorization seam. Unknown and foreign targets therefore return the same
byte-equivalent, non-identifying `not_found` result. Other verbs keep their current router
behavior.

### Turn boundary

The tune operation acquires the existing per-session lane as its control fence. While it
holds that fence, it checks both the active task reference and the durable queued-turn
ledger. Either condition returns `turn_in_progress` without waiting or mutation. The fence
is the linearization point: a turn queued after acquisition waits for the accepted tune;
a turn filed before acquisition causes refusal. Tune does not add a second queue or lock.

### Model and effort inside one harness

The gateway resolves the request against the target host and resident harness. A degraded
attempt is permitted only from an eligible catalog snapshot. Live apply and readback still
decide the outcome.

Before the first external write, one database transaction changes the session's runtime
verification state from `verified` to `mutating`. A gateway or adapter restart treats a
persisted `mutating` value as `unknown`; process memory is never the marker. If the harness
refuses before any field can change, the gateway restores `verified` without changing the
stored projection.

The session row stores `runtimeConfigState`, `runtimeConfigCause`,
`runtimeConfigPrincipal`, and `runtimeConfigUpdatedAt`. Existing rows migrate to
`verified`. Every state transition writes all four fields together. The cause identifies
the tune operation or recovery attempt. The principal identifies the authorized caller or
the startup reconciler.

The adapter applies the model fields through the existing context-preserving path and then
reads the complete runtime configuration. If readback exactly matches, one transaction
commits the stored projection and `verified`. If a field applied but the verified
configuration differs from the request, that transaction reconciles the projection to the
verified configuration and marks it `verified`; the command returns nonzero
`runtime_config_mismatch` with those values. It does not claim the prior runtime. If that
reconciliation transaction fails, the durable state remains `unknown` and the command
returns `runtime_projection_failed` with the verified active configuration.

If exact readback fails after mutation may have started, the gateway returns nonzero
`runtime_config_unknown`. It durably changes `mutating` to `unknown`. The stored model,
context, effort, and provider fields remain historical values and no response presents them
as active.

A turn, status request, or later tune that sees `mutating` or `unknown` enters recovery
before it pushes stored model fields or reports them. Recovery loads the existing harness
session without applying the stored projection, reads the complete live configuration, and
commits the verified actual projection plus `verified`. If exact recovery readback is not
available, status reports `runtimeConfigStatus: "unknown"` with actual model fields `null`,
and a turn or tune refuses with `runtime_config_unknown`. Restart cannot reassert the stale
stored projection.

If exact readback succeeds but the projection commit fails, the gateway returns nonzero
`runtime_projection_failed`. It includes the verified active configuration and
`projectionCommitted: false`, while the durable verification state remains non-authoritative
as `mutating` or `unknown`. Both values enter the same recovery path. Repeating the request
runs recovery and retries the projection commit. Tightbeam adds no automatic rollback.

An idempotent same-harness request first reads the runtime. If it already matches, the
gateway reconciles a stale stored projection if necessary and returns success with
`engineContext: "preserved"`. It creates no pointer, barrier, or tombstone.

### Harness replacement

The gateway validates the destination credential, host readiness, harness, model, context,
and effort before it changes the session row or history barrier. Before external candidate
creation, it inserts one cleanup obligation in `creating` state with the operation id,
target session key, destination harness and host, caller principal, cause, creation time,
and a 24-hour deadline. The external session id starts as null. The gateway creates the
candidate, immediately stores its returned session id, applies the requested fields, and
verifies the complete live readback. Only then does one database transaction change the
harness, provider, model fields, runtime verification state, pointer, visible-history
barrier, and swap tombstone, and marks the candidate obligation `adopted`.

If the process stops after external creation but before it records the returned session id,
startup reconciliation changes the `creating` obligation to `unidentified` and requires
operator action. It never retries candidate creation from that row. This named state accepts
the external atomicity limit without pretending that Tightbeam can close an unidentified
runtime.

A pre-commit failure keeps the source runtime active and requests candidate teardown. The
gateway verifies teardown. If teardown cannot be verified, it returns
`destination_cleanup_failed`, reports the source as active, and leaves the candidate
obligation `pending`.

After a successful commit, the destination runtime is active. That same transaction inserts
the superseded source's `pending` cleanup obligation with its known session id. Tightbeam
then closes the source and verifies closure. If closure cannot be verified, the command
returns nonzero `source_cleanup_failed`, reports the destination as active, and leaves the
source obligation pending.

One supervised runtime-cleanup worker owns pending obligations after the command returns and
after restart. It retries immediately, then after 1 minute, 5 minutes, 30 minutes, and hourly
until the 24-hour deadline. The row stores the attempt count, next attempt, last error, and
updated time. At the deadline it becomes `manual_required`; Tightbeam does not delete it.
An active-row uniqueness constraint on the harness session id deduplicates retries. Before
each close, the worker checks the current pointer in the same claim transaction. It marks a
runtime that became current as `adopted` and never closes it. A successful close marks the
row `closed` and records the verification time. Session status exposes pending,
unidentified, and manual-required obligations without raw harness errors.

The cleanup table stores `id`, `operationId`, `targetSessionKey`, `kind`, `harness`, `host`,
nullable `harnessSessionId`, `state`, `principal`, `cause`, `deadlineAt`, `attemptCount`,
`nextAttemptAt`, `lastError`, `createdAt`, and `updatedAt`. `kind` is `candidate` or
`superseded_source`. `state` is `creating`, `pending`, `adopted`, `closed`, `unidentified`,
or `manual_required`. Session status returns `runtimeCleanup.obligations` with only each
obligation's id, kind, state, deadline, next attempt, and attempt count.

On success, the session key and all substrate relationships remain unchanged. The visible
chat resets at the tombstone because the destination engine has a new private context.
Transcript rows remain available through the transcript command.

### Fast

The resident adapter exposes a canonical Fast control only when its live config response
advertises the adapter's supported Fast option and live values. The gateway sends the value
that the adapter maps from `on` or `off`, then reads the option back. Exact readback owns
success. A missing option returns `fast_unsupported` without a guessed config id.

Fast is intentionally ephemeral. Tightbeam stores no Fast intent and does not reapply it
after adapter or gateway restart. Session status queries the resident adapter. It reports
`fastStatus: "known"` with `fast: "on"|"off"`, `fastStatus: "unsupported"` with `fast: null`,
or `fastStatus: "unknown"` with `fast: null` when live readback is unavailable. A model or
harness change makes no retention promise and reports the live value it can verify.

If readback fails after the Fast write may have started, the gateway returns
`runtime_config_unknown` with `runtimeControl: "fast"` and does not claim the prior Fast
value. This does not change the durable model verification state because Fast has no stored
projection. A verified live value that differs from the request returns
`runtime_config_mismatch` with that value.

### Result

Success exits zero and prints one JSON object built from verified state:

```json
{
  "ok": true,
  "runtimeControl": "model",
  "sessionKey": "agent:coder:auth s_1234",
  "harness": "codex",
  "model": "gpt-5.6-sol",
  "effort": "high",
  "context": null,
  "fast": "on",
  "fastStatus": "known",
  "fastPersistence": "ephemeral",
  "projectionCommitted": true,
  "runtimeConfigStatus": "verified",
  "engineContext": "preserved"
}
```

`engineContext` is `preserved` for same-harness model, effort, and Fast changes. It is
`reset` for a cross-harness change. Failure JSON includes verified actual fields whenever
they are known. `fastPersistence` is always `ephemeral`. `projectionCommitted` is `true`
for model or harness success and `null` for Fast, which has no stored projection. The
response includes `runtimeConfigStatus: "verified"|"unknown"` for model and harness
operations. `runtimeControl` is `model`, `harness`, or `fast`, so control-specific nulls are
unambiguous. Cleanup failures also include `cleanupObligationId`. The response never echoes
an unverified requested value as actual state.

### Stable refusals

Every refusal exits nonzero and prints gateway error JSON. Only codes that state the source
runtime is active may make that claim.

- `not_found`: the session is unknown, retired, or not visible to the caller.
- `turn_in_progress`: a turn was queued or running at the control fence.
- `same_harness`: `--harness` named the resident harness; use `--model` instead.
- `unknown_harness`: the harness name is not registered.
- `host_unready`: the target host cannot run the destination harness.
- `credential_unavailable`: the destination credential is absent or unusable.
- `catalog_unavailable`: no fresh catalog or eligible snapshot can support the attempt.
- `model_unavailable`: the requested model, context, or effort is not offered.
- `model_apply_failed`: the harness refused before any runtime field could change.
- `fast_unsupported`: the resident adapter did not expose an advertised Fast control.
- `runtime_config_mismatch`: verified active fields differ from the request.
- `runtime_config_unknown`: mutation may have occurred and exact live state is unavailable;
  the response identifies `model` or `fast` as the affected control.
- `runtime_projection_failed`: verified runtime is active, but its stored projection failed.
- `session_config_commit_failed`: a staged cross-harness commit failed; source stays active.
- `destination_cleanup_failed`: source stays active; the named candidate obligation is pending.
- `source_cleanup_failed`: destination is active; the named source obligation is pending.

Harness errors become one concise operator sentence. Raw Elixir terms, ACP payload dumps,
and inferred fallback models never reach the user.

### Implementation boundary

The CLI adds one `Tune` command and sends the existing `tune` gateway verb with one of
`set_harness`, `set_model`, `set_reasoning`, or `set_fast_mode`. It does not call the
client-only `/api/session-control` facade.

The gateway uses the existing session lane. The session row gains one runtime verification
state. One cleanup-obligation table and one supervised cleanup worker own candidate and
superseded harness sessions; no other component may retry those closes. The adapter adds one
normalized, verified live-config operation for options the harness advertises. It
normalizes the observed Claude `fast` and Codex `fast-mode` options at the adapter boundary.
No gateway Fast table or global resolver is added.

Session status and tune use the same live runtime readback. The CLI, Clawline, and future
clients do not maintain separate capability guesses. This slice applies the unified model
resolution ruling only at the seams it touches.

## Acceptance

### CLI parser and wire

1. Each supported form produces the exact typed `tune` request with separate model fields.
2. Missing required fields, invalid combinations, packed effort syntax, and no control fail
   before network I/O.
3. Help lists the field meanings, context continuity, Fast behavior, and same-harness rule.
4. Session-file identity, `--as`, and `--as-user` use the ordinary identity path.
5. A gateway refusal exits nonzero and preserves its structured code and message.

### Authorization and ordering

1. The owner and an administrator can tune. Another owner and a process get byte-equivalent
   `not_found` results without readiness or mutation calls.
2. Unknown and retired sessions refuse without revealing existence.
3. An idle lane with a durable queued turn refuses before mutation.
4. A running turn refuses before mutation.
5. A turn queued after the accepted control fence starts only after tune releases the lane.

### Model, effort, and harness

1. Exact model and effort readback commits the exact family, context, effort, and provider.
2. A partial in-place apply returns verified actual state as `runtime_config_mismatch` or
   returns `runtime_config_unknown`; it never claims the prior state.
3. A kill at each boundary from durable `mutating` through readback and projection commit
   proves restart reports or recovers `unknown` without reapplying stored model fields.
4. A projection failure returns `runtime_projection_failed` with actual values. A repeated
   request reconciles the projection without another pointer.
5. A stale catalog attempt requires every eligible-snapshot field. A missing or mismatched
   field returns `catalog_unavailable` before mutation.
6. A same-harness `--harness` refuses without a pointer, barrier, or tombstone.
7. A cross-harness switch verifies a destination before one transaction commits runtime,
   pointer, barrier, and tombstone fields.
8. Candidate teardown failure returns `destination_cleanup_failed` with one durable
   obligation. Superseded source teardown failure returns `source_cleanup_failed` with the
   new runtime reported active and one durable obligation.
9. Restart, retry, dedupe, current-pointer fencing, deadline expiry, and an interrupted
   candidate-id write produce the specified cleanup states without closing a current runtime.
10. A successful cross-harness switch keeps the session key, roles, assignments, work-item
   links, spawn lineage, workdir, identity revision, and overrides.

### Fast

1. Captured real Claude and Codex responses prove each normalized option id, option type,
   and accepted value. Each fixture records the actual harness CLI version, adapter package
   and version, ACP SDK or protocol version, host, and capture time.
2. Fast on and off use the live advertised option and require exact readback.
3. A missing option returns `fast_unsupported` without a guessed config id.
4. Failed readback after a possible write returns `runtime_config_unknown`.
5. Status and tune use one live readback and distinguish known, unsupported, and unknown.
6. Restart tests prove that Tightbeam does not reapply Fast intent. A model change reports
   the post-change live value without a retention assertion.

### Reality gate

Before merge, run the feature-smoke matrix against fresh Claude and Codex sessions with the
installed harness CLI, adapter package, and ACP SDK or protocol versions recorded in each
fixture. Capture the real config responses as fixtures. Prove
same-harness model and effort continuity on both harnesses. Prove Fast on and off on each
advertising harness. Prove both cross-harness directions preserve the Tightbeam session key
and work relationships while resetting only engine context. Prove the next real turn runs
on the accepted runtime. A mocked adapter cannot satisfy this gate.

## Open Questions

None. A disproved assumption reopens this spec before implementation continues.

## Operating Pattern and Specification Homes

- Public CLI and behavior: this document.
- Wire request types: the CLI and gateway source types.
- Live capability evidence: captured real fixtures and the feature-smoke record.
- Architecture principles: `wi_4e1d39f7-0425-4607-bebb-7f81b2f30eb9`.
- Agent operating guidance: no new operating pattern. The command follows the existing
  session-control and assignment practices.

Tests, fixtures, catalogs, and comments are evidence or implementation. They do not override
this product authority.
