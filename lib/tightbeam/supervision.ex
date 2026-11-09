defmodule Tightbeam.Supervision do
  @moduledoc """
  Shared assignment liveness and notice helpers.

  Older releases persisted assignment inactivity deadlines, climbs, and their
  episode prompts. Startup retires only those still-pending legacy wakes before
  the scheduler starts; the current runtime does not create or consume them.
  """

  alias Tightbeam.{DB, Org, Wakes}
  alias Tightbeam.DB.Txn

  require Logger

  @deadline_consumer "assignment_inactivity_deadline"
  @climb_consumer "assignment_inactivity_climb"
  @deadline_ref "assignment-inactivity-deadline-v1:"
  @episode_ref "assignment-inactivity-episode-v1:"

  @watermarks_ddl """
  CREATE TABLE IF NOT EXISTS supervision_watermarks (
    sessionKey TEXT NOT NULL,
    assignmentId TEXT NOT NULL DEFAULT '',
    lastEvaluatedTerminal INTEGER NOT NULL,
    pendingBranch TEXT CHECK (pendingBranch IN ('prod','escalation','terminus')),
    pendingAssignment TEXT,
    pendingK INTEGER NULL,
    pendingN INTEGER NULL,
    PRIMARY KEY (sessionKey, assignmentId)
  )
  """

  @doc false
  def ensure_schema(_db), do: :ok

  @doc false
  def watermarks_ddl, do: @watermarks_ddl

  @doc false
  def assignment_closed_in_txn(%Txn{} = txn, assignment_id)
      when is_binary(assignment_id) do
    Wakes.assignment_closed_in_txn(txn, assignment_id)
  end

  def assignment_closed_in_txn(_txn, _assignment_id), do: :ok

  @doc false
  def liveness_trigger_in_txn(%Txn{} = txn, {:assignment, assignment_id})
      when is_binary(assignment_id) do
    case Txn.q(txn, "SELECT state FROM assignments WHERE id=?1", [assignment_id]) do
      [["open"]] -> {:ok, %{kind: "supervision_entitlement", id: assignment_id}}
      _ -> :none
    end
  end

  def liveness_trigger_in_txn(%Txn{} = txn, {:work_item, work_item_id})
      when is_binary(work_item_id) do
    case Txn.q(txn, "SELECT state FROM work_items WHERE id=?1", [work_item_id]) do
      [["open"]] ->
        case Txn.q(
               txn,
               """
               SELECT 1 FROM work_items wi
               JOIN wakes w ON w.wakeId=wi.routingWakeId OR w.wakeId=wi.slateWakeId
               WHERE wi.id=?1 AND wi.state='open' AND w.state='pending' LIMIT 1
               """,
               [work_item_id]
             ) do
          [[1]] ->
            {:ok, %{kind: "routing_bracket", id: work_item_id}}

          _ ->
            case Txn.q(
                   txn,
                   "SELECT id FROM assignments WHERE workItemId=?1 AND state='open' ORDER BY openedAt,id LIMIT 1",
                   [work_item_id]
                 ) do
              [[assignment_id]] when is_binary(assignment_id) ->
                {:ok, %{kind: "supervision_entitlement", id: assignment_id}}

              _ ->
                :none
            end
        end

      _ ->
        :none
    end
  end

  def liveness_trigger_in_txn(_txn, _primary), do: :none

  @doc false
  def assignment_inactivity_action?(%{
        consumer: @deadline_consumer,
        assignment_id: assignment_id,
        obligation_ref: obligation_ref
      })
      when is_binary(assignment_id) and is_binary(obligation_ref),
      do: obligation_ref == @deadline_ref <> assignment_id

  def assignment_inactivity_action?(%{
        consumer: @climb_consumer,
        obligation_ref: obligation_ref
      })
      when is_binary(obligation_ref),
      do: String.starts_with?(obligation_ref, @episode_ref)

  def assignment_inactivity_action?(%{consumer: "prompt", obligation_ref: obligation_ref})
      when is_binary(obligation_ref),
      do: String.starts_with?(obligation_ref, @episode_ref)

  def assignment_inactivity_action?(_wake), do: false

  @doc "Cancel undelivered inactivity wakes left by earlier releases."
  @spec drain_legacy_inactivity_wakes(DB.server()) :: :ok | {:error, term()}
  def drain_legacy_inactivity_wakes(db) do
    case DB.transaction(db, fn txn ->
           Txn.q(
             txn,
             """
             SELECT wakeId FROM wakes
             WHERE state='pending' AND deliveredTurnSeq IS NULL
               AND (consumer IN (?1,?2) OR
                    (consumer='prompt' AND substr(obligationRef,1,length(?3))=?3))
             ORDER BY createdAt,wakeId
             """,
             [@deadline_consumer, @climb_consumer, @episode_ref]
           )
           |> Enum.each(fn
             [wake_id] when is_binary(wake_id) ->
               command = %{
                 wake_id: wake_id,
                 requester: %{kind: "process", id: "tightbeam:rail-remedy"},
                 reason_kind: "superseded",
                 causal_source: %{kind: "wake", id: wake_id},
                 outcome: %{kind: "no_replacement"}
               }

               unless Wakes.cancel_in_txn(txn, command) do
                 raise DB.Error,
                   message: "legacy assignment inactivity wake could not be canceled: #{wake_id}"
               end

               settle_legacy_controller_in_txn(txn, wake_id)

             _ ->
               raise DB.Error, message: "malformed legacy assignment inactivity wake reference"
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp settle_legacy_controller_in_txn(txn, wake_id) do
    case Txn.q(
           txn,
           "SELECT 1 FROM supervision_liveness_sidecar WHERE wakeId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'",
           [wake_id]
         ) do
      [[1]] ->
        Txn.q(
          txn,
          "UPDATE supervision_liveness_sidecar SET controllerState='settled' WHERE wakeId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'",
          [wake_id]
        )

        if Txn.changes(txn) != 1,
          do:
            raise(DB.Error,
              message: "legacy assignment inactivity controller changed: #{wake_id}"
            )

      _ ->
        :ok
    end
  end

  @doc """
  Close open assignments whose holder is already retired.

  Retirement normally closes them in its own transaction; this recovers rows a
  predecessor left open. Runs at boot after row recognition is installed so the
  closures reach rules like any other retirement.
  """
  @spec close_retired_holder_assignments(DB.server()) :: :ok
  def close_retired_holder_assignments(db) do
    case DB.transaction_then(
           db,
           fn txn ->
             txn
             |> Txn.q("""
             SELECT DISTINCT s.sessionKey, s.ownerUserId
             FROM sessions s
             JOIN assignments a ON a.holderKey=s.sessionKey
             WHERE s.state='retired' AND a.state='open'
             ORDER BY s.sessionKey
             """)
             |> Enum.flat_map(fn [session_key, owner_user_id] ->
               Tightbeam.Assignments.interrupt_for_retire_in_txn(
                 txn,
                 session_key,
                 owner_user_id,
                 "process:tightbeam"
               )
               |> Enum.map(& &1.work_item_id)
             end)
             |> Enum.filter(&is_binary/1)
             |> Enum.uniq()
             |> Enum.each(&Tightbeam.WorkItemSummary.publish_change_in_txn(txn, &1, %{}))
           end,
           fn txn, result ->
             Wakes.row_commit_in_txn(txn, [])
             result
           end
         ) do
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end
  end

  @doc false
  def ladder_target(db_or_txn, holder_key, rung)
      when is_binary(holder_key) and is_integer(rung) and rung > 0 do
    case query(
           db_or_txn,
           "SELECT ownerUserId, #{Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey=?1",
           [holder_key]
         ) do
      [[owner, spawned_by]] ->
        chain = lineage(db_or_txn, spawned_by, MapSet.new([holder_key]), [])

        case Enum.at(chain, rung - 1) do
          nil -> active_personal_key(db_or_txn, owner)
          target -> target
        end

      [] ->
        Logger.warning("assignment notice holder session missing for #{inspect(holder_key)}")
        nil

      other ->
        Logger.warning(
          "assignment notice holder session unreadable for #{inspect(holder_key)}: #{inspect(other)}"
        )

        nil
    end
  rescue
    error ->
      Logger.warning("assignment notice lineage unavailable: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.warning("assignment notice lineage unavailable: #{inspect({kind, reason})}")
      nil
  end

  def ladder_target(_db_or_txn, _holder_key, _rung), do: nil

  @doc false
  def holder_activity_in_txn(txn, holder) do
    Txn.q(txn, "SELECT id,openedAt FROM assignments WHERE holderKey=?1 AND state='open'", [holder])
    |> Enum.map(fn [id, opened] ->
      current_activity_time_in_txn(txn, id, holder, activity_start_in_txn(txn, id, opened))
    end)
    |> Enum.max(fn -> nil end)
  end

  defp current_activity_time_in_txn(txn, assignment_id, holder, opened_at) do
    candidates = [
      max_row(
        txn,
        "SELECT MAX(ts) FROM attests WHERE assignmentId=?1 AND bySession=?2 AND ts>=?3",
        [assignment_id, holder, opened_at]
      ),
      max_row(
        txn,
        "SELECT MAX(createdAt) FROM artifacts WHERE producedByAssignmentId=?1 AND createdBySession=?2 AND createdAt>=?3",
        [assignment_id, holder, opened_at]
      ),
      max_row(
        txn,
        "SELECT MAX(w.createdAt) FROM wakes w " <>
          "WHERE w.assignmentId=?1 AND w.creatorSessionKey=?2 AND w.createdAt>=?3 " <>
          "AND NOT EXISTS (SELECT 1 FROM wake_activity_exclusions e WHERE e.wakeId=w.wakeId)",
        [assignment_id, holder, opened_at]
      ),
      max_row(
        txn,
        "SELECT MAX(raisedAt) FROM decision_requests WHERE assignmentId=?1 AND raiserSessionKey=?2 AND raisedAt>=?3",
        [assignment_id, holder, opened_at]
      )
    ]

    [opened_at | Enum.filter(candidates, &is_integer/1)] |> Enum.max()
  end

  defp activity_start_in_txn(txn, assignment_id, opened_at) do
    case Txn.q(txn, "SELECT MAX(ts) FROM assignment_reopenings WHERE assignmentId=?1", [
           assignment_id
         ]) do
      [[at]] when is_integer(at) ->
        max(opened_at, at)

      [[nil]] ->
        opened_at

      other ->
        Logger.warning(
          "assignment reopen time unreadable for #{assignment_id}: #{inspect(other)}"
        )

        opened_at
    end
  end

  defp max_row(txn, sql, params) do
    case Txn.q(txn, sql, params) do
      [[at]] when is_integer(at) ->
        at

      [[nil]] ->
        nil

      other ->
        Logger.warning("assignment activity time unavailable: #{inspect(other)}")
        nil
    end
  end

  defp lineage(_db, nil, _visited, acc), do: Enum.reverse(acc)

  defp lineage(db_or_txn, session_key, visited, acc) do
    if MapSet.member?(visited, session_key) do
      Logger.warning("assignment notice lineage contains a cycle at #{inspect(session_key)}")
      Enum.reverse(acc)
    else
      case query(
             db_or_txn,
             "SELECT state, #{Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey=?1",
             [session_key]
           ) do
        [[state, parent]] ->
          next = if state == "active", do: [session_key | acc], else: acc
          lineage(db_or_txn, parent, MapSet.put(visited, session_key), next)

        [] ->
          Logger.warning("assignment notice lineage session missing for #{inspect(session_key)}")
          Enum.reverse(acc)

        other ->
          Logger.warning(
            "assignment notice lineage unreadable for #{inspect(session_key)}: #{inspect(other)}"
          )

          Enum.reverse(acc)
      end
    end
  end

  defp active_personal_key(_db_or_txn, nil), do: nil

  defp active_personal_key(db_or_txn, owner) do
    key = Org.personal_session_key(owner)

    case query(db_or_txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [key]) do
      [[1]] ->
        key

      [] ->
        Logger.warning("assignment notice personal target unavailable for #{inspect(owner)}")
        nil

      other ->
        Logger.warning(
          "assignment notice personal target unreadable for #{inspect(owner)}: #{inspect(other)}"
        )

        nil
    end
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    case DB.query(db, sql, params) do
      {:ok, rows} -> rows
      {:error, error} -> raise error
    end
  end
end
