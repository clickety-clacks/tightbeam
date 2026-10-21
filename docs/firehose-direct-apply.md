# Direct application of Firehose rows

Clients can apply an upsert directly when its resource is marked certified in
the table below. For each key, keep the highest `rowVersion` seen from any
source, including notices, snapshot rows, and delete tombstones. A higher
version replaces the held state: an upsert stores the row, while a delete
removes the row and retains its version as a tombstone. Ignore equal or lower
versions. Equal versions for one key carry identical projection bytes. When a
fresh, complete walk establishes that a key is absent, discard the held version
for that key.

## R8 resource coverage

The version sources and write paths below describe this candidate. A required
resource remains uncertified until the complete behavior and convergence tests
are verified on the integrated 0.1.11 commit. All required resources have no
hard-delete path; lifecycle removal is represented by an upsert. Rows marked
as a fallback use invalidation plus a detail read and are not directly
certified.

| Resource | Primary key | Version source | Hard delete | Direct-apply certification | Write-path audit and candidate tests |
|---|---|---|---|---|---|
| Work items | `id` | `work_item_versions.rowVersion` | No | Pending integrated 0.1.11 acceptance | `create_result`, `update_result` (including body and priority side tables), and `dispose_result` stamp and publish; `arm_routing_in_txn`, `arm_slate_in_txn`, `rearm_on_fire_in_txn`, and `cancel_brackets_in_txn` stamp and publish the canonical projection. `test/firehose_publisher_test.exs`, `test/work_item_brackets_test.exs`, `test/work_items_test.exs`, `test/firehose_direct_apply_test.exs`, `test/firehose_cold_restart_test.exs` |
| Assignments | `id` | `assignments.rowVersion` | No | Pending integrated 0.1.11 acceptance | `open_assignment_in_txn`, close/revoke/reopen, and holder-retire writes are covered by the row trigger; attest-derived status and commit-ref correction bump explicitly before publishing. Reminder-state writes are outside the projection. `test/firehose_publisher_test.exs`, `test/assignments_test.exs`, `test/assignment_commit_ref_corrections_test.exs`, `test/firehose_direct_apply_test.exs`, `test/firehose_cold_restart_test.exs` |
| Attests | `id` | Immutable `attests.ts` | No | Pending integrated 0.1.11 acceptance | `insert_attest` is the sole runtime write; the row and `attest.filed` notice use the committed attest. There is no update or delete path. `test/firehose_publisher_test.exs`, `test/assignment_commit_ref_corrections_test.exs`, `test/firehose_direct_apply_test.exs`, `test/firehose_cold_restart_test.exs` |
| Artifacts | `artifactId` | `artifact_version_floors.rowVersion` | No | Pending integrated 0.1.11 acceptance | `record`, archive/release transition, and archive repoint reserve a floor in the committing transaction before publishing the canonical artifact. There is no delete path. `test/artifact_lifecycle_firehose_test.exs`, `test/firehose_direct_apply_test.exs`, `test/firehose_cold_restart_test.exs` |
| Turns | `seq` | `turns.rowVersion` | No | Pending integrated 0.1.11 acceptance | `Ledger.enqueue_in_txn` is the sole insert and publishes `turn.queued`; claim, terminal settlement, stale settlement, adapter generation, reply attention, and publication stamps use the row trigger and their existing lifecycle notice. `test/firehose_publisher_test.exs`, `test/ledger_test.exs`, `test/firehose_direct_apply_test.exs`, `test/firehose_cold_restart_test.exs` |
| Wakes | `wakeId` | `wakes.rowVersion` | No | Pending integrated 0.1.11 acceptance | Schedule/replace/retarget, fire/cancel, prompt and delivery-rule changes in `Wakes`; batch fire in `NoticeBatcher`; reschedule in `EffortCheckin` and `CronWake`; delivery in `Gateway` and `Ledger`; reconciliation in `RailRemedy`; insertion in `NoticeSubmission`; retarget in `Supervision`; and prompt updates in `Ephemeral` were audited. Each projected write publishes the current lifecycle class. Turn-linked `deliveryStatus` changes increment the wake version and publish its current lifecycle class. Source, recognition, verification, and cleanup columns are outside the projection. `test/firehose_publisher_test.exs`, `test/effort_checkin_test.exs`, `test/cron_wake_test.exs`, `test/supervision_test.exs`, `test/firehose_direct_apply_test.exs`, `test/firehose_cold_restart_test.exs` |
| Sessions | `sessionKey` | Monotonic `sessions.updatedAt` | No | Pending integrated 0.1.11 acceptance | `Gateway.spawn_result` and first-stream session seeding publish `session.spawned` in their creation transactions; field mutations including parent changes use `Org.mutate_session_in_txn`; retirement stamps and publishes through `Org` or the ephemeral retirement seam. Supervision cleanup observations are not projected. `test/gateway_test.exs`, `test/socket_test.exs`, `test/session_reparent_test.exs`, `test/firehose_publisher_test.exs`, `test/firehose_direct_apply_test.exs`, `test/firehose_cold_restart_test.exs` |
| Decision requests | `id` | `decision_requests.rowVersion` | No | No — invalidation plus read fallback | `lib/tightbeam/escalation.ex`; `test/firehose_org_escalation_test.exs` |
| Messages | `id` | Immutable `seq` | No | No — invalidation plus read fallback | `lib/tightbeam/ledger.ex`; `test/firehose_publisher_test.exs` |
| Toplines and composed facts | Resource-specific | Event sequence or source-row versions | Not a single row resource | No — invalidation plus read fallback | Read the source resources after invalidation |
| Roles | `name` | `roles.updatedAt` for upserts | Yes | No — invalidation plus read fallback | `lib/tightbeam/roles.ex` |
| Critical state | `sessionKey` | `critical_leases.updatedAt` | No | No — invalidation plus read fallback | `lib/tightbeam/critical_leases.ex` |
| Users | `userId` | Admin projection version | No | No — invalidation plus read fallback | `lib/tightbeam/admin_projection.ex` |
| Devices | `deviceId` | Device projection version | No | No — invalidation plus read fallback | `lib/tightbeam/devices.ex` |
| Read markers | `userId`, `scopeKey` | `read_markers.updatedAt` | No | No — invalidation plus read fallback | `lib/tightbeam/read_markers.ex` |
| Condition facts | `id` | Immutable `id` | No | No — invalidation plus read fallback | `lib/tightbeam/condition_facts.ex` |
| Config | `key` | Admin projection version | No | No — invalidation plus read fallback | `lib/tightbeam/admin_projection.ex` |
| Host environment | `host`, `harness`, `name` | Admin and host-environment projection versions | No | No — invalidation plus read fallback | `lib/tightbeam/admin_projection.ex`, `lib/tightbeam/placement.ex` |
| Hosts | `host` | Admin projection version | No | No — invalidation plus read fallback | `lib/tightbeam/admin_projection.ex` |
| Identity | `name` | Admin publication stamp | No | No — invalidation plus read fallback | `lib/tightbeam/admin_projection.ex` |
| Kungfu | `name` | Admin publication stamp | No | No — invalidation plus read fallback | `lib/tightbeam/admin_projection.ex` |
| Harness processes | `id` | No direct-apply version | No | No — outside the direct-apply set | `lib/tightbeam/harness_process.ex` |
| Operator ruling provenance | `submittingSessionKey` | Not exposed as a row at this tip | Not applicable | No — unavailable at this tip | No row projection or publisher is registered |

