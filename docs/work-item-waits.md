# Recorded waits for work items

An open work item with no open assignment can record a dependency instead of
receiving reminders to route or close it while it is legitimately waiting.
Recording a wait suppresses only its routing and slate reminders (r04/r05).
Assignment, decision, terminal handoff and failure notices keep their existing
behavior. Items without a recorded wait keep their existing reminders.

```
tightbeam work-item-wait <item> --assignment <assignment> \
  --wait-reason "Waiting for the dependency to complete"
tightbeam work-item-wait <item> --decision <decision-request> \
  --wait-reason "Waiting for the decision"
tightbeam work-item-wait <item> --when-fact <kind> --when-scope <scope> \
  --fallback-after 3h --wait-reason "Waiting for the named event"
tightbeam work-item-get <item>
tightbeam work-item-wait-withdraw <item>
```

The reason is required: one nonblank line, at most 140 characters, validated by
the same `WaitReason` contract as other waits. The item owner, an admin or the
current delivery-owner session may record or withdraw a wait. Owner/admin
sessions retain their usual authority. An item with an open assignment must
record new waits on that assignment instead.

Unknown assignments and decisions are refused without changing reminders. An
unannounced fact kind is accepted with the existing no-live-producer warning. An already
matching fact satisfies the wait at registration; use a distinct scope when
waiting for a distinct occurrence. Facts use the existing owner visibility
contract. An event never being produced is bounded by the required event fallback;
there is no second timer or periodic producer check.

A completed assignment, answered/ruled decision or matching fact releases the
wait. A target ending another way wakes for reconsideration. An already resolved
or terminal target is recognized immediately. Fallback expiry also releases the
wait and identifies that outcome without claiming the dependency succeeded.
Assignment and decision waits have no deadline: only the target ending releases
them. `--fallback-after` is refused for assignment and decision targets; it belongs
to events only. The continuation goes once to the current active delivery owner, with the
personal Main fallback for an ownerless item or retired owner.

The item keeps its wait if assignments open or close while it stands. Their
notices remain active; a last assignment close does not start a slate reminder
until the item wait ends. Closing, failing or iceboxing the item withdraws its
pending wait. Reopening does not resurrect it. Recording a different target or
reason atomically replaces the old wait. Retrying the same active declaration
returns its existing wake and does not extend its safety deadline.

Withdrawal ends suppression without an extra resolution prompt. Resolution or
fallback likewise ends suppression permanently. If the item remains bare, its
ordinary routing reminder (never assigned) or slate reminder (previously
assigned) is restored at the usual triage interval. Ignoring the continuation
therefore does not leave the item silent.

## Stored state and compatibility

`wakes` stores the predicate, recognition, recipient and deadline;
`wake_wait_reasons` stores the existing short reason. `work_item_waits` links an
item to its current wake and records release once. Old wakes and their typed
cancellations retain history. Replacement and release occur in the source
transaction. Existing recognition and delivery identities make replay and
scheduler restart idempotent. No new scheduler is introduced.

`work-item-get` adds a nullable `wait` result with the wake identity, reason,
predicate, deadline, active/released state and recognition outcome. Other work
item fields remain unchanged. Withdrawal, replacement and item disposition reuse the existing typed
cancellation carriers, with no new cancellation migration.

The substrate applies wait suppression to the r04/r05 notice families at
admission and reconciliation. Shipped and customized rule declarations remain
unchanged; recording the wait elects its suppression without a served identity
update. The durable `wait_ended` observation resumes the applicable family's
existing initial-bracket expressions; the slate reminder uses its triage
horizon rather than duplicating the immediate resolution prompt. This change
is intended for the release after 0.1.17.
