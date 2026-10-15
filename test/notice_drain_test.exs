defmodule Tightbeam.NoticeDrainTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Ledger, Schema, SessionLane, Wakes}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,createdAt,updatedAt)
      VALUES('recipient','recipient','owner','user:owner','default','claude','anthropic','claude-sonnet-5','local',1,1);
      """)

    registry = start_supervised!({Tightbeam.ConnRegistry, name: nil})
    lane_name = :"notice_drain_lane_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane_name})
    opts = [conn_registry: registry, lane_manager: lane_name]
    %{db: db, delivery_opts: opts}
  end

  test "direct delivery records its turn before the transaction commits", ctx do
    wake = notice(ctx.db)

    assert {:ok, seq} =
             DB.transaction(ctx.db, fn txn ->
               assert {:appended, "recipient", _, _} =
                        Gateway.deliver_prompt_in_txn(txn, "recipient", wake.origin, wake.prompt,
                          wake_id: wake.wake_id,
                          fire_wake_in_txn: true
                        )

               [[seq]] =
                 DB.Txn.q(txn, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
                   wake.wake_id
                 ])

               assert is_integer(seq)

               assert [[^seq]] =
                        DB.Txn.q(txn, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])

               seq
             end)

    assert {:ok, [[^seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake.wake_id])
  end

  test "a NULL wake delivery stamp still deduplicates its committed turn", ctx do
    wake = notice(ctx.db)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               assert {:appended, "recipient", _, _} =
                        Gateway.deliver_prompt_in_txn(txn, "recipient", wake.origin, wake.prompt,
                          wake_id: wake.wake_id,
                          fire_wake_in_txn: true
                        )

               DB.Txn.q(txn, "UPDATE wakes SET deliveredTurnSeq=NULL WHERE wakeId=?1", [
                 wake.wake_id
               ])

               assert {:duplicate, _} =
                        Gateway.deliver_prompt_in_txn(txn, "recipient", wake.origin, wake.prompt,
                          wake_id: wake.wake_id,
                          fire_wake_in_txn: true
                        )

               :ok
             end)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])
  end

  test "a rescheduled deadline drains its prompt and leaves future prompts pending", ctx do
    due = notice(ctx.db, System.system_time(:millisecond) + 60_000)
    future = notice(ctx.db, System.system_time(:millisecond) + 120_000)

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: :notice_due_scheduler,
         tick_ms: 60_000,
         delivery_opts: ctx.delivery_opts,
         deliver: fn _ -> :ok end}
      )

    :sys.get_state(scheduler)
    assert Wakes.get(ctx.db, due.wake_id).state == "pending"

    assert {:ok, :ok} = DB.transaction(ctx.db, fn txn ->
      DB.Txn.q(txn, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [
        due.wake_id, System.system_time(:millisecond) - 1
      ])
      Wakes.schedule_changed_in_txn(txn)
    end)

    await_delivery(ctx.db, due.wake_id)
    assert Wakes.get(ctx.db, due.wake_id).state == "fired"
    assert Wakes.get(ctx.db, future.wake_id).state == "pending"

    assert {:ok, [[seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [due.wake_id])

    assert is_integer(seq)
  end

  for scope <- [:all, :recipient] do
    @scope scope
    test "#{scope} drain delivers a lineage notice to the successor after a respawn", ctx do
      :ok =
        DB.execute(ctx.db, """
        INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,spawnedBy,createdAt,updatedAt)
        VALUES('child','child','owner','user:owner','default','claude','anthropic','claude-sonnet-5','local','recipient',1,1),
          ('successor','successor','owner','user:owner','default','claude','anthropic','claude-sonnet-5','local',NULL,2,2);
        INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt)
        VALUES('lineage-work','Lineage work','owner','open','owner',1);
        INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,workItemId)
        VALUES('lineage-assignment','Lineage assignment','child','owner',1,'lineage-work');
        """)

      wake =
        Wakes.schedule(ctx.db, %{
          session_key: "recipient",
          origin: "process:test",
          prompt: "notice for the current parent",
          due_at: System.system_time(:millisecond),
          reresolve: "lineage",
          reresolve_seed: "child",
          reresolve_rung: 1
        })

      # Preserve the child's creation parent while recording its current parent
      # after the original recipient retires and its successor takes over.
      :ok =
        DB.execute(ctx.db, """
        UPDATE sessions SET state='retired' WHERE sessionKey='recipient';
        INSERT INTO session_reparent_events(eventId,ownerUserId,childSessionKey,assignmentId,workItemId,
          originParentSessionKey,previousCurrentParentSessionKey,newCurrentParentSessionKey,
          originAssignmentOpenerKind,originAssignmentOpenerRef,newCurrentCoordinationParentSessionKey,
          cause,principalKind,principalRef,idempotencyKey,requestFingerprint,createdAt)
        VALUES('lineage-reparent','owner','child','lineage-assignment','lineage-work',
          'recipient','recipient','successor','user','owner','successor',
          'owner_topology_correction','user','user:owner','lineage-reparent','lineage-reparent',2);
        """)

      recipient = if @scope == :recipient, do: "successor", else: nil

      assert [carrier] =
               Tightbeam.NoticeBatcher.recover(
                 ctx.db,
                 System.system_time(:millisecond),
                 ctx.delivery_opts,
                 recipient
               )

      assert Wakes.get(ctx.db, wake.wake_id).session_key == "recipient"
      assert Wakes.get(ctx.db, wake.wake_id).state == "fired"

      assert {:ok, [["successor", seq]]} =
               DB.query(ctx.db, "SELECT sessionKey,seq FROM turns WHERE wakeId=?1", [carrier])

      assert is_integer(seq)

      assert {:ok, [[^seq]]} =
               DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [carrier])

      assert Enum.map(Wakes.digest_members(ctx.db, carrier), & &1.wake_id) == [wake.wake_id]

      assert Tightbeam.NoticeBatcher.recover(
               ctx.db,
               System.system_time(:millisecond),
               ctx.delivery_opts
             ) == []
    end
  end

  test "a failed backfill logs and waits five seconds before retrying", ctx do
    :ok =
      DB.execute(ctx.db, """
      INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,state)
      VALUES('backfill-error','recipient','process:test','old',1,1,'fired');
      UPDATE wake_delivery_backfill SET afterRowid=0,
        throughRowid=(SELECT MAX(rowid) FROM wakes),completedAt=NULL;
      CREATE TRIGGER reject_backfill BEFORE UPDATE OF deliveredTurnSeq ON wakes
      BEGIN SELECT RAISE(ABORT,'backfill test refusal'); END;
      """)

    state = %{db: ctx.db}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:noreply, ^state} = Wakes.handle_info(:backfill_wake_delivery, state)
      end)

    assert log =~ "wake delivery backfill deferred for 5 seconds"
    refute_receive :backfill_wake_delivery, 200
    assert_receive :backfill_wake_delivery, 5_500

    assert {:ok, [[0, nil]]} =
             DB.query(
               ctx.db,
               "SELECT afterRowid,completedAt FROM wake_delivery_backfill"
             )
  end

  test "a busy backlog adds no idle database calls or preparation", ctx do
    scheduler = start_supervised!({Wakes, db: ctx.db, name: nil,
      deliver: fn _ -> flunk("unexpected delivery") end,
      delivery_opts: ctx.delivery_opts})
    Process.sleep(300)
    :ok = Wakes.fire_due(scheduler)
    empty = idle_requests(ctx.db)
    assert empty == []

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: "recipient",
               message_id: "busy",
               origin: "user:owner",
               prompt: "hold"
             })

    :ok =
      DB.execute(ctx.db, """
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000)
      INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt)
      SELECT 'notice-' || x,'recipient','process:test','waiting',1,1 FROM n;
      """)

    :ok = Wakes.fire_due(scheduler)
    busy = idle_requests(ctx.db)
    assert busy == []
    refute Enum.any?(busy, &match?({:transaction_then, _, _}, &1))
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM notice_batches")
    assert {:ok, [[1000]]} = DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE state='pending'")
  end

  test "turn completion drains the recipient without waiting for a scheduler tick", ctx do
    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})
    tasks = start_supervised!({Task.Supervisor, name: :notice_drain_tasks})

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: :notice_drain_scheduler,
         tick_ms: 60_000,
         delivery_opts: ctx.delivery_opts,
         deliver: fn _ -> :ok end}
      )

    parent = self()

    assert {:ok, initial} =
             Ledger.enqueue(ctx.db, %{
               session_key: "recipient",
               message_id: "busy",
               origin: "user:owner",
               prompt: "hold"
             })

    start_supervised!(
      {SessionLane,
       session_key: "recipient",
       db: ctx.db,
       task_sup: tasks,
       wake_scheduler: scheduler,
       runner: fn turn ->
         if turn.seq == initial do
           send(parent, {:running, self()})

           receive do
             :release -> :ok
           end
         end

         {:ok, %{text: "done"}}
       end,
       on_terminal: fn _, seq -> send(parent, {:terminal, seq}) end}
    )

    assert_receive {:running, runner}
    wake = notice(ctx.db)
    assert :ok = Wakes.fire_due(scheduler)

    assert {:ok, [[nil]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake.wake_id])

    send(runner, :release)
    assert_receive {:terminal, ^initial}, 2_000
    :sys.get_state(scheduler)

    assert {:ok, [[seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake.wake_id])

    assert is_integer(seq)

    assert {:ok, [[^seq]]} =
             DB.query(
               ctx.db,
               "SELECT t.seq FROM turns t JOIN notice_batches b ON b.deliveryWakeId=t.wakeId JOIN notice_batch_members m ON m.batchId=b.batchId WHERE m.sourceWakeId=?1",
               [wake.wake_id]
             )
  end

  test "the miss detector drains overdue notices and leaves future notices alone", ctx do
    future = notice(ctx.db, System.system_time(:millisecond) + 60_000)

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: :notice_detector_scheduler,
         tick_ms: 60_000,
         delivery_opts: ctx.delivery_opts,
         deliver: fn _ -> :ok end}
      )

    :sys.get_state(scheduler)
    # Insert after boot with its event deliberately omitted, simulating a miss.
    assert {:ok, due} = DB.transaction(ctx.db, fn txn ->
      source = Wakes.schedule_in_txn(txn, %{session_key: "recipient", origin: "process:test",
        prompt: "notice", due_at: System.system_time(:millisecond) - 61_000, target_gate: 0})
      Process.put({DB.Txn, :outbox, txn.outbox}, [])
      source
    end)
    send(scheduler, :detect_misses)
    :sys.get_state(scheduler)
    assert Wakes.health(scheduler) == %{misses: 1}
    assert Wakes.get(ctx.db, due.wake_id).state == "fired"
    assert Wakes.get(ctx.db, future.wake_id).state == "pending"
  end

  defp notice(db, at \\ System.system_time(:millisecond)) do
    Wakes.schedule(db, %{
      session_key: "recipient",
      origin: "process:test",
      prompt: "notice",
      due_at: at,
      target_gate: 0
    })
  end

  defp idle_requests(db) do
    :erlang.trace(db, true, [:receive])
    Process.sleep(1_200)
    ref = :erlang.trace_delivered(db)
    assert_receive {:trace_delivered, ^db, ^ref}
    :erlang.trace(db, false, [:receive])
    collect_requests(db, [])
  end

  defp await_delivery(db, wake_id, attempts \\ 100)
  defp await_delivery(_db, _wake_id, 0), do: flunk("deadline event did not deliver the notice")
  defp await_delivery(db, wake_id, attempts) do
    case DB.query(db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake_id]) do
      {:ok, [[seq]]} when is_integer(seq) -> seq
      _ ->
        Process.sleep(10)
        await_delivery(db, wake_id, attempts - 1)
    end
  end

  defp collect_requests(db, requests) do
    receive do
      {:trace, ^db, :receive, {:"$gen_call", _, request}} ->
        collect_requests(db, [request | requests])

      {:trace, ^db, :receive, _} ->
        collect_requests(db, requests)
    after
      0 -> requests
    end
  end
end
