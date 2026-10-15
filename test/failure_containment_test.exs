defmodule Tightbeam.FailureContainmentTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Firehose,
    ListenerLifecycle,
    ModelCatalog,
    Schema,
    SentinelSupervisor,
    Wakes
  }

  defmodule HealthPlug do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  @tag :tmp_dir
  test "service crashes preserve the listener, scheduler and other services", %{tmp_dir: tmp} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    children = [
      {Firehose.Hub, name: __MODULE__.Hub},
      {ModelCatalog, name: __MODULE__.Catalog, base_dir: tmp, hosts: fn -> %{} end},
      {Wakes, db: db, deliver: fn _ -> :ok end, name: __MODULE__.Scheduler, tick_ms: 60_000},
      {DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.Adapters},
      {SentinelSupervisor, db: db, base_dir: tmp, cli_bin: "unused", name: __MODULE__.Sentinels},
      ListenerLifecycle.listener_spec(
        plug: HealthPlug,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )
    ]

    root =
      start_supervised!(%{
        id: :containment_root,
        start:
          {Supervisor, :start_link,
           [
             [Tightbeam.Application.runtime_child(children)],
             Keyword.delete(Tightbeam.Application.root_opts(), :name)
           ]}
      })

    [{Tightbeam.RuntimeSupervisor, runtime, _, _}] = Supervisor.which_children(root)
    listener = child(runtime, Bandit)
    scheduler = Process.whereis(__MODULE__.Scheduler)
    adapters = Process.whereis(__MODULE__.Adapters)
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)

    for id <- [Firehose.Hub, ModelCatalog, SentinelSupervisor] do
      before = Map.new(Supervisor.which_children(runtime), fn {id, pid, _, _} -> {id, pid} end)
      old = Map.fetch!(before, id)
      Process.exit(old, :kill)

      assert eventually(fn ->
               replacement = child(runtime, id)
               is_pid(replacement) and replacement != old and Process.alive?(replacement)
             end)

      assert child(runtime, Bandit) == listener
      assert Process.whereis(__MODULE__.Scheduler) == scheduler
      assert Process.whereis(__MODULE__.Adapters) == adapters
      for {other, pid} <- Map.delete(before, id), do: assert(child(runtime, other) == pid)

      assert {:ok, socket} =
               :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

      :ok =
        :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

      assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
      assert response =~ "200 OK"
      :gen_tcp.close(socket)
    end
  end

  defp child(supervisor, id) do
    {^id, pid, _, _} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end

  defp eventually(fun, tries \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end
end
