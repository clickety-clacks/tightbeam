defmodule Tightbeam.EffortHolderActivityCancellationMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, Schema, Wakes}

  setup do
    db = :"effort_activity_migration_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    assert :ok = Schema.ensure_all(db)

    assert :ok =
             DB.execute(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn',1,1)")

    session_key = "effort-activity-migration-holder"

    Org.create(db, %{
      session_key: session_key,
      display_name: "Effort activity migration holder",
      owner_user_id: "flynn",
      origin: "agent:#{session_key}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    wake =
      Wakes.schedule(db, %{
        session_key: session_key,
        origin: "agent:#{session_key}",
        creator_session_key: session_key,
        prompt: "withdraw this wake",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert {:ok, {:accepted_in_txn, _event_id, %{canceled: true}}} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, %{
                 wake_id: wake.wake_id,
                 expected_origin: "agent:#{session_key}",
                 requester: %{kind: "session", id: session_key},
                 reason_kind: "requester_withdrew",
                 causal_source: %{
                   kind: "verb_call",
                   accepted_event: %{
                     origin: "agent:#{session_key}",
                     session_key: session_key,
                     principal: {:session, session_key}
                   }
                 },
                 outcome: %{kind: "no_replacement"}
               })
             end)

    before_rows = rows(db, "SELECT * FROM wake_cancellations ORDER BY wakeId")
    assert length(before_rows) == 1

    assert :ok =
             Tightbeam.SchemaShapeRuntimeFixture.downgrade_effort_holder_activity_cancellation!(
               db
             )

    %{db: db, before_rows: before_rows}
  end

  test "upgrades the exact current cancellation table and preserves its rows", ctx do
    assert :ok = Schema.upgrade_effort_holder_activity_cancellation_v1(ctx.db)
    assert rows(ctx.db, "SELECT * FROM wake_cancellations ORDER BY wakeId") == ctx.before_rows
    assert rows(ctx.db, "PRAGMA foreign_key_check") == []

    assert [[table_sql]] =
             rows(
               ctx.db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
             )

    assert String.contains?(table_sql, "requesterId = 'tightbeam:rail-remedy' AND")

    assert rows(ctx.db, "SELECT shape FROM effort_holder_activity_cancellation_epoch WHERE id=0") ==
             [["effort-holder-activity-cancellation-v1-019"]]

    assert :ok = Schema.upgrade_effort_holder_activity_cancellation_v1(ctx.db)
    assert rows(ctx.db, "SELECT * FROM wake_cancellations ORDER BY wakeId") == ctx.before_rows
    assert_activity_route_is_admitted(ctx.db)
  end

  # Exercise the migrated SQLite CHECK constraints against a real canceled wake.
  # sqlite_master normalizes the source DDL's whitespace, so route behavior is
  # the stable contract here rather than a layout-sensitive match on its text.
  defp assert_activity_route_is_admitted(db) do
    [[wake_id]] = rows(db, "SELECT wakeId FROM wake_cancellations ORDER BY wakeId LIMIT 1")

    assert {:ok, []} =
             DB.query(
               db,
               """
               UPDATE wake_cancellations
               SET requesterKind='process', requesterId='tightbeam:effort-checkin',
                   reasonKind='superseded', causalSourceKind='progress_attest',
                   causalSourceId='fixture-attest', outcomeKind='no_replacement',
                   replacementWakeId=NULL, dispositionKind=NULL, dispositionId=NULL,
                   primaryWorkKind='assignment', primaryWorkId='fixture-open-assignment',
                   workImpactKind='linked_work_open', livenessTriggerKind=NULL,
                   livenessTriggerId=NULL, actionNeeded=0
               WHERE wakeId=?1
               """,
               [wake_id]
             )

    assert [
             [
               "process",
               "tightbeam:effort-checkin",
               "superseded",
               "progress_attest",
               "no_replacement",
               "assignment",
               "fixture-open-assignment",
               "linked_work_open",
               nil,
               nil,
               0
             ]
           ] =
             rows(
               db,
               """
               SELECT requesterKind,requesterId,reasonKind,causalSourceKind,outcomeKind,
                      primaryWorkKind,primaryWorkId,workImpactKind,livenessTriggerKind,
                      livenessTriggerId,actionNeeded
               FROM wake_cancellations WHERE wakeId=?1
               """,
               [wake_id]
             )

    assert {:error, _constraint_error} =
             DB.query(
               db,
               "UPDATE wake_cancellations SET causalSourceKind='wake' WHERE wakeId=?1",
               [wake_id]
             )
  end

  defp rows(db, sql, params \\ []) do
    assert {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
