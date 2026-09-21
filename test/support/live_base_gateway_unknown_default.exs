defmodule GuardUnknownDefaultAdapterStub do
  use GenServer
  alias Tightbeam.Model

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def init(parent), do: {:ok, parent}

  def handle_call({:new_session, model, _cwd, _mcp, _guidance}, _from, parent) do
    send(parent, {:unknown_new_session, model})
    {:reply, {:ok, "default-session"}, parent}
  end

  def handle_call(
        {:new_session, model, cwd, mcp, guidance, _request_timeout},
        from,
        parent
      ),
      do: handle_call({:new_session, model, cwd, mcp, guidance}, from, parent)

  def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

  def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
    send(parent, {:unknown_load_lost, sid, model})
    {:reply, {:error, :session_lost}, parent}
  end

  def handle_call(
        {:load_session, sid, model, cwd, mcp, guidance, _request_timeout},
        from,
        parent
      ),
      do: handle_call({:load_session, sid, model, cwd, mcp, guidance}, from, parent)

  def handle_call({:current_model, "default-session"}, _from, parent) do
    send(parent, :default_model_captured)
    {:reply, {:ok, Model.new("harness-default")}, parent}
  end

  def handle_call({:prompt, "default-session", _prompt, _opts}, _from, parent) do
    send(parent, :default_session_prompted)
    {:reply, {:ok, %{text: "continued", stop_reason: "end_turn"}}, parent}
  end
end

ExUnit.start(autorun: false)

defmodule GuardUnknownDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardUnknownDefault do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, DB, Gateway, Ledger, Model, Org}
  alias Tightbeam.GatewayTurnFixture.CoordinatorStub
  alias GuardUnknownDefaultAdapterStub, as: AdapterStub

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

      {:ok, lane} = GenServer.start_link(GuardUnknownDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "unknown-default",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        # Runtime legacy-null fixture only, after canonical admitted startup.
        make_model_unknown(db, "k1")

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "use the default",
                   db: db,
                   conn_registry: Tightbeam.ConnRegistry,
                   lane_manager: lane,
                   client_message_id: "c_unknown_default"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")
        assert {:ok, %{terminal_publish: publish}} = runner.(Map.put(turn, :session_key, "k1"))
        assert :ok = Ledger.finish(db, turn.seq, "delivered")
        publish.("delivered")

        assert_receive {:unknown_new_session, nil}
        assert_receive :default_model_captured
        assert_receive :default_session_prompted
        assert Org.get(db, "k1").model == Model.new("harness-default")

        # The session/load-lost fallback consumes the same unknown value: it must
        # create without seeding, then capture the new harness default too.
        make_model_unknown(db, "k1")

        assert :appended =
                 Gateway.deliver_prompt("k1", "user:flynn", "fall back to the default",
                   db: db,
                   conn_registry: Tightbeam.ConnRegistry,
                   lane_manager: lane,
                   client_message_id: "c_unknown_fallback"
                 )

        assert {:ok, fallback_turn} = Ledger.claim_next(db, "k1", "test")

        assert {:ok, %{terminal_publish: fallback_publish}} =
                 runner.(Map.put(fallback_turn, :session_key, "k1"))

        assert :ok = Ledger.finish(db, fallback_turn.seq, "delivered")
        fallback_publish.("delivered")

        assert_receive {:unknown_load_lost, "default-session", nil}
        assert_receive {:unknown_new_session, nil}
        assert_receive :default_model_captured
        assert_receive :default_session_prompted
        assert Org.get(db, "k1").model == Model.new("harness-default")
        assert Enum.map(Org.pointer_chain(db, "k1"), & &1.reason) == ["created", "fallback"]
      after
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end

  defp make_model_unknown(db, session_key) do
    {:ok, [[sidecar_trigger]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE name='supervision_liveness_sidecar_insert_coherent'"
      )

    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

    try do
      :ok =
        DB.execute(
          db,
          """
          DROP TRIGGER supervision_liveness_sidecar_insert_coherent;
          CREATE TABLE sessions_with_unknown AS SELECT * FROM sessions;
          DROP TABLE sessions;
          ALTER TABLE sessions_with_unknown RENAME TO sessions;
          CREATE UNIQUE INDEX sessions_unknown_key ON sessions(sessionKey);
          UPDATE sessions SET model=NULL WHERE sessionKey='#{session_key}';
          #{sidecar_trigger};
          """
        )
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
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

GuardUnknownDefault.run()
IO.puts("guarded-gateway-unknown-default: ok")