The seven required rows are intentionally not marked certified in this local
candidate: DA3.4 allows certification only after its tests pass on the
integrated 0.1.11 commit. The table is closed for the R8 surface inspected at
this tip; the integration-only certification step remains open.

## Candidate test coverage

The publisher, lifecycle, artifact, session, and version-migration tests named
in the table exercise canonical row/notice parity, supported lifecycle
transitions, same-millisecond version increments, persisted version sources
across database reopen, and the client version rule.
The generic client-model cases in `test/firehose_direct_apply_test.exs` use
synthetic rows for duplicate and out-of-order application, walk overlap,
lifecycle reversal, client restart, and visibility-boundary behavior. They do
not prove server convergence.

The server-backed cases in `test/firehose_direct_apply_test.exs` exercise
convergence through committed notices and the real REST router. The first test
mutates each required resource through its production write path, applies each
notice twice, and compares the projection with the corresponding REST
collection or detail route.
Assignments use their detail route because this candidate exposes assignment
details, not an assignment collection.

The server-backed matrix starts real paged REST walks, applies actual committed
notices while each walk is held, and compares the resulting client model with a
fresh complete walk. It replays duplicate notices for every required resource,
checks two writes at one fixed timestamp per resource, and exercises work-item
icebox/reopen, assignment close/reopen, and wake fired/pending lifecycle
reversals. For each resource it also restarts the persisted database and
Firehose Hub owners between the fixture's initial row and a follow-up mutation.
Visibility tests promote and demote the reader during an incomplete walk and
between complete walks, then compare each rebuilt model with a fresh walk. The
turns case applies a real
`turn.queued` notice while the turns model is held in a paged walk and checks
that the row remains queued in both the notice and REST snapshot.

The separate `test/firehose_cold_restart_test.exs` case holds a server-backed
client model across a full Gateway process restart. It applies post-restart
notices for each required resource, compares every notice with its REST detail
row, and then compares the final model with a fresh complete REST walk.

The seven required rows remain pending certification until DA3.1 to DA3.5 pass
for each resource on the integrated 0.1.11 commit. No DA3.7 fallback is marked
certified.
