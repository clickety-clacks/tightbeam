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

  test "five consecutive start failures open the circuit", ctx do
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_opts: fn _ ->
           [harness: :claude, cmd: [System.find_executable("false")], home: "/tmp", cwd: "/tmp"]
         end,
         db: ctx.db,
         name: :"coordinator_#{System.unique_integer([:positive])}"}
      )

    for _ <- 1..5,
        do:
          assert(
            {:error, :degraded} =
              AdapterCoordinator.adapter_for(coordinator, {:claude, "default"})
          )

    assert %{"claude:default" => %{circuit: :open, consecutive_failures: 5}} =
             AdapterCoordinator.health(coordinator)
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

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, {:claude, "default"})
    Process.exit(adapter, :kill)

    assert eventually(fn ->
             AdapterCoordinator.generation(coordinator, {:claude, "default"}) == 2
           end)

    assert [%{kind: "adapter_down", subject: "claude:default"}] =
             EventLog.lifecycle_events(ctx.db)
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
