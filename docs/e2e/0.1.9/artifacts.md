# 0.1.9 artifact custody checks

Run this area on a fresh copy of the preserved migrated database. Follow the
shared limits in the [aggregate](README.md#execution-contract). Artifact bytes
and source paths can contain private data; use only disposable fixtures and
keep content out of the scorecard.

## Scripted area

Prepare a fresh area clone and start its gateway as described in the
[aggregate](README.md#aggregate-run). From the repository root on Racter or
Eezo, have the unchanged canonical wrapper execute:

```sh
TIGHTBEAM_BASE_DIR="$AREA_BASE" \
TIGHTBEAM_SMOKE_AREAS=artifacts \
mix run --no-start scripts/feature_smoke.exs
```

The area checks artifact-backed rule gates, then asks a real harness turn to
record the report from its actual output. After the holder retires and the
bytes enter custody, it calls `artifact-content-fetch` and checks the exact
bytes, size and SHA-256. A named single-harness run remains incomplete for
harness parity.

## Manual 0.1.9 checks

| Feature | Exercise | Pass condition |
|---|---|---|
| Artifact producer binding | On a disposable item, have its assigned holder directly run `tightbeam artifact-record --kind report --title ... --path <observed-output> --work-item <id> --produced-by-assignment <held-assignment>`. | `artifacts --work-item <id>` reports that exact producer assignment. A different holder, assignment, work item, or owner is refused. |
| Captured and uncaptured content | Fetch a captured artifact with `artifact-content-fetch <artifactId>`. If the test database contains an artifact whose content was genuinely never captured, fetch that ID as a separate negative check. | Captured bytes are base64 with matching stored size and SHA-256; uncaptured content returns `content_not_captured`. The fetch reads custody only and never the origin path. |
| Artifact-attest binding | Use the supported verdict path on a disposable review assignment with a real artifact, its exact SHA, and the relevant wake ID if this verdict is a continuation. Read `attests <assignmentId>`. | The verdict carries the exact artifact ID, digest and wait ID; the relevant gate accepts only that matching custody row. |

Do not hand-write report bytes, claim output that a command did not produce, or
fetch from an origin path as a substitute for the captured-content result.
