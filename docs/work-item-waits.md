# Recorded waits for work items

An open work item with no open assignment can record a dependency instead of
receiving reminders to route or close it while it is legitimately waiting.
Recording a wait suppresses only its routing and slate reminders (r04/r05).
Assignment, decision, terminal handoff and failure notices keep their existing
behavior. Items without a recorded wait keep their existing reminders.

```
tightbeam work-item-wait <item> --assignment <assignment> \
  --fallback-after 3h --wait-reason "Waiting for the dependency to complete"
tightbeam work-item-wait <item> --decision <decision-request> \
  --fallback-after 3h --wait-reason "Waiting for the decision"
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

Unknown assignments and decisions are refused without changing reminders. A
fact kind must have a substrate definition or a live producer claim. An already
matching fact satisfies the wait at registration; use a distinct scope when
waiting for a distinct occurrence. Facts use the existing owner visibility
contract. A producer disappearing later is bounded by the required fallback;
there is no second timer or periodic producer check.

A completed assignment, answered/ruled decision or matching fact releases the
wait. A target ending another way wakes for reconsideration. An already resolved
or terminal target is recognized immediately. Fallback expiry also releases the
wait and identifies that outcome without claiming the dependency succeeded.
The continuation goes once to the current active delivery owner, with the
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
item fields remain unchanged. A stamped schema migration admits the typed
item-wait cancellation carrier; ordinary reminder cancellation continues to
use the existing routing-bracket contract.

The updated r04/r05 seed declarations must be elected for suppression and
resumption. Existing organizations retain their served identity until its
normal seed update is applied; installation alone must not be credited as
activation. This change is intended for the release after 0.1.17.
