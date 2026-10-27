defmodule Tightbeam.Wire.ChangeSocket do
  @moduledoc "State-change authentication and delivery; router activation is composed separately."
  @behaviour WebSock
  alias Tightbeam.Firehose.{Hub, Publisher}
  alias Tightbeam.StateResources
  alias Tightbeam.Devices
  alias Tightbeam.Org
  alias Tightbeam.Wire.OperatorSession
  @max_subscriptions 100
  @turn_classes ~w(turn.queued turn.started turn.ended)
  @filter_keys ~w(classes sessionKey workItemId origin principal)
  defstruct phase: :unauthed,
            user_id: nil,
            device_id: nil,
            principal_kind: nil,
            principal_id: nil,
            credential_digest: nil,
            selected_session_key: nil,
            operator_default_read_principal: false,
            is_admin: false,
            subscriptions: %{},
            heartbeat_timer: nil,
            hub_monitor: nil,
            backlog_counter: nil,
            deps: %{}

  @impl true
  def init(deps) do
    state = %__MODULE__{deps: Map.new(deps)}
    pid = GenServer.whereis(hub(state))
    ref = Process.monitor(pid)
    backlog_counter = :atomics.new(1, signed: false)
    :ok = Hub.register(pid, self(), %{mode: :pending, backlog_counter: backlog_counter})
    {:ok, %{state | hub_monitor: ref, backlog_counter: backlog_counter}}
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
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{hub_monitor: ref} = state),
    do: {:stop, :normal, 1012, state}

  def handle_info({:firehose_notice, notice}, %{phase: :live} = state) do
    state = release_backlog_bytes(state, {:firehose_notice, notice})
    await_delivery_release(state, notice)

    try do
      push(notice, state)
    rescue
      ArgumentError -> {:stop, :normal, 1008, state}
    end
  end

  def handle_info({:firehose_notice, _} = message, state),
    do: {:ok, release_backlog_bytes(state, message)}

  def handle_info({:firehose_control, frame} = message, %{phase: :live} = state) do
    state = release_backlog_bytes(state, message)
    push(frame, state)
  end

  def handle_info({:firehose_control, _} = message, state),
    do: {:ok, release_backlog_bytes(state, message)}

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

  defp release_backlog_bytes(%{backlog_counter: counter} = state, message)
       when not is_nil(counter) do
    :atomics.sub(counter, 1, :erlang.external_size(message))
    state
  end

  defp release_backlog_bytes(state, _message), do: state

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
      OperatorSession.operator_token?(token, state.deps) ->
        authenticate_operator(message, token, state)

      session = active_session(state, token) ->
        :ok =
          Hub.register(hub(state), self(), %{
            mode: :filtered,
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

  defp authenticate_operator(message, token, state) do
    default_read_principal = not Map.has_key?(message, "asUser")

    user_result =
      if default_read_principal,
        do: OperatorSession.resolve_default_read_principal(db(state)),
        else: OperatorSession.resolve_user(db(state), message["asUser"])

    with {:ok, user} <- user_result,
         {:ok, selected_session_key} <- operator_selected_session(db(state), user, message) do
      :ok =
        Hub.register(hub(state), self(), %{
          mode: :filtered,
          user_id: user.user_id,
          principal_kind: :user,
          principal_id: user.user_id,
          is_admin: user.is_admin
        })

      state = %{
        state
        | phase: :live,
          user_id: user.user_id,
          principal_kind: :user,
          principal_id: user.user_id,
          is_admin: user.is_admin,
          operator_default_read_principal: default_read_principal,
          selected_session_key: selected_session_key,
          credential_digest: credential_digest(token)
      }

      auth_result = %{
        "type" => "auth_result",
        "success" => true,
        "userId" => user.user_id,
        "isAdmin" => user.is_admin
      }

      auth_result =
        if is_binary(selected_session_key),
          do: Map.put(auth_result, "sessionKey", selected_session_key),
          else: auth_result

      push(
        auth_result,
        schedule_heartbeat(state)
      )
    else
      {:error, reason} ->
        stop_with(auth_failure(reason), 1008, state)
    end
  end

  defp operator_selected_session(_db, _user, %{"sessionKey" => nil}), do: {:ok, nil}

  defp operator_selected_session(_db, _user, %{} = message)
       when not is_map_key(message, "sessionKey"), do: {:ok, nil}

  defp operator_selected_session(db, user, %{"sessionKey" => session_key})
       when is_binary(session_key) and session_key != "" do
    case OperatorSession.resolve(db, %{
           "asUser" => user.user_id,
           "sessionKey" => session_key
         }) do
      {:ok, _resolved_user, session} -> {:ok, session.session_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp operator_selected_session(_db, _user, _message), do: {:error, "invalid_message"}

  defp subscribe(message, state) do
    id = message["subscriptionId"]

    cond do
      Map.has_key?(message, "protocolVersion") and
          message["protocolVersion"] != 2 ->
        invalid("protocolVersion must be 2", state)

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
                :ok = Hub.begin_subscribe(hub(state), self(), id, filters)
                state = %{state | subscriptions: Map.put(state.subscriptions, id, filters)}

                :ok =
                  Hub.finish_subscribe(
                    hub(state),
                    self(),
                    id,
                    active_turn_notices(state, filters)
                  )

                {:ok, state}

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

  defp authorized_filters(%{selected_session_key: session_key}, filters)
       when is_binary(session_key) do
    if filters["sessionKey"] == session_key do
      :ok
    else
      {:error, "sessionKey must match selected session"}
    end
  end

  defp authorized_filters(_state, _filters), do: :ok

  defp schedule_heartbeat(state) do
    cancel_timer(state.heartbeat_timer)
    timer = Process.send_after(self(), :firehose_heartbeat, heartbeat_ms(state))
    %{state | heartbeat_timer: timer}
  end

  defp active_turn_notices(state, filters) do
    session_key = filters["sessionKey"]

    if is_binary(session_key) do
      StateResources.query_active_turns_for_session(db(state), session_key)
      |> Enum.map(fn turn ->
        class = if turn.status == "queued", do: "turn.queued", else: "turn.started"
        Publisher.committed_notice(class, turn, %{"sessionKey" => session_key})
      end)
      |> Enum.filter(&class_filter_matches?(filters["classes"], &1["class"]))
    else
      []
    end
  end

  defp class_filter_matches?(nil, class), do: class in @turn_classes

  defp class_filter_matches?(classes, class) when is_list(classes),
    do: Enum.any?(classes, &String.starts_with?(class, &1))

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
  defp credential_current?(%{selected_session_key: key} = state) when is_binary(key) do
    with {:ok, user, _session} <-
           OperatorSession.resolve(db(state), %{
             "asUser" => state.user_id,
             "sessionKey" => key
           }),
         true <- user.is_admin == state.is_admin,
         token when is_binary(token) <- state.deps[:cli_token] do
      credential_digest(token) == state.credential_digest
    else
      _ -> false
    end
  end

  defp credential_current?(state) do
    case state.principal_kind do
      :session ->
        case Org.get(db(state), state.principal_id) do
          %{state: "active", cli_token: token} when is_binary(token) ->
            Plug.Crypto.secure_compare(credential_digest(token), state.credential_digest)

          _other ->
            false
        end

      :user when is_nil(state.device_id) ->
        user_result =
          if state.operator_default_read_principal,
            do: OperatorSession.resolve_default_read_principal(db(state)),
            else: OperatorSession.resolve_user(db(state), state.user_id)

        with {:ok, user} <- user_result,
             true <- user.user_id == state.user_id,
             true <- user.is_admin == state.is_admin,
             token when is_binary(token) <- state.deps[:cli_token] do
          credential_digest(token) == state.credential_digest
        else
          _ -> false
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
