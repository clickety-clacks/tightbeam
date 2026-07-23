# Core-supervision conformance handoff

This file records every clause that the independent verifier classified
`STILL-OPEN`. None is claimed closed. The four verifier-approved
`CLOSED-REAL` clauses remain implemented and unchanged:

- Supervision 31.
- Escalation 13.
- Escalation 54.
- Escalation 120.

## Authoritative spec conflicts

### Supervision 5, 12, 15, 22, 33, 42, 50, 60, 74, 75, 86, 89, 107, 119, 122, 123, 125, 129; Escalation 21 and 122

**Exact blocker:** `supervision-impl-v1.md` r20 says it is the sole authority for
the build lane and requires pending-wake suppression before the canonical claim,
watermark movement only on a canonical claim, an exact public result-tag set, no
statute-expressed supervision policy, no check-tier completion gate, no
assignment mutation, no `rail_sweep` lifecycle kind, and substrate acts limited
to wakes/stamps. The ratified `escalation-substrate-v1.md` r7 and its named
parent `rails-mechanism-v1.md` require the already-shipped turn-end order and
effects: adjudication hold, `Rules.decide/2`, remedy close/fire, escalation
open/park, and rail lifecycle emission before the generic target-keyed pending
wake check. Existing conformance and unit tests assert the latter behavior.
Choosing either side in `lib/tightbeam/supervision.ex` would silently violate the
other governing spec.

**Required change:** Flynn/spec authority must amend the specs to select one
ordering and ownership model. If supervision r20 wins, the rails/escalation
specs and their conformance fixtures must remove the turn-end rail fold, and the
supervision implementation must remove `Adjudication`, `Rules`, `RailRemedy`,
turn-end `Escalation`, `rail_sweep`, noncanonical watermark writes, and the
extra public outcomes. If the rails/escalation model wins, supervision r20 and
the listed supervision clauses/acceptance contract must be amended with a new
termination proof and exact public contract. The owning test lane must then add
the full real-state matrix for the selected behavior.

### Supervision 29

**Exact blocker:** supervision r20 makes `notify_retired` doorbell-only, while
ratified escalation r7 §8 explicitly requires the same handler to call
`Escalation.withdraw_for_retired/2`. Removing that call closes Supervision 29
but violates escalation's retirement fast path; keeping it does the reverse.

**Required change:** an authoritative spec amendment must either move
retirement withdrawal to another durable/fast-path owner or explicitly permit
it in supervision's retirement handler. The selected path then needs a
real-state retirement test in the owning test lane. Supervision 31's existing
total catch must remain around the whole selected handler.

### Accountability 82

**Exact blocker:** the accountability constitution requires a strand to notify
the first living ancestor/root through wake-to-user, while supervision r20 step
7 says waking anyone about a retired holder is an operator judgment and limits
the optional doorbell to a stamp/lifecycle row.

**Required change:** the two specs must receive an authority ruling. If
notification is required, the owner-delivery lane must expose the existing
wake-to-user capability to the selected owner and define whether the recipient
is `ladder_target/3` or the org owner/root, then a real retired-holder matrix
must assert the actual delivered prompt. If supervision r20 wins,
Accountability 82 must be amended or removed.

## Owned behavior blocked by the test-file boundary

The lane owns only `lib/tightbeam/supervision.ex` and
`lib/tightbeam/escalation.ex`; the task expressly forbids editing the test files.
The anti-stub contract also forbids claiming implementation-only closure.

### Supervision 10 and 59

**Exact blocker:** the implementation still writes
`lastEvaluatedTerminal` for a retired holder, and
`test/supervision_test.exs` currently asserts that forbidden write. Correcting
the implementation alone makes the required test gate fail, while this lane
cannot change that test.

**Required change:** the test-owning lane must replace the contrary oracle with
a real retired-holder terminal and recovery-sweep matrix asserting no wake,
claim, counter, or watermark movement. Then remove the retired-branch
`write_watermark/3` call in `lib/tightbeam/supervision.ex`.

### Supervision 57

**Exact blocker:** the implementation already uses
`Assignments.list(%{state: "open"})`, deduplicates holder keys, unions pending
outbox sessions, and evaluates the union. The verifier found no regression test
that fails if this is reverted to raw assignment SQL. A normal end-state test
cannot distinguish two query mechanisms that intentionally return the same
rows, and this lane may not add a test seam or edit tests.

**Required change:** the spec/test owner must either authorize an observable
dependency seam that a test can exercise (for example, an injected candidate
enumerator used only through the public `Assignments.list` contract), or accept
source-level dependency inspection as the oracle for this implementation-mechanic
clause. Then add the corresponding non-stub test outside this lane.

### Supervision 135

**Exact blocker:** the N=0 fixture does not assert every session ledger and every
watermark outbox is quiescent.

**Required change:** extend `test/supervision_test.exs` to drive the real
cross-assignment reaction to rest and assert zero pending ledger/wake rows for
every session and `pendingBranch IS NULL` for every watermark.

### Supervision 136

