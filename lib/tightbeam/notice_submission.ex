defmodule Tightbeam.NoticeSubmission do
  @moduledoc false

  alias Tightbeam.{Assignments, DB, EventLog, NoticeAuthority, NoticeBatcher,
    QueuedMessageSuppression, ReminderDelivery, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  # This is evidence about our own prewrite boundary, not a receiver capacity
  # estimate. DOWN, timeout, interruption and provider errors are not evidence.
  def prewrite_evidence(:prompt, {:acp_request_not_dispatched,
        {:transport_capacity_exceeded, bytes, limit}})
      when is_integer(bytes) and is_integer(limit) and limit > 0 and bytes > limit,
      do: %{"disposition" => "not_dispatched", "reason" => "transport_capacity_exceeded",
        "requestBytes" => bytes, "limitBytes" => limit}

  def prewrite_evidence(:prompt, {:acp_request_not_dispatched,
        {:submission_text_limit_exceeded, chars, limit}})
      when is_integer(chars) and limit == 1_048_576 and chars > limit,
      do: %{"disposition" => "not_dispatched", "reason" => "submission_text_limit_exceeded",
        "textChars" => chars, "limitChars" => limit}

  def prewrite_evidence(_, _), do: nil

  def valid_evidence?(%{"disposition" => "not_dispatched",
        "reason" => "transport_capacity_exceeded", "requestBytes" => bytes,
        "limitBytes" => limit} = evidence),
      do: map_size(evidence) == 4 and is_integer(bytes) and is_integer(limit) and
        limit > 0 and bytes > limit

  def valid_evidence?(%{"disposition" => "not_dispatched",
        "reason" => "submission_text_limit_exceeded", "textChars" => chars,
        "limitChars" => limit} = evidence),
      do: map_size(evidence) == 4 and is_integer(chars) and limit == 1_048_576 and chars > limit

  def valid_evidence?(_), do: false

  # Used before the terminal UPDATE and again before successor insertion. A
  # legacy turn, stale lease or any recorded port write must remain held.
  def assert_owner_in_txn!(%Txn{} = txn, seq, lease, evidence, status) do
    unless valid_evidence?(evidence) and is_binary(lease) and byte_size(lease) > 0 and
        Txn.q(txn, """
        SELECT 1 FROM turns t JOIN turn_lifecycle_events c ON c.turnSeq=t.seq
        WHERE t.seq=?1 AND t.status=?2 AND c.kind='claimed' AND c.ownerLease=?3
          AND NOT EXISTS (SELECT 1 FROM turn_lifecycle_events d
            WHERE d.turnSeq=t.seq AND d.kind='prompt_dispatched')
        """, [seq, status, lease]) == [[1]] do
      raise DB.Error, message: "notice_prewrite_restoration_refused: stale lease or uncertain dispatch"
    end
    :ok
  end

  # The caller has already won the lease-fenced failed terminal CAS. The typed
  # terminal evidence and all root successors commit in that same transaction.
  def assert_restoration_in_txn!(%Txn{} = txn, turn, evidence) do
    :ok = assert_owner_in_txn!(txn, turn.seq, turn.owner_lease, evidence, "failed")

    case Txn.q(txn, """
           SELECT detail FROM turn_lifecycle_events
           WHERE turnSeq=?1 AND kind='terminal_committed' AND outcome='failed'
             AND ownerLease=?2
           """, [turn.seq, turn.owner_lease]) do
      [[detail]] ->
        unless JSON.decode!(detail)["prewrite"] == evidence,
          do: raise(DB.Error, message: "notice_prewrite_restoration_refused: missing terminal evidence")

      _ ->
        raise DB.Error, message: "notice_prewrite_restoration_refused: missing terminal evidence"
    end
    :ok
  end

  def restore_in_txn(%Txn{} = txn, turn, evidence) do
    :ok = assert_restoration_in_txn!(txn, turn, evidence)

    sources =
      if is_binary(turn.wake_id),
        do: NoticeBatcher.carrier_source_ids_in_txn(txn, turn.wake_id),
        else: []

    sources =
      if sources == [] do
        case Wakes.get_in_txn(txn, turn.wake_id) do
          %{consumer: "prompt", digest: false} -> [turn.wake_id]
          nil -> []
          _ -> raise DB.Error, message: "notice_prewrite_restoration_refused: carrier has no sources"
        end
      else
        unless Txn.q(txn, """
                 SELECT 1 FROM notice_batches b JOIN turns t ON t.wakeId=b.deliveryWakeId
                 WHERE t.seq=?1 AND b.state='delivered' AND b.envelope=t.prompt
                 """, [turn.seq]) == [[1]],
          do: raise(DB.Error, message: "notice_prewrite_restoration_refused: inconsistent carrier")
        sources
      end

    Enum.map(sources, &restore_source_in_txn(txn, &1, turn, evidence))
  end

  defp restore_source_in_txn(txn, source_id, turn, evidence) do
    seq = turn.seq
    %{consumer: "prompt", digest: false, state: "fired"} = source = Wakes.get_in_txn(txn, source_id)
    {root, attempt, previous_seq, successor} =
      case Txn.q(txn, """
             SELECT rootWakeId,attempt,sourceTurnSeq,retryWakeId FROM wake_retry_attempts
             WHERE wakeId=?1
             """, [source_id]) do
        [] -> {source_id, 0, nil, nil}
        [[root, attempt, previous_seq, successor]] -> {root, attempt, previous_seq, successor}
      end

    next_attempt = attempt + 1
    digest = :crypto.hash(:sha256, "#{root}:#{next_attempt}")
    successor_id = "wr_" <> Base.encode16(digest, case: :lower)

    cond do
      is_binary(successor) ->
        unless successor == successor_id and previous_seq == seq and
            Txn.q(txn, """
            SELECT 1 FROM wake_retry_attempts r JOIN wakes w ON w.wakeId=r.wakeId
            WHERE r.wakeId=?1 AND r.rootWakeId=?2 AND r.predecessorWakeId=?3 AND r.attempt=?4
            """, [successor_id, root, source_id, next_attempt]) == [[1]],
          do: raise(DB.Error, message: "notice_prewrite_restoration_refused: conflicting successor")

      previous_seq not in [nil, seq] ->
        raise DB.Error, message: "notice_prewrite_restoration_refused: conflicting invocation"

      true ->
        observed_at = System.system_time(:millisecond)
        due_at = observed_at + min(1_000 * Integer.pow(2, min(attempt, 10)), 60_000)

        Txn.q(txn, """
        INSERT INTO wake_retry_attempts
          (wakeId,rootWakeId,predecessorWakeId,attempt,sourceTurnSeq,outcome,retryWakeId,observedAt)
        VALUES (?1,?2,NULL,?3,?4,'failed',NULL,?5)
        ON CONFLICT(wakeId) DO UPDATE SET sourceTurnSeq=?4,outcome='failed',observedAt=?5
          WHERE wake_retry_attempts.retryWakeId IS NULL
            AND wake_retry_attempts.outcome IN ('pending','failed')
            AND (wake_retry_attempts.sourceTurnSeq IS NULL OR wake_retry_attempts.sourceTurnSeq=?4)
        """, [source_id, root, attempt, seq, observed_at])
        unless Txn.changes(txn) == 1,
          do: raise(DB.Error, message: "notice_prewrite_restoration_refused: retry already settled")

        copy_source_in_txn(txn, source_id, successor_id, due_at)
        QueuedMessageSuppression.copy_replacement_request_in_txn(txn, source_id, successor_id)
        case ReminderDelivery.rebind_wake_in_txn(txn, source.assignment_id, seq, source_id, successor_id) do
          result when result in [:recorded, :no_claim] -> :ok
          _ -> raise DB.Error, message: "notice_prewrite_restoration_refused: reminder claim changed"
        end

        Txn.q(txn, """
        INSERT INTO wake_retry_attempts
          (wakeId,rootWakeId,predecessorWakeId,attempt,sourceTurnSeq,outcome,retryWakeId,observedAt)
        VALUES (?1,?2,?3,?4,NULL,'pending',NULL,?5)
        """, [successor_id, root, source_id, next_attempt, observed_at])
        Txn.q(txn, "UPDATE wake_retry_attempts SET retryWakeId=?2 WHERE wakeId=?1",
          [source_id, successor_id])
        NoticeAuthority.resolve!(txn, successor_id)
        :ok = Assignments.assert_retry_decision_in_txn!(txn, successor_id)
        :ok = Tightbeam.Productions.Bubble.assert_retry_disposer_in_txn!(txn, successor_id)
        # Bind only after the existing deterministic root lineage is present,
        # inside the same lease-fenced terminal transaction. A prod reuses its
        # charged generation; an escalation delegates its original transfer
        # through the same proved lineage. Stale authority refuses the entire
        # transaction rather than partially restoring siblings.
        :ok = Supervision.rebind_not_dispatched_source_in_txn(
          txn, source_id, successor_id, turn, evidence)
        Wakes.publish_change_in_txn(txn, "wake.scheduled", successor_id)
        EventLog.lifecycle_in_txn(txn, "notice_prewrite_source_restored", root,
          "sourceTurnSeq=#{seq} predecessor=#{source_id} successor=#{successor_id} cause=not-dispatched")
    end

    successor_id
  end

  # Preserve authored/raw values and recognition, not the rendered envelope.
  # Client dedupe authority remains on the original row. Historical members,
  # controller charge and carrier history are never reset or moved.
  @source_columns ~w(sessionKey targetRole origin prompt consumer createdAt firedAt
    reresolve reresolveSeed reresolveRung conditionKind conditionScope conditionAfterId firedBy
    creatorSessionKey rumination work_item_id assignmentId targetGate class classElection
    deliveryRule digest summon ownerUserId obligationRef waitMode predicate resolverKind resolverId
    resolverHolder resolverAddressee necessity verificationAssignmentId verificationHolderKey
    selectedPolicyName verificationState verificationAttestId verificationNoticeWakeId
    originatingTurnSeq recognitionAt recognitionPath recognitionReason recognitionEvidence
    recognitionDisposition recognitionTransition sourceAttachments sourceVisibilityScope sourceAddress)

  defp copy_source_in_txn(txn, source, successor, due_at) do
    columns = Enum.join(@source_columns, ",")
    Txn.q(txn, """
    INSERT INTO wakes(wakeId,state,dueAt,#{columns})
    SELECT ?2,'pending',?3,#{columns} FROM wakes WHERE wakeId=?1
    """, [source, successor, due_at])
  end
end
