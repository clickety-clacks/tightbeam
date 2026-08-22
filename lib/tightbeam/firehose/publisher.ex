defmodule Tightbeam.Firehose.Publisher do
  @moduledoc "Post-commit translation from accepted dispatch verbs to live notices."

  alias Tightbeam.Firehose.{Hub, Registry}
  alias Tightbeam.StateResources

  @state_verbs %{
    "work-item-create" => {"work_item.created", &StateResources.work_item/1},
    "work-item-update" => {"work_item.updated", &StateResources.work_item/1},
    "work-item-icebox" => {"work_item.iceboxed", &StateResources.work_item/1},
    "work-item-reopen" => {"work_item.reopened", &StateResources.work_item/1},
    "work-item-close" => {"work_item.closed", &StateResources.work_item/1},
    "work-item-fail" => {"work_item.failed", &StateResources.work_item/1},
    "assign" => {"assignment.opened", &StateResources.assignment/1},
    "dispatch" => {"assignment.opened", &StateResources.assignment/1},
    "reopen-assignment" => {"assignment.reopened", &StateResources.assignment/1},
    "revoke-assignment" => {"assignment.closed", &StateResources.assignment/1},
    "attest" => {"attest.filed", &StateResources.attest/1},
    "wake" => {"wake.scheduled", &StateResources.wake/1},
    "condition" => {"condition_fact.filed", &StateResources.condition_fact/1},
    "artifact-record" => {"artifact.recorded", &StateResources.artifact/1},
    "ask" => {"decision_request.opened", &StateResources.decision_request/1},
    "answer" => {"decision_request.ruled", &StateResources.decision_request/1},
    "rule" => {"decision_request.ruled", &StateResources.decision_request/1},
    "effort-rule" => {"decision_request.ruled", &StateResources.decision_request/1},
    "withdraw" => {"decision_request.withdrawn", &StateResources.decision_request/1},
    "approve-device" => {"device.approved", &StateResources.device/1},
    "deny-device" => {"device.denied", &StateResources.device/1},
    "revoke-device" => {"device.revoked", &StateResources.device/1},
    "role-create" => {"role.created", &StateResources.role/1},
    "role-bind" => {"role.bound", &StateResources.role/1},
    "role-rm" => {"role.removed", &StateResources.role/1},
    "spawn" => {"session.spawned", &StateResources.session/1},
    "retire" => {"session.retired", &StateResources.session/1},
    "add-user" => {"user.added", &StateResources.user/1},
    "read-marker-set" => {"read_marker.updated", &StateResources.read_marker/1},
    "read-marker-clear" => {"read_marker.updated", &StateResources.read_marker/1},
    "critical" => {"critical_lease.updated", &StateResources.critical_state/1}
  }

  @direct_state_classes ~w(message.created wake.fired prod.fired turn.started turn.ended)
  @variant_verb_effects %{
    "work-item-create" => ["wake.scheduled"],
    "wake" => ["wake.canceled"],
    "attest" => ["assignment.closed"]
  }

  @spec state_verbs() :: [String.t()]
  def state_verbs, do: Map.keys(@state_verbs)

  @doc "State effects attached to the gateway's actual immutable handler table."
  @spec handler_effects(Tightbeam.Dispatch.handlers()) :: %{String.t() => [String.t()]}
  def handler_effects(handlers) do
    Map.new(handlers, fn {verb, _handler} -> {verb, effect_classes(verb)} end)
  end

  @spec emitted_state_classes(Tightbeam.Dispatch.handlers()) :: [String.t()]
  def emitted_state_classes(handlers) do
    handlers
    |> handler_effects()
    |> Map.values()
    |> List.flatten()
    |> Kernel.++(@direct_state_classes)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp effect_classes(verb) do
    primary =
      case @state_verbs[verb] do
        {class, _serializer} -> [class]
        nil -> []
      end

    primary ++ Map.get(@variant_verb_effects, verb, [])
  end

  @spec accepted(map(), term()) :: :ok
  def accepted(call, result), do: Hub.accepted(nil, call, result)

  @spec accepted(GenServer.server(), map(), term()) :: :ok
  def accepted(db, call, result), do: Hub.accepted(db, call, result)

  @doc "Capture state needed to authorize and serialize a delete after it commits."
  @spec capture_before(GenServer.server(), map()) :: map()
  def capture_before(db, %{verb: "role-rm"} = call) do
    Map.put(call, :firehose_before, StateResources.query_role(db, call.params[:name]))
  end

  def capture_before(_db, call), do: call

  @spec denied(map(), map()) :: :ok
  def denied(call, error), do: Hub.denied(call, error)

  @spec observed_accepted(map()) :: :ok
  def observed_accepted(call), do: Hub.publish(observation_notice("verb.accepted", call))

  @spec accepted_notices(GenServer.server() | nil, map(), term()) :: [map()]
  def accepted_notices(db, call, result) do
    [observation_notice("verb.accepted", call)] ++ state_notices(db, call, result)
  end

  defp state_notices(db, call, result) do
    primary = List.wrap(state_notice(db, call, result))

    case {call.verb, result} do
      {"attest", %{assignment: %{state: state} = assignment}}
      when state in ~w(completed surrendered revoked) ->
        primary ++ [build("assignment.closed", call, assignment, &StateResources.assignment/1)]

      _ ->
        primary
    end
  end

  @spec denied_notices(map(), map()) :: [map()]
  def denied_notices(call, error) do
    verb = observation_notice("verb.denied", call, error)

    if is_binary(error[:rule] || error["rule"]) do
      [verb, observation_notice("rail.denied", call, error)]
    else
      [verb]
    end
  end

  @spec committed(String.t(), map(), map()) :: :ok
  def committed(class, payload, refs \\ %{}), do: Hub.committed(class, payload, refs)

  @spec lifecycle(String.t(), map(), map()) :: :ok
  def lifecycle(class, payload, refs \\ %{}) do
    Hub.publish(%{
      "class" => class,
      "op" => "observe",
      "occurredAt" => System.system_time(:millisecond),
      "refs" => refs,
      "payload" => StateResources.observation(payload)
    })
  end

  @spec committed_notice(String.t(), map(), map()) :: map()
  def committed_notice(class, payload, refs) do
    {:ok, row} = Registry.fetch(class)
    projection = apply(StateResources, row.serializer, [payload])

    %{
      "class" => class,
      "resource" => row.resource,
      "op" => row.op,
      "occurredAt" => occurred_at(projection),
      "refs" =>
        refs
        |> Map.put_new(row.primary_ref, projection[row.primary_ref] || projection["id"])
        |> Map.reject(fn {_key, value} -> is_nil(value) end),
      "payload" => projection
    }
  end

  @spec state_notice(map(), term()) :: map() | nil
  def state_notice(call, result), do: state_notice(nil, call, result)

  def state_notice(db, %{verb: "wake", params: %{cancel_wake_id: wake_id}} = call, _result)
      when is_binary(wake_id) do
    build(
      "wake.canceled",
      call,
      Tightbeam.Wakes.get(db, wake_id) || %{wake_id: wake_id},
      &StateResources.wake/1
    )
  end

  def state_notice(_db, _call, %{changed: false}), do: nil
  def state_notice(_db, %{firehose_changed: false}, _result), do: nil

  def state_notice(db, %{verb: verb} = call, result) do
    case @state_verbs[verb] do
      {class, serializer} -> build(class, call, canonical_result(db, call, result), serializer)
      nil -> nil
    end
  end

  defp canonical_result(nil, _call, result), do: result

  defp canonical_result(db, %{verb: verb} = call, result)
       when verb in ~w(work-item-create work-item-update work-item-icebox work-item-reopen work-item-close work-item-fail) do
    id = result[:id] || result["id"] || call.params[:work_item_id]
    StateResources.query_work_item(db, id, call) || result
  end

  defp canonical_result(db, %{verb: verb} = call, result)
       when verb in ~w(assign dispatch reopen-assignment revoke-assignment) do
    id = result[:id] || result["id"] || result[:assignment_id] || call.params[:assignment_id]
    StateResources.query_assignment(db, id, call) || result
  end

  defp canonical_result(db, %{verb: "wake"} = call, result) do
    id = result[:wake_id] || result["wakeId"] || call.params[:wake_id]
    StateResources.query_wake(db, id) || result
  end

  defp canonical_result(db, %{verb: "artifact-record"}, result) do
    id = result[:artifact_id] || result["artifactId"] || result[:id]
    StateResources.query_artifact(db, id) || result
  end

  defp canonical_result(db, %{verb: verb} = call, result)
       when verb in ~w(role-create role-bind) do
    StateResources.query_role(db, call.params[:name]) || result
  end

  defp canonical_result(_db, %{verb: "role-rm"} = call, result) do
    Map.get(call, :firehose_before) || result
  end

  defp canonical_result(db, %{verb: "spawn"}, result) do
    id = result[:session_key] || result["sessionKey"] || result[:key]
    StateResources.query_session(db, id) || result
  end

  defp canonical_result(db, %{verb: "retire"} = call, result) do
    StateResources.query_session(db, call.session_key) || result
  end

  defp canonical_result(db, %{verb: verb} = call, result)
       when verb in ~w(approve-device deny-device revoke-device) do
    StateResources.query_device(db, call.params[:device_id]) || result
  end

  defp canonical_result(db, %{verb: "add-user"} = call, result) do
    StateResources.query_user(db, call.params[:user_id]) || result
  end

  defp canonical_result(db, %{verb: verb} = call, result)
       when verb in ~w(read-marker-set read-marker-clear) do
    user_id = result[:user_id] || result["userId"]
    StateResources.query_read_marker(db, user_id, call.params[:scope_key]) || result
  end

  defp canonical_result(db, %{verb: "critical"} = call, result) do
    StateResources.query_critical_state(db, call.session_key) || result
  end

  defp canonical_result(_db, _call, result), do: result

  defp build(class, call, result, serializer) do
    {:ok, row} = Registry.fetch(class)
    payload = result |> unwrap(row.resource) |> serializer.()
    refs = refs(call, payload, row.primary_ref)

    %{
      "class" => class,
      "resource" => row.resource,
      "op" => row.op,
      "occurredAt" => occurred_at(payload),
      "refs" => refs,
      "payload" => payload
    }
  end

  @spec observation_notice(String.t(), map()) :: map()
  def observation_notice(class, call), do: observation_notice(class, call, %{})

  @spec observation_notice(String.t(), map(), map()) :: map()
  def observation_notice(class, call, details) do
    %{
      "class" => class,
      "op" => "observe",
      "occurredAt" => System.system_time(:millisecond),
      "refs" => base_refs(call),
      "payload" =>
        details
        |> StateResources.observation()
        |> Map.put("verb", call.verb)
    }
  end

  defp unwrap(result, "work-items"), do: wrapped(result, [:work_item, "workItem"])
  defp unwrap(result, "assignments"), do: wrapped(result, [:assignment, "assignment"])
  defp unwrap(result, "attests"), do: wrapped(result, [:attest, "attest"])
  defp unwrap(result, "wakes"), do: wrapped(result, [:wake, "wake"])

  defp unwrap(result, "decision-requests"),
    do: wrapped(result, [:decision_request, "decisionRequest"])

  defp unwrap(result, "sessions"), do: wrapped(result, [:session, "session"])
  defp unwrap(result, "roles"), do: wrapped(result, [:role, "role"])
  defp unwrap(result, "artifacts"), do: wrapped(result, [:artifact, "artifact"])
  defp unwrap(result, "read-markers"), do: wrapped(result, [:read_marker, "readMarker"])
  defp unwrap(result, "messages"), do: wrapped(result, [:message, "message"])
  defp unwrap(result, "condition-facts"), do: wrapped(result, [:fact, "fact"])
  defp unwrap(result, "critical-state"), do: wrapped(result, [:critical_state, "criticalState"])

  defp unwrap(result, "devices"),
    do: wrapped(result, [:device, :approved, "device", "approved"])

  defp unwrap(result, _resource) when is_map(result), do: result

  defp unwrap(result, _resource), do: %{"value" => result}

  defp wrapped(result, keys) when is_map(result),
    do: Enum.find_value(keys, result, &Map.get(result, &1))

  defp wrapped(result, _keys), do: %{"value" => result}

  defp refs(call, payload, primary_ref) do
    base_refs(call)
    |> Map.put(primary_ref, primary_value(payload, primary_ref, call))
    |> Map.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp base_refs(call) do
    params = Map.get(call, :params, %{})

    %{
      "sessionKey" => Map.get(call, :session_key) || params[:session_key],
      "workItemId" => params[:work_item_id],
      "assignmentId" => params[:assignment_id],
      "origin" => Map.get(call, :origin),
      "principal" => principal(Map.get(call, :principal))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp primary_value(payload, key, call) do
    params = Map.get(call, :params, %{})
    atom_key = primary_param(key)

    payload[key] || payload["id"] || params[atom_key] ||
      if(key == "sessionKey", do: Map.get(call, :session_key), else: nil)
  end

  defp primary_param("workItemId"), do: :work_item_id
  defp primary_param("assignmentId"), do: :assignment_id
  defp primary_param("attestId"), do: :attest_id
  defp primary_param("wakeId"), do: :wake_id
  defp primary_param("decisionRequestId"), do: :request_id
  defp primary_param("sessionKey"), do: :session_key
  defp primary_param("artifactId"), do: :artifact_id
  defp primary_param("deviceId"), do: :device_id
  defp primary_param("role"), do: :name
  defp primary_param(_key), do: :id

  defp occurred_at(payload) do
    payload["updatedAt"] || payload["createdAt"] || payload["openedAt"] || payload["ts"] ||
      System.system_time(:millisecond)
  end

  defp principal(nil), do: nil
  defp principal({kind, value}) when is_binary(value), do: "#{kind}:#{value}"
  defp principal(value) when is_binary(value), do: value
  defp principal(_value), do: nil
end
