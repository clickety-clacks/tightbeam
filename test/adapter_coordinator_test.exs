defmodule Tightbeam.AdapterCoordinatorTest do
  use ExUnit.Case, async: false

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
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    %{db: db, sup: sup}
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

    assert wait_until(fn ->
             match?(
               %{"claude:default@testhost" => %{circuit: :open}},
               AdapterCoordinator.health(coordinator)
             )
           end)

    assert {:error, :degraded} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    assert %{"claude:default@testhost" => %{consecutive_failures: failures}} =
             AdapterCoordinator.health(coordinator)

    assert failures >= 5
  end

  test "containment refusal in adapter_opts takes the uniform degraded path", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         backoff_base_ms: 1,
         adapter_opts: fn _ -> raise ArgumentError, "contained_remote_unsupported" end,
         db: ctx.db,
         name: :"containment_coord_#{System.unique_integer([:positive])}"}
      )

    key = {:codex, "contained", "worker"}
    assert {:ok, _pid, _generation} = AdapterCoordinator.adapter_for(coordinator, key)

    assert wait_until(fn ->
             match?(
               %{"codex:contained@worker" => %{circuit: :open}},
               AdapterCoordinator.health(coordinator)
             )
           end)

    assert {:error, :degraded} = AdapterCoordinator.adapter_for(coordinator, key)

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "adapter_down")) >= 5
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
               %{"claude:default@testhost" =>
                   %{circuit: :open, consecutive_failures: 1}},
               AdapterCoordinator.health(coordinator)
             )
           end)
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

  test "harness OS-process death (acp_exit) kills the adapter — no silent wedge", ctx do
    path =
      Path.join(
        System.tmp_dir!(),
        "coordinator_acp_exit_#{System.unique_integer([:positive])}.js"
      )

    File.write!(path, @fake)
    stderr_path = path <> ".stderr.log"

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: "/tmp",
             cwd: "/tmp",
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
             AdapterCoordinator.generation(coordinator, {:claude, "default", "testhost"}) == 2
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

  test "adapter death bumps generation and records lifecycle", ctx do
    path =
      Path.join(System.tmp_dir!(), "coordinator_adapter_#{System.unique_integer([:positive])}.js")

    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: "/tmp",
             cwd: "/tmp"
           ]
         end,
         db: ctx.db,
         name: :"coordinator_#{System.unique_integer([:positive])}"}
      )

    assert {:ok, adapter, 1} =
             AdapterCoordinator.adapter_for(coordinator, {:claude, "default", "testhost"})

    Process.exit(adapter, :kill)

    assert eventually(fn ->
             AdapterCoordinator.generation(coordinator, {:claude, "default", "testhost"}) == 2
           end)

    assert [%{kind: "adapter_down", subject: "claude:default@testhost"}] =
             EventLog.lifecycle_events(ctx.db)
  end

  test "planned close tears down the adapter without crash restart bookkeeping", ctx do
    path =
      Path.join(System.tmp_dir!(), "coordinator_close_#{System.unique_integer([:positive])}.js")

    File.write!(path, @fake)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: "/tmp",
             cwd: "/tmp"
           ]
         end,
         db: ctx.db,
         name: :planned_close_coordinator}
      )

    key = {:claude, "default", "testhost"}
    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    ref = Process.monitor(adapter)

    assert :ok = AdapterCoordinator.close_adapter(coordinator, key)
    assert_receive {:DOWN, ^ref, :process, ^adapter, _reason}, 2_000
    assert AdapterCoordinator.generation(coordinator, key) == 1
    assert EventLog.lifecycle_events(ctx.db) == []
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

    {:ok, counts} = Agent.start_link(fn -> %{active: 0, max: 0} end)

    tasks =
      for _ <- 1..6 do
        Task.async(fn ->
          AdapterCoordinator.with_load_slot(coordinator, fn ->
            Agent.update(counts, fn s ->
              %{active: s.active + 1, max: max(s.max, s.active + 1)}
            end)

            Process.sleep(40)
            Agent.update(counts, &%{&1 | active: &1.active - 1})
          end)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 2_000))
    assert Agent.get(counts, & &1.max) == 3
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
        AdapterCoordinator.with_load_slot(coordinator, fn ->
          send(parent, :first_entered)
          receive do: (:release_first -> :ok)
        end)
      end)

    assert_receive :first_entered

    second =
      Task.async(fn ->
        AdapterCoordinator.with_load_slot(coordinator, fn -> send(parent, :second_entered) end)
      end)

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
