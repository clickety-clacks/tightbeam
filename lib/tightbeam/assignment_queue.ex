defmodule Tightbeam.AssignmentQueue do
  @moduledoc """
  Read-only queue summaries for a single assignment's queued turns.

  A turn may carry its assignment directly, through its source wake, or through
  the audited liveness scope. Scheduled wakes without a queued turn are not in
  the holder's current inbox.
  """

  alias Tightbeam.DB.Txn

  @doc false
  def read_in_txn(%Txn{} = txn, assignment_id, principal, now_ms)
      when is_binary(assignment_id) and is_integer(now_ms) do
    case Txn.q(
           txn,
           """
           SELECT a.holderKey,a.openedByUser,a.openedBySession,w.ownerUserId
           FROM assignments AS a
           LEFT JOIN work_items AS w ON w.id=a.workItemId
           WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [] ->
        :not_found

      [[holder_key, opened_by_user, opened_by_session, owner_user_id]] ->
        if authorized?(principal, opened_by_user, opened_by_session, owner_user_id) do
          {:ok, summarize_in_txn(txn, assignment_id, holder_key, now_ms)}
        else
          :forbidden
        end
    end
  end

  defp summarize_in_txn(txn, assignment_id, holder_key, now_ms) do
    rows =
      Txn.q(
        txn,
        """
        SELECT t.origin,t.createdAt
        FROM turns AS t
        LEFT JOIN wakes AS w ON w.wakeId=t.wakeId
        LEFT JOIN queued_message_scopes AS q ON q.turnSeq=t.seq
        WHERE t.sessionKey=?1
          AND t.status='queued'
          AND (t.assignmentId=?2 OR w.assignmentId=?2 OR q.assignmentId=?2)
          AND (t.assignmentId IS NULL OR t.assignmentId=?2)
          AND (w.assignmentId IS NULL OR w.assignmentId=?2)
          AND (q.assignmentId IS NULL OR q.assignmentId=?2)
        ORDER BY t.createdAt,t.seq
        """,
        [holder_key, assignment_id]
      )

    oldest_age_ms =
      case List.first(rows) do
        [_sender, created_at] -> max(now_ms - created_at, 0)
        nil -> nil
      end

    senders =
      rows
      |> Enum.map(fn [sender, _created_at] -> sender end)
      |> Enum.uniq()

    %{
      count: length(rows),
      oldestAgeMs: oldest_age_ms,
      senders: senders
    }
  end

  defp authorized?({:session, session_key}, _opened_by_user, opened_by_session, _owner_user_id)
       when is_binary(session_key) and session_key != "",
       do: session_key == opened_by_session

  defp authorized?({:user, user_id}, opened_by_user, _opened_by_session, owner_user_id)
       when is_binary(user_id) and user_id != "",
       do: user_id == opened_by_user or user_id == owner_user_id

  defp authorized?(_principal, _opened_by_user, _opened_by_session, _owner_user_id),
    do: false
end
