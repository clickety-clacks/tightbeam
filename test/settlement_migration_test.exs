defmodule Tightbeam.SettlementMigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}

  @assignment_replacement_route ~r/\(requesterId = 'tightbeam:assignments' AND reasonKind = 'superseded' AND\s+causalSourceKind = 'wake' AND outcomeKind = 'replacement'\)\s+OR/

  setup do
    db = :"settlement_migration_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    Tightbeam.HistoricalSchemaFixture.load!(
      db,
      "cannot_proceed_predecessor_2d70e49b",
      "4fd9dd1992166594cd3da01c56a5cd50587463dce2dcb1b76106b1c2c6c21131"
    )

    assert {:ok, [["cannot-proceed-v1-019"]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    :ok =
      DB.execute(db, """
      INSERT INTO wire_idempotency VALUES
        ('mike','session-reparent','prior-key','prior-event','prior-fingerprint','{"prior":true}'),
        ('mike','session-po-set','po-key','po-event','po-fingerprint','{"po":true}');
      """)

    %{db: db}
  end

  test "named transition preserves reparent and PO replay and is idempotent", %{db: db} do
    preserved_sql =
      "SELECT name,sql FROM sqlite_master WHERE name IN ('assignments','attests','assignment_cannot_proceed') ORDER BY name"

    assert {:ok, before_ddl} = DB.query(db, preserved_sql)
    assert length(before_ddl) == 3
    # Preserve the settlement transition's objects at its own boundary, before
    # subsequent migrations update assignment and actor schemas.
    assert :ok =
             DB.execute(db, """
             CREATE TABLE settlement_schema_checkpoint AS #{preserved_sql} LIMIT 0;
             CREATE TRIGGER capture_settlement_schema AFTER UPDATE ON schema_stamp
             WHEN NEW.shape='stale-turn-settlement-v1-019'
             BEGIN INSERT INTO settlement_schema_checkpoint #{preserved_sql}; END;
             """)

    assert :ok = Schema.ensure_all(db)

    assert {:ok, ^before_ddl} =
             DB.query(db, "SELECT name,sql FROM settlement_schema_checkpoint ORDER BY name")

    assert {:ok, [[wake_cancellations_ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
             )

    assert Regex.match?(@assignment_replacement_route, wake_cancellations_ddl)
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")

    assert {:ok, [["closed-assignment-cannot-proceed-reconciliation-v1-015"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, [["prior-fingerprint", ~s({"prior":true}), nil]]} =
             DB.query(
               db,
               "SELECT requestFingerprint,canonicalResponse,responseJson FROM wire_idempotency WHERE operation='session-reparent'"
             )

    assert {:ok, [[1]]} = DB.query(db, "SELECT firstTurnSeq FROM turn_lifecycle_epoch")

    assert {:ok, [["po-fingerprint", ~s({"po":true}), nil]]} =
             DB.query(
               db,
               "SELECT requestFingerprint,canonicalResponse,responseJson FROM wire_idempotency WHERE operation='session-po-set'"
             )

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM wire_idempotency")
  end

  test "stamp failure rolls back idempotency rebuild and lifecycle activation together", %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TRIGGER reject_settlement_stamp BEFORE UPDATE ON schema_stamp
      WHEN NEW.shape='stale-turn-settlement-v1-019'
      BEGIN SELECT RAISE(ABORT,'forced settlement rollback'); END;
      """)

    assert_raise Tightbeam.DB.Error, fn -> Schema.ensure_all(db) end

    assert {:ok, [["cannot-proceed-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE name IN ('turn_lifecycle_events','turn_lifecycle_epoch','wire_idempotency_settlement')"
             )

    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(wire_idempotency)")
    assert length(columns) == 6

    assert {:ok, [["prior-fingerprint", ~s({"prior":true})]]} =
             DB.query(
               db,
               "SELECT requestFingerprint,canonicalResponse FROM wire_idempotency WHERE operation='session-reparent'"
             )
  end
end
