defmodule Tightbeam.NoticeDrainTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Ledger, Schema, SessionLane, Wakes}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, """
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
    assert {:ok, seq} = DB.transaction(ctx.db, fn txn ->
      assert {:appended, "recipient", _, _} = Gateway.deliver_prompt_in_txn(txn, "recipient", wake.origin, wake.prompt,
        wake_id: wake.wake_id, fire_wake_in_txn: true)
      [[seq]] = DB.Txn.q(txn, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake.wake_id])
      assert is_integer(seq)
      assert [[^seq]] = DB.Txn.q(txn, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])
      seq
    end)
    assert {:ok, [[^seq]]} = DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake.wake_id])
  end

  test "a busy backlog does not add database calls or preparation to a tick", ctx do
    state = %{db: ctx.db, deliver: fn _ -> flunk("unexpected delivery") end,
      internal_consumers: %{}, delivery_opts: ctx.delivery_opts, tick_ms: 60_000,
      review_remedy_interval_ms: 60_000, batch: 100}
    empty = tick_requests(ctx.db, state)
    assert {:ok, _seq} = Ledger.enqueue(ctx.db, %{session_key: "recipient", message_id: "busy", origin: "user:owner", prompt: "hold"})
    :ok = DB.execute(ctx.db, """
    WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000)
    INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt)
    SELECT 'notice-' || x,'recipient','process:test','waiting',1,1 FROM n;
    """)
    busy = tick_requests(ctx.db, state)
    assert length(busy) == length(empty)
    refute Enum.any?(busy, &match?({:transaction_then, _, _}, &1))
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM notice_batches")
    assert {:ok, [[1000]]} = DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE state='pending'")
  end

  test "turn completion drains the recipient without waiting for a scheduler tick", ctx do
    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})
    tasks = start_supervised!({Task.Supervisor, name: :notice_drain_tasks})
    scheduler = start_supervised!({Wakes, db: ctx.db, name: :notice_drain_scheduler,
      tick_ms: 60_000, delivery_opts: ctx.delivery_opts, deliver: fn _ -> :ok end})
    parent = self()
    assert {:ok, initial} = Ledger.enqueue(ctx.db, %{session_key: "recipient", message_id: "busy", origin: "user:owner", prompt: "hold"})
    start_supervised!({SessionLane, session_key: "recipient", db: ctx.db, task_sup: tasks,
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
      on_terminal: fn _, seq -> send(parent, {:terminal, seq}) end})
    assert_receive {:running, runner}
    wake = notice(ctx.db)
    assert :ok = Wakes.fire_due(scheduler)
    assert {:ok, [[nil]]} = DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake.wake_id])
    send(runner, :release)
    assert_receive {:terminal, ^initial}, 2_000
    :sys.get_state(scheduler)
    assert {:ok, [[seq]]} = DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake.wake_id])
    assert is_integer(seq)
    assert {:ok, [[^seq]]} = DB.query(ctx.db, "SELECT t.seq FROM turns t JOIN notice_batches b ON b.deliveryWakeId=t.wakeId JOIN notice_batch_members m ON m.batchId=b.batchId WHERE m.sourceWakeId=?1", [wake.wake_id])
  end

  test "fallback drains due notices and leaves future notices alone", ctx do
    due = notice(ctx.db)
    future = notice(ctx.db, System.system_time(:millisecond) + 60_000)
    scheduler = start_supervised!({Wakes, db: ctx.db, name: :notice_fallback_scheduler,
      tick_ms: 60_000, delivery_opts: ctx.delivery_opts, deliver: fn _ -> :ok end})
    send(scheduler, :notice_fallback)
    :sys.get_state(scheduler)
    assert Wakes.get(ctx.db, due.wake_id).state == "fired"
    assert Wakes.get(ctx.db, future.wake_id).state == "pending"
  end

  defp notice(db, at \\ System.system_time(:millisecond)) do
    Wakes.schedule(db, %{session_key: "recipient", origin: "process:test", prompt: "notice", due_at: at, target_gate: 0})
  end

  defp tick_requests(db, state) do
    :erlang.trace(db, true, [:receive])
    assert {:noreply, ^state} = Wakes.handle_info(:tick, state)
    ref = :erlang.trace_delivered(db)
    assert_receive {:trace_delivered, ^db, ^ref}
    :erlang.trace(db, false, [:receive])
    collect_requests(db, [])
  end

  defp collect_requests(db, requests) do
    receive do
      {:trace, ^db, :receive, {:"$gen_call", _, request}} -> collect_requests(db, [request | requests])
      {:trace, ^db, :receive, _} -> collect_requests(db, requests)
    after
      0 -> requests
    end
  end
end
