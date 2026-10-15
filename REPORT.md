# Database repair report

PR: https://github.com/clickety-clacks/tightbeam/pull/284

Branch: `fix/rc-db-readers-deadlines-commit-once`. Target: `0.1.9`.
Tested production code: `762a5b78`. Final test head: `6943dcd5`; that later commit adds only the two-VM durability regression. The PR remains a draft pending independent review of these changes.

## Result

File-backed databases use four reader processes. Each owns one read-only SQLite connection and finishes and releases one statement before admitting another. Reader selection uses `:persistent_term` keyed by the owner pid. Neither reader selection nor owner detection copies the owner's process dictionary.

Reader calls use the caller's remaining budget, including queue time. On expiry, `Exqlite.Sqlite3.interrupt/1` stops the active statement. Request tokens and an acknowledgement prevent cancellation from interrupting a different caller. A deadline watchdog also covers expiry while a request is starting. All statements finalize before the next request. The regression fixture verifies a committed write becomes visible behind a busy reader and WAL truncation succeeds afterward.

Scheduler ticks, supervision sweeps, notice drains, bubble sweeps, lane reconciliation, and retention defer `DB.Overloaded` to their next tick. Their regression tests preserve the existing timers and state.

Both `transaction_then` callback arities contain recognition exceptions, throws, exits, and recognition error returns. The caller receives the committed primary value. Callers whose recognition changes the result shape explicitly supply the equivalent fallback with empty recognition-derived deliveries. A recognition deadline failure follows the same path. Inline recognition uses the original operation's remaining budget.

One `pending_recognition` table holds retry intent, callback data, captured row transitions, attempt count, next attempt time, and the bounded-failure flag. The pending row is written **inside the primary transaction**, before its commit. Recognition runs in a separate transaction. A failed recognition rolls back its own changes and handoffs while retaining the primary commit and pending row.

One retry process per database owner consumes the table. It avoids callbacks still running inline, monitors their callers, retries with exponential backoff, and flags a row after five failed retries. Retries also complete callback-derived deliveries where the caller normally does so. File-backed retry storage is installed after the existing schema checks; retries activate only after schema bootstrap finishes. Recovery tests stop and reopen the database owner and recreate the retry process without an in-memory callback registry.

## Implementation

- `lib/tightbeam/db_reader.ex`: serialized connections, deadline interruption, cancellation acknowledgement, and statement cleanup.
- `lib/tightbeam/db.ex` and `db_observation.ex`: persistent reader lookup, remaining-budget calls, primary recognition intent, and committed-result replies.
- `lib/tightbeam/recognition.ex` and `schema.ex`: the single pending table, single retry process, backoff, bounded flagging, and post-bootstrap activation.
- `condition_facts.ex`, `subagent_markers.ex`, `artifacts.ex`, `escalation.ex`, `gateway.ex`, and `productions/bubble.ex`: explicit committed-result fallback shapes and delivery completion on retry.
- `retention.ex`: explicit debug-level overload deferral. The other named background loops already had overload containment and were rechecked.

## Verification

Final focused run at `6943dcd5`: **61 tests, 0 failures**. Includes both callback arities recovering in a second virtual machine.
Final expanded run at `762a5b78`: **340 tests, 0 failures**.
Formatting: `mix format --check-formatted` passed in the expanded runner and on the local tree.
Whitespace: `git diff --check` passed.

The expanded run includes all previously selected CLI integration tests. No source assertion was removed or weakened to work around the earlier Git-object-store runner fault. The transaction callback regression now asserts the requested committed-success response while retaining the primary-state and recognition-rollback assertions.

Focused files:

```text
test/db_readers_deadlines_test.exs
test/db_call_timeout_test.exs
test/db_observation_test.exs
test/db_transaction_then_test.exs
test/db_handoff_test.exs
test/db_background_overload_test.exs
test/recognition_retry_test.exs
```

The expanded run adds:

```text
test/dispatch_test.exs
test/bubble_test.exs
test/transcript_test.exs
test/cli_integration_test.exs
test/condition_facts_test.exs
test/subagent_markers_test.exs
test/artifacts_test.exs
test/escalation_test.exs
test/escalation_delivery_test.exs
test/retention_test.exs
test/schema_shape_test.exs
```

The authoritative `scripts/verify_mix.sh` runner uses the pinned Elixir 1.19.5 and Erlang/OTP 28.5 release line. The complete CLI integration file uses the executable built from this branch's Rust source. No Rust source changed in this continuation.

Intermediate runs in this continuation:

- `2209e4d8`: 59 tests, 1 failure; format passed. A new throw test exposed writer termination rather than recognition rollback. That defect was fixed.
- `82efd5be`: 145 tests, 0 failures; format passed. Includes the complete CLI integration file.
- `6d2e2cb1`: 146 tests, 0 failures; format passed. Adds active-publication isolation and file-backed owner recovery coverage.
- `6d8a16df`: 340 tests, 1 failure; format passed. The new deadline test asserted messages its callbacks did not send. The missing test notifications were added without changing the assertions or production behavior.

## Limits

Persisted callbacks use Erlang external terms and carry their defining module's build checksum. Recovery is tied to that module build. A changed build or an unusable captured runtime value fails visibly and reaches the bounded-failure flag; this is not a callback migration mechanism. External arity-one publication is at least once across a crash between publication and intent deletion. Callbacks with external effects must tolerate replay.

The passing focused regression also exercises two separate virtual machines against the same file-backed database and build, recovering both callback arities with captured data. This does not establish cross-version callback migration or replay of arbitrary runtime resources.

The owner admission check remains a mailbox-depth snapshot, so simultaneous arrivals can overshoot its fixed limit. Private in-memory databases keep their original single connection.

No full suite, independent review of this continuation, or actual-device validation is claimed. No target branch was merged and no release or installation was performed. Device testing follows merge.

Every continuation commit ends with the requested co-author footer. Existing history was not rewritten.
