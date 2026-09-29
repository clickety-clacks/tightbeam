# 0.1.9 work and routing checks

This area checks work-item updates, assignment relationships, delivery
responsibility and wake routing. Follow the shared test-host and data-isolation
rules in the [aggregate](README.md#execution-contract), and begin from a fresh
copy of the preserved migrated database described in [migration.md](migration.md).

## Scripted area

Prepare a fresh area clone and start its gateway as described in the
[aggregate](README.md#aggregate-run). From the repository root on Racter or
Eezo, have the unchanged canonical wrapper execute:

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
| Default priority | Read `config get default-priority`, set a test-only value with `config set default-priority <0..8>`, create an open throwaway work item, then read both values and restore the prior setting in the disposable org. | The setting readback matches and the new item inherits it; restoring the test base discards the temporary organization default. |
| Spawn work-item placement and dependency edges | `tightbeam spawn --display ... --work-item <id>`; attach one assignment to a second throwaway item with `assign --succeeds <prior-assignment>`. In a separate disposable branch use `--delegates-delivery` where the successor actually accepts that obligation. | `list`, `work-item-get`, and `assignment-get` show the exact work-item, predecessor and delegation relationships requested. No edge points at a different record. |
| Work-item delivery scope | On a throwaway custom session, associate its exact PO role with `session-po-set`. Bind a throwaway item with `work-item-delivery-scope-set` using the current association revision, then set the accountable scope owner with `delivery-scope-owner-set`. Read `delivery-responsibility-get`. | The accepted association and owner revisions match the returned responsibility history; the item resolves to the intended scope and accountable session. |
| Session parent correction | Create a disposable custom session and one open assignment linked to a test work item. Run `session-reparent --session <child> --parent <parent> --assignment <id> --key <unique>` as the authorized user. | The child has the requested parent and retains the exact open assignment; the command refuses if its preconditions do not hold. Do not reparent an active production session. |
| Wake delivery options | Create a held disposable assignment. Exercise one ready-now continuation with `wake --session <holder> --assignment <id> --after-turn`, one predicate/fallback wait, and one assignment-targeted queued replacement on a queue you created. Exercise an explicit delivery class on a separate test wake. | Each wake row records the requested assignment, condition/predicate, fallback or class; replacement affects only eligible queued messages for that holder and assignment. Read durable wake/message rows after delivery. |
| Condition fact payload | Publish one unique test fact with `condition --kind <kind> --scope <scope> --payload '<json>' --key <unique-key>`, then read the resulting fact and satisfy one matching disposable dependency wait. | The fact row retains the exact structured payload and scope; the matching wake resumes with that fact, while a nonmatching scope does not. |
| Delivery scope revision conflict | Repeat one scope mutation with its old expected revision. | It returns the supported conflict/refusal and leaves the accepted owner/revision unchanged. |

The predicate, queued-message replacement and `--after-turn` rows need real
turn/wake state. Call `--after-turn` from the holder's harmless live turn so it
captures that turn. If the selected gateway cannot create the stated condition
without fabricating rows, mark that check `INCOMPLETE` and name the missing
fixture.
