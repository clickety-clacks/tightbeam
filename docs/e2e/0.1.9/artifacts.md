# 0.1.9 artifact custody checks

Run this area on a fresh copy of the preserved migrated database. Follow the
shared limits in the [aggregate](README.md#execution-contract). Artifact bytes
and source paths can contain private data; use only disposable fixtures and
keep content out of the scorecard.

## Scripted area

The shared [safe-stop](README.md#safe-stop-before-copied-org-gateway-boot)
blocks boot on this copied database. Do not start it until the PO records the
source-backed isolation path and this runbook names its supported use. Once
cleared, prepare a fresh area clone and use that route before the unchanged
canonical wrapper on Racter or Eezo executes:

```sh
TIGHTBEAM_BASE_DIR="$AREA_BASE" \
TIGHTBEAM_SMOKE_AREAS=artifacts \
mix run --no-start scripts/feature_smoke.exs
```

The area checks artifact-backed rule gates, then asks a real harness turn to
record the report from its actual output. It calls `artifact-content-fetch` for
that newly registered artifact and checks the structured `content_not_captured`
result against the record's ID, kind, creator, work item, digest field and turn
evidence. The current source-backed fixture lifecycle does not capture bytes, so
this is a negative/uncaptured-content check, not positive content-retrieval
coverage. The coverage map records that gap. A named single-harness run remains
incomplete for harness parity.

## Manual 0.1.9 checks

| Feature | Exercise | Pass condition |
|---|---|---|
| Artifact producer binding | On a disposable item, have its assigned holder directly run `tightbeam artifact-record --kind report --title ... --path <observed-output> --work-item <id> --produced-by-assignment <held-assignment>`. | `artifacts --work-item <id>` reports that exact producer assignment. A different holder, assignment, work item, or owner is refused. |
| Uncaptured content on a newly registered artifact | The scripted real-turn check fetches the artifact just recorded by that turn, then reads its metadata with the `artifact-get` gateway verb. | `artifact-content-fetch` returns structured `content_not_captured` with the source's `artifact has no stored content` message. The `artifact-get` gateway response has the same ID, report kind, creating session, work item and turn evidence, with no stored digest. This does not count as positive captured-content retrieval coverage; the current source-backed fixture has no capture lifecycle. The fetch reads custody only and never the origin path. |
| Artifact-attest binding | Use the supported verdict path on a disposable review assignment with a real artifact, its exact SHA, and the relevant wake ID if this verdict is a continuation. Read `attests <assignmentId>`. | The verdict carries the exact artifact ID, digest and wait ID; the relevant gate accepts only that matching custody row. |

Do not hand-write report bytes, claim output that a command did not produce, or
fetch from an origin path as a substitute for the captured-content result.
