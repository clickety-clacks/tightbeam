defmodule Tightbeam.FirehoseSmokeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ClientE2E.WS
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router
  alias Tightbeam.{DB, Gateway, Rules}

  setup do
    db = :firehose_smoke_db
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: Hub})
    :ok = Tightbeam.Schema.ensure_all(db)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-firehose-smoke-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    {:paired, device} =
      claim_org(db, %{
        device_id: "smoke-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, wake_tick_ms: 1_000})
    Rules.load!(Path.join(base_dir, "no-rules"), Map.keys(handlers))
    on_exit(fn -> Rules.load!(Path.join(base_dir, "reset-rules"), []) end)

    router_opts =
      Router.init(
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_firehose_smoke",
        firehose_hub: Hub,
        session_status: fn _ -> nil end
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    %{device: device, port: port}
  end

  test "external subscribe, query rebuild, live apply, and forced reconnect converge", ctx do
    ws = connect(ctx)
    snapshot = snapshot(ctx.port)
    assert snapshot == %{}

    first = create_item(ctx.port, "First live item")
    {notice, ws} = recv_change(ws)
    assert notice["class"] == "work_item.created"
    model = Map.put(snapshot, notice["refs"]["workItemId"], notice["payload"])
    assert Map.keys(model) == [first]
    assert Map.keys(model) |> Enum.sort() == snapshot(ctx.port) |> Map.keys() |> Enum.sort()

    :ok = WS.close(ws)
    second = create_item(ctx.port, "Committed while disconnected")

    ws = connect(ctx)
    rebuilt = snapshot(ctx.port)
    assert Enum.sort(Map.keys(rebuilt)) == Enum.sort([first, second])

    third = create_item(ctx.port, "After reconnect")
    {notice, ws} = recv_change(ws)
    rebuilt = Map.put(rebuilt, notice["refs"]["workItemId"], notice["payload"])
    assert Enum.sort(Map.keys(rebuilt)) == Enum.sort([first, second, third])
    assert rebuilt == snapshot(ctx.port)
    :ok = WS.close(ws)
  end

  defp connect(ctx) do
    {:ok, ws} = WS.connect("127.0.0.1", ctx.port, "/ws/changes?protocolVersion=1")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => ctx.device.token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "work-items",
          "filters" => %{"classes" => ["work_item."]}
        })
      )

    {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "subscription_ready"} = JSON.decode!(ready)
    ws
  end

  defp recv_change(ws) do
    {:ok, {:text, bytes}, ws} = WS.recv(ws, 2_000)
    notice = JSON.decode!(bytes)
    assert notice["type"] == "change"
    {notice, ws}
  end

  defp create_item(port, title) do
    %{"result" => %{"id" => id}} =
      dispatch(port, "work-item-create", %{"title" => title})

    id
  end

  defp snapshot(port) do
    %{"result" => %{"workItems" => items}} = dispatch(port, "work-item-list", %{})
    Map.new(items, &{&1["id"], Tightbeam.StateResources.work_item(&1)})
  end

  defp dispatch(port, verb, params) do
    body = JSON.encode!(%{"verb" => verb, "asUser" => "flynn", "params" => params})
    url = ~c"http://127.0.0.1:#{port}/agent/dispatch"

    {:ok, {{_version, 200, _reason}, _headers, response}} =
      :httpc.request(
        :post,
        {url,
         [
           {~c"authorization", ~c"Bearer tbc_firehose_smoke"},
           {~c"x-tightbeam-cli-version",
            String.to_charlist(Tightbeam.CliCompatibility.required_version())},
           {~c"content-type", ~c"application/json"}
         ], ~c"application/json", body},
        [{:timeout, 2_000}],
        body_format: :binary
      )

    JSON.decode!(response)
  end
end
