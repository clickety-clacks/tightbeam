defmodule GuardHomePinDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardHomePin do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, Gateway, Identity, Ledger, Model, Org}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      Org.create(db, %{
        session_key: "k1",
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("claude-fable-5")
      })

      {:ok, lane} = GenServer.start_link(GuardHomePinDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link(adapter)
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "home-pin",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        manifest_path = Path.join([base, "identity", "archetypes", "default.toml"])

        manifest =
          manifest_path
          |> File.read!()
          |> String.replace("name = \"default\"", "name = \"default\"\nwhere = [\"testhost\"]")

        identity_edit!(base, "default", :manifest, manifest, "test")

        # Org default is claude-fable-5 (gateway_config); the session SELECTED a
        # different catalog model. The provisioned home must follow the selection.
        _ = Org.set_model(db, "k1", Model.new("claude-sonnet-4-6"), "anthropic")
        assert Org.get(db, "k1").model == Model.new("claude-sonnet-4-6")

        config = %{
          config
          | default_harness: :claude,
            default_model: Model.new("claude-fable-5"),
            port: 0
        }

        assert config.default_model.family == "claude-fable-5"

        children = Gateway.children(config)

        {Tightbeam.LaneManager, lane_opts} =
          Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "ping",
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "home-pin",
                   client_message_id: "c_home_pin"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")
        task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

        try do
          # new_session having been reached proves harness_session ran the pin first.
          assert_receive {:new_session_mcp_servers, _}, 60_000

          settings =
            [base, "homes", "testhost", "claude", "settings.json"]
            |> Path.join()
            |> File.read!()
            |> JSON.decode!()

          assert settings["model"] == "claude-sonnet-4-6"

          assert_receive {:prompt_started, ^adapter}, 60_000
          send(adapter, :continue_prompt)
          assert {:ok, _} = Task.await(task)
        after
          Task.shutdown(task, :brutal_kill)
        end
      after
        send(adapter, :continue_prompt)
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end

  defp identity_edit!(base, archetype, target, content, author) do
    candidate = Identity.edit!(base, archetype, target, content, author)
    assert {:ok, revision} = Identity.publish_live!(base, candidate)
    revision
  end
end

GuardHomePin.run()
IO.puts("guarded-gateway-home-pin: ok")
