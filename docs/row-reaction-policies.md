# Row-reaction policies

These descriptions follow the declarations linked below. A reaction runs only
when its declaration is elected and its conditions match. Removing a declaration
suppresses its automatic action; it does not undo the source command.

## Assignment work starting

[`assignment-first-start-notice`](../priv/kungfu/agentic-engineering/rules/row-reaction-status.toml)
belongs to the engineering bundle. When the assignment holder's first started
turn changes from queued to running, it sends one immediate notice to the
assignment opener. Earlier started turns by another session or on another
assignment do not count. Started holder turns are ordered by start time and turn
sequence. Later turns, repeated running observations, and turns that never
started do not produce a start notice.

A session opener receives the notice at its existing session. A user opener
receives it at that user's personal session, provided that session exists and
belongs to the user. The rule does not introduce a fallback recipient or require
an active session at selection. The existing delivery gate applies. No available
target means no automatic action. An author who is the same typed principal as
the opener receives no self-notice; matching text across a user and session does
not make them the same principal.

This intentionally replaces routine progress notifications with a real start
notification. Progress and ordinary verdict records stay durable and quiet.
This rule emits no finish notice; the completion handoff owns that event. Blocker
notices are a separate declaration, not inferred from progress prose. There is
no repeating timer. Removing the rule suppresses only this notice. Changing its
wording or recipient preserves the source event's action identity; replay uses
that identity instead of admitting a second notice.

## Assignment blocker notices

The following declarations in the engineering bundle use the same existing
opener selection and typed self-notice suppression as the first-start rule:

- [`assignment-blocker-raised-notice`](../priv/kungfu/agentic-engineering/rules/row-reaction-status.toml)
  sends an immediate notice when a linked operator, statute or agent decision
  request is inserted open. A request update is not a new blocker. The separate
  cannot-proceed request carries that command's explicit communication; its
  attest is not another automatic status notice.
- [`assignment-blocker-resolved-notice`](../priv/kungfu/agentic-engineering/rules/row-reaction-status.toml)
  sends an immediate notice for an operator or statute request changing from
  open to ruled, or an agent request changing from open to answered. Consumption,
  repeated terminal observations, returns and ordinary withdrawals do not match.
- [`assignment-blocker-receipt-notice`](../priv/kungfu/agentic-engineering/rules/row-reaction-status.toml)
  sends a resolution notice on the first insertion of a linked ruling-consumed
  verdict, if the opener has not already received that resolution. The receipt
  must name that operator request exactly. This also applies to a late receipt
  on a closed assignment; it does not close the assignment again or emit a
  finish handoff. An ordinary verdict, unrelated receipt or replay is quiet.

Each rule skips a missing recipient and adds no timer. It suppresses a notice
when a pending or fired explicit command notice for that request already reaches
the same session at the same stage: the request when raised, or the ruling or
answer when resolved. Raised-request suppression includes the existing statute
owner notice from the `escalate` operation. Its original attempted command stays
in the request context; it is not treated as an operator ask or a resolution. A canceled notice does not establish that communication.
A request notice does not suppress a later resolution notice, and an explicit
notice to another recipient does not suppress the opener's update.

Resolution and receipt notices share the resolution effect slot. A pending or
accepted status action for the same request and recipient suppresses a second
resolution from another source event. Reconciliation excludes the current
source event from that check so its own pending action can be updated. Canceled
or held actions do not count as communication. This preserves one status update
without duplicating the explicit request or answer.

Removing these declarations suppresses only their automatic notices. Changing
wording or recipient keeps each source event and effect slot's identity. Source
requests, answers, receipts and ordinary progress remain durable. The deliberate
change from routine attest notifications is that only these explicit blocker
transitions produce notices; prose alone does not signal a blocker or resolution.

[`assignment-standing-block-settled-notice`](../priv/kungfu/agentic-engineering/rules/row-reaction-status.toml)
also belongs to the engineering bundle. It handles the specific withdrawal that
settles a cannot-proceed block: the linked agent request changes from open to
withdrawn, its recorded context names cannot-proceed, and its linked standing
condition is settled by a release fact or assignment disposition. It immediately
notifies the existing opener using the same resolution slot and suppression
rules above. An ordinary withdrawal, a still-standing condition, or an unrelated
condition does not match. Repeated withdrawn observations do not notify again.

The settled condition is the evidence; this rule does not independently verify
the release fact or the agent's disposition. Canceling the old decision wake or
appending holder transcript text is not an explicit resolution notice to the
opener. Those writes therefore do not suppress this notice. Removing the rule
suppresses only its notice, preserving settlement and cancellation. A disposition
may already have closed the assignment; this rule reports the block's settlement
and performs no assignment transition or finish handoff.

## Terminal assignment handoff

[`assignment-terminal-handoff`](../priv/kungfu/agentic-engineering/rules/row-reaction-handoff.toml)
belongs to the engineering bundle. An actual open-to-closed assignment transition
produces one immediate handoff for a completion or supported surrender attest,
or for a revocation. A lookup, replay, late receipt or already-closed assignment
does not produce another finish notice. The start and blocker rules do not
produce this handoff.

