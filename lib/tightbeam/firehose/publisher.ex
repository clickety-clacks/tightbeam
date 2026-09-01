defmodule Tightbeam.Firehose.Publisher do
  @moduledoc "Post-commit translation from accepted dispatch verbs to live notices."

  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.{Hub, Registry}
  alias Tightbeam.{ModelCatalog, StateResources}

  @work_item_public_shape MapSet.new(
                            ~w(id title specRefName specRefSha256 isBug ownerUserId state failReason createdByUser createdBySession createdAt priority rowVersion)
                          )

  # Preserve only the exact result-shaped payloads already emitted on current main.
  # Any additive drift still refuses at the shared Publisher boundary.
  @message_public_shape MapSet.new(
                          ~w(id seq sessionKey role messageType content timestamp sender deviceId clientMessageId replyToMessageId replyToClientMessageId llmVisibleMessageId attachments attentionTier rowVersion)
                        )
  @message_public_shape_without_type MapSet.delete(@message_public_shape, "messageType")
  @session_public_shape MapSet.new(
                          ~w(sessionKey displayName kind orderIndex isBuiltIn adopted ownerUserId origin spawnedBy handle archetype overrides identityName identityRevision harness provider model thinkingLevel modelContext host clearedThroughSeq state createdAt updatedAt mechanicalStatus rowVersion)
                        )
  @role_public_shape MapSet.new(
                       ~w(role name boundSessionKey ownerUserId createdAt updatedAt rowVersion)
                     )
  @role_removed_shape MapSet.new(~w(removed))
  @legacy_partial_shapes %{
    "work_item.created" => [
      MapSet.new(~w(id rowVersion)),
      @work_item_public_shape
    ],
    "work_item.updated" => [
      MapSet.new(~w(id ownerUserId rowVersion)),
      MapSet.new(~w(id title ownerUserId updatedAt rowVersion)),
      @work_item_public_shape
    ],
    "work_item.iceboxed" => [@work_item_public_shape],
    "work_item.reopened" => [@work_item_public_shape],
    "work_item.closed" => [@work_item_public_shape],
    "work_item.failed" => [@work_item_public_shape],
    "message.created" => [@message_public_shape, @message_public_shape_without_type],
    "session.updated" => [@session_public_shape],
    "role.created" => [@role_public_shape],
    "role.removed" => [@role_public_shape, @role_removed_shape]
  }

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
    "operator-ask" => {"decision_request.opened", &StateResources.decision_request/1},
    "operator-rule" => {"decision_request.ruled", &StateResources.decision_request/1},
    "operator-withdraw" => {"decision_request.withdrawn", &StateResources.decision_request/1},
    "return" => {"decision_request.returned", &StateResources.decision_request/1},
    "withdraw" => {"decision_request.withdrawn", &StateResources.decision_request/1},
    "approve-device" => {"device.approved", &StateResources.device/1},
    "deny-device" => {"device.denied", &StateResources.device/1},
    "revoke-device" => {"device.revoked", &StateResources.device/1},
    "role-create" => {"role.created", &StateResources.role/1},
    "role-bind" => {"role.bound", &StateResources.role/1},
    "role-rm" => {"role.removed", &StateResources.role/1},
    "spawn" => {"session.spawned", &StateResources.session/1},
    "add-user" => {"user.added", &StateResources.user/1},
    "read-marker-set" => {"read_marker.updated", &StateResources.read_marker/1},
    "read-marker-clear" => {"read_marker.updated", &StateResources.read_marker/1},
    "critical" => {"critical_lease.updated", &StateResources.critical_state/1}
  }

  @transactional_verbs MapSet.new(
                         ~w(work-item-create work-item-update work-item-icebox work-item-reopen work-item-close work-item-fail assign dispatch attest reopen-assignment revoke-assignment wake condition artifact-record read-marker-set read-marker-clear critical role-create role-bind role-rm spawn retire ask answer return rule effort-rule operator-ask operator-rule operator-withdraw withdraw approve-device deny-device revoke-device add-user promote-user config host-env-set host-env-unset register-host identity-edit identity-relearn learn unlearn kungfu-scaffold)
                       )

  @spec accepted(map(), term()) :: :ok
  def accepted(call, result), do: Hub.accepted(hub(call), nil, call, result)

  @spec accepted(GenServer.server(), map(), term()) :: :ok
  def accepted(db, call, result), do: Hub.accepted(hub(call), db, call, result)

  @spec transactional_verb?(String.t()) :: boolean()
  def transactional_verb?(verb), do: MapSet.member?(@transactional_verbs, verb)

  @spec accepted_after_handler(GenServer.server(), map(), term()) :: :ok
  def accepted_after_handler(db, call, result) do
    if transactional_verb?(call.verb),
      do: :ok,
      else: accepted(db, call, result)
  end

  @doc "Queue accepted notices on the transaction that committed their state."
  @spec accepted_in_txn(Txn.t(), map(), term()) :: :ok
  def accepted_in_txn(%Txn{} = txn, call, result) do
    Txn.handoff(txn, hub(call), {:accepted, nil, call, result})
  end

  @spec maybe_accepted_in_txn(Txn.t(), map(), term()) :: :ok
  def maybe_accepted_in_txn(%Txn{} = txn, %{firehose_in_txn: true} = call, result),
    do: accepted_in_txn(txn, call, result)

  def maybe_accepted_in_txn(%Txn{}, _call, _result), do: :ok

  @spec observed_accepted_in_txn(Txn.t(), map()) :: :ok
  def observed_accepted_in_txn(%Txn{} = txn, call) do
    Txn.handoff(txn, hub(call), {:publish, observation_notice("verb.accepted", call)})
  end

  @spec maybe_observed_accepted_in_txn(Txn.t(), map()) :: :ok
  def maybe_observed_accepted_in_txn(
        %Txn{} = txn,
        %{firehose_in_txn: true} = call
      ),
      do: observed_accepted_in_txn(txn, call)

  def maybe_observed_accepted_in_txn(%Txn{}, _call), do: :ok

  @doc "Capture state needed to authorize and serialize a delete after it commits."
  @spec capture_before(GenServer.server(), map()) :: map()
  def capture_before(db, %{verb: "role-rm"} = call) do
    Map.put(call, :firehose_before, StateResources.query_role(db, call.params[:name]))
  end

  def capture_before(_db, call), do: call

  @spec denied(map(), map()) :: :ok
  def denied(call, error), do: Hub.denied(hub(call), call, error)

  @spec denied_in_txn(Txn.t(), map(), map()) :: :ok
  def denied_in_txn(%Txn{} = txn, call, error) do
    Txn.handoff(txn, hub(call), {:denied, call, error})
  end

  @spec observed_accepted(map()) :: :ok
  def observed_accepted(call),
    do: Hub.publish(hub(call), observation_notice("verb.accepted", call))

  @spec accepted_notices(GenServer.server() | nil, map(), term()) :: [map()]
  def accepted_notices(db, call, result) do
    [observation_notice("verb.accepted", call)] ++ state_notices(db, call, result)
  end

  defp state_notices(db, call, result) do
    primary = List.wrap(state_notice(db, call, result))

    case {call.verb, result} do
      {"attest", %{assignment: %{state: "closed", outcome: outcome} = assignment}}
      when outcome in ~w(completed surrendered revoked) ->
        canonical_assignment = canonical_assignment_result(db, call, assignment)

        primary ++
          [
            build(
              "assignment.closed",
              call,
              canonical_assignment,
              &StateResources.assignment/1
            )
          ]

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

  @doc "Queue one committed state notice on the transaction that produced it."
  @spec committed_in_txn(Txn.t(), String.t(), map(), map()) :: :ok
  def committed_in_txn(%Txn{} = txn, class, payload, refs \\ %{}) do
    Txn.handoff(txn, Hub, {:committed, class, payload, refs})
  end

  @doc "Queue one exact source-invalidation notice on its committing transaction."
  @spec source_invalidation_in_txn(
          Txn.t(),
          GenServer.server(),
          String.t(),
          pos_integer(),
          integer(),
          map()
        ) :: :ok
  def source_invalidation_in_txn(
        %Txn{} = txn,
        hub,
        class,
        source_version,
        occurred_at,
        refs
      ) do
    Txn.handoff(
      txn,
      hub,
      {:publish, source_invalidation_notice(class, source_version, occurred_at, refs)}
    )
  end

  @doc false
  @spec source_invalidation_notice(String.t(), pos_integer(), integer(), map()) :: map()
  def source_invalidation_notice(class, source_version, occurred_at, refs)
      when is_binary(class) and is_integer(source_version) and source_version > 0 and
             is_integer(occurred_at) and is_map(refs) do
    row =
      case Registry.fetch_invalidation(class) do
        {:ok, row} -> row
        :error -> raise ArgumentError, "unregistered firehose source invalidation: #{class}"
      end

    actual_ref_set = refs |> Map.keys() |> Enum.sort()

    unless actual_ref_set in row.ref_sets and
             Enum.all?(refs, fn {_key, value} -> is_binary(value) and value != "" end) do
      raise ArgumentError,
            "firehose #{class} invalidation refs do not match the registry: " <>
              "got=#{inspect(actual_ref_set)} allowed=#{inspect(row.ref_sets)}"
    end

    %{
      "class" => class,
      "op" => row.op,
      "occurredAt" => occurred_at,
      "refs" => refs,
      "payload" => %{"sourceVersion" => source_version}
    }
  end

  def source_invalidation_notice(class, source_version, occurred_at, refs) do
    raise ArgumentError,
          "invalid firehose source invalidation: class=#{inspect(class)} " <>
            "sourceVersion=#{inspect(source_version)} occurredAt=#{inspect(occurred_at)} " <>
            "refs=#{inspect(refs)}"
  end

  @doc "Queue the existing message-created notice on the transaction that appended it."
  @spec message_in_txn(Txn.t(), String.t(), map(), String.t() | nil) :: :ok
  def message_in_txn(%Txn{} = txn, session_key, message, owner_user_id \\ nil) do
    owner_user_id =
      owner_user_id ||
        case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey = ?1", [session_key]) do
          [[owner]] -> owner
          [] -> nil
        end

    if is_binary(owner_user_id) do
      committed_in_txn(txn, "message.created", message, %{
        "messageId" => message.id,
        "sessionKey" => session_key,
        "ownerUserId" => owner_user_id
      })
    else
      :ok
    end
  end

  @doc "Queue the existing turn notice on the transaction that changed its state."
  @spec turn_in_txn(Txn.t(), String.t(), integer()) :: :ok
  def turn_in_txn(%Txn{} = txn, class, seq) when class in ~w(turn.started turn.ended) do
    case StateResources.query_turn_in_txn(txn, seq) do
      %{} = turn ->
        committed_in_txn(txn, class, turn, %{
          "turnSeq" => turn.seq,
          "sessionKey" => turn.session_key,
          "assignmentId" => turn.assignment_id,
          "workItemId" => turn.job_ref
        })

      nil ->
        :ok
    end
  end

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

  @doc "Queue one lifecycle observation on the transaction that recorded it."
  @spec lifecycle_in_txn(Txn.t(), String.t(), map(), map()) :: :ok
  def lifecycle_in_txn(%Txn{} = txn, class, payload, refs \\ %{}) do
    notice = %{
      "class" => class,
      "op" => "observe",
      "occurredAt" => System.system_time(:millisecond),
      "refs" => refs,
      "payload" => StateResources.observation(payload)
    }

    Txn.handoff(txn, Hub, {:publish, notice})
  end

  @doc "Queue one observational notice with the mutation's durable occurrence time."
  @spec observation_in_txn(Txn.t(), String.t(), map(), map(), integer()) :: :ok
  def observation_in_txn(%Txn{} = txn, class, payload, refs, occurred_at)
      when is_integer(occurred_at) do
    notice = %{
      "class" => class,
      "op" => "observe",
      "occurredAt" => occurred_at,
      "refs" => refs,
      "payload" => StateResources.observation(payload)
    }

    Txn.handoff(txn, Hub, {:publish, notice})
  end

  @doc false
  def encode_wire_notice(notice), do: encode_wire_notice(notice, ModelCatalog.get())

  @doc false
  def encode_wire_notice(%{"class" => class, "payload" => payload} = notice, catalog)
      when is_map(catalog) do
    case Registry.fetch(class) do
      {:ok, %{resource: "productions"}} ->
        JSON.encode!(notice)

      {:ok, %{resource: resource}} when is_map(payload) ->
        # Some current-main producers still publish result-shaped partial maps. Only a closed
        # R7/R7a item is eligible for RawJSON; the shared encoder remains strict for REST parity.
        cond do
          StateResources.item_has_secret_fields?(payload) ->
            raise ArgumentError, "#{resource} Publisher payload has a forbidden field"

          StateResources.item_shape_complete?(resource, payload) ->
            bytes = StateResources.encode_item(resource, payload, catalog)
            JSON.encode!(Map.put(notice, "payload", %StateResources.RawJSON{bytes: bytes}))

          permitted_legacy_payload?(class, payload) ->
            JSON.encode!(notice)

          true ->
            raise ArgumentError,
                  "#{resource} Publisher payload has no permitted legacy partial shape"
        end

      _ ->
        JSON.encode!(notice)
    end
  end

  def encode_wire_notice(notice, _catalog), do: JSON.encode!(notice)

  defp permitted_legacy_payload?(class, payload) do
    keys = MapSet.new(Map.keys(payload))
    Enum.any?(Map.get(@legacy_partial_shapes, class, []), &MapSet.equal?(&1, keys))
  end

  @spec committed_notice(String.t(), map(), map()) :: map()
  def committed_notice(class, payload, refs) do
    {:ok, row} = Registry.fetch(class)
    projection = apply(StateResources, row.serializer, [payload])

    resolved_refs =
      Enum.reduce(row.primary_refs, refs, fn primary_ref, resolved ->
        Map.put_new(
          resolved,
          primary_ref,
          projection[primary_ref] || projection["id"]
        )
      end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    require_primary_refs!(class, row.primary_refs, resolved_refs)

    %{
      "class" => class,
      "resource" => row.resource,
      "op" => row.op,
      "occurredAt" => occurred_at(projection),
      "refs" => resolved_refs,
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
    canonical_assignment_result(db, call, result)
  end

  defp canonical_assignment_result(nil, _call, result), do: result

  defp canonical_assignment_result(db, call, result) do
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
    refs = refs(call, payload, row.primary_refs)
    require_primary_refs!(class, row.primary_refs, refs)

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

  defp refs(call, payload, primary_refs) do
    Enum.reduce(primary_refs, base_refs(call), fn primary_ref, refs ->
      Map.put(refs, primary_ref, primary_value(payload, primary_ref, call))
    end)
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
  defp primary_param("key"), do: :key
  defp primary_param("host"), do: :host
  defp primary_param("harness"), do: :harness
  defp primary_param("name"), do: :name
  defp primary_param("userId"), do: :user_id
  defp primary_param(_key), do: :id

  defp occurred_at(payload) do
    payload["updatedAt"] || payload["createdAt"] || payload["openedAt"] || payload["ts"] ||
      System.system_time(:millisecond)
  end

  defp principal(nil), do: nil
  defp principal({kind, value}) when is_binary(value), do: "#{kind}:#{value}"
  defp principal(value) when is_binary(value), do: value
  defp principal(_value), do: nil

  defp hub(call), do: Map.get(call, :firehose_hub, Hub)

  defp require_primary_refs!(class, primary_refs, refs) do
    missing = Enum.reject(primary_refs, &(is_binary(refs[&1]) or is_integer(refs[&1])))

    if missing != [] do
      raise ArgumentError,
            "firehose #{class} projection is missing primary refs: #{Enum.join(missing, ", ")}"
    end

    :ok
  end
end
