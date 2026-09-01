defmodule Tightbeam.Breathing do
  @moduledoc """
  Query-time physical liveness. This module deliberately consumes only the
  durable session, assignment, work-item, turn, and wake rows; it stores and
  publishes no liveness result.
  """

  alias Tightbeam.{DB, StateResources}
  alias Tightbeam.DB.Txn

  @spec query(DB.server(), map()) :: map()
  def query(db \\ DB, call) do
    with :ok <- principal_allowed(call[:principal]),
         {:ok, kind, id} <- target(call[:params] || %{}),
         {:ok, result} <- DB.transaction(db, fn txn -> evaluate(txn, kind, id) end) do
      result
    else
      {:error, exception} -> %{code: "server_error", message: Exception.message(exception)}
      %{code: _code} = error -> error
    end
  end

  defp target(%{target_kind: kind, target_id: id})
       when kind in ~w(session assignment work-item) and is_binary(id) and id != "",
       do: {:ok, kind, id}

  defp target(_),
    do: %{
      code: "invalid_breathing_target",
      message: "usage: breathing session|assignment|work-item <id>"
    }

  defp principal_allowed({kind, _}) when kind in [:session, :user], do: :ok

  defp principal_allowed({:process, _}),
    do: %{code: "process_denied", message: "process principals cannot query breathing"}

  defp principal_allowed(_),
    do: %{
      code: "principal_required",
      message: "breathing requires a user credential or a session token"
    }

  defp evaluate(txn, "session", id), do: session_result(txn, id)
  defp evaluate(txn, "assignment", id), do: assignment_result(txn, id)
  defp evaluate(txn, "work-item", id), do: work_item_result(txn, id)

  defp session_result(txn, id) do
    case session(txn, id) do
      nil ->
        result("session", id, false, "session_missing", %{})

      %{state: "retired"} = row ->
        result("session", id, false, "session_retired", %{session: evidence(:session, row)})

      row ->
        base = %{session: evidence(:session, row)}

        current_or_terminal(
          txn,
          "sessionKey = ?1",
          [id],
          "sessionKey = ?1",
          [id],
          base,
          "session",
          id
        )
    end
  end

  defp assignment_result(txn, id) do
    case assignment(txn, id) do
      nil ->
        result("assignment", id, false, "assignment_missing", %{})

      %{state: "closed"} = row ->
        result("assignment", id, false, "assignment_closed", %{
          assignment: evidence(:assignment, row)
        })

      row ->
        holder = session(txn, row.holder_key)
        base = %{assignment: evidence(:assignment, row)} |> put_holder(holder)

        if match?(%{state: "retired"}, holder) do
          result("assignment", id, false, "holder_retired", base)
        else
          current_or_terminal(
            txn,
            "assignmentId = ?1",
            [id],
            "assignmentId = ?1",
            [id],
            base,
            "assignment",
            id
          )
        end
    end
  end

  defp work_item_result(txn, id) do
    case work_item(txn, id) do
      nil ->
        result("work-item", id, false, "work_item_missing", %{})

      %{state: state} = row when state != "open" ->
        result("work-item", id, false, "work_item_terminal", %{
          work_item: evidence(:work_item, row)
        })

      row ->
        base = %{work_item: evidence(:work_item, row)}

        case current_path(txn, "jobRef = ?1", [id], "work_item_id = ?1", [id]) do
          {:current, reason, row} ->
            result(
              "work-item",
              id,
              true,
              reason,
              Map.put(base, current_key(reason), evidence(current_type(reason), row))
            )

          :none ->
            linked_assignments_result(txn, id, base)
        end
    end
  end

  defp linked_assignments_result(txn, work_item_id, base) do
    assignments =
      Txn.q(
        txn,
        "SELECT id, openedAt, state, outcome, holderKey, workItemId FROM assignments WHERE workItemId = ?1 AND state = 'open'",
        [work_item_id]
      )
      |> Enum.map(&assignment_row/1)
      |> Enum.map(fn row -> {row, assignment_result(txn, row.id)} end)
      |> Enum.sort_by(fn {row, answer} -> assignment_order(row, answer) end)

    case assignments do
      [] ->
        result("work-item", work_item_id, false, "no_open_assignment", base)

      [{row, %{breathing: true} = winner} | _] ->
        result(
          "work-item",
          work_item_id,
          true,
          "open_assignment_lively",
          Map.put(base, :assignment, assignment_entry(row, winner))
        )

      _ ->
        entries = Enum.map(assignments, fn {row, answer} -> assignment_entry(row, answer) end)

        result(
          "work-item",
          work_item_id,
          false,
          "all_open_assignments_not_lively",
          Map.put(base, :open_assignments, entries)
        )
    end
  end

  # Non-breathing assignments are ordered only by their durable link keys. For
  # breathing candidates the physical current-path precedence chooses the winner.
  defp assignment_order(row, %{breathing: true, reason: reason}),
    do: {0, reason_rank(reason), row.opened_at, row.id}

  defp assignment_order(row, _answer), do: {1, 0, row.opened_at, row.id}

  defp assignment_entry(row, answer) do
    %{
      id: row.id,
      openedAt: row.opened_at,
      breathing: answer.breathing,
      reason: answer.reason,
      evidence: answer.evidence
    }
  end

  defp reason_rank("running_turn"), do: 0
  defp reason_rank("queued_turn"), do: 1
  defp reason_rank("pending_wake"), do: 2

  defp current_or_terminal(
         txn,
         turn_where,
         turn_params,
         wake_where,
         wake_params,
         base,
         kind,
         id
       ) do
    case current_path(txn, turn_where, turn_params, wake_where, wake_params) do
      {:current, reason, row} ->
        result(
          kind,
          id,
          true,
          reason,
          Map.put(base, current_key(reason), evidence(current_type(reason), row))
        )

      :none ->
        case terminal_turn(txn, turn_where, turn_params) do
          %{status: status} = row when status in ["failed", "failed_unknown"] ->
            result(
              kind,
              id,
              false,
              "latest_terminal_failed",
              Map.put(base, :turn, evidence(:turn, row))
            )

          %{status: "canceled"} = row ->
            result(
              kind,
              id,
              false,
              "latest_terminal_canceled",
              Map.put(base, :turn, evidence(:turn, row))
            )

          _ ->
            result(kind, id, false, "no_current_path", base)
        end
    end
  end

  defp current_path(txn, turn_where, turn_params, wake_where, wake_params) do
    case newest_turn(txn, "running", turn_where, turn_params) do
      nil ->
        case newest_turn(txn, "queued", turn_where, turn_params) do
          nil ->
            case pending_wake(txn, wake_where, wake_params) do
              nil -> :none
              row -> {:current, "pending_wake", row}
            end

          row ->
            {:current, "queued_turn", row}
        end

      row ->
        {:current, "running_turn", row}
    end
  end

  defp newest_turn(txn, status, where, params) do
    Txn.q(
      txn,
      "SELECT seq, sessionKey, assignmentId, jobRef, status, adapterGen, error, createdAt, startedAt, endedAt FROM turns WHERE status = ?1 AND #{String.replace(where, "?1", "?2")} ORDER BY seq DESC LIMIT 1",
      [status | params]
    )
    |> one(&turn_row/1)
  end

  defp terminal_turn(txn, where, params) do
    Txn.q(
      txn,
      "SELECT seq, sessionKey, assignmentId, jobRef, status, adapterGen, error, createdAt, startedAt, endedAt FROM turns WHERE status IN ('delivered','canceled','failed','failed_unknown') AND #{where} ORDER BY seq DESC LIMIT 1",
      params
    )
    |> one(&turn_row/1)
  end

  defp pending_wake(txn, where, params) do
    Txn.q(
      txn,
      "SELECT wakeId, sessionKey, assignmentId, work_item_id, state, dueAt, createdAt FROM wakes WHERE state = 'pending' AND #{where} ORDER BY dueAt ASC, wakeId ASC LIMIT 1",
      params
    )
    |> one(&wake_row/1)
  end

  defp session(txn, id),
    do:
      Txn.q(txn, "SELECT sessionKey, state FROM sessions WHERE sessionKey = ?1", [id])
      |> one(&session_row/1)

  defp assignment(txn, id),
    do:
      Txn.q(
        txn,
        "SELECT id, openedAt, state, outcome, holderKey, workItemId FROM assignments WHERE id = ?1",
        [id]
      )
      |> one(&assignment_row/1)

  defp work_item(txn, id),
    do:
      Txn.q(txn, "SELECT id, state, failReason FROM work_items WHERE id = ?1", [id])
      |> one(&work_item_row/1)

  defp one([row], fun), do: fun.(row)
  defp one([], _fun), do: nil

  defp session_row([session_key, state]), do: %{session_key: session_key, state: state}

  defp assignment_row([id, opened_at, state, outcome, holder_key, work_item_id]),
    do: %{
      id: id,
      opened_at: opened_at,
      state: state,
      outcome: outcome,
      holder_key: holder_key,
      work_item_id: work_item_id
    }

  defp work_item_row([id, state, fail_reason]),
    do: %{id: id, state: state, fail_reason: fail_reason}

  defp turn_row([
         seq,
         session_key,
         assignment_id,
         job_ref,
         status,
         adapter_gen,
         error,
         created_at,
         started_at,
         ended_at
       ]),
       do: %{
         seq: seq,
         session_key: session_key,
         assignment_id: assignment_id,
         job_ref: job_ref,
         status: status,
         adapter_gen: adapter_gen,
         error: error,
         created_at: created_at,
         started_at: started_at,
         ended_at: ended_at
       }

  defp wake_row([wake_id, session_key, assignment_id, work_item_id, state, due_at, created_at]),
    do: %{
      wake_id: wake_id,
      session_key: session_key,
      assignment_id: assignment_id,
      work_item_id: work_item_id,
      state: state,
      due_at: due_at,
      created_at: created_at
    }

  defp put_holder(base, nil), do: base
  defp put_holder(base, holder), do: Map.put(base, :holder_session, evidence(:session, holder))
  defp current_key("pending_wake"), do: :wake
  defp current_key(_), do: :turn
  defp current_type("pending_wake"), do: :wake
  defp current_type(_), do: :turn

  defp result(kind, id, breathing, reason, evidence),
    do: %{
      schema: "breathing-v1",
      target: %{kind: kind, id: id},
      breathing: breathing,
      reason: reason,
      evidence: evidence
    }

  # StateResources is main's canonical public-read boundary. The compact maps
  # above name only the physical fields admitted by the BREATHING contract.
  defp evidence(_kind, row), do: StateResources.breathing_evidence(row)
end
