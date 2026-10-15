defmodule Tightbeam.EventDrivenSchedulerTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog
  alias Tightbeam.{DB, Ledger, NoticeBatcher, Wakes}

  defmodule OverloadedDeliveryDB do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:transaction_then, _prepare, _commit}, _from, {_db, parent} = state) do
      send(parent, :delivery_overloaded)
      {:reply, {:error, %DB.Overloaded{}}, state}
    end

    def handle_call(request, _from, {db, _parent} = state) do
      {:reply, GenServer.call(db, request), state}
    end
  end

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

    %{
      misses_before: Tightbeam.SchedulerMisses.count(),
      db: db,
      delivery_opts: [conn_registry: registry, lane_manager: lane_name]
    }
  end

  defp scheduler(ctx, extra \\ []) do
    parent = self()

    start_supervised!(
      {Wakes,
       Keyword.merge(
         [
           db: ctx.db,
           name: Tightbeam.WakeScheduler,
           deliver: fn wake ->
             send(parent, {:delivered, wake.wake_id, System.system_time(:millisecond)})
           end,
           internal_consumers: %{
             "test" => fn wake ->
               send(parent, {:delivered, wake.wake_id, System.system_time(:millisecond)})
             end
           },
           delivery_opts: ctx.delivery_opts
         ],
         extra
       )}
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

  test "condition delivery overload defers the pass without advancing either cursor", ctx do
    pending = wake(ctx.db, 1, %{condition_kind: "ready", condition_after_id: 0})

    assert {:ok, [[fact_id]]} =
             DB.query(
               ctx.db,
               "INSERT INTO condition_facts(ts,kind,origin) VALUES (1,'ready','system') RETURNING id"
             )

    assert {:ok, [[before_fact]]} = DB.query(ctx.db, "SELECT afterFact FROM scheduler_state")
    assert fact_id > before_fact
    proxy = start_supervised!({OverloadedDeliveryDB, {ctx.db, self()}})
    timer = make_ref()

    state = %{
      db: proxy,
      timer: timer,
      deadline: nil,
      retries: %{},
      retry_attempts: %{},
      scanned_through: -1,
      internal_consumers: %{},
      deliver: fn _ -> flunk("delivery must not run") end,
      delivery_opts: ctx.delivery_opts,
      batch: 100
    }

    assert {:noreply, next} = Wakes.handle_info({:timeout, timer, :due}, state)
    assert_received :delivery_overloaded
    assert next.scanned_through == state.scanned_through
    assert next.retries[:pass] > System.system_time(:millisecond)
    assert :erlang.read_timer(next.timer) >= 900
    :erlang.cancel_timer(next.timer)
    assert {:ok, [[^before_fact]]} = DB.query(ctx.db, "SELECT afterFact FROM scheduler_state")
    assert Wakes.get(ctx.db, pending.wake_id).state == "pending"
    assert Wakes.get(ctx.db, pending.wake_id).fired_at == nil
  end

  for column <- ~w(predicate recognitionEvidence recognitionTransition) do
    test "malformed #{column} defers one internal wake while other wakes deliver", ctx do
      bad = wake(ctx.db, 1, %{consumer: "test"})
      good = wake(ctx.db, 2, %{consumer: "test"})
      column = unquote(column)

      assert {:ok, _} =
               DB.query(ctx.db, "UPDATE wakes SET #{column}='{' WHERE wakeId=?1", [bad.wake_id])

      log =
        capture_log(fn ->
          pid = scheduler(ctx)
          assert :ok = Wakes.fire_due(pid)
          assert_receive {:delivered, id, _}, 1_000
          assert id == good.wake_id
          assert Process.alive?(pid)
          assert :ok = Wakes.fire_due(pid)
        end)

      assert length(Regex.scan(~r/#{bad.wake_id}/, log)) == 1
      assert log =~ "deferred"

      assert {:ok, [["pending", "{"]]} =
               DB.query(ctx.db, "SELECT state,#{column} FROM wakes WHERE wakeId=?1", [bad.wake_id])
    end
  end

  for {column, value} <- [
        {"conditionKind", ""},
        {"conditionAfterId", nil},
        {"recognitionEvidence", "{"}
      ] do
    test "bad condition #{column} does not stop fallback candidates or ordinary delivery", ctx do
      bad = wake(ctx.db, 1, %{condition_kind: "ready", condition_after_id: 0})
      sibling = wake(ctx.db, 2, %{condition_kind: "other-ready", condition_after_id: 0})
      good = wake(ctx.db, 3, %{consumer: "test"})

      assert {:ok, [[fact_id]]} =
               DB.query(
                 ctx.db,
                 "INSERT INTO condition_facts(ts,kind,origin) VALUES (1,'unrelated','system') RETURNING id"
               )

      column = unquote(column)

      assert {:ok, _} =
               DB.query(ctx.db, "UPDATE wakes SET #{column}=?2 WHERE wakeId=?1", [
                 bad.wake_id,
                 unquote(value)
               ])

      log =
        capture_log(fn ->
          pid = scheduler(ctx)
          assert :ok = Wakes.fire_due(pid)
          assert_receive {:delivered, id, _}, 1_000
          assert id == good.wake_id
          assert Process.alive?(pid)
        end)

      assert log =~ bad.wake_id

      assert {:ok, [["pending", nil]]} =
               DB.query(ctx.db, "SELECT state,firedAt FROM wakes WHERE wakeId=?1", [bad.wake_id])

      assert {:ok, [[after_fact]]} = DB.query(ctx.db, "SELECT afterFact FROM scheduler_state")
      assert after_fact == fact_id
      assert Wakes.get(ctx.db, sibling.wake_id).fired_at != nil
    end
  end

  test "malformed remedy source does not stop wake delivery", ctx do
    bad = wake(ctx.db, 1, %{origin: "remedy:broken"})
    good = wake(ctx.db, 2, %{consumer: "test"})

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET recognitionTransition='{' WHERE wakeId=?1", [
               bad.wake_id
             ])

    log =
      capture_log(fn ->
        assert :ok = Wakes.dispose_closed_remedy_sources(ctx.db)
        pid = scheduler(ctx)
        assert :ok = Wakes.fire_due(pid)
        assert_receive {:delivered, id, _}, 1_000
        assert id == good.wake_id
        assert Process.alive?(pid)
      end)

    assert log =~ bad.wake_id
    assert log =~ "cleanup deferred"
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

               Wakes.schedule_changed_in_txn(txn, {:schedule_changed, due})
             end)

    assert_receive {:delivered, id, fired_at}, 1_250
    assert id == scheduled.wake_id
    assert fired_at >= due and fired_at - due < 1_000
    assert Process.alive?(pid)
  end

  test "a restored prewrite successor fires on time without the miss detector", ctx do
    source = wake(ctx.db, System.system_time(:millisecond) - 100)

    [_carrier] =
      NoticeBatcher.recover(ctx.db, System.system_time(:millisecond), ctx.delivery_opts)

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "recipient", "testhost")
    pid = scheduler(ctx)
    # Let startup recovery and the one-time backfill finish before inserting.
    Process.sleep(300)
    assert :sys.get_state(pid).timer == nil

    evidence =
      Tightbeam.NoticeSubmission.prewrite_evidence(
        :prompt,
        {:acp_request_not_dispatched, {:transport_capacity_exceeded, 201, 200}}
      )

    assert {:ok, [successor]} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", "prewrite refusal",
                        owner_lease: turn.owner_lease,
                        prewrite_evidence: evidence
                      )

               Tightbeam.NoticeSubmission.restore_in_txn(txn, turn, evidence)
             end)

    due = Wakes.get(ctx.db, successor).due_at
    assert :sys.get_state(pid).deadline == due
    Process.sleep(1_500)

    assert [%{delivery_wake_id: carrier, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, successor)

    assert {:ok, [[delivered_at]]} =
             DB.query(ctx.db, "SELECT createdAt FROM turns WHERE wakeId=?1", [
               carrier
             ])

    assert delivered_at >= due and delivered_at - due < 1_000
    assert Wakes.get(ctx.db, successor).state == "fired"
    assert Wakes.get(ctx.db, source.wake_id).state == "fired"
    assert Tightbeam.SchedulerMisses.count() == ctx.misses_before
  end

  test "distant deadlines keep one timer without overflowing a relative timeout", ctx do
    pid = scheduler(ctx)

    scheduled =
      wake(ctx.db, System.system_time(:millisecond) + 60 * 86_400_000, %{consumer: "test"})

    assert is_reference(:sys.get_state(pid).timer)
    assert Wakes.get(ctx.db, scheduled.wake_id).state == "pending"
    refute_receive {:delivered, _, _}, 100
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
    assert Tightbeam.SchedulerMisses.count() - ctx.misses_before == 0
  end

  test "recipient readiness cancels a deadline satisfied by an early recognized notice", ctx do
    pid = scheduler(ctx)
    source = wake(ctx.db, System.system_time(:millisecond) + 60_000)
    assert is_reference(:sys.get_state(pid).timer)

    assert {:ok, {:ok, _}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.prepare_prompt_source_for_batch_in_txn(
                 txn,
                 source.wake_id,
                 "recipient",
                 source.prompt
               )
             end)

    Wakes.recipient_ready(pid, "recipient")
    assert :sys.get_state(pid).timer == nil

    assert {:ok, [[seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
               source.wake_id
             ])

    assert is_integer(seq)
  end

  test "a deleted role is reported at its deadline while the former recipient is busy", ctx do
    busy(ctx.db)
    Tightbeam.Roles.create!(ctx.db, "reviewer", "owner", "recipient")
    pid = scheduler(ctx)
    source = wake(ctx.db, System.system_time(:millisecond) + 250, %{target_role: "reviewer"})
    :ok = Tightbeam.Roles.rm(ctx.db, "reviewer")

    deadline = System.monotonic_time(:millisecond) + 5_000
    assert await_fired(ctx.db, source.wake_id, deadline)
    assert NoticeBatcher.source_refs(ctx.db, source.wake_id) == []
    assert :ok = Wakes.fire_due(pid)

    assert Enum.count(Tightbeam.EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "wake_unresolved" and event.subject == source.wake_id and
               event.detail == "role reviewer no longer exists"
           end) == 1

    assert Tightbeam.SchedulerMisses.count() == ctx.misses_before
  end

  defp await_fired(db, id, deadline) do
    cond do
      Wakes.get(db, id).state == "fired" ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        await_fired(db, id, deadline)
    end
  end

  test "the detector ignores busy recipients then delivers and logs a suppressed readiness signal",
       ctx do
    turn = busy(ctx.db)
    pid = scheduler(ctx)
    source = wake(ctx.db, System.system_time(:millisecond) - 61_000)
    :ok = Wakes.fire_due(pid)
    send(pid, :detect_misses)
    :sys.get_state(pid)
    assert Tightbeam.SchedulerMisses.count() - ctx.misses_before == 0
    assert NoticeBatcher.source_refs(ctx.db, source.wake_id) == []
    :ok = Ledger.finish(ctx.db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

    log =
      capture_log(fn ->
        send(pid, :detect_misses)
        :sys.get_state(pid)
      end)

    assert log =~ "wake scheduler miss wake=#{source.wake_id} kind=prompt late_ms="
    assert Tightbeam.SchedulerMisses.count() - ctx.misses_before == 1

    response =
      Tightbeam.Wire.Router.call(
        Plug.Test.conn(:get, "/version"),
        Tightbeam.Wire.Router.init(db: ctx.db, wake_scheduler: pid)
      )

    assert JSON.decode!(response.resp_body)["schedulerMisses"] - ctx.misses_before == 1

    assert {:ok, [[seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
               source.wake_id
             ])

    assert is_integer(seq)
    send(pid, :detect_misses)
    :sys.get_state(pid)
    assert Tightbeam.SchedulerMisses.count() - ctx.misses_before == 1
    assert :sys.get_state(pid).detected_misses == MapSet.new()
  end

  test "failed internal deliveries back off and succeed without another write", ctx do
    parent = self()
    attempts = :ets.new(:retry_attempts, [:public])
    :ets.insert(attempts, {:count, 0})

    consumer = fn wake ->
      n = :ets.update_counter(attempts, :count, 1)
      send(parent, {:attempt, n, System.system_time(:millisecond)})
      if n < 3, do: raise("transient failure")
      {:ok, _} = DB.transaction(ctx.db, &Wakes.consume_internal_in_txn(&1, wake.wake_id))
    end

    pid = scheduler(ctx, internal_consumers: %{"effort_probe" => consumer})
    scheduled = wake(ctx.db, System.system_time(:millisecond), %{consumer: "effort_probe"})
    assert_receive {:attempt, 1, first}, 5_000
    assert_receive {:attempt, 2, second}, 5_000
    assert second - first >= 1_000
    assert_receive {:attempt, 3, third}, 7_000
    assert third - second >= 2_000
    :sys.get_state(pid)
    assert Wakes.get(ctx.db, scheduled.wake_id).state == "fired"
    assert :sys.get_state(pid).retries == %{}
  end

  test "internal retries cap at five minutes and respect rescheduled deadlines", ctx do
    parent = self()

    pid =
      scheduler(ctx,
        internal_consumers: %{
          "effort_deadline" => fn _ ->
            send(parent, :attempted)
            raise "temporary"
          end
        }
      )

    scheduled = wake(ctx.db, System.system_time(:millisecond), %{consumer: "effort_deadline"})
    assert_receive :attempted, 1_000
    :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      %{state | retries: %{scheduled.wake_id => 0}, retry_attempts: %{scheduled.wake_id => 20}}
    end)

    before = System.system_time(:millisecond)
    Wakes.fire_due(pid)
    assert_receive :attempted
    next = :sys.get_state(pid).retries[scheduled.wake_id]
    assert next >= before + 300_000
    assert next <= System.system_time(:millisecond) + 300_000
    refute_receive :attempted, 100

    later = System.system_time(:millisecond) + 60_000

    {:ok, :ok} =
      DB.transaction(ctx.db, fn txn ->
        DB.Txn.q(txn, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [scheduled.wake_id, later])
        Wakes.schedule_changed_in_txn(txn, {:schedule_changed, later})
      end)

    Wakes.fire_due(pid)
    state = :sys.get_state(pid)
    assert state.retries == %{}
    assert state.deadline == later
    refute_receive :attempted, 100
  end

  test "the detector excludes digests and waits that cannot deliver", ctx do
    pid = scheduler(ctx)
    Process.sleep(150)
    state = :sys.get_state(pid)
    stop_supervised!(Wakes)
    due = System.system_time(:millisecond) + 60_000
    digest = wake(ctx.db, due, %{digest: true})
    boundary = wake(ctx.db, due, %{delivery_rule: "turn-boundary-digest r1"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET deliveryRule=?2 WHERE wakeId=?1", [
        boundary.wake_id,
        "turn-boundary-digest r1"
      ])

    unrecognized = wake(ctx.db, due)
    after_turn = wake(ctx.db, due)

    {:ok, _} =
      DB.query(ctx.db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,
        provider,model,host,state,createdAt,updatedAt)
      VALUES ('originator','originator','owner','user:owner','default','claude',
        'anthropic','fable','testhost','active',1,1)
      """)

    {:ok, _} =
      Ledger.enqueue(ctx.db, %{
        session_key: "originator",
        message_id: "origin-turn",
        origin: "user:owner",
        prompt: "working"
      })

    {:ok, origin} = Ledger.claim_next(ctx.db, "originator", "testhost")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET waitMode='dependency' WHERE wakeId=?1", [
        unrecognized.wake_id
      ])

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE wakes SET waitMode='after-turn',recognitionAt=1,originatingTurnSeq=?2 WHERE wakeId=?1
        """,
        [after_turn.wake_id, origin.seq]
      )

    for wake <- [digest, boundary, unrecognized, after_turn] do
      {:ok, _} =
        DB.query(ctx.db, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [
          wake.wake_id,
          System.system_time(:millisecond) - 61_000
        ])
    end

    # Exercise the detector before any due pass recognizes dependency fallbacks.
    assert {:noreply, _} = Wakes.handle_info(:detect_misses, state)
    assert Tightbeam.SchedulerMisses.count() - ctx.misses_before == 0
  end

  test "later schedule storms retain the deadline and coalesce delivery passes", ctx do
    pid = scheduler(ctx)
    first = System.system_time(:millisecond) + 60_000
    wake(ctx.db, first, %{consumer: "test"})
    original = :sys.get_state(pid)
    for _ <- 1..200, do: GenServer.cast(pid, {:schedule_changed, first + 60_000})
    state = :sys.get_state(pid)
    assert state.timer == original.timer
    assert state.scanned_through == original.scanned_through

    state = %{fire_pending: false}
    {:noreply, queued} = Wakes.handle_cast(:wake_ready, state)
    for _ <- 1..200, do: assert({:noreply, queued} == Wakes.handle_cast(:wake_ready, queued))
    assert_receive :fire_due
    refute_receive :fire_due
  end
end
