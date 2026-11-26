# Firehose change stream

The Firehose WebSocket carries published state changes to authenticated
subscribers. While the socket remains open and the hub that accepted its
subscription stays alive, every published notice for a post-subscription
change is delivered in commit order when it matches the subscription, is
visible to that subscriber, and is not withheld by the payload guard. This
guarantee has no other omission within those conditions.

The payload guard withholds a whole notice if any nested payload contains a
key named `cliToken`, `token`, or `identityToken`. A withheld notice is dropped
silently: the socket remains open and its sequence does not advance. The
sequence counts delivered subscription frames, so a heartbeat cannot reveal a
withheld notice. Whether a live producer currently emits such a payload has
not been established.

If a notice is never received, the corresponding change is invisible to a
healthy socket until the client completes another rebuild. This can happen
when a resource publishes no notice or when the payload guard withholds one.
For the seven resources in 0.1.11—work items, assignments, attests, artifacts,
turns, wakes, and sessions—published notices are invalidations rather than
complete rows. The stream does not guarantee a notice for every committed row
change. Other resources may also have committed changes that publish no notice;
whenever they do publish an eligible notice, the healthy-socket guarantee
above applies. The server keeps no record of undelivered notices and offers no
replay, receipt, durable cursor, or delivery ledger. A detail read for an
unrelated notice cannot recover a change whose notice never arrived. Without a
client-chosen rebuild interval, recovery has no finite freshness bound.

After any socket close, or when the expected heartbeat does not arrive, a
client reconnects, authenticates, subscribes, and rebuilds its visible state.
If one app's live-update backlog exceeds 64 MiB, the server sends that socket
`{"type":"reload_required","reason":"backlog_overflow"}` and closes it with
code 4008. The app must reload its visible state after reconnecting; other
subscribers continue receiving their notices.
It starts the subscription before the snapshot walk. A rebuild may remove a
row by absence only when a complete walk began after a fresh subscription
boundary and no notice for that row arrived on the current subscription. If a
close or visibility change interrupts the walk, the client discards its
absence results and starts again from a fresh boundary.

A client must treat notices for these seven resources as invalidations, never
as complete rows, and read each notice's key from the corresponding REST
detail route to obtain current state. For any resource with a separate
direct-application contract, follow that contract; otherwise, treat its
notices as invalidations and read the detail route. These per-notice detail
reads and the reads for composed views are the normal-path requests.

The `session_record_event.created` class has a direct-application contract. Its
payload is one record-event item, and clients append that item to the session's
record-event feed. The stream remains lossy; after reconnect, clients rebuild
the feed from `GET /api/sessions/:session_key/record-events`.

For transcript catch-up after reconnect, `GET /api/session-message-sequences`
returns `{"items":[{"sessionKey":"example","latestMessageSeq":123}]}` for all
sessions visible under the same authentication and `asUser` rules as
`GET /api/sessions`. Items are ordered by `sessionKey` ascending, without paging.
Only `asUser` is accepted as a query parameter. `latestMessageSeq` is the maximum
global `messages.seq` stored for that session, across all roles and message types,
including cleared history; an empty session returns `0`. It is a sequence from
message history, not a message count or a Firehose sequence. The endpoint uses
one read-connection query with an indexed latest-row seek per visible session,
without reading transcript bodies or using the database writer. Read markers
remain available separately from `GET /api/read-markers`.

Subscribe before reading this snapshot, then fetch history only for sessions
whose sequence advanced beyond the client's stored high-water mark. Persist
that mark after catching up through the observed sequence; a bounded history
read may need more pages to reach it. Continue applying live events while
catching up. This is an additive REST snapshot; existing roster and Firehose
payloads are unchanged. It does not detect edits to existing messages.

After a close, the minimum request count for one rebuild is

```text
sum over each modeled bulk collection: max(1, ceil(visible rows / 500))
+ one /api/execution-map/tree request, if ExecutionMap facts are shown
+ one unpaged `toplines` dispatch read, if Toplines are shown
+ one `topline` dispatch read for each of T visible Toplines, if Toplines are shown
```

This is a lower bound. It assumes pages use `limit=500` and that no rows are
added during the walk. If a collection's walk must restart, its pages are read
again. The rebuild view models seven bulk collections: work items,
assignments, attests, artifacts, turns, wakes, and sessions.
For an archetype-filtered subscription, rebuild by listing sessions with the
requested archetype filter and then using the existing per-session message and
tool-call reads for each returned session. There is no cross-session message
or tool-call collection.

### Capacity snapshots

With `provider_accounts_enabled`, administrators can subscribe to the
`capacity.changed` class and rebuild from `GET /api/capacity?refresh=cache`.
Wait for subscription readiness before fetching the snapshot. For a changed
account, use its opaque `refs.accountId` with
`GET /api/capacity/:accountId?refresh=cache`. Cache reads never call the provider.
Rebuild the snapshot after reconnect or `reload_required`.

The event has `op: "observe"` and a `payload.sourceVersion` derived from the
gateway's completion timestamp. A successful observation advances that
timestamp even when usage is unchanged. The event carries no provider account
identity, upstream response, or credential data.
