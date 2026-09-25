defmodule Tightbeam.Wire.ChangeSocket do
  @moduledoc "State-change authentication and delivery; router activation is composed separately."
  @behaviour WebSock
  alias Tightbeam.Firehose.{Hub, Publisher}
  alias Tightbeam.StateVisibility
  alias Tightbeam.Devices
  alias Tightbeam.Org
  @max_subscriptions 100
  @filter_keys ~w(classes sessionKey workItemId origin principal)
  defstruct phase: :unauthed,
            user_id: nil,
            device_id: nil,
            principal_kind: nil,
            principal_id: nil,
            credential_digest: nil,
            is_admin: false,
            subscriptions: %{},
            heartbeat_timer: nil,
            deps: %{}

  @impl true
  def init(deps) do
    state = %__MODULE__{deps: Map.new(deps)}
    :ok = Hub.register(hub(state), self(), %{mode: :pending})
    {:ok, state}
  end

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
    await_delivery_release(state, notice)
    Hub.delivered(hub(state), self())

    if StateVisibility.visible?(state.deps[:db], notice, visibility_principal(state)) do
      try do
        push(notice, state)
      rescue
        ArgumentError -> {:stop, :normal, 1008, state}
      end
    else
      {:stop, :normal, 1008, state}
    end
  end

  def handle_info({:firehose_notice, _}, state), do: {:ok, state}

  def handle_info(:firehose_heartbeat, %{phase: :live} = state) do
    if credential_current?(state) do
      state = schedule_heartbeat(state)
      push(%{"type" => "heartbeat", "seq" => Hub.sequence(hub(state), self())}, state)
    else
      {:stop, :normal, 1008, state}
    end
  end

  def handle_info(:firehose_heartbeat, state), do: {:ok, state}
  def handle_info(:firehose_overflow, state), do: {:stop, :normal, 4008, state}
  def handle_info(:firehose_revoked, state), do: {:stop, :normal, 1008, state}

  def handle_info(:firehose_shutdown, state) do
    Hub.shutdown_delivered(hub(state), self())
    {:stop, :normal, 1012, state}
  end

  @impl true
  def handle_control({_bytes, opcode: :ping}, state), do: {:ok, state}
  def handle_control({_bytes, opcode: :pong}, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.heartbeat_timer)
    Hub.unregister(hub(state), self())
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
    token = string(message["token"])

    cond do
      token == Map.get(state.deps, :cli_token) ->
        stop_with(auth_failure("org_token_read_forbidden"), 1008, state)

      session = active_session(state, token) ->
        :ok =
          Hub.register(hub(state), self(), %{
            mode: :filtered,
            db: db(state),
            user_id: session.owner_user_id,
            principal_kind: :session,
            principal_id: session.session_key,
            is_admin: false
          })

        state = %{
          state
          | phase: :live,
            user_id: session.owner_user_id,
            principal_kind: :session,
            principal_id: session.session_key,
            credential_digest: credential_digest(token),
            is_admin: false
        }

        push(
          %{
            "type" => "auth_result",
            "success" => true,
            "sessionKey" => session.session_key,
            "userId" => session.owner_user_id,
            "isAdmin" => false
          },
          schedule_heartbeat(state)
        )

      device = Devices.by_token(db(state), token) ->
        :ok =
          Hub.register(hub(state), self(), %{
            mode: :filtered,
            db: db(state),
            user_id: device.user_id,
            device_id: device.device_id,
            principal_kind: :user,
            principal_id: device.user_id,
            is_admin: device.is_admin
          })

        state = %{
          state
          | phase: :live,
            user_id: device.user_id,
            device_id: device.device_id,
            principal_kind: :user,
            principal_id: device.user_id,
            credential_digest: credential_digest(token),
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

      true ->
        known = Devices.by_id(db(state), string(message["deviceId"]))

        reason =
          case known do
            %{status: "pending"} -> "device_not_approved"
            %{status: "allowlisted"} -> "token_revoked"
            _ -> "auth_failed"
          end

        stop_with(auth_failure(reason), 1008, state)
    end
  end

  defp subscribe(message, state) do
    id = message["subscriptionId"]

    cond do
      not canonical_subscribe_shape?(message) ->
        invalid("subscribe contains an unsupported key", state)

      not (is_binary(id) and id != "") ->
        invalid("subscriptionId is required", state)

      Map.has_key?(state.subscriptions, id) ->
        invalid("duplicate subscriptionId", state)

      map_size(state.subscriptions) >= @max_subscriptions ->
        invalid("subscription cap is #{@max_subscriptions}", state)

      true ->
        case normalize_filters(message["filters"]) do
          {:ok, filters} ->
            case authorized_filters(state, filters) do
              :ok ->
                :ok = Hub.subscribe(hub(state), self(), id, filters)
                state = %{state | subscriptions: Map.put(state.subscriptions, id, filters)}
                push(%{"type" => "subscription_ready", "subscriptionId" => id}, state)

              {:error, message} ->
                invalid(message, state)
            end

          :error ->
            invalid("invalid filters", state)
        end
    end
  end

  defp unsubscribe(message, state) do
    id = message["subscriptionId"]

    if is_binary(id) and Map.has_key?(state.subscriptions, id) do
      :ok = Hub.unsubscribe(hub(state), self(), id)
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

  defp canonical_subscribe_shape?(message) do
    Enum.all?(
      Map.keys(message),
      &(&1 in ["type", "protocolVersion", "subscriptionId", "filters"])
    ) and
      (not Map.has_key?(message, "protocolVersion") or message["protocolVersion"] == 1)
  end

  defp authorized_filters(%{principal_kind: :session, principal_id: session_key}, filters) do
    if filters["sessionKey"] == session_key do
      :ok
    else
      {:error, "sessionKey must match authenticated session"}
    end
  end

  defp authorized_filters(_state, _filters), do: :ok

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

  defp push(%{"class" => "kungfu.updated"} = payload, state),
    do: {:push, {:text, Publisher.encode_wire_notice(payload)}, state}

  defp push(%{"class" => _class} = payload, state),
    do: {:push, {:text, Publisher.encode_wire_notice(payload, model_catalog(state))}, state}

  defp model_catalog(state) do
    case state.deps[:model_catalog] || Tightbeam.ModelCatalog do
      catalog when is_map(catalog) -> catalog
      server -> Tightbeam.ModelCatalog.get(server)
    end
  end

  defp push(payload, state), do: {:push, {:text, JSON.encode!(payload)}, state}

  defp stop_with(payload, code, state),
    do: {:stop, :normal, code, {:text, JSON.encode!(payload)}, state}

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""
  defp db(state), do: Map.get(state.deps, :db, Tightbeam.DB)
  defp heartbeat_ms(state), do: Map.get(state.deps, :firehose_heartbeat_ms, 15_000)

  defp active_session(state, token) do
    case Org.active_session_key_by_cli_token(db(state), token) do
      nil -> nil
      session_key -> Org.get(db(state), session_key)
    end
  end

  # The revocation notice is best-effort. Heartbeats also compare the exact
  # credential generation so a lost notice cannot leave a revoked socket live.
  defp credential_current?(state) do
    case state.principal_kind do
      :session ->
        case Org.get(db(state), state.principal_id) do
          %{state: "active", cli_token: token} when is_binary(token) ->
            Plug.Crypto.secure_compare(credential_digest(token), state.credential_digest)

          _other ->
            false
        end

      _ ->
        case Devices.by_id(db(state), state.device_id) do
          %{status: "allowlisted", token: token} when is_binary(token) ->
            Plug.Crypto.secure_compare(credential_digest(token), state.credential_digest)

          _other ->
            false
        end
    end
  end

  defp credential_digest(token), do: :crypto.hash(:sha256, token)

  defp visibility_principal(%{principal_kind: :session, principal_id: session_key}),
    do: %{kind: "session", id: session_key}

  defp visibility_principal(%{principal_kind: :user, principal_id: user_id, is_admin: is_admin}),
    do: %{kind: "user", id: user_id, is_admin: is_admin}

  defp visibility_principal(state),
    do: %{kind: "user", id: state.user_id, is_admin: state.is_admin}

  defp await_delivery_release(state, notice) do
    case Map.get(state.deps, :firehose_delivery_barrier) do
      barrier when is_function(barrier, 1) -> barrier.(notice)
      nil -> :ok
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
  defp hub(state), do: Map.get(state.deps, :firehose_hub, Hub)
end
