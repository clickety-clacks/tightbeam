defmodule Tightbeam.RateLimitReleaseTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    HarnessHealth,
    HarnessProcess,
    LaneManager,
    Ledger,
    Org,
    RateLimitReset,
    Wakes
  }

  alias Tightbeam.DB.Txn

  @key {:claude, "shared", "testhost"}
  @past DateTime.to_unix(~U[2025-08-14 23:00:00Z], :millisecond)
  @past_reset DateTime.to_unix(~U[2025-08-15 00:00:00Z], :millisecond)
  @error %{
    "code" => -32_603,
    "data" => %{"errorKind" => "rate_limit"},
    "message" => "Internal error: You've hit your weekly limit · resets Aug 15, 12am (UTC)"
  }

  setup do
    db = :"reset_release_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    ensure_main_session(db, "tester")

    for key <- ["k1", "k2"] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "tester",
        origin: "user:tester",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Tightbeam.Model.new("claude-sonnet-5")
      })
    end

    %{db: db}
  end

  test "terminal failure persists the stated reset before the shared incident opens", %{db: db} do
    before_failure = System.system_time(:millisecond)
    error = reset_error(before_failure + 3_600_000)
    fail_turn(db, "k1", error)
    refute HarnessProcess.parked?(db, @key)

    assert {:ok, [[first, due_at, nil]]} =
             DB.query(db, """
             SELECT w.wakeId,w.dueAt,o.incidentId FROM wakes w
             JOIN harness_health_observations o ON o.id=w.prompt
             WHERE w.consumer='rate_limit_reset'
             """)

    assert due_at == RateLimitReset.from_error(error, before_failure)
    fail_turn(db, "k2", error)
    assert HarnessProcess.parked?(db, @key)

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE consumer='rate_limit_reset'")

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harness_health_observations WHERE incidentId IS NOT NULL"
             )

    assert {:ok, {:deferred, :before_reset}} = RateLimitReset.release(db, %{wake_id: first})
    assert HarnessProcess.parked?(db, @key)
  end

  test "an overdue reset recovered on scheduler boot releases queued lanes without claiming success",
       %{db: db} do
    {incident, wake} = observe_reset(db, "old-limit", @error, @past)
    assert wake.due_at == @past_reset
    assert HarnessProcess.parked?(db, @key)
    parent = self()
    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})
    task_sup = start_supervised!({Task.Supervisor, []})
    lane_sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    manager =
      start_supervised!(
        {LaneManager,
         db: db,
         lane_sup: lane_sup,
         task_sup: task_sup,
         name: Tightbeam.LaneManager,
         runner: fn turn ->
           send(parent, {:started, turn.seq, self()})

           receive do
             :finish -> {:ok, %{text: "done"}}
           end
         end}
      )

    seqs =
      for key <- ["k1", "k2"] do
        seq = enqueue(db, key)
        :ok = LaneManager.ensure_lane(manager, key)
        [{lane, _}] = Registry.lookup(Tightbeam.LaneRegistry, key)
        :sys.get_state(lane)
        assert {:ok, [["queued"]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [seq])
        seq
      end

    start_supervised!(
      {Wakes,
       db: db,
       name: Tightbeam.WakeScheduler,
       deliver: fn _ -> :retry end,
       internal_consumers: %{"rate_limit_reset" => &RateLimitReset.release(db, &1)}}
    )

    started =
      for _ <- seqs do
        assert_receive {:started, seq, runner}, 5_000
        {seq, runner}
      end

    assert Enum.sort(Enum.map(started, &elem(&1, 0))) == Enum.sort(seqs)
    refute HarnessProcess.parked?(db, @key)
    assert HarnessHealth.get(db, incident.id).state == "open"

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harness_health_observations WHERE evidenceKind='normal-turn-success'"
             )

    assert {:ok, [["fired"]]} =
             DB.query(db, "SELECT state FROM wakes WHERE wakeId=?1", [wake.wake_id])

    assert {:ok, :already_consumed} = RateLimitReset.release(db, wake)
    Enum.each(started, fn {_, runner} -> send(runner, :finish) end)
  end

  @tag timeout: 70_000
  test "the scheduler releases at the stated reset without a poll or manual repair", %{db: db} do
    reset_at = (div(System.system_time(:millisecond), 60_000) + 1) * 60_000
    error = reset_error(reset_at)
    fail_turn(db, "k1", error)
    fail_turn(db, "k2", error)
    assert HarnessProcess.parked?(db, @key)

    assert {:ok, [[^reset_at]]} =
             DB.query(db, "SELECT DISTINCT dueAt FROM wakes WHERE consumer='rate_limit_reset'")

    parent = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: Tightbeam.WakeScheduler,
       deliver: fn _ -> :retry end,
       internal_consumers: %{
         "rate_limit_reset" => fn wake ->
           result = RateLimitReset.release(db, wake)
           send(parent, {:released, System.system_time(:millisecond)})
           result
         end
       }}
    )

    assert_receive {:released, released_at}, 65_000
    assert released_at >= reset_at
    assert released_at - reset_at < 5_000
    refute HarnessProcess.parked?(db, @key)
  end

  test "an earlier reset cannot release a later stated limit in the same incident", %{db: db} do
    {incident, early} = observe_reset(db, "early", @error, @past)
    future_at = System.system_time(:millisecond)
    later_error = reset_error(future_at + 3_600_000)
    {same, later} = observe_reset(db, "later", later_error, future_at)
    assert same.id == incident.id
    assert later.due_at > future_at
    assert {:ok, :ok} = RateLimitReset.release(db, early)
    assert HarnessProcess.parked?(db, @key)

    assert {:ok, [["pending"]]} =
             DB.query(db, "SELECT state FROM wakes WHERE wakeId=?1", [later.wake_id])
  end

  test "a stale reset from a resolved incident cannot release a new hold", %{db: db} do
    {incident, old} = observe_reset(db, "old", @error, @past)

    assert {:resolved, _} =
             HarnessHealth.resolve(db, %{
               correlation_id: "success",
               harness: "claude",
               host: "testhost",
               failure_class: "rate-limit-dead",
               session_key: "k1",
               assignment_id: nil,
               observed_at: @past + 1,
               cause: "normal turn delivered",
               principal: "process:test"
             })

    {new, _} = observe_reset(db, "new", @error, @past + 2)
    refute new.id == incident.id
    assert {:ok, :ok} = RateLimitReset.release(db, old)
    assert HarnessProcess.parked?(db, @key)
  end

  test "retry limit rearms the open incident and duplicate observation does not rearm a consumed reset",
       %{db: db} do
    {incident, wake} = observe_reset(db, "first", @error, @past)
    assert {:ok, :ok} = RateLimitReset.release(db, wake)
    refute HarnessProcess.parked?(db, @key)
    {same, ^wake} = observe_reset(db, "first", @error, @past)
    assert same.id == incident.id
    refute HarnessProcess.parked?(db, @key)
    {same, retry} = observe_reset(db, "retry", @error, @past + 1)
    assert same.id == incident.id
    assert HarnessProcess.parked?(db, @key)
    assert {:ok, :ok} = RateLimitReset.release(db, retry)
    refute HarnessProcess.parked?(db, @key)
  end

  test "a typed error without a reset retains the hold without inventing a deadline", %{db: db} do
    error = %{@error | "message" => "Rate limit exceeded"}
    fail_turn(db, "k1", error)
    fail_turn(db, "k2", error)
    assert HarnessProcess.parked?(db, @key)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE consumer='rate_limit_reset'")
  end

  defp reset_error(reset_at) do
    reset = DateTime.from_unix!(reset_at, :millisecond)
    hour = rem(reset.hour + 11, 12) + 1
    period = if reset.hour < 12, do: "am", else: "pm"
    minute = reset.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    %{@error | "message" => "Limit reached · resets #{hour}:#{minute}#{period} UTC"}
  end

  defp observe_reset(db, correlation, reason, at) do
    assert {:ok, {incident, wake}} =
             DB.transaction(db, fn txn ->
               result =
                 HarnessHealth.observe_in_txn(txn, %{
                   correlation_id: correlation,
                   harness: "claude",
                   host: "testhost",
                   failure_class: "rate-limit-dead",
                   evidence_kind: "authoritative-provider",
                   session_key: "k1",
                   assignment_id: nil,
                   observed_at: at,
                   cause: reason["message"],
                   principal: "process:test"
                 })

               {_, incident} = result

               RateLimitReset.schedule_in_txn(
                 txn,
                 %{harness: :claude, host: "testhost", session_key: "k1"},
                 result,
                 reason,
                 at
               )

               [[id, due_at]] =
                 Txn.q(
                   txn,
                   "SELECT wakeId,dueAt FROM wakes WHERE consumer='rate_limit_reset' AND prompt=?1",
                   [incident.observationId]
                 )

               {incident, %{wake_id: id, due_at: due_at}}
             end)

    {incident, wake}
  end

  defp enqueue(db, key) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: key,
        message_id: "message-#{System.unique_integer([:positive])}",
        origin: "user:tester",
        prompt: "queued work"
      })

    seq
  end

  defp fail_turn(db, key, reason) do
    seq = enqueue(db, key)
    {:ok, turn} = Ledger.claim_next(db, key, "test-owner")
    session = Org.get(db, key)

    {:ok, _} =
      DB.transaction(db, fn txn ->
        assert Ledger.finish_in_txn(txn, seq, "failed", reason["message"],
                 owner_lease: turn.owner_lease
               )

        HarnessHealth.observe_turn_failure_in_txn(
          txn,
          session,
          Map.put(turn, :session_key, key),
          :prompt,
          reason
        )
      end)
  end
end
