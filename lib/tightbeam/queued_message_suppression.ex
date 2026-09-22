defmodule Tightbeam.QueuedMessageSuppression do
  @moduledoc """
  The pre-execution boundary for stale machine liveness notices.

  Eligibility is deliberately narrow: the queued turn must point to an exact
  durable wake that the existing supervision machinery classifies as liveness,
  and that wake must name one real assignment. Human, decision, continuation,
  report, failure, unscoped, and ambiguous traffic remains claimable.

  The source turn, wake, and message remain durable. Suppression only
  terminalizes the queued turn through the ledger's normal audited seam.
  """

  alias Tightbeam.{DB, EventLog, Ledger, Wakes}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS queued_message_scopes (
    turnSeq         INTEGER PRIMARY KEY REFERENCES turns(seq),
    assignmentId    TEXT NOT NULL REFERENCES assignments(id),
    turnCreatedAt   INTEGER NOT NULL CHECK(turnCreatedAt >= 0),
    wakeId          TEXT NOT NULL CHECK(length(trim(wakeId)) > 0),
    wakeCreatedAt   INTEGER NOT NULL CHECK(wakeCreatedAt >= 0)
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Bind an eligible queued liveness notice to its exact durable wake."
  @spec record_in_txn(Txn.t(), pos_integer(), map()) :: :ok
  def record_in_txn(%Txn{} = txn, turn_seq, attrs) do
    with {:ok, scope} <- scope_in_txn(txn, turn_seq, attrs) do
      Txn.q(
        txn,
        """
        INSERT INTO queued_message_scopes
          (turnSeq,assignmentId,turnCreatedAt,wakeId,wakeCreatedAt)
        VALUES (?1,?2,?3,?4,?5)
        """,
        [
          turn_seq,
          scope.assignment_id,
          scope.turn_created_at,
          scope.wake_id,
          scope.wake_created_at
        ]
      )
    else
      :not_eligible -> :ok
    end

    :ok
  end

  @doc "Suppress stale liveness candidates ahead of the next claim."
  @spec suppress_before_claim_in_txn(Txn.t(), String.t()) :: [pos_integer()]
  def suppress_before_claim_in_txn(%Txn{} = txn, session_key) do
    rows =
      Txn.q(
        txn,
        """
        SELECT turnSeq,assignmentId,turnCreatedAt,wakeId,wakeCreatedAt
        FROM queued_message_scopes
        WHERE turnSeq IN (
          SELECT seq FROM turns WHERE sessionKey=?1 AND status='queued'
        )
        ORDER BY turnSeq
        """,
        [session_key]
      )

    Enum.reduce_while(rows, [], fn row, suppressed ->
      scope = scope_from_row(row)

      if originating_wake_still_matches?(txn, scope) do
        suppress_scope_in_txn(txn, scope, suppressed)
      else
        {:cont, suppressed}
      end
    end)
    |> Enum.reverse()
  end

  defp suppress_scope_in_txn(txn, scope, suppressed) do
    case suppression_reason(txn, scope) do
      {:suppress, reason} ->
        if Ledger.cancel_queued_in_txn(txn, scope.turn_seq, reason) do
          EventLog.lifecycle_in_txn(
            txn,
            "queued_message_suppressed",
            Integer.to_string(scope.turn_seq),
            JSON.encode!(%{
              turnSeq: scope.turn_seq,
              messageKind: "liveness",
              scopeKind: "assignment",
              scopeId: scope.assignment_id,
              cause: reason,
              sourceCreatedAt: scope.turn_created_at,
              sourceKind: "wake",
              sourceId: scope.wake_id,
              sourceObservedAt: scope.wake_created_at
            })
          )

          {:cont, [scope.turn_seq | suppressed]}
        else
          {:halt, suppressed}
        end

      :retain ->
        {:cont, suppressed}
    end
  end

  defp scope_in_txn(txn, turn_seq, attrs) do
    case Txn.q(
           txn,
           "SELECT origin,requestRef,createdAt,wakeId FROM turns WHERE seq=?1 AND status='queued'",
           [turn_seq]
         ) do
      [[origin, request_ref, turn_created_at, wake_id]] ->
        wake = wake_in_txn(txn, wake_id)
        requested_kind = Map.get(attrs, :queue_message_kind)

        cond do
          human_origin?(origin) or decision_ref?(request_ref) or decision_wake?(wake) ->
            :not_eligible

          continuation_wake?(wake) ->
            :not_eligible

          requested_kind not in [nil, "liveness"] ->
            :not_eligible

          not liveness_wake?(txn, wake, wake_id) ->
            :not_eligible

          true ->
            exact_assignment_scope_in_txn(txn, attrs, wake, turn_created_at)
        end

      [] ->
        :not_eligible
    end
  end

  defp exact_assignment_scope_in_txn(txn, attrs, wake, turn_created_at) do
    assignment_id = Map.get(attrs, :assignment_id) || wake_value(wake, :assignment_id)

    with true <- valid_text?(assignment_id),
         ^assignment_id <- wake_value(wake, :assignment_id),
         wake_id when is_binary(wake_id) <- wake_value(wake, :wake_id),
         wake_created_at when is_integer(wake_created_at) <- wake_value(wake, :created_at),
         [[1]] <- Txn.q(txn, "SELECT 1 FROM assignments WHERE id=?1", [assignment_id]) do
      {:ok,
       %{
         assignment_id: assignment_id,
         turn_created_at: turn_created_at,
         wake_id: wake_id,
         wake_created_at: wake_created_at
       }}
    else
      _ -> :not_eligible
    end
  end

  defp suppression_reason(txn, scope) do
    case Txn.q(txn, "SELECT state,closedAt FROM assignments WHERE id=?1", [scope.assignment_id]) do
      [["closed", closed_at]]
      when is_integer(closed_at) and closed_at > scope.wake_created_at ->
        {:suppress, "newer_assignment_disposition"}

      [["open", _]] ->
        cond do
          newer_liveness_receipt?(txn, scope.assignment_id, scope.wake_created_at) ->
            {:suppress, "verified_liveness_recovery"}

          Wakes.covering_continuation_in_txn?(txn, scope.assignment_id) ->
            {:suppress, "admitted_continuation_coverage"}

          true ->
            :retain
        end

      _ ->
        :retain
    end
  end

  defp newer_liveness_receipt?(txn, assignment_id, observed_at) do
    Txn.q(
      txn,
      "SELECT 1 FROM supervision_liveness_receipts WHERE assignmentId=?1 AND acceptedAt>?2 LIMIT 1",
      [assignment_id, observed_at]
    ) == [[1]]
  end

  # Re-read both the queued turn and the wake in the claim transaction. The
  # sidecar cannot authorize suppression if either durable source changed or
  # no longer proves the same liveness assignment.
  defp originating_wake_still_matches?(txn, scope) do
    case Txn.q(
           txn,
           "SELECT origin,requestRef,createdAt,wakeId FROM turns WHERE seq=?1 AND status='queued'",
           [scope.turn_seq]
         ) do
      [[origin, request_ref, turn_created_at, wake_id]] ->
        wake = wake_in_txn(txn, wake_id)

        turn_created_at == scope.turn_created_at and wake_id == scope.wake_id and
          not human_origin?(origin) and not decision_ref?(request_ref) and
          not decision_wake?(wake) and not continuation_wake?(wake) and
          liveness_wake?(txn, wake, wake_id) and
          wake_value(wake, :assignment_id) == scope.assignment_id and
          wake_value(wake, :created_at) == scope.wake_created_at

      [] ->
        false
    end
  end

  defp liveness_wake?(_txn, %{consumer: consumer}, _wake_id)
       when consumer in ["effort_deadline", "effort_probe"],
       do: true

  defp liveness_wake?(txn, _wake, wake_id) when is_binary(wake_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM supervision_liveness_sidecar WHERE wakeId=?1 LIMIT 1",
      [wake_id]
    ) == [[1]]
  end

  defp liveness_wake?(_txn, _wake, _wake_id), do: false

  defp continuation_wake?(%{wait_mode: wait_mode})
       when wait_mode in ["dependency", "after-turn"],
       do: true

  defp continuation_wake?(_), do: false

  defp wake_in_txn(_txn, nil), do: nil
  defp wake_in_txn(txn, wake_id) when is_binary(wake_id), do: Wakes.get_in_txn(txn, wake_id)

  defp decision_wake?(%{target_gate: 0}), do: true
  defp decision_wake?(_), do: false

  defp decision_ref?(ref) when is_binary(ref), do: String.starts_with?(ref, "dr_")
  defp decision_ref?(_), do: false

  defp human_origin?(origin) when is_binary(origin), do: String.starts_with?(origin, "user:")
  defp human_origin?(_), do: false

  defp valid_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp wake_value(nil, _key), do: nil
  defp wake_value(wake, key), do: Map.get(wake, key)

  defp scope_from_row([turn_seq, assignment_id, turn_created_at, wake_id, wake_created_at]) do
    %{
      turn_seq: turn_seq,
      assignment_id: assignment_id,
      turn_created_at: turn_created_at,
      wake_id: wake_id,
      wake_created_at: wake_created_at
    }
  end
end
