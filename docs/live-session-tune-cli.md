# Live-session tune CLI

Status: implementation authority for `wi_6435c199-16aa-480e-8381-4c471e2ed35a`.

## Spirit

An operator must be able to change the engine of an existing Tightbeam session
without replacing the session or moving its work to a successor. The supported
CLI must preserve the session key, roles, assignments, work-item links, spawn
lineage, and graph position. It must report the runtime configuration that the
harness accepted. It must never claim success from a catalog guess or an
unverified write.

The command serves a deliberate operator change. It does not implement automatic
fallback, succession, role rebinding, host movement, or a global rewrite of every
model-selection consumer.

A harness change cannot preserve one harness's private conversation context in a
different harness. The operation retains every substrate transcript row, moves the
visible-history barrier with its existing tombstone, and starts a fresh engine
context. A model or effort change inside one harness preserves the harness
conversation through the existing verified switch or fork path.

## Supported command

The public verb is `tune`:

```text
tightbeam tune --session <key> --harness <harness> --model <model>
               [--effort <level>] [--context <variant>]

tightbeam tune --session <key> --model <model>
               [--effort <level>] [--context <variant>]

tightbeam tune --session <key> --effort <level>

tightbeam tune --session <key> --fast on|off
```

The normal identity flags apply: `--as <role>` and `--as-user <id>`. Session
credential discovery also applies when the caller omits an identity flag.

One invocation changes one control dimension. A model's `model`, `effort`, and
`context` fields form one dimension. A harness change includes its destination
model because a model from the old harness is not a valid destination default.
The CLI parser refuses all other combinations before it calls the gateway. This
keeps partial multi-control application unrepresentable instead of adding a
rollback mechanism.

The parser rules are:

1. `--session` is required and targets one exact active session key.
2. `--harness` requires `--model`. It may include `--effort` and `--context`.
3. `--model` may include `--effort` and `--context`.
4. `--effort` may appear alone and then applies to the current model.
5. `--context` never appears without `--model`.
6. `--fast` accepts only `on` or `off` and is mutually exclusive with the model
   and harness fields.
7. Model identity uses separate fields. The CLI never accepts a packed
   `model[effort]` value. A vendor context variant may still appear in a catalog
   row's issued reference and resolves through the catalog that issued it.
8. At least one control is required. Unknown flags and empty required values are
   usage errors and cause no request.

Examples:

```text
tightbeam tune --session "agent:coder:auth s_1234" \
  --model gpt-5.6-sol --effort high

tightbeam tune --session "agent:reviewer:auth s_5678" \
  --harness codex --model gpt-5.6-sol --effort high

tightbeam tune --session "agent:reviewer:auth s_5678" --fast on
```

## Field meanings

- `--model` selects the vendor model family.
- `--context` selects the vendor's context-window variant. Omission selects the
  catalog row's default variant for a newly named model. An issued catalog
  reference resolves back to the exact row that issued it.
- `--effort` is Tightbeam's public name for the thinking or reasoning level. The
  adapter translates it to the harness-owned config option. The current adapters
  use `effort` for Claude and `reasoning_effort` for Codex.
- `--fast` maps only to the live ACP session config option whose id is `fast`.
  With the current Tightbeam ACP client capability, Claude Agent ACP 0.66.0
  exposes that option as the select values `on` and `off`. Fast is a per-session
  Claude runtime preference. It is not part of `Tightbeam.Model`, not an effort
  tier, and not a model-catalog field. A harness or current model that does not
  advertise the live `fast` option does not support this control.

## Authority

The gateway resolves the caller before it mutates anything. The caller's user
must own the target session, or the caller must be an admin. This matches the
existing owner-scoped client control path. A process identity cannot tune a
session. An unauthorized or unknown target returns the same non-identifying
`not_found` result and performs no readiness probe or mutation.

## Apply semantics

Every mode runs at a session turn boundary. A queued or running turn causes an
immediate `turn_in_progress` refusal. The command never waits behind the turn and
never lands a change mid-turn. The operator retries after the turn finishes.

### Model and effort

The gateway resolves the requested fields against the target session's host and
current harness. Catalog freshness may permit a degraded attempt, but catalog
membership never proves success. The adapter applies the model and effort through
the existing resident switch or fork path. It reads the harness config back and
commits the model fields and replacement pointer only after the readback matches.
Failure leaves the stored model and pointer unchanged and closes or forgets any
rejected replacement session.

### Harness

The gateway validates the destination credential, host readiness, harness, model,
context, and effort before it changes the session row or visible-history barrier.
It projects the destination home, starts a destination harness session, applies
the requested model fields, and verifies the harness readback. Only then does one
database transaction change the harness, provider, model fields, pointer,
visible-history barrier, and swap tombstone. If validation, startup, application,
readback, or commit fails, the original harness, model, pointer, and visible
history remain active. The gateway closes the rejected destination session.

On success, the session key and all substrate relationships remain unchanged.
The visible chat resets at the tombstone because the destination engine has a new
private context. Transcript rows remain readable through the transcript command.

### Fast

The gateway asks the resident harness session for its live config options. It
refuses `fast_unsupported` unless that response contains the `fast` option. It
sends `session/set_config_option` with `configId: "fast"` and `value: "on"` or
`"off"`, then reads the returned option value. Success requires an exact
readback. Fast does not use the derived model catalog and does not silently map
to a model, effort, or provider flag.

