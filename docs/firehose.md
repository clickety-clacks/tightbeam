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
In 0.1.11, some committed row changes are not published, including a pending
wake moving to a new delivery target during retirement or supervision. When a
change does publish an eligible notice, the healthy-socket guarantee above
applies. The server keeps no record of undelivered notices and offers no
replay, receipt, durable cursor, or delivery ledger. A detail read for an
unrelated notice cannot recover a change whose notice never arrived. Without
a client-chosen rebuild interval, recovery has no finite freshness bound.

After any socket close, or when the expected heartbeat does not arrive, a
client reconnects, authenticates, subscribes, and rebuilds its visible state.
It starts the subscription before the snapshot walk. A rebuild may remove a
row by absence only when a complete walk of the modeled collections began
after a fresh subscription boundary and no notice for that row arrived on the
current subscription. If a close or visibility change interrupts the walk,
the client discards its absence results and starts again from a fresh
boundary.

The directly applied resources need no REST reads on the normal path. A
client must treat notices for any resource not certified for direct
application as invalidations, never as complete rows, and read each notice's
key from that resource's REST detail route until it is certified. These
per-notice detail reads and the reads for composed views are the other
normal-path requests.

After a close, the minimum request count for one rebuild is

```text
sum over each supported collection route used by the view:
  max(1, ceil(visible rows / 500))
+ one /api/execution-map/tree request, if ExecutionMap facts are shown
+ one unpaged `toplines` dispatch read, if Toplines are shown
+ one `topline` dispatch read for each of T visible Toplines, if Toplines are shown
```

This is a lower bound. It assumes pages use `limit=500` and that no rows are
added during the walk. If a collection's walk must restart, its pages are read
again. For core Firehose rows, the global collection routes available in
0.1.11 are `/api/work-items`,
`/api/attests`, `/api/artifacts`, and `/api/sessions`. Assignments have a
detail route and a per-assignment attests collection. Wakes and turns have
detail routes and per-session collections; this release has no global
assignment, wake, or turn collection routes. A global collection walk cannot
discover assignments; wakes and turns can be enumerated within each known
session.
