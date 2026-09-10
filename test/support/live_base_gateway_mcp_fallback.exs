defmodule GuardMcpDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardMcpFallback do
  import ExUnit.Assertions
  alias Tightbeam.{Archetypes, ConnRegistry, Gateway, Identity, Ledger, Model, Org, Placement}
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

      {:ok, lane} = GenServer.start_link(GuardMcpDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "golden",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        config = %{config | port: 0}
        put_skill!(base, "review", "# Review")
        manifest_path = Path.join([base, "identity", "archetypes", "default.toml"])

        identity_edit!(
          base,
          "default",
          :manifest,
          File.read!(manifest_path) <>
            """

            [mcp.xcodebuild]
            command = "xcodebuildmcp"
            args = ["--daemon"]
            env = { XCODEBUILD_MCP_MODE = "cli" }
            """,
          "test"
        )

        children = Gateway.children(config)
        archetype = Archetypes.get("default")

        {:ok, overrides} =
          Archetypes.normalize_overrides(base, archetype, %{"skills_add" => ["review"]})

        identity_name = Placement.identity_name(config, archetype, overrides, :claude)
        Org.set_identity(db, "k1", overrides, identity_name)

        {_archetypes, fragments} = :persistent_term.get(Archetypes)
        :persistent_term.put(Archetypes, {%{}, fragments})
        refute Archetypes.get("default")
        assert archetype.mcp != []
        assert Archetypes.builtin_default().mcp == []

        {Tightbeam.LaneManager, lane_opts} =
          Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "ping",
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "golden",
                   client_message_id: "c_gold"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

        task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

        try do
          assert_receive {:adapter_key, {:claude, "shared", "testhost"}}, 1_000

          assert_receive {:new_session_mcp_servers, []}, 60_000

          # Four ms behind the wait above in every sample: the forks are already paid.
          assert_receive {:prompt_started, ^adapter}, 60_000

          digest =
            :crypto.hash(:sha256, "k1")
            |> Base.encode16(case: :lower)
            |> binary_part(0, 12)

          session_file = Path.join([base, "work", digest, ".tightbeam-session"])

          assert File.read!(session_file) ==
                   JSON.encode!(%{
                     url: "http://127.0.0.1:0",
                     token: Org.get(db, "k1").cli_token,
                     sessionKey: "k1"
                   })

          assert Bitwise.band(File.stat!(session_file).mode, 0o777) == 0o600
          send(self(), {:push, Tightbeam.Wire.Payloads.ack("c_gold")})
          send(adapter, :continue_prompt)
          assert {:ok, %{terminal_publish: publish}} = Task.await(task)
          assert :ok = Ledger.finish(db, turn.seq, "delivered")
          publish.("delivered")

          frames = collect_pushes(10, [])

          assert Enum.map(frames, &frame_name/1) == [
                   "message:user",
                   "turn:accepted",
                   "turn:running",
                   "typing:true",
                   "activity:true",
                   "ack",
                   "message:assistant",
                   "turn:delivered",
                   "typing:false",
                   "activity:false"
                 ]
        after
          Task.shutdown(task, :brutal_kill)
        end
      after
        # Unblock a failed controller's adapter before synchronous teardown.
        send(adapter, :continue_prompt)
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end

  defp put_skill!(base, name, body) do
    Identity.init!(base)
    identity_edit!(base, "default", {:skill, name, false}, body, "test")
    Archetypes.load!(base)
  end

  defp identity_edit!(base, archetype, target, content, author) do
    candidate = Identity.edit!(base, archetype, target, content, author)
    assert {:ok, revision} = Identity.publish_live!(base, candidate)
    revision
  end

  defp collect_pushes(0, acc), do: Enum.reverse(acc)

  defp collect_pushes(n, acc) do
    receive do
      {:push, payload} -> collect_pushes(n - 1, [payload | acc])
      {:push_message, _key, _seq, payload} -> collect_pushes(n - 1, [payload | acc])
      {:ensure_lane, _key} -> collect_pushes(n, acc)
    after
      1_000 -> flunk("timed out collecting golden frames")
    end
  end

  defp frame_name(%{"type" => "message", "role" => role}), do: "message:#{role}"

  defp frame_name(%{
         "type" => "event",
         "event" => "prompt_turn_state",
         "payload" => %{"state" => state}
       }),
       do: "turn:#{state}"

  defp frame_name(%{"type" => "typing", "active" => active}), do: "typing:#{active}"

  defp frame_name(%{
         "type" => "event",
         "event" => "activity",
         "payload" => %{"isActive" => active}
       }),
       do: "activity:#{active}"

  defp frame_name(%{"type" => "ack"}), do: "ack"
end

GuardMcpFallback.run()
IO.puts("guarded-gateway-mcp-fallback: ok")
