defmodule Tightbeam.NoticeAuthority do
  @moduledoc false
  alias Tightbeam.{DB, NoticeSubmission}
  alias Tightbeam.DB.Txn

  # Discovery only, never authority: callers use this to find a domain row
  # before resolve! qualifies every edge. Ordinary retries need no delegation
  # when they have no controller/decision/bubble authority to carry.
  def candidate_root(db, wake_id) do
    case query(db, "SELECT rootWakeId FROM wake_retry_attempts WHERE wakeId=?1", [wake_id]) do
      [] -> wake_id
      [[root]] -> root
    end
  end

  # Existing non-prewrite retries retain their original delivery semantics;
  # they gain no transfer/decision authority from this new resolver. A proved
  # prewrite edge uses the strict resolver, never an error-swallowing fallback.
  def for_delivery!(db, wake_id) do
    if prewrite_edge?(db, wake_id),
      do: resolve!(db, wake_id),
      else: %{root_wake_id: wake_id, root_turn_seq: nil}
  end

  defp prewrite_edge?(db, wake_id) do
    case query(
           db,
           """
           SELECT e.detail FROM wake_retry_attempts r
           JOIN wake_retry_attempts p ON p.wakeId=r.predecessorWakeId
           JOIN turn_lifecycle_events e ON e.turnSeq=p.sourceTurnSeq AND e.kind='terminal_committed'
           WHERE r.wakeId=?1 AND r.attempt>0
           """,
           [wake_id]
         ) do
      [[detail]] ->
        case JSON.decode(detail) do
          {:ok, %{"prewrite" => evidence}} -> NoticeSubmission.valid_evidence?(evidence)
          _ -> false
        end

      _ ->
        false
    end
  end

  # No authority is inferred from a wr_ name, prompt text or failure string.
  # Every delegation edge must be the deterministic successor of an actual
  # leased, terminal, explicitly NOT-DISPATCHED delivery of its predecessor.
  def resolve!(db, wake_id), do: resolve!(db, wake_id, MapSet.new(), nil)

  defp resolve!(db, wake_id, seen, expected_root) do
    if MapSet.member?(seen, wake_id), do: refuse!(:cyclic_retry_authority)
    seen = MapSet.put(seen, wake_id)

    case query(
           db,
           """
           SELECT rootWakeId,predecessorWakeId,attempt FROM wake_retry_attempts WHERE wakeId=?1
           """,
           [wake_id]
         ) do
      [] ->
        if expected_root not in [nil, wake_id], do: refuse!(:missing_retry_root)
        %{root_wake_id: wake_id, root_turn_seq: nil}

      [[root, nil, 0]] when root == wake_id ->
        if expected_root not in [nil, root], do: refuse!(:conflicting_retry_root)
        %{root_wake_id: root, root_turn_seq: nil}

      [[root, predecessor, attempt]] when is_binary(predecessor) and attempt > 0 ->
        digest = :crypto.hash(:sha256, "#{root}:#{attempt}")

        if wake_id != "wr_" <> Base.encode16(digest, case: :lower) or
             expected_root not in [nil, root],
           do: refuse!(:conflicting_retry_identity)

        previous =
          query(
            db,
            """
            SELECT p.sourceTurnSeq,c.ownerLease,e.detail
            FROM wake_retry_attempts p JOIN turns t ON t.seq=p.sourceTurnSeq
            JOIN turn_lifecycle_events c ON c.turnSeq=t.seq AND c.kind='claimed'
            JOIN turn_lifecycle_events e ON e.turnSeq=t.seq AND e.kind='terminal_committed'
            WHERE p.wakeId=?1 AND p.rootWakeId=?2 AND p.attempt=?3
              AND p.retryWakeId=?4 AND p.outcome='failed' AND t.status='failed'
              AND e.outcome='failed' AND e.ownerLease=c.ownerLease
              AND c.ownerLease IS NOT NULL AND length(c.ownerLease)>0
              AND NOT EXISTS (SELECT 1 FROM turn_lifecycle_events d
                WHERE d.turnSeq=t.seq AND d.kind='prompt_dispatched')
              AND EXISTS (SELECT 1 FROM (SELECT wakeId AS sourceWakeId,deliveredTurnSeq AS turnSeq,assignmentId FROM wakes WHERE deliveredTurnSeq IS NOT NULL) delivery
                WHERE delivery.sourceWakeId=p.wakeId AND delivery.turnSeq=t.seq)
            """,
            [predecessor, root, attempt - 1, wake_id]
          )

        seq =
          case previous do
            [[seq, _lease, detail]] ->
              with {:ok, %{"prewrite" => evidence}} <- JSON.decode(detail),
                   true <- NoticeSubmission.valid_evidence?(evidence) do
                seq
              else
                _ -> refuse!(:unproven_prewrite_delegation)
              end

            _ ->
              refuse!(:unproven_prewrite_delegation)
          end

        # Editable prompt, priority and attachments do not define authority.
        # Target/provenance/condition/disposer references must still match the
        # actual predecessor; changing these cannot inherit its authority.
        unless query(
                 db,
                 """
                 SELECT 1 FROM wakes old JOIN wakes next ON next.wakeId=?2
                 WHERE old.wakeId=?1 AND old.state='fired' AND old.consumer='prompt' AND old.digest=0
                   AND next.consumer=old.consumer AND next.digest=old.digest
                   AND next.sessionKey IS old.sessionKey AND next.targetRole IS old.targetRole
                   AND next.origin IS old.origin AND next.assignmentId IS old.assignmentId
                   AND next.work_item_id IS old.work_item_id AND next.targetGate IS old.targetGate
                   AND next.deliveryRule IS old.deliveryRule AND next.summon IS old.summon
                   AND next.rumination IS old.rumination AND next.originatingTurnSeq IS old.originatingTurnSeq
                   AND next.ownerUserId IS old.ownerUserId AND next.creatorSessionKey IS old.creatorSessionKey
                   AND next.reresolve IS old.reresolve AND next.reresolveSeed IS old.reresolveSeed
                   AND next.reresolveRung IS old.reresolveRung AND next.obligationRef IS old.obligationRef
                   AND next.conditionKind IS old.conditionKind AND next.conditionScope IS old.conditionScope
                   AND next.conditionAfterId IS old.conditionAfterId
                   AND next.waitMode IS old.waitMode AND next.predicate IS old.predicate
                   AND next.resolverKind IS old.resolverKind AND next.resolverId IS old.resolverId
                   AND next.resolverHolder IS old.resolverHolder AND next.resolverAddressee IS old.resolverAddressee
                   AND next.necessity IS old.necessity AND next.verificationAssignmentId IS old.verificationAssignmentId
                   AND next.verificationHolderKey IS old.verificationHolderKey
                   AND next.verificationAttestId IS old.verificationAttestId
                   AND next.verificationNoticeWakeId IS old.verificationNoticeWakeId
                   AND next.selectedPolicyName IS old.selectedPolicyName
                   AND next.recognitionEvidence IS old.recognitionEvidence
                   AND next.sourceVisibilityScope IS old.sourceVisibilityScope
                   AND next.sourceAddress IS old.sourceAddress
                 """,
                 [predecessor, wake_id]
               ) == [[1]], do: refuse!(:changed_retry_authority)

        original = resolve!(db, predecessor, seen, root)
        %{original | root_turn_seq: original.root_turn_seq || seq}

      _ ->
        refuse!(:invalid_retry_authority)
    end
  end

  # A terminal callback must not create a second climb/transfer for the same
  # explicitly unsubmitted delivery after its sources were restored atomically.
  # This never suppresses an unknown-effect failure or an unbound sibling.
  def restored_turn?(db, seq) do
    proved =
      case query(
             db,
             """
             SELECT e.detail FROM turns t JOIN turn_lifecycle_events e ON e.turnSeq=t.seq
             WHERE t.seq=?1 AND t.status='failed' AND e.kind='terminal_committed' AND e.outcome='failed'
             """,
             [seq]
           ) do
        [[detail]] ->
          case JSON.decode(detail) do
            {:ok, %{"prewrite" => evidence}} -> NoticeSubmission.valid_evidence?(evidence)
            _ -> false
          end

        _ ->
          false
      end

    if proved, do: all_sources_restored?(db, seq), else: false
  end

  defp all_sources_restored?(db, seq) do
    rows =
      query(
        db,
        """
        SELECT source.wakeId,r.retryWakeId,r.sourceTurnSeq
        FROM (SELECT wakeId AS sourceWakeId,deliveredTurnSeq AS turnSeq,assignmentId FROM wakes WHERE deliveredTurnSeq IS NOT NULL) d
        JOIN wakes source ON source.wakeId=d.sourceWakeId AND source.consumer='prompt' AND source.digest=0
        LEFT JOIN wake_retry_attempts r ON r.wakeId=source.wakeId
        WHERE d.turnSeq=?1
        """,
        [seq]
      )

    rows != [] and
      Enum.all?(rows, fn
        [_source, next, ^seq] when is_binary(next) ->
          resolve!(db, next)
          true

        _ ->
          false
      end)
  end

  # Resolve the live leaf without mutating the original decision or historical
  # delivery. Release/disposition cancels that leaf, not the fired root.
  def current!(db, root) do
    %{root_wake_id: ^root} = resolve!(db, root)
    current!(db, root, MapSet.new())
  end

  defp current!(db, id, seen) do
    if MapSet.member?(seen, id), do: refuse!(:cyclic_retry_authority)

    case query(db, "SELECT retryWakeId FROM wake_retry_attempts WHERE wakeId=?1", [id]) do
      [] ->
        id

      [[nil]] ->
        id

      [[next]] when is_binary(next) ->
        if prewrite_edge?(db, next) do
          resolve!(db, next)
          current!(db, next, MapSet.put(seen, id))
        else
          id
        end

      _ ->
        refuse!(:conflicting_retry_authority)
    end
  end

  defp query(%Txn{} = txn, sql, args), do: Txn.q(txn, sql, args)

  defp query(db, sql, args) do
    {:ok, rows} = DB.query(db, sql, args)
    rows
  end

  defp refuse!(reason),
    do:
      raise(DB.Error,
        message: "notice_retry_authority_refused: #{reason}"
      )
end
