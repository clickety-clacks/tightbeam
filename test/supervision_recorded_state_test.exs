defmodule Tightbeam.SupervisionRecordedStateTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema, Supervision}
  import ExUnit.CaptureLog

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

  test "0.1.9 upgrade records its migration once without changing the sidecar DDL", %{db: db} do
    :ok = DB.execute(db, File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql")))
    assert :ok = Schema.ensure_all(db)
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_supervision_recorded_state!(db)

    assert {:ok, [[ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE name='supervision_liveness_sidecar'"
             )

    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM supervision_state_migration")

    assert {:ok, [[^ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE name='supervision_liveness_sidecar'"
             )
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

    transition =
      JSON.encode!(%{
        "base" => Path.dirname(path),
        "source" => "unmarked",
        "target" => manifest["buildIdentity"],
        "expectedSchema" => "operator-decision-requests-v1"
      })

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           name: name, path: path, guard_inputs: [transition: transition], payload_root: payload},
          id: name
        )
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

    :ok =
      DB.execute(db, """
      INSERT INTO patrol_failure_boundary(id,firstTurnSeq,activatedAt,principal)
        VALUES(0,1,1,'process:tightbeam');
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,endedAt)
        VALUES('s','inconsistent','test','prompt','queued',1,1),
              ('s','valid','test','prompt','delivered',2,2);
      """)

    log = capture_log(fn -> assert :ok = Supervision.sweep_unclassified_terminals(db) end)
    assert log =~ "terminal classification refused for turn 1:"

    assert {:ok, [[reason]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind='supervision_terminal_refused' AND subject='1'"
             )

    assert reason != ""
    assert log =~ reason
    :ok = DB.execute(db, "UPDATE patrol_failure_boundary SET lastTurnSeq=0")
    repeated = capture_log(fn -> assert :ok = Supervision.sweep_unclassified_terminals(db) end)
    refute repeated =~ "terminal classification refused for turn 1:"
    assert {:ok, [[2]]} = DB.query(db, "SELECT turnSeq FROM patrol_terminal_classifications")

    assert {:ok, [["1"]]} =
             DB.query(
               db,
               "SELECT subject FROM lifecycle_events WHERE kind='supervision_terminal_refused'"
             )

    assert {:ok, [[2]]} = DB.query(db, "SELECT lastTurnSeq FROM patrol_failure_boundary")
  end

  test "migration copies all historical observations once and skips bad records", %{db: db} do
    :ok = Schema.ensure_all(db)
    seed_session(db)
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_supervision_recorded_state!(db)

    :ok =
      DB.execute(db, """
      WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<1001)
      INSERT INTO lifecycle_events(ts,kind,subject,detail)
        SELECT i,'idle_cleanup_pending_observed','wake-'||i,'{"session":"s"}' FROM n;
      INSERT INTO lifecycle_events(ts,kind,subject,detail)
        VALUES(1002,'idle_cleanup_pending_observed','bad','invalid json');
      """)

    assert :ok = Schema.ensure_all(db)

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

    # A second boot must not replay observations over newer recorded state.
    :ok =
      DB.execute(db, "UPDATE sessions SET idleCleanupObservedWake='newer' WHERE sessionKey='s'")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["newer"]]} =
             DB.query(db, "SELECT idleCleanupObservedWake FROM sessions WHERE sessionKey='s'")
  end

  test "migration delivery copy equals the old history derivation", %{db: db} do
    :ok = Schema.ensure_all(db)
    seed_session(db)
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_supervision_recorded_state!(db)
    group = :crypto.hash(:sha256, "idle-cleanup-group-v1\0parent") |> Base.encode16(case: :lower)

    for {id, state, at, depth, main, token} <- [
          {"direct", "fired", 12, 1, false, "token"},
          {"batched", "fired", 42, 3, true, "token"},
          {"not-delivered", "fired", 80, 9, true, "token"},
          {"canceled", "canceled", 90, 9, true, "token"},
          {"pending", "pending", nil, 9, true, "token"},
          {"other-occurrence", "fired", 100, 8, false, "other-token"}
        ] do
      metadata = %{
        "group" => "parent",
        "owner" => "owner",
        "n" => 2,
        "depth" => depth,
        "main" => main,
        "members" => %{"s" => token}
      }

      ref = "idle-cleanup-v1:" <> group <> "|" <> token <> "|\n" <> JSON.encode!(metadata)

      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,state,firedAt,obligationRef)
          VALUES(?1,'s','process:tightbeam','cleanup',1,1,?2,?3,?4)
          """,
          [id, state, at, ref]
        )
    end

    :ok =
      DB.execute(db, """
      INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt)
        VALUES('carrier','s','process:tightbeam','batch',1,1);
      INSERT INTO notice_batches(batchId,recipientAddress,sessionKey,visibilityScope,policyRevision,
        state,dueAt,openedAt,sealedAt,deliveryToken,envelope,deliveryWakeId)
        VALUES('batch','session:s','s','owner','fixture','delivery_pending',1,1,1,'token','batch','carrier');
      INSERT INTO notice_batch_members(memberId,batchId,sourceWakeId,policyRef,recipientAddress,
        visibilityScope,publicationSeq,policyRevision,senderPrincipal,cause,class,payload,renderedBytes,state,addedAt)
        VALUES('member','batch','batched','policy','session:s','owner',1,'fixture','process:tightbeam',
               'idle_cleanup','fyi','cleanup',7,'included',1);
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,wakeId)
        VALUES('s','direct-message','process:tightbeam','cleanup','queued',1,'direct'),
              ('s','batch-message','process:tightbeam','batch','queued',1,'carrier'),
              ('s','other-message','process:tightbeam','cleanup','queued',1,'other-occurrence'),
              ('s','canceled-message','process:tightbeam','cleanup','queued',1,'canceled');
      """)

    # Preserve the old packed-reference selection and metadata reduction as
    # an independent oracle, including both direct and carried delivery.
    assert {:ok, history} =
             DB.query(
               db,
               """
               SELECT w.firedAt,w.obligationRef FROM wakes w
               WHERE w.origin='process:tightbeam' AND w.state='fired'
                 AND w.obligationRef LIKE ?1 AND w.obligationRef LIKE ?2
                 AND (EXISTS(SELECT 1 FROM turns t WHERE t.wakeId=w.wakeId)
                   OR EXISTS(SELECT 1 FROM notice_batch_members m
                     JOIN notice_batches b ON b.batchId=m.batchId
                     JOIN turns t ON t.wakeId=b.deliveryWakeId
                     WHERE m.sourceWakeId=w.wakeId AND m.state='included'))
               """,
               ["idle-cleanup-v1:" <> group <> "|%", "%|token|%"]
             )

    expected =
      Enum.reduce(history, [0, 0, 0, 0], fn [at, ref], [count, last, depth, main] ->
        [_, json] = String.split(ref, "\n", parts: 2)
        metadata = JSON.decode!(json)

        [
          count + 1,
          max(last, at),
          max(depth, metadata["depth"]),
          max(main, if(metadata["main"], do: 1, else: 0))
        ]
      end)

    assert expected == [2, 42, 3, 1]
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [^expected]} =
             DB.query(db, Supervision.idle_cleanup_delivery_history_sql(), [group, "token"])

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [^expected]} =
             DB.query(db, Supervision.idle_cleanup_delivery_history_sql(), [group, "token"])

    assert {:ok, [[1, 100, 8, 0]]} =
             DB.query(db, Supervision.idle_cleanup_delivery_history_sql(), [group, "other-token"])
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

    # Historical turn evidence alone must not bypass the runtime delivery column.
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(txn, "UPDATE wakes SET state='fired',firedAt=42 WHERE wakeId='cleanup'")
               Supervision.record_idle_cleanup_delivery_in_txn(txn, "cleanup")
             end)

    assert {:ok, []} = DB.query(db, "SELECT * FROM idle_cleanup_state")
    assert {:ok, _} = DB.query(db, "UPDATE wakes SET state='pending',firedAt=NULL WHERE wakeId='cleanup'")

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               # Gateway stamps included sources before the delivered callback.
               Tightbeam.DB.Txn.q(txn, """
               UPDATE wakes SET deliveredTurnSeq=(SELECT seq FROM turns WHERE wakeId='carrier')
               WHERE wakeId='cleanup'
               """)

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
