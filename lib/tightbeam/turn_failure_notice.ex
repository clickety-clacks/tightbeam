defmodule Tightbeam.TurnFailureNotice do
  @moduledoc false

  alias Tightbeam.{DB, Gateway, Org}
  alias Tightbeam.DB.Txn

  # Health redelivery retains messageId but cannot retain the UNIQUE wakeId.
  # Ordinary wake retries instead retain their root in wake_retry_attempts.
  # Both routes resolve to the first failed turn of that delivery.
  def cause_seq(db, seq, session_key, message_id, wake_id) do
    [[cause_seq]] =
      query(
        db,
        """
        SELECT min(seq) FROM (
          SELECT seq FROM turns
          WHERE messageId=?3 AND sessionKey=?2 AND seq<?1
            AND status IN ('failed','failed_unknown')
          UNION ALL
          SELECT t.seq FROM wake_retry_attempts retry
          JOIN turns t ON t.wakeId=retry.rootWakeId
          WHERE retry.wakeId=?4 AND t.sessionKey=?2 AND t.seq<?1
            AND t.status IN ('failed','failed_unknown')
          UNION ALL
          SELECT ?1
        )
        """,
        [seq, session_key, message_id, wake_id]
      )

    cause_seq
  end

  def source_wake_id(db, seq, session_key, message_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT wakeId FROM turns
        WHERE messageId=?3 AND sessionKey=?2 AND seq<?1 AND wakeId IS NOT NULL
          AND status IN ('failed','failed_unknown')
        ORDER BY seq LIMIT 1
        """,
        [seq, session_key, message_id]
      )

    case rows do
      [[wake_id]] -> wake_id
      [] -> nil
    end
  end

  # The initial destination is selected before any of the routes sends. A
  # failed bubble notice has its own escalation and does not use this choice.
  def recipient(%Txn{} = txn, session_key, assignment_id, owner_fallback? \\ true) do
    case Txn.q(
           txn,
           """
           WITH RECURSIVE lineage(sessionKey,depth) AS (
             SELECT #{Org.current_parent_sql("source")},1
             FROM sessions source WHERE source.sessionKey=?1
             UNION ALL
             SELECT #{Org.current_parent_sql("ancestor")},lineage.depth+1
             FROM lineage JOIN sessions ancestor ON ancestor.sessionKey=lineage.sessionKey
             WHERE lineage.depth<32 AND ancestor.state!='active'
           )
           SELECT recipient,route FROM (
             SELECT opener.sessionKey AS recipient,'opener' AS route,0 AS priority
             FROM assignments a
             JOIN sessions opener ON opener.sessionKey=COALESCE(a.currentOpenerSessionKey,a.openedBySession)
             WHERE a.id=?2 AND a.holderKey=?1 AND opener.state='active' AND opener.sessionKey!=?1
             UNION ALL
             SELECT ancestor.sessionKey,'ancestor',lineage.depth
             FROM lineage JOIN sessions ancestor ON ancestor.sessionKey=lineage.sessionKey
             WHERE ancestor.state='active' AND ancestor.sessionKey!=?1
             UNION ALL
             SELECT main.sessionKey,'owner',33
             FROM sessions source JOIN sessions main ON main.ownerUserId=source.ownerUserId
             WHERE source.sessionKey=?1 AND ?3=1 AND main.kind='main'
               AND main.state='active' AND main.sessionKey!=?1
           )
           ORDER BY priority LIMIT 1
           """,
           [session_key, assignment_id, if(owner_fallback?, do: 1, else: 0)]
         ) do
      [[recipient, route]] -> {recipient, route}
      [] -> nil
    end
  end

  def for_turn(db, seq) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        case Txn.q(txn, "SELECT sessionKey,assignmentId FROM turns WHERE seq=?1", [seq]) do
          [[session_key, assignment_id]] ->
            if Tightbeam.Assignments.decision_conditions_for_delivery_in_txn(txn, seq) == [],
              do: recipient(txn, session_key, assignment_id),
              else: :decision_carrier

          [] ->
            nil
        end
      end)

    result
  end

  def original_cause_in_txn(txn, seq) do
    [[session_key, message_id, wake_id, error]] =
      Txn.q(txn, "SELECT sessionKey,messageId,wakeId,error FROM turns WHERE seq=?1", [seq])

    first = cause_seq(txn, seq, session_key, message_id, wake_id)

    if first == seq do
      {seq, error}
    else
      [[original_error]] = Txn.q(txn, "SELECT error FROM turns WHERE seq=?1", [first])
      {first, original_error}
    end
  end

  # The first failure sequence is shared by all routes, independent of the
  # recipient. Existing receipt, question and bubble records are the evidence.
  def initial_admitted?(txn, seq, reason) do
    suffix = "\nReason: " <> Gateway.recorded_turn_failure_sentence(reason)
    prefix = "bubble:#{seq}:"

    Txn.q(
      txn,
      """
      SELECT 1 FROM wakes WHERE wakeId=?1 OR (wakeId>=?2 AND wakeId<?3)
      UNION ALL
      SELECT 1 FROM turns WHERE wakeId>=?2 AND wakeId<?3
      UNION ALL
      SELECT 1 FROM sessions recipient
      WHERE EXISTS (
        SELECT 1 FROM messages
        WHERE sessionKey=recipient.sessionKey AND deviceId='process:tightbeam' AND clientMessageId=?4
          AND substr(content,-length(?5))=?5
      )
      LIMIT 1
      """,
      [
        "w_health_redelivery_parent_#{seq}",
        prefix,
        "bubble:#{seq};",
        "wake-undelivered:#{seq}",
        suffix
      ]
    ) != []
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
