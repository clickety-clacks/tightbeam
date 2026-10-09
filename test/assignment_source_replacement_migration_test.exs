defmodule Tightbeam.AssignmentSourceReplacementMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, Schema, Wakes}

  @predecessor "work-item-delivery-owner-v1-019"
  @successor "notice-source-storage-v1-019"
  @replacement_route ~r/\(requesterId = 'tightbeam:assignments' AND reasonKind = 'superseded' AND\s+causalSourceKind = 'wake' AND outcomeKind = 'replacement'\)\s+OR/
  @cancellation_columns "wakeId,wakeState,canceledAt,requesterKind,requesterId,reasonKind," <>
                          "causalSourceKind,causalSourceId,outcomeKind,replacementWakeId," <>
                          "dispositionKind,dispositionId,primaryWorkKind,primaryWorkId,workImpactKind," <>
                          "livenessTriggerKind,livenessTriggerId,actionNeeded"

  setup do
    db = :"assignment_source_replacement_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    assert :ok = Schema.ensure_all(db)

    assert :ok =
             DB.execute(
               db,
               "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn',1,1)"
             )

    session_key = "assignment-replacement-holder"

    Org.create(db, %{
      session_key: session_key,
      display_name: "Replacement holder",
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

    downgrade_to_receipt_cancellation_predecessor!(db)
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@predecessor]]
    %{db: db, before_rows: before_rows}
  end

  test "the exact predecessor widens only sender replacement and preserves cancellation rows",
       %{db: db, before_rows: before_rows} do
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@successor]]
    assert rows(db, "SELECT * FROM wake_cancellations ORDER BY wakeId") == before_rows
    assert rows(db, "PRAGMA foreign_key_check") == []

    assert [[table_sql]] =
             rows(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
             )

    assert Regex.match?(@replacement_route, table_sql)
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT * FROM wake_cancellations ORDER BY wakeId") == before_rows
  end

  defp downgrade_to_receipt_cancellation_predecessor!(db) do
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_notice_source_storage!(db)

    assert [[current_sql]] =
             rows(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
             )

    predecessor_sql = Regex.replace(@replacement_route, current_sql, "", global: false)
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
             ALTER TABLE wake_cancellations RENAME TO wake_cancellations_assignment_replacement_current;
             #{predecessor_sql};
             INSERT INTO wake_cancellations (#{@cancellation_columns})
               SELECT #{@cancellation_columns} FROM wake_cancellations_assignment_replacement_current;
             DROP TABLE wake_cancellations_assignment_replacement_current;
             #{trigger_sql};
             UPDATE schema_stamp SET shape='#{@predecessor}',stampedAt=1;
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
