defmodule Tightbeam.WorkItemWaits do
  @moduledoc "Work-item ownership of existing dependency wakes; no separate scheduler."
  alias Tightbeam.{DB, Wakes, RowReactions, Org, Gateway}
  alias Tightbeam.DB.Txn

  def enabled?, do: Application.get_env(:tightbeam, :work_item_waits_enabled, false) == true

  def disabled_error do
    %{
      code: "feature_disabled",
      message: "Work-item waits are disabled; enable work_item_waits_enabled to use this command."
    }
  end

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS work_item_waits (
      workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
      wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
      releasedAt INTEGER NULL
    )
    """)
  end

  def get(db, id) do
    case DB.read_transaction(db, &get_in_txn(&1, id)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  def get_in_txn(txn, id) do
    if enabled?(), do: get_in_txn_enabled(txn, id), else: nil
  end

  defp get_in_txn_enabled(txn, id) do
    case Txn.q(txn, "SELECT wakeId,releasedAt FROM work_item_waits WHERE workItemId=?1", [id]) do
      [[wake_id, released_at]] ->
        wake = Wakes.get_in_txn(txn, wake_id)

        %{
          wakeId: wake_id,
          reason: wake.wait_reason,
          predicate: wake.predicate,
          dueAt: if(wake.due_at == Wakes.no_deadline(), do: nil, else: wake.due_at),
          active: is_nil(released_at),
          releasedAt: released_at,
          recognitionPath: wake.recognition_path,
          recognitionReason: wake.recognition_reason,
          recognitionDisposition: wake.recognition_disposition,
          recognitionEvidence: wake.recognition_evidence,
          state: wake.state
        }

      [] ->
        nil
    end
  end

  def active_in_txn?(txn, id) do
    if enabled?(), do: active_in_txn_enabled?(txn, id), else: false
  end

  defp active_in_txn_enabled?(txn, id) do
    Txn.q(txn, "SELECT 1 FROM work_item_waits WHERE workItemId=?1 AND releasedAt IS NULL", [id]) !=
      []
  end

  def linked_in_txn?(txn, wake_id) do
    if enabled?(), do: linked_in_txn_enabled?(txn, wake_id), else: false
  end

  defp linked_in_txn_enabled?(txn, wake_id) do
    Txn.q(txn, "SELECT 1 FROM work_item_waits WHERE wakeId=?1", [wake_id]) != []
  end

  def apply_in_txn(txn, item, call, operation) do
    if enabled?(), do: apply_enabled_in_txn(txn, item, call, operation), else: disabled_error()
  end

  defp apply_enabled_in_txn(txn, item, call, :record) do
    with :ok <- bare_open(txn, item),
         :ok <- Tightbeam.WaitReason.validate(call.params[:wait_reason], "--wait-reason"),
         {:ok, declaration} <- declaration(txn, call.params),
         {:ok, deadline} <- deadline(call.params, declaration) do
      current = get_in_txn(txn, item.id)
      # A retry does not move the safety deadline. A changed reason or target replaces it.
      if current && current.active && current.reason == call.params.wait_reason &&
           same_declaration?(current.predicate, declaration) do
        %{wait: current}
      else
        creator =
          case call.principal do
            {:session, key} -> key
            _ -> nil
          end

        result =
          Wakes.register_work_item_wait_in_txn(
            txn,
            %{
              session_key: recipient(txn, item.id),
              origin: call.origin,
              creator_session_key: creator,
              owner_user_id: item.ownerUserId,
              work_item_id: item.id,
              wait_reason: call.params.wait_reason,
              prompt:
                "The recorded wait for work item #{item.id} ended. Read the wait outcome and decide the next action: tightbeam work-item-get #{item.id}.",
              due_at: deadline
            },
            declaration
          )

        case result do
          {:error, error} ->
            error

          wake ->
            response = %{wait: get_in_txn(txn, item.id)}

            warning =
              Gateway.warn_unserved_condition_in_txn(txn, wake, call.params[:condition_kind])

            if warning[:warnings],
              do: Map.put(response, :warnings, warning.warnings),
              else: response
        end
      end
    else
      {:error, error} -> error
    end
  end

  defp apply_enabled_in_txn(txn, item, call, :withdraw) do
    case get_in_txn(txn, item.id) do
      nil ->
        %{wait: nil}

      current ->
        release_in_txn(txn, current.wakeId)
        withdraw_in_txn(txn, current.wakeId, call)
        %{wait: get_in_txn(txn, item.id)}
    end
  end

  defp bare_open(txn, item) do
    cond do
      item.state != "open" ->
        error("item_not_open", "only an open work item can record a wait")

      Txn.q(txn, "SELECT 1 FROM assignments WHERE workItemId=?1 AND state='open' LIMIT 1", [
        item.id
      ]) != [] ->
        error("assignments_open", "record the wait on the open assignment instead")

      true ->
        :ok
    end
  end

  defp deadline(params, %{resolver_ref: %{kind: "condition_fact"}}) do
    case params[:after_ms] do
      ms when is_integer(ms) and ms > 0 -> {:ok, now() + ms}
      _ -> error("invalid_fallback", "event waits require a positive --fallback-after duration")
    end
  end

  defp deadline(params, _) do
    if is_nil(params[:after_ms]),
      do: {:ok, Wakes.no_deadline()},
      else: error("invalid_fallback", "--fallback-after is only supported for event waits")
  end

  defp declaration(_txn, params) do
    case {params[:assignment_id], params[:decision_request_id], params[:condition_kind],
          params[:condition_scope]} do
      {id, nil, nil, nil} when is_binary(id) and id != "" ->
        {:ok,
         %{
           conditions: [%{fact: "assignment.outcome", op: "eq", value: "completed"}],
           bindings: %{assignmentId: id},
           resolver_ref: %{kind: "assignment", id: id}
         }}

      {nil, id, nil, nil} when is_binary(id) and id != "" ->
        {:ok,
         %{
           conditions: [
             %{fact: "decision_request.status", op: "in", value: ~w(ruled consumed answered)}
           ],
           bindings: %{decisionRequestId: id},
           resolver_ref: %{kind: "decision_request", id: id}
         }}

      {nil, nil, kind, scope}
      when is_binary(kind) and kind != "" and is_binary(scope) and scope != "" ->
        if String.trim(kind) == "" or String.trim(scope) == "" do
          error("invalid_wait_target", "event kind and scope must be nonblank")
        else
          {:ok,
           %{
             conditions: [%{fact: "condition_fact.matches", op: "eq", value: true}],
             bindings: %{conditionKind: kind, conditionScope: scope, conditionAfterId: 0},
             resolver_ref: %{kind: "condition_fact", id: JSON.encode!([kind, scope])}
           }}
        end

      _ ->
        error(
          "invalid_wait_target",
          "name exactly one --assignment, --decision, or --when-fact with --when-scope"
        )
    end
  end

  defp same_declaration?(predicate, declaration) do
    predicate["conditions"] == JSON.decode!(JSON.encode!(declaration.conditions)) and
      predicate["bindings"] == JSON.decode!(JSON.encode!(declaration.bindings))
  end

  # Called only after the resolver and predicate have validated. Keep replacement,
  # reminder withdrawal and snapshot recognition in the registration transaction.
  def link_in_txn(txn, id, wake) do
    if enabled?(), do: link_in_txn_enabled(txn, id, wake), else: disabled_error()
  end

  defp link_in_txn_enabled(txn, id, wake) do
    case get_in_txn(txn, id) do
      nil ->
        :ok

      old ->
        Txn.q(
          txn,
          "UPDATE work_item_waits SET releasedAt=COALESCE(releasedAt,?2) WHERE workItemId=?1",
          [id, now()]
        )

        cancel_in_txn(txn, old.wakeId, %{
          requester: %{kind: "process", id: "tightbeam:work-items"},
          reason_kind: "routing_bracket_satisfied",
          causal_source: %{kind: "routing_bracket", id: id},
          outcome: %{kind: "replacement", replacement_wake_id: wake.wake_id}
        })
    end

    Txn.q(
      txn,
      "INSERT INTO work_item_waits(workItemId,wakeId,releasedAt) VALUES (?1,?2,NULL) ON CONFLICT(workItemId) DO UPDATE SET wakeId=excluded.wakeId,releasedAt=NULL",
      [id, wake.wake_id]
    )

    [[routing, slate]] =
      Txn.q(txn, "SELECT routingWakeId,slateWakeId FROM work_items WHERE id=?1", [id])

    for old <- [routing, slate], is_binary(old) do
      case Wakes.get_in_txn(txn, old) do
        %{state: "pending", delivered_turn_seq: nil} ->
          accepted =
            Wakes.cancel_in_txn(txn, %{
              wake_id: old,
              requester: %{kind: "process", id: "tightbeam:work-items"},
              reason_kind: "routing_bracket_satisfied",
              causal_source: %{kind: "routing_bracket", id: id},
              outcome: %{kind: "replacement", replacement_wake_id: wake.wake_id}
            })

          unless accepted, do: raise(DB.Error, message: "item wait reminder withdrawal refused")

        _ ->
          :ok
      end
    end

    Txn.q(txn, "UPDATE work_items SET routingWakeId=NULL,slateWakeId=NULL WHERE id=?1", [id])
    RowReactions.reconcile_work_item_in_txn(txn, id)
    :ok
  end

  def release_in_txn(txn, wake_id) do
    if enabled?(), do: release_in_txn_enabled(txn, wake_id), else: :ok
  end

  defp release_in_txn_enabled(txn, wake_id) do
    case Txn.q(
           txn,
           "SELECT workItemId FROM work_item_waits WHERE wakeId=?1 AND releasedAt IS NULL",
           [wake_id]
         ) do
      [[id]] ->
        at = now()

        Txn.q(
          txn,
          "UPDATE work_item_waits SET releasedAt=?2 WHERE wakeId=?1 AND releasedAt IS NULL",
          [wake_id, at]
        )

        readdress_in_txn(txn, wake_id)

        RowReactions.observe_work_item_in_txn(
          txn,
          id,
          "wait_ended",
          %{
            kind: "wake",
            id: wake_id,
            at: at,
            principal: {:process, "tightbeam:work-item-waits"}
          },
          %{}
        )

      [] ->
        :ok
    end
  end

  def dispose_in_txn(txn, id, transition_id) do
    if enabled?(), do: dispose_in_txn_enabled(txn, id, transition_id), else: :ok
  end

  defp dispose_in_txn_enabled(txn, id, transition_id) do
    case get_in_txn(txn, id) do
      nil ->
        :ok

      wait ->
        Txn.q(
          txn,
          "UPDATE work_item_waits SET releasedAt=COALESCE(releasedAt,?2) WHERE workItemId=?1",
          [id, now()]
        )

        cancel_in_txn(txn, wait.wakeId, %{
          requester: %{kind: "process", id: "tightbeam:work-items"},
          reason_kind: "routing_bracket_satisfied",
          causal_source: %{kind: "work_item_transition", id: transition_id},
          outcome: %{
            kind: "disposition",
            disposition_kind: "work_item_transition",
            disposition_id: transition_id
          }
        })
    end
  end

  defp withdraw_in_txn(txn, wake_id, call) do
    {kind, id} = call.principal

    cancel_in_txn(txn, wake_id, %{
      requester: %{kind: to_string(kind), id: id},
      reason_kind: "requester_withdrew",
      expected_origin: call.origin,
      item_wait_withdrawal: true,
      causal_source: %{
        kind: "verb_call",
        accepted_event: %{
          origin: call.origin,
          session_key: call[:session_key],
          principal: call.principal
        }
      },
      outcome: %{kind: "no_replacement"}
    })
  end

  defp cancel_in_txn(txn, wake_id, command) do
    case Wakes.get_in_txn(txn, wake_id) do
      %{state: "pending", delivered_turn_seq: nil} ->
        unless Wakes.cancel_in_txn(txn, Map.put(command, :wake_id, wake_id)),
          do: raise(DB.Error, message: "item wait withdrawal refused")

      _ ->
        :ok
    end
  end

  def readdress_in_txn(txn, wake_id) do
    if enabled?(), do: readdress_in_txn_enabled(txn, wake_id), else: :ok
  end

  defp readdress_in_txn_enabled(txn, wake_id) do
    case Txn.q(txn, "SELECT workItemId FROM work_item_waits WHERE wakeId=?1", [wake_id]) do
      [[id]] ->
        target = recipient(txn, id)

        case Wakes.get_in_txn(txn, wake_id) do
          %{state: "pending", delivered_turn_seq: nil, session_key: previous}
          when previous != target ->
            case Wakes.readdress_pending_in_txn(txn, wake_id, target) do
              :ok ->
                :ok

              {:ok, _} ->
                :ok

              error ->
                raise DB.Error, message: "item wait recipient update refused: #{inspect(error)}"
            end

          _ ->
            :ok
        end

      [] ->
        :ok
    end
  end

  defp recipient(txn, id) do
    [[owner, delivery, state]] =
      Txn.q(
        txn,
        "SELECT w.ownerUserId,w.deliveryOwnerSessionKey,s.state FROM work_items w LEFT JOIN sessions s ON s.sessionKey=w.deliveryOwnerSessionKey WHERE w.id=?1",
        [id]
      )

    if state == "active", do: delivery, else: Org.personal_session_key(owner)
  end

  defp now, do: System.system_time(:millisecond)
  defp error(code, message), do: {:error, %{code: code, message: message}}
end
