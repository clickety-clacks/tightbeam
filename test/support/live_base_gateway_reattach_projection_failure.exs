defmodule GuardProjectionFailureAdapterStub do
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def init(parent), do: {:ok, parent}

  def handle_call({:knows_session?, sid}, _from, parent) do
    send(parent, {:projection_residency, sid})
    {:reply, false, parent}
  end

  def handle_call({:load_session, sid, _model, _cwd, _mcp, _guidance}, _from, parent) do
    send(parent, {:projection_attempted, sid})
    {:reply, {:error, {:codex_identity_projection_failed, :injected}}, parent}
  end

  def handle_call(
        {:load_session, sid, model, cwd, mcp, guidance, _request_timeout},
        from,
        parent
      ),
      do: handle_call({:load_session, sid, model, cwd, mcp, guidance}, from, parent)

  def handle_call({:new_session, _model, _cwd, _mcp, _guidance}, _from, parent) do
    send(parent, :unexpected_projection_new_session)
    {:reply, {:ok, "unexpected"}, parent}
  end

  def handle_call({:prompt, _sid, _prompt, _opts}, _from, parent) do
    send(parent, :load_failure_prompted)
    {:reply, {:ok, %{text: "unexpected", stop_reason: "end_turn"}}, parent}
  end
end

ExUnit.start(autorun: false)

defmodule GuardProjectionFailureDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardReattachProjectionFailure do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, DB, EventLog, Gateway, Ledger, Model, Org, Projection}
  alias Tightbeam.GatewayTurnFixture.CoordinatorStub

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
      Org.create(db, %{
        session_key: "k1",
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

      {:ok, lane} = GenServer.start_link(GuardProjectionFailureDoorbell, self())
      {:ok, adapter} = GuardProjectionFailureAdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "projection-failure",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        Org.append_pointer(db, "k1", "resident-codex-session", "created")

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "ping",
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "projection-failure",
                   client_message_id: "c_projection_failure"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

        assert {:error,
                %{
                  reason: {:codex_identity_projection_failed, :injected},
                  terminal_publish: publish,
                  record_in_txn: record
                }} = runner.(Map.put(turn, :session_key, "k1"))

        assert {:ok, true} =
                 DB.transaction(db, fn txn ->
                   assert Ledger.finish_in_txn(txn, turn.seq, "failed", "projection failed")
                   record.(txn)
                   true
                 end)

        publish.("failed")

        assert_receive {:projection_residency, "resident-codex-session"}
        assert_receive {:projection_attempted, "resident-codex-session"}
        refute_receive :unexpected_projection_new_session
        refute_receive :load_failure_prompted

        assert Enum.map(Org.pointer_chain(db, "k1"), & &1.reason) == ["created"]
        refute Enum.any?(EventLog.lifecycle_events(db), &(&1.kind == "pointer_fallback"))

        assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
                 event.kind == "harness_turn_error" and
                   event.detail =~ "codex_identity_projection_failed"
               end)

        assert Enum.any?(Projection.list_after(db, "k1", nil, 100), fn message ->
                 String.starts_with?(message.content || "", "[turn failed]")
               end)

        refute Enum.any?(Projection.list_after(db, "k1", nil, 100), fn message ->
                 String.starts_with?(message.content || "", "[context reset]")
               end)
      after
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end
end

GuardReattachProjectionFailure.run()
IO.puts("guarded-gateway-reattach-projection-failure: ok")
