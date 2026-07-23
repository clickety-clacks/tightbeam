# Artifacts redo handoffs

- **Clause 4 — exact archived file `home`:** `Tightbeam.Artifacts` now maps and
  verifies an artifact's real path inside a reachable local workspace, but
  `lib/tightbeam/gateway.ex` still passes `nil` for remote workspaces. The Gateway
  / remote-workspace owner must execute archival where the workspace is reachable
  and return the resulting archive path; its integration test must assert the exact
  archived file bytes and `home`.

- **Clause 7 — no-policy/ticket-ID floor:** the spec says both that every closing
  workspace is archived and tied to a work item without recording discipline, and
  that a workspace with no `in-workspace` artifact rows is removed. A spec ruling
  must choose which behavior owns an unrecorded workspace and, if it is archived,
  define the authoritative work-item edge that cleanup must use.

- **Clause 8 — conversation/intent provenance graph:** this module now requires and
  migrates the four provenance foreign keys, but the production dispatch seam does
  not supply an authoritative message ID and the CLI still permits no work item.
  `lib/tightbeam/wire/router.ex` (or the transcript/adapter event seam) must attach
  the exact firing `messages.id`; `cli/src/args.rs` must require `--work-item`, with
  router and CLI integration tests using real message/work-item rows.

- **Clause 11 — exact firing turn:** `recordedMessageId` cannot be made
  authoritative inside `Artifacts.record/2`; a caller-selected ID is not proof of
  the firing turn. The transcript/dispatch owner must bind the current committed
  artifact-record turn's `messages.id` onto the call and prove that exact ID reaches
  the persisted artifact row.

- **Clause 12 — exact work-item edge:** the owned table now requires an exact
  `work_items.id` FK and upgrades populated compatible legacy tables, but the shipped
  CLI still makes `--work-item` optional. The CLI parser/dispatcher must make it
  required. The spec owner must also rule how pre-migration rows with a null
  `workItemId` are repaired without inventing intent or deleting permanent rows.

- **Clause 14 — all load-bearing edges are exact FKs:** the owned migration installs
  all four FKs on compatible existing tables. A legacy row written by the old
  implementation always has a null `recordedMessageId` and may have a null
  `workItemId`, so it cannot be copied into the ratified non-null shape without
  fabricated provenance. The spec owner must define a truthful legacy-row repair,
  and the test owner must add the populated legacy upgrade case to
  `test/artifacts_test.exs`.

- **Clause 20 — released transition:** `Artifacts.release/2` performs the real
  transition, but no shipped verb reaches it. Gateway, router, and CLI owners must
  add `artifact-release` and an end-to-end test that observes the retained row in
  `released` state with no `home`.

- **Clause 21 — archived home is actual custody:** reachable local workspaces now
  use canonical paths so a symlink cannot leave artifact bytes outside custody.
  Remote workspaces and hard copy failures still lack an archive executor. Gateway
  / remote-workspace ownership must supply archival where the bytes live and test
  the returned exact home.

- **Clause 22 — released means no asserted home:** the owned operation and migrated
  schema enforce this, but the release operation has no Gateway/router/CLI surface.
  Those owners must expose it. The spec owner must also decide how a legacy
  `released` row with a non-null `home` is migrated without silently rewriting
  historical custody assertions.

- **Clause 31 — archiving always succeeds:** the literal clause cannot be guaranteed
  for a missing remote workspace or an exhausted/unwritable filesystem while also
  requiring archived bytes to survive and teardown never to block. The spec must
  define valid archival preconditions and a durable failure/retry owner, or the
  remote-workspace/Gateway lane must provide a guaranteed archive service. Until
  then, this module deliberately raises on missing bytes or terminal rename-plus-copy
  failure rather than falsely labeling an uncustodied row `archived`.

- **Clause 33 — archived rows and bytes remain findable:** the local owned path is
  real, but the clause also depends on authoritative firing-turn/work-item callers
  (clauses 8/11/12) and remote archive execution (clauses 4/21/31). Those exact
  cross-lane changes must land before this aggregate clause can close.

- **Clause 35 — archived means actual Tightbeam custody:** local canonical custody is
  enforced in this module. `lib/tightbeam/gateway.ex` must stop passing `nil` for
  remote workspaces and must return a real archive result before any row is marked
  archived.

- **Clause 36 — out of custody preserves provenance and clears location:** the owned
  release update retains the row and clears `home`; Gateway/router/CLI owners must
  expose that operation and prove the observable end state through the shipped
  interface.

- **Clause 40 — durable topology reaches the exact conversation:** this depends on
  the authoritative firing-turn binding and required CLI work-item input described
  for clauses 8, 11, and 12. The router/transcript and CLI owners must implement and
  integration-test those edges; `Artifacts` cannot infer them truthfully.

- **Clause 45 — time-window filters:** the owned query implements inclusive
  `created_after` / `created_before` bounds. The spec owner must confirm the bound
  names and created-time interpretation, then CLI/router owners must expose the
  fields and test both inclusive boundaries through the shipped interface.

- **Clause 57 — authoritative work-item spec resolver:** generic artifact filtering
  cannot decide which artifact satisfies `work_items.specRefName`.
  `lib/tightbeam/work_items.ex`, Gateway, and CLI owners must replace or bind that
  string to an exact spec artifact identity and resolve its current `home`.

- **Clause 58 — artifact workspace archival is universal and nonblocking:** the
  reachable local path is real, but remote sessions still have no reachable
  workspace in the Gateway reap call and terminal filesystem failure has no durable
  retry owner. The Gateway/remote archive lane plus the clause-31 spec ruling must
  provide those missing states and end-to-end coverage.
