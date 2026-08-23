defmodule Tightbeam.Productions.CompletionEscalation do
  @moduledoc "The durable completion-notice and explicit session-disposition production."

  alias Tightbeam.{DB, EventLog, Org, Wakes}
  alias Tightbeam.DB.Txn

  @process_principal "process:tightbeam:completion-escalation"
  @deadline_consumer "completion_disposition_deadline"
  @default_deadline_ms 86_400_000

  @ddl """
  CREATE TABLE IF NOT EXISTS completion_escalations (
    id TEXT PRIMARY KEY,
    dedupeKey TEXT NOT NULL UNIQUE,
    assignmentId TEXT NOT NULL UNIQUE REFERENCES assignments(id),
    workItemId TEXT NULL REFERENCES work_items(id),
    childSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    remainingOpenAssignments INTEGER NOT NULL CHECK (remainingOpenAssignments >= 0),
    closingAttestId TEXT NOT NULL UNIQUE REFERENCES attests(id),
    outcome TEXT NOT NULL CHECK (outcome = 'completed'),
    causeBySession TEXT NOT NULL REFERENCES sessions(sessionKey),
    ownerUserId TEXT NOT NULL REFERENCES users(userId),
    rootMainHolder INTEGER NOT NULL CHECK (rootMainHolder IN (0,1)),
    immediateParentSessionKey TEXT NULL REFERENCES sessions(sessionKey),
    initialRecipientSessionKey TEXT NULL REFERENCES sessions(sessionKey),
    initialResolutionKind TEXT NOT NULL CHECK (
      initialResolutionKind IN ('lineage','main-fallback','main-unavailable')
    ),
    initialLineageRung INTEGER NULL CHECK (initialLineageRung IS NULL OR initialLineageRung >= 1),
    currentRecipientSessionKey TEXT NULL REFERENCES sessions(sessionKey),
    currentResolutionKind TEXT NOT NULL CHECK (
      currentResolutionKind IN ('lineage','main-fallback','main-unavailable')
    ),
    currentLineageRung INTEGER NULL CHECK (currentLineageRung IS NULL OR currentLineageRung >= 1),
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    currentNoticeWakeId TEXT NULL UNIQUE REFERENCES wakes(wakeId),
    deadlineWakeId TEXT NULL UNIQUE REFERENCES wakes(wakeId),
    actionDeadlineAt INTEGER NULL,
    status TEXT NOT NULL CHECK (
      status IN ('notice-only','open','acknowledged','retained_root','superseded')
    ),
    decision TEXT NULL CHECK (decision IN ('retain','park','retire')),
    actedBySession TEXT NULL REFERENCES sessions(sessionKey),
    actedByUser TEXT NULL REFERENCES users(userId),
    actedAt INTEGER NULL,
    supersededReason TEXT NULL CHECK (
      supersededReason IN ('new-assignment','child-retired')
    ),
    supersededByAssignmentId TEXT NULL REFERENCES assignments(id),
    supersededAt INTEGER NULL,
    createdAt INTEGER NOT NULL,
    CHECK (causeBySession = childSessionKey),
    CHECK (dedupeKey = 'completion:' || closingAttestId),
    CHECK (
      (initialResolutionKind = 'lineage' AND initialRecipientSessionKey IS NOT NULL AND initialLineageRung IS NOT NULL)
      OR
      (initialResolutionKind = 'main-fallback' AND initialRecipientSessionKey IS NOT NULL AND initialLineageRung IS NULL)
      OR
      (initialResolutionKind = 'main-unavailable' AND initialRecipientSessionKey IS NULL AND initialLineageRung IS NULL)
    ),
    CHECK (
      (currentResolutionKind = 'lineage' AND currentRecipientSessionKey IS NOT NULL AND currentLineageRung IS NOT NULL)
      OR
      (currentResolutionKind = 'main-fallback' AND currentRecipientSessionKey IS NOT NULL AND currentLineageRung IS NULL)
      OR
      (currentResolutionKind = 'main-unavailable' AND currentRecipientSessionKey IS NULL AND currentLineageRung IS NULL)
    ),
    CHECK (
      (currentResolutionKind = 'main-unavailable' AND currentNoticeWakeId IS NULL)
      OR
      (currentResolutionKind != 'main-unavailable' AND currentNoticeWakeId IS NOT NULL)
    ),
    CHECK (
      rootMainHolder = 0
      OR (
        initialResolutionKind = 'main-fallback'
        AND initialRecipientSessionKey = childSessionKey
        AND currentResolutionKind = 'main-fallback'
        AND currentRecipientSessionKey = childSessionKey
      )
    ),
    CHECK (
      status = 'notice-only'
        AND remainingOpenAssignments >= 1
        AND decision IS NULL AND actionDeadlineAt IS NULL AND deadlineWakeId IS NULL
        AND actedBySession IS NULL AND actedByUser IS NULL AND actedAt IS NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'open'
        AND remainingOpenAssignments = 0
        AND decision IS NULL AND actionDeadlineAt IS NOT NULL AND deadlineWakeId IS NOT NULL
        AND actedBySession IS NULL AND actedByUser IS NULL AND actedAt IS NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'acknowledged'
        AND rootMainHolder = 0
        AND remainingOpenAssignments = 0
        AND decision IS NOT NULL AND actionDeadlineAt IS NOT NULL AND deadlineWakeId IS NULL
        AND ((actedBySession IS NOT NULL) != (actedByUser IS NOT NULL)) AND actedAt IS NOT NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'retained_root'
        AND rootMainHolder = 1
        AND remainingOpenAssignments = 0
        AND decision = 'retain' AND actionDeadlineAt IS NOT NULL AND deadlineWakeId IS NULL
        AND ((actedBySession IS NOT NULL) != (actedByUser IS NOT NULL)) AND actedAt IS NOT NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'superseded'
        AND remainingOpenAssignments = 0
        AND decision IS NULL AND actionDeadlineAt IS NOT NULL AND deadlineWakeId IS NULL
        AND actedBySession IS NULL AND actedByUser IS NULL AND actedAt IS NULL AND supersededAt IS NOT NULL
        AND (
          (supersededReason = 'new-assignment' AND supersededByAssignmentId IS NOT NULL)
          OR
          (supersededReason = 'child-retired' AND supersededByAssignmentId IS NULL)
        )
    )
  );
  CREATE INDEX IF NOT EXISTS completion_escalations_child_status
    ON completion_escalations(childSessionKey, status);
  CREATE UNIQUE INDEX IF NOT EXISTS completion_escalations_one_open_child
    ON completion_escalations(childSessionKey) WHERE status = 'open';

  CREATE TABLE IF NOT EXISTS completion_escalation_wakes (
    wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
    completionId TEXT NOT NULL REFERENCES completion_escalations(id),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('notice','deadline')),
    UNIQUE (completionId, generation, kind)
  );
  CREATE INDEX IF NOT EXISTS completion_escalation_wakes_completion
    ON completion_escalation_wakes(completionId, generation, kind);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Create the completion record and its first durable wakes inside the close transaction."
  @spec open_in_txn(Txn.t(), map(), map()) :: map()
  def open_in_txn(%Txn{} = txn, assignment, attest) do
    child = assignment.holderKey

    [[owner, immediate_parent, built_in]] =
      Txn.q(
        txn,
        "SELECT ownerUserId, spawnedBy, isBuiltIn FROM sessions WHERE sessionKey=?1",
        [child]
      )

    [[remaining]] =
      Txn.q(txn, "SELECT count(*) FROM assignments WHERE holderKey=?1 AND state='open'", [
        child
      ])

    root_main = built_in == 1 and child == Org.personal_session_key(owner)
    {resolution, foreign_boundary} = resolve_recipient(txn, child, owner, root_main)
    now = now()
    completion_id = "cn_" <> Tightbeam.Id.uuid4()
    generation = 0
    action_needed = remaining == 0
    status = if(action_needed, do: "open", else: "notice-only")
    deadline_at = if(action_needed, do: now + deadline_ms())

    notice_id =
      schedule_notice(
        txn,
        completion_id,
        assignment,
        attest,
        immediate_parent,
        resolution,
        remaining,
        root_main,
        generation,
        now
      )

    deadline_id =
      if action_needed do
        id = wake_id(attest.id, "deadline", generation)

        Wakes.schedule_in_txn(txn, %{
          wake_id: id,
          session_key: child,
          origin: "process:tightbeam",
          prompt: nil,
          consumer: @deadline_consumer,
          due_at: deadline_at,
          assignment_id: nil,
          work_item_id: nil
        })

        id
      end

    Txn.q(
      txn,
      """
      INSERT INTO completion_escalations
        (id, dedupeKey, assignmentId, workItemId, childSessionKey,
         remainingOpenAssignments, closingAttestId, outcome, causeBySession,
         ownerUserId, rootMainHolder, immediateParentSessionKey,
         initialRecipientSessionKey, initialResolutionKind, initialLineageRung,
         currentRecipientSessionKey, currentResolutionKind, currentLineageRung,
         generation, currentNoticeWakeId, deadlineWakeId, actionDeadlineAt,
         status, createdAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'completed', ?5, ?8, ?9, ?10,
              ?11, ?12, ?13, ?11, ?12, ?13, 0, ?14, ?15, ?16, ?17, ?18)
      """,
      [
        completion_id,
        "completion:" <> attest.id,
        assignment.id,
        assignment.workItemId,
        child,
        remaining,
        attest.id,
        owner,
        if(root_main, do: 1, else: 0),
        immediate_parent,
        resolution.recipient,
        resolution.kind,
        resolution.rung,
        notice_id,
        deadline_id,
        deadline_at,
        status,
        now
      ]
    )

    if notice_id, do: insert_membership(txn, notice_id, completion_id, generation, "notice")
    if deadline_id, do: insert_membership(txn, deadline_id, completion_id, generation, "deadline")

    EventLog.lifecycle_in_txn(txn, "completion_escalation_opened", completion_id, nil)
    record_routing_events(txn, completion_id, resolution, foreign_boundary, generation)
    fetch_in_txn!(txn, completion_id)
  end

  @doc "Supersede an open empty-session request when a new assignment is inserted."
  @spec supersede_open_for_assignment_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def supersede_open_for_assignment_in_txn(%Txn{} = txn, child_session_key, assignment_id) do
    case Txn.q(
           txn,
           """
           SELECT id, deadlineWakeId, currentNoticeWakeId
           FROM completion_escalations
           WHERE childSessionKey=?1 AND status='open'
           """,
           [child_session_key]
         ) do
      [[completion_id, deadline_id, notice_id]] ->
        event_id =
          EventLog.lifecycle_with_id_in_txn(
            txn,
            "completion_escalation_superseded",
            completion_id,
            "reason=new-assignment"
          )

        cancel_disposed!(txn, deadline_id, event_id)
        cancel_disposed!(txn, notice_id, event_id)
        at = now()

        Txn.q(
          txn,
          """
          UPDATE completion_escalations
          SET status='superseded', supersededReason='new-assignment',
              supersededByAssignmentId=?2, supersededAt=?3,
              deadlineWakeId=NULL
          WHERE id=?1 AND status='open'
          """,
          [completion_id, assignment_id, at]
        )

        if Txn.changes(txn) != 1, do: raise("completion supersede race")
        :ok

      [] ->
        :ok
    end
  end

  defp schedule_notice(
         _txn,
         _completion_id,
         _assignment,
         _attest,
         _immediate_parent,
         %{kind: "main-unavailable"},
         _remaining,
         _root_main,
         _generation,
         _now
       ),
       do: nil

  defp schedule_notice(
         txn,
         completion_id,
         assignment,
         attest,
         immediate_parent,
         resolution,
         remaining,
         root_main,
         generation,
         now
       ) do
    id = wake_id(attest.id, "notice", generation)

    Wakes.schedule_in_txn(txn, %{
      wake_id: id,
      session_key: resolution.recipient,
      origin: "process:tightbeam",
      prompt:
        prompt(
          completion_id,
          assignment,
          attest,
          immediate_parent,
          resolution,
          remaining,
          root_main
        ),
      consumer: "prompt",
      due_at: now,
      target_gate: 1,
      reresolve: "lineage",
      reresolve_seed: assignment.holderKey,
      reresolve_rung: if(resolution.kind == "lineage", do: resolution.rung, else: 1),
      assignment_id: nil,
      work_item_id: nil
    })

    id
  end

  defp prompt(
         completion_id,
         assignment,
         attest,
         immediate_parent,
         resolution,
         remaining,
         root_main
       ) do
    action_needed = remaining == 0
    work_item = assignment.workItemId || "none"
    parent = immediate_parent || "none"

    resolution_text =
      if resolution.kind == "lineage",
        do: "lineage:rung-#{resolution.rung}",
        else: resolution.kind

    body =
      """
      Child completion recorded.
      completionId=#{completion_id}
      assignmentId=#{assignment.id}
      workItemId=#{work_item}
      childSessionKey=#{assignment.holderKey}
      closingAttestId=#{attest.id}
      outcome=completed
      causePrincipal=session:#{assignment.holderKey}
      immediateParentSessionKey=#{parent}
      recipientResolution=#{resolution_text}
      remainingOpenAssignments=#{remaining}
      actionNeeded=#{action_needed}
      """
      |> String.trim_trailing()

    cond do
      not action_needed ->
        body

      root_main ->
        body <>
          "\nChoose retain with `tightbeam completion-disposition #{completion_id} --decision retain`. Tightbeam will not choose or auto-retain."

      true ->
        body <>
          "\nChoose retain, park, or retire with `tightbeam completion-disposition #{completion_id} --decision <retain|park|retire>`. Tightbeam will not choose or auto-retire."
    end
  end

  defp resolve_recipient(_txn, child, _owner, true),
    do: {%{recipient: child, kind: "main-fallback", rung: nil}, nil}

  defp resolve_recipient(txn, child, owner, false) do
    [[parent]] = Txn.q(txn, "SELECT spawnedBy FROM sessions WHERE sessionKey=?1", [child])

    case first_active_same_owner(txn, parent, owner, 1, MapSet.new([child])) do
      {:ok, recipient, rung} ->
        {%{recipient: recipient, kind: "lineage", rung: rung}, nil}

      {:none, foreign_boundary} ->
        main = Org.personal_session_key(owner)

        case Txn.q(
               txn,
               "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
               [main, owner]
             ) do
          [[1]] -> {%{recipient: main, kind: "main-fallback", rung: nil}, foreign_boundary}
          [] -> {%{recipient: nil, kind: "main-unavailable", rung: nil}, foreign_boundary}
        end
    end
  end

  defp first_active_same_owner(_txn, nil, _owner, _rung, _seen), do: {:none, nil}

  defp first_active_same_owner(txn, key, owner, rung, seen) do
    if MapSet.member?(seen, key) do
      {:none, nil}
    else
      case Txn.q(
             txn,
             "SELECT ownerUserId, state, spawnedBy FROM sessions WHERE sessionKey=?1",
             [key]
           ) do
        [[^owner, "active", _parent]] ->
          {:ok, key, rung}

        [[^owner, _state, parent]] ->
          first_active_same_owner(txn, parent, owner, rung + 1, MapSet.put(seen, key))

        [[_foreign_owner, _state, _parent]] ->
          {:none, key}

        [] ->
          {:none, nil}
      end
    end
  end

  defp record_routing_events(txn, completion_id, resolution, foreign_boundary, generation) do
    if foreign_boundary do
      EventLog.lifecycle_in_txn(
        txn,
        "completion_escalation_cross_owner_lineage",
        completion_id,
        "foreignSessionKey=#{foreign_boundary} principal=#{@process_principal}"
      )
    end

    case resolution.kind do
      "main-fallback" ->
        EventLog.lifecycle_in_txn(
          txn,
          "completion_escalation_fallback",
          completion_id,
          "resolution=main-fallback generation=#{generation} principal=#{@process_principal}"
        )

      "main-unavailable" ->
        EventLog.lifecycle_in_txn(
          txn,
          "completion_escalation_undeliverable",
          completion_id,
          "resolution=main-unavailable generation=#{generation} principal=#{@process_principal}"
        )

      "lineage" ->
        :ok
    end
  end

  defp insert_membership(txn, wake_id, completion_id, generation, kind) do
    Txn.q(
      txn,
      """
      INSERT INTO completion_escalation_wakes (wakeId, completionId, generation, kind)
      VALUES (?1, ?2, ?3, ?4)
      """,
      [wake_id, completion_id, generation, kind]
    )
  end

  defp cancel_disposed!(_txn, nil, _event_id), do: :ok

  defp cancel_disposed!(txn, wake_id, event_id) do
    case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id]) do
      [["pending"]] ->
        command = %{
          wake_id: wake_id,
          requester: %{kind: "process", id: "tightbeam:completion-escalation"},
          reason_kind: "completion_request_disposed",
          causal_source: %{kind: "lifecycle_event", id: Integer.to_string(event_id)},
          outcome: %{
            kind: "disposition",
            disposition_kind: "completion_transition",
            disposition_id: Integer.to_string(event_id)
          }
        }

        if Wakes.cancel_in_txn(txn, command) != true,
          do: raise("completion wake cancellation refused: #{wake_id}")

      _ ->
        :ok
    end
  end

  defp fetch_in_txn!(txn, completion_id) do
    [[id, status, notice, deadline]] =
      Txn.q(
        txn,
        "SELECT id, status, currentNoticeWakeId, deadlineWakeId FROM completion_escalations WHERE id=?1",
        [completion_id]
      )

    %{id: id, status: status, current_notice_wake_id: notice, deadline_wake_id: deadline}
  end

  defp wake_id(attest_id, kind, generation),
    do: "completion:#{attest_id}:#{kind}:#{generation}"

  defp deadline_ms do
    Application.get_env(:tightbeam, :escalation_decision_deadline_ms, @default_deadline_ms)
  end

  defp now, do: System.system_time(:millisecond)
end
