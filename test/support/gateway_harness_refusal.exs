defmodule GatewayHarnessRefusal do
  import ExUnit.Assertions

  alias Tightbeam.{Acp.Adapter, Gateway, Model, ModelCatalog, Org, Rules}
  alias Tightbeam.ClientE2E.SimClient
  alias Tightbeam.GatewayTurnFixture.CoordinatorStub
  alias Tightbeam.Wire.Router

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      start_dependencies(base, db)

      config = Map.put(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)

      {Tightbeam.LaneManager, lane_opts} =
        Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

      handlers = Gateway.handlers(config)
      Rules.load!(base, Map.keys(handlers))

      opts =
        Keyword.merge(lane_opts,
          interval: 60_000,
          on_terminal: fn _session_key, _seq -> :ok end
        )

      {:ok, lane_manager} = Tightbeam.LaneManager.start_link(opts)
      token =
        base
        |> Path.join("gateway.json")
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("cliToken")

      router_opts =
        Router.init(
          db: db,
          base_dir: base,
          handlers: handlers,
          conn_registry: Tightbeam.ConnRegistry,
          cli_token: token,
          adapter_coordinator: Tightbeam.AdapterCoordinator,
          session_status: fn _key -> nil end,
          defaults: %{
            archetype: "default",
            host: "testhost",
            harness: :fixture,
            provider: fn -> :fixture_provider end,
            model: Model.new("fixture-model")
          }
        )

      {:ok, server} =
        Bandit.start_link(
          plug: {Router, router_opts},
          port: 0,
          ip: {127, 0, 0, 1},
          startup_log: false
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)

      {:ok, device} =
        SimClient.pair("127.0.0.1", port,
          device_id: "context-refusal-device",
          claimed_name: "Fixture"
        )

      {:ok, client} =
        SimClient.connect("127.0.0.1", port, device.token,
          device_id: "context-refusal-device"
        )
      session_key = Org.personal_session_key(device.user_id)
      content = String.duplicate("x", 65_537)
      watermark = SimClient.mark(client)
      {:ok, client, message_id} = SimClient.post(client, session_key, content)

      {:ok, ack, client} =
        SimClient.await(
          client,
          watermark,
          &(&1["type"] == "ack" and &1["id"] == message_id),
          10_000
        )

      assert ack["id"] == message_id

      {:ok, failure, client} =
        SimClient.await(
          client,
          watermark,
          fn frame ->
            frame["type"] == "event" and frame["event"] == "prompt_turn_state" and
              get_in(frame, ["payload", "messageId"]) == message_id and
              get_in(frame, ["payload", "state"]) == "failed"
          end,
          30_000
        )

      payload = failure["payload"]
      assert payload["messageId"] == message_id
      assert payload["correlationId"] == message_id
      assert payload["terminalState"] == true
      assert payload["state"] == "failed"

      reason = payload["error"] |> JSON.encode!()
      assert reason =~ "context_length_exceeded"
      assert File.regular?(Path.join(base, "harness-request.json"))
      assert File.read!(Path.join(base, "harness-request.json.exit")) == "1"

      captured =
        base
        |> Path.join("harness-request.json")
        |> File.read!()
        |> JSON.decode!()

      assert captured["method"] == "session/prompt"

      prompt =
        captured["params"]["prompt"]
        |> Enum.map(& &1["text"])
        |> Enum.join("\n")

      assert prompt == content
      assert byte_size(prompt) == 65_537
      assert {:ok, [[^content, 65_537]]} =
               Tightbeam.DB.query(
                 db,
                 "SELECT content, length(CAST(content AS BLOB)) FROM messages WHERE clientMessageId = ?1",
                 [message_id]
               )

      assert {:ok, [["failed"]]} =
               Tightbeam.DB.query(
                 db,
                 "SELECT status FROM turns WHERE messageId = (SELECT id FROM messages WHERE clientMessageId = ?1)",
                 [message_id]
               )

      SimClient.disconnect(client)
      GenServer.stop(server)
      GenServer.stop(lane_manager)
      IO.puts("gateway-harness-refusal: ok")
    end)
  end

  defp start_dependencies(base, db) do
    {:ok, _lane_registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)

    {:ok, _lane_supervisor} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Tightbeam.LaneSupervisor)

    {:ok, _task_supervisor} = Task.Supervisor.start_link(name: Tightbeam.TurnTaskSupervisor)
    {:ok, _episodes} = Tightbeam.RailEpisodes.start_link(name: Tightbeam.RailEpisodes)
    {:ok, _observations} = Tightbeam.TurnObservations.start_link(name: Tightbeam.TurnObservations)
    {:ok, _hub} = Tightbeam.Firehose.Hub.start_link(name: Tightbeam.Firehose.Hub)

    {:ok, catalog} =
      ModelCatalog.start_link(
        base_dir: base,
        db: db,
        hosts: fn -> %{} end,
        credential_status: fn _ -> flunk("unexpected credential probe") end,
        credential_kind: fn _ -> flunk("unexpected credential-kind probe") end,
        sh: fn _ -> flunk("unexpected catalog shell") end,
        claude_fetch: fn _, _ -> flunk("unexpected catalog fetch") end
      )

    Tightbeam.GuardGatewayFixture.seed_catalog!(catalog, fn state ->
      now = state.now.()

      cache = %{
        entries: [
          %{
            family: "fixture-model",
            context: nil,
            display_name: "Fixture Model",
            name: "Fixture Model",
            efforts: [],
            max_input_tokens: 1_024,
            capabilities: %{},
            provider: :fixture_provider
          }
        ],
        derived_at: now,
        attempted_at: now,
        reason: nil,
        refreshing: true
      }

      %{
        state
        | hosts: fn -> %{"testhost" => %{base_dir: base, ssh: nil}} end,
          entries: %{{"testhost", "fixture"} => cache}
      }
    end)

    capture = Path.join(base, "harness-request.json")
    fixture = Path.join(Path.dirname(__ENV__.file), "gateway_refusal_harness.js")
    node = System.find_executable("node") || raise "node is required for the local harness process"

    {:ok, adapter} =
      Adapter.start_link(
        harness: :fixture,
        cmd: [node, fixture, capture],
        home: base,
        cwd: base,
        name: :gateway_refusal_adapter
      )

    {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
    :ok
  end
end

GatewayHarnessRefusal.run()
