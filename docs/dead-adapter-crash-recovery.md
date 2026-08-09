# Proven-dead adapter crash recovery

Status: READY for implementation  
Work item: `wi_c99cd061-79c8-4f00-af49-bd36f45ba173`

## Spirit

An adapter crash must interrupt work, not permanently remove the harness from the org.
Tightbeam must still prevent two live adapters from claiming one shared key. Cleanup is
best effort after the current adapter is proven dead. A cleanup failure remains durable
evidence, but it must not become a fence that only manual database repair can clear.

## Scope

This slice changes only automatic crash recovery after the coordinator observes the
current adapter instance die. It does not weaken planned park, boot reconciliation, or
any case where Tightbeam cannot prove that the current adapter is dead.

No new state, retry worker, timeout, operator command, or schema column is required.

## Regression specimen

On 2026-08-08, `codex:shared@gibson` exited with `{:acp_exit, 137}`. The coordinator
recorded the death, but durable cleanup could not use the launch identity material. The
row became `kill_failed`, `HarnessProcess.fenced?/2` stayed true, and every replacement
attempt returned `park_fenced`. The durable transcript records the initial adapter-down
message followed by repeated failures at timestamps `1786232516672` through
`1786232883156`.

On 2026-08-09, Mike confirmed the recorded operating-system PIDs were gone and repaired
three stale rows. The live `harness-process list` result is the regression fixture:

| launch sequence | launch id | adapter key | recorded PID | kill attempted | kill sent | repaired result |
|---|---|---|---:|---:|---:|---|
| 336 | `01KZH9S0PF07YRSD7JZKHBKQTQ` | `claude:shared@gibson` | 2823430 | 1786232513094 | null | `exited`, resolved 1786239917855 |
| 337 | `01KZH9S5411WZCQ1CSD3X990R6` | `codex:shared@eezo` | 34808 | 1786232515097 | null | `exited`, resolved 1786239917855 |
| 338 | `01KZH9XCHTTNGMJ1H487DNJXMM` | `codex:shared@gibson` | 2824381 | 1786232516674 | null | `exited`, resolved 1786239917855 |

The implementation must turn the same pre-repair shape into a normal automatic recovery:
a recorded launch, an observed current-instance death, no confirmed kill delivery, a
durable cleanup error, no remaining fence, and one serving successor.

## Current cause

The coordinator observes the matching monitor `:DOWN` and records the adapter death, then
calls `HarnessProcess.reconcile_key/2` before scheduling a restart
(`lib/tightbeam/adapter_coordinator.ex:517-604`). Reconciliation establishes a durable
park fence and tries to recover or verify the launch identity
(`lib/tightbeam/harness_process.ex:297-315`). Missing, invalid, or unusable identity calls
`kill_failed/3` (`lib/tightbeam/harness_process.ex:338-347,427-465,902-918`). Both the
unresolved `kill_failed` row and the explicit park row count as fences
(`lib/tightbeam/harness_process.ex:238-257`). The scheduled restart therefore stops at
the fence (`lib/tightbeam/adapter_coordinator.ex:632-641`).

This is a category error. The matching monitor death is capability truth: the coordinator
can no longer use that adapter instance. The later group-kill attempt is cleanup truth.
Today, a cleanup error reverses the already-observed capability truth.

## Required design

### 1. Keep the existing duplicate fence

The matching `:DOWN` handler remains the only crash-recovery authority. It runs inside the
single coordinator process. Before a successor can start, it asks the durable launch owner
to settle the one unresolved row for the key. `prepare_launch/3` must continue to refuse a
new launch while that settlement is in progress.

An absorbed stale `:DOWN` must remain record-only. It must not settle the row for the
replacement already held by the entry.

### 2. Add one proven-dead settlement path

Add a narrowly named HarnessProcess operation for the matching current-instance death.
The operation must:

1. Establish the existing per-key park fence.
2. Select the one unresolved launch for that key under the existing invariant.
3. Attempt the existing identity recovery and authorized process-group kill.
4. On confirmed kill, resolve the row exactly as today.
5. On missing, invalid, refused, or timed-out cleanup, resolve the row as `exited`, retain
   the cleanup reason in `lastError`, and append a lifecycle event containing the adapter
   key, launch id, phase, and reason.
6. Clear the explicit park fence after either terminal result.

The caller then performs the existing generation bump, backoff, context capture, and
single successor start. Cleanup failure must not change that restart schedule.

The operation must be idempotent. A repeated call after terminal resolution returns
`already_resolved` and neither starts nor authorizes another adapter.

### 3. Do not broaden proof

The new path is legal only when `AdapterCoordinator` handles the matching monitor for the
entry it currently owns. Do not expose a public CLI or infer death from a missing identity
file, an old timestamp, a failed signal, a failed SSH connection, or an unresolved database
row.

Keep the current fence for:

- boot reconciliation without a live coordinator observation;
- planned close or park when the adapter may still be alive;
- remote hosts whose liveness cannot be read;
- invalid identity material when no matching current-instance death was observed.

The existing negative tests for planned close and boot-time `kill_failed` remain valid.

### 4. Keep failure visible

Do not clear `lastError` when cleanup fails. Use one lifecycle kind for this condition,
`harness_cleanup_failed`, with durable detail containing `launch_id`, `phase`, and `reason`.
The old launch is terminal and non-fencing; the record, not availability loss, is the
operator surface.

`adapter_reconcile_failed` may remain for unresolved reconciliation failures outside this
proven-dead path. It must not be emitted for a cleanup failure that the new path settles.

## Acceptance

1. A matching current adapter death with missing identity material records
   `harness_cleanup_failed`, resolves the old launch, clears the park fence, and starts one
   successor.
2. The successor reaches ready state and can serve a real turn.
3. Concurrent checkout and restart signals cannot create two successor launch rows or two
   live adapter PIDs for one key.
4. A repeated settlement is inert.
5. Planned close with unusable identity remains refused and fenced.
6. Boot reconciliation with unusable identity and no proof of death remains refused and
   fenced.
7. A table-driven regression fixture covers the three repaired rows above, including local
   and remote adapter keys, `killAttemptedAt` present, and `killSentAt` absent.
8. Focused tests cover the HarnessProcess state transition and the coordinator restart.
9. A controlled local smoke removes or corrupts the identity file, terminates the current
   adapter through the real crash path, observes one replacement become ready, and runs one
   real turn. The smoke must preserve the resulting ledger and lifecycle rows.

## Compatibility

This is an internal lifecycle correction. It changes no CLI or wire shape and needs no
database migration. Existing terminal rows remain readable. Existing unresolved
`kill_failed` rows are not guessed safe at boot and are not auto-rewritten; only a future
observed matching death can use the new settlement path. The three live rows already
repaired by Mike remain historical evidence and need no further mutation.

## Subtraction ruling

Delete the indefinite cleanup gate for proven-dead crash recovery. A retry queue, lease,
TTL, new state, and operator unstick command all lose because they preserve a hold after the
capability decision is already known. Unknown-liveness cases keep the existing fence; that
is where duplicate protection still has a subject.
