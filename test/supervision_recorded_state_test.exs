defmodule Tightbeam.SupervisionRecordedStateTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema, Supervision}

  setup do
    name = :"recorded_state_#{System.unique_integer([:positive])}"

    tmp = Path.join(System.tmp_dir!(), "recorded-db-#{System.unique_integer([:positive])}")
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "schema_shape_runtime.exs")
    path = Path.join(prepared.base, "state.db")
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm_rf!(tmp) end)
    db_opts = [name: name, path: path, guard_inputs: [], payload_root: prepared.payload]
    db = start_supervised!({DB, db_opts})
    %{db: db, db_opts: db_opts, payload: prepared.payload}
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

  test "0.1.8 operator-decision predecessor upgrades through the existing migrations", %{
    payload: payload
  } do
    path =
      Path.join(
        System.tmp_dir!(),
        "recorded-state-#{System.unique_integer([:positive])}/state.db"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(path, payload)
    name = :"recorded_predecessor_#{System.unique_integer([:positive])}"
    manifest = File.read!(Path.join(payload, "build-manifest.json")) |> JSON.decode!()
    transition = JSON.encode!(%{"base" => Path.dirname(path), "source" => "unmarked",
      "target" => manifest["buildIdentity"], "expectedSchema" => "operator-decision-requests-v1"})

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB, name: name, path: path, guard_inputs: [transition: transition], payload_root: payload}, id: name)
      )

    assert {:ok, [["operator-decision-requests-v1"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM supervision_state_migration")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "terminal sweeps bound their work and resume after a database restart", %{
    db: db,
    db_opts: db_opts
  } do
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

    :ok = stop_supervised(DB)
    db = start_supervised!({DB, db_opts})
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

  test "one inconsistent terminal is flagged without blocking the rest of a batch", %{db: db} do
    :ok = Schema.ensure_all(db)
    seed_session(db)
    :ok = DB.execute(db, """
    INSERT INTO patrol_failure_boundary(id,firstTurnSeq,activatedAt,principal)
      VALUES(0,1,1,'process:tightbeam');
    INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,endedAt)
      VALUES('s','inconsistent','test','prompt','queued',1,1),
            ('s','valid','test','prompt','delivered',2,2);
    """)
    assert :ok = Supervision.sweep_unclassified_terminals(db)
    assert {:ok, [[2]]} = DB.query(db, "SELECT turnSeq FROM patrol_terminal_classifications")
    assert {:ok, [["1"]]} = DB.query(db, "SELECT subject FROM lifecycle_events WHERE kind='supervision_terminal_refused'")
    assert {:ok, [[2]]} = DB.query(db, "SELECT lastTurnSeq FROM patrol_failure_boundary")
  end

  test "historical observations copy in bounded batches, skip bad records, and resume", %{db: db} do
    :ok = Schema.ensure_all(db)
    seed_session(db)

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

    assert {:ok, [["wake-1000", "wake-999"]]} =
             DB.query(
               db,
               "SELECT idleCleanupObservedWake,idleCleanupPreviousWake FROM sessions WHERE sessionKey='s'"
             )

    assert :ok = Schema.ensure_all(db)
    assert {:ok, true} = DB.transaction(db, &Supervision.backfill_idle_cleanup_in_txn/1)

    assert {:ok, [["wake-1001", "wake-1000"]]} =
             DB.query(
               db,
               "SELECT idleCleanupObservedWake,idleCleanupPreviousWake FROM sessions WHERE sessionKey='s'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='idle_cleanup_refused' AND subject='bad'"
             )

    assert {:ok, true} = DB.transaction(db, &Supervision.backfill_idle_cleanup_in_txn/1)
  end

  test "batched cleanup delivery records its members once in the delivery transaction", %{db: db} do
    :ok = Schema.ensure_all(db)
    seed_session(db)

    metadata = %{
      "group" => "parent",
      "owner" => "owner",
      "n" => 2,
      "depth" => 3,
      "main" => true,
      "members" => %{"s" => "token"}
    }

    group = :crypto.hash(:sha256, "idle-cleanup-group-v1\0parent") |> Base.encode16(case: :lower)
    ref = "idle-cleanup-v1:" <> group <> "|token|\n" <> JSON.encode!(metadata)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,obligationRef)
          VALUES('cleanup','s','process:tightbeam','cleanup',1,1,?1)
        """,
        [ref]
      )

    :ok = DB.execute(db, "UPDATE supervision_state_migration SET complete=0")

    assert {:ok, {:idle_cleanup_deferred, :state_backfill}} =
             DB.transaction(db, fn txn ->
               Supervision.idle_cleanup_delivery_in_txn(txn, "cleanup", 42)
             end)

    :ok = DB.execute(db, "UPDATE supervision_state_migration SET complete=1")

    :ok =
      DB.execute(db, """
      INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt)
        VALUES('carrier','s','process:tightbeam','batch',1,1);
      INSERT INTO notice_batches(batchId,recipientAddress,sessionKey,visibilityScope,policyRevision,
        state,dueAt,openedAt,sealedAt,deliveryToken,envelope,deliveryWakeId)
        VALUES('batch','session:s','s','owner','fixture','delivery_pending',1,1,1,'token','batch','carrier');
      INSERT INTO notice_batch_members(memberId,batchId,sourceWakeId,policyRef,recipientAddress,
        visibilityScope,publicationSeq,policyRevision,senderPrincipal,cause,class,payload,renderedBytes,state,addedAt)
        VALUES('member','batch','cleanup','policy','session:s','owner',1,'fixture','process:tightbeam',
               'idle_cleanup','fyi','cleanup',7,'included',1);
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,wakeId)
        VALUES('s','batch-message','process:tightbeam','batch','queued',1,'carrier');
      """)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.NoticeBatcher.enqueue_or_recover_in_txn(txn, {:delivered, "carrier", 42})
             end)

    assert {:ok, [[1, 42, 3, 1]]} =
             DB.query(db, Supervision.idle_cleanup_delivery_history_sql(), [group, "token"])

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Supervision.record_idle_cleanup_delivery_in_txn(txn, "cleanup")
             end)

    assert {:ok, [[1, 42, 3, 1]]} =
             DB.query(db, Supervision.idle_cleanup_delivery_history_sql(), [group, "token"])

    :ok =
      DB.execute(
        db,
        "DELETE FROM idle_cleanup_state; UPDATE wakes SET idleCleanupRecorded=0 WHERE wakeId='cleanup'"
      )

    assert {:error, _} =
             DB.transaction(db, fn txn ->
               Supervision.record_idle_cleanup_delivery_in_txn(txn, "cleanup")
               raise "rollback delivery"
             end)

    assert {:ok, []} = DB.query(db, "SELECT * FROM idle_cleanup_state")

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT idleCleanupRecorded FROM wakes WHERE wakeId='cleanup'")
  end

  defp seed_session(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
      VALUES('s','session','owner','user:owner','coder','fixture','fixture_provider','fixture',1,1)
      """)
  end
end
