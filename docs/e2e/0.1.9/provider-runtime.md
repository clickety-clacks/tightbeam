# 0.1.9 provider, session and host-runtime checks

Use the [fresh-base actors](README.md#fresh-base-actors), matching package and
[CLI shell](README.md#cli-shell). All sessions, credentials, endpoints and
files belong to this authorized test base. Record package/source, harness CLI,
adapter, provider/model/effort and host for each real boundary. A queued wake
or a model's claim that it used a tool is not execution evidence.

The manual identity journey owns identity mutations/status/apply. Smoke's
`provider` area owns per-harness local deployment/projection and the
non-mutating onboarding-entry envelope; cite those results. Gateway isolation
is in [gateway-surface.md](gateway-surface.md); the single sentinel journey
is in [work-routing.md](work-routing.md#landing-watcher).

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| <a id="identity-current"></a>`identity current` | Fresh / records | In an unused scratch directory, write a test marker `.tightbeam-session` with a known test `sessionKey` and inert `token: runbook-not-a-token`. With endpoint/token variables unset, run the packaged `identity current` there and in a subdirectory. | Both print only the key; the inert token never appears. No network needed; malformed marker cases remain in CLI tests. |
| <a id="identity-lifecycle"></a>Identity lifecycle | Fresh / records | Follow [identity and composed guidance](#identity-and-composed-guidance) once. | Reversible edits, relearn, status and selected-session apply read back truthfully, with original fixture bytes restored. |
| <a id="guidance-presence"></a>Composed guidance (U8) | Fresh / records | Inspect delivery, reviewer and shared core/manual in the same journey. | Current carry, bookkeeping, agreed-phase/MVP review and clone custody appear in composed output; deleted rules are not requirements. |
| <a id="session-connect"></a>Satellite connection (U2) | Fresh / online | Follow [satellite round trip](#satellite-round-trip) on an authorized satellite without a local gateway. | Correlated send/reply, replacement snapshot after reconnect, retained message and exclusion of another session's traffic. |
| <a id="harness-capability"></a>Capability negotiation (U1) | Fresh / online | Compare actual Firehose-v2 session change and REST-v1 resource/status in [provider transition](#provider-transition). | Matching `capabilities.setHarness`, resident option disabled, compatible REST envelope. Legacy fallback has its own prerequisite/result. |
| <a id="tune-turn-in-progress"></a>Provider transition (U1) | Fresh / online; two harnesses | One switch with two queued messages, known pre-switch context and the running-turn refusal. | Durable switch, ordered delivery and observed context continuity; no canceled or duplicated queued intent. |
| <a id="sentinel-lifecycle"></a>Sentinel lifecycle | Conditional online | Cite the single [sentinel/PR journey](work-routing.md#landing-watcher), including missing settings and disable after real use. | One lifecycle supplies the results; no second provider-side lifecycle. |
| Harness-health authorization | Fresh / records | As a non-admin test session call `harness-health-review-other hh_runbook-unknown --outcome confirmed_other --key <unique>` and `harness-health-evidence-other hh_runbook-unknown`. | `not_authorized`, `evidence_not_found`, and no incident created. Invalid enums remain in CLI tests. |
| <a id="sign-in-recovery-wake"></a>Sign-in recovery wake | Online, operator at keyboard | Complete one authorized subscription `onboard openai` or `onboard anthropic`, then inspect that user's Main turns. | Exactly one recovery wake to that user. API-key-negative/provider failure cases remain in `test/oauth_recovery_wake_test.exs`; no second login ceremony. |
| <a id="local-openai"></a>Pi boundary (#47/#106; U1) | Conditional online | Onboard one authorized Pi provider, record its catalog model, then follow [real tool boundary](#real-tool-boundary). | Real allowed tool, before-execution denial with absent effect, recorded provider/model and clean closure. One journey covers both PRs. |
| <a id="cursor-leg"></a>Cursor boundary (#31; U1) | Conditional online; deny gap | With test credentials and Cursor's existing dedicated execution identity, follow the allowed-tool/UID portion of [real tool boundary](#real-tool-boundary) locally on the gateway host. | Record `skipped: no probe gate on Cursor` for the boundary row; keep any actual allowed-call/UID evidence separately. It does not establish the deny/non-execution half. |
| <a id="provider-recovery"></a>Provider recovery (U7) | Conditional incidents | Follow [provider recovery evidence](#provider-recovery-evidence). | Each incident retains its own prerequisite, public outcome and missing-evidence status. |

## Identity and composed guidance

Learn `agentic-engineering` on the fresh base and record `identity status`'s
`live_revision`. Before editing, verify that this test base already contains
`identity/guidance/coder.md` and `identity/archetypes/coder.toml`, whose guidance
includes `coder.md`. Save both original files byte-for-byte in private scratch
outside the identity repository and record their digests. A missing fragment
or include is a setup gap; do not create an unreferenced guidance file.

Append one unique inert fixture comment to a scratch copy of the guidance,
then publish it with `identity edit coder --file <edited-guidance-copy>`.
Require the published fragment and `identity status coder`'s composed guidance
to contain that comment. Restore through `identity edit coder --file
<original-guidance-copy>`; require the original file digest and absence of the
comment from composed guidance. Repeat with a TOML comment in a scratch copy
of the existing coder manifest using `identity edit coder --manifest --file
<edited-manifest-copy>`, then restore using the untouched original manifest
copy and verify its digest. Keep these restoration copies until cleanup is
verified, including after any failed step; unresolved restoration stops the
journey and remains an incomplete cleanup result.

Choose an unelected test skill name absent from this base. Put it with
`identity edit coder --skill <unique> --file <scratch-skill-file>`, inspect it,
then remove it with `identity edit coder --skill <unique> --rm`. Verify absence
after cleanup, including on failure. These are temporary mutations of test
fixtures only. Run `identity relearn`, retaining its actual publication/conflict
result; conflict is not successful publication.

Apply to one active test session; the apply response's `applied` names it.
Then read status: `identity_revision` equals `live_revision`, and
`identity_stale` is false with expected revision/render/digest fields.
Applying to an already-retired test
session refuses `not_found`. Host/admission failures are setup gaps.

Read `identity status pdo`, `identity status reviewer-code` and `identity
status coder`. Inspect the **composed** `guidance` at that recorded revision
for one selected harness, plus its projected `tightbeam-operating-manual`
skill. The returned map allows comparison without model calls. Require:

- Delivery carries accepted output to its authorized destination and
  distinguishes branch delivery, installation and availability (#60), without
  resurrecting the historical default to both release lines.
- Core/manual routes bookkeeping to the opener and genuine product/trust/scope
  choices to the user (#100).
- Reviewer judges the agreed phase; an adequate MVP does not owe optional
  polish. Blockers name required behavior, explicit constraints or missing
  acceptance evidence; other findings are `post-mvp` (#39). Do not require
  the deleted engineering-posture rail.
- Core requires an owned clone, preserving another agent's work and unresolved
  custody (#33's surviving intent), not the deleted clone-owned skill or
  unconditional clone deletion at completion.
- Retain no in-turn waiting (#131), assignment-scoped helpers (#134), briefs
  stating goal/context/limits (#165), and testing the version under test plus
  applicable landing guidance (#163). Removed exception wording `incredibly
  detrimental failure mode` and `post-MVP sanity check` is absent (#35). The
  operating-manual skill is projected (#122).

Record short semantic excerpts, not a model obedience trial, helper staffing
or clone deletion. During the existing Codex deployment smoke inspect the
generated test `config.toml`: `guardian_approval = false` if no explicit value
was supplied; otherwise preserve/report that value. The configuration matrix
remains in `test/codex_guardian_default_test.exs`.

## Satellite round trip

Record the authorized satellite, matching packaged CLI, test session S and
its configured test gateway endpoint. Verify from the non-secret process/
listening-port view that no gateway runs locally on the satellite. Do not
reconfigure a production satellite or print a bearer to fill this prerequisite.
From S's own satellite workdir, with stdin held open, run:

```sh
"$PKG/bin/tightbeam" session-connect --session "$session_key"
```

Keep output in private scratch. Require `snapshot.begin`, `snapshot.item`
frames, matching `snapshot.end`, then `ready` for S. A fresh invocation has no
leading `connection` frame; that frame reports `state: reconnecting` after an
existing worker connection closes. Send one line:

```json
{"type":"send","protocolVersion":1,"requestId":"rb-satellite-1","content":"Reply with SATELLITE-ONE <nonce>","idempotencyKey":"rb-satellite-1-<nonce>"}
```

Correlate `send.accepted.requestId` and `wakeId` to the message/turn and real
nonce reply in an `event`. While open, create a distinct nonce event in another
test session T of the same user. Verify T's durable event exists and its turn
has ended, while its event/reply/session key is absent from S's stream over
that recorded observation interval.

Reconnect once by normal EOF (exit 0), then start the same command through the
same satellite configuration. Treat each complete matching
`generation`/`snapshotCycle` snapshot as replacement state keyed by resource
IDs. Require the first message, turn and reply retained once by ID and no T
traffic. Send a second unique request and require its correlated reply;
never resend the first prompt to manufacture continuity.

This is public client reconnect, not a gateway restart or proof of automatic
retry inside a running client. Automatic reconnect/parser/race permutations
remain in `cli/src/session_connect.rs`. If a separately authorized transient
disconnect occurs, retain its new generation/replacement snapshot without
forcing a network or gateway failure.

## Provider transition

Use one fresh S with two admitted, credential-ready harnesses. Reuse its
satellite connection where suitable. Outer NDJSON `protocolVersion` stays 1;
Firehose negotiates `/ws/changes?protocolVersion=2`. Require a wrapped `event`
containing an actual `change` with `schemaVersion: 2`, resource `sessions`, a
`session.*` class and `payload.capabilities.setHarness`. This is the canonical
session capability; `session_status` is not a Firehose event class here.

Compare S through authenticated `GET /api/sessions/<URL-encoded S>` (REST
envelope `schemaVersion: 1`) and `GET /api/session-status?sessionKey=<URL-encoded S>`.
The D1 resource and Firehose accept S's test session credential; the status
route requires an already paired test device owned by S's user. Name that
device prerequisite separately, rather than sending a session bearer to a
device-only route. An approved HTTP client keeps these credentials in memory,
never arguments/logs. Require matching choices, resident harness disabled and chosen
alternative enabled. An unsupported specimen retains its reason and cannot
prove a switch.

Give S a unique recent work fact containing two random nonces; obtain its
acknowledgement. Start a harmless bounded turn. While running, queue distinct
messages A then B: A asks for those earlier facts from supplied context,
without tools or restating the facts; B asks for a different fixed reply.
Record queued IDs and assignment/work lineage. During the running turn,
`tune --session <S> --harness <other> --model <catalog model>` must refuse
`turn_in_progress`, leaving source and queue unchanged.

At that turn's end issue the same tune while A and B remain queued. Use a
bounded observer and at most three harmless fixture attempts. If queued work
starts first, do not freeze a lane or edit rows; report `INCOMPLETE: queued
boundary not obtained` if no attempt obtains it. On acceptance require the
durable `harness-switch` transcript marker naming old/new harness/model, the
committed session change and new harness readback. A returns the pre-switch
nonces without a transcript/file tool read; retain actual reply/tool evidence.
If an existing redacted adapter capture is available, also inspect its
`Cross-harness handoff from durable session records`. Source construction
alone is not observed receipt. B runs after A exactly once in S; compare
preserved historical messages and original lineage. Repeat tune to the resident
harness: `same_harness`, without another switch marker.

**Legacy fallback is separate.** With an already authorized, hash-qualified
legacy gateway fixture supporting only Firehose v1 and compatible REST, run
this same packaged client against its fresh base. This deliberately tests a
version mix: record both versions. Require refused v2 upgrade, REST rebuild,
v1 subscribe, schema-v1 session event without the new capability field and
retained snapshot/ready behavior. Use an existing approved redacted protocol
observation facility; do not add a proxy or fake server. Without that fixture/
observation, record `skipped: legacy Firehose-v1 fallback lacks E2E evidence`
and `cli/src/session_connect.rs` tests
`protocol_426_rebuilds_before_the_single_legacy_fallback` and
`session_reader_accepts_absent_legacy_and_both_closed_capability_forms`. The current
gateway refuses v1 at `/ws/changes` and cannot stand in for the legacy specimen.
Current v2 plus REST-v1 comparison does not prove fallback.

## Real tool boundary

Pi uses one authorized provider: `onboard local-openai --name <n> --endpoint
<url>` (API key on stdin if required), or `onboard opencode-go --api-key`
with stdin only. Reuse an onboarded test provider for #47/#106. Cursor uses
`onboard cursor --api-key`, stdin only, with existing supported local setup.
Record selected catalog model/provider; missing endpoint/key/model/dedicated
identity/observation is a named prerequisite gap.

Each selected Pi/Cursor session performs a harmless allowed shell call, such
as `printf 'ALLOW-<nonce>\n'; id -u`. Require actual tool arguments, successful
result and UID; Cursor's UID matches the configured dedicated execution
account, not the gateway user. Do not create an OS account to pass.

For Pi only, next request `touch <absolute test scratch>/must-not-exist; echo tightbeam-gate-probe`.
The only possible side effect is this inert file in its own workspace.
Establish absence before the call. The existing reserved `tightbeam-probe`
gate matches it. Require an actual tool attempt, gate denial and the file
still absent afterward. A model merely declining to call the tool leaves
boundary evidence missing. Never disable the gate or supply a synthetic
response.

Cursor's shipped rails do not include this probe gate. Record the Cursor
boundary row `skipped: no probe gate on Cursor`, with the missing deny and
non-execution evidence named. Keep its allowed-call/UID observations separately;
they do not make the full boundary pass. Do not send the Pi denial command to
Cursor or add a gate to manufacture this outcome. The Cursor source test adds
a probe explicitly and does not establish that shipped sessions carry it.

For each tested session, dispose its assignment and close it normally,
recording terminal state/cleanup and preserving artifacts.

Provider-selection, process-instance, race and local-only permutations remain
in `test/harness_pi_test.exs` and `test/harness_cursor_rails_test.exs`.

## Provider recovery evidence

Use genuinely encountered, separately authorized test incidents. Export only
non-secret IDs/transitions and redacted public messages.

Use the actual packaged CLI `spawn`/`tune` refusal already produced by that
authorized fixture, plus `list` for its host/model projection and the
recipient's `transcript`. An empty model list alone cannot distinguish an
unreachable host from missing credentials. Preserve the typed response at
the incident, rather than inventing a read-only readiness CLI or starting a
source-tree probe. If that response was not captured, name the missing public
evidence; a catalog source test does not supply it retrospectively.

For the credential incident, inspect only named non-secret columns in the
test DB through `sqlite3 -readonly`: `terminal_credential_incidents`
(`id,state,host,harness,provider,statementId,recoveryState,resolvedAt`),
`terminal_credential_observations` (`incidentId,kind,observedAt,outcomeClass`),
`terminal_credential_redirects` (`incidentId,destinationHost`), and
`terminal_credential_deliveries` (`incidentId,state,messageId`). Correlate the
standing message ID to its recipient transcript. Incident rows do not prove
absence of probes: use existing redacted runtime observations spanning the
normal catalog refresh interval, or retain that suppression-evidence gap.

| Prerequisite | Safe observation | Required outcome and limit |
|---|---|---|
| Terminal credential failure (#121) | Record host/harness/provider and typed failure. Read gateway/catalog readiness and standing recipient notice. Across the next normal observation interval inspect incident/observation counters and existing redacted probe logs. If an independently authorized sign-in succeeds, follow that incident through recovery. | Automatic reprobes stop; public refusal/readiness names terminal credential failure and its remedy. Redirect names an eligible destination, otherwise work stays truthfully parked. Standing notice remains until recovery, then resolves and readiness returns. Missing recovery or probe evidence is a separate incomplete half. Source: `test/terminal_credential_failure_test.exs`. |
| Already-unreachable registered test host (#138) | Read the captured gateway readiness refusal for that host once, alongside its retained host/catalog projection, using the surfaces above. Do not disconnect a host or make a new failed launch to create this prerequisite. | The typed readiness result is `credential_status_unavailable`, not missing credentials or a re-onboarding instruction. Missing host or captured public response is skipped explicitly. Timing/cancellation/late-result fencing remain source cases in `test/pi_remote_credential_status_test.exs` and the unavailable-not-missing case in `test/model_catalog_test.exs`. |

The package `doctor --json` is a different probe, not evidence for these
gateway/catalog outcomes. Rate-limit successor, typed ACP redelivery and
manual repair have separate [decision recovery rows](decisions-assignments.md#incident-evidence).
No credential is expired, revoked or replaced to fill a scorecard cell.
