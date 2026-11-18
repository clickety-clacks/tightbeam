defmodule Tightbeam.VersionAdapterHealthTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, AdapterHealthSnapshot, DB, Wire.Router}

  @fake ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  setup do
    db = :"version_health_db_#{System.unique_integer([:positive])}"
    sup = :"version_health_sup_#{System.unique_integer([:positive])}"
    coordinator = :"version_health_coordinator_#{System.unique_integer([:positive])}"

    test_dir =
      Path.join(System.tmp_dir!(), "version-adapter-health-#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    script = Path.join(test_dir, "adapter.js")
    File.write!(script, @fake)
    AdapterHealthSnapshot.clear(coordinator)
    previous_circuit = Application.get_env(:tightbeam, :adapter_failure_circuit)
    Application.put_env(:tightbeam, :adapter_failure_circuit, 10)

    on_exit(fn ->
      AdapterHealthSnapshot.clear(coordinator)
      File.rm_rf!(test_dir)

      if previous_circuit == nil,
        do: Application.delete_env(:tightbeam, :adapter_failure_circuit),
        else: Application.put_env(:tightbeam, :adapter_failure_circuit, previous_circuit)
    end)

    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})

    listener =
      start_supervised!(
        {Bandit,
         plug: {Router, [adapter_coordinator: coordinator]},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    %{db: db, sup: sup, coordinator: coordinator, test_dir: test_dir, script: script, port: port}
  end

  test "/version reads the last published health while the coordinator is suspended or absent",
       ctx do
    assert %{"adapters" => %{}, "adaptersAsOf" => nil} = version(ctx.port)

    Application.put_env(:tightbeam, :adapter_failure_circuit, 1)
    # Keep autonomous circuit retries outside this short snapshot-read probe.
    # The restart-loop test below still uses the normal fast retry setting.
    coordinator = start_coordinator(ctx, backoff_base_ms: 60_000)
    key = {:claude, "shared", "testhost"}
    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(ctx.coordinator, key)
    assert wait_until(fn -> AdapterCoordinator.ready?(ctx.coordinator, key) end)

    Process.exit(adapter, :kill)

    assert wait_until(fn ->
             AdapterCoordinator.health(ctx.coordinator)["claude:shared@testhost"].circuit == :open
           end)

    expected = AdapterCoordinator.health(ctx.coordinator)["claude:shared@testhost"]
    assert expected.consecutive_failures == 1

    before = version(ctx.port)

    assert before["adapters"]["claude:shared@testhost"] == %{
             "generation" => expected.generation,
             "circuit" => Atom.to_string(expected.circuit),
             "consecutiveFailures" => expected.consecutive_failures
           }

    assert is_integer(before["adaptersAsOf"])

    :ok = :sys.suspend(coordinator)

    try do
      {:message_queue_len, queued_before} = Process.info(coordinator, :message_queue_len)
      {elapsed_us, suspended_body} = :timer.tc(fn -> version(ctx.port) end)
      {:message_queue_len, queued_after} = Process.info(coordinator, :message_queue_len)

      assert elapsed_us < 1_000_000
      assert suspended_body["adapters"] == before["adapters"]
      assert suspended_body["adaptersAsOf"] == before["adaptersAsOf"]
      assert queued_after == queued_before
    after
      :ok = :sys.resume(coordinator)
    end

    :ok = stop_supervised(ctx.coordinator)

    absent_body = version(ctx.port)
    assert absent_body["adapters"] == before["adapters"]
    assert absent_body["adaptersAsOf"] == before["adaptersAsOf"]

    refute Process.alive?(adapter)
    _replacement = start_coordinator(ctx)
    restarted_body = version(ctx.port)
    assert restarted_body["adapters"] == %{}
    assert is_integer(restarted_body["adaptersAsOf"])
  end

  @tag timeout: 60_000
  test "/version stays responsive through repeated adapter crashes and restarts", ctx do
    _coordinator = start_coordinator(ctx)
    key = {:claude, "shared", "testhost"}
    assert {:ok, adapter, generation} = AdapterCoordinator.adapter_for(ctx.coordinator, key)
    assert wait_until(fn -> AdapterCoordinator.ready?(ctx.coordinator, key) end)

    parent = self()

    samples =
      Task.async(fn ->
        first = :timer.tc(fn -> version(ctx.port) end)
        send(parent, :sampling_started)
        sample_versions(ctx.port, [first])
      end)

    assert_receive :sampling_started

    {final_adapter, final_generation} =
      Enum.reduce(1..3, {adapter, generation}, fn _, {current, prior_generation} ->
        Process.exit(current, :kill)

        replacement =
          Task.async(fn -> AdapterCoordinator.adapter_for(ctx.coordinator, key) end)

        assert {:ok, next, next_generation} = Task.await(replacement, 10_000)
        assert next != current
        assert next_generation > prior_generation
        assert wait_until(fn -> AdapterCoordinator.ready?(ctx.coordinator, key) end)
        Process.sleep(100)
        {next, next_generation}
      end)

    assert Process.alive?(final_adapter)
    assert final_generation > generation

    send(samples.pid, :stop_sampling)
    readings = Task.await(samples, 10_000)
    assert length(readings) >= 3

    assert Enum.all?(readings, fn {elapsed_us, body} ->
             elapsed_us < 1_000_000 and is_integer(body["adaptersAsOf"])
           end)

    assert readings
           |> Enum.map(fn {_, body} -> body["adaptersAsOf"] end)
           |> Enum.uniq()
           |> length() > 1

    generations =
      readings
      |> Enum.map(fn {_, body} -> body["adapters"]["claude:shared@testhost"]["generation"] end)
      |> Enum.uniq()

    assert length(generations) > 1
    max_latency_us = readings |> Enum.map(&elem(&1, 0)) |> Enum.max()
    IO.puts("version crash loop: requests=#{length(readings)} max_latency_us=#{max_latency_us}")
  end

  defp start_coordinator(ctx, overrides \\ []) do
    start_supervised!(
      {AdapterCoordinator,
       Keyword.merge(
         [
           adapter_sup: ctx.sup,
           adapter_context: fn _ -> [] end,
           adapter_opts: fn _, _ ->
             [
               harness: :claude,
               cmd: [System.find_executable("node"), ctx.script],
               home: ctx.test_dir,
               cwd: ctx.test_dir
             ]
           end,
           db: ctx.db,
           backoff_base_ms: 40,
           name: ctx.coordinator
         ],
         overrides
       )}
    )
  end

  defp version(port) do
    url = String.to_charlist("http://127.0.0.1:#{port}/version")

    assert {:ok, {{_, 200, _}, _headers, body}} =
             :httpc.request(:get, {url, []}, [timeout: 2_000], body_format: :binary)

    JSON.decode!(body)
  end

  defp sample_versions(port, readings) do
    reading = :timer.tc(fn -> version(port) end)

    receive do
      :stop_sampling -> Enum.reverse([reading | readings])
    after
      25 -> sample_versions(port, [reading | readings])
    end
  end

  defp wait_until(fun, tries \\ 1_000) do
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
end
