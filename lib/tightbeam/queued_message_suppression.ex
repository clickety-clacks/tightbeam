defmodule Tightbeam.QueuedMessageSuppression do
  @moduledoc """
  Sender-authorized replacement of an earlier queued notice.

  Assignment attribution alone never retracts a notice. A replacement applies
  only when the authenticated sender explicitly scoped both the prior and new
  notice to the same open assignment and recipient.
  """

  alias Tightbeam.{DB, EventLog, Ledger, Wakes}
  alias Tightbeam.DB.Txn

  @replacement_requests_ddl """
  CREATE TABLE IF NOT EXISTS queued_message_replacement_requests (
    wakeId       TEXT PRIMARY KEY REFERENCES wakes(wakeId) ON DELETE RESTRICT,
    assignmentId TEXT NOT NULL REFERENCES assignments(id) ON DELETE RESTRICT,
    requestedAt  INTEGER NOT NULL CHECK(requestedAt >= 0)
  );
  CREATE INDEX IF NOT EXISTS queued_message_replacement_assignment
    ON queued_message_replacement_requests(assignmentId, requestedAt);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @replacement_requests_ddl)

  @doc "Persist the sender's explicit replacement scope on its durable wake row."
  @spec record_replacement_request_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def record_replacement_request_in_txn(%Txn{} = txn, wake_id, assignment_id)
      when is_binary(wake_id) and is_binary(assignment_id) do
    requested_at = next_replacement_request_at_in_txn(txn, assignment_id)

    Txn.q(
      txn,
      """
      INSERT INTO queued_message_replacement_requests(wakeId,assignmentId,requestedAt)
      VALUES (?1,?2,?3)
      """,
      [wake_id, assignment_id, requested_at]
    )

    :ok
  end

  # requestedAt is the durable order key used to distinguish older sender
  # requests from replacements. Wall-clock milliseconds can collide or move
  # backward, so keep each new request strictly after prior requests for this
  # assignment. Retry wakes copy their source request's original value.
  defp next_replacement_request_at_in_txn(%Txn{} = txn, assignment_id) do
    now = System.system_time(:millisecond)

    case Txn.q(
           txn,
           "SELECT MAX(requestedAt) FROM queued_message_replacement_requests WHERE assignmentId=?1",
           [assignment_id]
         ) do
      [[nil]] -> now
      [[latest]] when is_integer(latest) -> max(now, latest + 1)
    end
  end

  @doc "Copy an explicit replacement request when the wake retry creates a new durable row."
  @spec copy_replacement_request_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def copy_replacement_request_in_txn(%Txn{} = txn, source_wake_id, replacement_wake_id) do
    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO queued_message_replacement_requests(wakeId,assignmentId,requestedAt)
      SELECT ?2,assignmentId,requestedAt
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

  @doc false
  def replace_pending_wakes_in_txn(%Txn{} = txn, replacement_wake, assignment_id)
      when is_map(replacement_wake) and is_binary(assignment_id) do
    requester_session = replacement_wake.creator_session_key

    attrs = %{
      wake_id: replacement_wake.wake_id,
      session_key: replacement_wake.session_key,
      origin: replacement_wake.origin,
      request_ref: nil
    }

    if valid_replacement_request?(
         txn,
         assignment_id,
         replacement_wake.session_key,
         replacement_wake.origin,
         requester_session,
         replacement_wake.wake_id,
         attrs
       ) do
      incoming_requested_at =
        case Txn.q(
               txn,
               "SELECT requestedAt FROM queued_message_replacement_requests WHERE wakeId=?1 AND assignmentId=?2",
               [replacement_wake.wake_id, assignment_id]
             ) do
          [[requested_at]] -> requested_at
          [] -> nil
        end

      if is_integer(incoming_requested_at) do
        sources =
          Txn.q(
            txn,
            """
            SELECT w.wakeId,w.createdAt,r.requestedAt
            FROM wakes w
            JOIN queued_message_replacement_requests r ON r.wakeId=w.wakeId
            WHERE w.state='pending' AND w.sessionKey=?1 AND w.origin=?2
              AND w.creatorSessionKey=?3
              -- Ordinary correction wakes retain NULL assignment attribution;
              -- the explicit request row carries their replacement scope.
              AND (w.assignmentId IS NULL OR w.assignmentId=?4)
              AND w.consumer='prompt' AND w.digest=0 AND w.targetGate<>0
              AND w.conditionKind IS NULL AND w.waitMode IS NULL
              AND w.obligationRef IS NULL AND r.assignmentId=?4
              AND r.requestedAt<?5
              AND NOT EXISTS (
                SELECT 1 FROM notice_batch_members m
                JOIN notice_batches b ON b.batchId=m.batchId
                WHERE m.sourceWakeId=w.wakeId AND m.state='included'
                  AND b.state IN ('sealed','delivery_pending','delivered','delivery_failed')
              )
            ORDER BY r.requestedAt,w.rowid
            """,
            [
              replacement_wake.session_key,
              replacement_wake.origin,
              requester_session,
              assignment_id,
              incoming_requested_at
            ]
          )

        Enum.each(sources, fn [source_wake_id, source_created_at, _requested_at] ->
          at = System.system_time(:millisecond)

          canceled =
            Wakes.cancel_in_txn(txn, %{
              wake_id: source_wake_id,
              requester: %{kind: "process", id: "tightbeam:assignments"},
              reason_kind: "superseded",
              causal_source: %{kind: "wake", id: replacement_wake.wake_id},
              outcome: %{kind: "replacement", replacement_wake_id: replacement_wake.wake_id}
            })

          case canceled do
            true ->
              EventLog.lifecycle_in_txn(
                txn,
                "queued_message_suppressed",
                source_wake_id,
                JSON.encode!(%{
                  messageKind: "sender-replacement",
                  scopeKind: "assignment",
                  scopeId: assignment_id,
                  cause: "sender_requested_replacement",
                  sourceKind: "wake",
                  sourceId: source_wake_id,
                  sourceCreatedAt: source_created_at,
                  senderOrigin: replacement_wake.origin,
                  senderSessionKey: requester_session,
                  holderSessionKey: replacement_wake.session_key,
                  replacementWakeId: replacement_wake.wake_id
                })
              )

              :ok

            _ ->
              raise DB.Error,
                message: "assignment-scoped sender replacement refused for wake #{source_wake_id}"
          end
        end)
      end
    end

    :ok
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
              -- Retry wakes keep the original requestedAt, so a delayed older
              -- request cannot cancel a newer queued replacement.
              (t.wakeId IS NOT NULL AND w.creatorSessionKey=?4 AND EXISTS (
                SELECT 1 FROM queued_message_replacement_requests r
                WHERE r.wakeId=t.wakeId AND r.assignmentId=?3
                  AND r.requestedAt < (
                    SELECT incoming.requestedAt
                    FROM queued_message_replacement_requests incoming
                    WHERE incoming.wakeId=?6 AND incoming.assignmentId=?3
                  )
              ))
            )
            AND (t.wakeId IS NULL OR w.wakeId IS NOT NULL)
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

  defp decision_ref?(ref) when is_binary(ref), do: String.starts_with?(ref, "dr_")
  defp decision_ref?(_ref), do: false

end
