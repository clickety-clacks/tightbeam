# 0.1.9 decision and assignment checks

Run this area against a fresh copy of the preserved migrated database. Follow
the shared limits in the [aggregate](README.md#execution-contract). Every request
and assignment below must belong to the disposable test org.

## Scripted area

Prepare a fresh area clone and start its gateway as described in the
[aggregate](README.md#aggregate-run). From the repository root on Racter or
Eezo, have the unchanged canonical wrapper execute:

```sh
TIGHTBEAM_BASE_DIR="$AREA_BASE" \
TIGHTBEAM_SMOKE_AREAS=decisions \
mix run --no-start scripts/feature_smoke.exs
```

Start this gateway clone with `TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS=250` as in
the aggregate setup so the effort check-in uses the bounded test horizon.

It checks an effort check-in, an independent review loop, and a cannot-proceed
request reaching its opener. The request check reads its durable row; it does
not treat a command response alone as proof.

## Manual 0.1.9 checks

| Feature | Exercise | Pass condition |
|---|---|---|
| Ask and answer | Use `tightbeam ask --session <throwaway-session> --question ... --about <test-assignment>` to open a request. Read it with `decision-requests --status open` and `decision-request --request <id>`, then answer it from its addressed session with `answer --request <id> --answer ...`. | The request is initially open, the addressed session is exact, and readback shows it answered with the submitted response. |
| Return a request | Open a second throwaway request and use `return --request <id> --reason ...` from its authorized holder. | Readback shows the returned state and reason; the first request remains answered and unchanged. |
| Verdict evidence, wait binding and release-fact tuple | On a disposable assignment where the relevant real release fact exists, file a `cannot-proceed` with its complete release-fact kind/scope/principal tuple. On an independently reviewed test assignment, file a verdict with a real artifact ID and matching SHA and, where the verdict waited on one, its exact wake ID. | Partial release tuples and mismatched artifact/digest pairs refuse. Readback retains the complete tuple, artifact/digest pair and wait ID; no release fact is invented for the smoke. |
| Revoke with reason | Revoke a separate open test assignment using `revoke-assignment <id> --reason ...`. | The exact assignment closes and `assignment-get`/`work-item-trace` retain the reason; no other assignment changes. |
| Stop a running assignment turn | Start a deliberately long, harmless turn on a throwaway assignment. Record its session and turn sequence, then run `assignment-stop-turn <assignment> --reason ...`. | The exact in-flight turn reaches the documented stopped outcome and no unrelated turn or assignment changes. Do not issue this command against an ordinary active assignment. |
| Reopen an assignment | Close a disposable assignment through its supported terminal path, then run `reopen-assignment <id> --reason ...`. | Readback shows the same assignment reopened according to the command's response contract; its work-item and holder links remain exact. |
| Repair a failed assignment | Use a genuine failed turn in the disposable org. Run one appropriate `repair-assignment <id> --action tune|restart|rerun|resume|relaunch` with the required evidence and explicit key. | The response and subsequent assignment/turn reads show only the requested repair action. A merely slow or running turn is not a failed-turn fixture. |
| Correct commit references | On a completed disposable assignment, file a real artifact with the actual repository evidence, then run `assignment-commitref-correct` with the artifact ID, reason, idempotency key and corrected commit refs. | The correction row is visible on the assignment trace, cites the exact evidence artifact, and the effective commit refs match that artifact. Never invent a commit or evidence pointer. |
| Settle a stale turn | Establish from read-only process and durable turn state that a disposable turn is stale. Run `settle-turn --session <session> --seq <seq> --outcome cancel|fail --reason ... --key ... --as-user <admin>`. | Only the proven stale turn is settled and its durable outcome matches the request. An active process is a refusal, not permission to force settlement. |

If no genuine failed or stale turn can be established, mark the corresponding
row `INCOMPLETE`; do not synthesize a provider failure or edit database rows.
