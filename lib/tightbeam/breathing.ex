defmodule Tightbeam.Breathing do
  @moduledoc """
  Deterministic, read-only physical breathing queries.

  A result is computed from one database snapshot and is never stored. Only
  session, assignment, work-item, turn, and wake rows participate.
  """

  alias Tightbeam.{DB, StateResources}
  alias Tightbeam.DB.Txn

  @schema "breathing-v1"
  @terminal_statuses ~w(delivered canceled failed failed_unknown)

  @spec handle(DB.server(), map()) :: map()
  def handle(db, %{principal: {kind, _}, params: params}) when kind in [:session, :user] do
    with target_kind when target_kind in ~w(session assignment work-item) <-
           params[:target_kind],
         target_id when is_binary(target_id) and target_id != "" <- params[:target_id] do
      query(db, target_kind, target_id)
    else
      _ ->
        %{
          code: "invalid",
          message: "breathing requires session, assignment, or work-item and one target id"
        }
    end
  end

  def handle(_db, %{principal: {:process, _}}),
    do: %{code: "process_denied", message: "process principals cannot use breathing queries"}

  def handle(_db, _call),
    do: %{
      code: "principal_required",
      message: "breathing requires a user credential or session token"
    }

  @spec query(DB.server(), String.t(), String.t()) :: map()
  def query(db, target_kind, target_id)
      when target_kind in ~w(session assignment work-item) and is_binary(target_id) do
    case DB.transaction(db, fn txn -> query_in_txn(txn, target_kind, target_id) end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp query_in_txn(txn, "session", id), do: session_in_txn(txn, id)
  defp query_in_txn(txn, "assignment", id), do: assignment_in_txn(txn, id)
  defp query_in_txn(txn, "work-item", id), do: work_item_in_txn(txn, id)

  defp session_in_txn(txn, id) do
    case Txn.q(txn, "SELECT sessionKey,state FROM sessions WHERE sessionKey=?1", [id]) do
      [] ->
        result("session", id, false, "session_missing", %{})

      [[session_key, "retired"]] ->
        session = StateResources.breathing_session([session_key, "retired"])
        result("session", id, false, "session_retired", %{session: session})

      [[session_key, state]] ->
        session = StateResources.breathing_session([session_key, state])
        finish_path(txn, "session", id, %{session: session})
    end
  end

  defp assignment_in_txn(txn, id) do
    case assignment_row(txn, id) do
      nil ->
        result("assignment", id, false, "assignment_missing", %{})

      %{state: "closed"} = assignment ->
        result("assignment", id, false, "assignment_closed", %{assignment: assignment})

      assignment ->
        holder = session_row(txn, assignment.holderKey)
        evidence = %{assignment: assignment} |> put_if(:holder, holder)

        if holder && holder.state == "retired" do
          result("assignment", id, false, "holder_retired", evidence)
        else
          finish_path(txn, "assignment", id, evidence)
        end
    end
  end

  defp work_item_in_txn(txn, id) do
    case work_item_row(txn, id) do
      nil ->
        result("work-item", id, false, "work_item_missing", %{})

      %{state: state} = work_item when state != "open" ->
        result("work-item", id, false, "work_item_terminal", %{workItem: work_item})

      work_item ->
        evidence = %{workItem: work_item}

        case current_path(txn, "work-item", id) do
          {reason, kind, row} ->
            result("work-item", id, true, reason, Map.put(evidence, kind, row))

          nil ->
            linked_assignment_result(txn, id, evidence)
        end
    end
  end

  defp linked_assignment_result(txn, work_item_id, evidence) do
    assignments =
      Txn.q(
        txn,
        "SELECT id,openedAt FROM assignments WHERE workItemId=?1 AND state='open' ORDER BY openedAt,id",
        [work_item_id]
      )
      |> Enum.map(fn [id, opened_at] ->
        assignment_in_txn(txn, id)
        |> assignment_entry(id, opened_at)
      end)
      |> Enum.sort_by(&assignment_result_order/1)

    case Enum.find(assignments, & &1.breathing) do
      assignment when is_map(assignment) ->
        result(
          "work-item",
          work_item_id,
          true,
          "open_assignment_lively",
          Map.put(evidence, :assignment, assignment)
        )

      nil when assignments == [] ->
        result("work-item", work_item_id, false, "no_open_assignment", evidence)

      nil ->
        ordered = Enum.sort_by(assignments, &{&1.openedAt, &1.id})

        result(
          "work-item",
          work_item_id,
          false,
          "all_open_assignments_not_lively",
          Map.put(evidence, :openAssignments, ordered)
        )
    end
  end

  defp finish_path(txn, target_kind, id, evidence) do
    case current_path(txn, target_kind, id) do
      {reason, kind, row} ->
        result(target_kind, id, true, reason, Map.put(evidence, kind, row))

      nil ->
        finish_terminal(txn, target_kind, id, evidence)
    end
  end

  defp finish_terminal(txn, target_kind, id, evidence) do
    case latest_terminal(txn, target_kind, id) do
      %{status: status} = turn when status in ~w(failed failed_unknown) ->
        result(target_kind, id, false, "latest_terminal_failed", Map.put(evidence, :turn, turn))

      %{status: "canceled"} = turn ->
        result(
          target_kind,
          id,
          false,
          "latest_terminal_canceled",
          Map.put(evidence, :turn, turn)
        )

      turn when is_map(turn) ->
        result(target_kind, id, false, "no_current_path", Map.put(evidence, :turn, turn))

      nil ->
        result(target_kind, id, false, "no_current_path", evidence)
    end
  end

  defp current_path(txn, target_kind, id) do
    case current_turn(txn, target_kind, id, "running") do
      turn when is_map(turn) -> {"running_turn", :turn, turn}
      nil -> current_non_running_path(txn, target_kind, id)
    end
  end

  defp current_non_running_path(txn, target_kind, id) do
    case current_turn(txn, target_kind, id, "queued") do
      turn when is_map(turn) ->
        {"queued_turn", :turn, turn}

      nil ->
        case pending_wake(txn, target_kind, id) do
          wake when is_map(wake) -> {"pending_wake", :wake, wake}
          nil -> nil
        end
    end
  end

  defp current_turn(txn, target_kind, id, status) do
    {where, params} = turn_target(target_kind, id, status)

    txn
    |> Txn.q(turn_select() <> " WHERE " <> where <> " ORDER BY seq DESC LIMIT 1", params)
    |> one(&StateResources.breathing_turn/1)
  end

  defp latest_terminal(txn, target_kind, id) do
    {where, params} = terminal_target(target_kind, id)
    placeholders = Enum.map_join(@terminal_statuses, ",", fn _ -> "?" end)

    txn
    |> Txn.q(
      turn_select() <>
        " WHERE " <> where <> " AND status IN (" <> placeholders <> ") ORDER BY seq DESC LIMIT 1",
      params ++ @terminal_statuses
    )
    |> one(&StateResources.breathing_turn/1)
  end

  defp pending_wake(txn, target_kind, id) do
    {where, params} = wake_target(target_kind, id)

    txn
    |> Txn.q(
      "SELECT wakeId,sessionKey,assignmentId,work_item_id,state,dueAt,createdAt FROM wakes WHERE " <>
        where <> " AND state='pending' ORDER BY dueAt,wakeId LIMIT 1",
      params
    )
    |> one(&StateResources.breathing_wake/1)
  end

  defp turn_target("session", id, status), do: {"sessionKey=?1 AND status=?2", [id, status]}

  defp turn_target("assignment", id, status),
    do: {"assignmentId=?1 AND status=?2", [id, status]}

  defp turn_target("work-item", id, status), do: {"jobRef=?1 AND status=?2", [id, status]}

  defp terminal_target("session", id), do: {"sessionKey=?1", [id]}
  defp terminal_target("assignment", id), do: {"assignmentId=?1", [id]}
  defp terminal_target("work-item", id), do: {"jobRef=?1", [id]}

  defp wake_target("session", id), do: {"sessionKey=?1", [id]}
  defp wake_target("assignment", id), do: {"assignmentId=?1", [id]}
  defp wake_target("work-item", id), do: {"work_item_id=?1", [id]}

  defp turn_select do
    "SELECT seq,sessionKey,assignmentId,jobRef,status,adapterGen,error,createdAt,startedAt,endedAt FROM turns"
  end

  defp assignment_row(txn, id) do
    txn
    |> Txn.q(
      "SELECT id,openedAt,state,outcome,holderKey,workItemId FROM assignments WHERE id=?1",
      [id]
    )
    |> one(&StateResources.breathing_assignment/1)
  end

  defp session_row(txn, id) do
    txn
    |> Txn.q("SELECT sessionKey,state FROM sessions WHERE sessionKey=?1", [id])
    |> one(&StateResources.breathing_session/1)
  end

  defp work_item_row(txn, id) do
    txn
    |> Txn.q("SELECT id,state,failReason FROM work_items WHERE id=?1", [id])
    |> one(&StateResources.breathing_work_item/1)
  end

  defp assignment_entry(result, id, opened_at) do
    %{
      id: id,
      openedAt: opened_at,
      breathing: result.breathing,
      reason: result.reason,
      evidence: result.evidence
    }
  end

  defp assignment_result_order(%{breathing: true, reason: reason, openedAt: opened_at, id: id}),
    do: {0, breathing_reason_order(reason), opened_at, id}

  defp assignment_result_order(%{openedAt: opened_at, id: id}), do: {1, 0, opened_at, id}

  defp breathing_reason_order("running_turn"), do: 0
  defp breathing_reason_order("queued_turn"), do: 1
  defp breathing_reason_order("pending_wake"), do: 2

  defp result(target_kind, id, breathing, reason, evidence) do
    %{
      schema: @schema,
      target: %{kind: target_kind, id: id},
      breathing: breathing,
      reason: reason,
      evidence: evidence
    }
  end

  defp one([], _mapper), do: nil
  defp one([row], mapper), do: mapper.(row)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