**Exact blocker:** the past-sink fixture stops with a pending escalation.

**Required change:** extend the fixture through delivery and terminal handling
until real quiescence, then assert every ledger, wake, and outbox end-state.

### Supervision 137

**Exact blocker:** the suppressed/reclaimed fixture stops after scheduling one
wake.

**Required change:** deliver the reclaimed chain to rest and assert complete
ledger/wake/outbox quiescence.

### Supervision 138

**Exact blocker:** only pure `ladder_target/3` resolution is covered.

**Required change:** add a real H→S→H delivery/terminal cascade that reaches Main
and quiesces with no pending ledger, wake, or outbox state.

### Supervision 139

**Exact blocker:** no restart-gap test drops a published terminal cast while
Supervision is down and proves both recovery legs.

**Required change:** add a real supervised restart fixture that simultaneously
proves closed-assignment pending-outbox drain and open-holder predicate replay.

### Supervision 140

**Exact blocker:** no successful-dispatch/lost-clear crash fixture exists.

**Required change:** add a controlled post-dispatch/pre-clear failure seam and
assert duplicate redispatch occurs while `prodCount` advances exactly once.

### Supervision 141

**Exact blocker:** no test counts automatic recovery sweeps across boot and
forced restart.

**Required change:** add an authorized sweep-observation seam and assert exactly
one recovery sweep for each server start, including restart.

### Supervision 143

**Exact blocker:** no pending-outbox replay test changes `prod_limit`.

**Required change:** claim under old N, retain the real pending outbox, restart
under a new N, drain it, and assert the delivered prompt contains the frozen old
N and k/rung.

### Supervision 146

**Exact blocker:** the existing derived-stranded test proves only the open
retired-holder leg.

**Required change:** extend `test/work_state_test.exs` to close the assignment
and assert the same query no longer returns `stranded`.

### Supervision 149

**Exact blocker:** no non-Main contiguous holder reply-chain test proves the
N+1 wake bound.

**Required change:** run a real holder through N prods and the one off-holder
escalation with no fresh external input, assert at most N+1 contiguous wakes,
and do not assert N+1 as a per-assignment total.

### Supervision 151

**Exact blocker:** no two-assignment/repeat/dropped-`notify_retired` matrix
exists, and the required no-watermark oracle also conflicts with the existing
retired-holder test and the escalation retirement-withdrawal spec.

**Required change:** after the Supervision 29 authority ruling, add a
two-assignment retired-holder fixture asserting doorbell stamp dedupe, zero
wakes/claims/watermarks, repeat silence, and unchanged derived-stranded truth
when the cast is dropped.

### Supervision 152

**Exact blocker:** no pending-outbox fixture contrasts the two retirement
branches.

**Required change:** add real pending entries proving an escalation re-resolves
past a retired rung and dispatches to a live target while a prod to a retired
holder clears with no dispatch or counter movement.

### Supervision 153

**Exact blocker:** current tests cover a synthetic transient error and an exit,
not a raising handler plus both exit and throw total-catch branches.

**Required change:** add three real handler fixtures: raise must leave the
outbox pending and emit `supervision_dispatch_failed`; exit and throw must emit
`supervision_evaluate_failed` while the server survives.

### Supervision 156

**Exact blocker:** the code contains `strandedAt`, the four pending fields, and a
four-field clear, but schema acceptance does not exercise all of them.

**Required change:** extend schema tests to assert the `strandedAt` column and
run a real pending entry through clear, asserting all four pending fields become
NULL.

### Supervision 157

**Exact blocker:** later-evaluation transient retry is covered, but
`request_sweep` retry is not.

**Required change:** create a real pending transient outbox, restore the
handler, call `request_sweep`, and assert dispatch, one counter advance, and a
cleared outbox.

### Supervision 158

**Exact blocker:** the denial acceptance matrix is incomplete.

**Required change:** add real-state cases for delivered-after-denials resetting
the streak, a fully denied assignment retrying branch 1 forever, and duplicate
evaluation of the same terminal producing no extra denial/count/write.

### Supervision 159

**Exact blocker:** the pause/reset/oldest-selection matrix is incomplete.

**Required change:** add real-state cases for resume after the continuation wake
fires, a progress-only turn drawing prod 1, completion and surrender returning
idle, and selection of the oldest of two open assignments.

### Supervision 160

**Exact blocker:** the ladder acceptance matrix omits named branches.

**Required change:** add all required real-state cases: escalation after N
delivered prods, `stalledAt` set once, two-deep active lineage, nil-spawner Main
fallback, retired-rung skip, cycle handling, and exhausted-chain Main fallback.

### Supervision 162

**Exact blocker:** branch-level dedupe exists, but the required interleavings do
not.

**Required change:** add the exact lost-T1/newer-T2 `:coalesced` fixture and the
revoked-A1→oldest-A2 shift fixture, asserting zero action on the stale terminal.

### Supervision 164

**Exact blocker:** only the canceled-pause sweep case is covered.

