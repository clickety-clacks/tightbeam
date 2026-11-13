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
