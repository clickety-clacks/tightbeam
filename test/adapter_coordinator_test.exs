defmodule Tightbeam.AdapterCoordinatorTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, DB, EventLog, HarnessProcess, HarnessProcessCensus}

  @fake ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  defmodule DelayedDbProxy do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         db: Keyword.fetch!(opts, :db),
         delay_ms: Keyword.fetch!(opts, :delay_ms),
         owner: Keyword.fetch!(opts, :owner),
         calls: 0
       }}
    end

    @impl true
    def handle_call({:transaction_until, fun, deadline}, _from, state) do
      call = state.calls + 1
      if call == 2, do: Process.sleep(state.delay_ms)
      reply = Tightbeam.DB.transaction_until(state.db, fun, deadline)
      send(state.owner, {:delayed_db_proxy_done, call})
      {:reply, reply, %{state | calls: call}}
    end

    def handle_call(request, _from, state) do
      {:reply, GenServer.call(state.db, request), state}
    end
  end

  setup do
    db = :"coordinator_db_#{System.unique_integer([:positive])}"
    sup = :"adapter_sup_#{System.unique_integer([:positive])}"
    test_dir = Path.join(System.tmp_dir!(), "adapter-coordinator-#{test_nonce()}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    start_supervised!({DB, path: ":memory:", name: db})
    # The whole schema, not just the events table: a death is now told to the
    # sessions it halted, so the coordinator reads `sessions` and `messages`.
    :ok = ensure_all_schemas(db)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    %{db: db, sup: sup, test_dir: test_dir}
  end

  test "five consecutive boot failures open the circuit (async boot)", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         backoff_base_ms: 1,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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

  # THE INCIDENT TEST (2026-08-14). A latched circuit vetoed the credential
  # lifecycle's own start call, so an operator installing a WORKING credential
  # was refused by a verdict about the credential they were replacing -- and the
  # onboarding ceremony read that refusal as "this credential is bad". Recovery
  # required restarting the gateway to wipe the in-memory latch.
  #
  # SCOPE, stated so it is not read for more than it proves (Sol xhigh): this is
  # a coordinator-level ADMISSION regression. It proves the latched circuit no
  # longer refuses the authoritative caller, and that ordinary checkouts are
  # still refused. It does not exercise start_provider_runtime, credential
  # persistence, or eventual circuit closure -- the adapter command here is
  # `false` and never boots. The end-to-end proof is a live credential swap on a
  # real gateway, recorded in the e2e ledger.
  test "an open circuit does not refuse the credential lifecycle", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         backoff_base_ms: 1,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           [harness: :claude, cmd: [System.find_executable("false")], home: "/tmp", cwd: "/tmp"]
         end,
         db: ctx.db,
         name: :"coord_#{System.unique_integer([:positive])}"}
      )

    key = {:claude, "default", "testhost"}

    # Drive the key into a latched circuit, exactly as an expired credential does.
    assert {:ok, _pid, _gen} = AdapterCoordinator.adapter_for(coordinator, key)

    assert wait_until(
             fn ->
               match?(
                 %{"claude:default@testhost" => %{circuit: :open}},
                 AdapterCoordinator.health(coordinator)
               )
             end,
             1_500
           )

    # An ordinary checkout is still refused -- the circuit keeps doing its real
    # job, which this change does not touch.
    assert {:error, :degraded} = AdapterCoordinator.adapter_for(coordinator, key)

    # The credential lifecycle's call is NOT refused. Before the fix this
    # returned {:error, :degraded}, which is the entire deadlock.
    assert {:ok, _pid, _generation} =
             AdapterCoordinator.adapter_for(coordinator, key, credential_kind: :subscription)
  end

  test "adapter boot context is captured in the coordinator before lazy adapter opts", ctx do
    owner = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn key ->
           send(owner, {:adapter_context, self(), key})
           [credential_kind: :subscription]
         end,
         adapter_opts: fn key, context ->
           send(owner, {:adapter_opts, self(), key, context})

           [
             harness: :claude,
             cmd: [System.find_executable("false")],
             home: "/tmp",
             cwd: "/tmp"
           ]
         end,
         db: ctx.db,
         name: :"coord_#{System.unique_integer([:positive])}"}
      )

    key = {:claude, "default", "testhost"}
    assert {:ok, adapter, _generation} = AdapterCoordinator.adapter_for(coordinator, key)
    assert_receive {:adapter_context, context_worker, ^key}
    refute context_worker == coordinator
    assert_receive {:adapter_opts, ^adapter, ^key, [credential_kind: :subscription]}
  end

  test "context capture frees the coordinator mailbox for a lifecycle callback", ctx do
    owner = self()
    coordinator_slot = :atomics.new(1, signed: false)
    lifecycle_key = {:claude, "lifecycle", "testhost"}

    lifecycle = start_supervised!({Agent, fn -> nil end})

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn key ->
           coordinator = :persistent_term.get({__MODULE__, coordinator_slot})

           Agent.get(lifecycle, fn _ ->
             send(owner, {:capture_entered, self(), key})
             :ok = AdapterCoordinator.close_adapter(coordinator, lifecycle_key)
             [credential_kind: :subscription]
           end)
         end,
         adapter_opts: fn _, _ ->
           [harness: :claude, cmd: [System.find_executable("false")], home: "/tmp", cwd: "/tmp"]
         end,
         db: ctx.db,
         name: :"coord_#{System.unique_integer([:positive])}"}
      )

    :persistent_term.put({__MODULE__, coordinator_slot}, coordinator)
    on_exit(fn -> :persistent_term.erase({__MODULE__, coordinator_slot}) end)

    key = {:claude, "default", "testhost"}
    checkout = Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
    assert_receive {:capture_entered, worker, ^key}
    refute worker == coordinator
    assert {:ok, {:ok, _adapter, _generation}} = Task.yield(checkout, 500)
  end

  test "authoritative credential context replaces a live adapter with a different kind", ctx do
    path = Path.join(ctx.test_dir, "context_fake.js")
    File.write!(path, @fake)
    owner = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [credential_kind: :subscription] end,
         adapter_opts: fn _, context ->
           send(owner, {:boot_context, self(), context})

           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir
           ]
         end,
         db: ctx.db,
         name: :"coord_#{System.unique_integer([:positive])}"}
      )

    key = {:claude, "default", "testhost"}
    assert {:ok, first, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    assert_receive {:boot_context, ^first, [credential_kind: :subscription]}
    first_ref = Process.monitor(first)

    assert {:ok, second, 2} =
             AdapterCoordinator.adapter_for(coordinator, key, credential_kind: :api_key)

    refute second == first
    assert_receive {:DOWN, ^first_ref, :process, ^first, _reason}
    assert_receive {:boot_context, ^second, [credential_kind: :api_key]}
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
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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

  test "an open circuit suppresses automatic restart but permits authoritative recovery", ctx do
    old_value = Application.get_env(:tightbeam, :adapter_failure_circuit)

    on_exit(fn ->
      if old_value,
        do: Application.put_env(:tightbeam, :adapter_failure_circuit, old_value),
        else: Application.delete_env(:tightbeam, :adapter_failure_circuit)
    end)

    Application.put_env(:tightbeam, :adapter_failure_circuit, 1)

    path = Path.join(ctx.test_dir, "circuit_recovery_fake.js")
    File.write!(path, @fake)

    owner = self()
    boot_attempt = :atomics.new(1, signed: false)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         backoff_base_ms: 1,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, context ->
           attempt = :atomics.add_get(boot_attempt, 1, 1)

           if attempt == 1 do
             [harness: :claude, cmd: [System.find_executable("false")], home: "/tmp", cwd: "/tmp"]
           else
             send(owner, {:recovery_boot_started, self(), context})

             receive do
               {:release_recovery_boot, pid} when pid == self() ->
                 [
                   harness: :claude,
                   cmd: [System.find_executable("node"), path],
                   home: ctx.test_dir,
                   cwd: ctx.test_dir
                 ]
             end
           end
         end,
         db: ctx.db,
         name: :circuit_latch_recovery_coordinator}
      )

    key = {:claude, "default", "testhost"}
    assert {:ok, _first_adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)

    assert wait_until(fn ->
             match?(
               %{"claude:default@testhost" => %{circuit: :open, consecutive_failures: 1}},
               AdapterCoordinator.health(coordinator)
             )
           end)

    # The threshold opens the latch before any restart can be admitted. The
    # public checkout must not observe a generation started by an automatic
    # restart while the latch is open.
    refute wait_until(fn -> :atomics.get(boot_attempt, 1) > 1 end, 100)
    assert {:error, :degraded} = AdapterCoordinator.adapter_for(coordinator, key)

    # Credential lifecycle recovery is the authoritative boundary: it may
    # start a replacement while ordinary checkout remains degraded.
    assert {:ok, recovery_adapter, 2} =
             AdapterCoordinator.adapter_for(coordinator, key, credential_kind: :subscription)

    assert_receive {:recovery_boot_started, ^recovery_adapter, [credential_kind: :subscription]}
    assert {:error, :degraded} = AdapterCoordinator.adapter_for(coordinator, key)

    send(recovery_adapter, {:release_recovery_boot, recovery_adapter})

    assert wait_until(fn ->
             match?(
               %{"claude:default@testhost" => %{circuit: :closed, consecutive_failures: 0}},
               AdapterCoordinator.health(coordinator)
             )
           end)

    assert {:ok, ^recovery_adapter, 2} = AdapterCoordinator.adapter_for(coordinator, key)
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
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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

  test "an adapter killed inside the park window is still recorded as a death", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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

    key = {:claude, "default", "testhost"}
    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    ref = Process.monitor(adapter)

    # Order the two messages the way ONLY a park can order them. Suspending the
    # coordinator puts the close request in its mailbox ahead of the death, so
    # do_close_adapter's selective receive is what collects the :DOWN and
    # handle_info/2 never sees it. That is the whole hazard: the park window is
    # a second, silent path a genuine death can leave by.
    :erlang.suspend_process(coordinator)
    :ok = AdapterCoordinator.request_close_adapter(coordinator, key)
    send(adapter, {:acp_exit, 137})
    assert_receive {:DOWN, ^ref, :process, ^adapter, _reason}, 2_000
    :erlang.resume_process(coordinator)

    assert eventually(fn ->
             ctx.db |> EventLog.lifecycle_events() |> Enum.any?(&(&1.kind == "adapter_down"))
           end)

    assert [%{kind: "adapter_down", detail: detail}] =
             ctx.db |> EventLog.lifecycle_events() |> Enum.filter(&(&1.kind == "adapter_down"))

    # The row says which state the adapter died in. A park that was ASKED for
    # and got :normal is not a death and stays unrecorded (the test below);
    # this one was killed while the park was in flight.
    assert detail =~ "parked=true"
    assert detail =~ "137"
  end

  test "a park that closes the adapter as asked records no death", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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

    key = {:claude, "default", "testhost"}
    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    ref = Process.monitor(adapter)

    assert :ok = AdapterCoordinator.close_adapter(coordinator, key)
    assert_receive {:DOWN, ^ref, :process, ^adapter, _reason}, 2_000

    assert [] = ctx.db |> EventLog.lifecycle_events() |> Enum.filter(&(&1.kind == "adapter_down"))
  end

  test "supervisor allowance exceeds the configured shutdown budget" do
    # The child_spec must read the configured option, not the module attribute:
    # a caller raising shutdown_budget_ms above the default would otherwise be
    # brutal-killed before its own internal deadline.
    assert AdapterCoordinator.child_spec([]).shutdown > 30_000
    assert AdapterCoordinator.child_spec(shutdown_budget_ms: 45_000).shutdown > 45_000
  end

  test "shutdown parks every adapter group under one supervisor budget", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)
    slow_helper = Path.join(ctx.test_dir, "slow_harness_helper")

    File.write!(
      slow_helper,
      "#!/bin/sh\n" <>
        "if [ \"$1\" = \"harness-group\" ]; then sleep 2; fi\n" <>
        "exec #{helper} \"$@\"\n"
    )

    File.chmod!(slow_helper, 0o755)

    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_helper: slow_helper,
            process_identity_dir: ctx.test_dir
          ]
        end,
        db: ctx.db,
        name: String.to_atom("shutdown_budget_coordinator_#{System.unique_integer([:positive])}")
      )

    Process.unlink(coordinator)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator, :shutdown) end)

    keys =
      for index <- 1..6 do
        {:claude, "shared", "shutdown-host-#{index}"}
      end

    for key <- keys do
      assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    end

    assert eventually(
             fn ->
               rows = HarnessProcess.list(ctx.db)
               length(rows) == length(keys) and Enum.all?(rows, &(&1.state == "running"))
             end,
             300
           )

    started_at = System.monotonic_time(:millisecond)
    assert :ok = GenServer.stop(coordinator, :shutdown, 30_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    # Six two-second group commands must overlap. The old serial terminate/2
    # needed roughly twelve seconds and made later adapters miss the same
    # 30-second supervisor shutdown window as the adapter count grew.
    assert elapsed_ms < 8_000
    assert Enum.all?(HarnessProcess.list(ctx.db), &(&1.state == "killed"))
    assert Enum.all?(keys, &(not HarnessProcess.fenced?(ctx.db, &1)))

    refute Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "adapter_shutdown_cleanup_failed")
           )
  end

  test "forced shutdown exhaustion is recorded before the supervisor budget expires", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)
    slow_helper = Path.join(ctx.test_dir, "slow_harness_helper")

    File.write!(
      slow_helper,
      "#!/bin/sh\n" <>
        "if [ \"$1\" = \"harness-group\" ]; then sleep 2; fi\n" <>
        "exec #{helper} \"$@\"\n"
    )

    File.chmod!(slow_helper, 0o755)

    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_helper: slow_helper,
            process_identity_dir: ctx.test_dir
          ]
        end,
        db: ctx.db,
        shutdown_budget_ms: 500,
        shutdown_settlement_budget_ms: 100,
        name:
          String.to_atom("shutdown_exhaustion_coordinator_#{System.unique_integer([:positive])}")
      )

    Process.unlink(coordinator)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator, :shutdown) end)

    keys =
      for index <- 1..6 do
        {:claude, "shared", "shutdown-exhaustion-host-#{index}"}
      end

    for key <- keys do
      assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    end

    assert eventually(
             fn ->
               rows = HarnessProcess.list(ctx.db)
               length(rows) == length(keys) and Enum.all?(rows, &(&1.state == "running"))
             end,
             300
           )

    started_at = System.monotonic_time(:millisecond)
    assert :ok = GenServer.stop(coordinator, :shutdown, 5_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 2_000

    rows = HarnessProcess.list(ctx.db)
    assert length(rows) == length(keys)
    assert Enum.all?(rows, &(&1.state == "kill_failed"))
    assert Enum.all?(rows, &(&1.last_error =~ "shutdown_budget_exhausted"))
    assert Enum.all?(keys, &HarnessProcess.fenced?(ctx.db, &1))

    assert length(
             Enum.filter(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "adapter_shutdown_cleanup_failed")
             )
           ) == length(keys)

    # The forced path must cancel the port-owned helper as well as record the
    # durable cleanup failure. A Task kill alone can strand the shebang wrapper
    # on macOS, where suite teardown catches it as a leaked fixture process.
    assert eventually(
             fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0 end,
             300
           )
  end

  test "preparation exhaustion fences every adapter and records each outcome", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)
    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)

    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_identity_dir: ctx.test_dir,
            process_helper: helper
          ]
        end,
        db: ctx.db,
        shutdown_budget_ms: 1_500,
        shutdown_settlement_budget_ms: 500,
        name:
          String.to_atom("shutdown_preparation_coordinator_#{System.unique_integer([:positive])}")
      )

    Process.unlink(coordinator)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator, :shutdown) end)

    keys =
      for index <- 1..6 do
        {:claude, "shared", "shutdown-preparation-host-#{index}"}
      end

    for key <- keys do
      assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    end

    assert eventually(
             fn ->
               rows = HarnessProcess.list(ctx.db)
               length(rows) == length(keys) and Enum.all?(rows, &(&1.state == "running"))
             end,
             300
           )

    parent = self()

    blocker =
      Task.async(fn ->
        DB.transaction(ctx.db, fn _txn ->
          send(parent, :shutdown_preparation_db_locked)
          # Must hold the DB owner past the park deadline (budget minus
          # settlement reserve) so preparation misses, while releasing well
          # before the full budget so settlement still lands. Process.sleep
          # only promises a minimum; the gap on each side absorbs the
          # scheduler overshoot a loaded parallel suite adds, which at the
          # old 450-in-500 margin recorded zero cleanup outcomes.
          Process.sleep(1_200)
          :ok
        end)
      end)

    assert_receive :shutdown_preparation_db_locked, 500
    started_at = System.monotonic_time(:millisecond)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = GenServer.stop(coordinator, :shutdown, 5_000)
      end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 2_000
    assert {:ok, :ok} = Task.await(blocker, 1_000)
    assert log =~ "preparation unresolved"

    rows = HarnessProcess.list(ctx.db)
    assert length(rows) == length(keys)
    assert Enum.all?(rows, &(&1.state == "running"))
    assert Enum.all?(keys, &HarnessProcess.fenced?(ctx.db, &1))
    refute Enum.any?(keys, &HarnessProcess.parked?(ctx.db, &1))

    assert length(
             Enum.filter(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "adapter_shutdown_cleanup_failed")
             )
           ) == length(keys)

    assert eventually(
             fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0 end,
             300
           )
  end

  test "a zero shutdown budget reports unresolved settlement and retires adapters", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)
    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)

    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_identity_dir: ctx.test_dir,
            process_helper: helper
          ]
        end,
        db: ctx.db,
        # No phase has time to reach the DB. The coordinator must retain OTP's
        # :ok while logging that durable outcomes are unresolved.
        shutdown_budget_ms: 0,
        shutdown_settlement_budget_ms: 100,
        name:
          String.to_atom("shutdown_settlement_coordinator_#{System.unique_integer([:positive])}")
      )

    Process.unlink(coordinator)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator, :shutdown) end)

    keys =
      for index <- 1..6 do
        {:claude, "shared", "shutdown-settlement-host-#{index}"}
      end

    for key <- keys do
      assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    end

    assert eventually(
             fn ->
               rows = HarnessProcess.list(ctx.db)
               length(rows) == length(keys) and Enum.all?(rows, &(&1.state == "running"))
             end,
             300
           )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = GenServer.stop(coordinator, :shutdown, 5_000)
      end)

    assert log =~ "durable outcomes unresolved"
    rows = HarnessProcess.list(ctx.db)
    assert length(rows) == length(keys)
    assert Enum.all?(rows, &(&1.state == "running"))
    assert Enum.all?(keys, &HarnessProcess.fenced?(ctx.db, &1))
    refute Enum.any?(keys, &HarnessProcess.parked?(ctx.db, &1))

    assert [] =
             Enum.filter(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "adapter_shutdown_cleanup_failed")
             )

    assert eventually(
             fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0 end,
             300
           )
  end

  test "settlement overrun keeps fences and bounds adapter retirement", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)
    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)

    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_identity_dir: ctx.test_dir,
            process_helper: helper
          ]
        end,
        db: ctx.db,
        shutdown_budget_ms: 500,
        shutdown_settlement_budget_ms: 100,
        name:
          String.to_atom(
            "shutdown_settlement_overrun_coordinator_#{System.unique_integer([:positive])}"
          )
      )

    Process.unlink(coordinator)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator, :shutdown) end)

    keys =
      for index <- 1..6 do
        {:claude, "shared", "shutdown-settlement-overrun-host-#{index}"}
      end

    for key <- keys do
      assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    end

    assert eventually(
             fn ->
               rows = HarnessProcess.list(ctx.db)
               length(rows) == length(keys) and Enum.all?(rows, &(&1.state == "running"))
             end,
             300
           )

    proxy =
      start_supervised!({DelayedDbProxy, db: ctx.db, delay_ms: 500, owner: self()})

    :sys.replace_state(coordinator, fn state -> %{state | db: proxy} end)
    started_at = System.monotonic_time(:millisecond)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = GenServer.stop(coordinator, :shutdown, 5_000)
      end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 1_000
    assert_receive {:delayed_db_proxy_done, 2}, 1_000
    assert log =~ "durable outcomes unresolved"

    rows = HarnessProcess.list(ctx.db)
    assert length(rows) == length(keys)

    # NOT "all rows killed". Identity-bound signalling is fail-closed: when the
    # audit-token executable-version fence trips — the same process having exec'd
    # between capture and signal — it REFUSES and records kill_failed. That is a
    # correct outcome, not a failure, and demanding unconditional kills asserts a
    # contract the product does not promise. A V6 macOS run surrendered on
    # exactly that (`process changed executable identity during capture`,
    # harness_process/signal.rs:311-320, reached only after Handle::open had
    # already accepted exact start-time and pgid equality).
    #
    # What the product does promise, and what is asserted instead: every row
    # carries a truthful terminal outcome, and nothing is left alive.
    assert Enum.all?(rows, &(&1.state in ["killed", "kill_failed"]))

    for row <- rows, row.state == "kill_failed" do
      assert row.last_error not in [nil, ""],
             "a kill_failed row must say why it refused, not merely that it did"
    end

    assert Enum.all?(keys, &HarnessProcess.fenced?(ctx.db, &1))

    assert eventually(
             fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0 end,
             300
           )
  end

  test "retirement cutoff preserves late entries for the settlement reserve", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)
    slow_helper = Path.join(ctx.test_dir, "slow_harness_helper")

    File.write!(
      slow_helper,
      "#!/bin/sh\n" <>
        "if [ \"$1\" = \"harness-group\" ]; then sleep 2; fi\n" <>
        "exec #{helper} \"$@\"\n"
    )

    File.chmod!(slow_helper, 0o755)

    # The cleanup owner. In the real tree this is Tightbeam.TurnTaskSupervisor,
    # which starts before the coordinator under rest_for_one and so outlives its
    # terminate/2; a standalone coordinator is given an equivalent owner here so
    # the same handoff path is exercised rather than the inline fallback.
    cleanup_owner =
      start_supervised!(
        {Task.Supervisor, name: :"shutdown_cutoff_cleanup_#{System.unique_integer([:positive])}"}
      )

    budget_ms = 1_200

    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_helper: slow_helper,
            process_identity_dir: ctx.test_dir
          ]
        end,
        db: ctx.db,
        shutdown_budget_ms: budget_ms,
        shutdown_settlement_budget_ms: 500,
        # Zero grace pins this test to the late path by construction: the
        # cancel deadline collapses to the reserve boundary, every hung park is
        # force-killed with no cooperative wait, and retirement always enters
        # past settle_start. At the default grace the premise is a race against
        # the host's process-enumeration cost — deterministically lost on Linux,
        # where 24 parks answer the cooperative cancel well inside 100ms and
        # retirement runs early (0/24 late over 5 runs), and only incidentally
        # won on macOS (24/24 late; art_171f5abc).
        shutdown_cancel_grace_ms: 0,
        shutdown_cleanup_supervisor: cleanup_owner,
        name:
          String.to_atom(
            "shutdown_retirement_cutoff_coordinator_#{System.unique_integer([:positive])}"
          )
      )

    Process.unlink(coordinator)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator, :shutdown) end)

    # Cardinality is the point: the deadline guarantee must not degrade as the
    # retained-adapter count grows, and this also exceeds the 20-key log sample
    # cap so the aggregate line's remainder path is exercised under load.
    keys =
      for index <- 1..24 do
        {:claude, "shared", "shutdown-retirement-cutoff-host-#{index}"}
      end

    for key <- keys do
      assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    end

    assert eventually(
             fn ->
               rows = HarnessProcess.list(ctx.db)
               length(rows) == length(keys) and Enum.all?(rows, &(&1.state == "running"))
             end,
             300
           )

    started_at = System.monotonic_time(:millisecond)

    # The cleanup now runs on its own owner AFTER terminate/2 returns, so its log
    # lands after GenServer.stop does. Waiting for the descendants to disappear
    # inside the capture is what makes that line observable here; measuring the
    # elapsed time before that wait is what keeps the deadline assertion honest.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # Deliberately looser than the budget so an overrun fails on the elapsed
        # bound below with a real number, instead of exiting here on an ambiguous
        # caller timeout.
        assert :ok = GenServer.stop(coordinator, :shutdown, 3_000)
        send(self(), {:shutdown_elapsed_ms, System.monotonic_time(:millisecond) - started_at})

        assert eventually(
                 fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0 end,
                 1_000
               )
      end)

    assert_received {:shutdown_elapsed_ms, elapsed_ms}

    # terminate/2 promises to complete within shutdown_budget_ms, and the V7
    # concern — a callback overrunning its own budget passing unnoticed — still
    # governs: the allowance below is measurement-scale, not phase-scale, so a
    # real overrun of the 500ms reserve still fails. Without the allowance the
    # bound's margin is negative by construction — it forbids what the code's
    # own contract permits and can fail on a quiet host on a scheduling hiccup.
    # Two costs land in elapsed_ms without being terminate's to spend:
    # DB.transaction_until grants
    # a final commit already in flight remaining + 50ms past the deadline rather
    # than abort a durable outcome (observed +8..22ms), and the measurement
    # starts before GenServer.stop dispatches, ahead of the callback's own clock
    # (observed +12..26ms under 4x CPU oversubscription). 100ms is ~3x the worst
    # observed sum of the two. This bound is a sanity check on the deadline
    # contract, not the regression detector: at the pre-fix base its catch rate
    # is platform-dependent — 0 of 8 loaded runs on eezo (macOS, elapsed
    # 853-1284ms, review control art_88fb2ef4) versus 3 of 6 on racter (Linux,
    # 1320-1338ms). What caught the base defect on both hosts is the row-state,
    # log-content and census oracles below, which this allowance leaves
    # untouched. With 24
    # retained adapters this also proves the bound does not degrade with
    # cardinality: the late entries' outcomes are decided before settlement, and
    # their cleanup is owned by someone else afterwards.
    observation_allowance_ms = 100

    assert elapsed_ms <= budget_ms + observation_allowance_ms,
           "shutdown took #{elapsed_ms}ms against a configured #{budget_ms}ms budget " <>
             "(+#{observation_allowance_ms}ms observation allowance) with " <>
             "#{length(keys)} retained adapters; the deadline guarantee did not hold"

    assert log =~ "retirement late entry unresolved"

    # 24 late entries against a 20-key sample cap, so the aggregate line must
    # name 24 and account for the 4 it did not list. Asserted rather than left to
    # a comment, because an unbounded log line on this path is the thing the cap
    # exists to prevent.
    assert log =~ "for #{length(keys)} adapter(s)"
    assert log =~ "and #{length(keys) - 20} more"

    # Durable unresolved outcomes: truthful per row, and fenced.
    rows = HarnessProcess.list(ctx.db)
    assert length(rows) == length(keys)
    assert Enum.all?(rows, &(&1.state == "kill_failed"))
    assert Enum.all?(rows, &(&1.last_error =~ "shutdown_retirement_unresolved"))
    assert Enum.all?(keys, &HarnessProcess.fenced?(ctx.db, &1))

    failures =
      Enum.filter(
        EventLog.lifecycle_events(ctx.db),
        &(&1.kind == "adapter_shutdown_cleanup_failed")
      )

    assert length(failures) == length(keys)
    assert Enum.all?(failures, &String.contains?(&1.detail, "shutdown_retirement_unresolved"))

    # No surviving live descendant — asserted inside the capture above, and again
    # here so the guarantee is stated where it is read.
    assert HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0
  end

  # The companion to the retirement-cutoff test above: the same 24 hung parks,
  # but with a grace the cooperative cancel can answer within on every
  # platform. It pins the non-late half of the contract, which no other test
  # distinguishes: the forced-exhaustion test earlier in this file matches
  # "shutdown_budget_exhausted" as a substring, and the late path's
  # {:shutdown_retirement_unresolved, :shutdown_budget_exhausted} satisfies
  # that too, so only the refutations here tell the two paths apart.
  test "cancel grace answered in time settles hung parks as plain budget exhaustion", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)
    slow_helper = Path.join(ctx.test_dir, "slow_harness_helper")

    File.write!(
      slow_helper,
      "#!/bin/sh\n" <>
        "if [ \"$1\" = \"harness-group\" ]; then sleep 2; fi\n" <>
        "exec #{helper} \"$@\"\n"
    )

    File.chmod!(slow_helper, 0o755)

    cleanup_owner =
      start_supervised!(
        {Task.Supervisor, name: :"shutdown_grace_cleanup_#{System.unique_integer([:positive])}"}
      )

    # The grace must exceed what consumes it: 24 concurrent process-group
    # enumerations cost ~31ms on Linux and ~197ms on macOS (art_171f5abc), so
    # one second holds a >5x margin on the slower platform. The budget grows by
    # the same second so the park phase keeps the cutoff test's shape: parks
    # get ~900ms against a 2s hang and always time out into the cancel path.
    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_helper: slow_helper,
            process_identity_dir: ctx.test_dir
          ]
        end,
        db: ctx.db,
        shutdown_budget_ms: 2_400,
        shutdown_settlement_budget_ms: 500,
        shutdown_cancel_grace_ms: 1_000,
        shutdown_cleanup_supervisor: cleanup_owner,
        name:
          String.to_atom(
            "shutdown_grace_settled_coordinator_#{System.unique_integer([:positive])}"
          )
      )

    Process.unlink(coordinator)
    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator, :shutdown) end)

    keys =
      for index <- 1..24 do
        {:claude, "shared", "shutdown-grace-settled-host-#{index}"}
      end

    for key <- keys do
      assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    end

    assert eventually(
             fn ->
               rows = HarnessProcess.list(ctx.db)
               length(rows) == length(keys) and Enum.all?(rows, &(&1.state == "running"))
             end,
             300
           )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = GenServer.stop(coordinator, :shutdown, 5_000)

        assert eventually(
                 fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0 end,
                 1_000
               )
      end)

    # The discriminator: retirement ran before the reserve boundary, so the
    # late-entry machinery never engaged.
    refute log =~ "retirement late entry unresolved"

    # Every hung park settled durably as plain budget exhaustion — truthful
    # rows, fenced, no unresolved marker anywhere.
    rows = HarnessProcess.list(ctx.db)
    assert length(rows) == length(keys)
    assert Enum.all?(rows, &(&1.state == "kill_failed"))
    assert Enum.all?(rows, &(&1.last_error =~ "shutdown_budget_exhausted"))
    refute Enum.any?(rows, &(&1.last_error =~ "shutdown_retirement_unresolved"))
    assert Enum.all?(keys, &HarnessProcess.fenced?(ctx.db, &1))

    failures =
      Enum.filter(
        EventLog.lifecycle_events(ctx.db),
        &(&1.kind == "adapter_shutdown_cleanup_failed")
      )

    assert length(failures) == length(keys)
    assert Enum.all?(failures, &String.contains?(&1.detail, "shutdown_budget_exhausted"))
    refute Enum.any?(failures, &String.contains?(&1.detail, "shutdown_retirement_unresolved"))

    assert HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0
  end

  test "Application.stop keeps cleanup failure evidence when OTP returns ok", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)
    helper = Path.expand("../cli/target/release/tightbeam", __DIR__)

    {:ok, coordinator} =
      AdapterCoordinator.start_link(
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            process_identity_dir: ctx.test_dir,
            process_helper: helper
          ]
        end,
        db: ctx.db,
        name: String.to_atom("shutdown_failure_coordinator_#{System.unique_integer([:positive])}")
      )

    Process.unlink(coordinator)
    key = {:claude, "shared", "shutdown-failure-host"}
    assert {:ok, _adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)

    assert eventually(fn -> match?([%{state: "running"}], HarnessProcess.list(ctx.db)) end)
    [%{identity_path: identity_path}] = HarnessProcess.list(ctx.db)
    File.write!(identity_path, "identity was corrupted before application stop\n")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # OTP's supervisor/application shutdown path ignores terminate/2's
        # return value. The truthful contract is therefore :ok plus durable
        # kill_failed and lifecycle evidence for the operator.
        assert :ok = GenServer.stop(coordinator, :shutdown, 30_000)
      end)

    assert [%{state: "kill_failed", last_error: last_error}] = HarnessProcess.list(ctx.db)
    assert last_error =~ "identity"
    assert HarnessProcess.fenced?(ctx.db, key)

    assert [%{kind: "adapter_shutdown_cleanup_failed", subject: subject, detail: detail}] =
             Enum.filter(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "adapter_shutdown_cleanup_failed")
             )

    assert subject == AdapterCoordinator.key_name(key)
    assert detail =~ "kill_failed"
    assert log =~ "adapter shutdown cleanup failed"
  end

  test "an adapter dying with a draining gateway is lifecycle, not an [error]", ctx do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
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

    assert wait_until(fn -> AdapterCoordinator.ready?(coordinator, key) end, 500)

    ref = Process.monitor(adapter)

    assert :ok = AdapterCoordinator.close_adapter(coordinator, key)
    assert_receive {:DOWN, ^ref, :process, ^adapter, _reason}, 2_000

    # A planned teardown IS a death for generation purposes: the successor must
    # be a NEW generation, so nothing downstream can mistake it for the process
    # it replaced. Still no crash bookkeeping: no lifecycle row, no failure
    # count.
    assert coordinator_generation(coordinator, key) == 2
    assert EventLog.lifecycle_events(ctx.db) == []

    # The successor boots as generation 2.
    assert {:ok, _successor, 2} = AdapterCoordinator.adapter_for(coordinator, key)

    assert wait_until(fn -> AdapterCoordinator.ready?(coordinator, key) end, 500)
    assert coordinator_generation(coordinator, key) == 2
  end

  test "load-slot queue caps concurrency at three and releases on borrower exit", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ -> [] end,
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
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ -> [] end,
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
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ -> [] end,
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

  ## Task #14 — the guard covers the ACTION, not the RECORD

  test "a death absorbed by a replacement is recorded and told, but restarts nothing", ctx do
    key = {:claude, "shared", "testhost"}
    coordinator = start_fake_coordinator(ctx, :"absorbed_#{System.unique_integer([:positive])}")

    session_key = seed_session!(ctx.db)
    running_turn!(ctx.db, session_key)

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    await_ready!(coordinator, key)

    # The race this guard exists for, made deterministic: a :DOWN arriving under
    # a monitor ref the entry has already replaced. Only the ref is synthetic —
    # the branch it selects is the production one.
    stale_ref = make_ref()

    # Ready, like the instance a real absorbed :DOWN belongs to: it had booted
    # and was serving before a replacement took the entry over.
    :sys.replace_state(coordinator, fn state ->
      %{
        state
        | monitors: Map.put(state.monitors, stale_ref, key),
          ready_refs: MapSet.put(state.ready_refs, stale_ref)
      }
    end)

    send(coordinator, {:DOWN, stale_ref, :process, adapter, :killed})
    _ = :sys.get_state(coordinator)

    assert [%{kind: "adapter_down", subject: "claude:shared@testhost", detail: detail}] =
             EventLog.lifecycle_events(ctx.db)

    assert detail =~ "absorbed=true"

    # The ACTION stayed gated: no generation bump, no restart timer, and the
    # live adapter the replacement owns was not nilled out.
    assert coordinator_generation(coordinator, key) == 1
    assert %{pid: ^adapter, timer: nil} = :sys.get_state(coordinator).adapters[key]

    # The resident session is still TOLD: the message claims only that the
    # engine stopped, which is true of an absorbed death too, so there is no
    # attribution to get wrong.
    assert [marker] = Tightbeam.Projection.list_after(ctx.db, session_key, nil, 10)
    assert marker.content =~ "[adapter down]"
  end

  test "readiness is credited to the instance the ready message names, not to the entry", ctx do
    key = {:claude, "shared", "testhost"}
    coordinator = start_fake_coordinator(ctx, :"credit_#{System.unique_integer([:positive])}")

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    await_ready!(coordinator, key)

    # Wind readiness back so the credit is observable, then replay the ready
    # message under a FOREIGN pid — the shape of an instance that announced
    # readiness, died, and had a replacement installed before the coordinator
    # got to the message.
    :sys.replace_state(coordinator, fn state ->
      %{
        state
        | adapters: Map.update!(state.adapters, key, &%{&1 | ready: false}),
          ready_refs: MapSet.new()
      }
    end)

    send(coordinator, {:adapter_ready, key, self()})
    state = :sys.get_state(coordinator)
    refute state.adapters[key].ready, "a foreign instance's ready credited this entry"
    assert MapSet.size(state.ready_refs) == 0

    # The instance the entry DOES point at is credited, and its monitor ref is
    # what gets remembered — that ref is the identity a later :DOWN asks about.
    send(coordinator, {:adapter_ready, key, adapter})
    state = :sys.get_state(coordinator)
    assert state.adapters[key].ready
    assert MapSet.member?(state.ready_refs, state.adapters[key].monitor)
  end

  test "a ready adapter's death is told even when a replacement already took the entry over",
       ctx do
    key = {:claude, "shared", "testhost"}
    coordinator = start_fake_coordinator(ctx, :"absorbed2_#{System.unique_integer([:positive])}")

    session_key = seed_session!(ctx.db)

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    await_ready!(coordinator, key)

    # The state an absorbed death actually presents, injected rather than raced
    # into being: the instance that DIED had booted (its ref is in ready_refs),
    # while the entry now describes the replacement that took over and has not
    # booted yet (ready: false). Driving it with a second live adapter cannot
    # pin this — its own {:adapter_ready, key} can overtake the :DOWN in the
    # mailbox, and the test then passes for the wrong reason.
    #
    # Readiness asked of the ENTRY answers for the successor and this genuine
    # post-ready death goes silent; asked of the REF it answers for the instance
    # that died. Nothing re-marks the entry ready here, so the distinction is
    # the only thing this test can be reading.
    stale_ref = make_ref()

    :sys.replace_state(coordinator, fn state ->
      %{
        state
        | monitors: Map.put(state.monitors, stale_ref, key),
          ready_refs: MapSet.put(state.ready_refs, stale_ref),
          adapters: Map.update!(state.adapters, key, &%{&1 | ready: false})
      }
    end)

    send(coordinator, {:DOWN, stale_ref, :process, adapter, :killed})
    _ = :sys.get_state(coordinator)

    assert [%{kind: "adapter_down"}] = EventLog.lifecycle_events(ctx.db)
    assert [marker] = Tightbeam.Projection.list_after(ctx.db, session_key, nil, 10)
    assert marker.content =~ "[adapter down]"
  end

  test "an adapter that never became ready messages nobody", ctx do
    key = {:claude, "shared", "testhost"}

    # `false` never speaks the ACP handshake, so this adapter dies during boot
    # and is never marked ready. A boot-failure cascade runs this five times
    # before the circuit opens; posting each one to every session on the host
    # is the firehose the audit exists to prevent.
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         backoff_base_ms: 60_000,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           [harness: :claude, cmd: [System.find_executable("false")], home: "/tmp", cwd: "/tmp"]
         end,
         db: ctx.db,
         name: :"never_ready_#{System.unique_integer([:positive])}"}
      )

    session_key = seed_session!(ctx.db)
    _seq = running_turn!(ctx.db, session_key)

    assert {:ok, _pid, 1} = AdapterCoordinator.adapter_for(coordinator, key)

    assert eventually(fn -> EventLog.lifecycle_events(ctx.db) != [] end)

    # The death is still ON THE RECORD; only the interruption is withheld.
    assert [%{kind: "adapter_down"}] = EventLog.lifecycle_events(ctx.db)
    assert Tightbeam.Projection.list_after(ctx.db, session_key, nil, 10) == []
  end

  test "a death posts a fault message the session's reader sees", ctx do
    key = {:claude, "shared", "testhost"}
    coordinator = start_fake_coordinator(ctx, :"halted_#{System.unique_integer([:positive])}")

    session_key = seed_session!(ctx.db)

    seq = running_turn!(ctx.db, session_key)
    :ok = Tightbeam.Ledger.stamp_adapter(ctx.db, seq, 1)

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    await_ready!(coordinator, key)
    Process.exit(adapter, :kill)

    assert eventually(fn -> coordinator_generation(coordinator, key) == 2 end)

    assert [%{kind: "adapter_down"}] = EventLog.lifecycle_events(ctx.db)

    # A message a clawline client renders and replays — the counterpart of the
    # "[adapter recovered]" probe that already reaches this reader.
    assert [marker] = Tightbeam.Projection.list_after(ctx.db, session_key, nil, 10)
    assert marker.content =~ "[adapter down]"
    assert marker.content =~ "claude:shared@testhost"
    assert marker.sender == "process:tightbeam"
    assert marker.attention_tier == 0

    assert Tightbeam.Wire.Payloads.server_message(marker)["attentionTier"] == 0
  end

  test "a session resident on the adapter is told even with no turn in flight", ctx do
    key = {:claude, "shared", "testhost"}
    coordinator = start_fake_coordinator(ctx, :"unstamped_#{System.unique_integer([:positive])}")

    # No turn at all. The engine this session runs on died and its harness
    # context went with it, which is true whether or not a prompt was in
    # flight — and the turn-attribution predicates that would have excluded
    # this session are exactly what three review rounds found unsound.
    session_key = seed_session!(ctx.db)

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    await_ready!(coordinator, key)
    Process.exit(adapter, :kill)

    assert eventually(fn -> coordinator_generation(coordinator, key) == 2 end)

    assert [%{kind: "adapter_down"}] = EventLog.lifecycle_events(ctx.db)
    assert [marker] = Tightbeam.Projection.list_after(ctx.db, session_key, nil, 10)
    assert marker.content =~ "[adapter down]"
  end

  test "a death on a key no session is resident to messages nobody", ctx do
    # The session below lives on `testhost`; this adapter serves `otherhost`.
    key = {:claude, "shared", "otherhost"}
    coordinator = start_fake_coordinator(ctx, :"idle_#{System.unique_integer([:positive])}")

    session_key = seed_session!(ctx.db)

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    await_ready!(coordinator, key)
    Process.exit(adapter, :kill)

    assert eventually(fn -> coordinator_generation(coordinator, key) == 2 end)

    # The record is unconditional; the interruption is not.
    assert [%{kind: "adapter_down"}] = EventLog.lifecycle_events(ctx.db)
    assert Tightbeam.Projection.list_after(ctx.db, session_key, nil, 10) == []
  end

  # `start_supervised!` is not a boot barrier: Acp.Adapter returns from init
  # before `node` is spawned, and only {:adapter_ready, key} marks the entry
  # ready. A death BEFORE that point is a boot failure, which deliberately
  # messages nobody — so a test about a working engine dying must wait here.
  defp await_ready!(coordinator, key) do
    assert wait_until(
             fn -> AdapterCoordinator.ready?(coordinator, key) end,
             2_000
           )
  end

  defp seed_session!(db) do
    :ok = DB.execute(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',0,1)")
    session_key = "agent:main:clawline:flynn:main"

    Tightbeam.Org.create(db, %{
      session_key: session_key,
      display_name: "Main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("claude-fable-5")
    })

    session_key
  end

  defp running_turn!(db, session_key) do
    {:ok, seq} =
      Tightbeam.Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "m_#{System.unique_integer([:positive])}",
        origin: "user:flynn",
        prompt: "do the thing"
      })

    {:ok, _turn} = Tightbeam.Ledger.claim_next(db, session_key, "lane")
    seq
  end

  defp start_fake_coordinator(ctx, name) do
    path = Path.join(ctx.test_dir, "fake_harness.js")
    File.write!(path, @fake)

    start_supervised!(
      {AdapterCoordinator,
       adapter_sup: ctx.sup,
       adapter_context: fn _ -> [] end,
       adapter_opts: fn _, _ ->
         [
           harness: :claude,
           cmd: [System.find_executable("node"), path],
           home: ctx.test_dir,
           cwd: ctx.test_dir
         ]
       end,
       db: ctx.db,
       name: name}
    )
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
