defmodule Tightbeam.Wire.SocketTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{ConnRegistry, DB, Devices, EventLog, Org, Projection}
  alias Tightbeam.Wire.Socket

  setup do
    db = :"socket_db_#{System.unique_integer([:positive])}"
    registry = :"socket_registry_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: registry})
    for module <- [Devices, EventLog, Org, Projection], do: :ok = module.ensure_schema(db)

    deps = %{
      db: db,
      conn_registry: registry,
      handlers: %{},
      defaults: %{archetype: "default", harness: :claude, provider: :anthropic, model: "fable"},
      ping_interval_ms: 60_000,
      pong_timeout_ms: 60_000
    }

    %{db: db, registry: registry, deps: deps}
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
end
