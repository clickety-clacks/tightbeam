defmodule GuardModeFailureAdapterStub do
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def init(parent), do: {:ok, parent}

  def handle_call({:knows_session?, sid}, _from, parent) do
    send(parent, {:load_apply_residency, sid})
    {:reply, false, parent}
  end

  def handle_call({:load_session, sid, _model, _cwd, _mcp, _guidance}, _from, parent) do
    send(parent, {:mode_apply_attempted, sid})
    {:reply, {:error, {:mode_apply_failed, :mode_refused}}, parent}
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
    send(parent, :load_failure_prompted)
    {:reply, {:ok, %{text: "unexpected", stop_reason: "end_turn"}}, parent}
  end
end

ExUnit.start(autorun: false)

defmodule GuardModeFailureDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardReattachModeFailure do
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
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

      {:ok, lane} = GenServer.start_link(GuardModeFailureDoorbell, self())
      {:ok, adapter} = GuardModeFailureAdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "mode-failure",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        Org.append_pointer(db, "k1", "resident-mode-session", "created")

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "ping",
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "mode-failure",
                   client_message_id: "c_mode_failure"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

        assert {:error,
                %{
                  reason: {:mode_apply_failed, :mode_refused},
                  terminal_publish: publish,
                  record_in_txn: record
                }} = runner.(Map.put(turn, :session_key, "k1"))

        assert {:ok, true} =
                 DB.transaction(db, fn txn ->
                   assert Ledger.finish_in_txn(txn, turn.seq, "failed", "mode refused",
                            owner_lease: turn.owner_lease
                          )

                   record.(txn)
                   true
                 end)

        publish.("failed")

        assert_receive {:load_apply_residency, "resident-mode-session"}
        assert_receive {:mode_apply_attempted, "resident-mode-session"}
        refute_receive :unexpected_load_apply_new_session
        refute_receive :load_failure_prompted

        assert Enum.map(Org.pointer_chain(db, "k1"), & &1.reason) == ["created"]
        refute Enum.any?(EventLog.lifecycle_events(db), &(&1.kind == "pointer_fallback"))

        assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
                 event.kind == "harness_turn_error" and
                   event.detail =~ "mode_apply_failed"
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

GuardReattachModeFailure.run()
IO.puts("guarded-gateway-reattach-mode-failure: ok")
