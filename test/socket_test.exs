defmodule Tightbeam.Wire.SocketTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConnRegistry,
    DB,
    Devices,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Projection,
    Rules
  }

  alias Tightbeam.Wire.Socket

  defmodule LaneDoorbell do
    use GenServer

    def start_link({parent, name}), do: GenServer.start_link(__MODULE__, parent, name: name)
    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:ensure_lane, session_key})
      {:reply, :ok, parent}
    end
  end

  defmodule MainSeedRaceDB do
    use GenServer

    def start_link({name, db}), do: GenServer.start_link(__MODULE__, db, name: name)
    def init(db), do: {:ok, %{db: db, waiting: nil, armed: true}}

    def handle_call({:query, sql, _params} = request, from, state) do
      if state.armed and String.contains?(sql, "FROM sessions") and
           String.contains?(sql, "WHERE sessionKey = ?1") do
        result = GenServer.call(state.db, request)

        case state.waiting do
          nil ->
            {:noreply, %{state | waiting: {from, result}}}

          {first_from, first_result} ->
            GenServer.reply(first_from, first_result)
            {:reply, result, %{state | waiting: nil, armed: false}}
        end
      else
        {:reply, GenServer.call(state.db, request), state}
      end
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.db, request), state}
  end

  setup do
    db = :"socket_db_#{System.unique_integer([:positive])}"
    registry = :"socket_registry_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: registry})

    for module <- [Devices, EventLog, Idempotency, Ledger, Org, Projection],
        do: :ok = module.ensure_schema(db)

    deps = %{
      db: db,
      conn_registry: registry,
      handlers: %{},
      defaults: %{
        archetype: "default",
        host: "testhost",
        harness: :claude,
        provider: fn -> :anthropic end,
        model: "fable"
      },
      ping_interval_ms: 60_000,
      pong_timeout_ms: 60_000
    }

    %{db: db, registry: registry, deps: deps}
  end

  test "chat ingress uses real Gateway handlers for ack, dedupe, conflict, and validation", ctx do
    start_supervised!(%{
      id: :socket_e2e_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    start_supervised!(%{
      id: :socket_e2e_lane_manager,
      start: {LaneDoorbell, :start_link, [{self(), Tightbeam.LaneManager}]}
    })

    config = %{db: ctx.db, base_dir: System.tmp_dir!(), port: 0}
    handlers = Gateway.handlers(config)
    Rules.load!(Path.join(System.tmp_dir!(), "missing-socket-e2e-rules"), Map.keys(handlers))

    on_exit(fn ->
      Rules.load!(Path.join(System.tmp_dir!(), "missing-socket-e2e-reset"), [])
    end)

    {:paired, device} =
      Devices.pair(ctx.db, %{
        device_id: "chat-e2e",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    Devices.set_user_admin(ctx.db, device.user_id, false)

    deps = %{
      ctx.deps
      | conn_registry: Tightbeam.ConnRegistry,
        handlers: handlers
    }

    {:ok, socket} = Socket.init(deps)
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}

    {:push, _auth_frames, replaying} =
      Socket.handle_in({JSON.encode!(auth), opcode: :text}, socket)

    {:push, _sync_frame, live} = Socket.handle_info(:finish_replay, replaying)
    main = Org.personal_session_key(device.user_id)

    message = %{
      "type" => "message",
      "id" => "c_once",
      "content" => "hello",
      "sessionKey" => main
    }

    {:push, {:text, ack}, live} =
      Socket.handle_in({JSON.encode!(message), opcode: :text}, live)

    assert JSON.decode!(ack) == %{"type" => "ack", "id" => "c_once"}

    {:push, {:text, duplicate_ack}, live} =
      Socket.handle_in({JSON.encode!(message), opcode: :text}, live)

    assert JSON.decode!(duplicate_ack) == %{"type" => "ack", "id" => "c_once"}

    {:push, {:text, conflict}, live} =
      Socket.handle_in(
        {JSON.encode!(%{message | "content" => "different"}), opcode: :text},
        live
      )

    assert JSON.decode!(conflict) == %{
             "type" => "error",
             "code" => "invalid_message",
             "message" => "clientMessageId reused with different content",
             "messageId" => "c_once"
           }

    {:push, {:text, bad_prefix}, live} =
      Socket.handle_in(
        {JSON.encode!(%{message | "id" => "bad_prefix"}), opcode: :text},
        live
      )

    assert JSON.decode!(bad_prefix) == %{
             "type" => "error",
             "code" => "invalid_message",
             "message" => "message id must start with c_"
           }

    {:push, {:text, too_large}, live} =
      Socket.handle_in(
        {JSON.encode!(%{message | "id" => "c_big", "content" => String.duplicate("x", 65_537)}),
         opcode: :text},
        live
      )

    assert JSON.decode!(too_large) == %{
             "type" => "error",
             "code" => "payload_too_large",
             "messageId" => "c_big"
           }

    :ok =
      DB.execute(
        ctx.db,
        "INSERT OR IGNORE INTO users (userId,isAdmin,createdAt) VALUES ('other',0,1)"
      )

    Org.create(ctx.db, %{
      session_key: "other-session",
      display_name: "Other",
      owner_user_id: "other",
      origin: "user:other",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    {:push, {:text, not_found}, _live} =
      Socket.handle_in(
        {JSON.encode!(%{message | "id" => "c_foreign", "sessionKey" => "other-session"}),
         opcode: :text},
        live
      )

    assert JSON.decode!(not_found) == %{
             "type" => "error",
             "code" => "not_found",
             "messageId" => "c_foreign"
           }

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM messages WHERE clientMessageId='c_once'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               """
               SELECT COUNT(*)
               FROM turns t JOIN messages m ON m.id=t.messageId
               WHERE m.clientMessageId='c_once'
               """
             )
  end

  test "pair and auth failures use the contract reasons", ctx do
    {:ok, state} = Socket.init(ctx.deps)

    pair = %{
      "type" => "pair_request",
      "protocolVersion" => 1,
      "deviceId" => "d1",
      "claimedName" => "Flynn"
    }

    {:stop, :normal, 1000, {:text, frame}, _} =
      Socket.handle_in({JSON.encode!(pair), opcode: :text}, state)

    assert %{"type" => "pair_result", "success" => true, "token" => token} = JSON.decode!(frame)

    Devices.revoke(ctx.db, "d1")
    {:ok, state} = Socket.init(ctx.deps)
    auth = %{"type" => "auth", "token" => token, "deviceId" => "d1"}

    {:stop, :normal, 1000, {:text, frame}, _} =
      Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)

    assert %{"success" => false, "reason" => "token_revoked"} = JSON.decode!(frame)

    {:ok, state} = Socket.init(ctx.deps)
    auth = %{"type" => "auth", "token" => "nope", "deviceId" => "unknown"}

    {:stop, :normal, 1000, {:text, frame}, _} =
      Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)

    assert %{"success" => false, "reason" => "auth_failed"} = JSON.decode!(frame)

    assert {:pending, _} =
             Devices.pair(ctx.db, %{
               device_id: "d2",
               claimed_name: "Guest",
               platform: nil,
               model: nil
             })

    {:ok, state} = Socket.init(ctx.deps)
    auth = %{"type" => "auth", "token" => "nope", "deviceId" => "d2"}

    {:stop, :normal, 1000, {:text, frame}, _} =
      Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)

    assert %{"success" => false, "reason" => "device_not_approved"} = JSON.decode!(frame)
  end

  test "auth registers, replays at most 500, then sends sync_complete", ctx do
    {:paired, device} =
      Devices.pair(ctx.db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    key = Org.personal_session_key(device.user_id)

    Org.create(ctx.db, %{
      session_key: key,
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: device.user_id,
      origin: "user:#{device.user_id}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    for n <- 1..501,
        do: Projection.append(ctx.db, %{session_key: key, role: "assistant", content: "m#{n}"})

    {:ok, state} = Socket.init(ctx.deps)
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}
    {:push, frames, replaying} = Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)
    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert [
             %{"type" => "auth_result", "replayCount" => 500, "replayTruncated" => true},
             %{"type" => "stream_snapshot"} | replay
           ] = decoded

    assert length(replay) == 500
    assert replaying.phase == :replaying

    {:push, [{:text, sync}], live} = Socket.handle_info(:finish_replay, replaying)
    assert JSON.decode!(sync) == %{"type" => "sync_complete"}
    assert live.phase == :live
  end

  test "concurrent first auths converge on one personal main stream", ctx do
    {:paired, device} =
      Devices.pair(ctx.db, %{device_id: "race", claimed_name: "Flynn", platform: nil, model: nil})

    proxy = :"main_seed_race_db_#{System.unique_integer([:positive])}"
    start_supervised!({MainSeedRaceDB, {proxy, ctx.db}})
    deps = %{ctx.deps | db: proxy}
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}
    parent = self()

    refs =
      for _ <- 1..2 do
        {:ok, state} = Socket.init(deps)

        spawn_monitor(fn ->
          send(
            parent,
            {:auth_result, Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)}
          )
        end)
        |> elem(1)
      end

    for _ <- refs do
      assert_receive {:auth_result, {:push, _frames, _state}}
    end

    for ref <- refs do
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end

    assert [%{session_key: key}] = Org.list_for_user(ctx.db, device.user_id, false)
    assert key == Org.personal_session_key(device.user_id)
  end

  test "drain filters a mid-replay push already covered by the replay window", ctx do
    {:paired, device} =
      Devices.pair(ctx.db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    key = Org.personal_session_key(device.user_id)

    Org.create(ctx.db, %{
      session_key: key,
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: device.user_id,
      origin: "user:#{device.user_id}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    {:appended, replayed} =
      Projection.append(ctx.db, %{session_key: key, role: "assistant", content: "old"})

    {:ok, state} = Socket.init(ctx.deps)
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}
    {:push, _frames, replaying} = Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)

    # The race: a publication for a seq the replay window already sent
    # arrives while replaying (registry watermark was 0 at publish time).
    dupe = {:push_message, key, replayed.seq, %{"type" => "message", "id" => replayed.id}}
    {:ok, buffered} = Socket.handle_info(dupe, replaying)

    # And one genuinely-new message push arrives too.
    fresh = {:push_message, key, replayed.seq + 1, %{"type" => "message", "id" => "s_new"}}
    {:ok, buffered} = Socket.handle_info(fresh, buffered)

    {:push, frames, live} = Socket.handle_info(:finish_replay, buffered)
    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert decoded == [
             %{"type" => "message", "id" => "s_new"},
             %{"type" => "sync_complete"}
           ]

    assert live.phase == :live

    # Once live, message pushes flow straight through (registry filters).
    assert {:push, {:text, _}, _} = Socket.handle_info(fresh, live)
  end

  test "work-state-only auth skips chat material, gates inbound chat, and preserves class on re-auth",
       ctx do
    {:paired, device} =
      Devices.pair(ctx.db, %{device_id: "state", claimed_name: "State", platform: nil, model: nil})

    {:ok, state} = Socket.init(ctx.deps)

    auth = %{
      "type" => "auth",
      "token" => device.token,
      "deviceId" => device.device_id,
      "subscriptions" => ["work_state"]
    }

    {:push, [{:text, auth_frame}], replaying} =
      Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)

    decoded = JSON.decode!(auth_frame)
    assert decoded["type"] == "auth_result"
    assert decoded["sessionKeys"] == []
    assert decoded["streamReadStates"] == %{}
    assert decoded["streamTailStates"] == %{}
    assert decoded["replayCount"] == 0
    assert Org.list_for_user(ctx.db, device.user_id, false) == []

    {:push, [{:text, sync}], live} = Socket.handle_info(:finish_replay, replaying)
    assert JSON.decode!(sync) == %{"type" => "sync_complete"}

    for frame <- [
          %{"type" => "message", "id" => "c_x", "content" => "no"},
          %{"type" => "stream_read", "sessionKey" => "missing", "lastReadMessageId" => "s_1"},
          %{"type" => "typing"}
        ] do
      {:push, {:text, error}, kept} =
        Socket.handle_in({JSON.encode!(frame), opcode: :text}, live)

      assert JSON.decode!(error)["code"] == "invalid_message"
      assert kept.phase == :live
    end

    reauth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}

    {:push, [{:text, _}], reauthing} =
      Socket.handle_in({JSON.encode!(reauth), opcode: :text}, live)

    assert reauthing.conn_ref == live.conn_ref
    assert reauthing.subscriptions == MapSet.new(["work_state"])
    assert Org.list_for_user(ctx.db, device.user_id, false) == []

    {:push, [{:text, _}], live_again} = Socket.handle_info(:finish_replay, reauthing)

    :ok =
      ConnRegistry.publish_work_state(
        ctx.registry,
        device.user_id,
        %{"type" => "work_state_event"},
        fn pid, payload -> send(pid, {:push, payload}) end
      )

    assert_receive {:push, %{"type" => "work_state_event"} = payload}
    assert {:push, {:text, event}, _} = Socket.handle_info({:push, payload}, live_again)

    assert JSON.decode!(event)["type"] == "work_state_event"

    differing = Map.put(reauth, "subscriptions", ["chat"])

    assert {:stop, :normal, 1000, {:text, error}, _} =
             Socket.handle_in({JSON.encode!(differing), opcode: :text}, live_again)

    assert JSON.decode!(error)["code"] == "invalid_message"
  end

  test "default connection re-auth preserves its lifetime class without re-registration", ctx do
    {:paired, device} =
      Devices.pair(ctx.db, %{
        device_id: "default-reauth",
        claimed_name: "Default",
        platform: nil,
        model: nil
      })

    {:ok, state} = Socket.init(ctx.deps)
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}

    {:push, initial_frames, replaying} =
      Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)

    assert Enum.map(initial_frames, fn {:text, frame} -> JSON.decode!(frame)["type"] end) == [
             "auth_result",
             "stream_snapshot"
           ]

    {:push, [{:text, sync}], live} = Socket.handle_info(:finish_replay, replaying)
    assert JSON.decode!(sync) == %{"type" => "sync_complete"}
    assert live.subscriptions == MapSet.new(["chat"])
    assert map_size(:sys.get_state(ctx.registry).conns) == 1

    {:push, reauth_frames, reauthing} =
      Socket.handle_in({JSON.encode!(auth), opcode: :text}, live)

    assert Enum.map(reauth_frames, fn {:text, frame} -> JSON.decode!(frame)["type"] end) == [
             "auth_result",
             "stream_snapshot"
           ]

    assert reauthing.conn_ref == live.conn_ref
    assert reauthing.subscriptions == MapSet.new(["chat"])
    assert map_size(:sys.get_state(ctx.registry).conns) == 1
    refute_receive {:takeover_close}

    {:push, [{:text, second_sync}], live_again} =
      Socket.handle_info(:finish_replay, reauthing)

    assert JSON.decode!(second_sync) == %{"type" => "sync_complete"}
    assert live_again.conn_ref == live.conn_ref
    assert live_again.subscriptions == MapSet.new(["chat"])
  end

  test "invalid subscription sets fail before seeding or registration", ctx do
    {:paired, device} =
      Devices.pair(ctx.db, %{device_id: "bad", claimed_name: "Bad", platform: nil, model: nil})

    for subscriptions <- [[], ["unknown"]] do
      {:ok, state} = Socket.init(ctx.deps)

      auth = %{
        "type" => "auth",
        "token" => device.token,
        "deviceId" => device.device_id,
        "subscriptions" => subscriptions
      }

      assert {:stop, :normal, 1000, {:text, error}, _} =
               Socket.handle_in({JSON.encode!(auth), opcode: :text}, state)

      assert JSON.decode!(error)["code"] == "invalid_message"
      assert map_size(:sys.get_state(ctx.registry).conns) == 0
      assert Org.list_for_user(ctx.db, device.user_id, false) == []
    end
  end
end
