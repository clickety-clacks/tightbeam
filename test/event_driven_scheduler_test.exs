defmodule Tightbeam.EventDrivenSchedulerTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog
  alias Tightbeam.{DB, Ledger, NoticeBatcher, Wakes}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = ensure_all_schemas(db)
    registry = start_supervised!({Tightbeam.ConnRegistry, name: nil})
    lane_name = :"event_lane_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane_name})

    :ok =
      DB.execute(db, """
      INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',1,1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,
        provider,model,host,state,createdAt,updatedAt)
      VALUES ('recipient','recipient','owner','user:owner','default','claude',
        'anthropic','fable','testhost','active',1,1);
      """)

    %{db: db, delivery_opts: [conn_registry: registry, lane_manager: lane_name]}
  end

  defp scheduler(ctx, extra \\ []) do
    parent = self()

    start_supervised!(
      {Wakes,
       [
         db: ctx.db,
         name: nil,
         deliver: fn wake ->
           send(parent, {:delivered, wake.wake_id, System.system_time(:millisecond)})
         end,
         internal_consumers: %{
           "test" => fn wake ->
             send(parent, {:delivered, wake.wake_id, System.system_time(:millisecond)})
           end
         },
         delivery_opts: ctx.delivery_opts
       ] ++ extra}
    )
  end

  defp wake(db, due_at, extra \\ %{}) do
    Wakes.schedule(
      db,
      Map.merge(
        %{
          session_key: "recipient",
          origin: "system",
          prompt: "scheduled notice",
          due_at: due_at,
          sender_scheduled: true
        },
        extra
      )
    )
  end

  defp busy(db) do
    {:ok, _} =
      Ledger.enqueue(db, %{
        session_key: "recipient",
        message_id: "busy",
        origin: "user:owner",
        prompt: "working"
      })

    {:ok, turn} = Ledger.claim_next(db, "recipient", "testhost")
    turn
  end

  test "an empty scheduler sleeps without database calls between events", ctx do
    pid = scheduler(ctx)
    # The one-time delivery backfill completes before measuring idle work.
    Process.sleep(300)
    :sys.get_state(pid)
    1 = :erlang.trace(pid, true, [:send, {:tracer, self()}])

    try do
      refute_receive {:trace, ^pid, :send, {:"$gen_call", _, _}, _}, 1_200
    after
      :erlang.trace(pid, false, [:send])
    end

    assert :sys.get_state(pid).timer == nil
  end

  @tag timeout: 20_000
  test "a wake inserted after boot fires at its ten second deadline without a tick", ctx do
    pid = scheduler(ctx)
    later = wake(ctx.db, System.system_time(:millisecond) + 60_000, %{consumer: "test"})
    due = System.system_time(:millisecond) + 10_000
    scheduled = wake(ctx.db, due, %{consumer: "test"})
    assert_receive {:delivered, id, fired_at}, 11_000
    assert id == scheduled.wake_id
    assert fired_at >= due
    assert fired_at - due < 1_000
    assert Wakes.get(ctx.db, later.wake_id).state == "pending"
    assert Process.alive?(pid)
  end

  test "a committed deadline change moves the timer earlier", ctx do
    pid = scheduler(ctx)
    scheduled = wake(ctx.db, System.system_time(:millisecond) + 60_000, %{consumer: "test"})
    due = System.system_time(:millisecond) + 250

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(txn, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [scheduled.wake_id, due])

               Wakes.schedule_changed_in_txn(txn)
             end)

    assert_receive {:delivered, id, fired_at}, 1_250
    assert id == scheduled.wake_id
    assert fired_at >= due and fired_at - due < 1_000
    assert Process.alive?(pid)
  end

  test "boot reconstructs the earliest timer from pending wakes", ctx do
    scheduled = wake(ctx.db, System.system_time(:millisecond) + 300, %{consumer: "test"})
    scheduler(ctx)
    assert_receive {:delivered, id, _}, 1_300
    assert id == scheduled.wake_id
  end

  test "a rolled back schedule never arms the timer", ctx do
    pid = scheduler(ctx)

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.schedule_in_txn(txn, %{
                 session_key: "recipient",
                 origin: "system",
                 consumer: "test",
                 due_at: System.system_time(:millisecond)
               })

               raise "rollback"
             end)

    assert :sys.get_state(pid).timer == nil
    refute_receive {:delivered, _, _}, 100
  end

  test "the recipient readiness signal drains its waiting notices without a fallback", ctx do
    turn = busy(ctx.db)
    pid = scheduler(ctx)
    source = wake(ctx.db, System.system_time(:millisecond) - 100)
    :ok = Wakes.fire_due(pid)
    assert NoticeBatcher.source_refs(ctx.db, source.wake_id) == []
    :ok = Ledger.finish(ctx.db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
    Wakes.recipient_ready(pid, "recipient")
    :sys.get_state(pid)

    assert {:ok, [[seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
               source.wake_id
             ])

    assert is_integer(seq)
    assert Wakes.health(pid) == %{misses: 0}
  end

  test "the detector ignores busy recipients then delivers and logs a suppressed readiness signal",
       ctx do
    turn = busy(ctx.db)
    pid = scheduler(ctx)
    source = wake(ctx.db, System.system_time(:millisecond) - 61_000)
    :ok = Wakes.fire_due(pid)
    send(pid, :detect_misses)
    :sys.get_state(pid)
    assert Wakes.health(pid) == %{misses: 0}
    assert NoticeBatcher.source_refs(ctx.db, source.wake_id) == []
    :ok = Ledger.finish(ctx.db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

    log =
      capture_log(fn ->
        send(pid, :detect_misses)
        :sys.get_state(pid)
      end)

    assert log =~ "wake scheduler miss wake=#{source.wake_id} kind=prompt late_ms="
    assert Wakes.health(pid) == %{misses: 1}

    response =
      Tightbeam.Wire.Router.call(
        Plug.Test.conn(:get, "/version"),
        Tightbeam.Wire.Router.init(db: ctx.db, wake_scheduler: pid)
      )

    assert JSON.decode!(response.resp_body)["wakeScheduler"] == %{"misses" => 1}

    assert {:ok, [[seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
               source.wake_id
             ])

    assert is_integer(seq)
    send(pid, :detect_misses)
    :sys.get_state(pid)
    assert Wakes.health(pid) == %{misses: 1}
  end
end
