# 0.1.9 telemetry and durable Topline checks

Offline rows run on a new copy of the migrated result
([reuse the result](migration.md#reuse-the-result)) inside the verified
[containment](README.md#containment) boundary, from the
[CLI shell](README.md#cli-shell). `tb` calls that read or change org records add
`--as-user "$test_admin"`, an admin chosen from the area copy:

```sh
test_admin="$(sqlite3 -readonly "${AREA_BASE:?}/state.db" "SELECT userId FROM users WHERE isAdmin = 1 ORDER BY userId LIMIT 1")"
```

Online rows run on a fresh empty base under the [online tier](README.md#tiers)
and are labelled "fresh-base feature evidence, not proof on migrated state".
The feature smoke's `telemetry` area ([feature smoke](README.md#feature-smoke),
online only) covers a physical `breathing` read, an `execution-map` row and
`execution-map-select --under`, the durable Topline lifecycle, and the Toplines
roster and state filter.

In 0.1.9, `toplines` and `topline` are durable Toplines. The computed roster
and its tree moved to `execution-map` and `execution-map-select`. The 0.1.8
spellings `toplines --tree` and `topline --under` now fail at parse.

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| <a id="breathing"></a>Breathing reads | Offline | Pick one copied work item with no open assignment and one open copied assignment. Run `tb breathing work-item <id> --as-user "$test_admin"` and `tb breathing assignment <id> --as-user "$test_admin"`. | Each result has `schema` `breathing-v1`, `target` `{kind,id}` naming the requested record, a boolean `breathing`, a `reason` code and an `evidence` map. The work item with no open assignment reports `breathing: false` with `no_open_assignment` (or `pending_wake` if a pending wake carries its ID). |
| Breathing on a running turn | Online | Start one harmless turn on a test-owned assignment and read `breathing assignment <id>` while it runs, then after it ends. | While running: `breathing: true`, reason `running_turn`. After it ends, the reason is a terminal or idle code, not `running_turn`. |
| <a id="worker-queue-summary"></a>Worker queue summary | Offline for the key; online for a count | Offline: read `breathing assignment <id>` for one copied assignment as its opener (the opener user with `--as-user`) and again as an admin who is neither the opener, the work-item owner nor the opener session's owner. Online: keep a test holder busy with a long harmless turn, queue two further prompts to it with `wake --session <holder> --assignment <id> --prompt ...`, and read as the opener. | The opener's result has a `queue` object with `count`, `oldestAgeMs` and `senders`. The unrelated reader gets the same breathing result with no `queue` key, and no refusal. Online, `count` is 2 while the holder stays busy. A scheduled wake with no queued turn is not counted. |
| <a id="execution-map"></a>Execution map | Offline | Run `tb execution-map --as-user "$test_admin"`, `tb execution-map --tree --as-user "$test_admin"`, `tb execution-map-select --under <copied work item> --as-user "$test_admin"` and `tb execution-map-select --assignments <two copied assignment IDs> --as-user "$test_admin"`. Then run `execution-map-select --assignments <one real ID>,asg_00000000-0000-4000-8000-000000000000`. Also run `tb toplines --tree`. | Results carry `edgeBasis` `concurrent_turn` and `coverage`; `--tree` and `--under` return `roots`; `--assignments` returns `items` and `noItem`, and an assignment with no resolved item appears in `noItem` for the admin. The list with an unknown ID fails whole with `not_found`. `toplines --tree` fails at parse. |
| <a id="topline-lifecycle"></a>Durable Topline lifecycle | Offline | As the admin, run `topline-create --title ... --key k1`, `topline-update <id> --title ... --reason ... --key k2`, `topline-link-work <id> <copied work item> --reason ... --key k3`, `topline-close <id> --reason ... --key k4`, `topline-reopen <id> --reason ... --key k5`. Read `toplines --state open`, `toplines --state closed`, `toplines --state all` and `topline <id> --history` after each. Repeat `topline-create` with key `k1` and the same title, then with key `k1` and a different title. | Each mutation shows in the state filters, and `--history` lists one event per mutation with `actor`, `at`, `kind` and `reason`. The same key and request returns the stored response; the same key with a different title is refused `idempotency_conflict`. |
| <a id="leave-unlinked"></a>Leave a work item unlinked | Offline | Run `tb topline-placement-list --state pending --as-user <owner>` for a copied owner. If a pending placement exists, run `topline-work-leave-unlinked <workItemId> --reason ... --key ...` as that owner and read `topline-placement-list --state resolved`. | The placement is `left_unlinked`, with the reason in `resolutionReason` and `resolutionActor` and `resolvedAt` set. With no pending placement in the copy, record `skipped: no pending placement`; nothing in 0.1.9 opens a new one. |
| <a id="notice-rules"></a>Notice rules present | Offline | Run `tb learn agentic-engineering --as-user "$test_admin"`, then read `$AREA_BASE/identity/rules/ac6a.toml`. | The file holds the four notice rules `ac6a-queue-backlog`, `ac6a-sender-flood`, `ac6a-fourth-review-or-fix-round` and `ac6a-unassigned-agent-turn`. Their firing is covered by source tests. |

Every Topline mutation needs `--key`. Keys are scoped to the calling user and
operation, so reusing a key for a different operation is not a conflict.
