defmodule GuardRemoteUrlDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardRemoteUrl do
  import ExUnit.Assertions
  import Tightbeam.TestCase, only: [register_hosts: 2]
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

      {:ok, lane} = GenServer.start_link(GuardRemoteUrlDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link(adapter)
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "remote-url",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        manifest_path = Path.join([base, "identity", "archetypes", "default.toml"])

        manifest =
          manifest_path
          |> File.read!()
          |> String.replace(
            "name = \"default\"",
            "name = \"default\"\nwhere = [\"testhost\", \"worker\"]"
          )

        identity_edit!(base, "default", :manifest, manifest, "test")

        parent = self()

        sh = fn command ->
          assert_synthetic_command!(command)

          if hd(command) == "rsync" do
            stage_file = Enum.at(command, -2)

            if String.contains?(stage_file, "/staging/session-files/") do
              assert String.starts_with?(
                       Path.expand(stage_file),
                       Path.join(base, "staging/session-files") <> "/"
                     )

              assert File.lstat!(stage_file).type == :regular
              assert Bitwise.band(File.stat!(stage_file).mode, 0o777) == 0o600
              send(parent, {:delivered_session_file, File.read!(stage_file)})
            end
          end

          if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
               Enum.any?(command, &String.contains?(&1, "cat")),
             do: {"", 42},
             else: {"", 0}
        end

        sh_out = fn command ->
          assert_synthetic_command!(command)

          if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
               Enum.any?(command, &String.contains?(&1, "cat")),
             do: {"", 42},
             else: {"", 0}
        end

        config =
          Map.merge(config, %{
            default_harness: :claude,
            default_model: Model.new("claude-fable-5"),
            credential_status: fn _ -> :onboarded end,
            credential_kind: fn _ -> :subscription end,
            patch_adapter: fn _, _ -> :ok end
          })
          |> Map.put(:sh, sh)
          |> Map.put(:sh_out, sh_out)

        children = Gateway.children(config)

        {Tightbeam.LaneManager, lane_opts} =
          Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        Application.put_env(:tightbeam, :advertised_url, "https://new-gateway.example")

        register_hosts(db, %{
          "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
        })

        assert %{ok: true, host: "worker"} =
                 Gateway.handlers(config)["tune"].(%{
                   origin: "user:flynn",
                   session_key: "k1",
                   params: %{setting: "set_host", host: "worker"}
                 })

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "remote ping",
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "d1",
                   client_message_id: "c_remote_url"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")
        task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

        try do
          token = Org.get(db, "k1").cli_token

          assert_receive {:delivered_session_file, content}, 60_000

          assert JSON.decode!(content) == %{
                   "url" => "https://new-gateway.example",
                   "token" => token,
                   "sessionKey" => "k1"
                 }

          # Proven late, not lost -- see 60_000 for the measurement.
          assert_receive {:prompt_started, ^adapter}, 60_000
          send(adapter, :continue_prompt)
          assert {:ok, %{terminal_publish: publish}} = Task.await(task)
          assert :ok = Ledger.finish(db, turn.seq, "delivered")
          publish.("delivered")
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

  # Never execute these argv. They describe a fictional worker to a synthetic callback.
  defp assert_synthetic_command!([program | args]) do
    assert program in ["ssh", "rsync"]
    assert Enum.any?(args, &(&1 == "worker" or String.starts_with?(&1, "worker:")))
    refute Enum.any?(args, &String.contains?(&1, "npm install"))
  end

  defp identity_edit!(base, archetype, target, content, author) do
    candidate = Identity.edit!(base, archetype, target, content, author)
    assert {:ok, revision} = Identity.publish_live!(base, candidate)
    revision
  end
end

GuardRemoteUrl.run()
IO.puts("guarded-gateway-remote-url: ok")
