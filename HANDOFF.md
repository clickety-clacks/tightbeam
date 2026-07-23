# Core-rules conformance handoffs

## Check-tier clause 127 — verdict filing emits exactly one verb event

- Blocker: the required behavior already exists in the owned implementation at
  `Tightbeam.Dispatch.dispatch_to_handler/7`: a successful `attest` handler
  return appends exactly one `events(kind="verb")` row. The rejected proof used
  a completion attest, however, and this lane does not own any test path.
- Required cross-lane change: in `test/check_tier_test.exs`, create a real open
  assignment and authorized user or session principal, file
  `kind="verdict"` through `Dispatch.dispatch/3`, assert the verdict row's
  observable fields, and assert the event table contains exactly one row whose
  `kind` is `"verb"` and `verb` is `"attest"`. The test must use the real
  Gateway handler and must not call `Assignments.__handle__/3` directly.
- Existing cross-lane proof: the core-assignments lane commit `1f74cd6`
  contains this real verdict-via-Dispatch assertion in
  `test/assignments_test.exs`; integrate that proof in the lane that owns the
  test rather than duplicating verdict-specific production logic here.
- Self-proof target: removing the successful-handler
  `EventLog.append_event(db, "verb", ...)` call in
  `Tightbeam.Dispatch.dispatch_to_handler/7` makes that test fail.

## Rails I8.2 / F2.2 / P5.1 / C6.8 — F2 fixed target/parameter reachability

- Blocker: `rails-mechanism-v1.md` F2(b) says literal remedy targets and params
  map to `target.*`/parameter facts, but it does not define that mapping.
  Runtime `target.*` facts are projections of `Org.get(call.session_key)`, not
  of literal target names: assign/wake role targets require runtime role
  resolution and a DB row, while spawn dispatches with `session_key=nil`.
  The closed fact registry also has no generic remedy-parameter facts; the only
  parameter-derived facts are `attest.kind` and
  `assign.declared_files_overlap_open`, neither of which has a general
  literal-to-fact mapping. Inventing one would change the substrate fact model.
- Required spec change: add an explicit per-action table mapping every literal
  `[rule.remedy]` target/param field to an existing fixed fact value, including
  the behavior for role targets, literal session keys, spawn's nil target, list
  params, and interpolated values; or narrow F2(b) to the currently
  implementable fixed attributes (`verb` and
  `caller.origin_class="remedy"`). Then add the complete table-driven load
  matrix in the lane that owns `test/rail_remedy_test.exs`.

## Rails I7.1 / E1.1 — turn-end non-pass denial rows

- Blocker: the missing actor is `Tightbeam.Supervision.rail_step`, outside this
  lane's owned paths.
- Required cross-lane change: in `lib/tightbeam/supervision.ex`, append one
  best-effort `events(kind="denied")` row for each turn-end remedy, escalate,
  and deny branch using the synthesized call and E1 payload. Add real
  `test/supervision_test.exs` assertions for exactly one row per branch with
  `edge="turn-end"`, statute, reason, ref, and manifest SHA.

## Rails I8.3 / F2.5 — blocked turn-end remedy re-enters the ladder

- Blocker: only `Tightbeam.Supervision.rail_step` can inspect a blocked remedy
  outcome and fall through to the existing prod/escalation ladder; that module
  is outside this lane's owned paths.
- Required cross-lane change: retain the existing acted/watermarked branch for
  non-blocked outcomes, but on `outcome=="blocked"` record
  `rail_sweep/re-obligate` and fall through to the ordinary ladder. Add a real
  conditional-blocker integration in `test/supervision_test.exs` that observes
  the blocked remedy lifecycle row and the ladder action on the same terminal.

## P3 clause 91 — producer worker unlocks a produced-verdict gate

- Blocker: the required acceptance proof belongs to the producer runner and
  `test/producers_test.exs`, outside this lane's owned paths.
- Required cross-lane change: load a real
  `assignment.produced_verdict_kinds not_in ["tests-passed"]` gate, prove
  completion denies, invoke public `run-tests`, allow the actual async runner
  to file its frozen producer verdict, then re-dispatch completion and prove it
  succeeds. Do not insert the verdict through a helper.

## Check-tier clause 124 — zero-rule lifecycle precedence remainder

- Blocker: the remaining acceptance matrix belongs to
  `test/check_tier_test.exs`, outside this lane's owned paths.
- Required cross-lane change: send lifecycle attests through
  `Dispatch.dispatch/3` under zero rules and assert non-holder plus garbage kind
  returns `not_holder`, holder plus garbage kind returns `invalid_kind`, and a
  lifecycle kind carrying stray `verdictKind` returns
  `invalid_verdict_kind` last.

## Check-tier clause 126 — verdict activity resets supervision prod state

- Blocker: this is a `Tightbeam.Supervision` integration and its implementation
  and test are outside this lane's owned paths.
- Required cross-lane change: mirror the real progress-row prod-reset fixture,
  file a real verdict on the open assignment, prove `attest_count` advances,
  and prove the next supervision evaluation resets the attempt/prod counters
  from that neutral row count.

## Check-tier clauses 129A / 129B — complete attests kind/order matrix

- Blocker: the required query fixture belongs to
  `test/check_tier_test.exs`, outside this lane's owned paths.
- Required cross-lane change: create progress, completion, surrender, and
  verdict rows with both distinct and tied timestamps, call the real `attests`
  read verb, and assert all kinds are returned in `ts ASC, id ASC` order.
