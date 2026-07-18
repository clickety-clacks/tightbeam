defmodule Tightbeam.GatewayTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{ConnRegistry, DB, EventLog, Gateway, Ledger, Org, Projection}

  defmodule LaneDoorbell do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, key}, _from, parent) do
      send(parent, {:ensure_lane, key})
      {:reply, :ok, parent}
    end
  end

  defmodule CoordinatorStub do
    use GenServer

    def start_link(adapter),
      do: GenServer.start_link(__MODULE__, adapter, name: Tightbeam.AdapterCoordinator)

    def init(adapter), do: {:ok, adapter}

    def handle_call({:adapter_for, _key}, _from, adapter),
      do: {:reply, {:ok, adapter, 1}, adapter}

    def handle_call({:acquire_load_slot, _borrower}, _from, adapter),
      do: {:reply, make_ref(), adapter}

    def handle_cast({:release_load_slot, _slot}, adapter), do: {:noreply, adapter}
  end

  defmodule AdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:new_session, _model, _cwd}, _from, parent),
      do: {:reply, {:ok, "harness-1"}, parent}

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

    def handle_call({:load_session, _sid, _model, _cwd}, _from, parent),
      do: {:reply, {:error, %{"code" => -32602, "message" => "Invalid params"}}, parent}

    def handle_call({:prompt, _sid, prompt, _opts}, from, parent) do
      send(parent, {:prompt_started, self()})

      receive do: (:continue_prompt ->
                     GenServer.reply(
                       from,
                       {:ok, %{text: String.upcase(prompt), stop_reason: "end_turn"}}
                     ))

      {:noreply, parent}
    end
  end

  setup do
    db = :"gateway_db_#{System.unique_integer([:positive])}"
    registry = :"gateway_registry_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: registry})
    lane = start_supervised!({LaneDoorbell, self()})
    for module <- [EventLog, Ledger, Org, Projection], do: :ok = module.ensure_schema(db)

    Org.create(db, %{
      session_key: "k1",
      display_name: "Main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    {:ok, _ref, nil} =
      ConnRegistry.register(registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "d1",
        is_admin: false
      })

    %{db: db, registry: registry, lane: lane}
  end

  test "deliver_prompt commits echo+turn once and client duplicate short-circuits", ctx do
    opts = [
      db: ctx.db,
      conn_registry: ctx.registry,
      lane_manager: ctx.lane,
      device_id: "d1",
      client_message_id: "c_1"
    ]

    assert Gateway.deliver_prompt("k1", "user:flynn", "hello", opts) == :appended
    assert_receive {:push_message, "k1", _seq, %{"type" => "message", "role" => "user"}}

    assert_receive {:push,
                    %{"event" => "prompt_turn_state", "payload" => %{"state" => "accepted"}}}

    assert_receive {:ensure_lane, "k1"}
    assert Gateway.deliver_prompt("k1", "user:flynn", "hello", opts) == :duplicate
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
  end

  test "wake_id dedupes the transaction including its second echo", ctx do
    opts = [
      db: ctx.db,
      conn_registry: ctx.registry,
      lane_manager: ctx.lane,
      wake_id: "w_1",
      sender: "agent:caller"
    ]

    assert Gateway.deliver_prompt("k1", "agent:caller", "wake", opts) == :appended
    assert Gateway.deliver_prompt("k1", "agent:caller", "wake", opts) == :duplicate
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = 'w_1'")
  end

  test "one fake-adapter turn publishes the golden frame order", ctx do
    exact_registry =
      start_supervised!(%{
        id: :exact_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "golden",
        is_admin: false
      })

    base = Path.join(System.tmp_dir!(), "gateway_children_#{System.unique_integer([:positive])}")

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "fable",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "ping",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "golden",
               client_message_id: "c_gold"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)
    assert_receive {:prompt_started, ^adapter}
    send(self(), {:push, Tightbeam.Wire.Payloads.ack("c_gold")})
    send(adapter, :continue_prompt)
    assert {:ok, %{terminal_publish: publish}} = Task.await(task)
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
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
  end

  test "a fallback turn appends the context-reset marker between echo and reply", ctx do
    exact_registry =
      start_supervised!(%{
        id: :marker_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "marker",
        is_admin: false
      })

    base = Path.join(System.tmp_dir!(), "gateway_children_#{System.unique_integer([:positive])}")

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "fable",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    # A pre-existing pointer the stub adapter refuses to load → the runner
    # must fall back AND put the memory-loss line on the wire.
    Org.append_pointer(ctx.db, "k1", "stale-harness-sid", "created")

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "ping",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "marker",
               client_message_id: "c_marker"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)
    assert_receive {:prompt_started, ^adapter}
    send(adapter, :continue_prompt)
    assert {:ok, %{terminal_publish: publish}} = Task.await(task)
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")

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

    marker = Enum.find(frames, &(&1["type"] == "message" and &1["sender"] == "process:tightbeam"))
    assert String.starts_with?(marker["content"], "[context reset]\n")

    assert Enum.map(Org.pointer_chain(ctx.db, "k1"), & &1.reason) == ["created", "fallback"]

    assert [%{kind: "pointer_fallback", subject: "k1"}] =
             EventLog.lifecycle_events(ctx.db) |> Enum.filter(&(&1.kind == "pointer_fallback"))
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
