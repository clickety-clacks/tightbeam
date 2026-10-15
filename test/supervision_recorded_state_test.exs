defmodule Tightbeam.SupervisionRecordedStateTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema, Supervision}

  setup do
    name = :"recorded_state_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "recorded-db-#{System.unique_integer([:positive])}/state.db")
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    db = start_supervised!({DB, name: name, path: path})
    %{db: db, path: path, name: name}
  end

  test "0.1.9 upgrade records its migration once and preserves its checkpoint", %{db: db} do
    :ok = DB.execute(db, File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql")))
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM supervision_state_migration")

    :ok =
      DB.execute(db, "UPDATE supervision_state_migration SET wakeCursor=77,observationCursor=88")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[77, 88]]} =
             DB.query(db, "SELECT wakeCursor,observationCursor FROM supervision_state_migration")
  end

  test "0.1.8 operator-decision predecessor upgrades through the existing migrations" do
    path =
      Path.join(
        System.tmp_dir!(),
        "recorded-state-#{System.unique_integer([:positive])}/state.db"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(path)
    name = :"recorded_predecessor_#{System.unique_integer([:positive])}"
    db = start_supervised!({DB, name: name, path: path})

    assert {:ok, [["operator-decision-requests-v1"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM supervision_state_migration")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "terminal sweeps bound their work and resume after a database restart", %{db: db, path: path, name: name} do
    :ok = Schema.ensure_all(db)
    seed_session(db)

    :ok =
      DB.execute(db, """
      INSERT INTO patrol_failure_boundary(id,firstTurnSeq,activatedAt,principal)
        VALUES(0,1,1,'process:tightbeam');
      WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<300)
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,endedAt)
        SELECT 's','message-'||i,'test','prompt','delivered',i,i FROM n;
      """)

    assert :ok = Supervision.sweep_unclassified_terminals(db)

    assert {:ok, [[256, 256]]} =
             DB.query(db, "SELECT COUNT(*),MAX(turnSeq) FROM patrol_terminal_classifications")

    assert :ok = Schema.ensure_all(db)
    assert :ok = Supervision.sweep_unclassified_terminals(db)

    assert {:ok, [[300, 300]]} =
             DB.query(db, "SELECT COUNT(*),MAX(turnSeq) FROM patrol_terminal_classifications")

    assert {:ok, [[300]]} = DB.query(db, "SELECT lastTurnSeq FROM patrol_failure_boundary")
  end

  test "a late terminal rewinds the checkpoint and is classified", %{db: db} do
    :ok = Schema.ensure_all(db)
    seed_session(db)

    :ok =
      DB.execute(db, """
      INSERT INTO patrol_failure_boundary(id,firstTurnSeq,activatedAt,principal)
        VALUES(0,1,1,'process:tightbeam');
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt)
        VALUES('s','late','test','prompt','running',1);
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,endedAt)
        VALUES('s','done','test','prompt','delivered',2,2);
      """)

    assert :ok = Supervision.sweep_unclassified_terminals(db)
    assert {:ok, [[2]]} = DB.query(db, "SELECT lastTurnSeq FROM patrol_failure_boundary")
    :ok = DB.execute(db, "UPDATE turns SET endedAt=3,status='delivered' WHERE messageId='late'")
    assert {:ok, [[0]]} = DB.query(db, "SELECT lastTurnSeq FROM patrol_failure_boundary")
    assert :ok = Supervision.sweep_unclassified_terminals(db)
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM patrol_terminal_classifications")
  end

  test "historical observations copy in bounded batches, skip bad records, and resume", %{db: db} do
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      UPDATE supervision_state_migration SET complete=0;
      WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<1001)
      INSERT INTO lifecycle_events(ts,kind,subject,detail)
        SELECT i,'idle_cleanup_pending_observed','wake-'||i,'{"session":"s"}' FROM n;
      INSERT INTO lifecycle_events(ts,kind,subject,detail)
        VALUES(1002,'idle_cleanup_pending_observed','bad','invalid json');
      """)

    assert {:ok, false} = DB.transaction(db, &Supervision.backfill_idle_cleanup_in_txn/1)
    assert {:ok, [[1000]]} = DB.query(db, "SELECT COUNT(*) FROM idle_cleanup_observations")
    assert :ok = Schema.ensure_all(db)
    assert {:ok, true} = DB.transaction(db, &Supervision.backfill_idle_cleanup_in_txn/1)
    assert {:ok, [[1001]]} = DB.query(db, "SELECT COUNT(*) FROM idle_cleanup_observations")

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='idle_cleanup_refused' AND subject='bad'"
             )

    assert {:ok, true} = DB.transaction(db, &Supervision.backfill_idle_cleanup_in_txn/1)
  end

  defp seed_session(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
      VALUES('s','session','owner','user:owner','coder','fixture','fixture','fixture',1,1)
      """)
  end
end
