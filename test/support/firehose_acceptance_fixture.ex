defmodule Tightbeam.FirehoseAcceptanceFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.ClientE2E.WS

  # Attach only to a DB already owned and admitted by the cold Application.
  # This helper creates no DB, copies no home, and launches no provider.
  def attach!(base) do
    db = Tightbeam.DB
    :ok = Tightbeam.DB.assert_base_admitted!(db, base)

    {:paired, device} =
      Tightbeam.Devices.pair(db, %{
        device_id: "a4-inventory",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    handlers = Tightbeam.Gateway.handlers(%{db: db, base_dir: base, wake_tick_ms: 1_000})
    token = "tbc_synthetic_inventory"

    opts =
      Tightbeam.Wire.Router.init(
        db: db,
        base_dir: base,
        handlers: handlers,
        cli_token: token,
        firehose_hub: Tightbeam.Firehose.Hub,
        model_catalog: %{
          {"testhost", "fixture"} => [
            %{family: "fixture-model", context: nil, efforts: [], provider: :fixture_provider}
          ],
          {"testhost", "claude"} => [
            %{family: "fable", context: nil, efforts: ["medium"], provider: :anthropic}
          ]
        },
        session_status: fn _ -> nil end
      )

    {:ok, gateway} =
      Supervisor.start_child(
        supervisor,
        {Bandit,
         plug: {Tightbeam.Wire.Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(gateway)

    %{
      base_dir: base,
      db: db,
      hub: Tightbeam.Firehose.Hub,
      supervisor: supervisor,
      device: device,
      user_id: device.user_id,
      cli_token: token,
      port: port
    }
  end

  def connect(fixture, opts \\ []) do
    {:ok, ws} = WS.connect("127.0.0.1", fixture.port, "/ws/changes?protocolVersion=1")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => fixture.device.token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => Keyword.get(opts, :subscription_id, "inventory"),
          "filters" => Keyword.get(opts, :filters, %{"classes" => ["work_item."]})
        })
      )

    {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "subscription_ready"} = JSON.decode!(ready)
    ws
  end

  def recv_change(ws) do
    case WS.recv_event(ws, 2_000) do
      {:ok, {:text, bytes}, ws} ->
        case JSON.decode!(bytes) do
          %{"type" => "change"} = notice -> {notice, ws}
          _ -> recv_change(ws)
        end

      other ->
        flunk("inventory socket closed before notice: #{inspect(other)}")
    end
  end

  def create_item(fixture, title) do
    body =
      JSON.encode!(%{
        "verb" => "work-item-create",
        "asUser" => fixture.user_id,
        "params" => %{"title" => title}
      })

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> fixture.cli_token)},
      {~c"x-tightbeam-cli-version",
       String.to_charlist(Tightbeam.CliCompatibility.required_version())}
    ]

    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{fixture.port}/agent/dispatch", headers, ~c"application/json",
         body},
        [timeout: 2_000],
        body_format: :binary
      )

    %{"result" => %{"id" => id}} = JSON.decode!(raw)
    id
  end
end
