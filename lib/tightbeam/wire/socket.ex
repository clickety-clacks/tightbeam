defmodule Tightbeam.Wire.Socket do
  @moduledoc """
  The Clawline WebSocket handler — a `WebSock` implementation, one process
  per socket under Bandit (TS reference: src/wire/server.ts; its behavior,
  frame-for-frame, is the oracle — including the E0 golden frame ORDER for
  the canonical turn).

  Two socket lifecycles:
  - pairing socket: pair_request → pair_result (+ close)
  - authed socket:  auth → auth_result → stream_snapshot → replay messages →
    sync_complete → live

  Process/ownership rules (the Elixir-shape decisions — binding):
  - This process owns NOTHING shared. Fan-out scoping, device takeover, and
    the replay/live de-dup watermark live in `Tightbeam.ConnRegistry`; this
    process registers on auth, unregisters on terminate, and forwards frames.
  - Replay protocol vs the registry (the race-closing order): register FIRST
    (live pushes start arriving and are buffered by this process), then read
    the replay window from Projection, sending each and advancing the
    watermark via `ConnRegistry.note_replayed`, then drain the buffer THROUGH
    the watermark, then send sync_complete, then go live. The drain filter is
    load-bearing: a message published between register and note_replayed
    passes the registry's filter (watermark still 0) AND appears in the
    replay window — so message pushes arrive tagged as
    `{:push_message, session_key, seq, payload}` and the drain drops any
    whose seq ≤ the watermark this socket advanced during replay. Untagged
    `{:push, payload}` events (turn state, typing, activity) have no seq and
    drain unfiltered.
  - Takeover: `ConnRegistry.register` returns the replaced ref; the SOCKET
    (not the registry) then sends session_replaced+close to the old pid via
    the registry's message — the old socket receives `{:takeover_close}` and
    closes itself. The registry has already swapped the slot, so the old
    socket's unregister cannot evict the new one.
  - Keepalive: WebSock ping/pong with a pong deadline (Process.send_after);
    silence past the deadline closes the socket. Defaults: ping every 30s,
    pong timeout 90s.
  - Rate limits are GLOBAL per deviceId and live in ConnRegistry (a
    per-process window would reset on reconnect): typing 2/s, pair 5/min.

  Inbound frames (server.ts message handler, same semantics):
  - pair_request: protocolVersion must be 1; pair via Devices; reply
    pair_result; close.
  - auth: token → Devices.by_token; failure reasons: pending device →
    device_not_approved, allowlisted-but-stale-token → token_revoked, unknown
    → auth_failed. Success: seed the main stream if absent (defaults come
    from the gateway config — NEVER hardcoded here), register, replay, live.
  - message: id must start with "c_" (else invalid_message); content ≤ 64KiB
    utf8 (else payload_too_large); session ownership enforced (not_found);
    then verb "post" through Dispatch. dedupe: :duplicate → ack again;
    :conflict → invalid_message and NO ack.
  - stream_read: write read state, echo stream_read_state.
  - typing: rate-limited, otherwise dropped silently (not fanned out in v1).
  - anything else: invalid_message.
  """

  @behaviour WebSock

  alias Tightbeam.{ConnRegistry, Devices, Dispatch, Org, Projection}
  alias Tightbeam.Wire.Payloads

  @max_content_bytes 64 * 1024

  @typedoc "Socket state; `conn_ref` is nil until authed."
  @type t :: %__MODULE__{
          conn_ref: reference() | nil,
          user_id: String.t() | nil,
          device_id: String.t() | nil,
          is_admin: boolean(),
          phase: :unauthed | :replaying | :live,
          buffer: [tuple()],
          watermarks: %{optional(String.t()) => integer()},
          deps: map()
        }

  defstruct conn_ref: nil,
            user_id: nil,
            device_id: nil,
            is_admin: false,
            phase: :unauthed,
            buffer: [],
            watermarks: %{},
            deps: %{}

  @impl true
  def init(deps) do
    {:ok, %__MODULE__{deps: deps}}
  end

  @impl true
  def handle_in({data, opcode: :text}, state) do
    case JSON.decode(data) do
      {:ok, msg} when is_map(msg) -> route(msg, state)
      _ -> push(Payloads.wire_error("invalid_message", "malformed json"), state)
    end
  end

  def handle_in({_data, opcode: :binary}, state),
    do: push(Payloads.wire_error("invalid_message"), state)

  @impl true
  def handle_info(msg, state) do
    case msg do
      {:push, payload} when state.phase == :replaying ->
        {:ok, %{state | buffer: [{:frame, payload} | state.buffer]}}

      {:push, payload} when state.phase == :live ->
        push(payload, state)

      {:push, _payload} ->
        {:ok, state}

      {:push_message, key, seq, payload} when state.phase == :replaying ->
        {:ok, %{state | buffer: [{:msg, key, seq, payload} | state.buffer]}}

      {:push_message, _key, _seq, payload} when state.phase == :live ->
        push(payload, state)

      {:push_message, _key, _seq, _payload} ->
        {:ok, state}

      :finish_replay ->
        # Drain THROUGH the watermark (see moduledoc): drop buffered message
        # pushes already covered by the replay window; keep everything else.
        frames =
          state.buffer
          |> Enum.reverse()
          |> Enum.flat_map(fn
            {:msg, key, seq, payload} ->
              if seq > Map.get(state.watermarks, key, 0), do: [payload], else: []

            {:frame, payload} ->
              [payload]
          end)

        push_many(frames ++ [Payloads.sync_complete()], %{state | phase: :live, buffer: []})

      {:takeover_close} ->
        stop_with(Payloads.wire_error("session_replaced"), state)

      {:ping, token} ->
        if token == state.deps[:ping_token] do
          state = schedule_ping(state)
          {:push, {:ping, ""}, state}
        else
          {:ok, state}
        end

      {:pong_deadline, token} ->
        if token == state.deps[:pong_token], do: {:stop, :timeout, state}, else: {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_control({_data, opcode: :pong}, state), do: {:ok, arm_pong_deadline(state)}
  def handle_control({_data, opcode: :ping}, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.deps[:ping_timer])
    cancel_timer(state.deps[:pong_timer])

    if state.conn_ref do
      Tightbeam.ConnRegistry.unregister(conn_registry(state), state.conn_ref)
    end

    :ok
  end

  defp route(%{"type" => "pair_request"} = msg, state), do: pair(msg, state)
  defp route(%{"type" => "auth"} = msg, state), do: auth(msg, state)

  defp route(_msg, %{phase: :unauthed} = state) do
    push(Payloads.wire_error("auth_failed", "not authenticated"), state)
  end

  defp route(%{"type" => "message"} = msg, state), do: client_message(msg, state)

  defp route(%{"type" => "stream_read"} = msg, state) do
    session_key = string(msg["sessionKey"])
    last = string(msg["lastReadMessageId"])
    :ok = Projection.set_read_state(db(state), state.user_id, session_key, last)
    push(Payloads.stream_read_state(session_key, last), state)
  end

  defp route(%{"type" => "typing"}, state) do
    _ =
      ConnRegistry.within_rate_limit(
        conn_registry(state),
        state.device_id,
        :typing,
        typing_limit(state),
        1_000
      )

    {:ok, state}
  end

  defp route(msg, state) do
    push(
      Payloads.wire_error("invalid_message", "unsupported type: #{string(msg["type"])}"),
      state
    )
  end

  defp pair(msg, state) do
    device_id = string(msg["deviceId"])

    cond do
      not ConnRegistry.within_rate_limit(
        conn_registry(state),
        device_id,
        :pair,
        pair_limit(state),
        60_000
      ) ->
        stop_with(Payloads.wire_error("rate_limited"), state)

      msg["protocolVersion"] != 1 ->
        stop_with(Payloads.wire_error("invalid_message", "protocolVersion must be 1"), state)

      true ->
        info = if is_map(msg["deviceInfo"]), do: msg["deviceInfo"], else: %{}

        result =
          Devices.pair(db(state), %{
            device_id: device_id,
            claimed_name: string(msg["claimedName"] || "device"),
            platform: info["platform"],
            model: info["model"]
          })

        payload =
          case result do
            {:paired, device} -> Payloads.pair_result({:ok, device.token, device.user_id})
            {:pending, _device} -> Payloads.pair_result({:error, "pair_pending"})
            :denied -> Payloads.pair_result({:error, "pair_denied"})
          end

        stop_with(payload, state)
    end
  end

  defp auth(msg, state) do
    token = string(msg["token"])

    case Devices.by_token(db(state), token) do
      nil ->
        known = Devices.by_id(db(state), string(msg["deviceId"]))

        reason =
          case known do
            %{status: "pending"} -> "device_not_approved"
            %{status: "allowlisted"} -> "token_revoked"
            _ -> "auth_failed"
          end

        stop_with(Payloads.auth_result_failure(reason), state)

      device ->
        seed_main_stream(device.user_id, state)

        {:ok, conn_ref, _replaced} =
          ConnRegistry.register(conn_registry(state), %{
            pid: self(),
            user_id: device.user_id,
            device_id: device.device_id,
            is_admin: device.is_admin
          })

        sessions = Org.list_for_user(db(state), device.user_id, false)
        keys = Enum.map(sessions, & &1.session_key)
        cursors = replay_cursors(msg, device.user_id, state)

        {replay, truncated?, watermarks} =
          Enum.reduce(keys, {[], false, %{}}, fn key, {messages, truncated, marks} ->
            barrier = Enum.find_value(sessions, 0, &(&1.session_key == key && &1.cleared_through_seq))
            rows = Projection.list_after(db(state), key, cursors[key], 501, barrier || 0)
            selected = Enum.take(rows, 500)

            Enum.each(selected, fn message ->
              ConnRegistry.note_replayed(conn_registry(state), conn_ref, key, message.seq)
            end)

            marks =
              case List.last(selected) do
                %{seq: seq} -> Map.put(marks, key, seq)
                nil -> marks
              end

            {messages ++ selected, truncated or length(rows) == 501, marks}
          end)

        read_states = Projection.read_states(db(state), device.user_id)

        tail_states =
          Map.new(keys, fn key -> {key, Projection.tail(db(state), key)} end)
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
          |> Map.new(fn {key, tail} ->
            {key,
             %{
               "lastMessageId" => tail.last_message_id,
               "lastMessageRole" => tail.last_message_role
             }}
          end)

        auth_payload =
          Payloads.auth_result_success(%{
            user_id: device.user_id,
            session_id: "conn_#{device.device_id}",
            is_admin: device.is_admin,
            replay_count: length(replay),
            replay_truncated: truncated?,
            history_reset: false,
            session_keys: keys,
            stream_read_states: read_states,
            stream_tail_states: tail_states,
            features: ["tightbeam"],
            dm_scope: if(device.is_admin, do: "admin", else: nil)
          })

        snapshot =
          Payloads.stream_snapshot(Enum.map(sessions, &(&1 |> Payloads.stream_session())))

        state = %{
          state
          | conn_ref: conn_ref,
            user_id: device.user_id,
            device_id: device.device_id,
            is_admin: device.is_admin,
            phase: :replaying,
            watermarks: watermarks
        }

        state = state |> schedule_ping() |> arm_pong_deadline()
        send(self(), :finish_replay)
        push_many([auth_payload, snapshot | Enum.map(replay, &Payloads.server_message/1)], state)
    end
  end

  defp client_message(msg, state) do
    id = string(msg["id"])
    content = string(msg["content"])
    session_key = string(msg["sessionKey"] || Org.personal_session_key(state.user_id))
    session = Org.get(db(state), session_key)

    cond do
      not String.starts_with?(id, "c_") ->
        push(Payloads.wire_error("invalid_message", "message id must start with c_"), state)

      byte_size(content) > @max_content_bytes ->
        push(Payloads.wire_error("payload_too_large", nil, id), state)

      is_nil(session) or (session.owner_user_id != state.user_id and not state.is_admin) ->
        push(Payloads.wire_error("not_found", nil, id), state)

      true ->
        call = %{
          verb: "post",
          origin: "user:#{state.user_id}",
          session_key: session_key,
          params: %{
            content: content,
            device_id: state.device_id,
            client_message_id: id,
            attachments: msg["attachments"] || []
          }
        }

        case Dispatch.dispatch(db(state), state.deps.handlers, call) do
          {:ok, %{dedupe: dedupe}} when dedupe in [:conflict, "conflict"] ->
            push(
              Payloads.wire_error(
                "invalid_message",
                "clientMessageId reused with different content",
                id
              ),
              state
            )

          {:ok, _result} ->
            push(Payloads.ack(id), state)

          {:error, error} ->
            push(Payloads.wire_error(error[:code] || "server_error", error[:message], id), state)
        end
    end
  end

  defp seed_main_stream(user_id, state) do
    key = Org.personal_session_key(user_id)

    unless Org.get(db(state), key) do
      defaults = Map.fetch!(state.deps, :defaults)

      Org.create(db(state), %{
        session_key: key,
        display_name: "Main",
        kind: "main",
        is_built_in: true,
        order_index: 0,
        owner_user_id: user_id,
        origin: "user:#{user_id}",
        archetype: Map.fetch!(defaults, :archetype),
        host: Tightbeam.Placement.local_host_name(),
        harness: defaults |> Map.fetch!(:harness) |> to_string(),
        provider: defaults |> Map.fetch!(:provider) |> to_string(),
        model: Map.fetch!(defaults, :model)
      })
    end
  end

  defp replay_cursors(msg, user_id, state) do
    cursors =
      if is_map(msg["replayCursorsBySessionKey"]), do: msg["replayCursorsBySessionKey"], else: %{}

    if map_size(cursors) == 0 and is_binary(msg["lastMessageId"]) and msg["lastMessageId"] != "" do
      case Projection.get(db(state), msg["lastMessageId"]) do
        %{session_key: key, id: id} ->
          case Org.get(db(state), key) do
            %{owner_user_id: ^user_id} -> %{key => id}
            _ -> cursors
          end

        _ ->
          cursors
      end
    else
      cursors
    end
  end

  defp schedule_ping(state) do
    cancel_timer(state.deps[:ping_timer])
    token = make_ref()

    timer =
      Process.send_after(self(), {:ping, token}, Map.get(state.deps, :ping_interval_ms, 30_000))

    %{state | deps: Map.merge(state.deps, %{ping_timer: timer, ping_token: token})}
  end

  defp arm_pong_deadline(state) do
    cancel_timer(state.deps[:pong_timer])
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:pong_deadline, token},
        Map.get(state.deps, :pong_timeout_ms, 90_000)
      )

    %{state | deps: Map.merge(state.deps, %{pong_timer: timer, pong_token: token})}
  end

  defp push(payload, state), do: {:push, {:text, JSON.encode!(payload)}, state}

  defp push_many(payloads, state),
    do: {:push, Enum.map(payloads, &{:text, JSON.encode!(&1)}), state}

  defp stop_with(payload, state),
    do: {:stop, :normal, 1000, {:text, JSON.encode!(payload)}, state}

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value
  defp string(value), do: to_string(value)
  defp db(state), do: Map.get(state.deps, :db, Tightbeam.DB)
  defp conn_registry(state), do: Map.get(state.deps, :conn_registry, Tightbeam.ConnRegistry)
  defp typing_limit(state), do: Map.get(state.deps, :typing_per_sec, 2)
  defp pair_limit(state), do: Map.get(state.deps, :pair_per_min, 5)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
