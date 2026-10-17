defmodule Tightbeam.EffortHolderActivityCancellationMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, Schema, Wakes}

  @activity_route ~r/\n\s+OR\n\s+\(workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND livenessTriggerId IS NULL AND actionNeeded = 0 AND\s+requesterKind = 'process' AND requesterId = 'tightbeam:effort-checkin' AND\s+reasonKind = 'superseded' AND causalSourceKind = 'progress_attest'\)/
  @activity_requester_route ~r/\(requesterId = 'tightbeam:effort-checkin' AND reasonKind = 'superseded' AND\s+causalSourceKind = 'progress_attest' AND outcomeKind = 'no_replacement'\)\n\s+OR\n\s+/
  @columns "wakeId,wakeState,canceledAt,requesterKind,requesterId,reasonKind," <>
             "causalSourceKind,causalSourceId,outcomeKind,replacementWakeId," <>
             "dispositionKind,dispositionId,primaryWorkKind,primaryWorkId,workImpactKind," <>
             "livenessTriggerKind,livenessTriggerId,actionNeeded"

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

    downgrade_activity_cancellation!(db)
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

    assert Regex.match?(@activity_route, table_sql)
    assert Regex.match?(@activity_requester_route, table_sql)

    assert rows(ctx.db, "SELECT shape FROM effort_holder_activity_cancellation_epoch WHERE id=0") ==
             [["effort-holder-activity-cancellation-v1-019"]]

    assert :ok = Schema.upgrade_effort_holder_activity_cancellation_v1(ctx.db)
    assert rows(ctx.db, "SELECT * FROM wake_cancellations ORDER BY wakeId") == ctx.before_rows
  end

  defp downgrade_activity_cancellation!(db) do
    assert [[current_sql]] =
             rows(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
             )

    predecessor_sql =
      current_sql
      |> then(&Regex.replace(@activity_route, &1, "", global: false))
      |> then(&Regex.replace(@activity_requester_route, &1, "", global: false))

    refute predecessor_sql == current_sql

    assert {:ok, trigger_rows} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='trigger' AND name IN ('wake_cancellations_pending_insert','wakes_typed_cancellation_required') ORDER BY name"
             )

    assert length(trigger_rows) == 2
    trigger_sql = Enum.map_join(trigger_rows, ";\n", &hd/1)
    assert :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")
    assert :ok = DB.execute(db, "PRAGMA legacy_alter_table=ON")

    assert :ok =
             DB.execute(db, """
             DROP TRIGGER wake_cancellations_pending_insert;
             DROP TRIGGER wakes_typed_cancellation_required;
             DROP TABLE effort_holder_activity_cancellation_epoch;
             ALTER TABLE wake_cancellations RENAME TO wake_cancellations_effort_activity_current;
             #{predecessor_sql};
             INSERT INTO wake_cancellations (#{@columns})
               SELECT #{@columns} FROM wake_cancellations_effort_activity_current;
             DROP TABLE wake_cancellations_effort_activity_current;
             #{trigger_sql};
             """)

    assert :ok = DB.execute(db, "PRAGMA legacy_alter_table=OFF")
    assert :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  defp rows(db, sql) do
    assert {:ok, rows} = DB.query(db, sql)
    rows
  end
end
