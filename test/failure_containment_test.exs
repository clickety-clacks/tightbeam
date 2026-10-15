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

  alias Tightbeam.ClientE2E.WS

  defmodule HealthPlug do
    def init(opts), do: opts

    def call(%{request_path: "/changes"} = conn, deps) do
      conn
      |> WebSockAdapter.upgrade(Tightbeam.Wire.ChangeSocket, deps, [])
      |> Plug.Conn.halt()
    end

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
        plug: {HealthPlug, %{db: db, firehose_hub: __MODULE__.Hub, model_catalog: %{}}},
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

    {:paired, device} =
      Tightbeam.Devices.pair(db, %{device_id: "containment", claimed_name: "Client"})

    ws = subscribe(port, device.token)

    for id <- [Firehose.Hub, ModelCatalog, SentinelSupervisor] do
      before = Map.new(Supervisor.which_children(runtime), fn {id, pid, _, _} -> {id, pid} end)
      old = Map.fetch!(before, id)
      Process.exit(old, :kill)

      assert eventually(fn ->
               replacement = child(runtime, id)
               is_pid(replacement) and replacement != old and Process.alive?(replacement)
             end)

      if id == Firehose.Hub do
        assert {:ok, {:closed, 1012}, _} = WS.recv_event(ws, 2_000)
        WS.close(ws)
        resumed = subscribe(port, device.token)

        {:ok, _} = DB.query(db, """
        INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt)
        VALUES ('wi_restart','Restart delivery',?1,'open',?1,1)
        """, [device.user_id])

        notice = %{
          "class" => "work_item.updated",
          "resource" => "work-items",
          "op" => "upsert",
          "occurredAt" => 1,
          "refs" => %{"workItemId" => "wi_restart", "ownerUserId" => device.user_id},
          "payload" => %{"id" => "wi_restart"}
        }

        Firehose.Hub.publish(__MODULE__.Hub, notice)
        assert {:ok, {:text, bytes}, _} = WS.recv(resumed, 2_000)
        frame = JSON.decode!(bytes)
        assert frame["class"] == "work_item.updated"
        assert frame["payload"]["id"] == "wi_restart"
        WS.close(resumed)
      end

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

  defp subscribe(port, token) do
    {:ok, ws} = WS.connect("127.0.0.1", port, "/changes")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => token}))
    assert {:ok, {:text, bytes}, ws} = WS.recv(ws, 2_000)
    assert %{"success" => true} = JSON.decode!(bytes)
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "subscribe", "subscriptionId" => "all"}))
    assert {:ok, {:text, bytes}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "subscription_ready"} = JSON.decode!(bytes)
    ws
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
