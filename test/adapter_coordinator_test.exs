defmodule Tightbeam.AdapterCoordinatorTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, DB, EventLog}

  @process_helper Path.expand("../cli/target/release/tightbeam", __DIR__)

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
    # The whole schema, not just the events table: a death is now told to the
    # sessions it halted, so the coordinator reads `sessions` and `messages`.
    :ok = ensure_all_schemas(db)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    %{db: db, sup: sup, test_dir: test_dir}
  end

  test "all public checkout APIs retain the reviewed 190s budget over the 185s generation deadline" do
    source = File.read!("lib/tightbeam/adapter_coordinator.ex")
    assert source =~ "@adapter_readiness_timeout 185_000"
    assert source =~ "@adapter_checkout_timeout 190_000"
    assert length(Regex.scan(~r/GenServer\.call\([^\n]+@adapter_checkout_timeout\)/, source)) == 3
    refute source =~ "{:adapter_for, key}, 30_000"
  end

  test "typed launch refusal is coalesced and never starts an adapter child", ctx do
    parent = self()
    refusal = %{code: "DIV-CURSOR-API-KEY-ONLY", message: "Cursor requires a banked API key"}

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           send(parent, :preflight)
           Process.sleep(25)
           {:error, refusal}
         end,
         db: ctx.db,
         name: :typed_refusal_coordinator}
      )

    key = {:cursor, "default", "testhost"}

    callers =
      for _ <- 1..3, do: Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)

    assert Enum.map(callers, &Task.await/1) ==
             List.duplicate({:error, {:launch_refused, refusal}}, 3)

    assert_receive :preflight
    refute_receive :preflight
    assert DynamicSupervisor.count_children(ctx.sup).active == 0
  end

  test "generation readiness timeout flushes callers and ignores its late preflight", ctx do
    parent = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           send(parent, {:preflight_waiting, self()})

           receive do
             :release -> [harness: :cursor]
           end
         end,
         db: ctx.db,
         name: :readiness_timeout_coordinator}
      )

    key = {:cursor, "default", "testhost"}
    caller = Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
    assert_receive {:preflight_waiting, task}

    state = :sys.get_state(coordinator)
    entry = state.adapters[key]

    send(
      coordinator,
      {:adapter_readiness_timeout, key, entry.generation, entry.readiness_token}
    )

    assert {:error, {:launch_refused, %{code: "adapter_readiness_timeout"}}} = Task.await(caller)

    refute Process.alive?(task)
    assert DynamicSupervisor.count_children(ctx.sup).active == 0
  end

  test "authoritative credential context replaces pending stale preflight", ctx do
    parent = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [credential_kind: :subscription] end,
         adapter_opts: fn _, context ->
           send(parent, {:preflight_context, self(), context})

           if context[:credential_kind] == :subscription do
             receive do
               :release_stale -> :ok
             end
           end

           {:error, %{code: Atom.to_string(context[:credential_kind]), message: "context used"}}
         end,
         db: ctx.db,
         name: :authoritative_pending_coordinator}
      )

    key = {:cursor, "default", "testhost"}
    initial = Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
    assert_receive {:preflight_context, stale_task, [credential_kind: :subscription]}

    authoritative =
      Task.async(fn ->
        AdapterCoordinator.adapter_for(coordinator, key, credential_kind: :api_key)
      end)

    assert_receive {:preflight_context, _replacement_task, [credential_kind: :api_key]}
    refute Process.alive?(stale_task)

    expected = {:error, {:launch_refused, %{code: "api_key", message: "context used"}}}
    assert Task.await(initial) == expected
    assert Task.await(authoritative) == expected
  end

  test "authoritative replacement of a booting child settles its old launch and transfers both callers",
       ctx do
    slow = Path.join(ctx.test_dir, "slow_authoritative.js")
    fast = Path.join(ctx.test_dir, "fast_authoritative.js")

    File.write!(slow, """
    const rl = require("node:readline").createInterface({ input: process.stdin });
    const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\\n");
    rl.on("line", (line) => {
      const m = JSON.parse(line);
      if (m.method === "initialize") setTimeout(() => send({ id: m.id, result: { protocolVersion: 1 } }), 10000);
    });
    """)

    File.write!(fast, @fake)
    parent = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [credential_kind: :subscription] end,
         adapter_opts: fn _, context ->
           kind = context[:credential_kind]
           send(parent, {:authoritative_child_opts, kind})

           [
             harness: :claude,
             readiness_rendezvous: true,
             cmd: [System.find_executable("node"), if(kind == :api_key, do: fast, else: slow)],
             home: ctx.test_dir,
             cwd: ctx.test_dir,
             process_identity_dir: ctx.test_dir,
             process_helper: @process_helper
           ]
         end,
         db: ctx.db,
         name: :authoritative_child_replacement_coordinator}
      )

    key = {:claude, "shared", "testhost"}
    first = Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
    assert_receive {:authoritative_child_opts, :subscription}

    assert wait_until(fn ->
             match?(
               [%{state: "running", resolved_at: nil}],
               Tightbeam.HarnessProcess.list(ctx.db)
             )
           end)

    old = :sys.get_state(coordinator).adapters[key]
    assert is_pid(old.pid)
    assert is_reference(old.monitor)
    assert is_reference(old.readiness_token)

    second =
      Task.async(fn ->
        AdapterCoordinator.adapter_for(coordinator, key, credential_kind: :api_key)
      end)

    assert_receive {:authoritative_child_opts, :api_key}
    assert {:ok, replacement, 2} = Task.await(first, 5_000)
    assert {:ok, ^replacement, 2} = Task.await(second, 5_000)

    [current, replaced] = Tightbeam.HarnessProcess.list(ctx.db)
    assert current.state == "running"
    assert current.resolved_at == nil
    assert replaced.state == "exited"
    assert is_integer(replaced.resolved_at)

    current_entry = :sys.get_state(coordinator).adapters[key]
    assert current_entry.pid == replacement
    assert current_entry.generation == 2

    send(
      coordinator,
      {:adapter_readiness_timeout, key, old.generation, old.readiness_token}
    )

    send(coordinator, {:adapter_ready, key, old.pid, old.generation, old.readiness_token})

    send(
      coordinator,
      {:adapter_readiness_result, key, old.generation, old.readiness_token, self(),
       {:error, %{code: "stale"}}}
    )

    send(coordinator, {:DOWN, old.monitor, :process, old.pid, :killed})
    Process.sleep(20)

    after_stale = :sys.get_state(coordinator).adapters[key]
    assert after_stale.pid == replacement
    assert after_stale.generation == 2
    assert after_stale.ready

    assert Enum.map(Tightbeam.HarnessProcess.list(ctx.db), &{&1.state, &1.resolved_at}) ==
             [{"running", nil}, {"exited", replaced.resolved_at}]
  end

  test "hung readiness task times out, removes its child state, and flushes caller", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         readiness_timeout_ms: 30,
         adapter_context: fn _ -> Process.sleep(:infinity) end,
         adapter_opts: fn _, _ -> flunk("hung context reached adapter opts") end,
         db: ctx.db,
         name: :hung_readiness_coordinator}
      )

    assert {:error, {:launch_refused, %{code: "adapter_readiness_timeout"}}} =
             AdapterCoordinator.adapter_for(coordinator, {:cursor, "default", "testhost"})

    state = :sys.get_state(coordinator)
    entry = state.adapters[{:cursor, "default", "testhost"}]
    assert entry.pid == nil
    assert entry.readiness_task == nil
    assert entry.readiness_timer == nil
    assert entry.waiters == []
    assert DynamicSupervisor.count_children(ctx.sup).active == 0
  end

  test "caller cancellation removes its readiness waiter without extending the generation", ctx do
    parent = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ ->
           send(parent, :context_blocked)
           Process.sleep(:infinity)
         end,
         adapter_opts: fn _, _ -> [] end,
         db: ctx.db,
         name: :caller_cancel_coordinator}
      )

    key = {:cursor, "default", "testhost"}
    caller = spawn(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
    assert_receive :context_blocked
    Process.exit(caller, :kill)

    assert wait_until(fn -> :sys.get_state(coordinator).adapters[key].waiters == [] end)
    entry = :sys.get_state(coordinator).adapters[key]
    assert is_reference(entry.readiness_timer)
  end

  test "duplicate restart messages coalesce behind one generation readiness task", ctx do
    parent = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ ->
           send(parent, {:restart_generation_preflight, self()})

           receive do
             :release -> []
           end
         end,
         adapter_opts: fn _, _ ->
           {:error, %{code: "bounded", message: "bounded test refusal"}}
         end,
         db: ctx.db,
         name: :restart_generation_coalescing_coordinator}
      )

    key = {:cursor, "default", "testhost"}
    caller = Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
    assert_receive {:restart_generation_preflight, task}
    generation = :sys.get_state(coordinator).adapters[key].generation

    send(coordinator, {:restart_adapter, key, generation})
    send(coordinator, {:restart_adapter, key, generation})
    _ = :sys.get_state(coordinator)
    refute_receive {:restart_generation_preflight, _}

    send(task, :release)

    assert {:error, {:launch_refused, %{code: "bounded"}}} = Task.await(caller)
  end

  test "rendezvous does not release checkout before a delayed valid ready signal", ctx do
    path = Path.join(ctx.test_dir, "slow_ready.js")

    File.write!(path, """
    const rl = require("node:readline").createInterface({ input: process.stdin });
    const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\\n");
    rl.on("line", (line) => {
      const m = JSON.parse(line);
      if (m.method === "initialize") setTimeout(() => send({ id: m.id, result: { protocolVersion: 1 } }), 75);
    });
    """)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         readiness_timeout_ms: 500,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           [
             harness: :cursor,
             readiness_rendezvous: true,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir
           ]
         end,
         db: ctx.db,
         name: :slow_valid_readiness_coordinator}
      )

    started = System.monotonic_time(:millisecond)

    assert {:ok, _pid, 1} =
             AdapterCoordinator.adapter_for(coordinator, {:cursor, "default", "testhost"})

    assert System.monotonic_time(:millisecond) - started >= 50
  end

  test "hung live rendezvous child is terminated through its supervisor at deadline", ctx do
    path = Path.join(ctx.test_dir, "never_ready.js")

    File.write!(
      path,
      "process.stdin.resume(); process.stdin.on('end', () => process.exit(0)); setInterval(() => {}, 1000);\n"
    )

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         readiness_timeout_ms: 75,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           [
             harness: :cursor,
             readiness_rendezvous: true,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir
           ]
         end,
         db: ctx.db,
         name: :hung_child_readiness_coordinator}
      )

    assert {:error, {:launch_refused, %{code: "adapter_readiness_timeout"}}} =
             AdapterCoordinator.adapter_for(coordinator, {:cursor, "default", "testhost"})

    assert DynamicSupervisor.count_children(ctx.sup).active == 0
    Process.sleep(100)
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
    assert_receive {:adapter_opts, readiness_task, ^key, [credential_kind: :subscription]}
    refute readiness_task == adapter
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
    assert_receive {:boot_context, first_readiness, [credential_kind: :subscription]}
    refute first_readiness == first
    first_ref = Process.monitor(first)

    assert {:ok, second, 2} =
             AdapterCoordinator.adapter_for(coordinator, key, credential_kind: :api_key)

    refute second == first
    assert_receive {:DOWN, ^first_ref, :process, ^first, _reason}
    assert_receive {:boot_context, second_readiness, [credential_kind: :api_key]}
    refute second_readiness == second
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
