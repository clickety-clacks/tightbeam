defmodule Tightbeam.AdapterCoordinatorTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, DB, EventLog}

  @fake ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  setup do
    db = :"coordinator_db_#{System.unique_integer([:positive])}"
    sup = :"adapter_sup_#{System.unique_integer([:positive])}"
    test_dir = Path.join(System.tmp_dir!(), "adapter-coordinator-#{test_nonce()}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    %{db: db, sup: sup, test_dir: test_dir}
  end

  test "five consecutive boot failures open the circuit (async boot)", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         backoff_base_ms: 1,
         adapter_opts: fn _ ->
           [harness: :claude, cmd: [System.find_executable("false")], home: "/tmp", cwd: "/tmp"]
         end,
         db: ctx.db,
         name: :"coord_#{System.unique_integer([:positive])}"}
      )

    # Async boot: the first checkout hands out a pid whose boot then fails;
    # crashes count via :DOWN on the (fast) backoff clock until the circuit
    # opens and checkout fails fast.
    assert {:ok, _pid, _gen} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    # MEASURED 2026-07-29, this cascade timed directly on an idle 16-core mac with
    # only four test files running: 90, 99, 127, 2211, 2532 ms. Bimodal, and the
    # slow mode is not the nominal work — five `sh -c false` spawns plus a
    # 1,2,4,8,16ms backoff is the ~100ms cluster. The ~2.2s cluster is fork/exec
    # contention with the `node` spawns of sibling suites, so what this budget
    # actually races is process-spawn pressure from the rest of the run, which no
    # barrier here can remove. The old 200-try (2s) budget lost to it in 2 of 3
    # combined runs on an IDLE machine; CI is 4-core and busier.
    assert wait_until(
             fn ->
               match?(
                 %{"claude:default@testhost" => %{circuit: :open}},
                 AdapterCoordinator.health(coordinator)
               )
             end,
             1_500
           )

    assert {:error, :degraded} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    assert %{"claude:default@testhost" => %{consecutive_failures: failures}} =
             AdapterCoordinator.health(coordinator)

    assert failures >= 5
  end

  test "failure circuit threshold uses application config", ctx do
    old_value = Application.get_env(:tightbeam, :adapter_failure_circuit)

    on_exit(fn ->
      if old_value,
        do: Application.put_env(:tightbeam, :adapter_failure_circuit, old_value),
        else: Application.delete_env(:tightbeam, :adapter_failure_circuit)
    end)

    Application.put_env(:tightbeam, :adapter_failure_circuit, 1)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         backoff_base_ms: 1_000,
         adapter_opts: fn _ ->
           [harness: :claude, cmd: [System.find_executable("false")], home: "/tmp", cwd: "/tmp"]
         end,
         db: ctx.db,
         name: :configured_failure_circuit}
      )

    assert {:ok, _pid, _generation} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    assert wait_until(fn ->
             match?(
               %{"claude:default@testhost" => %{circuit: :open, consecutive_failures: 1}},
               AdapterCoordinator.health(coordinator)
             )
           end)
  end

  # What the coordinator itself says it is doing: {holding a slot, waiting for one}.
  # Kept as a pair rather than a total because the total is what an uncapped
  # coordinator can also produce — the queued half is the cap's only footprint.
  defp load_slot_split(coordinator, machine) do
    state = :sys.get_state(coordinator)
    active = Map.get(state.load_active, machine, %{})
    queue = Map.get(state.load_queue, machine, :queue.new())
    {map_size(active), :queue.len(queue)}
  end

  defp coordinator_generation(coordinator, key) do
    coordinator
    |> :sys.get_state()
    |> get_in([:adapters, key, :generation])
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  defp test_nonce do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  test "harness OS-process death (acp_exit) kills the adapter — no silent wedge", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)
    stderr_path = Path.join(ctx.test_dir, "stderr.log")
    refute File.exists?(stderr_path)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir,
             stderr_path: stderr_path
           ]
         end,
         db: ctx.db,
         name: :"coordinator_#{System.unique_integer([:positive])}"}
      )

    assert {:ok, adapter, 1} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    assert is_pid(Tightbeam.Acp.Adapter.conn(adapter))
    ref = Process.monitor(adapter)
    File.write!(stderr_path, "adapter transport died: credential socket closed\n")
    send(adapter, {:acp_exit, 137})

    assert_receive {:DOWN, ^ref, :process, ^adapter,
                    {:adapter_fault,
                     %{
                       reason: {:acp_exit, 137},
                       stderr: "adapter transport died: credential socket closed"
                     }}},
                   2_000

    assert eventually(fn ->
             coordinator_generation(coordinator, {:claude, "default", "testhost"}) == 2
           end)

    assert [
             %{
               kind: "adapter_down",
               detail: detail
             }
           ] =
             ctx.db |> EventLog.lifecycle_events() |> Enum.filter(&(&1.kind == "adapter_down"))

    assert detail =~ "adapter transport died: credential socket closed"
  end

  test "an adapter dying with a draining gateway is lifecycle, not an [error]", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir
           ]
         end,
         db: ctx.db,
         name: :"coordinator_#{System.unique_integer([:positive])}"}
      )

    assert {:ok, adapter, 1} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    assert is_pid(Tightbeam.Acp.Adapter.conn(adapter))
    ref = Process.monitor(adapter)

    :persistent_term.put({Tightbeam.Application, :draining}, true)
    on_exit(fn -> :persistent_term.erase({Tightbeam.Application, :draining}) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(adapter, {:acp_exit, 255})

        # {:shutdown, reason} is the demotion: OTP emits no crash report for a
        # shutdown tuple, and the wrapped reason still reaches the coordinator's
        # adapter_down row. A spontaneous death (the test above) keeps the bare
        # fault reason and with it the [error] report.
        assert_receive {:DOWN, ^ref, :process, ^adapter, {:shutdown, {:acp_exit, 255}}}, 2_000
      end)

    refute log =~ "[error]"
    assert log =~ "adapter exited with the draining gateway"
  end

  test "adapter death bumps generation and records lifecycle", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir
           ]
         end,
         db: ctx.db,
         name: :"coordinator_#{System.unique_integer([:positive])}"}
      )

    assert {:ok, adapter, 1} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    Process.exit(adapter, :kill)

    assert eventually(fn ->
             coordinator_generation(coordinator, {:claude, "default", "testhost"}) == 2
           end)

    assert [%{kind: "adapter_down", subject: "claude:default@testhost"}] =
             EventLog.lifecycle_events(ctx.db)
  end

  test "planned close tears down the adapter without crash restart bookkeeping", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir
           ]
         end,
         db: ctx.db,
         name: :planned_close_coordinator}
      )

    key = {:claude, "default", "testhost"}
    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)

    assert wait_until(
             fn -> match?({:ok, {_, 1}}, AdapterCoordinator.ready_token(coordinator, key)) end,
             500
           )

    {:ok, closed_token} = AdapterCoordinator.ready_token(coordinator, key)
    ref = Process.monitor(adapter)

    assert :ok = AdapterCoordinator.close_adapter(coordinator, key)
    assert_receive {:DOWN, ^ref, :process, ^adapter, _reason}, 2_000

    # A planned teardown IS a death in the token algebra: the successor must be
    # a NEW generation, or a credential stop/start landing inside a probe-retry
    # window would re-mint the SAME ready token and the strict heal sweep would
    # never feed the re-held session (task #103 review). Still no crash
    # bookkeeping: no lifecycle row, no failure count.
    assert coordinator_generation(coordinator, key) == 2
    assert EventLog.lifecycle_events(ctx.db) == []

    # The successor boots as generation 2, and its ready token strictly
    # outranks every token stamped against the closed process.
    assert {:ok, _successor, 2} = AdapterCoordinator.adapter_for(coordinator, key)

    assert wait_until(
             fn -> match?({:ok, {_, 2}}, AdapterCoordinator.ready_token(coordinator, key)) end,
             500
           )

    {:ok, reborn_token} = AdapterCoordinator.ready_token(coordinator, key)
    assert AdapterCoordinator.newer_token?(reborn_token, closed_token)
  end

  test "load-slot queue caps concurrency at three and releases on borrower exit", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ -> [] end,
         db: ctx.db,
         name: :"coordinator_#{System.unique_integer([:positive])}"}
      )

    parent = self()

    tasks =
      for i <- 1..6 do
        Task.async(fn ->
          send(parent, {:asking, i})

          AdapterCoordinator.with_load_slot(coordinator, "testhost", fn ->
            send(parent, {:entered, i, self()})
            receive do: (:release -> :ok)
          end)
        end)
      end

    # Every borrower HOLDS its slot until released, so "three at once" is observed
    # rather than inferred. The old shape gave each borrower a 40ms sleep and read
    # a high-water mark afterwards: under load a borrower could enter and leave
    # before a sibling was scheduled, and a correct cap read as 2.
    for _ <- 1..6, do: assert_receive({:asking, _})

    # The COORDINATOR's own books are the barrier, because only it can evidence
    # that a borrower asked. Mailbox order is a guarantee about ONE sender pair,
    # and these are six senders: a `:sys.get_state` from the test process can be
    # answered before a borrower's acquire arrives, leaving the refute below free
    # to pass because the stragglers had not asked yet rather than because the cap
    # held.
    #
    # It is the SPLIT that has to be asserted, not the total. Six borrowers accounted
    # for is satisfied by an uncapped coordinator reporting six ACTIVE, and then the
    # refute passes whenever only three of them happen to resume inside its 50ms.
    # {3, 3} is a shape only a coordinator that actually held the cap can produce, so
    # the fail-before stops depending on how the scheduler feels.
    assert wait_until(fn -> load_slot_split(coordinator, "testhost") == {3, 3} end)

    holders = for _ <- 1..3, do: assert_receive({:entered, _i, _pid})
    refute_receive {:entered, _, _}, 50

    release = fn entered -> for {:entered, _i, pid} <- entered, do: send(pid, :release) end
    release.(holders)

    # The queue drains onto the freed slots rather than staying wedged.
    release.(for _ <- 1..3, do: assert_receive({:entered, _i, _pid}))
    Enum.each(tasks, &Task.await(&1, 5_000))
  end

  test "load slots for different machines run concurrently", ctx do
    old_value = Application.get_env(:tightbeam, :adapter_load_soft_cap)

    on_exit(fn ->
      if old_value,
        do: Application.put_env(:tightbeam, :adapter_load_soft_cap, old_value),
        else: Application.delete_env(:tightbeam, :adapter_load_soft_cap)
    end)

    Application.put_env(:tightbeam, :adapter_load_soft_cap, 1)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ -> [] end,
         db: ctx.db,
         name: :per_machine_load_cap}
      )

    parent = self()

    first =
      Task.async(fn ->
        AdapterCoordinator.with_load_slot(coordinator, "machine-a", fn ->
          send(parent, {:entered, "machine-a"})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:entered, "machine-a"}

    second =
      Task.async(fn ->
        AdapterCoordinator.with_load_slot(coordinator, "machine-b", fn ->
          send(parent, {:entered, "machine-b"})
        end)
      end)

    assert_receive {:entered, "machine-b"}, 500
    send(first.pid, :release)
    Task.await(first)
    Task.await(second)
  end

  test "load soft cap uses application config", ctx do
    old_value = Application.get_env(:tightbeam, :adapter_load_soft_cap)

    on_exit(fn ->
      if old_value,
        do: Application.put_env(:tightbeam, :adapter_load_soft_cap, old_value),
        else: Application.delete_env(:tightbeam, :adapter_load_soft_cap)
    end)

    Application.put_env(:tightbeam, :adapter_load_soft_cap, 1)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ -> [] end,
         db: ctx.db,
         name: :configured_load_cap}
      )

    parent = self()

    first =
      Task.async(fn ->
        AdapterCoordinator.with_load_slot(coordinator, "testhost", fn ->
          send(parent, :first_entered)
          receive do: (:release_first -> :ok)
        end)
      end)

    assert_receive :first_entered

    second =
      Task.async(fn ->
        send(parent, :second_asking)

        AdapterCoordinator.with_load_slot(coordinator, "testhost", fn ->
          send(parent, :second_entered)
        end)
      end)

    # The barrier the refute needs: nothing here proved the second task had even
    # been SCHEDULED, so a cap that wrongly admitted it still looked blocked for
    # the whole 50ms window. The marker alone does not fix that — it is the task
    # speaking about itself, and a `:sys.get_state` from THIS process cannot be
    # ordered against a call sent by that one. Nor does a count of two: an uncapped
    # coordinator reports two ACTIVE, and the refute then rides on the second task
    # staying descheduled. Only {1, 1} — one holding, one waiting its turn — says
    # the cap turned the second borrower away rather than admitting it.
    assert_receive :second_asking
    assert wait_until(fn -> load_slot_split(coordinator, "testhost") == {1, 1} end)
    refute_receive :second_entered, 50
    send(first.pid, :release_first)
    assert_receive :second_entered
    Task.await(first)
    Task.await(second)
  end

  defp eventually(fun, tries \\ 40) do
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
end
