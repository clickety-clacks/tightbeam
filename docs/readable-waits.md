# Wake reasons and direct wait links

This feature defaults off. Enable the application setting `wait_links_enabled`
(or `TIGHTBEAM_WAIT_LINKS_ENABLED=true` at startup) to use the read endpoints,
optional reasons and missing-reason notices described here. While off, these
endpoints refuse, existing response shapes remain unchanged, and required
holder-wait reasons remain supported. Explicit item waits have their own
`work_item_waits_enabled` flag. See [feature flags](feature-flags.md) for the
additive schema work and rollout ownership.

A wake's `waitReason` explains why its sender scheduled it. Its prompt tells the
recipient what to do. The reason uses the existing `WaitReason` contract: a
nonblank single line of at most 140 characters. `wake --wait-reason` accepts this
field on timed, recurring, conditional, dependency and after-turn declarations.
Existing item waits use the same field and validator.

Newly covered wake forms accept an omitted, null or blank reason. New agent waits return a
`missing_wait_reason` warning in the command reply; this does not create a turn
or refuse the wake. Process and user callers, ordinary immediate messages, and
idempotent replays do not receive that warning. Previously mandatory dependency
and item-wait paths keep their existing requirements. Invalid supplied values
are refused; text is never truncated. Cron occurrences inherit their root's
reason. Historical missing reasons are not filled from prompts.

## Reads

The existing state bearer credential and `asUser` selection apply to these GET
routes:

- `/api/work-items/:id/wait-links`
- `/api/assignments/:id/wait-links`
- `/api/sessions/:key/wait-links`
- `/api/decision-requests/:id/wait-links`

Each response contains `items`, `source`, `asOf`, `rowVersion`, `nextCursor` and
`truncated`. `limit` defaults to 20 and is capped at 50. Pass the returned opaque
`cursor` unchanged for the next page. `nextCursor: null` ends the page sequence.
Active records are selected by default; `includeEnded=true` includes retained
ended records. Cursors are scoped to the source and the ended-record selection.
Pages are ordered by recorded creation time and a stable record ordinal; cursor keys do not expose hidden target IDs. Pending after-turn waits remain active until the originating turn ends. A trigger already released for delivery is no longer a wait; recurring roots remain active for their next occurrence. Native work-item routing and slate reminders, and failed-delivery retry attempts, are not declared waits. They do not supply wait links or waiting indicators, including in ended history. Their ordinary delivery notices remain unchanged.

An edge has `id`, nullable `wakeId`, `kind`, nullable `waitReason`, `createdAt`,
`state`, `recognition`, `from`, `to` and `waitOn`. `to` is the primary target;
`waitOn` retains all recorded predicate targets and any fallback. A fallback
has `kind: "time"` and `role: "fallback"`, distinct from a timed wake's
`role: "due"`. Assignments include their state, holder and work item; decisions
include their state and addressee; session endpoints include `running` and
`runningSince`. Unreadable targets remain as `{kind, id: null, visible: false}`.
Unreadable wake rows remain as hidden edges with null identifiers and reason. Wake detail and event targets use the same unreadable-target placeholder. A source the caller cannot read returns 404.

Targets come from existing record references, predicates and schedules. A custom
fact's scope remains an event scope, even when its spelling resembles a record
ID. Substrate assignment facts can name an assignment. After-turn waits name
their recorded originating turn. No target is inferred from a prompt. Decision
addressees and raisers follow current custody. Decision and cannot-proceed edges without a wake reason expose null, rather than copying
a potentially long question or note into the short reason field.

For a page of items, [work-item indicators](work-item-indicators.md) returns the
same waiting facts for up to 50 items and 50 cards in one read.

These are direct links, not a recursively expanded graph. Clients follow exact
record IDs and track visited `(kind, id)` pairs. The server returns cycle edges;
a client stops traversal at a repeated node, terminal record, exhausted page,
time/event endpoint, or unreadable target. Clients should display their traversal
limits; the consuming client uses 12 hops and 40 records. Different hops may be
read at different moments.

## Changes and compatibility

Wake reads and events add `waitOn` using the same derived references. Work-item
reads add `waiting: {agent, time, event, userIds}` and `running`, and linked changes
publish ordinary work-item updates, including operator questions and disposer transfers. Item summaries seek linked assignment, wake and decision indexes rather than scanning organization-wide pending work. Item-wait readback retains `reason` for
compatibility and adds `waitReason` and `waitOn`.

`event` covers pending custom-fact waits; reserved assignment facts count as
`agent`. A fallback deadline does not set `time`: that flag means the awaited
time itself. Any true flag or nonempty `userIds` means waiting; all false/empty
means not waiting.

These are additive response fields. Existing change subscriptions already accept
one `workItemId` per subscription. Wake and decision notices now carry that
reference when the source item is known directly or through an assignment;
unlinked records do not invent an item. No new list-filter syntax is needed.

Work-item notices retain the invalidation contract in `docs/firehose.md`: clients
re-read their exact detail route. A complete summary snapshot in one producer
is not a new direct-application contract for every producer. Exact item detail
uses a primary-key seek; its associated landing lookup seeks the recorded merge
and head-commit indexes. The dispatch detail verbs are also reachable under the
organization credential; REST is the consuming client's preferred interface.

A later release may require reasons on newly declared agent waits, after an
inventory of omitted reasons and affected callers. This change does not enable
that new refusal. Paged `/api/wakes` reads expose the creator, reason, derived
targets and timestamps needed for a retained-row inventory. Such a snapshot
counts rows, not command invocations or warning deliveries; retries and retained
history must be reported with their window and limitations.
