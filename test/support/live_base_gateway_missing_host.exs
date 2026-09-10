defmodule GuardMissingHost do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, Gateway, LaneManager, Model, Org}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
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

      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      {:ok, registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)
      {:ok, tasks} = Task.Supervisor.start_link()
      {:ok, lanes} = DynamicSupervisor.start_link(strategy: :one_for_one)

      {:ok, _ref, nil} =
        ConnRegistry.register(Tightbeam.ConnRegistry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "placement-refusal",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      {LaneManager, lane_opts} =
        Gateway.children(config) |> Enum.find(&match?({LaneManager, _}, &1))

      {:ok, manager} =
        LaneManager.start_link(
          db: db,
          lane_sup: lanes,
          task_sup: tasks,
          runner: Keyword.fetch!(lane_opts, :runner),
          terminal_publisher: Keyword.fetch!(lane_opts, :terminal_publisher),
          interval: 60_000,
          name: :guard_missing_host_manager
        )

      try do
        Org.set_host(db, "k1", "eurisko")

        expected =
          "host eurisko is not configured for claude; run tightbeam assimilate <ssh-dest> " <>
            "--name eurisko --as-user <adminUserId>"

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "try vanished host",
                   db: db,
                   conn_registry: Tightbeam.ConnRegistry,
                   lane_manager: manager,
                   device_id: "placement-refusal",
                   client_message_id: "c_placement_refusal"
                 )

        frames = collect_pushes(10, [])

        failed =
          Enum.find(frames, fn
            %{
              "type" => "event",
              "event" => "prompt_turn_state",
              "payload" => %{"state" => "failed"}
            } ->
              true

            _ ->
              false
          end)

        assert failed["payload"]["error"] == expected

        assert Enum.any?(frames, fn
                 %{"type" => "message", "content" => content} ->
                   content ==
                     "[turn failed]\n\nThe agent could not answer the message above: " <> expected

                 _ ->
                   false
               end)
      after
        GenServer.stop(manager)
        Supervisor.stop(lanes)
        Supervisor.stop(tasks)
        send(adapter, :continue_prompt)
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        Supervisor.stop(registry)
      end
    end)
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

GuardMissingHost.run()
IO.puts("guarded-gateway-missing-host: ok")
