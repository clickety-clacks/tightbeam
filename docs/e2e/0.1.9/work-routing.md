# 0.1.9 work and routing checks

This area checks work-item updates, assignment relationships, direct delivery
owner links and wake routing. Follow the shared test-host and data-isolation
rules in the [aggregate](README.md#execution-contract), and begin from a fresh
copy of the preserved migrated database described in [migration.md](migration.md).

## Scripted area

The shared [safe-stop](README.md#safe-stop-before-copied-org-gateway-boot)
blocks boot on this copied database. Do not start it until the PO records the
source-backed isolation path and this runbook names its supported use. Once
cleared, prepare a fresh area clone and use that route before the unchanged
canonical wrapper on Racter or Eezo executes:

```sh
TIGHTBEAM_BASE_DIR="$AREA_BASE" \
TIGHTBEAM_SMOKE_AREAS=work \
mix run --no-start scripts/feature_smoke.exs
```

The area creates and closes its own records. It checks work-item and assignment
reads, dispatch linking, body replace/clear, and direct delivery-owner
set/read/clear. It also checks existing facts and configuration reads. A full
run selects this same area as part of `all`.

## Manual 0.1.9 checks

Use unique throwaway work items, sessions and assignment IDs in the area copy.
Record the exact values you sent and read them back; do not use real open work.

| Feature | Exercise | Pass condition |
|---|---|---|
| Work-item create and patch fields | Create a throwaway item with `work-item-create --title ... --priority 3`. Run `tightbeam work-item-update <id> --title ... --priority 5`; set a test spec with `--spec-ref <name> --spec-sha256 <exact-sha>`, then clear it with `--clear-spec-ref`. Read with `tightbeam work-item-get <id>`. | Each selected field changes, omitted fields stay unchanged, the spec name/hash remain a pair, and the read shows the requested priority/title. |
| <a id="editable-work-item-body"></a>Editable work-item body | Create a disposable item, set a body with `work-item-update <id> --body ...`, replace it with a different body, then clear it with `--clear-body`. Read after each operation. | Each read shows the latest body or an empty body after clear; an omitted body field never resets the title, priority, or metadata. |
| Default priority | Read `config get default-priority`, set a test-only value with `config set default-priority <0..8>`, create an open throwaway work item, then read both values and restore the prior setting in the disposable org. | The setting readback matches and the new item inherits it; restoring the test base discards the temporary organization default. |
| Spawn work-item placement and dependency edges | `tightbeam spawn --display ... --work-item <id>`; attach one assignment to a second throwaway item with `assign --succeeds <prior-assignment>`. The successor remains an ordinary assignment. | `list`, `work-item-get <id>`, and `work-item-trace <id>` show the exact work-item and predecessor links requested. No edge points at a different record. |
| <a id="orchestrator-model-defaults"></a>Orchestrator model defaults | On a disposable work item, use the authorized default staffing path to spawn an `orchestrator` session without model overrides. Read its harness, model and effort alongside that host's advertised catalog. | The session defaults to `codex` with `gpt-6-luna/max` when that exact pair is advertised. If the target host cannot supply it, mark `INCOMPLETE` and stop rather than substituting a different host's catalog. |
| Direct work-item delivery owner | On a throwaway item, run `tightbeam work-item-update <id> --delivery-owner <sessionKey>` for an active disposable session, then read with `tightbeam work-item-get <id>`. Clear it with `--clear-delivery-owner` and read again. | The item names the selected direct owner, then has no owner after clearing. |
| <a id="canonical-topology"></a>Canonical session topology | Create a disposable custom child session and one open assignment linked to a test work item. Run `session-reparent --session <child> --parent <parent> --assignment <id> --key <unique>` as the authorized user, then read the session. | `topologyParent` reflects the committed parent while `spawnedBy` remains the original creation provenance; the child retains the exact open assignment. The command refuses if its preconditions do not hold. Do not reparent a production session. |
| <a id="wake-delivery-options"></a>Wake delivery | Create a held disposable assignment. Exercise a ready-now continuation with `wake --session <holder> --assignment <id> --after-turn --prompt "<continuation>"`, a predicate/fallback wait with its prompt, and a wake with an explicit delivery class and prompt. Read the durable wake and resulting turn rows. | Each wake records the requested assignment, condition/predicate, fallback or class; only the matching eligible turn is delivered. Every wake command includes the required non-empty `--prompt`. |
| <a id="replace-unread-messages"></a>Replace unread messages | Queue two eligible messages for one throwaway assignment, then issue a newer message with `wake --session <holder> --assignment <id> --replace-queued --prompt ...`. Leave a second assignment for that holder queued as a control. | Only eligible queued messages scoped to the selected assignment are canceled/replaced; the unrelated assignment, human messages and any turn that already started remain unchanged. Read the durable wake/turn history. |
| <a id="wake-cancellation-history"></a>Wake cancellation history | Schedule a disposable future wake, record its returned ID, then run `cancel-wake <wakeId>` before it becomes due. Read the wake and its event history, and inspect the holder's queue. | The original wake remains queryable with its canceled outcome, no delivery turn is created, and another wake for that holder is unaffected. |
| Condition fact payload | Publish one unique test fact with `condition --kind <kind> --scope <scope> --payload '<json>' --key <unique-key>`, then read the resulting fact and satisfy one matching disposable dependency wait. | The fact row retains the exact structured payload and scope; the matching wake resumes with that fact, while a nonmatching scope does not. |
| <a id="landing-watcher"></a>Landing watcher and process-fact wake | In a designated disposable repository, subscribe the test owner to `pr.checks-completed` with scope `<owner>/<repo>#<number>` and a bounded fallback. Let the real required checks on that open PR finish; do not publish a synthetic condition. Repeat on a second disposable PR to confirm a later process fact can wake the same test owner again. | Each completed check set produces one correctly scoped fact and matching wake; a different PR scope does not wake the subscriber. The fallback is not treated as check evidence. |
| <a id="notice-batching"></a>Notice batching | Only in a disposable org whose approved policy already selects batching for the test recipient, send two routine agent-authored `fyi` notices to that same lane and one urgent blocker. If no such lane is configured, record `INCOMPLETE` rather than editing internal policy rows. | The batch preserves both source notice IDs in publication order and delivers one carrier; urgent traffic remains on the ordinary immediate path, and each source wake remains readable. |

The predicate, queued-message replacement and `--after-turn` rows need real
turn/wake state. Call `--after-turn` from the holder's harmless live turn so it
captures that turn. If the selected gateway cannot create the stated condition
without fabricating rows, mark that check `INCOMPLETE` and name the missing
fixture.
