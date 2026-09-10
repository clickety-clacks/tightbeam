defmodule GuardSplitDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardSplitMessages do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, Gateway, Ledger, Model, Org, Projection}
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

      {:ok, lane} = GenServer.start_link(GuardSplitDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "boundaries",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "split assistant messages",
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "boundaries",
                   client_message_id: "c_boundaries"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")
        echo = Projection.get(db, turn.message_id)
        task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

        try do
          assert_receive {:prompt_started, ^adapter}, 60_000
          send(adapter, :continue_prompt)
          assert {:ok, %{terminal_publish: publish}} = Task.await(task)
          assert :ok = Ledger.finish(db, turn.seq, "delivered")
          publish.("delivered")

          replies =
            db
            |> Projection.list_after("k1", echo.id, 10)
            |> Enum.filter(&(&1.sender == "tightbeam"))

          assert Enum.map(replies, & &1.content) == ["FIRST", "SECOND"]
          assert Enum.map(replies, & &1.reply_to_message_id) == [echo.id, echo.id]

          assert Enum.map(replies, & &1.reply_to_client_message_id) == [
                   "c_boundaries",
                   "c_boundaries"
                 ]

          assert Enum.map(replies, & &1.seq) == Enum.sort(Enum.map(replies, & &1.seq))

          frames = collect_pushes(10, [])

          assert Enum.map(frames, &frame_name/1) == [
                   "message:user",
                   "turn:accepted",
                   "turn:running",
                   "typing:true",
                   "activity:true",
                   "message:assistant",
                   "message:assistant",
                   "turn:delivered",
                   "typing:false",
                   "activity:false"
                 ]

          assert frames
                 |> Enum.filter(&(&1["type"] == "message" and &1["role"] == "assistant"))
                 |> Enum.map(& &1["content"]) == ["FIRST", "SECOND"]
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

GuardSplitMessages.run()
IO.puts("guarded-gateway-split-messages: ok")
