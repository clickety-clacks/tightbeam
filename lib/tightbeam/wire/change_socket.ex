defmodule Tightbeam.Wire.ChangeSocket do
  @moduledoc "The live-only state-change WebSocket at `/ws/changes`."

  @behaviour WebSock

  alias Tightbeam.Devices
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.StateVisibility

  @max_subscriptions 100
  @filter_keys ~w(classes sessionKey workItemId origin principal)

  defstruct phase: :unauthed,
            user_id: nil,
            device_id: nil,
            is_admin: false,
            subscriptions: %{},
            seq: 0,
            heartbeat_timer: nil,
            deps: %{}

  @impl true
  def init(deps), do: {:ok, %__MODULE__{deps: Map.new(deps)}}

  @impl true
  def handle_in({bytes, opcode: :text}, state) do
    case JSON.decode(bytes) do
      {:ok, message} when is_map(message) -> route(message, state)
      _ -> invalid("malformed json", state)
    end
  end

  def handle_in({_bytes, opcode: :binary}, state),
    do: invalid("binary frames are unsupported", state)

  @impl true
  def handle_info({:firehose_notice, notice}, %{phase: :live} = state) do
    cond do
      revoked?(notice, state) ->
        {:stop, :normal, 1008, state}

      visible?(notice, state) ->
        {frames, seq} = matching_frames(notice, state)

        case frames do
          [] -> {:ok, state}
          _ -> {:push, Enum.map(frames, &{:text, JSON.encode!(&1)}), %{state | seq: seq}}
        end

      true ->
        {:ok, state}
    end
  end

  def handle_info({:firehose_notice, _notice}, state), do: {:ok, state}

  def handle_info(:firehose_heartbeat, %{phase: :live} = state) do
    state = schedule_heartbeat(state)
    push(%{"type" => "heartbeat", "seq" => state.seq}, state)
  end

  def handle_info(:firehose_heartbeat, state), do: {:ok, state}

  def handle_info(:firehose_overflow, state),
    do: {:stop, :normal, 4008, {:text, JSON.encode!(error("slow consumer"))}, state}

  @impl true
  def handle_control({_bytes, opcode: :ping}, state), do: {:ok, state}
  def handle_control({_bytes, opcode: :pong}, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.heartbeat_timer)
    if state.phase == :live, do: Hub.unregister(hub(state), self())
    :ok
  end

  defp route(%{"type" => "auth"} = message, %{phase: :unauthed} = state),
    do: authenticate(message, state)

  defp route(_message, %{phase: :unauthed} = state),
    do: stop_with(auth_failure("auth_failed"), 1008, state)

  defp route(%{"type" => "subscribe"} = message, state), do: subscribe(message, state)
  defp route(%{"type" => "unsubscribe"} = message, state), do: unsubscribe(message, state)
  defp route(_message, state), do: invalid("unsupported request", state)

  defp authenticate(message, state) do
    case Devices.by_token(db(state), string(message["token"])) do
      nil ->
        known = Devices.by_id(db(state), string(message["deviceId"]))

        reason =
          case known do
            %{status: "pending"} -> "device_not_approved"
            %{status: "allowlisted"} -> "token_revoked"
            _ -> "auth_failed"
          end

        stop_with(auth_failure(reason), 1008, state)

      device ->
        :ok = Hub.register(hub(state), self())

        state = %{
          state
          | phase: :live,
            user_id: device.user_id,
            device_id: device.device_id,
            is_admin: device.is_admin
        }

        push(
          %{
            "type" => "auth_result",
            "success" => true,
            "userId" => device.user_id,
            "isAdmin" => device.is_admin
          },
          schedule_heartbeat(state)
        )
    end
  end

  defp subscribe(message, state) do
    id = message["subscriptionId"]

    cond do
      message["protocolVersion"] != 1 ->
        invalid("protocolVersion must be 1", state)

      not (is_binary(id) and id != "") ->
        invalid("subscriptionId is required", state)

      Map.has_key?(state.subscriptions, id) ->
        invalid("duplicate subscriptionId", state)

      map_size(state.subscriptions) >= @max_subscriptions ->
        invalid("subscription cap is #{@max_subscriptions}", state)

      true ->
        case normalize_filters(message["filters"]) do
          {:ok, filters} ->
            state = %{state | subscriptions: Map.put(state.subscriptions, id, filters)}
            push(%{"type" => "subscription_ready", "subscriptionId" => id}, state)

          :error ->
            invalid("invalid filters", state)
        end
    end
  end

  defp unsubscribe(message, state) do
    id = message["subscriptionId"]

    if is_binary(id) and Map.has_key?(state.subscriptions, id) do
      state = %{state | subscriptions: Map.delete(state.subscriptions, id)}
      push(%{"type" => "subscription_removed", "subscriptionId" => id}, state)
    else
      invalid("unknown subscriptionId", state)
    end
  end

  defp normalize_filters(nil), do: {:ok, %{}}
  defp normalize_filters(filters) when filters == %{}, do: {:ok, %{}}

  defp normalize_filters(filters) when is_map(filters) do
    valid_keys? = Enum.all?(Map.keys(filters), &(&1 in @filter_keys))

    valid_values? =
      Enum.all?(filters, fn
        {"classes", values} -> is_list(values) and Enum.all?(values, &is_binary/1)
        {_key, value} -> is_nil(value) or is_binary(value)
      end)

    if valid_keys? and valid_values?, do: {:ok, filters}, else: :error
  end

  defp normalize_filters(_filters), do: :error

  defp matching_frames(notice, state) do
    Enum.reduce(state.subscriptions, {[], state.seq}, fn {id, filters}, {frames, seq} ->
      if matches?(notice, filters) do
        next = seq + 1

        frame =
          notice
          |> Map.put("type", "change")
          |> Map.put("schemaVersion", 1)
          |> Map.put("subscriptionId", id)
          |> Map.put("seq", next)

        {[frame | frames], next}
      else
        {frames, seq}
      end
    end)
    |> then(fn {frames, seq} -> {Enum.reverse(frames), seq} end)
  end

  defp matches?(notice, filters) do
    refs = notice["refs"] || %{}

    class_match? =
      case filters["classes"] do
        nil -> true
        prefixes -> Enum.any?(prefixes, &String.starts_with?(notice["class"] || "", &1))
      end

    class_match? and
      Enum.all?(~w(sessionKey workItemId origin principal), fn key ->
        is_nil(filters[key]) or filters[key] == refs[key]
      end)
  end

  defp visible?(notice, state) do
    payload = notice["payload"] || %{}

    not secret_payload?(payload) and
      StateVisibility.visible?(db(state), notice, state.user_id, state.is_admin)
  end

  defp revoked?(%{"class" => "device.revoked", "refs" => refs}, state),
    do: refs["deviceId"] == state.device_id

  defp revoked?(%{"class" => "session.retired"} = notice, state) do
    payload = notice["payload"] || %{}
    refs = notice["refs"] || %{}
    payload["ownerUserId"] == state.user_id or refs["ownerUserId"] == state.user_id
  end

  defp revoked?(_notice, _state), do: false

  defp secret_payload?(payload) when is_map(payload) do
    Enum.any?(payload, fn {key, value} ->
      key in ["cliToken", "token", "identityToken"] or secret_payload?(value)
    end)
  end

  defp secret_payload?(payload) when is_list(payload), do: Enum.any?(payload, &secret_payload?/1)
  defp secret_payload?(_payload), do: false

  defp schedule_heartbeat(state) do
    cancel_timer(state.heartbeat_timer)
    timer = Process.send_after(self(), :firehose_heartbeat, heartbeat_ms(state))
    %{state | heartbeat_timer: timer}
  end

  defp invalid(message, state), do: push(error(message), state)

  defp error(message),
    do: %{"type" => "error", "code" => "invalid_request", "message" => message}

  defp auth_failure(reason),
    do: %{"type" => "auth_result", "success" => false, "reason" => reason}

  defp push(payload, state), do: {:push, {:text, JSON.encode!(payload)}, state}

  defp stop_with(payload, code, state),
    do: {:stop, :normal, code, {:text, JSON.encode!(payload)}, state}

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""
  defp db(state), do: Map.get(state.deps, :db, Tightbeam.DB)
  defp hub(state), do: Map.get(state.deps, :firehose_hub, Hub)
  defp heartbeat_ms(state), do: Map.get(state.deps, :firehose_heartbeat_ms, 15_000)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
