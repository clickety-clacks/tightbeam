# 0.1.9 work and routing checks

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

The smoke `work` area owns facts/configuration reads and the basic
work-item/assignment/dispatch wiring pass. The rows here own distinct CLI
field changes, body preservation, current-owner routing and queue behavior.
Do not repeat their CRUD lifecycles in smoke.

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| Work-item fields | Fresh / records | As the admin, create a test item with `work-item-create --title ... --priority 3`. Run `work-item-update <id> --title ... --priority 5`, then `--spec-ref <name> --spec-sha256 <64 hex>`, then `--clear-spec-ref`. Read `work-item-get <id>` after each. | Each read shows only the requested change; omitted fields are unchanged; the spec name and hash appear and clear together. |
| <a id="editable-work-item-body"></a>Editable work-item body | Fresh / records | On a test item with recorded title, priority, metadata and bound spec name/hash, run `work-item-update <id> --body "first"`, again with `--body "second"`, again with `--body "second"`, then `--clear-body`. Read `work-item-get <id>` after each. | `workItem.body` shows the latest text, and `bodyUpdate` carries `state`, `byteLength`, `sha256`, `changed` and the updater. The repeated body shows `changed: false`. After the clear, `body` is null and `bodyUpdate.state` is `absent`. Title, priority, metadata and the spec name/hash never change. This is the sole aggregate body lifecycle. |
| Default priority | Fresh / records | Run `config get default-priority`, then `config set default-priority 2` as the admin, create a test item with no `--priority`, read it, then set the setting back to its first value. | The setting reads back as 2 and the new item has priority 2. The restored value matches the first read. |
| <a id="delivery-owner"></a>Current delivery owner (U6) | Fresh / records; receipt online | Follow the [owner/topology journey](#owner-topology-journey), including owner set/read/replace/clear and a child terminal event after replacement. | The owner field reads back exactly, the worker retains assignment/provenance, and the terminal notice routes to the current eligible owner without a stale-owner duplicate. A stored owner link alone is not notice evidence. |
| Successor assignment | Fresh / records | Dispatch assignment A on a test item and close it. Dispatch assignment B with `--succeeds <A>`. Then try `--succeeds` naming an open assignment. Read `work-item-get <wi>`. | B's `subject` ends with `Ruled-but-unconsumed decisions carried from <A>: ...` and an `assignment-successor-created` fact is scoped to B. The open predecessor is refused `predecessor_not_terminal`. |
| <a id="canonical-topology"></a>Canonical topology and session-principal reparent (U6) | Fresh / records | Use the same [owner/topology journey](#owner-topology-journey). Deliberately inspect a Main-proxy edge and have the delivery-owner session reparent its own worker. | `topologyParent` distinguishes the proxy edge from `spawnedBy`; the authenticated session reparent changes current coordination, not historical opener/owner/holder/spawn provenance. The same-key replay has one event. |
| <a id="wake-delivery-options"></a>Dependency wait | Fresh / records | On a test item, open assignment H (the waiter), R (the resolver) and V (the verifier). As H's holder, run `wake --session <H holder> --assignment <H> --fallback-after 1h --prompt "resolver closed" --predicate '{"conditions":[{"fact":"assignment.state","op":"eq","value":"closed"}],"bindings":{"assignmentId":"<R>"},"resolverRef":{"kind":"assignment","id":"<R>"},"necessity":"R owns the required output.","verificationRef":{"kind":"assignment","id":"<V>"}}'`. Read the `turns` table for its `wakeId`. Revoke R with a reason, wait one wake tick, and read again. Also run the same wake as a user. | Before R closes, no turn carries the wake's ID. After R is revoked, one turn does, with the prompt. The user caller is refused `invalid_wait`. |
| Ready-now continuation | Fresh / online | From inside a harmless running turn of H's holder, have it run `wake --session <itself> --assignment <H> --after-turn --prompt "continue"`. Read the `turns` table after the turn ends. Run the same command from a session with no running turn. | Exactly one later turn carries the continuation's wake ID, and it starts only after the capturing turn ended. With no running turn: `no_running_turn`. |
| Delivery class | Fresh / records | As a test session, send `wake --session <other> --class blocker --prompt ...` and `wake --session <other> --class not-a-class --prompt ...`. Read `class` for both wake IDs from the `wakes` table. | Each wake stores the class its sender gave. The unknown class is accepted, not refused. |
| <a id="replace-unread-messages"></a>Replace, stop and resume (U5) | Fresh / online | Follow [queue correction](#queue-correction), including the still-queued dispatch prompt, another sender, and the real resumed correction. | Superseded source messages stay auditable; stop records its actor/reason; the newest correction runs next in the same session. The running turn and different-sender message survive replacement; only the authorized stop cancels the current turn. |
| <a id="wake-cancellation-history"></a>Wake cancellation history | Fresh / records | As H's holder, register another [dependency wait](#wake-delivery-options) on H naming a resolver that stays open, and a third as a control. Run `cancel-wake <wakeId>` from the holder, then again. Try cancelling the control from a different session. Read `work-item-trace <wi>` and the `turns` table. | The first cancel returns `canceled: true`, the second `canceled: false`. The trace shows `wake_canceled` for that wake with reason `requester_withdrew`. No turn carries its ID. The other session's cancel leaves the control pending. |
| Consequence condition fact | Fresh / records | On an assignment with at least one attest, as its holder, publish `condition --kind obligation-consequence-changed --scope <asg> --key <unique> --payload '<object>'` with exactly `assignmentId` (the scope), `consequenceKey`, `revision`, `attentionRequestId`, `evidenceAttestId` and boolean `explicitAttention`. | The fact is kept with its payload. |
| <a id="landing-watcher"></a>One sentinel/PR lifecycle (U4) | Fresh / online, disposable repository | Follow [sentinel and PR](#sentinel-and-pr) with two eligible test owners and one wrong-scope control. | The same real PR yields the checks-completed fact and queue/landing settlement fact, both eligible owners wake from the process fact, and disabling stops the owned sentinel. Fallback expiry is never fact evidence. |
| Orchestrator defaults | Fresh / records | After learning `agentic-engineering`, inspect its composed `identity/archetypes/orchestrator.toml` and the matching `identity status orchestrator` readback. | Defaults are harness `codex`, model `gpt-6-luna`, effort `max`. This checks shipped defaults without a provider placement; actual availability and configured-model forwarding remain distinct evidence. |

## Notice batching (Fresh / online)

Run this journey by hand on a disposable area with O (an agent sender), H (the
recipient), C (a second agent sender), R (a reviewer), and a human user. Use
the normal `dispatch`, `wake`, `attest`, and chat-post routes. Do not write a
helper script or edit queue rows.

1. Create work item W. As O, open a harmless producer assignment P for H with
   `assign --session <H> --work-item <W> --subject "producer fixture"`. While H
   is idle, H opens review assignment A for P to R with
   `assign --reviews <P> --work-item <W> --session <R> --subject "review fixture"`.
2. As O, dispatch a separate harmless bounded task X to H with
   `dispatch --to <H> --work-item <W> --subject "running fixture" --brief "Continue this harmless fixture task." --key <unique>`.
   Wait until X's turn is actually running; record its sequence and assignment.
   If it ends before the queued observations below, record the missed
   prerequisite and retry the hand-run journey.
3. While X is running, O dispatches a second bounded task B to H with
   `dispatch --to <H> --work-item <W> --subject "queued fixture" --brief "Handle this harmless queued fixture task." --key <unique>`.
   Confirm B remains an individual pending source row and has no delivery
   turn. As O, run
   `wake --session <H> --assignment <B> --replace-queued --class fyi --prompt "DRAFT <nonce>"`,
   then run `wake --session <H> --assignment <B> --replace-queued --class blocker --prompt "CORRECTION <nonce>"`.
4. While X is still running, have C send two ordinary `input-needed` wakes to H;
   O send a `status-query` wake; and C schedule a timed `input-needed` wake with
   `wake --session <H> --after 5s --class input-needed --prompt "TIMED <nonce>"`.
   Wait for its due time while X remains running. The human user posts an
   ordinary chat message with one harmless attachment, and R files
   `attest <A> --kind verdict --verdict reviewed-clean`. Record every source
   wake ID and read back its actual origin and class. The ruling must notify
   A's opener H through the ordinary batchable route. Do not send the human
   message as a `wake` or use the separate `algedonic` human-channel route.
   Before X ends, C cancels one pending source with `cancel-wake <wakeId>`.
5. Use read-only SQLite inspection with `sqlite3 -readonly "$AREA_BASE/state.db"`
   to compare each source in `wakes` (`wakeId`, `sessionKey`, `origin`,
   `creatorSessionKey`, `assignmentId`, `class`, `state`, `prompt`) with
   `notice_batch_members` (`sourceWakeId`, `batchId`, `publicationSeq`, `state`)
   and `notice_batches` (`batchId`, `state`, `releaseCause`, `deliveryWakeId`);
   inspect `notice_batch_source_attachments`, read the batch `envelope`, and
   inspect `turns` (`seq`, `sessionKey`, `status`, `wakeId`). Do not mutate the
   database.

   **Assert while X is running:** B's dispatch prompt and O's first replacement
   remain auditable as superseded sources; O's correction is a distinct pending
   row with class `blocker`; C's canceled source remains auditable and is
   excluded from delivery; every other prompt remains an individual row with
   its own source ID, origin and class. No second queued turn exists beside X;
   every next-turn prompt is in this one editable source queue. The correction
   moves only O's selected source ahead of `input-needed`, `status-query` and
   `fyi` by class priority. This demonstrates that a source can be replaced,
   canceled or reordered before readiness without changing other source rows.
   No source has batch membership or its own delivery turn yet, and X's running
   turn is unchanged.
6. After X ends, wait for the ready lane to deliver. **Assert:** exactly one
   next turn is created for the carrier; its envelope has a visible marker for
   each included source, with its ID, origin in `sender=`, cause in `cause=`,
   and class; and surviving members appear in class priority order with
   publication order within a class (`blocker`, `input-needed`, `status-query`,
   `fyi`, then other classes). The human post, its attachment, and R's ruling
   are in the same carrier turn; none starts a separate turn, and the canceled
   source is absent. The attachment payload is carried with its source and is
   present on the delivered carrier message.
7. After the carrier turn finishes and H is idle, O sends one ordinary first
   wake. **Assert:** it starts one delivery immediately, without waiting for a
   timed batching window. This journey is part of the core-flow smoke before
   the initial Gibson install.

## Queue correction

Use admitted test sessions O (opener), H (holder) and C (different sender), and
an area item W. O dispatches a harmless bounded task to H on assignment A.
Fixture briefs leave assignments open for the opener's cleanup after checks.
Record the actual running turn sequence and assignment attribution. Do not
freeze a lane or edit turn rows to hold this window. If the task ends before
the observations below, record the missed running/queued prerequisite and
retry this bounded journey; no race outcome is presumed.

While A's turn is running:

1. O uses `dispatch --to <H> --work-item <W> --subject <fixture>
   --brief "INITIAL <nonce>" --key <unique>` to open assignment B. Confirm
   its initial prompt is one pending editable source row with no delivery
   turn. C sends the ordinary control
   `wake --session <H> --prompt "CONTROL <nonce>: reply with this nonce"`,
   without `--assignment`. Require exactly these two individual pending source
   rows, no new queued turns, and record their source IDs, publication order,
   classes and origins.
2. O sends `wake --session <H> --assignment <B> --replace-queued
   --prompt "CORRECTION <nonce>: reply with this nonce"`. Read source and
   cancellation records: B's INITIAL source is canceled with reason
   `sender_requested_replacement`; C's ordinary control remains pending. An
   ordinary wake is not replacement consent. Retain the original prompt and
   source IDs. A's running turn remains running.
3. O sends a newer correction using the same B-bound `--replace-queued`
   command and a new nonce. Require the prior replacement-consenting source to
   be canceled and C's control to remain pending. Let A's bounded task finish.
   **Assert:** C's control and the newest correction form one carrier turn in
   priority order, with publication order preserved within their class. Both
   source rows remain individually auditable; neither got its own turn.
4. Still in H, O dispatches one bounded harmless task on a new assignment D
   under W. Observe its immediate first turn running and attributed to D.
   A replacement wake does not stamp a turn with an assignment and cannot
   supply this attributed running-turn prerequisite. With no other source
   ahead of it, O sends
   `wake --session <H> --assignment <D> --replace-queued
   --prompt "OLDER <nonce>"`, then another such `--replace-queued` wake with
   the final correction and a fresh nonce. Require OLDER canceled and the
   final correction pending as a source row. Both correction wakes explicitly consent to
   replacement; do not use an ordinary wake for OLDER.
   As a non-opener, try `assignment-stop-turn <D> --reason <fixture reason>`;
   require `not_authorized` and no change. As O, run that stop once. Its result
   names D, H, the exact current `turnSeq` and `acpCancel`. That turn becomes
   `canceled`; its lifecycle event records cause `assignment-opener-stop`.
   The `assignment_turn_stopped` lifecycle event records O's actor and exact
   reason. The final pending correction source is unchanged by the stop.
5. Require that final correction to run next and produce its nonce reply in H.
   Tie its wake ID to D through `queued_message_replacement_requests` and D
   to W through the assignment record; do not claim automatic assignment turn
   attribution from a replacement request. All suppressed INITIAL, OLDER and
   replaced correction sources remain readable but never execute. C's
   preserved control appears once in its carrier. Record the actual sequences
   and terminal results, not only accepted wakes. The second bounded window
   isolates stop/resume ordering without discarding C's message.
   Dispose all three fixture assignments with recorded reasons after the checks.

The decisions stop row cites this result. `test/queued_message_suppression_test.exs`
owns clock-regression/retry ordering and the wider protected-traffic matrix;
`test/lane_test.exs` owns deterministic stop races. A normal-stop test
is not evidence for automatic incident recovery.

## Owner/topology journey

<a id="owner-topology-journey"></a>

Use test owner U, its Main M, direct owner D, successor N, coordinator K and
worker H, all under U. At least D is user-spawned: its `spawnedBy` and
`currentParent` are null while `topologyParent` names M; M has no topology
parent. This is the Main-proxy specimen, not an inferred spawn edge. D spawns
K and H so their original ancestry names D. Record `list` before changes.
Use public PO association and role setup (`session-po-set --session <key>
--po-role <test PO role> --key <unique>`) where required for the existing
admission contract; no raw fixture writes.

U creates W and sets `work-item-update <W> --delivery-owner <D>`. D opens H's
single test assignment on W. As D through its session workdir, run
`session-reparent --session <H> --parent <K> --assignment <A> --key <unique>`.
Require the returned origin parent/opener still name D and the current parent
and `currentCoordinationParentRef` name K. `list` agrees, while H's
`spawnedBy`, owner, assignment holder and work-item ID remain unchanged.
Read `session_reparent_events` by returned event ID: `principalKind` is
`session`, `principalRef` names D and `cause` is `delivery_owner_reparent`.
Repeat the exact key/request as D and require the same event, not a second
transfer. An unrelated session cannot perform this transfer; retain its
no-write refusal. Scope/cycle permutations stay in `test/session_reparent_test.exs`.

Before H's terminal event, U changes W's direct owner to N and reads it back.
D is not also a delegated opener with a separate still-open lane assignment
on W; the supported delegated-opener priority is not stale-owner duplication.
Have H finish its actual bounded test assignment with the required genuine
verification/review evidence, or use a completed coordination fixture whose
admission requires none of that code evidence. Read the terminal source attest,
W's trace and recipient transcripts/notice wakes. Require the notice for that
source to name/reach N once and no corresponding notice to stale owner D.
If recipient execution is unavailable, record routed wake and missing delivery
separately. Re-read to confirm one source notice. Owner replacement does not
rewrite A's original opener, H's holder or spawn provenance.

Finally clear W's owner link and read null. On a separate inactive fixture,
retain unknown-owner and retired-owner no-write refusals (`unknown_delivery_owner`
and `delivery_owner_unavailable`). Source cases remain in
`test/delivery_responsibilities_test.exs` and `test/topology_parent_test.exs`.

## Sentinel and PR

Use one authorized disposable repository and one PR with real required checks
and a merge queue available for its disposable target branch. Repository
mutation/landing authority and test GitHub credentials are prerequisites;
this runbook grants neither. Record the repository, branch, PR, head and
checks. Missing queue support leaves settlement/landing evidence `skipped`
even if checks-completed succeeds; do not use a production PR to fill it.

Before learning the bundle, inspect `sentinel list` (empty `sentinels` and
`setup`); enabling the unlearned landing watcher refuses `unknown_sentinel`
("no learned bundle declares sentinel ...; learned sentinels: none"), while
`kungfu setup` of an unlearned bundle is the call that refuses
`kungfu_not_learned`. Learn
`agentic-engineering`, inspect `kungfu setup agentic-engineering` and
`sentinel list`, and require disabled state plus missing `GH_CONFIG_DIR` and
`LANDING_REPOS`. Enable while those settings are absent: require
`sentinel_settings_missing` and no owned watcher process.

Set the real test `GH_CONFIG_DIR` and a single `LANDING_REPOS` entry
`<owner>/<repo>@<disposable branch>=<test owner role>` with
`host-env-set --sentinel agentic-engineering/landing-watch NAME=VALUE`.
`host-env-list --sentinel agentic-engineering/landing-watch` shows setting
names with values withheld. Ensure the sentinel's CLI resolves to the same
verified package and only this fresh test gateway; record that binding before
enabling it. Run `sentinel enable agentic-engineering/landing-watch` as the
test admin and record its owned process identity.

Before the PR's checks finish, have two eligible sessions owned by distinct
test users each register `wake --session <self> --when-fact pr.checks-completed
--when-scope <owner>/<repo>#<n> --fallback-after 2h --prompt <unique>`.
Register a third subscription on a different PR scope. After actual checks
finish, require one process-filed fact with lowercased scope and key
`pr-checks:<scope>:<head>:<outcome>`. Both owners' subscriptions fire by
`condition` for that same fact; the wrong-scope control stays pending.
Inspect actual wake and turn records. Fallback wakes prove no condition.

Before queueing the same PR, register settlement subscriptions on
`landing.settled` with its same scope. Use the authorized ordinary queue/merge
route. Observe the real queue settlement/landing and the watcher's fact, with
its actual source key such as `landing-fact:<scope>:merged:<merge SHA>`;
require the merge SHA matches the repository's public readback and both
eligible subscribers fire once. A removed queue entry or closed PR has its
own truthful settlement outcome and is not a merged result. Record whichever
actually occurred; do not force fail/rerun/restart permutations.

Run `sentinel disable agentic-engineering/landing-watch`. Require disabled
state and the previously recorded owned process stopped, without affecting
another process. Unset only the two test-owned settings and cancel the pending
wrong-scope subscriptions. Source watcher tests own red/green/rerun/restart
cases; `test/wakes_test.exs` retains owned-fact isolation. This is also the
provider sentinel row's evidence; do not start a second watcher lifecycle.
