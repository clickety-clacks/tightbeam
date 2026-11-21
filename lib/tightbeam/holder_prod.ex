defmodule Tightbeam.HolderProd do
  @moduledoc false

  alias Tightbeam.{DB, Wakes}
  alias Tightbeam.DB.Txn

  @quiet_ms 30 * 60 * 1_000
  @hour_ms 60 * 60 * 1_000
  @default_hourly_cap 16
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
        );
        CREATE INDEX IF NOT EXISTS holder_prod_turn_end
          ON turns(sessionKey, endedAt DESC) WHERE endedAt IS NOT NULL;
        CREATE TABLE IF NOT EXISTS assignment_holder_prod_attempts (
          id INTEGER PRIMARY KEY,
          episodeId TEXT NOT NULL,
          assignmentId TEXT NOT NULL,
          holderKey TEXT NOT NULL,
          repeatNumber INTEGER NOT NULL,
          admittedAt INTEGER NOT NULL,
          wakeId TEXT UNIQUE
        );
        CREATE INDEX IF NOT EXISTS holder_prod_attempt_episode
          ON assignment_holder_prod_attempts(episodeId, id DESC);
        CREATE INDEX IF NOT EXISTS holder_prod_attempt_report_recency
          ON assignment_holder_prod_attempts(admittedAt) WHERE wakeId IS NULL;
        CREATE INDEX IF NOT EXISTS holder_prod_wake_delivery
          ON wakes(firedAt) WHERE deliveredTurnSeq IS NOT NULL
            AND origin='process:tightbeam' AND substr(obligationRef,1,#{byte_size(@marker)})='#{@marker}';
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
      if current_source?(txn, wake) do
        true
      else
        cancel_in_txn(txn, wake.wake_id)
        false
      end
    else
      true
    end
  end

  defp current_source?(txn, wake) do
    with %{report_only: false} <- settings(),
         [%{holder: holder, episode: episode, wake: id, possible: true}] <-
           candidates(txn, wake.assignment_id, System.system_time(:millisecond), false) do
      holder == wake.session_key and episode == wake.obligation_ref and id == wake.wake_id
    else
      _ -> false
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
  # interval. A turn carrying only holder prods cannot rearm any quiet
  # assignment. Mixed batches still count as ordinary holder activity.
  @candidates """
  WITH own_starts AS MATERIALIZED (
    SELECT a.id, a.holderKey, a.workItemId, s.ownerUserId, s.harness, s.host,
           MAX(a.openedAt, COALESCE(c.changedAt, 0)) AS custodySince,
           MAX(a.openedAt, COALESCE(c.changedAt, 0),
             COALESCE((SELECT MAX(r.ts) FROM assignment_reopenings r WHERE r.assignmentId=a.id), 0),
             COALESCE((SELECT MAX(p.ts) FROM attests p
                       WHERE p.assignmentId=a.id AND p.bySession=a.holderKey), 0),
             COALESCE((SELECT MAX(p.createdAt) FROM artifacts p
                       WHERE p.producedByAssignmentId=a.id AND p.createdBySession=a.holderKey), 0),
             COALESCE((SELECT MAX(p.raisedAt) FROM decision_requests p
                       WHERE p.assignmentId=a.id AND p.raiserSessionKey=a.holderKey), 0),
             COALESCE((SELECT MAX(w.createdAt) FROM wakes w
                       WHERE w.assignmentId=a.id AND w.creatorSessionKey=a.holderKey
                         AND NOT EXISTS(SELECT 1 FROM wake_activity_exclusions x WHERE x.wakeId=w.wakeId)), 0)
           ) AS ownSince
    FROM assignments a
    JOIN sessions s ON s.sessionKey=a.holderKey AND s.state='active'
    LEFT JOIN assignment_holder_prod_custody c ON c.assignmentId=a.id
    WHERE a.state='open' /* assignment_filter */
  ), quiet_starts AS MATERIALIZED (
    SELECT a.*,
           MAX(a.ownSince,
             COALESCE((SELECT MAX(cp.settledAt) FROM assignment_cannot_proceed cp
                       JOIN attests p ON p.id=cp.attestId
                       WHERE cp.assignmentId=a.id AND p.bySession=a.holderKey), 0),
             COALESCE((SELECT t.endedAt FROM turns t
                       WHERE t.sessionKey=a.holderKey AND t.endedAt IS NOT NULL
                         AND (t.startedAt IS NOT NULL OR t.assignmentId=a.id)
                         AND (
                           NOT EXISTS (
                             SELECT 1 FROM wakes p WHERE p.deliveredTurnSeq=t.seq AND p.digest=0
                               AND p.origin='process:tightbeam' AND substr(p.obligationRef,1,length(?2))=?2
                           ) OR EXISTS (
                             SELECT 1 FROM wakes w WHERE w.deliveredTurnSeq=t.seq AND w.digest=0
                               AND NOT (w.origin='process:tightbeam'
                                 AND COALESCE(substr(w.obligationRef,1,length(?2))=?2,0))
                           )
                         )
                       ORDER BY t.endedAt DESC LIMIT 1), 0),
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
    FROM own_starts a
  ), episodes AS (
    SELECT quiet_starts.*, ?2 || id || ':' || holderKey || ':' || quietSince AS episodeId
    FROM quiet_starts
  )
  SELECT e.id, e.holderKey, e.workItemId, e.ownerUserId, e.quietSince, e.episodeId,
         p.wakeId, p.state, p.deliveredTurnSeq, last.repeatNumber,
         CASE WHEN last.wakeId IS NULL THEN last.admittedAt
              WHEN p.deliveredTurnSeq IS NOT NULL THEN p.firedAt END AS lastSentAt,
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
           SELECT 1 FROM assignment_cannot_proceed cp JOIN attests p ON p.id=cp.attestId
           WHERE cp.assignmentId=e.id AND cp.state='standing' AND p.bySession=e.holderKey
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
         )
         AND NOT EXISTS (
           SELECT 1 FROM decision_requests d WHERE d.assignmentId=e.id AND d.status='open'
         )
         AND NOT EXISTS (
           SELECT 1 FROM harness_park_fences f WHERE f.adapterKey=e.harness || ':shared@' || e.host
         )
         AND NOT EXISTS (
           SELECT 1 FROM harness_processes hp
           WHERE hp.adapterKey=e.harness || ':shared@' || e.host AND hp.resolvedAt IS NULL
             AND hp.state IN ('park_requested','kill_failed')
         )
         AND COALESCE((
           SELECT t.status IN ('failed','failed_unknown') AND t.endedAt>=e.ownSince
           FROM turns t
           WHERE t.sessionKey=e.holderKey AND t.endedAt>=e.custodySince
             AND (t.assignmentId=e.id OR EXISTS (
               SELECT 1 FROM wakes w WHERE w.deliveredTurnSeq=t.seq AND w.assignmentId=e.id AND w.digest=0
             ))
           ORDER BY t.endedAt DESC,t.seq DESC LIMIT 1
         ),0)=0 AS possible
  FROM episodes e
  LEFT JOIN assignment_holder_prod_attempts last ON last.id=(
    SELECT n.id FROM assignment_holder_prod_attempts n
    LEFT JOIN wakes w ON w.wakeId=n.wakeId
    WHERE n.episodeId=e.episodeId AND (
      (?4=1 AND n.wakeId IS NULL) OR
      (?4=0 AND (w.state='pending' OR w.deliveredTurnSeq IS NOT NULL))
    )
    ORDER BY n.id DESC LIMIT 1
  )
  LEFT JOIN wakes p ON p.wakeId=last.wakeId
  """

  def settings do
    %{
      cap: Application.get_env(:tightbeam, :holder_prod_hourly_cap, @default_hourly_cap),
      report_only: Application.get_env(:tightbeam, :holder_prod_report_only, false)
    }
  end

  def next_deadline_in_txn(txn, at, settings \\ settings()) do
    candidates = eligible(txn, at, settings)
    {used, free_at} = budget(txn, at, settings.report_only)

    case Enum.min_by(candidates, & &1.due_at, fn -> nil end) do
      nil -> nil
      %{due_at: due_at} when used < settings.cap -> due_at
      %{due_at: due_at} when is_integer(free_at) -> max(due_at, free_at)
      _ -> nil
    end
  end

  def admit_due_in_txn(txn, at, batch \\ 100, settings \\ settings()) do
    {used, _free_at} = budget(txn, at, settings.report_only)
    slots = max(0, min(settings.cap - used, batch))

    if slots > 0 do
      txn
      |> eligible(at, settings)
      |> Enum.filter(&(&1.due_at <= at))
      |> Enum.sort_by(&{&1.next_repeat, &1.since, &1.id})
      |> Enum.uniq_by(& &1.holder)
      |> Enum.take(slots)
      |> Enum.each(&admit_in_txn(txn, &1, at, settings.report_only))
    end

    :ok
  end

  defp eligible(txn, at, settings) do
    pending = if settings.report_only, do: MapSet.new(), else: pending_holders(txn)

    txn
    |> candidates(nil, at, settings.report_only)
    |> Enum.filter(fn candidate ->
      candidate.possible and candidate.state != "pending" and
        not MapSet.member?(pending, candidate.holder)
    end)
    |> Enum.map(fn candidate ->
      candidate
      |> Map.put(:due_at, max(candidate.since, candidate.sent_at || 0) + @quiet_ms)
      |> Map.put(:next_repeat, (candidate.repeat || -1) + 1)
    end)
  end

  defp pending_holders(txn) do
    txn
    |> Txn.q("""
    SELECT n.holderKey FROM wakes w JOIN assignment_holder_prod_attempts n ON n.wakeId=w.wakeId
    WHERE w.state='pending'
    UNION
    SELECT n.holderKey FROM turns t
    JOIN wakes w ON w.deliveredTurnSeq=t.seq
    JOIN assignment_holder_prod_attempts n ON n.wakeId=w.wakeId
    WHERE t.status='queued'
    """)
    |> MapSet.new(&hd/1)
  end

  # Reservations count until delivery or cancellation. Once delivered, the
  # rolling hour is anchored on actual delivery, so delayed sources cannot burst
  # past the budget. Report-only uses its own simulated stream.
  defp budget(txn, at, true) do
    [[used, earliest]] =
      Txn.q(
        txn,
        """
        SELECT COUNT(*), MIN(admittedAt) FROM assignment_holder_prod_attempts
        WHERE wakeId IS NULL AND admittedAt>?1
        """,
        [at - @hour_ms]
      )

    {used, if(is_integer(earliest), do: earliest + @hour_ms)}
  end

  defp budget(txn, at, false) do
    [[reserved, sent, earliest]] =
      Txn.q(
        txn,
        """
        SELECT (SELECT COUNT(*) FROM wakes w
                JOIN assignment_holder_prod_attempts n ON n.wakeId=w.wakeId
                WHERE w.state='pending' AND w.deliveredTurnSeq IS NULL),
               COUNT(*), MIN(firedAt)
        FROM wakes WHERE firedAt>?1 AND deliveredTurnSeq IS NOT NULL
          AND origin='process:tightbeam' AND substr(obligationRef,1,#{byte_size(@marker)})='#{@marker}'
        """,
        [at - @hour_ms]
      )

    {reserved + sent, if(is_integer(earliest), do: earliest + @hour_ms)}
  end

  defp admit_in_txn(txn, candidate, at, report_only) do
    wake_id =
      if report_only do
        Tightbeam.EventLog.lifecycle_in_txn(
          txn,
          "holder_prod_would_send",
          candidate.id,
          JSON.encode!(%{
            episodeId: candidate.episode,
            repeatNumber: candidate.next_repeat,
            at: at
          })
        )

        nil
      else
        wake =
          Wakes.schedule_in_txn(txn, %{
            session_key: candidate.holder,
            origin: "process:tightbeam",
            owner_user_id: candidate.owner,
            assignment_id: candidate.id,
            work_item_id: candidate.item,
            activity_assignment_id: nil,
            due_at: at,
            class: "fyi",
            obligation_ref: candidate.episode,
            prompt:
              "Your assignment #{candidate.id} has been quiet for 30 minutes. Continue the work. " <>
                "If you are waiting, record a fact, predicate, or timed fallback wait with a short reason. " <>
                "If the work is impossible, attest cannot-proceed. If it is done, attest completion."
          })

        wake.wake_id
      end

    Txn.q(
      txn,
      """
      INSERT INTO assignment_holder_prod_attempts(episodeId, assignmentId, holderKey, repeatNumber, admittedAt, wakeId)
      VALUES (?1,?2,?3,?4,?5,?6)
      """,
      [candidate.episode, candidate.id, candidate.holder, candidate.next_repeat, at, wake_id]
    )
  end

  def evidence(db, assignment_id, holder) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        case candidates(txn, assignment_id, System.system_time(:millisecond), false) do
          [%{holder: ^holder, possible: true} = p] ->
            %{
              holderSessionKey: holder,
              quietSince: p.since,
              episodeId: p.episode,
              wakeId: p.wake,
              repeatNumber: p.repeat,
              state: evidence_state(p.state, p.delivered)
            }

          _ ->
            nil
        end
      end)

    result
  end

  defp evidence_state(_state, delivered) when is_integer(delivered), do: "delivered"
  defp evidence_state("pending", _delivered), do: "pending"
  defp evidence_state(nil, _delivered), do: "scheduled"

  @single_candidate String.replace(@candidates, "/* assignment_filter */", "AND a.id=?1")

  defp candidates(txn, assignment_id, at, report_only) do
    query = if is_nil(assignment_id), do: @candidates, else: @single_candidate

    txn
    |> Txn.q(query, [assignment_id, @marker, at, if(report_only, do: 1, else: 0)])
    |> Enum.map(fn [
                     id,
                     holder,
                     item,
                     owner,
                     since,
                     episode,
                     wake,
                     state,
                     delivered,
                     repeat,
                     sent_at,
                     possible
                   ] ->
      %{
        id: id,
        holder: holder,
        item: item,
        owner: owner,
        since: since,
        episode: episode,
        wake: wake,
        state: state,
        delivered: delivered,
        repeat: repeat,
        sent_at: sent_at,
        possible: possible == 1
      }
    end)
  end
end
