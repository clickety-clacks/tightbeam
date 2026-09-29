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

  @replacement_requests_ddl """
  CREATE TABLE IF NOT EXISTS queued_message_replacement_requests (
    wakeId       TEXT PRIMARY KEY REFERENCES wakes(wakeId) ON DELETE RESTRICT,
    assignmentId TEXT NOT NULL REFERENCES assignments(id) ON DELETE RESTRICT,
    requestedAt  INTEGER NOT NULL CHECK(requestedAt >= 0),
    requestOrder INTEGER NOT NULL CHECK(requestOrder > 0)
  );
  """

  @replacement_requests_index_ddl """
  CREATE INDEX IF NOT EXISTS queued_message_replacement_assignment
    ON queued_message_replacement_requests(assignmentId, requestedAt);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    with :ok <- DB.execute(db, @ddl),
         :ok <- DB.execute(db, @replacement_requests_ddl),
         :ok <- ensure_replacement_request_order(db),
         :ok <- DB.execute(db, @replacement_requests_index_ddl) do
      :ok
    end
  end

  defp ensure_replacement_request_order(db) do
    case DB.transaction(db, &ensure_replacement_request_order_in_txn/1) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_replacement_request_order_in_txn(%Txn{} = txn) do
    columns =
      Txn.q(txn, "PRAGMA table_info(queued_message_replacement_requests)")
      |> Enum.map(&Enum.at(&1, 1))

    case columns do
      ["wakeId", "assignmentId", "requestedAt"] ->
        :ok =
          Txn.exec(
            txn,
            "ALTER TABLE queued_message_replacement_requests " <>
              "ADD COLUMN requestOrder INTEGER NOT NULL DEFAULT 0"
          )

        Txn.q(
          txn,
          "UPDATE queued_message_replacement_requests SET requestOrder=rowid WHERE requestOrder=0"
        )

        :ok

      ["wakeId", "assignmentId", "requestedAt", "requestOrder"] ->
        case Txn.q(
               txn,
               "SELECT wakeId,requestOrder FROM queued_message_replacement_requests " <>
                 "WHERE requestOrder <= 0 LIMIT 1"
             ) do
          [] ->
            :ok

          invalid_rows ->
            raise ArgumentError,
                  "invalid queued message replacement request order rows: #{inspect(invalid_rows)}"
        end

      unexpected_columns ->
        raise ArgumentError,
              "unexpected queued message replacement request schema: #{inspect(unexpected_columns)}"
    end
  end

  @doc "Persist the sender's explicit replacement scope on its durable wake row."
  @spec record_replacement_request_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def record_replacement_request_in_txn(%Txn{} = txn, wake_id, assignment_id)
      when is_binary(wake_id) and is_binary(assignment_id) do
    Txn.q(
      txn,
      """
      INSERT INTO queued_message_replacement_requests
        (wakeId,assignmentId,requestedAt,requestOrder)
      VALUES (?1,?2,?3,(SELECT COALESCE(MAX(requestOrder),0)+1
                         FROM queued_message_replacement_requests))
      """,
      [wake_id, assignment_id, System.system_time(:millisecond)]
    )

    :ok
  end

  @doc "Copy an explicit replacement request when the wake retry creates a new durable row."
  @spec copy_replacement_request_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def copy_replacement_request_in_txn(%Txn{} = txn, source_wake_id, replacement_wake_id) do
    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO queued_message_replacement_requests
        (wakeId,assignmentId,requestedAt,requestOrder)
      SELECT ?2,assignmentId,requestedAt,requestOrder
      FROM queued_message_replacement_requests WHERE wakeId=?1
      """,
      [source_wake_id, replacement_wake_id]
    )

    :ok
  end

  @doc "Return the explicit assignment scope requested for one wake, if any."
  @spec replacement_assignment_id_in_txn(Txn.t(), String.t() | nil) :: String.t() | nil
  def replacement_assignment_id_in_txn(_txn, nil), do: nil

  def replacement_assignment_id_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    case Txn.q(
           txn,
           "SELECT assignmentId FROM queued_message_replacement_requests WHERE wakeId=?1",
           [wake_id]
         ) do
      [[assignment_id]] -> assignment_id
      [] -> nil
    end
  end

  @doc "Terminalize this sender's older eligible turns for the exact holder and assignment."
  @spec replace_own_queued_in_txn(Txn.t(), pos_integer(), map()) :: [pos_integer()]
  def replace_own_queued_in_txn(%Txn{} = txn, replacement_seq, attrs) do
    assignment_id = replacement_assignment_id_in_txn(txn, Map.get(attrs, :wake_id))

    session_key = Map.get(attrs, :session_key)
    origin = Map.get(attrs, :origin)

    sender_session_key =
      replacement_sender_session_in_txn(txn, assignment_id, Map.get(attrs, :wake_id))

    if valid_replacement_request?(
         txn,
         assignment_id,
         session_key,
         origin,
         sender_session_key,
         Map.get(attrs, :wake_id),
         attrs
       ) do
      candidates =
        Txn.q(
          txn,
          """
          SELECT t.seq,t.createdAt,t.wakeId,t.requestRef,t.origin,w.createdAt,w.targetGate,
                 w.consumer,w.waitMode,w.obligationRef
          FROM turns t
          LEFT JOIN wakes w ON w.wakeId=t.wakeId
          WHERE t.sessionKey=?1 AND t.status='queued' AND t.seq<>?2
            AND (
              (t.wakeId IS NULL AND t.assignmentId=?3 AND t.origin=?5 AND EXISTS (
                SELECT 1 FROM assignments a
                WHERE a.id=t.assignmentId AND a.openedBySession=?4
              ))
              OR
              -- A wake's assignment association is not replacement consent; only
              -- an explicit earlier replacement request makes it a candidate.
              -- Retry wakes keep their original request order as well as the
              -- requestedAt timestamp, so delayed older requests stay older.
              (t.wakeId IS NOT NULL AND w.creatorSessionKey=?4 AND EXISTS (
                SELECT 1 FROM queued_message_replacement_requests r
                JOIN queued_message_replacement_requests incoming
                  ON incoming.wakeId=?6 AND incoming.assignmentId=?3
                WHERE r.wakeId=t.wakeId AND r.assignmentId=?3
                  AND (r.requestedAt < incoming.requestedAt OR
                       (r.requestedAt = incoming.requestedAt AND
                        r.requestOrder < incoming.requestOrder))
              ))
            )
            AND (t.wakeId IS NULL OR w.wakeId IS NOT NULL)
            AND NOT EXISTS (
              SELECT 1 FROM queued_message_scopes s WHERE s.turnSeq=t.seq
            )
          ORDER BY t.seq
          """,
          [
            session_key,
            replacement_seq,
            assignment_id,
            sender_session_key,
            origin,
            Map.get(attrs, :wake_id)
          ]
        )

      Enum.reduce(candidates, [], fn row, replaced ->
        case replaceable_source(row) do
          {:ok, source} ->
            if Ledger.cancel_queued_in_txn(
                 txn,
                 source.turn_seq,
                 "sender_requested_replacement"
               ) do
              record_replacement_in_txn(
                txn,
                source,
                assignment_id,
                session_key,
                origin,
                sender_session_key,
                replacement_seq,
                Map.get(attrs, :wake_id)
              )

              [source.turn_seq | replaced]
            else
              replaced
            end

          :protected ->
            replaced
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  end

  defp valid_replacement_request?(
         txn,
         assignment_id,
         session_key,
         origin,
         sender_session_key,
         wake_id,
         attrs
       ) do
    is_binary(assignment_id) and String.trim(assignment_id) != "" and
      is_binary(session_key) and String.trim(session_key) != "" and
      is_binary(sender_session_key) and String.trim(sender_session_key) != "" and
      replacement_origin_matches_sender?(txn, origin, sender_session_key) and
      Map.get(attrs, :queue_message_kind) == nil and
      not decision_ref?(Map.get(attrs, :request_ref)) and
      Txn.q(
        txn,
        "SELECT 1 FROM assignments WHERE id=?1 AND holderKey=?2 AND state='open'",
        [assignment_id, session_key]
      ) == [[1]] and
      replacement_wake_is_ordinary?(txn, wake_id, origin, sender_session_key)
  end

  defp replacement_sender_session_in_txn(_txn, nil, _wake_id), do: nil

  defp replacement_sender_session_in_txn(txn, assignment_id, nil) do
    case Txn.q(txn, "SELECT openedBySession FROM assignments WHERE id=?1", [assignment_id]) do
      [[session_key]] -> session_key
      [] -> nil
    end
  end

  defp replacement_sender_session_in_txn(txn, _assignment_id, wake_id) do
    case Txn.q(txn, "SELECT creatorSessionKey FROM wakes WHERE wakeId=?1", [wake_id]) do
      [[session_key]] -> session_key
      [] -> nil
    end
  end

  defp replaceable_origin?(origin) when is_binary(origin) do
    String.starts_with?(origin, "agent:") or String.starts_with?(origin, "session:")
  end

  defp replaceable_origin?(_origin), do: false

  defp replacement_origin_matches_sender?(_txn, "session:" <> origin_session, sender),
    do: origin_session == sender

  defp replacement_origin_matches_sender?(txn, "agent:" <> role, sender) do
    Txn.q(
      txn,
      "SELECT 1 FROM roles WHERE name=?1 AND boundSessionKey=?2",
      [role, sender]
    ) == [[1]]
  end

  defp replacement_origin_matches_sender?(_txn, _origin, _sender), do: false

  defp replacement_wake_is_ordinary?(_txn, nil, _origin, _sender_session_key), do: true

  defp replacement_wake_is_ordinary?(txn, wake_id, origin, sender_session_key) do
    case Txn.q(
           txn,
           """
           SELECT origin,creatorSessionKey,targetGate,consumer,waitMode,obligationRef
           FROM wakes WHERE wakeId=?1
           """,
           [wake_id]
         ) do
      [[^origin, ^sender_session_key, target_gate, "prompt", nil, nil]]
      when target_gate != 0 ->
        true

      _ ->
        false
    end
  end

  defp replaceable_source([
         seq,
         turn_created_at,
         wake_id,
         request_ref,
         origin,
         wake_created_at,
         target_gate,
         consumer,
         wait_mode,
         obligation_ref
       ]) do
    cond do
      decision_ref?(request_ref) ->
        :protected

      not replaceable_origin?(origin) ->
        :protected

      is_nil(wake_id) ->
        {:ok,
         %{
           turn_seq: seq,
           turn_created_at: turn_created_at,
           wake_id: nil,
           wake_created_at: nil
         }}

      target_gate == 0 or consumer != "prompt" or not is_nil(wait_mode) or
          not is_nil(obligation_ref) ->
        :protected

      true ->
        {:ok,
         %{
           turn_seq: seq,
           turn_created_at: turn_created_at,
           wake_id: wake_id,
           wake_created_at: wake_created_at
         }}
    end
  end

  defp record_replacement_in_txn(
         txn,
         source,
         assignment_id,
         session_key,
         origin,
         sender_session_key,
         replacement_seq,
         replacement_wake_id
       ) do
    EventLog.lifecycle_in_txn(
      txn,
      "queued_message_suppressed",
      Integer.to_string(source.turn_seq),
      JSON.encode!(%{
        turnSeq: source.turn_seq,
        messageKind: "sender-replacement",
        scopeKind: "assignment",
        scopeId: assignment_id,
        cause: "sender_requested_replacement",
        sourceCreatedAt: source.turn_created_at,
        sourceKind: if(source.wake_id, do: "wake", else: "turn"),
        sourceId: source.wake_id || Integer.to_string(source.turn_seq),
        sourceObservedAt: source.wake_created_at || source.turn_created_at,
        senderOrigin: origin,
        senderSessionKey: sender_session_key,
        holderSessionKey: session_key,
        replacementTurnSeq: replacement_seq,
        replacementWakeId: replacement_wake_id
      })
    )
  end

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
