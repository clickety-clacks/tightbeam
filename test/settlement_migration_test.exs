defmodule Tightbeam.SettlementMigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}

  setup do
    db = :"settlement_migration_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    # Build the exact six-column predecessor, including reparent and PO replay contracts.
    # This is an isolated fixture, never a live downgrade or runtime repair.
    :ok =
      DB.execute(db, """
      DROP TABLE turn_lifecycle_events;
      DROP TABLE turn_lifecycle_epoch;
      DROP TABLE wire_idempotency;
      CREATE TABLE wire_idempotency (
        ownerUserId TEXT NOT NULL,
        operation TEXT NOT NULL CHECK(operation IN
          ('spawn','retire','wake','assign','condition','work-item-create','session-reparent','session-po-set')),
        idempotencyKey TEXT NOT NULL,
        sessionKey TEXT NOT NULL,
        requestFingerprint TEXT,
        canonicalResponse TEXT,
        PRIMARY KEY(ownerUserId,operation,idempotencyKey),
        CHECK(operation NOT IN ('session-reparent','session-po-set') OR
          (requestFingerprint IS NOT NULL AND canonicalResponse IS NOT NULL))
      );
      INSERT INTO wire_idempotency VALUES
        ('mike','session-reparent','prior-key','prior-event','prior-fingerprint','{"prior":true}'),
      ('mike','session-po-set','po-key','po-event','po-fingerprint','{"po":true}');
      UPDATE schema_stamp SET shape='cannot-proceed-v1-019';
      """)

    %{db: db}
  end

  test "named transition preserves reparent and PO replay and is idempotent", %{db: db} do
    preserved_sql =
      "SELECT name,sql FROM sqlite_master WHERE name IN ('wake_cancellations','assignments','attests','assignment_cannot_proceed') ORDER BY name"

    assert {:ok, before_ddl} = DB.query(db, preserved_sql)
    assert length(before_ddl) == 4
    assert :ok = Schema.ensure_all(db)
    assert {:ok, ^before_ddl} = DB.query(db, preserved_sql)
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")

    assert {:ok, [["stale-turn-settlement-v1-019"]]} =
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
