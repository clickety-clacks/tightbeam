defmodule GuardHarnessSwitchDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane_quiet, key}, _from, parent) do
    send(parent, {:ensure_lane_quiet, key})
    {:reply, :ok, parent}
  end

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardHarnessSwitch do
  import ExUnit.Assertions

  alias Tightbeam.{
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    Ledger,
    Model,
    ModelCatalog,
    Org,
    Projection
  }

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
        model: Model.new("fable")
      })

      prepare_codex!(base)
      {:ok, lane_registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)
      {:ok, tasks} = Task.Supervisor.start_link(name: Tightbeam.TurnTaskSupervisor)
      {:ok, lane} = GenServer.start_link(GuardHarnessSwitchDoorbell, self())
      # Existing synthetic adapter serves the replacement and subsequent turn without a provider.
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})

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

      try do
        # Synthetic catalog truth only; no credentials or provider are consulted.
        :sys.replace_state(catalog, fn state ->
          now = state.now.()

          cache = %{
            entries: [
              %{
                family: "gpt-5.6-sol",
                context: nil,
                display_name: "GPT",
                name: "GPT",
                efforts: ["medium"],
                max_input_tokens: 200_000,
                capabilities: %{},
                provider: :openai
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
              entries: %{{"testhost", "codex"} => cache}
          }
        end)

        exact_registry = Tightbeam.ConnRegistry

        for device <- ["d1"] do
          {:ok, _ref, nil} =
            ConnRegistry.register(exact_registry, %{
              pid: self(),
              user_id: "flynn",
              device_id: device,
              is_admin: false,
              subscriptions: MapSet.new(["chat"])
            })
        end

        config = %{
          config
          | default_harness: :claude,
            default_model: Model.new("claude-fable-5"),
            port: 0
        }

        config =
          Map.merge(config, %{
            conn_registry: exact_registry,
            lane_manager: lane,
            credential_status: fn _ -> :onboarded end,
            credential_kind: fn _ -> :subscription end,
            patch_adapter: fn _, _ -> :ok end
          })

        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        {:ok, session_lane} =
          Tightbeam.SessionLane.start_link(
            session_key: "k1",
            db: db,
            task_sup: tasks,
            runner: runner
          )

        try do
          prove(base, db, lane, exact_registry, runner, config, adapter)
        after
          GenServer.stop(session_lane)
        end
      after
        send(adapter, :continue_prompt)
        Supervisor.stop(tasks)
        Supervisor.stop(lane_registry)
        GenServer.stop(catalog)
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end

  defp prove(base, db, lane, exact_registry, runner, config, adapter) do
    local_host = Tightbeam.Placement.local_host_name()

    assert %{ok: true, harness: "codex", model: "gpt-5.6-sol", effort: "medium"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol",
                 effort: "medium"
               }
             })

    assert %{harness: "codex", provider: "openai", model: model} = Org.get(db, "k1")
    assert model == Model.new("gpt-5.6-sol", effort: "medium")

    home = Tightbeam.Homes.home_path(base, local_host, :codex)

    assert JSON.decode!(File.read!(Path.join([home, ".tightbeam", "manifest"])))["harness"] ==
             "codex"

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "next turn",
               db: db,
               conn_registry: exact_registry,
               lane_manager: lane,
               device_id: "d1",
               client_message_id: "after-harness-switch"
             )

    assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")
    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

    try do
      assert_receive {:adapter_key, {:codex, "shared", ^local_host}}, 1_000
      assert_receive {:new_session_mcp_servers, _mcp_servers}, 60_000
      assert_receive {:prompt_started, ^adapter}, 60_000

      send(adapter, :continue_prompt)
      assert {:ok, %{terminal_publish: publish}} = Task.await(task)
      assert :ok = Ledger.finish(db, turn.seq, "delivered")
      publish.("delivered")

      assert %{harness_session_id: "harness-1", harness: "codex"} =
               Org.current_pointer(db, "k1")
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp prepare_codex!(base) do
    %{input: %{profile: profile}} =
      Enum.find(
        Tightbeam.Harness.Codex.conformance_vectors()["ensure_adapter"],
        &(&1.case == "local_present")
      )

    package =
      Path.join(base, "adapters/node_modules/@agentclientprotocol/#{profile.adapter_package}")

    bundle = Path.join([package, "dist", profile.adapter_bundle])
    binary = Path.join(base, "adapters/node_modules/.bin/#{profile.adapter_bin}")
    File.mkdir_p!(Path.dirname(bundle))
    File.mkdir_p!(Path.dirname(binary))

    File.write!(
      Path.join(package, "package.json"),
      JSON.encode!(%{"version" => profile.adapter_version})
    )

    File.write!(bundle, profile.patched)
    File.write!(binary, "#!/bin/sh\necho forbidden >> \"$GUARD_TRIPWIRE\"\nexit 64\n")
    File.chmod!(binary, 0o755)
    home = Tightbeam.Homes.home_path(base, "testhost", :codex)
    File.mkdir_p!(home)
    File.write!(Path.join(home, "auth.json"), "test-token")
    File.chmod!(Path.join(home, "auth.json"), 0o600)
  end
end

GuardHarnessSwitch.run()
IO.puts("guarded-gateway-harness-switch: ok")
