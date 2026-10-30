defmodule Tightbeam.EffortCheckin do
  @moduledoc """
  Compatibility for decision requests and wake rows created by older releases.

  The historical generation table remains available for upgrades, but current
  code does not arm, inspect, expire, or otherwise act on its rows.
  """

  alias Tightbeam.{DB, Escalation, Org, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  @holder_prod_marker "effort-holder-prod:"

  @ddl """
  CREATE TABLE IF NOT EXISTS effort_checkin_generations (
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    generation INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('armed','probed','canceled')),
    baseHorizonMs INTEGER NOT NULL,
    multiplier INTEGER NOT NULL CHECK (multiplier IN (1,2,4)),
    armedAt INTEGER NOT NULL,
    terminalSeqWatermark INTEGER NOT NULL,
    holderKey TEXT NOT NULL,
    host TEXT NOT NULL,
    root TEXT NOT NULL,
    baseline TEXT NOT NULL,
    wakeId TEXT NOT NULL,
    evidence TEXT,
    agentProdded INTEGER NOT NULL DEFAULT 0,
    artifactWatermark INTEGER NOT NULL DEFAULT 0,
    attestWatermark INTEGER NOT NULL DEFAULT 0,
    workItemWatermark INTEGER NOT NULL DEFAULT 0,
    reliefStartedAt INTEGER,
    reliefExcludedMs INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (assignmentId, generation)
  );
  CREATE INDEX IF NOT EXISTS effort_checkin_wake
    ON effort_checkin_generations (wakeId, state);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    # Keep historical rows intact for upgrade compatibility.
    DB.execute(db, @ddl)
  end

  @doc false
  @spec ignore_retired_wake(DB.server(), Wakes.wake()) :: {:ok, atom()}
  def ignore_retired_wake(db, wake) do
    command = %{
      requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
      reason_kind: "consumer_unavailable",
      causal_source: %{kind: "scheduler_delivery", id: wake.wake_id},
      outcome: %{kind: "no_replacement"},
      wake_id: wake.wake_id
    }

    case DB.transaction(db, fn txn ->
           if Wakes.cancel_in_txn(txn, command) do
             :canceled
           else
             case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake.wake_id]) do
               [["pending"]] -> raise "retired effort wake could not be canceled"
               _ -> :already_settled
             end
           end
         end) do
      {:ok, outcome} -> {:ok, outcome}
      {:error, error} -> raise error
    end
  end

  @spec rule(DB.server(), map(), map()) :: map()
  def rule(db, _config, call) do
    request_id = call.params[:request_id] || call.params[:request]
    action = call.params[:action]
    request = request_row(db, request_id)
    actor = actor_id(call.principal)

    cond do
      is_nil(request) ->
        error("not_found", "decision request not found")

      request.kind != "effort" and not visible_request?(db, call, request) ->
        error("not_found", "decision request not found")

      request.kind != "effort" ->
        error("invalid", "effort-rule requires an effort request")

      action not in ["continue", "dismiss"] ->
        error("invalid_action", "action must be continue or dismiss")

      not authorized?(call.principal, request) ->
        error("not_authorized", "current expecter required")

      request.status == "ruled" and request.decision == action and request.ruled_by == actor ->
        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)
          end)

        request

      request.status != "open" ->
        error("not_open", "decision request is not open")

      true ->
        case DB.transaction_then(
               db,
               fn txn ->
                 before = Escalation.raw_by_id_in_txn(txn, request.id)

                 result = rule_in_txn(txn, request, action, actor, call.principal)

                 if is_map(result) and not Map.has_key?(result, :code) do
                   if before.status == "open" do
                     snapshot = Escalation.raw_by_id_in_txn(txn, result.id)
                     Tightbeam.Firehose.Publisher.maybe_accepted_in_txn(txn, call, snapshot)

                     _snapshot =
                       Escalation.publish_decision_transition_in_txn(
                         txn,
                         before,
                         snapshot,
                         Map.get(call, :firehose_hub, Tightbeam.Firehose.Hub)
                       )
                   else
                     Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)
                   end
                 end

                 result
               end,
               fn txn, result ->
                 Tightbeam.Wakes.row_commit_in_txn(txn, [])
                 result
               end
             ) do
          {:ok, result} -> result
          {:error, error} -> raise error
        end
    end
  end

  def holder_prod_ref(assignment_id) when is_binary(assignment_id),
    do: @holder_prod_marker <> assignment_id

  defp rule_in_txn(txn, request, action, actor, principal) do
    current = request_for_id(txn, request.id)

    cond do
      not authorized?(principal, current) ->
        error("not_authorized", "current expecter required")

      current.status == "ruled" and current.decision == action and
          current.ruled_by == actor ->
        current

      current.status == "open" ->
        ruled_at = now()

        Txn.q(
          txn,
          "UPDATE decision_requests SET status = 'ruled', decision = ?2, ruledBy = ?3, ruledAt = ?4 WHERE id = ?1 AND status = 'open'",
          [current.id, action, actor, ruled_at]
        )

        if Txn.changes(txn) == 1 do
          ruled = Escalation.raw_by_id_in_txn(txn, current.id)
          Wakes.clear_decision_request_notice_in_txn(txn, current.id)

          DB.record_row_commit(
            txn,
            decision_transition(current, "open", "ruled", actor, "effort-rule")
          )

          cancel_pending_wake_in_txn!(
            txn,
            current.deadline_wake_id,
            decision_disposition_command(
              txn,
              ruled,
              decision_inactivity_deadline_trigger_in_txn(txn, ruled.assignment_id)
            )
          )

          request_for_id(txn, current.id)
        else
          winner = request_for_id(txn, current.id)

          if winner.status == "ruled" and winner.decision == action and
               winner.ruled_by == actor,
             do: winner,
             else: error("not_open", "decision request is not open")
        end

      true ->
        error("not_open", "decision request is not open")
    end
  end

  defp cancel_pending_wake_in_txn!(txn, wake_id, command) do
    case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId = ?1", [wake_id]) do
      [["pending"]] ->
        if not Wakes.cancel_in_txn(txn, Map.put(command, :wake_id, wake_id)) do
          raise "typed effort cancellation refused for #{wake_id}"
        end

      [[state]] when state in ["fired", "canceled"] ->
        :ok

      [] ->
        raise "effort state references missing wake #{wake_id}"
    end
  end

  defp decision_disposition_command(_txn, request, liveness_trigger) do
    outcome = %{
      kind: "disposition",
      disposition_kind: "decision_request_transition",
      disposition_id: request.id,
      terminal_request: request
    }

    %{
      requester: %{kind: "process", id: "tightbeam:effort-checkin"},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "decision_request", id: request.id},
      outcome: put_liveness_trigger(outcome, liveness_trigger)
    }
  end

  defp put_liveness_trigger(outcome, trigger) when is_map(trigger),
    do: Map.put(outcome, :liveness_trigger, trigger)

  defp put_liveness_trigger(outcome, nil), do: outcome

  defp decision_inactivity_deadline_trigger_in_txn(txn, assignment_id) do
    primary = decision_liveness_primary_in_txn(txn, assignment_id)

    case primary && Supervision.inactivity_deadline_trigger_in_txn(txn, primary) do
      nil -> nil
      {:ok, trigger} when is_map(trigger) -> trigger
      :none -> nil
    end
  end

  defp decision_liveness_primary_in_txn(txn, assignment_id) do
    case Txn.q(
           txn,
           "SELECT state,workItemId FROM assignments WHERE id=?1",
           [assignment_id]
         ) do
      [["open", _work_item_id]] ->
        {:assignment, assignment_id}

      [[_state, work_item_id]] when is_binary(work_item_id) ->
        case Txn.q(txn, "SELECT state FROM work_items WHERE id=?1", [work_item_id]) do
          [["open"]] -> {:work_item, work_item_id}
          [[_terminal]] -> nil
          [] -> raise "assignment #{assignment_id} references missing work item #{work_item_id}"
        end

      [[_state, nil]] ->
        nil

      [] ->
        raise "decision request references missing assignment #{assignment_id}"
    end
  end

  defp authorized?({:session, _key}, _request), do: true
  defp authorized?({:user, _user}, _request), do: true
  defp authorized?({:process, _}, _request), do: true
  defp authorized?(_, _request), do: false

  defp actor_id({:session, key}), do: "session:" <> key
  defp actor_id({:user, user}), do: "user:" <> user
  defp actor_id({:process, name}), do: "process:" <> name
  defp actor_id(_principal), do: nil

  defp visible_request?(db, call, request) do
    owner_user_id =
      case call.principal do
        {:session, key} ->
          case Org.get(db, key) do
            %{owner_user_id: owner} -> owner
            _ -> nil
          end

        {:user, user_id} ->
          user_id

        _ ->
          nil
      end

    not is_nil(Escalation.get(db, call, request.id, owner_user_id: owner_user_id))
  end

  defp request_for_id(txn, id) do
    [row] = Txn.q(txn, request_select() <> " WHERE id = ?1", [id])
    request(row)
  end

  defp request_row(_db, nil), do: nil

  defp request_row(db, id) do
    {:ok, rows} = DB.query(db, request_select() <> " WHERE id = ?1", [id])

    case rows do
      [row] -> request(row)
      [] -> nil
    end
  end

  defp request_select do
    "SELECT id, kind, ownerUserId, assignmentId, expecterSessionKey, expecterUserId, lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt, question, options, context, status, decision, ruledBy, ruledAt FROM decision_requests"
  end

  defp request([
         id,
         kind,
         owner,
         assignment_id,
         expecter_session,
         expecter_user,
         rung,
         effort_generation,
         deadline_wake_id,
         raised_at,
         deadline_at,
         question,
         options,
         context,
         status,
         decision,
         ruled_by,
         ruled_at
       ]) do
    %{
      id: id,
      kind: kind,
      owner_user_id: owner,
      assignment_id: assignment_id,
      expecter_session_key: expecter_session,
      expecter_user_id: expecter_user,
      lineage_rung: rung,
      effort_generation: effort_generation,
      deadline_wake_id: deadline_wake_id,
      raised_at: raised_at,
      deadline_at: deadline_at,
      question: question,
      options: options && JSON.decode!(options),
      context: JSON.decode!(context),
      status: status,
      decision: decision,
      ruled_by: ruled_by,
      ruled_at: ruled_at
    }
  end

  defp decision_transition(request, old_status, new_status, principal, verb) do
    %{
      verb: verb,
      domain: "decision_request",
      row_id: request.id,
      owner_user_id: request.owner_user_id,
      principal: principal,
      bindings: %{decisionRequestId: request.id},
      field: %{name: "status", old: old_status, new: new_status}
    }
  end

  defp error(code, message), do: %{code: code, message: message}
  defp now, do: System.system_time(:millisecond)
end
