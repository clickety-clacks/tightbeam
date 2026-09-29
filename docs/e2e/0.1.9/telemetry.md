# 0.1.9 telemetry and durable Topline checks

Run this area on a fresh copy of the preserved migrated database. Follow the
shared limits in the [aggregate](README.md#execution-contract).

## Scripted area

The shared [safe-stop](README.md#safe-stop-before-copied-org-gateway-boot)
blocks boot on this copied database. Do not start it until the PO records the
source-backed isolation path and this runbook names its supported use. Once
cleared, prepare a fresh area clone and use that route before the unchanged
canonical wrapper on Racter or Eezo executes:

```sh
TIGHTBEAM_BASE_DIR="$AREA_BASE" \
TIGHTBEAM_SMOKE_AREAS=telemetry \
mix run --no-start scripts/feature_smoke.exs
```

It checks a physical idle work-item `breathing` result; an `execution-map` row
and exact `execution-map-select --under` result; durable Topline create,
update, work/concern links, history, close and reopen; and the computed
Toplines roster, state filter and tree. The roster check creates its own work
item, so it does not depend on another area.

## Manual 0.1.9 checks

| Feature | Exercise | Pass condition |
|---|---|---|
| <a id="deterministic-liveness"></a>Breathing for active targets | Create a harmless running turn on a disposable session, then query `breathing session <key>` and `breathing assignment <id>`; also query `breathing work-item <id>` before and after its turn. | Each result has `schema=breathing-v1`, the requested target identity, a boolean and evidence rows derived from the same durable snapshot. Running and idle observations agree with the real turn state. |
| <a id="worker-queue-summary"></a>Worker queue summary | As the authorized opener of a throwaway assignment, queue two harmless messages to its holder and run `breathing assignment <id>`. Repeat as an unrelated test user and against a different assignment. | The opener sees only that assignment's queued-turn count, oldest age and sender summary; the unrelated user is refused and no scheduled wake is counted as an already queued turn. |
| <a id="advancing-query-owner-rail"></a>Advancing query and owner rail | Select two disposable assignments with `execution-map-select --assignments ...`; move one under a different authorized direct delivery owner, then run the same selection and its `breathing assignment` reads again. | The later query reflects the committed owner and current queue/liveness evidence from one snapshot; the other assignment stays unchanged and no unowned row is silently attributed to the new owner. |
| Execution-map selection by assignment | Run `execution-map-select --assignments <comma-separated test IDs>` for two disposable assignments, including one deliberately unlinked item only if that state arose through supported APIs. | Every visible assignment resolves to its item; a truly unlinked assignment appears in `noItem`, never disappears. |
| Durable Topline read filters | Read `toplines --state open|closed|all`, `topline <id> --history`, and `topline-placement-list --state pending|resolved|all` for records created by this area. | State filters preserve the corresponding visible subset; history includes the recorded mutations; placement reads show exact owner, work item, state and resolution provenance. |
| Leave a work item unlinked | Run `topline-work-leave-unlinked <workItemId> --reason ... --key ...` only for a real pending placement obligation visible to the test owner. | The placement becomes `left_unlinked` with the requested reason and a durable history entry. If no pending placement exists, record `INCOMPLETE`; do not insert a row manually. |

Use one mutation key per operation, and use a different key when intentionally
testing idempotent replay. A replay of the same key and same request returns the
same result; reusing the key for different arguments must refuse with a conflict.
