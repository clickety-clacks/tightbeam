# Work-item indicators for a page

`GET /api/work-item-indicators` returns the small facts a page of work items
shows, in one bounded read. It uses the existing state bearer credential and
`asUser`, and shows exactly what the same caller's item, assignment, wake, turn
and decision reads show.

| parameter | meaning |
|---|---|
| `workItemIds` | up to 50 item ids, comma separated |
| `assignmentIds` | up to 50 assignment ids, comma separated; each resolves to its item |
| `asUser` | as on other state reads |

At least one id is required. More than 50 in either list is refused with 400
`too_many_ids`, naming the limit; any other malformed query is 400
`invalid_indicators_query`. Each item appears once however it was named. Ids that
do not exist and ids the caller cannot read are both listed under `notFound` and
never fail the read.

```json
{
  "schemaVersion": 1,
  "resource": "work item indicators",
  "asOf": 1790000000000,
  "items": [{
    "id": "wi_...", "title": "...", "state": "open", "rowVersion": 1790000000000,
    "started": true, "held": true, "holders": ["..."],
    "waiting": {"agent": false, "time": true, "event": false, "userIds": ["alex"]},
    "running": true,
    "waits": [{
      "id": "wake:w_...", "wakeId": "w_...", "kind": "timed", "by": "time",
      "assignmentId": "asg_...", "waitReason": "Waiting for the nightly build",
      "createdAt": 1790000000000, "dueAt": 1790000600000, "fallbackAt": null,
      "waitOn": [{"kind": "time", "id": null, "dueAt": 1790000600000, "role": "due", "cron": null, "visible": true}]
    }],
    "waitsTruncated": false,
    "questions": {"count": 1, "truncated": false, "items": [
      {"id": "dr_...", "kind": "operator", "userId": "alex", "assignmentId": "asg_...", "raisedAt": 1790000000000}
    ]},
    "runningCards": [{
      "assignmentId": "asg_...", "holderKey": "...",
      "turn": {"seq": 41, "startedAt": 1790000000000, "assignmentId": "asg_...", "workItemId": "wi_..."}
    }]
  }],
  "assignments": [{"id": "asg_...", "workItemId": "wi_...", "state": "open"}],
  "notFound": {"workItemIds": [], "assignmentIds": []}
}
```

- `state` is the stored state. `started` is whether the item ever had an
  assignment; `held` is whether one is open; `holders` are the holders of its open
  assignments. Nothing else is counted.
- `waiting` and `running` are the same fields, with the same meaning, as on the
  item detail; see [readable waits](readable-waits.md). A fallback deadline, a
  fired wake, a routing or slate reminder and a delivery retry are not waits.
- `waits` are the records behind `waiting`, oldest first, at most 20
  (`waitsTruncated` says when there are more; the item's and card's `wait-links`
  reads page through all of them). `by` is `agent`, `time`, `event` or `user`;
  `dueAt` is the awaited time and `fallbackAt` only a safety deadline. `waitOn` and
  hidden targets follow the wait-links rules. A wait on a question to a user is
  listed here when a wake recorded it.
- `questions` are open decision requests addressed to a user, without their text.
  `count` is exact; at most 20 are listed. A question the caller cannot read is
  `{"id": null, "visible": false}`.
- `running` means a running turn recorded this item or one of its cards.
  `runningCards` lists open cards whose holder is in any turn, with the card and
  item that turn recorded (both null when it recorded neither). A holder whose
  turns the caller cannot read is left out.

Everything is computed when read, by seeks on the named records. There is no
cursor, no organization-wide form and no stored indicator.

## Keeping it current

Change notices stay invalidations (`docs/firehose.md`). Re-read one item through
this read when a `work_item.*`, `assignment.*`, `wake.*` or `decision_request.*`
notice names it. A holder's turn that recorded no card or item produces no item
notice: re-read items whose `holders` include the `sessionKey` of a
`turn.started` or `turn.ended` notice. `rowVersion` is the item's version and does
not move for such a turn.
