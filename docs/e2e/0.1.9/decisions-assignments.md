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

It checks an effort check-in, an independent review loop, and a
`cannot-proceed` request reaching its opener. The request check reads its
durable row; it does not treat a command response alone as proof.

## Manual 0.1.9 checks

| Feature | Exercise | Pass condition |
|---|---|---|
| <a id="liveness-from-progress-receipts"></a>Liveness from progress receipts | On an open throwaway assignment, have its actual holder file one `attest <id> --kind progress --note ...`. Read `attests <id>` and then the assignment's `breathing` result from an authorized observer. | The persisted receipt names the same assignment and holder, and the physical liveness read reflects that receipt once; with no receipt, the read does not invent activity. |
| <a id="cannot-proceed-replacement"></a>Typed `cannot-proceed` replacement for terminal surrender | On a throwaway assignment, have its actual holder run `tightbeam attest <id> --kind cannot-proceed --note "blocked on disposable fixture"`. Read `attests <id>`, the assignment and the opener's decision inbox. | One typed block receipt is durable, the assignment remains open, and the exact opener receives its linked decision. The separate source-CI check confirms the removed terminal surrender route cannot close the assignment. |
| Ask and answer | Use `tightbeam ask --session <throwaway-session> --question ... --about <test-assignment>` to open a request. Read it with `decision-requests --status open` and `decision-request --request <id>`, then answer it from its addressed session with `answer --request <id> --answer ...`. | The request is initially open, the addressed session is exact, and readback shows it answered with the submitted response. |
| Return a request | Open a second throwaway request and use `return --request <id> --reason ...` from its authorized holder. | Readback shows the returned state and reason; the first request remains answered and unchanged. |
| <a id="completion-handoff"></a>Completion handoff | With a disposable parent that has an open assignment, run a child to a real terminal completion. Read the parent's received handoff notice and its exact source attest, then have the parent use the shipped `completion-handoff-action <assignment_id> <source_kind> <source_token> <kept|parked|retired> — <what you did>` directive for that child. | The parent's notice names that child and terminal source; its matching action is retained as progress and stops the reminder chain. An unrelated or stale source token does not stop it. This also verifies that the idle parent is reactivated for a new child notice. |
| <a id="completion-while-blocked"></a>Completion while blocked | Give a disposable successor assignment an unfinished predecessor. Attempt its completion attest before the predecessor completes, then complete the predecessor and retry. | The first attempt is refused and the successor remains open; after the real blocker clears, one completion closes it. |
| <a id="stop-and-redirect"></a>Stop and redirect | Start one harmless turn on a throwaway assignment, stop it with `assignment-stop-turn <assignment> --reason ...`, then send the replacement instruction to the intended disposable holder. | The old turn reaches its stopped outcome before the replacement turn begins; readback ties the new message to the selected holder and leaves other queued work alone. |
| <a id="stop-running-turn"></a>Stop a running assignment turn | Start a deliberately long, harmless turn on a throwaway assignment. Record its session and turn sequence, then run `assignment-stop-turn <assignment> --reason ...`. | The exact in-flight turn reaches the documented stopped outcome and no unrelated turn or assignment changes. Do not issue this command against an ordinary active assignment. |
| Revoke with reason | Revoke a separate open test assignment using `revoke-assignment <id> --reason ...`. | The exact assignment closes and `assignment-get`/`work-item-trace` retain the reason; no other assignment changes. |
| Reopen an assignment | Close a disposable assignment through its supported terminal path, then run `reopen-assignment <id> --reason ...`. | Readback shows the same assignment reopened according to the command's response contract; its work-item and holder links remain exact. |
| <a id="failed-turn-remains-failed-and-can-be-redelivered"></a>Failed turn remains failed and can be redelivered | Use only a genuine failed turn in the disposable org. Read its failed outcome before choosing one supported `repair-assignment <id> --action tune|restart|rerun|resume|relaunch --key ...` action, then read the new turn and assignment. | The original turn remains failed; the repair creates only the requested recovery attempt, and its terminal result is independently reported. A timeout that is still running is not a failed-turn fixture. Mark `INCOMPLETE` if no genuine failed turn occurs. |
| Repair a failed assignment | Use a genuine failed or never-launched disposable turn and run one appropriate `repair-assignment` action with the required evidence and explicit key. | The response and subsequent assignment/turn reads show only the requested repair action. A merely slow or running turn is not a failed-turn fixture. |
| <a id="timeout-diagnostics"></a>Timeout diagnostics | On an isolated gateway with a short test turn-timeout setting, send a harmless prompt that exceeds the limit, then read its turn and transcript. | The turn settles as timed out, the diagnostic identifies the timeout phase, and no success or unrelated failure is substituted. If the test host cannot set a bounded turn timeout, mark `INCOMPLETE`. |
| <a id="error-fidelity"></a>Error fidelity | Make a safe read for a fresh, nonexistent work-item or assignment ID through the packaged CLI. Capture its returned error envelope and read the work-item trace. | The CLI preserves the server's specific not-found code/message (and structured diagnostic when supplied); the failed read creates no work or assignment record. |
| Verdict evidence, wait binding and release-fact tuple | On a disposable assignment where the relevant real release fact exists, file a `cannot-proceed` with its complete release-fact kind/scope/principal tuple. On an independently reviewed test assignment, file a verdict with a real artifact ID and matching SHA and, where the verdict waited on one, its exact wake ID. | Partial release tuples and mismatched artifact/digest pairs refuse. Readback retains the complete tuple, artifact/digest pair and wait ID; no release fact is invented for the smoke. |
| Correct commit references | On a completed disposable assignment, file a real artifact with the actual repository evidence, then run `assignment-commitref-correct` with the artifact ID, reason, idempotency key and corrected commit refs. | The correction row is visible on the assignment trace, cites the exact evidence artifact, and the effective commit refs match that artifact. Never invent a commit or evidence pointer. |
| <a id="stale-turn-settlement"></a>Settle a stale turn | Establish from read-only process and durable turn state that a disposable turn is stale. Run `settle-turn --session <session> --seq <seq> --outcome cancel|fail --reason ... --key ... --as-user <adminUserId>`. | Only the proven stale turn is settled and its durable outcome matches the request. An active process is a refusal, not permission to force settlement. |

If no genuine failed or stale turn can be established, mark the corresponding
row `INCOMPLETE`; do not synthesize a provider failure or edit database rows.