**Required change:** add the full real sweep matrix: lost cast, nil-terminal
pending drain, already-claimed duplicate, canceled pause, pre-assignment
terminal, and never-terminal skip.

### Supervision 165

**Exact blocker:** row/query APIs lack a mixed fixture.

**Required change:** test `prod_state/2`, `watermark/2`,
`Ledger.pending_count/2`, `Ledger.last_terminal_seq/2`,
`Wakes.pending_count/2`, `Assignments.oldest_open/2`, and
`Assignments.attest_count/2` over mixed pending, terminal, claimed, and
unclaimed real rows.

### Supervision 168

**Exact blocker:** no single integration test covers the specified complete
timeline.

**Required change:** add the exact prod1→prod2→pause→prod3→escalation1→
escalation2→progress-reset→completion run and assert every wake, counter,
watermark, stamp, and lifecycle/event row at each transition.

## Escalation cross-lane implementation handoffs

### Escalation 6, 61, 105

**Exact blocker:** `rules.ex`/`dispatch.ex` do not carry the owner-delivery
capability into `Escalation.escalate/4`, and `Gateway.escalation_context/3` is
unused and resolves a personal session directly instead of using the existing
owner-user delivery seam.

**Required change:** the Rules/Dispatch/Gateway lane must supply a post-commit
owner-user delivery callback routed by `ownerUserId`, use the existing
wake-to-user path, and add an end-to-end halt/open/one-owner-delivery/pending
test.

### Escalation 8, 18, 44, 45, 47, 49, 78, 106, 111, 112

**Exact blocker:** no shipped live-agent caller/guidance implements the mandatory
session-raiser park protocol.

**Required change:** the live-agent/guidance lane must schedule the exact
self-created `escalation-ruled/<id>` wake before turn end, schedule-then-check
and cancel/act if already resolved, recheck/re-subscribe on every finite
fallback while open, and cancel/recheck on withdrawal. Add end-to-end real
agent tests for ruled-before/after schedule, two fallback iterations, and
withdrawal.

### Escalation 20, 48, 111, and the schedule-then-check portion of 122

**Exact blocker:** `park_escalation/3` must cancel a just-scheduled wake inside
its open transaction, but `lib/tightbeam/wakes.ex` exposes no transaction-scoped
cancellation operation; that file is outside this lane.

**Required change:** the Wakes lane must add the existing pending→canceled CAS
and lifecycle write for `DB.Txn`. Then `park_escalation/3` can schedule, re-read
`decision_requests.status`, cancel and act immediately for
`ruled|consumed|withdrawn`, with ruled-before/after race tests.

### Escalation 42 and 63

**Exact blocker:** r7 requires a separate thin `decision_request_event` doorbell
grain but does not define its DDL, sequence/cursor, writer API, retention, or
owner-surface consumer. A lifecycle row is explicitly insufficient.

**Required change:** the observability/spec owner must define the exact doorbell
schema and query/emission seam. Then the owning engine/wire/test lanes must emit
one doorbell on open and every resolve edge and prove owner queue observation
without using lifecycle rows as a substitute.

### Escalation 53

**Exact blocker:** direct engine option validation is implemented, but
`lib/tightbeam/rules.ex` cannot author or carry `options`; that file is outside
the lane.

**Required change:** the Rules lane must accept and validate
`[{label, effect}]` with `effect ∈ allow|deny`, carry it into escalation ctx,
and add real rule-load/decision tests for every option branch.

### Escalation 65

**Exact blocker:** `Escalation.list/4` and `get/4` are read-only, but the shared
Dispatch success path appends a `"verb"` event for the read verbs.

**Required change:** the Dispatch/Gateway lane must route
`decision-requests`/`decision-request` through a read-only dispatch outcome that
preserves authorization while appending no success event; tests must assert
event counts do not change.

### Escalation 66, 123, 124

**Exact blocker:** Gateway passes `owner_user_id` for same-owner agent/session
raisers, making owner scope indistinguishable from raiser scope inside
`Escalation.visibility/2`. Fixing only `escalation.ex` would either retain the
leak or wrongly remove admin-agent access.

**Required change:** Gateway must pass owner scope only when the existing
owner/admin axis authorizes it; otherwise call without owner scope so exact
canonical `raiserId` filtering applies. Add same-owner agent/session list/get
isolation tests plus authorized owner/admin coverage.

### Escalation 96

**Exact blocker:** r7 says deadline config is threaded through Escalation's child
spec, but `Escalation` is an effect-only module with no specified process state,
and `application.ex`/Gateway child wiring are outside this lane.

**Required change:** the spec owner must define whether Escalation becomes a
configured child or the child-spec sentence is removed in favor of the already
specified Application-env read. If a child is required, the Application/Gateway
lane must start it and thread `escalation_decision_deadline_ms`, with boot/default/
override tests.

### Escalation 102

**Exact blocker:** CLI files and CLI tests are outside this lane.

**Required change:** the CLI lane must add positive argument/help tests for
`revoke-waiver`, `withdraw`, `decision-requests`, and `decision-request`.

