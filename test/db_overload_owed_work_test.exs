defmodule Tightbeam.DBOverloadOwedWorkTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{
    AdapterCoordinator,
    DB,
    EventLog,
    LaneManager,
    Ledger,
    ListenerLifecycle,
    Schema,
    SessionLane
  }

  defmodule HealthPlug do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  @fake_harness ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  setup do
    db = :"overload_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    for index <- 1..8 do
      :ok =
        DB.execute(db, """
        INSERT INTO sessions
          (sessionKey,displayName,ownerUserId,origin,spawnedBy,archetype,
           harness,provider,model,thinkingLevel,host,createdAt,updatedAt)
        VALUES
          ('k#{index}','K#{index}','t','user:t','k1','default','claude','anthropic',
           'claude-sonnet-5','medium','testhost',#{index},#{index});
        """)
    end

    on_exit(fn ->
      case Process.whereis(db) do
        pid when is_pid(pid) -> :sys.resume(pid)
        _ -> :ok
      end
    end)

    %{db: db}
  end

  # Hold the owner still with its queue at the fixed limit: every new call is
  # refused exactly as it is when the owner is busy behind a slow transaction.
  defp overload!(db) do
    owner = Process.whereis(db)
    :sys.suspend(owner)

    for _ <- 1..128,
        do: send(owner, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})

    assert DB.overloaded?(db)
    owner
  end

  defp relieve!(db), do: :sys.resume(Process.whereis(db))

  defp enqueue!(db, session_key, prompt) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "m_#{System.unique_integer([:positive])}",
        origin: "user:t",
        prompt: prompt
      })

    seq
  end

  defp status(db, seq) do
    {:ok, [[status]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [seq])
    status
  end

  defp eventually(fun, tries \\ 400) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  defp start_lane_parts do
    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})

    task_sup =
      start_supervised!({Task.Supervisor, name: :"tsup_#{System.unique_integer([:positive])}"})

    lane_sup =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: :"lsup_#{System.unique_integer([:positive])}"}
      )

    %{task_sup: task_sup, lane_sup: lane_sup}
  end

  defp start_lane(db, parts, session_key, runner) do
    {:ok, lane} =
      DynamicSupervisor.start_child(
        parts.lane_sup,
        {SessionLane, session_key: session_key, db: db, task_sup: parts.task_sup, runner: runner}
      )

    lane
  end

  describe "the owed-work scope" do
    test "waits out a refused call and sends it once the queue has room", %{db: db} do
      overload!(db)
      test = self()

      log =
        capture_log(fn ->
          waiter =
            Task.async(fn ->
              DB.owed_work(fn ->
                send(test, :asking)

                DB.transaction(db, fn txn ->
                  DB.Txn.q(txn, "SELECT 41 + 1")
                end)
              end)
            end)

          assert_receive :asking
          # Nothing was sent: the owner's queue is exactly as full as before.
          assert Task.yield(waiter, 300) == nil
          assert {:message_queue_len, 128} = Process.info(Process.whereis(db), :message_queue_len)

          relieve!(db)
          assert {:ok, [[42]]} = Task.await(waiter, 5_000)
        end)

      assert log =~ "database overloaded; owed work is waiting to send db.transaction"
    end

    test "leaves every other caller, and every deadline call, refused", %{db: db} do
      overload!(db)

      assert {:error, %DB.Overloaded{}} = DB.transaction(db, fn _ -> flunk("must not run") end)

      # The scope ends with the function that opened it.
      assert :done = DB.owed_work(fn -> :done end)
      assert {:error, %DB.Overloaded{}} = DB.transaction(db, fn _ -> flunk("must not run") end)

      deadline = System.monotonic_time(:millisecond) + 2_000

      assert {:error, %DB.Overloaded{}} =
               DB.owed_work(fn ->
                 DB.transaction_until(db, fn _ -> flunk("must not run") end, deadline)
               end)
    end

    test "does not resend a call whose own work reported the overload", %{db: db} do
      ran = :counters.new(1, [])

      assert {:error, %DB.Overloaded{}} =
               DB.owed_work(fn ->
                 DB.transaction(db, fn _txn ->
                   :counters.add(ran, 1, 1)
                   raise DB.Overloaded
                 end)
               end)

      assert :counters.get(ran, 1) == 1
    end
  end

  describe "a session lane" do
    test "nudged while the owner is overloaded keeps running and then starts the turn",
         %{db: db} do
      parts = start_lane_parts()
      seq = enqueue!(db, "k1", "hello")
      overload!(db)

      capture_log(fn ->
        lane = start_lane(db, parts, "k1", fn turn -> {:ok, %{text: turn.prompt}} end)
        ref = Process.monitor(lane)

        # The lane's first act is to claim. On an overloaded owner that used to
        # be a MatchError, an immediate restart, and the same crash again.
        refute_receive {:DOWN, ^ref, :process, _, _}, 300
        assert Process.alive?(parts.lane_sup)
        assert [{^lane, _}] = Registry.lookup(Tightbeam.LaneRegistry, "k1")

        relieve!(db)
        assert eventually(fn -> status(db, seq) == "delivered" end)
        assert [{^lane, _}] = Registry.lookup(Tightbeam.LaneRegistry, "k1")
      end)
    end

    test "records a turn that finishes during the overload once the overload passes",
         %{db: db} do
      parts = start_lane_parts()
      seq = enqueue!(db, "k1", "hello")
      test = self()

      runner = fn turn ->
        send(test, {:running, self()})

        receive do
          :finish -> {:ok, %{text: turn.prompt}}
        end
      end

      capture_log(fn ->
        lane = start_lane(db, parts, "k1", runner)
        ref = Process.monitor(lane)
        assert_receive {:running, task}, 2_000
        assert status(db, seq) == "running"

        overload!(db)
        send(task, :finish)

        refute_receive {:DOWN, ^ref, :process, _, _}, 300
        relieve!(db)

        assert eventually(fn -> status(db, seq) == "delivered" end)
        assert [{^lane, _}] = Registry.lookup(Tightbeam.LaneRegistry, "k1")
      end)
    end

    test "does not fail a turn whose own database call meets the overload", %{db: db} do
      parts = start_lane_parts()
      seq = enqueue!(db, "k1", "hello")
      test = self()

      runner = fn turn ->
        send(test, {:running, self()})

        receive do
          :write -> :ok
        end

        {:ok, [[1]]} = DB.transaction(db, fn txn -> DB.Txn.q(txn, "SELECT 1") end)
        {:ok, %{text: turn.prompt}}
      end

      capture_log(fn ->
        start_lane(db, parts, "k1", runner)
        assert_receive {:running, task}, 2_000

        overload!(db)
        send(task, :write)
        Process.sleep(200)
        assert Process.alive?(task)

        relieve!(db)
        assert eventually(fn -> status(db, seq) == "delivered" end)
      end)
    end
  end

  describe "a request the lane serves for a caller" do
    test "still gets the refusal: a cancel during the overload answers at once", %{db: db} do
      parts = start_lane_parts()
      seq = enqueue!(db, "k1", "hello")
      test = self()

      runner = fn turn ->
        send(test, {:running, self()})

        receive do
          :finish -> {:ok, %{text: turn.prompt}}
        end
      end

      capture_log(fn ->
        start_lane(db, parts, "k1", runner)
        assert_receive {:running, task}, 2_000

        overload!(db)
        assert {:error, %DB.Overloaded{}} = SessionLane.cancel_current("k1")
        assert Process.alive?(task)

        relieve!(db)
        send(task, :finish)
        assert eventually(fn -> status(db, seq) == "delivered" end)
      end)
    end
  end

  describe "the adapter coordinator" do
    @tag :tmp_dir
    test "survives an adapter death during the overload and records it afterwards",
         %{db: db, tmp_dir: tmp} do
      path = Path.join(tmp, "fake_harness.js")
      File.write!(path, @fake_harness)

      adapter_sup =
        start_supervised!(
          {DynamicSupervisor,
           strategy: :one_for_one, name: :"asup_#{System.unique_integer([:positive])}"}
        )

      coordinator =
        start_supervised!(
          {AdapterCoordinator,
           adapter_sup: adapter_sup,
           adapter_context: fn _ -> [] end,
           adapter_opts: fn _, _ ->
             [harness: :claude, cmd: [System.find_executable("node"), path], home: tmp, cwd: tmp]
           end,
           db: db,
           name: :"coordinator_#{System.unique_integer([:positive])}"}
        )

      key = {:claude, "default", "testhost"}
      assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
      ref = Process.monitor(coordinator)

      capture_log(fn ->
        overload!(db)
        Process.exit(adapter, :kill)

        # Recording the death needs the database. The coordinator used to crash
        # on the refusal, and its shutdown took every other adapter with it.
        refute_receive {:DOWN, ^ref, :process, _, _}, 300

        relieve!(db)

        assert eventually(fn ->
                 coordinator |> :sys.get_state() |> get_in([:adapters, key, :generation]) == 2
               end)

        assert [%{kind: "adapter_down", subject: "claude:default@testhost"}] =
                 EventLog.lifecycle_events(db)

        refute_received {:DOWN, ^ref, :process, _, _}
      end)
    end
  end

  test "Harklight attachment keeps its existing worker-owned refusal retry", %{db: db} do
    manager = start_supervised!({Tightbeam.HarklightWakes, db: db})
    worker = self()
    :sys.get_state(manager)
    :sys.replace_state(manager, fn state -> %{state | workers: %{"attachment" => worker}} end)
    overload!(db)

    try do
      assert {:error, "attachment_state_unavailable"} =
               GenServer.call(manager, {:attached, "attachment"}, 500)

      assert MapSet.new() == GenServer.call(manager, {:unlistened_handles, []}, 500)
    after
      relieve!(db)
      :sys.replace_state(manager, fn state -> %{state | workers: %{}} end)
    end
  end

  describe "the full application runtime" do
    @tag :tmp_dir
    @tag timeout: 120_000
    test "retains every runtime child and delivers a deferred wake once", %{tmp_dir: tmp} do
      fixture = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "full_runtime_overload.exs")

      {output, status} =
        System.cmd(fixture.executable, fixture.args,
          env: [{"MIX_ENV", "test"} | fixture.env],
          stderr_to_stdout: true
        )

      File.write!(Path.join(tmp, "runtime.log"), output)
      assert status == 0, output
      assert output =~ "full-runtime-overload: listener survived; durable wake delivered once"
      assert output =~ "full-runtime-overload: startup recovery waits without restart cascade"
    end
  end

  describe "the process tree" do
    test "keeps its listener, lanes and supervisors through an overload burst", %{db: db} do
      # The production shape: lanes sit under their own supervisor ahead of the
      # runtime services, in one rest-for-one root, with production's limits.
      lane_supervisor =
        Enum.find(
          Tightbeam.Application.children(%{base_dir: "unused"}),
          &match?({DynamicSupervisor, _}, &1)
        )

      {DynamicSupervisor, lane_opts} = lane_supervisor
      assert lane_opts[:name] == Tightbeam.LaneSupervisor
      task_sup = :"tsup_#{System.unique_integer([:positive])}"
      manager = :"manager_#{System.unique_integer([:positive])}"

      runtime = [
        {LaneManager,
         db: db,
         lane_sup: Tightbeam.LaneSupervisor,
         task_sup: task_sup,
         runner: fn turn -> {:ok, %{text: turn.prompt}} end,
         interval: 3_600_000,
         name: manager},
        ListenerLifecycle.listener_spec(
          plug: {HealthPlug, %{}},
          port: 0,
          ip: {127, 0, 0, 1},
          startup_log: false
        )
      ]

      root =
        start_supervised!(%{
          id: :overload_root,
          start:
            {Supervisor, :start_link,
             [
               [
                 {Registry, keys: :unique, name: Tightbeam.LaneRegistry},
                 {Task.Supervisor, name: task_sup},
                 lane_supervisor,
                 Tightbeam.Application.runtime_child(runtime)
               ],
               Keyword.delete(Tightbeam.Application.root_opts(), :name)
             ]}
        })

      pids = fn ->
        runtime_sup = Process.whereis(Tightbeam.RuntimeSupervisor)

        listener =
          Enum.find_value(Supervisor.which_children(runtime_sup), fn
            {{Bandit, _ref}, pid, _, _} -> pid
            {Bandit, pid, _, _} -> pid
            _ -> nil
          end)

        %{
          root: root,
          lanes: Process.whereis(Tightbeam.LaneSupervisor),
          runtime: runtime_sup,
          manager: Process.whereis(manager),
          listener: listener
        }
      end

      before = pids.()
      {:ok, {_address, port}} = ThousandIsland.listener_info(before.listener)
      assert http_status(port) == "200"

      seqs = for index <- 1..8, do: enqueue!(db, "k#{index}", "burst #{index}")
      overload!(db)

      capture_log(fn ->
        # Every session's lane is started and rung while the owner refuses work.
        for index <- 1..8, do: GenServer.cast(manager, {:ensure_lane, "k#{index}"})

        for _ <- 1..10 do
          assert http_status(port) == "200"
          Process.sleep(50)
        end

        assert pids.() == before
        assert Enum.all?(Map.values(before), &Process.alive?/1)
        assert %{active: 8} = DynamicSupervisor.count_children(Tightbeam.LaneSupervisor)

        relieve!(db)
        assert eventually(fn -> Enum.all?(seqs, &(status(db, &1) == "delivered")) end)
      end)

      assert pids.() == before
      assert http_status(port) == "200"
    end
  end

  defp http_status(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :ok =
          :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

        status =
          case :gen_tcp.recv(socket, 0, 2_000) do
            {:ok, <<"HTTP/1.1 ", status::binary-size(3), _::binary>>} -> status
            other -> inspect(other)
          end

        :gen_tcp.close(socket)
        status

      {:error, reason} ->
        "connect:" <> inspect(reason)
    end
  end
end
