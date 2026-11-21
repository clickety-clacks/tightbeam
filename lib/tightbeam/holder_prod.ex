defmodule Tightbeam.HolderProd do
  @moduledoc false

  alias Tightbeam.{DB, Wakes}
  alias Tightbeam.DB.Txn

  @quiet_ms 30 * 60 * 1_000
  @marker "assignment-holder-prod-v1:"

  # Custody is distinct from assignment creation and reopening. Remember the
  # current term even if custody later returns to a previous holder.
  def ensure_schema(db) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.exec(txn, """
        CREATE TABLE IF NOT EXISTS assignment_holder_prod_custody (
          assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
          changedAt INTEGER NOT NULL
        )
        """)
      end)

    :ok
  end

  def custody_changed_in_txn(txn, assignment_ids, at) do
    Enum.each(assignment_ids, fn id ->
      Txn.q(
        txn,
        """
        INSERT INTO assignment_holder_prod_custody(assignmentId, changedAt) VALUES (?1, ?2)
        ON CONFLICT(assignmentId) DO UPDATE SET changedAt=excluded.changedAt
        """,
        [id, at]
      )

      cancel_pending_in_txn(txn, id)
    end)

    if assignment_ids != [], do: changed_in_txn(txn)
  end

  def changed_in_txn(txn), do: Wakes.schedule_changed_in_txn(txn, :holder_prod_changed)

  def own_notice?(%{origin: "process:tightbeam", obligation_ref: @marker <> _}), do: true
  def own_notice?(_wake), do: false

  def cancel_pending_in_txn(txn, assignment_id) do
    for [id] <-
          Txn.q(
            txn,
            """
            SELECT wakeId FROM wakes
            WHERE assignmentId=?1 AND state='pending' AND deliveredTurnSeq IS NULL
              AND origin='process:tightbeam' AND substr(obligationRef,1,length(?2))=?2
            """,
            [assignment_id, @marker]
          ) do
      cancel_in_txn(txn, id)
    end

    :ok
  end

  def prepare_in_txn(txn, wake) do
    if own_notice?(wake) do
      case candidates(txn, wake.assignment_id, System.system_time(:millisecond)) do
        [[_, holder, _, _, _, episode, id, _, _, 1]]
        when holder == wake.session_key and episode == wake.obligation_ref and id == wake.wake_id ->
          true

        _ ->
          cancel_in_txn(txn, wake.wake_id)
          false
      end
    else
      true
    end
  end

  defp cancel_in_txn(txn, wake_id) do
    unless Wakes.cancel_in_txn(txn, %{
             wake_id: wake_id,
             requester: %{kind: "process", id: "tightbeam:rail-remedy"},
             reason_kind: "superseded",
             causal_source: %{kind: "wake", id: wake_id},
             outcome: %{kind: "no_replacement"}
           }) do
      raise DB.Error, message: "holder prod supersession did not commit: #{wake_id}"
    end
  end

  # Ordinary holder activity and the end of a real path start the quiet
  # interval. The gateway's own notice and the turn it creates never rearm
  # the same assignment on their own.
  @candidates """
  WITH quiet_starts AS (
    SELECT a.id, a.holderKey, a.workItemId, s.ownerUserId,
           MAX(a.openedAt, COALESCE(c.changedAt, 0),
             COALESCE((SELECT MAX(r.ts) FROM assignment_reopenings r WHERE r.assignmentId=a.id), 0),
             COALESCE((SELECT MAX(p.ts) FROM attests p
                       WHERE p.assignmentId=a.id AND p.bySession=a.holderKey), 0),
             COALESCE((SELECT MAX(p.createdAt) FROM artifacts p
                       WHERE p.producedByAssignmentId=a.id AND p.createdBySession=a.holderKey), 0),
             COALESCE((SELECT MAX(p.raisedAt) FROM decision_requests p
                       WHERE p.assignmentId=a.id AND p.raiserSessionKey=a.holderKey), 0),
             COALESCE((SELECT MAX(t.endedAt) FROM turns t
                       WHERE t.sessionKey=a.holderKey AND (t.startedAt IS NOT NULL OR t.assignmentId=a.id)
                         AND NOT EXISTS (
                           SELECT 1 FROM wakes p WHERE p.deliveredTurnSeq=t.seq
                             AND p.assignmentId=a.id AND substr(p.obligationRef,1,length(?2))=?2
                         )), 0),
             COALESCE((SELECT MAX(MAX(w.createdAt, COALESCE(w.firedAt,0), COALESCE(w.canceledAt,0)))
                       FROM wakes w WHERE w.sessionKey=a.holderKey
                         AND w.state IN ('fired','canceled')
                         AND w.consumer='prompt' AND w.digest=0
                         AND NOT (w.origin='process:tightbeam'
                           AND COALESCE(substr(w.obligationRef,1,length(?2))=?2,0))
                         AND (
                           (w.creatorSessionKey=a.holderKey AND (w.assignmentId=a.id OR w.assignmentId IS NULL))
                           OR
                           (w.assignmentId=a.id AND (
                             w.deliveredTurnSeq IS NOT NULL OR w.firedAt IS NOT NULL OR
                             (w.canceledAt>=w.dueAt AND w.waitMode IS NULL AND w.conditionKind IS NULL)
                           ))
                         )), 0)
           ) AS quietSince
    FROM assignments a
    JOIN sessions s ON s.sessionKey=a.holderKey AND s.state='active'
    LEFT JOIN assignment_holder_prod_custody c ON c.assignmentId=a.id
    WHERE a.state='open' /* assignment_filter */
  ), episodes AS (
    SELECT quiet_starts.*, ?2 || id || ':' || holderKey || ':' || quietSince AS episodeId
    FROM quiet_starts
  )
  SELECT e.id, e.holderKey, e.workItemId, e.ownerUserId, e.quietSince, e.episodeId,
         p.wakeId, p.state, p.deliveredTurnSeq,
         NOT EXISTS (
           SELECT 1 FROM turns t
           WHERE t.sessionKey=e.holderKey
             AND t.status IN ('queued','running')
             AND (t.status='running' OR (t.status='queued' AND (
               (t.assignmentId=e.id AND t.seq IS NOT p.deliveredTurnSeq) OR EXISTS (
               SELECT 1 FROM wakes w WHERE w.deliveredTurnSeq=t.seq AND w.assignmentId=e.id
                 AND w.digest=0
                 AND w.wakeId IS NOT p.wakeId
             ))))
         )
         AND NOT EXISTS (
           SELECT 1 FROM wakes w
           WHERE w.sessionKey=e.holderKey AND w.state='pending' AND w.consumer='prompt' AND w.digest=0
             AND (w.assignmentId=e.id OR w.assignmentId IS NULL)
             AND (w.creatorSessionKey=e.holderKey OR
               (w.assignmentId=e.id
                 AND (w.waitMode IS NULL OR w.recognitionAt IS NOT NULL)
                 AND (w.dueAt<=?3 OR w.firedAt IS NOT NULL OR w.recognitionAt IS NOT NULL)))
             AND (p.wakeId IS NULL OR w.wakeId<>p.wakeId)
         ) AS idle
  FROM episodes e
  LEFT JOIN wakes p ON p.assignmentId=e.id AND p.sessionKey=e.holderKey
    AND p.origin='process:tightbeam' AND p.obligationRef=e.episodeId
  """

  def next_deadline_in_txn(txn, at) do
    candidates(txn, nil, at)
    |> Enum.flat_map(fn
      [_, _, _, _, since, _, nil, _, _, 1] -> [since + @quiet_ms]
      _ -> []
    end)
    |> Enum.min(fn -> nil end)
  end

  def admit_due_in_txn(txn, at, batch \\ 100) do
    due =
      for [id, holder, item, owner, since, episode, nil, _, _, 1] <- candidates(txn, nil, at),
          since + @quiet_ms <= at,
          do: {since, id, holder, item, owner, episode}

    for {_since, id, holder, item, owner, episode} <- due |> Enum.sort() |> Enum.take(batch) do
      Wakes.schedule_in_txn(txn, %{
        session_key: holder,
        origin: "process:tightbeam",
        owner_user_id: owner,
        assignment_id: id,
        work_item_id: item,
        activity_assignment_id: nil,
        due_at: at,
        class: "fyi",
        obligation_ref: episode,
        prompt:
          "Your assignment #{id} has been quiet for 30 minutes. Continue the work, or if you are legitimately waiting, record a fact, predicate, or timed fallback wait."
      })
    end

    :ok
  end

  def evidence(db, assignment_id, holder) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        case candidates(txn, assignment_id, System.system_time(:millisecond)) do
          [[^assignment_id, ^holder, _, _, since, episode, wake, state, delivered, 1]] ->
            %{
              holderSessionKey: holder,
              quietSince: since,
              episodeId: episode,
              wakeId: wake,
              state: evidence_state(state, delivered)
            }

          _ ->
            nil
        end
      end)

    result
  end

  defp evidence_state(_state, delivered) when is_integer(delivered), do: "delivered"
  defp evidence_state("pending", _delivered), do: "pending"
  defp evidence_state("canceled", _delivered), do: "canceled"
  defp evidence_state("fired", _delivered), do: "fired"
  defp evidence_state(nil, _delivered), do: "scheduled"

  @single_candidate String.replace(@candidates, "/* assignment_filter */", "AND a.id=?1")

  defp candidates(txn, nil, at), do: Txn.q(txn, @candidates, [nil, @marker, at])

  defp candidates(txn, assignment_id, at),
    do: Txn.q(txn, @single_candidate, [assignment_id, @marker, at])
end
