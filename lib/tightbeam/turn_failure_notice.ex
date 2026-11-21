defmodule Tightbeam.TurnFailureNotice do
  @moduledoc false

  alias Tightbeam.{DB, Org}

  # Health redelivery retains messageId but cannot retain the UNIQUE wakeId.
  # Ordinary wake retries instead retain their root in wake_retry_attempts.
  # Both routes resolve to the first failed turn of that delivery.
  def cause_seq(db, seq, session_key, message_id, wake_id) do
    {:ok, [[cause_seq]]} =
      DB.query(
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

  def recipient(db, turn_seq) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT COALESCE(opener.sessionKey,parent.sessionKey)
        FROM turns t JOIN sessions s ON s.sessionKey=t.sessionKey
        LEFT JOIN assignments a ON a.id=t.assignmentId AND a.holderKey=t.sessionKey
        LEFT JOIN sessions opener ON opener.sessionKey=COALESCE(a.currentOpenerSessionKey,a.openedBySession)
          AND opener.state='active' AND opener.sessionKey!=s.sessionKey
        LEFT JOIN sessions parent ON parent.sessionKey=#{Org.current_parent_sql("s")}
          AND parent.state='active' AND parent.sessionKey!=s.sessionKey
        WHERE t.seq=?1
        """,
        [turn_seq]
      )

    case rows do
      [[recipient]] when is_binary(recipient) -> recipient
      _ -> nil
    end
  end
end