The current Claude adapter retains the user's Fast intent across supported model
switches inside that adapter session. A harness switch starts a new engine context,
so Fast starts from the destination harness's reported value. The operator can run
a separate `--fast` command after the harness switch. Tightbeam does not claim
Fast persistence across gateway or adapter restart until a live resume test proves
that property.

## Result

Success exits zero and prints one JSON object built from verified state:

```json
{
  "ok": true,
  "sessionKey": "agent:coder:auth s_1234",
  "harness": "codex",
  "model": "gpt-5.6-sol",
  "effort": "high",
  "context": null,
  "fast": null,
  "engineContext": "preserved"
}
```

`fast` is `"on"`, `"off"`, or `null` when the live harness does not advertise
it. `engineContext` is `preserved` for model, effort, and Fast changes. It is
`reset` for a harness change. The response reports the actual accepted values,
not the request echoed back.

An idempotent request whose verified state already matches returns success with
the same shape. This command does not need an idempotency key because a repeated
single-control request converges on the same verified state and does not create a
new substrate identity or work record.

## Refusals

All refusals exit nonzero, print the gateway error JSON, and leave the prior
configuration active.

- `not_found`: the session is unknown, retired, or not visible to the caller.
- `turn_in_progress`: a turn is queued or running; retry at the boundary.
- `unknown_harness`: the harness name is not registered.
- `host_unready`: the target host cannot run the selected harness.
- `credential_unavailable`: the destination credential is absent or unusable.
- `catalog_unavailable`: the host cannot supply enough model facts to attempt
  the change honestly.
- `model_unavailable`: the requested model, context, or effort is not offered.
- `model_apply_failed`: the harness refused or could not verify the model fields.
- `fast_unsupported`: the live session does not advertise the `fast` option.
- `fast_apply_failed`: the harness refused Fast or returned a mismatched readback.
- `session_config_commit_failed`: verified runtime state could not be committed;
  the replacement runtime is rejected and the original state remains active.

Harness errors must be translated into one concise operator sentence. Raw Elixir
terms, ACP payload dumps, and inferred fallback models never reach the user.

## Implementation boundary

The CLI adds one `Tune` command and sends the existing `tune` gateway verb with
one of `set_harness`, `set_model`, `set_reasoning`, or `set_fast_mode`. It does not
call the client-only `/api/session-control` facade. The gateway keeps one mutation
lock and one turn-boundary mechanism per session.

The adapter adds a generalized verified live-config operation for options that
the harness actually advertises. Model and effort keep their current specialized
path. Fast uses the generalized path. No static Fast support table is added.

The session-status projection must source Fast availability and current value
from the same live config readback used by the mutation. The CLI, Clawline, and
future clients must not maintain separate Fast capability guesses.

This slice applies the unified model-resolution ruling at every seam it touches:
fields remain separate, the live harness owns its vocabulary, and readback decides
success. It does not authorize a broad refactor of unrelated spawn, fallback, or
picker code under `wi_4e1d39f7-0425-4607-bebb-7f81b2f30eb9`.

## Acceptance tests

### CLI parser and wire

1. Each of the four supported forms parses and produces the exact typed `tune`
   request with separate model fields.
2. Missing `--session`, missing destination `--model`, `--context` alone,
   `--fast` with another control, invalid Fast values, packed effort syntax, and
   no control all fail before network I/O.
3. Help lists the command, field meanings, continuity rule, and Fast limitation.
4. Session-file identity, `--as`, and `--as-user` use the ordinary identity path.
5. A successful response prints verified fields. A gateway refusal exits nonzero
   and preserves its structured code and message.

### Gateway and authorization

1. The owner and an admin can tune. Another owner and a process get non-identifying
   `not_found` without a mutation or readiness call.
2. Unknown and retired sessions refuse.
3. Every mode refuses at a queued or running turn and leaves all state unchanged.
4. Repeating an already-applied request succeeds without creating another pointer,
   barrier, or tombstone.

### Model, effort, and harness

1. Model and effort readback success commits the exact family, context, effort,
   provider, and pointer.
2. A stale catalog can permit an attempt, but a mismatched live readback refuses
   and leaves the prior selection intact.
3. A harness switch verifies a fresh destination runtime before one transaction
   commits the harness, provider, model, pointer, barrier, and tombstone.
4. Each failure before that transaction keeps the original engine usable and
   closes the destination session.
5. A successful harness switch keeps the session key, roles, assignments,
   work-item links, spawn lineage, workdir, identity revision, and overrides.
6. A successful harness switch reports `engineContext: "reset"`; same-harness
   changes report `"preserved"`.

### Fast

1. A captured real Claude Agent ACP 0.66.0 config response contains the `fast`
   option for a Fast-capable model and records its exact option type and values.
2. `--fast on` and `--fast off` send the live option's accepted value and require
   exact readback before success.
3. A missing option refuses `fast_unsupported` without sending a guessed config id.
4. A refusal, timeout, or mismatched readback returns `fast_apply_failed` and does
   not report a changed value.
5. Session status and CLI output use the same cached live readback.

### Reality gate

Before merge, run the live feature-smoke matrix against fresh Claude and Codex
sessions with the installed adapter versions. Capture the real config responses as
fixtures. Prove same-harness model and effort continuity on both harnesses. Prove a
Claude Fast toggle on and off when the account and model advertise it. Prove the
Codex session refuses Fast honestly. Prove both cross-harness directions preserve
the Tightbeam session key and work relationships while resetting only engine
context. A mocked adapter cannot satisfy this gate.
