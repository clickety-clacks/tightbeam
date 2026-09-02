defmodule Tightbeam.JobTrace do
  @moduledoc "Pinned, read-only work-item trace artifact."

  alias Tightbeam.{CausalEvents, DB}

  defmodule MissingCancellationProvenance do
    @moduledoc false
    defexception [:wake_id]

    @impl true
    def message(%__MODULE__{wake_id: wake_id}),
      do: "wake #{wake_id} is canceled without required typed cancellation provenance"
  end

  # Every type needs an explicit rank — the sorter uses Map.fetch!/2, so an
  # unranked type raises rather than sorting arbitrarily. The v2 types are
  # INSERTED; the relative order of the v1 types is unchanged.
  @type_rank %{
    "turn_start" => 0,
    "wake_scheduled" => 1,
    "wake_fired" => 2,
    "wake_canceled" => 3,
    "decision_request" => 4,
    "causal_event" => 5,
    "effort_generation" => 6,
    "attest" => 7,
    "completion_escalation" => 8,
    "completion_escalation_event" => 9,
    "turn_end" => 10
  }

  @spec build(DB.server(), map()) :: map()
  def build(db, item) do
    assignments = assignments(db, item.id)
    assignment_ids = Enum.map(assignments, & &1.id)
    {completion_entries, completion_ids} = completion_entries(db, item.id, assignment_ids)

    %{
      workItem: %{
        id: item.id,
        ownerUserId: item.ownerUserId,
        state: item.state,
        failReason: item.failReason,
        title: item.title
      },
      assignments: assignments,
      timeline:
        (turn_entries(db, item.id) ++
           attest_entries(db, assignment_ids) ++
           wake_entries(db, item.id, assignment_ids) ++
           decision_entries(db, assignment_ids) ++
           effort_entries(db, assignment_ids) ++
           causal_entries(db, item.id, assignment_ids) ++
           completion_entries ++
           completion_event_entries(db, completion_ids))
        |> Enum.sort_by(fn entry ->
          {entry.at, Map.fetch!(@type_rank, entry.type), entry.id}
        end)
    }
  end

  defp completion_entries(db, work_item_id, assignment_ids) do
    {assignment_filter, params} =
      case assignment_ids do
        [] ->
          {"0", [work_item_id]}

        ids ->
          clause =
            ids
            |> Enum.with_index(2)
            |> Enum.map_join(", ", fn {_id, index} -> "?#{index}" end)

          {"assignmentId IN (#{clause})", [work_item_id | ids]}
      end

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, workItemId, causeKind, causeId, closingAttestId,
               revocationId, outcome, childSessionKey, causeBySession, causeByUser,
               status, currentRecipientSessionKey, currentRecipientUserId,
               recipientGeneration, recipientReissueCount, recipientReissueLimit,
               decision, actedBySession, actedByUser, supersededReason,
               supersededByAssignmentId, createdAt, actedAt, supersededAt
        FROM completion_escalations
        WHERE workItemId=?1 OR #{assignment_filter}
        ORDER BY createdAt,id
        """,
        params
      )

    entries =
      Enum.flat_map(rows, fn [
                               id,
                               assignment_id,
                               item_id,
                               cause_kind,
                               cause_id,
                               attest_id,
                               revocation_id,
                               outcome,
                               child,
                               cause_session,
                               cause_user,
                               status,
                               recipient_session,
                               recipient_user,
                               recipient_generation,
                               recipient_reissue_count,
                               recipient_reissue_limit,
                               decision,
                               acted_session,
                               acted_user,
                               superseded_reason,
                               superseded_assignment,
                               created_at,
                               acted_at,
                               superseded_at
                             ] ->
        base = %{
          type: "completion_escalation",
          completionId: id,
          assignmentId: assignment_id,
          workItemId: item_id,
          causeKind: cause_kind,
          causeId: cause_id,
          closingAttestId: attest_id,
          revocationId: revocation_id,
          outcome: outcome,
          childSessionKey: child,
          causePrincipal: acting_principal(cause_session, cause_user),
          currentStatus: status,
          currentRecipient: acting_principal(recipient_session, recipient_user),
          recipientGeneration: recipient_generation,
          recipientReissueCount: recipient_reissue_count,
          recipientReissueLimit: recipient_reissue_limit,
          decision: decision,
          actingPrincipal: acting_principal(acted_session, acted_user),
          supersededReason: superseded_reason,
          supersededByAssignmentId: superseded_assignment
        }

        opened = Map.merge(base, %{id: "#{id}:opened", at: created_at, phase: "opened"})

        terminal =
          case status do
            "superseded" ->
              [Map.merge(base, %{id: "#{id}:superseded", at: superseded_at, phase: "superseded"})]

            terminal when terminal in ["acknowledged", "retained_root"] ->
              [Map.merge(base, %{id: "#{id}:#{terminal}", at: acted_at, phase: terminal})]

            _ ->
              []
          end

        [opened | terminal]
      end)

    {entries, Enum.map(rows, &hd/1)}
  end

  defp completion_event_entries(_db, []), do: []

  defp completion_event_entries(db, completion_ids) do
    {clause, params} = in_clause(completion_ids)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id,ts,subject,kind,detail
        FROM lifecycle_events
        WHERE subject IN (#{clause})
          AND kind IN ('completion_escalation_opened','completion_escalation_reissued',
                       'completion_escalation_superseded','completion_escalation_acknowledged',
                       'completion_escalation_undeliverable',
                       'completion_escalation_cross_owner_lineage',
                       'completion_escalation_state_inconsistent',
                       'completion_escalation_retire_deferred',
                       'completion_escalation_park_failed')
        """,
        params
      )

    Enum.map(rows, fn [id, at, completion_id, kind, detail] ->
      %{
        id: "le:#{id}",
        at: at,
        type: "completion_escalation_event",
        completionId: completion_id,
        kind: kind,
        detail: detail
      }
    end)
  end

  defp acting_principal(session, nil) when is_binary(session), do: "session:#{session}"
  defp acting_principal(nil, user) when is_binary(user), do: "user:#{user}"
  defp acting_principal(nil, nil), do: nil

  # causal_events carry their own monotonic seq; `seqTiebreak` exposes it so two
  # events sharing a millisecond still read in commit order.
  defp causal_entries(db, work_item_id, assignment_ids) do
    db
    |> CausalEvents.for_job(work_item_id, assignment_ids)
    |> Enum.map(fn event ->
      %{
        at: event.at,
        seqTiebreak: event.seq,
        type: "causal_event",
        id: "ce:#{event.seq}",
        kind: event.kind,
        assignmentId: event.assignment_id,
        jobRef: event.job_ref,
        sessionKey: event.session_key,
        detail: event.detail
      }
    end)
  end

  defp assignments(db, work_item_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        WITH RECURSIVE members(id) AS (
          SELECT id FROM assignments WHERE workItemId = ?1
          UNION
          SELECT review.id
          FROM assignments AS review
          JOIN members AS target ON review.reviewsAssignmentId = target.id
        )
        SELECT a.id, a.holderKey, a.openedByUser, a.openedBySession, a.state,
               a.reviewsAssignmentId
        FROM assignments AS a
        JOIN members AS m ON m.id = a.id
        ORDER BY a.id ASC
        """,
        [work_item_id]
      )

    Enum.map(rows, fn [id, holder, opened_user, opened_session, state, reviews] ->
      %{
        id: id,
        holderKey: holder,
        openerRef: opener_ref(opened_user, opened_session),
        state: state,
        files: assignment_files(db, id),
        reviewsAssignmentId: reviews
      }
    end)
  end

  defp assignment_files(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT path FROM assignment_files WHERE assignmentId = ?1 ORDER BY path ASC",
        [assignment_id]
      )

    Enum.map(rows, &hd/1)
  end

  defp opener_ref(user, nil), do: "user:" <> user
  defp opener_ref(nil, session), do: "session:" <> session

  defp turn_entries(db, work_item_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT seq, assignmentId, jobRef, status, model, thinkingLevel, modelContext,
               harness, createdAt, endedAt
        FROM turns
        WHERE jobRef = ?1
        ORDER BY seq ASC
        """,
        [work_item_id]
      )

    Enum.flat_map(rows, fn [
                             seq,
                             assignment_id,
                             job_ref,
                             status,
                             model,
                             effort,
                             model_context,
                             harness,
                             created,
                             ended
                           ] ->
      base = %{
        id: seq,
        assignmentId: assignment_id,
        jobRef: job_ref,
        status: status,
        model: model,
        context: model_context,
        effort: effort,
        harness: harness
      }

      [Map.merge(base, %{type: "turn_start", at: created})] ++
        if ended, do: [Map.merge(base, %{type: "turn_end", at: ended})], else: []
    end)
  end

  defp attest_entries(_db, []), do: []

  defp attest_entries(db, assignment_ids) do
    {clause, params} = in_clause(assignment_ids)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, kind, verdictKind, commitRefs, ts
        FROM attests
        WHERE assignmentId IN (#{clause})
        """,
        params
      )

    Enum.map(rows, fn [id, assignment_id, kind, verdict, commit_refs, at] ->
      %{
        at: at,
        type: "attest",
        id: id,
        assignmentId: assignment_id,
        kind: kind,
        verdict: verdict,
        commitRefs: decode(commit_refs)
      }
    end)
  end

  defp wake_entries(db, work_item_id, assignment_ids) do
    item_wakes =
      wake_rows(
        db,
        """
        SELECT w.wakeId, NULL, w.createdAt, w.dueAt, w.firedAt, w.firedBy,
               matched_fact_at, w.canceledAt, w.rid, w.origin,
               c.canceledAt, c.requesterKind, c.requesterId, c.reasonKind,
               c.causalSourceKind, c.causalSourceId, c.outcomeKind,
               c.replacementWakeId, c.dispositionKind, c.dispositionId,
               c.primaryWorkKind, c.primaryWorkId, c.workImpactKind,
               c.livenessTriggerKind, c.livenessTriggerId, c.actionNeeded,
               (SELECT activatedAt FROM supervision_liveness_epoch WHERE id=0)
        FROM (
          SELECT w.*, w.rowid AS rid,
                 CASE WHEN w.firedBy = 'condition' THEN (
                   SELECT f.ts FROM condition_facts AS f
                   WHERE f.id > w.conditionAfterId
                     AND f.kind = w.conditionKind
                     AND (w.conditionScope IS NULL OR f.scope = w.conditionScope)
                   ORDER BY f.id ASC LIMIT 1
                 ) END AS matched_fact_at
          FROM wakes AS w
        ) AS w
        LEFT JOIN wake_cancellations AS c ON c.wakeId=w.wakeId
        WHERE w.work_item_id = ?1
        """,
        [work_item_id]
      )

    assignment_wakes =
      case assignment_ids do
        [] ->
          []

        ids ->
          {clause, params} = in_clause(ids)

          wake_rows(
            db,
            """
            WITH links(wakeId, assignmentId) AS (
              SELECT wakeId, assignmentId FROM effort_checkin_generations
              WHERE assignmentId IN (#{clause})
              UNION
              SELECT deadlineWakeId, assignmentId FROM decision_requests
              WHERE assignmentId IN (#{clause})
              UNION
              SELECT wakeId, assignmentId FROM wakes
              WHERE assignmentId IN (#{clause})
            )
            SELECT w.wakeId, links.assignmentId, w.createdAt, w.dueAt, w.firedAt, w.firedBy,
                   CASE WHEN w.firedBy = 'condition' THEN (
                     SELECT f.ts FROM condition_facts AS f
                     WHERE f.id > w.conditionAfterId
                       AND f.kind = w.conditionKind
                       AND (w.conditionScope IS NULL OR f.scope = w.conditionScope)
                     ORDER BY f.id ASC LIMIT 1
                   ) END,
                   w.canceledAt, w.rowid, w.origin,
                   c.canceledAt, c.requesterKind, c.requesterId, c.reasonKind,
                   c.causalSourceKind, c.causalSourceId, c.outcomeKind,
                   c.replacementWakeId, c.dispositionKind, c.dispositionId,
                   c.primaryWorkKind, c.primaryWorkId, c.workImpactKind,
                   c.livenessTriggerKind, c.livenessTriggerId, c.actionNeeded,
                   (SELECT activatedAt FROM supervision_liveness_epoch WHERE id=0)
            FROM wakes AS w
            JOIN links ON links.wakeId = w.wakeId
            LEFT JOIN wake_cancellations AS c ON c.wakeId=w.wakeId
            """,
            params
          )
      end

    {completion_filter, completion_params} =
      case assignment_ids do
        [] ->
          {"ce.workItemId=?1", [work_item_id]}

        ids ->
          clause =
            ids
            |> Enum.with_index(2)
            |> Enum.map_join(", ", fn {_id, index} -> "?#{index}" end)

          {"(ce.workItemId=?1 OR ce.assignmentId IN (#{clause}))", [work_item_id | ids]}
      end

    completion_wakes =
      wake_rows(
        db,
        """
        SELECT w.wakeId, ce.assignmentId, w.createdAt, w.dueAt, w.firedAt, w.firedBy,
               CASE WHEN w.firedBy = 'condition' THEN (
                 SELECT f.ts FROM condition_facts AS f
                 WHERE f.id > w.conditionAfterId
                   AND f.kind = w.conditionKind
                   AND (w.conditionScope IS NULL OR f.scope = w.conditionScope)
                 ORDER BY f.id ASC LIMIT 1
               ) END,
               w.canceledAt, w.rowid, w.origin,
               c.canceledAt, c.requesterKind, c.requesterId, c.reasonKind,
               c.causalSourceKind, c.causalSourceId, c.outcomeKind,
               c.replacementWakeId, c.dispositionKind, c.dispositionId,
               c.primaryWorkKind, c.primaryWorkId, c.workImpactKind,
               c.livenessTriggerKind, c.livenessTriggerId, c.actionNeeded,
               (SELECT activatedAt FROM supervision_liveness_epoch WHERE id=0)
        FROM completion_escalation_wakes AS cew
        JOIN completion_escalations AS ce ON ce.id=cew.completionId
        JOIN wakes AS w ON w.wakeId=cew.wakeId
        LEFT JOIN wake_cancellations AS c ON c.wakeId=w.wakeId
        WHERE #{completion_filter}
        """,
        completion_params
      )

    (item_wakes ++ assignment_wakes ++ completion_wakes)
    |> Map.new(fn {wake_id, entries} -> {wake_id, entries} end)
    |> Map.values()
    |> List.flatten()
  end

  defp wake_rows(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)

    Enum.map(rows, fn [
                        id,
                        assignment_id,
                        created,
                        due,
                        fired,
                        fired_by,
                        matched_fact_at,
                        canceled,
                        rid,
                        scheduling_origin,
                        carrier_canceled_at,
                        requester_kind,
                        requester_id,
                        reason_kind,
                        source_kind,
                        source_id,
                        outcome_kind,
                        replacement_wake_id,
                        disposition_kind,
                        disposition_id,
                        primary_work_kind,
                        primary_work_id,
                        work_impact_kind,
                        liveness_trigger_kind,
                        liveness_trigger_id,
                        action_needed,
                        activated_at
                      ] ->
      scheduled = %{
        at: created,
        type: "wake_scheduled",
        id: id,
        assignmentId: assignment_id,
        dueAt: due
      }

      fired_entry =
        if fired do
          [
            %{
              at: fired,
              type: "wake_fired",
              id: id,
              assignmentId: assignment_id,
              firedBy: fired_by,
              matchedFactAt: matched_fact_at
            }
          ]
        else
          []
        end

      canceled_entry =
        if canceled do
          projection =
            cancellation_projection(
              id,
              canceled,
              scheduling_origin,
              carrier_canceled_at,
              requester_kind,
              requester_id,
              reason_kind,
              source_kind,
              source_id,
              outcome_kind,
              replacement_wake_id,
              disposition_kind,
              disposition_id,
              primary_work_kind,
              primary_work_id,
              work_impact_kind,
              liveness_trigger_kind,
              liveness_trigger_id,
              action_needed,
              activated_at
            )

          [
            Map.merge(projection, %{
              at: canceled,
              seqTiebreak: rid,
              type: "wake_canceled",
              id: id,
              assignmentId: assignment_id,
              reason: nil
            })
          ]
        else
          []
        end

      {id, [scheduled] ++ fired_entry ++ canceled_entry}
    end)
  end

  defp cancellation_projection(
         _wake_id,
         canceled_at,
         scheduling_origin,
         canceled_at,
         requester_kind,
         requester_id,
         reason_kind,
         source_kind,
         source_id,
         outcome_kind,
         replacement_wake_id,
         disposition_kind,
         disposition_id,
         primary_work_kind,
         primary_work_id,
         work_impact_kind,
         liveness_trigger_kind,
         liveness_trigger_id,
         action_needed,
         _activated_at
       )
       when is_integer(canceled_at) do
    %{
      provenanceStatus: "proven",
      schedulingOrigin: scheduling_origin,
      requesterKind: requester_kind,
      requesterId: requester_id,
      reasonKind: reason_kind,
      causalSourceKind: source_kind,
      causalSourceId: source_id,
      outcomeKind: outcome_kind,
      replacementWakeId: replacement_wake_id,
      dispositionKind: disposition_kind,
      dispositionId: disposition_id,
      primaryWorkKind: primary_work_kind,
      primaryWorkId: primary_work_id,
      workImpactKind: work_impact_kind,
      livenessTriggerKind: liveness_trigger_kind,
      livenessTriggerId: liveness_trigger_id,
      actionNeeded: action_needed == 1
    }
  end

  defp cancellation_projection(
         _wake_id,
         canceled_at,
         scheduling_origin,
         nil,
         _requester_kind,
         _requester_id,
         _reason_kind,
         _source_kind,
         _source_id,
         _outcome_kind,
         _replacement_wake_id,
         _disposition_kind,
         _disposition_id,
         _primary_work_kind,
         _primary_work_id,
         _work_impact_kind,
         _liveness_trigger_kind,
         _liveness_trigger_id,
         _action_needed,
         activated_at
       )
       when is_integer(canceled_at) and is_integer(activated_at) and
              canceled_at <= activated_at do
    %{
      provenanceStatus: "not_proven",
      schedulingOrigin: scheduling_origin,
      requesterKind: nil,
      requesterId: nil,
      reasonKind: nil,
      causalSourceKind: nil,
      causalSourceId: nil,
      outcomeKind: nil,
      replacementWakeId: nil,
      dispositionKind: nil,
      dispositionId: nil,
      primaryWorkKind: nil,
      primaryWorkId: nil,
      workImpactKind: nil,
      livenessTriggerKind: nil,
      livenessTriggerId: nil,
      actionNeeded: nil
    }
  end

  defp cancellation_projection(
         wake_id,
         _canceled_at,
         _scheduling_origin,
         _carrier_canceled_at,
         _requester_kind,
         _requester_id,
         _reason_kind,
         _source_kind,
         _source_id,
         _outcome_kind,
         _replacement_wake_id,
         _disposition_kind,
         _disposition_id,
         _primary_work_kind,
         _primary_work_id,
         _work_impact_kind,
         _liveness_trigger_kind,
         _liveness_trigger_id,
         _action_needed,
         _activated_at
       ),
       do: raise(MissingCancellationProvenance, wake_id: wake_id)

  defp decision_entries(_db, []), do: []

  defp decision_entries(db, assignment_ids) do
    {clause, params} = in_clause(assignment_ids)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, status, decision, raisedAt
        FROM decision_requests
        WHERE assignmentId IN (#{clause})
        """,
        params
      )

    Enum.map(rows, fn [id, assignment_id, state, ruling, at] ->
      %{
        at: at,
        type: "decision_request",
        id: id,
        assignmentId: assignment_id,
        state: state,
        ruling: ruling
      }
    end)
  end

  defp effort_entries(_db, []), do: []

  defp effort_entries(db, assignment_ids) do
    {clause, params} = in_clause(assignment_ids)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT assignmentId, generation, state, evidence, armedAt
        FROM effort_checkin_generations
        WHERE assignmentId IN (#{clause})
        """,
        params
      )

    Enum.map(rows, fn [assignment_id, generation, state, evidence, at] ->
      %{
        at: at,
        type: "effort_generation",
        id: "gen:#{assignment_id}:#{generation}",
        assignmentId: assignment_id,
        state: state,
        evidence: decode(evidence)
      }
    end)
  end

  defp decode(nil), do: nil
  defp decode(encoded), do: JSON.decode!(encoded)

  defp in_clause(values) do
    placeholders =
      values
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_value, index} -> "?#{index}" end)

    {placeholders, values}
  end
end
