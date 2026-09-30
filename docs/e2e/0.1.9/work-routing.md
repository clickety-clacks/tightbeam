# 0.1.9 work and routing checks

Offline rows run on a new copy of the migrated result
([reuse the result](migration.md#reuse-the-result)) inside the verified
[containment](README.md#containment) boundary, from the
[CLI shell](README.md#cli-shell). A copied session acts through
[`as_session`](README.md#copied-session-tokens), which stops unless the run's
execution approval names copied-token use; without it, record each row that
acts as a copied session `INCOMPLETE: copied-token use not approved`. An admin acts through
`tb ... --as-user "$test_admin"`:

```sh
test_admin="$(sqlite3 -readonly "${AREA_BASE:?}/state.db" "SELECT userId FROM users WHERE isAdmin = 1 ORDER BY userId LIMIT 1")"
```

Create this area's own test work items and assignments, and pick copied
active sessions with the same owner as their actors. Offline, a turn that a row
queues fails for want of a login or network; the row reads the durable wake and
turn records, not the turn's reply. Rows that read a table do so read-only:
`sqlite3 -readonly "$AREA_BASE/state.db"`.

Online rows run on a fresh empty base under the [online tier](README.md#tiers)
and are labelled "fresh-base feature evidence, not proof on migrated state".
The feature smoke's `work` area ([feature smoke](README.md#feature-smoke),
online only) covers facts and configuration reads, work-item and assignment
reads, dispatch linking, body replace and clear, and delivery owner
set, read and clear.

The D1 REST reads are in [gateway-surface.md](gateway-surface.md#rest-d1).

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| Work-item fields | Offline | As the admin, create a test item with `work-item-create --title ... --priority 3`. Run `work-item-update <id> --title ... --priority 5`, then `--spec-ref <name> --spec-sha256 <64 hex>`, then `--clear-spec-ref`, then `--priority 9`. Read `work-item-get <id>` after each. | Each read shows only the requested change; omitted fields are unchanged; the spec name and hash appear and clear together. Priority 9 is refused by the CLI before any request ("priority must be an integer from 0 through 8"). |
| <a id="editable-work-item-body"></a>Editable work-item body | Offline | On a test item, run `work-item-update <id> --body "first"`, again with `--body "second"`, again with `--body "second"`, then `--clear-body`. Also run `work-item-update <id> --body x --title y`. Read `work-item-get <id>` after each. | `workItem.body` shows the latest text, and `bodyUpdate` carries `state`, `byteLength`, `sha256`, `changed` and the updater. The repeated body shows `changed: false`. After the clear, `body` is null and `bodyUpdate.state` is `absent`. Title, priority and metadata never change. The combined form is a CLI usage error with exit 1. |
| Default priority | Offline | Run `config get default-priority`, then `config set default-priority 2` as the admin, create a test item with no `--priority`, read it, then set the setting back to its first value. Try `config set default-priority 9`. | The setting reads back as 2 and the new item has priority 2. The restored value matches the first read. 9 is refused. |
| <a id="delivery-owner"></a>Direct delivery owner | Offline | On a test item, run `work-item-update <id> --delivery-owner <active copied session>`, read `work-item-get <id>`, then `--clear-delivery-owner` and read again. Also try an unknown session key, a copied retired session, and `work-item-delivery-scope-set`. | The item shows `deliveryOwnerSessionKey` equal to the session, then null. The unknown key is refused `unknown_delivery_owner`, the retired session `delivery_owner_unavailable`, and the retired verb `delivery_operation_retired`. |
| Successor assignment | Offline | Dispatch assignment A on a test item and close it. Dispatch assignment B with `--succeeds <A>`. Then try `--succeeds` naming an open assignment. Read `work-item-get <wi>`. | B's `subject` ends with `Ruled-but-unconsumed decisions carried from <A>: ...` and an `assignment-successor-created` fact is scoped to B. The open predecessor is refused `predecessor_not_terminal`. |
| <a id="canonical-topology"></a>Canonical session topology | Offline | Pick a copied custom child session holding exactly one open assignment and a second copied session with the same owner. As the owning user, run `session-reparent --session <child> --parent <new parent> --assignment <id> --key <unique>`. Read `list`. Repeat the same call, and try a reparent that makes a cycle. | The response shows `originParent`, `previousCurrentParent` and `currentParent`, and the assignment shows `currentCoordinationParentRef`. `list` shows the new `currentParent` and `topologyParent`, with `spawnedBy` unchanged. The repeat replays; the cycle is refused `cycle_detected`. |
| <a id="wake-delivery-options"></a>Dependency wait | Offline | On a test item, open assignment H (the waiter), R (the resolver) and V (the verifier). As H's holder, run `wake --session <H holder> --assignment <H> --fallback-after 1h --prompt "resolver closed" --predicate '{"conditions":[{"fact":"assignment.state","op":"eq","value":"closed"}],"bindings":{"assignmentId":"<R>"},"resolverRef":{"kind":"assignment","id":"<R>"},"necessity":"R owns the required output.","verificationRef":{"kind":"assignment","id":"<V>"}}'`. Read the `turns` table for its `wakeId`. Revoke R with a reason, wait one wake tick, and read again. Also run the same wake as a user, and with both `--predicate` and `--after-turn`. | Before R closes, no turn carries the wake's ID. After R is revoked, one turn does, with the prompt. The user caller is refused `invalid_wait`; the combined flags fail at parse. |
| Ready-now continuation | Online | From inside a harmless running turn of H's holder, have it run `wake --session <itself> --assignment <H> --after-turn --prompt "continue"`. Read the `turns` table after the turn ends. Run the same command from a session with no running turn. | Exactly one later turn carries the continuation's wake ID, and it starts only after the capturing turn ended. With no running turn: `no_running_turn`. |
| Delivery class | Offline | As a copied session, send `wake --session <other> --class blocker --prompt ...` and `wake --session <other> --class not-a-class --prompt ...`. Read `class` for both wake IDs from the `wakes` table. | Each wake stores the class its sender gave. The unknown class is accepted, not refused. |
| <a id="replace-unread-messages"></a>Replace unread messages | Online | Keep H's holder busy with a long harmless turn. From the opener session, send two messages with `wake --session <holder> --assignment <H> --replace-queued --prompt ...`, then a third the same way. As a control, send one ordinary wake to the same holder from a different session. Read the holder's turns. | The two earlier queued turns end `canceled` with error `queued-message-suppressed: sender_requested_replacement`, and a `queued_message_suppressed` event is written. The third stays queued. The running turn and the control are unchanged. |
| <a id="wake-cancellation-history"></a>Wake cancellation history | Offline | As H's holder, register another [dependency wait](#wake-delivery-options) on H naming a resolver that stays open, and a third as a control. Run `cancel-wake <wakeId>` from the holder, then again. Try cancelling the control from a different session. Read `work-item-trace <wi>` and the `turns` table. | The first cancel returns `canceled: true`, the second `canceled: false`. The trace shows `wake_canceled` for that wake with reason `requester_withdrew`. No turn carries its ID. The other session's cancel leaves the control pending. |
| Consequence condition fact | Offline | On an assignment with at least one attest, as its holder, publish `condition --kind obligation-consequence-changed --scope <asg> --key <unique> --payload '<object>'` with exactly `assignmentId` (the scope), `consequenceKey`, `revision`, `attentionRequestId`, `evidenceAttestId` and boolean `explicitAttention`. Try a payload on another kind, and a payload missing a key. | The fact is kept with its payload. A payload on another kind is refused `invalid` ("payload requires consequence kind"); the incomplete payload is refused `invalid`. |
| <a id="landing-watcher"></a>Landing watcher | Online | In a disposable repository with one open PR, set the sentinel's `GH_CONFIG_DIR` and `LANDING_REPOS` and enable `agentic-engineering/landing-watch` (see [sentinel lifecycle](provider-runtime.md#sentinel-lifecycle)). Subscribe a test owner with `wake --session <owner> --when-fact pr.checks-completed --when-scope <owner>/<repo>#<n> --fallback-after 2h --prompt ...`. Let the PR's real checks finish. | One fact with the lowercased scope and key `pr-checks:<scope>:<head>:<outcome>` is filed for that head, and the subscriber wakes with `firedBy` `condition`. A subscription on another PR's scope does not fire. The fallback is not check evidence. |
| Orchestrator defaults | Online | After `learn agentic-engineering`, spawn an `orchestrator` session on a test item without harness, model or effort flags. | The session has harness `codex`, model `gpt-6-luna` and effort `max`. If that host does not offer that model, record `INCOMPLETE`; do not substitute another host. |

0.1.9 has no command that turns on notice batching, so these runbooks do not
check it.