For migration of an already-existing historical handoff, the declaration also
accepts an explicit historical event with a null prior row and exact supported
closed-assignment source evidence. This avoids inventing an earlier open row.
The runtime binds that evidence only to an existing output; the historical marker
does not authorize creating an absent action or replaying history. Unresolved
source evidence is held. The same outcome, source, recipient and identity checks
apply to adopted pending work; accepted and canceled outputs retain their history.
Historical adoption retains the actual stored output ID. For an explicit recovery
successor, this is its linked transport output rather than the canonical root's
hash. Pending reconciliation preserves that successor and the canceled root;
it neither starts an automatic retry nor resurrects the root. New terminal
observations continue to derive their canonical ID from the source record.

For a session opener, the recipient order is: the opener when it holds an open
assignment for this same item as a delegated participant; the item's current
explicit delivery owner; the opener; then the opener's user's personal session.
A current accountable owner is not classified as delegated. For a user opener,
the order is current explicit delivery owner, then that user's personal session.
Duplicate candidates are removed in order. Every selected session must be active
and owned by the opener's user. The holder's user does not replace the opener's
ownership. The source owner's identity comes from the immutable raw rows captured
at admission or historical adoption. Reconciliation does not replace it when the
opener changes owner. Current rows still choose recipients in the order above
and check that the opener and any linked work item retain that original owner.
Historical owner records do not supply a delivery fallback.

The handoff preserves the existing ordered terminal-source payload, its hash-based
wake identity, and its assignment relation. Recipient changes do not change that
source identity. It names the source record, assignment, work item (including
null), holder, opener, outcome and recorded terminal time. There is no repeating
timer in this declaration. Pending handoffs may be reconciled to a new eligible
recipient; accepted deliveries remain terminal.

If this rule matches but no recipient is available, the terminal close,
revocation or retirement still commits with one durable undelivered handoff
intent. The elected unavailable address is the session opener's address, or the
user opener's personal-session address. It is retained evidence, not an extra
delivery fallback. The executor cancels the undelivered intent through ordinary
cancellation and records typed undeliverable evidence with the original wake
identity, assignment, terminal-notification purpose and recipient-unavailable
reason. If the current opener or work-item owner relation no longer matches the
original owner, the rule instead elects no recipient and records
`invalid_terminal_notification_relation`, retaining the original owner in the
payload. It cannot deliver under the new owner. It reports no delivery and arms
no automatic retry.

Failure to persist the source transition, intent or required evidence still
refuses and rolls back the transaction. Later explicit recovery retains the
canceled root and links a deterministic successor under the same logical handoff;
it does not resurrect the root. Removing the rule preserves the explicit terminal
command and creates no automatic intent. Changing recipient order or wording
changes the elected reaction without a runtime rebuild. The default preserves
the existing recipient order, payload, terminal-source identity and undelivered
outcome. This corrects the earlier declaration's refusal on recipient absence;
that refusal did not preserve the existing terminal command behavior.

## Parent action after a terminal handoff

[`terminal-child-action-reminder`](../priv/kungfu/agentic-engineering/rules/row-reaction-terminal-action.toml)
belongs to the engineering bundle. Successful delivery of a child's completion
or supported surrender handoff arms a reminder two hours after that delivery.
Successful delivery of each reminder arms the next two-hour reminder. Direct and
batched source delivery use the same rule; readiness, failed delivery and replay
do not count as a new delivery. Revocation and other terminal outcomes do not
arm this reminder.

The recipient is the parent session that actually received the handoff, still
active under the source's owner. It must hold an open assignment on which it can
record its action. The root's assignment, child, owner and recipient relations
must agree with its exact terminal source. A successor names that same root and
recipient; it is not rerouted to a new parent. The actual delivered transport is
the root even when it is a retry, rather than substituting its retry ancestor.
The existing wake identity hashes this root and either the initial marker or
the immediately delivered predecessor, preserving one action for each link.

The reminder asks the parent to choose keep, park or retire within its authority
and report what it did using the existing progress-note convention. A progress
attest authored by that parent with the exact child assignment, source kind and
source token stops reminders. The parsed kept, parked or retired statement must
have nonempty detail. An unrelated, malformed or other-author note does not
stop them. The statement is trusted; this rule adds no verification ceremony.
It does not require that the receipt be on the child's closed assignment or that
its destination assignment remain open after the receipt.

No reminder action is admitted if the parent lacks an open progress destination
at the original delivery. Opening one later does not restart that occurrence.
A matching receipt, loss of the destination, or loss of the eligible recipient
cancels a pending reminder through ordinary reconciliation. A matched receipt
withdraws the output with that actual progress attest as the superseding cause.
Loss of the parent or open progress destination uses the existing target-unavailable
cause and the current output ID. Receipt cause takes precedence when both apply.
The current action result supplies that output ID; historical adoption can retain
its recorded existing wake ID. These withdrawal arguments apply only to an
existing pending action, even though its admission condition has become false.
Removing the rule or any other loss of eligibility uses ordinary engine removal
cancellation. Central cancellation authority and liveness checks still apply;
the declaration adds no exemption or independent receipt verification. Delivered
notices remain historical evidence. The reminder carries no closed-child assignment
attachment and preserves the existing prompt bytes and root obligation link.

Removing this declaration suppresses automatic reminders without retracting the
terminal handoff or the parent's action duty. Changing the delay or prompt
changes pending elected behavior while retaining source and effect identity;
accepted or canceled actions are not resurrected. This default preserves the
two-hour cadence and exact existing disposition convention. Legacy pending
reminder adoption and delivery observation are runtime responsibilities, not
additional policy hidden behind the family name.
