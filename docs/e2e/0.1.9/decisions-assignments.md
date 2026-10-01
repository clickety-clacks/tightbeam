# 0.1.9 decision and assignment checks

Use the [fresh-base actors](README.md#fresh-base-actors), matching package and
[CLI shell](README.md#cli-shell). `test_admin` is the admin of this disposable
base; `as_actor <workdir>` carries a test session's identity. Create only
area-owned items and assignments. Record admission refusals and missing actors
as setup limits; never fabricate rows or borrow live tokens.

Rows labelled **Fresh / records** check durable operations through admitted
test actors. **Fresh / online** needs the stated real runtime or external
service. Record each prerequisite and use the [scorecard](README.md#scorecard).
A queued turn alone is not evidence of delivery or a reply. Every database
inspection uses `sqlite3 -readonly "$AREA_BASE/state.db"` and named columns.

Read assignments through `work-item-get <wi>` (`assignments[]`) or
`attests <id>`. The smoke `decisions` area owns the effort check-in and selects
the one shared review/verification/artifact gate chain. If `artifacts` is also
selected, cite that same chain rather than running another. Its effort check
needs `TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS=2500` at gateway start; record the
setting and restore nothing in a live environment.

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| <a id="cannot-proceed"></a>`cannot-proceed` replaces surrender | Fresh / records | Dispatch a test assignment from the opener to the holder. As the holder, run `attest <id> --kind cannot-proceed --note "blocked on disposable fixture"`, repeat it unchanged, then run it with a different note. Then run `attest <id> --kind surrender --note x` as the holder. Read `attests <id>`, `work-item-get <wi>` and the opener's `decision-requests --status open`. | The first call returns `assignment`, `attest`, `cannotProceed` (a `cp_` id), `decisionRequest` and `decisionWake`; the assignment stays open and the opener holds the linked request. The unchanged repeat replays; the changed note is refused `cannot_proceed_conflict`. `--kind surrender` is refused `invalid_kind`. |
| Standing cannot-proceed blocks answer and completion | Fresh / records | On the same assignment, have the opener run `answer --request <dr> --answer x` and `return --request <dr> --reason x`, and the holder attempt `attest <id> --kind completion --note x`. Then have the opener run `revoke-assignment <id> --reason "fixture done"`. | `answer` and `return` are refused `cannot_proceed_standing`, as is the completion. The revoke closes the assignment. |
| Ask and answer | Fresh / records | As the holder of a test assignment, run `ask --session <opener> --question ... --about <assignment>`. Read `decision-request --request <id>` and `decision-requests --status open` as the opener, then answer with `answer --request <id> --answer ...` as the opener. Also try `ask` with `--session` naming the asker. | The request opens addressed to the opener. After the answer, `decision-request --request <id>` shows status `answered` with `answer` and `answeredBy`. Asking yourself is refused `invalid`. |
| Return a request | Fresh / records | Open a second request the same way and run `return --request <id> --reason ...` as the opener. Read both requests with `decision-requests --status all`. | The second shows `returned` with `returnReason` and `returnedBy`; the first is still `answered`. |
| <a id="liveness-superseded-by-progress"></a>Liveness superseded by progress | Fresh / records | Start the area gateway with a short `TIGHTBEAM_SUPERVISION_INTERVAL_MS`. Dispatch a test assignment, then have its holder file `attest <id> --kind progress --note ...`. After one supervision interval read `attests <id>` and `work-item-trace <wi>`. Repeat on a second test assignment with no progress attest. | One progress attest by the holder. The trace shows `wake_canceled` for the first assignment with reasonKind `superseded` and causalSourceKind `supervision_receipt`. The second assignment shows no such cancel. |
| <a id="completion-while-blocked"></a>Completion while blocked | Fresh / records | On a test assignment, the holder files `attest <id> --kind verdict --verdict blocked --note ...` and then attempts `attest <id> --kind completion --note ...`. The holder then files `--verdict cleared` and retries completion once. | The first completion is refused `completion_blocked` and the assignment stays open. After `cleared`, one completion closes it. |
| Verdict evidence and release tuple | Fresh / records, conditional | Reuse [verdict binding](artifacts.md#verdict-binding). If this test base holds a genuine applicable release fact, file a separate cannot-proceed with its complete kind, scope and principal tuple and read it back. | The tuple is retained exactly; without the prerequisite, record that positive case skipped. Partial flags and malformed IDs stay in CLI tests, not runtime scorecard rows. |
| <a id="completion-handoff"></a>Completion handoff | Fresh / online | A parent holds an open assignment and dispatches a child. The child completes. Read the parent's delivered notice and the child's closing attest id. As the parent, file `attest <parentAsg> --kind progress --note "completion-handoff-action <childAsg> attest <closingAttestId> kept — <detail>"` (the dash is U+2014). Repeat the setup and file the note with a wrong attest id. | The notice names the child and its closing attest. The matching note cancels the reminder chain: `work-item-trace` shows `wake_canceled` reason `superseded` with source `progress_attest`. The wrong token leaves the 2-hour reminder pending. |
| <a id="stop-running-turn"></a>Stop and resume an assignment turn (U5) | Fresh / online | Cite the [replace, stop and resume journey](work-routing.md#replace-unread-messages); a standalone decisions run follows that one journey. | Require its non-opener no-write refusal, exact canceled turn, actor/reason audit and actual next correction reply in the same session. Do not repeat the stop as a second lifecycle. |
| Revoke with reason | Fresh / records | Run `revoke-assignment <id> --reason ...` as the opener. Read `work-item-get <wi>`. | The assignment shows outcome `revoked` and `revocationReason` equal to the reason; no other assignment changes. |
| Reopen an assignment | Fresh / records | Complete a test assignment, then run `reopen-assignment <id> --reason ...` as its opener. Try again on the now-open assignment. | The same assignment is open again with `outcome` and `closedBy` fields cleared, and its work item and holder unchanged. The second call is refused `assignment_open`. |
| Repair entry controls | Fresh / records; relaunch online | As opener on an open test assignment with no incident, call `repair-assignment <id> --action restart --key <unique>`. For an admitted idle test session with its real provider authorized, use `--action relaunch` once and read the returned action plus resulting runtime/turn. | Restart refuses `no_open_incident`. Relaunch is accepted through its normal runtime path; preserve actual outcome and cleanup. A missing runtime is a relaunch gap, not an offline pass. This does not count as failed-runner recovery. |
| <a id="repair-assignment"></a>Repair an assignment (U7) | Conditional authorized incident | Follow [incident evidence](#incident-evidence): reconcile the real failed turn, use only its sanctioned repair action and replay the exact key/request. | One repair effect, one returned result, original failed-turn history retained. A replay is not permission to execute recovery again. No incident means that specific E2E recovery remains skipped. |
| <a id="failed-turn-escalation"></a>Failed-turn escalation | Conditional incident | If an already authorized test incident reaches six consecutive failed/failed_unknown turns, read its `patrol_failure_streaks` and `patrol_failure_escalations` rows and the routed notice. Do not enqueue six doomed prompts to manufacture it. | The streak has `thresholdState: escalated`, an escalation ID and cause `consecutive_turn_failures`, with the accountable recipient recorded. This is separate from rate-limit successor recovery below. Without this incident, retain `test/escalation_delivery_test.exs` and report missing E2E escalation evidence. |
| Settle a stale turn | Fresh / records; incident conditional | As the test admin, run `settle-turn --session <s> --seq <seq> --outcome fail --reason x --key k --as-user "$test_admin"` for a turn that already ended, and the same as a test session. Only for a turn shown stale from read-only process and turn state, run it with `--outcome cancel` or `fail`. | The ended turn is refused `turn_not_running`, and the session principal is refused `not_authorized`. Only that turn settles, `canceled` or `failed` as requested. A live turn is refused `turn_live`. With no proven stale turn, record the online half `skipped`. |
| Correct commit references | Fresh / online | On a completed test assignment whose work is in a real test repository, record an artifact of the evidence with `--sha256`, then run `assignment-commitref-correct` with that artifact, a reason, `--key` and refs naming `repo` (`host:/abs/path`), `remote`, `ref` and `commit`. Run it a second time. | `work-item-trace` shows a `commit_ref_correction` entry citing the artifact, and the effective commit refs are the submitted, git-verified refs. The second call is refused `correction_exists`. Never invent a commit. |
| Error fidelity | Fresh / records | Run `work-item-get wi_00000000-0000-4000-8000-000000000000`, `work-item-trace` with the same id, and `attests asg_00000000-0000-4000-8000-000000000000`. | The CLI prints `code: message (requestId)` and a JSON envelope with `ok: false`, `httpStatus` and the whole `error`. The codes are `unknown_work_item`, `not_found` and `unknown_assignment`. No record is created. |
| Turn timeout and manager-only recovery | Source only | Retain the focused source tests; no 30-minute hang or internal-process crash in this run. | No E2E acceptance claim. Ordinary gateway restart or manual settlement does not exercise the manager-only recovery race. |

If no genuine failed or stale turn occurs, record that half `skipped`. Never
synthesize a provider failure or edit database rows.

## Incident evidence

These are separate conditional rows, not alternative ways to pass a generic
recovery cell. Use only genuinely encountered incidents on this authorized
fresh test base, with any repair/credential action separately authorized.
Record the initial incident, source message/wake/turn, session, assignment,
work item, action, recovery observation and resulting IDs. Public reads and
named-column read-only queries of private scratch provide the evidence.
Never print credential values, force a rate limit, expire/revoke a grant,
kill a manager, fabricate failure rows or relabel an ordinary stop as failure.

| Incident prerequisite | Safe observation/action | Required outcome | Source control when absent |
|---|---|---|---|
| Genuine provider rate limit on an assignment-bound wake (#64) | Read the terminal turn and source wake, then observe the normal recovery scheduler and its successor without reissuing the prompt. | One deterministic pending successor preserves the original intent, assignment and work lineage; repeated observation yields the same successor ID. Record its actual later delivery separately if recovery becomes possible. Six unrelated failures are not this outcome. | `test/failed_turn_intent_test.exs`, including the deterministic successor and assignment-bound retry cases |
| Failed runner with a recorded, authorized repair (#48) | Reconcile possible effects first. As its opener call `repair-assignment <A> --action <incident-sanctioned action> --key <unique>` with any other required action arguments. Save the result, replay that exact call/key and inspect runtime/turn records. | Replay returns the stored result, no second restart/relaunch/rerun effect is observed, and original terminal history remains failed. An unknown outcome is not authorization for another key. | `test/gateway_test.exs` repair cases for outcome reconciliation, restart/model repair and exact-key replay |
| Recognized typed ACP incident (#153) | Observe the recorded typed failure, a genuinely healthy observation and automatic recovery. Do not send a replacement prompt. | Exactly one redelivery of the original message, retaining message/assignment/work/author metadata; original failed turn retained, new turn identity distinct. Existing queued traffic is not duplicated. Plain error text, normal cancellation or a manual repair does not satisfy this row. | `test/harness_health_test.exs` and `test/support/harness_health_redelivery_restart.exs` |

Terminal credential suppression/redirect/standing notice and already-unreachable
host status are separate rows in
[provider recovery](provider-runtime.md#provider-recovery). Each incident cell
records its own result and missing prerequisite. An absent event leaves a
named E2E gap even when its focused source suite is green.
