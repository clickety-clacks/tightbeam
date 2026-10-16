defmodule Tightbeam.CronWakeTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{CronWake, DB, Gateway, Schema, Wakes}

  defmodule OverloadedDB do
    use GenServer
    def start_link(db), do: GenServer.start_link(__MODULE__, db)
    def init(db), do: {:ok, db}

    def handle_call({:transaction, _fun}, _from, db),
      do: {:reply, {:error, %DB.Overloaded{}}, db}

    def handle_call(request, _from, db), do: {:reply, GenServer.call(db, request), db}
  end

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = ensure_all_schemas(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,
        provider,model,host,state,createdAt,updatedAt)
      VALUES('recipient','recipient','owner','user:owner','default','claude',
        'anthropic','fable','testhost','active',1,1);
      """)

    registry = start_supervised!({Tightbeam.ConnRegistry, name: nil})
    lane = :"cron_lane_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane})
    %{db: db, delivery_opts: [conn_registry: registry, lane_manager: lane]}
  end

  defp schedule(db, extra \\ %{}) do
    Wakes.schedule(
      db,
      Map.merge(
        %{
          session_key: "recipient",
          origin: "process:clock",
          prompt: "check progress",
          cron: "*/30 * * * *",
          class: "status-query"
        },
        extra
      )
    )
  end

  defp assert_eventually(fun, attempts \\ 200)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp local_ms(date, time) do
    [utc | _] = :calendar.local_time_to_universal_time_dst({date, time})
    (:calendar.datetime_to_gregorian_seconds(utc) - 62_167_219_200) * 1000
  end

  test "R1.1 five-field cron supports half-hour, hourly, lists, ranges and steps" do
    at = local_ms({2026, 10, 16}, {10, 0, 0})
    assert CronWake.next_at("*/30 * * * *", at) == at + 30 * 60_000
    assert CronWake.next_at("0 * * * *", at) == at + 60 * 60_000
    assert CronWake.next_at("5,20-40/10 10-12 * * *", at) == at + 5 * 60_000

    assert CronWake.next_at("0 0 29 2 *", local_ms({2025, 3, 1}, {0, 0, 0})) ==
             local_ms({2028, 2, 29}, {0, 0, 0})

    assert CronWake.next_at("0 0 * * 0,7", local_ms({2026, 10, 16}, {0, 0, 0})) ==
             local_ms({2026, 10, 18}, {0, 0, 0})

    assert CronWake.next_at("0 0 17 * 0", local_ms({2026, 10, 16}, {0, 0, 0})) ==
             local_ms({2026, 10, 17}, {0, 0, 0})
  end

  test "R1.1 invalid and impossible schedules are rejected" do
    for invalid <- [
          nil,
          "",
          "* * * *",
          "60 * * * *",
          "*/0 * * * *",
          "9-1 * * * *",
          "x * * * *",
          "0 0 30 2 *"
        ] do
      refute CronWake.valid?(invalid)
    end
  end

  test "R1.1 wire and public wake handler accept cron and reject mixed triggers", %{db: db} do
    assert Tightbeam.Wire.Router.atomize_params_for_test("wake", %{"cron" => "0 * * * *"}) == %{
             cron: "0 * * * *"
           }

    handler = Gateway.handlers(%{db: db})["wake"]

    call = %{
      origin: "process:clock",
      principal: {:process, "clock"},
      session_key: "recipient",
      params: %{prompt: "check progress", cron: "0 * * * *"}
    }

    assert %{wake_id: id, state: "pending", class: "fyi"} = handler.(call)
    assert Wakes.get(db, id).due_at > System.system_time(:millisecond)

    for params <- [
          %{cron: "bad"},
          %{cron: "0 * * * *", at: 1},
          %{cron: "0 * * * *", after_ms: 1},
          %{cron: "0 * * * *", condition_kind: "done"},
          %{cron: "0 * * * *", after_turn: true},
          %{cron: "0 * * * *", predicate: %{}}
        ] do
      assert %{code: "invalid"} = handler.(%{call | params: Map.merge(call.params, params)})
    end
  end

  test "R1.2 repeated firings stay armed and enqueue distinct ordinary deliveries", ctx do
    wake = schedule(ctx.db)

    for _ <- 1..2 do
      {:ok, []} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake.wake_id])
      CronWake.fire_due(ctx.db, System.system_time(:millisecond))
      assert %{state: "pending", due_at: next} = Wakes.get(ctx.db, wake.wake_id)
      assert next > System.system_time(:millisecond)
      Tightbeam.NoticeBatcher.recover(ctx.db, System.system_time(:millisecond), ctx.delivery_opts)
      assert {:ok, turn} = Tightbeam.Ledger.claim_next(ctx.db, "recipient", "testhost")

      assert :ok =
               Tightbeam.Ledger.finish(ctx.db, turn.seq, "delivered", nil,
                 owner_lease: turn.owner_lease
               )
    end

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")

    assert {:ok, rows} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,prompt,class FROM wakes WHERE consumer='prompt' AND digest=0"
             )

    assert rows == List.duplicate(["recipient", "check progress", "status-query"], 2)
  end

  test "R1.2 recovery fires once without catching up missed slots", %{db: db} do
    wake = schedule(db, %{class: nil})
    {:ok, []} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake.wake_id])
    at = System.system_time(:millisecond)
    CronWake.fire_due(db, at)
    CronWake.fire_due(db, at)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM wakes WHERE consumer='prompt' AND digest=0")

    assert {:ok, [["fyi", "classifier"]]} =
             DB.query(
               db,
               "SELECT class,classElection FROM wakes WHERE consumer='prompt' AND digest=0"
             )

    assert Wakes.get(db, wake.wake_id).due_at == CronWake.next_at("*/30 * * * *", at)
  end

  test "R1.2 overload defers the scheduler pass and preserves the armed wake", %{db: db} do
    wake = schedule(db)
    {:ok, []} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake.wake_id])
    proxy = start_supervised!({OverloadedDB, db})
    at = System.system_time(:millisecond)
    assert :deferred == DB.background_pass(fn -> CronWake.fire_due(proxy, at) end, :deferred)
    assert Wakes.get(db, wake.wake_id).due_at == 0
    CronWake.fire_due(db, at)
    assert Wakes.get(db, wake.wake_id).due_at > at

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM wakes WHERE consumer='prompt' AND digest=0")
  end

  test "R1.3 existing scheduler timer delivers the firing with recipient prompt and class", ctx do
    wake = schedule(ctx.db)

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: Tightbeam.WakeScheduler,
         deliver: fn _ -> flunk("ordinary sources must use normal delivery") end,
         delivery_opts: ctx.delivery_opts}
      )

    # Move only the stored deadline forward to exercise the actual single timer.
    due = System.system_time(:millisecond) + 200
    {:ok, []} = DB.query(ctx.db, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [wake.wake_id, due])
    GenServer.cast(scheduler, {:schedule_changed, due})

    assert_eventually(fn ->
      {:ok, [[count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
      count == 1
    end)

    assert {:ok, [["recipient", content]]} =
             DB.query(ctx.db, "SELECT sessionKey,prompt FROM turns")

    assert content =~ "check progress"
    assert content =~ "status-query"
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert :sys.get_state(scheduler).deadline == Wakes.get(ctx.db, wake.wake_id).due_at
  end

  test "R1.4 existing cancel stops future firings before and after first firing", %{db: db} do
    handler = Gateway.handlers(%{db: db})["wake"]

    for fired? <- [false, true] do
      wake = schedule(db)
      {:ok, []} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake.wake_id])
      if fired?, do: CronWake.fire_due(db, System.system_time(:millisecond))

      result =
        handler.(%{
          origin: "process:clock",
          principal: {:process, "clock"},
          session_key: "recipient",
          params: %{cancel_wake_id: wake.wake_id}
        })

      assert result == %{canceled: true} or
               match?({:accepted_in_txn, _, %{canceled: true}}, result)

      assert Wakes.get(db, wake.wake_id).state == "canceled"
      {:ok, before} = DB.query(db, "SELECT * FROM wakes")
      CronWake.fire_due(db, System.system_time(:millisecond) + 86_400_000)
      assert {:ok, ^before} = DB.query(db, "SELECT * FROM wakes")
    end
  end

  test "R1.1 additive migration runs once on current schema and preserves schedules", %{db: db} do
    wake = schedule(db)
    assert {:ok, marker} = DB.query(db, "SELECT * FROM cron_wake_migration")
    assert :ok = Schema.ensure_all(db)
    assert {:ok, ^marker} = DB.query(db, "SELECT * FROM cron_wake_migration")

    assert {:ok, [["*/30 * * * *"]]} =
             DB.query(db, "SELECT schedule FROM cron_wake_schedules WHERE wakeId=?1", [
               wake.wake_id
             ])
  end

  test "R1.1 additive migration follows a captured predecessor upgrade" do
    db = start_supervised!({DB, path: ":memory:", name: nil}, id: :predecessor)
    :ok = DB.execute(db, File.read!(Path.join(__DIR__, "fixtures/o2_admission_v1.sql")))
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[0, at]]} = DB.query(db, "SELECT * FROM cron_wake_migration")
    assert is_integer(at)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[0, ^at]]} = DB.query(db, "SELECT * FROM cron_wake_migration")
  end
end
