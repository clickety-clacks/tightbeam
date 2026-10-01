# 0.1.9 telemetry and durable Topline checks

Use the [fresh-base actors](README.md#fresh-base-actors), matching package and
[CLI shell](README.md#cli-shell). `test_admin` is the admin of this disposable
base; `as_actor <workdir>` carries a test session's identity. Create only
area-owned items and assignments. Record admission refusals and missing actors
as setup limits; never fabricate rows or borrow live tokens.

Rows labelled **Fresh / records** check durable operations through admitted
test actors. **Fresh / online** needs the stated real runtime or external
service. Record each prerequisite and use the [scorecard](README.md#scorecard).
A queued turn alone is not evidence of delivery or a reply. Every database
inspection uses `sqlite3 -readonly "$AREA_BASE/state.db"` and named columns.

The shared smoke `telemetry` pass owns physical breathing and execution-map
roster/filter assertions; the CLI rows below add packaged wiring and queue
visibility, not another full execution-map lifecycle. This area owns all
Topline mutations. In 0.1.9, `toplines`/`topline` are durable Toplines; the
computed roster is `execution-map`/`execution-map-select`.

A historical sample may reuse the gateway's contained migrated copy for the
Breathing reads row. Name that evidence separately from fresh-base checks;
use operator/admin reads only. Pending historical placements are conditional.

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| <a id="breathing"></a>Breathing reads | Fresh / records; historical sample optional | Cite shared smoke's physical breathing assertions. Make one packaged `tb breathing work-item <known id> --as-user "$test_admin"` read, reusing an existing fixture rather than making another lifecycle. The aggregate historical sample makes this read on an existing migrated item instead and labels it historical. | The result has `schema` `breathing-v1`, `target` `{kind,id}` naming the requested record, a boolean `breathing`, a truthful `reason` code and an `evidence` map. |
| Breathing on a running turn | Fresh / online | Reuse the queue-summary journey's assignment and read `breathing assignment <id>` while it runs, then after it ends; no extra provider task. | While running: `breathing: true`, reason `running_turn`. After it ends, the reason is a terminal or idle code, not `running_turn`. |
| <a id="worker-queue-summary"></a>Worker queue summary | Fresh / online | Reuse the busy holder and the two known queued messages before replacement in [replace, stop and resume](work-routing.md#replace-unread-messages). Read `breathing assignment <id>` as the opener and as an authorized unrelated admin who is neither opener, item owner nor opener-session owner. Record the enqueue times and sender. | Opener sees `queue.count: 2`, `senders` identifies the known sender/count, and `oldestAgeMs` is nonnegative and agrees with elapsed time since the older enqueue within the recorded observation interval. The unrelated reader gets the same breathing result without `queue`, not a refusal. A scheduled wake without a queued turn is excluded. If the holder drained before the read, record the missed prerequisite and repeat only this bounded setup, not a passed count. |
| <a id="execution-map"></a>Execution map | Fresh / records | Cite the shared smoke telemetry result for roster/filter/creation-context assertions. Run one packaged `tb execution-map-select --under <test work item> --as-user "$test_admin"` on its known item. | The CLI result names that item, reports `edgeBasis: concurrent_turn` and `coverage`, and returns `roots`. This is one CLI wiring read, not another full lifecycle. Source parser tests own the removed `toplines --tree` spelling. |
| <a id="topline-lifecycle"></a>Durable Topline lifecycle | Fresh / records | As the admin, run `topline-create --title ... --key k1`, `topline-update <id> --title ... --reason ... --key k2`, `topline-link-work <id> <test work item> --reason ... --key k3`, `topline-close <id> --reason ... --key k4`, `topline-reopen <id> --reason ... --key k5`. Read `toplines --state open`, `toplines --state closed`, `toplines --state all` and `topline <id> --history` after each. Repeat `topline-create` with key `k1` and the same title, then with key `k1` and a different title. | Each mutation shows in the state filters, and `--history` lists one event per mutation with `actor`, `at`, `kind` and `reason`. The same key and request returns the stored response; the same key with a different title is refused `idempotency_conflict`. |
| <a id="leave-unlinked"></a>Leave a work item unlinked | Contained migrated copy; conditional | Run `tb topline-placement-list --state pending --as-user <owner>` for a copied owner inside the historical boundary. If a pending placement exists and the run authorizes this copied-record mutation, run `topline-work-leave-unlinked <workItemId> --reason ... --key ...` as that owner and read `topline-placement-list --state resolved`. Honor the copied-token ruling if session identity is needed. | The placement is `left_unlinked`, with the reason in `resolutionReason` and `resolutionActor` and `resolvedAt` set. With no pending placement/authority, record the named gap; nothing in 0.1.9 opens a new placement to supply a fresh fixture. |
| <a id="notice-rules"></a>Fourth-review supervision notice (U3) | Fresh / records | Follow [fourth-review notice](#fourth-review-notice) below using ordinary test review cards and holder-filed verdicts. | The fourth verdict causes one durable notice to the accountable opener/coordinator; earlier rounds cause none, and rereading does not add another. A learned TOML file alone is not this result. |

Every Topline mutation needs `--key`. Keys are scoped to the calling user and
operation, so reusing a key for a different operation is not a conflict.

Within that same Topline lifecycle, retain its `membership.id`, create one
concern with `topline-concern-create <toplineId> --title <fixture> --key <k>`,
and link it using `topline-concern-link-work <concernId> <workItemId>
--reason <fixture> --key <k>`. Read `topline <id> --history`: the open Topline
contains that membership, concern and history, and the link result names the
work item. Unlink the concern with `topline-concern-unlink-work` using the same
two IDs and a fresh key/reason; unlink the membership with
`topline-unlink-work <membershipId> --reason <fixture> --key <k>`. Verify their
removal before the final close. Read `topline-placement-list --state all` and
require a `placements` list. These preserve the removed smoke helper's unique
assertions without repeating the full lifecycle.

## Fourth-review notice

Learn `agentic-engineering` on the fresh base, then restart only this area's
owned gateway with the README helpers to load its rules. If the bundle was
already present at this boot, no restart is needed. Inspect the composed
`ac6a-fourth-review-or-fix-round` rule as setup. Do not change its threshold.
Use test sessions O (accountable opener), P (producer), and R (independent
reviewer), with admitted roles. O creates item W and sets W's delivery owner
to O. For each round 1–4, O opens an evidence-fixture assignment on W with
`assign --effect-kind evidence` (no wake), and a review card to R with
`assign --reviews <producer> --work-item
<W>`. R files one truthful `changes-requested` verdict describing that numbered
disposable review fixture, naming an actual intentionally missing fixture
field. These cards review test evidence, not code, and make no judgment about
real product work. Keep source/review admission constraints;
if admission requires evidence the fixture does not have, stop and record it
rather than forge `tests-passed` or remove a rule.

Read `work-item-trace <W>`, O's transcript and these named columns from the
scratch DB after each verdict (substitute W using a bound SQL parameter in the
reader, or a recorded generated work-item ID):

```sql
SELECT wakeId,sessionKey,assignmentId,work_item_id,prompt,origin
FROM wakes
WHERE work_item_id = '<W>'
  AND origin = 'remedy:ac6a-fourth-review-or-fix-round';
```

After the first three verdicts require zero rows. After the fourth require one
row, targeting O (or the recorded accountable coordinator if the fixture uses
that topology), bound to the fourth review card and W, with a prompt naming
the fourth review round. Record its wake ID and actual delivered turn if the
recipient can run. If delivery cannot run, the routed durable notice and
missing delivered-turn evidence are separate results; do not call it delivered.
Repeat the trace and notice read after the next normal observer interval:
require the same single wake ID. An actual row-commit reevaluation replay is a
source-test control, not something a public read pretends to trigger.

Dispose the fixture cards through their opener with recorded reasons. The
other three predicates (backlog, sender flood and unassigned turn), exact
reevaluation deduplication and episode races remain in `test/rules_test.exs`
(`AC6a fourth review and fix rounds route through real assignment and attest
commits`) and `test/record_notice_test.exs`. No 60-minute wait or 20-prompt flood
is added to this journey.
