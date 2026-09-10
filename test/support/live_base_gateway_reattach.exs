defmodule GuardLoadWithoutOwnerReadAdapterStub do
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def init(parent), do: {:ok, parent}

  def handle_call({:knows_session?, sid}, _from, parent) do
    send(parent, {:load_apply_residency, sid})
    {:reply, false, parent}
  end

  def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
    send(parent, {:canonical_model_pushed_on_load, sid, model})
    {:reply, {:ok, model}, parent}
  end

  def handle_call(
        {:load_session, sid, model, cwd, mcp, guidance, _request_timeout},
        from,
        parent
      ),
      do: handle_call({:load_session, sid, model, cwd, mcp, guidance}, from, parent)

  def handle_call({:new_session, _model, _cwd, _mcp, _guidance}, _from, parent) do
    send(parent, :unexpected_load_apply_new_session)
    {:reply, {:ok, "unexpected"}, parent}
  end

  def handle_call({:prompt, _sid, _prompt, _opts}, _from, parent) do
    send(parent, :load_without_owner_read_prompted)
    {:reply, {:ok, %{text: "continued", stop_reason: "end_turn"}}, parent}
  end
end

ExUnit.start(autorun: false)

defmodule GuardReattachDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardReattach do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, EventLog, Gateway, Ledger, Model, Org, Projection}
  alias Tightbeam.GatewayTurnFixture.CoordinatorStub
  alias GuardLoadWithoutOwnerReadAdapterStub, as: AdapterStub

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

      {:ok, lane} = GenServer.start_link(GuardReattachDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "load-apply-failure",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        Org.append_pointer(db, "k1", "load-apply-session", "created")

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "ping",
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "load-apply-failure",
                   client_message_id: "c_load_apply_failure"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

        assert {:ok, %{terminal_publish: publish}} =
                 runner.(Map.put(turn, :session_key, "k1"))

        assert :ok = Ledger.finish(db, turn.seq, "delivered")
        publish.("delivered")
        assert_receive {:load_apply_residency, "load-apply-session"}

        assert_receive {:canonical_model_pushed_on_load, "load-apply-session",
                        %Model{family: "fable"}}

        assert_receive :load_without_owner_read_prompted
        refute_receive :unexpected_load_apply_new_session
        assert Enum.map(Org.pointer_chain(db, "k1"), & &1.reason) == ["created", "loaded"]
        refute Enum.any?(EventLog.lifecycle_events(db), &(&1.kind == "pointer_fallback"))

        refute Enum.any?(Projection.list_after(db, "k1", nil, 100), fn message ->
                 String.starts_with?(message.content, "[context reset]")
               end)
      after
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

GuardReattach.run()
IO.puts("guarded-gateway-reattach: ok")
