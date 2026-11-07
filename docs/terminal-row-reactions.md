The engineering bundle elects three row reactions. Loading the runtime alone
elects none. Their source events and pending actions are stored in the same
transaction as the writes they observe. Rule identity and revision are recorded
with the action; the recipient and prompt do not define its identity.

`r01-attest-notice` in `row-reaction-attest-notice.toml` means: tell the opener
once when the holder's first turn delivered for an assignment actually starts.
Use R02's single handoff for completion or revocation. Tell the opener about an
unlinked `blocked` verdict, a first late `ruling-consumed` receipt unless the
explicit ruling result already goes to that same recipient, and a linked review
verdict. Keep progress and other ordinary unlinked verdicts quiet. `cannot-proceed`
keeps its separate request path, and replaying a receipt sends nothing. Raising
a decision request or recording its ordinary ruling adds no extra opener notice;
the asked party and raiser keep their existing notifications. The opener uses the
existing session, personal-session, or process-recipient route;
missing or other-owner recipients are skipped, as is a notice when its author
and opener are the same session or user. The first-start notice is also skipped
when the session opener is the holder. The verdict-quiet and first-start notices
are intentional changes from the prior release line.

`assignment-terminal-handoff` in `row-reaction-handoff.toml` means: when an open
assignment actually completes or is revoked, create one durable handoff for that
exact terminal occurrence. For a session opener, try its delegated opener, the
current delivery owner, the opener, then the opener's personal session, in that
order. For a user opener, try the current delivery owner then the personal
session. A process opener retains its coordination parent, current delivery
owner, then personal-session order. Ignore duplicate candidates and select only
an active session belonging to the terminal relation's owner. Do not send an
additional terminal update to the opener when another recipient is selected.

If there is no eligible recipient, preserve the terminal change and its one
undelivered intent with typed undeliverable evidence. The record address does not
authorize another fallback recipient or assert delivery. The action stays incomplete:
a later recovery or reconciliation may use the elected recipient to deliver it,
under the same action identity and existing transport-attempt lineage. The
failed wake and typed undeliverable evidence remain historical; no timer is
added, and reevaluation while still unavailable creates no further attempt.
If persisting the source, intent or required evidence fails, roll back the
transaction. With no
matching elected rule, the command still completes and creates no automatic
handoff. Explicit command results and intervention messages keep their own
contracts.

`terminal-child-action-reminder` in `row-reaction-terminal-action.toml` means:
two hours after actual delivery of a completed or surrendered handoff, remind
the responsible parent if it is active, has an open assignment on which it can
record progress, and has not filed the exact disposition receipt. Revocation
handoffs do not start this reminder. A queued or accepted notice, a failed
attempt, and a fired timestamp without a committed delivery are not delivery.
Direct delivery and delivery as a batch member use the same source-to-turn
receipt. Each successful reminder delivery can start the next two-hour
interval; a scheduling attempt cannot.

The receipt is a progress attest by the responsible parent with this exact
shape and nonempty detail:

```
completion-handoff-action <assignment_id> <source_kind> <source_token> <kept|parked|retired>: <detail>
```

It names the child and terminal occurrence. It records the parent's statement
and does not independently prove physical retirement. A matching receipt or
loss of eligibility cancels pending reminders. An unrelated or malformed note
does not. Opening a progress destination later does not retroactively start a
chain. The rule selects the existing published terminal-action wording and its
current activity values; changing that wording does not change the receipt or
action identity.

Changing a rule reconciles existing pending actions under their original
identities. A missing match withdraws pending work; it does not retract a
delivered notice or create an action for an old event that originally matched
nothing. Boot adopts the bounded existing notice population, preserving source
and delivery history. An ambiguous historical action is held individually and
does not stop boot. Restoring an older rule revision reconciles pending work;
it does not replay accepted effects. Runtime installation or rollback remains
a separate operation from source changes.
