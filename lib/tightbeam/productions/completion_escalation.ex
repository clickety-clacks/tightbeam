defmodule Tightbeam.Productions.CompletionEscalation do
  @moduledoc "Durable terminal empty-slate notices and explicit lifecycle disposition."

  alias Tightbeam.{DB, EventLog, Org, Wakes}
  alias Tightbeam.DB.Txn

  @process_id "tightbeam:completion-escalation"
  @process_principal "process:tightbeam:completion-escalation"
  @deadline_consumer "completion_disposition_deadline"
  @default_deadline_ms 86_400_000
  @ddl """
  CREATE TABLE IF NOT EXISTS completion_escalations (
    id TEXT PRIMARY KEY,
    dedupeKey TEXT NOT NULL UNIQUE,
    causeKind TEXT NOT NULL CHECK (causeKind IN ('attest','revocation')),
    causeId TEXT NOT NULL,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    workItemId TEXT NULL REFERENCES work_items(id),
    childSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    remainingOpenAssignments INTEGER NOT NULL CHECK (remainingOpenAssignments >= 0),
    closingAttestId TEXT NULL UNIQUE REFERENCES attests(id),
    revocationId TEXT NULL UNIQUE REFERENCES assignment_revocations(id),
    outcome TEXT NOT NULL CHECK (outcome IN ('completed','revoked')),
    causeBySession TEXT NULL REFERENCES sessions(sessionKey),
    causeByUser TEXT NULL,
    ownerUserId TEXT NOT NULL,
    rootMainHolder INTEGER NOT NULL CHECK (rootMainHolder IN (0,1)),
    immediateParentSessionKey TEXT NOT NULL,
    parentSessionKey TEXT NOT NULL,
    parentResolutionSource TEXT NOT NULL CHECK (
      parentResolutionSource IN ('explicit','owner_main')
    ),
    parentRouteStatus TEXT NOT NULL CHECK (
      parentRouteStatus IN ('scheduled','unavailable','root-self')
    ),
    reportToSessionKey TEXT NULL REFERENCES sessions(sessionKey),
    reportToRouteStatus TEXT NOT NULL CHECK (
      reportToRouteStatus IN ('not-declared','scheduled','shared-parent','unavailable')
    ),
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    currentRecipientSessionKey TEXT NULL REFERENCES sessions(sessionKey),
    currentRecipientUserId TEXT NULL,
    recipientGeneration INTEGER NULL CHECK (recipientGeneration >= 0),
    recipientReissueCount INTEGER NULL CHECK (recipientReissueCount >= 0),
    recipientReissueLimit INTEGER NULL CHECK (recipientReissueLimit >= 0),
    currentParentNoticeWakeId TEXT NULL UNIQUE REFERENCES wakes(wakeId),
    reportToNoticeWakeId TEXT NULL UNIQUE REFERENCES wakes(wakeId),
    deadlineWakeId TEXT NULL UNIQUE REFERENCES wakes(wakeId),
    actionDeadlineAt INTEGER NULL,
    status TEXT NOT NULL CHECK (
      status IN ('notice-only','open','acknowledged','retained_root','superseded')
    ),
    decision TEXT NULL CHECK (decision IN ('retain','park','retire')),
    actedBySession TEXT NULL REFERENCES sessions(sessionKey),
    actedByUser TEXT NULL,
    actedAt INTEGER NULL,
    supersededReason TEXT NULL CHECK (
      supersededReason IN ('new-assignment','child-retired')
    ),
    supersededByAssignmentId TEXT NULL REFERENCES assignments(id),
    supersededAt INTEGER NULL,
    createdAt INTEGER NOT NULL,
    CHECK ((causeBySession IS NOT NULL) != (causeByUser IS NOT NULL)),
    UNIQUE (causeKind, causeId),
    CHECK (dedupeKey = 'terminal:' || causeKind || ':' || causeId),
    CHECK (
      (causeKind = 'attest' AND causeId = closingAttestId
        AND closingAttestId IS NOT NULL AND revocationId IS NULL
        AND outcome = 'completed' AND causeBySession = childSessionKey)
      OR
      (causeKind = 'revocation' AND causeId = revocationId
        AND revocationId IS NOT NULL AND closingAttestId IS NULL
        AND outcome = 'revoked' AND remainingOpenAssignments = 0
        AND reportToSessionKey IS NULL AND reportToRouteStatus = 'not-declared'
        AND reportToNoticeWakeId IS NULL)
    ),
    CHECK (
      (parentRouteStatus = 'scheduled' AND rootMainHolder = 0
        AND parentSessionKey IS immediateParentSessionKey
        AND (remainingOpenAssignments = 0 OR currentParentNoticeWakeId IS NOT NULL))
      OR
      (parentRouteStatus = 'unavailable' AND rootMainHolder = 0
        AND parentSessionKey IS immediateParentSessionKey
        AND ((remainingOpenAssignments >= 1 AND currentParentNoticeWakeId IS NULL)
          OR remainingOpenAssignments = 0))
      OR
      (parentRouteStatus = 'root-self' AND rootMainHolder = 1
        AND parentResolutionSource = 'owner_main'
        AND immediateParentSessionKey = childSessionKey
        AND parentSessionKey = childSessionKey
        AND (remainingOpenAssignments = 0 OR currentParentNoticeWakeId IS NOT NULL))
    ),
    CHECK (
      (reportToRouteStatus = 'not-declared'
        AND reportToSessionKey IS NULL AND reportToNoticeWakeId IS NULL)
      OR
      (reportToRouteStatus = 'scheduled'
        AND reportToSessionKey IS NOT NULL AND reportToNoticeWakeId IS NOT NULL
        AND reportToSessionKey IS NOT parentSessionKey)
      OR
      (reportToRouteStatus = 'shared-parent'
        AND reportToSessionKey IS NOT NULL AND reportToNoticeWakeId IS NULL
        AND parentRouteStatus IN ('scheduled','root-self')
        AND reportToSessionKey IS parentSessionKey)
      OR
      (reportToRouteStatus = 'unavailable'
        AND reportToSessionKey IS NOT NULL AND reportToNoticeWakeId IS NULL)
    ),
    CHECK (
      status = 'notice-only'
        AND remainingOpenAssignments >= 1
        AND currentRecipientSessionKey IS NULL AND currentRecipientUserId IS NULL
        AND recipientGeneration IS NULL AND recipientReissueCount IS NULL
        AND recipientReissueLimit IS NULL
        AND decision IS NULL AND actionDeadlineAt IS NULL AND deadlineWakeId IS NULL
        AND actedBySession IS NULL AND actedByUser IS NULL AND actedAt IS NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'open'
        AND remainingOpenAssignments = 0
        AND ((currentRecipientSessionKey IS NOT NULL) != (currentRecipientUserId IS NOT NULL))
        AND recipientGeneration IS NOT NULL AND recipientReissueCount IS NOT NULL
        AND recipientReissueLimit IS NOT NULL
        AND (
          (currentRecipientSessionKey IS NOT NULL
            AND currentParentNoticeWakeId IS NOT NULL
            AND actionDeadlineAt IS NOT NULL AND deadlineWakeId IS NOT NULL)
          OR
          (currentRecipientUserId = ownerUserId
            AND actionDeadlineAt IS NULL AND deadlineWakeId IS NULL)
        )
        AND decision IS NULL
        AND actedBySession IS NULL AND actedByUser IS NULL AND actedAt IS NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'acknowledged'
        AND rootMainHolder = 0
        AND remainingOpenAssignments = 0
        AND decision IS NOT NULL AND actionDeadlineAt IS NULL AND deadlineWakeId IS NULL
        AND ((actedBySession IS NOT NULL) != (actedByUser IS NOT NULL)) AND actedAt IS NOT NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'retained_root'
        AND rootMainHolder = 1
        AND remainingOpenAssignments = 0
        AND decision = 'retain' AND actionDeadlineAt IS NULL AND deadlineWakeId IS NULL
        AND ((actedBySession IS NOT NULL) != (actedByUser IS NOT NULL)) AND actedAt IS NOT NULL
        AND supersededReason IS NULL AND supersededByAssignmentId IS NULL AND supersededAt IS NULL
      OR status = 'superseded'
        AND remainingOpenAssignments = 0
        AND decision IS NULL AND actionDeadlineAt IS NULL AND deadlineWakeId IS NULL
        AND actedBySession IS NULL AND actedByUser IS NULL AND actedAt IS NULL AND supersededAt IS NOT NULL
        AND (
          (supersededReason = 'new-assignment' AND supersededByAssignmentId IS NOT NULL)
          OR
          (supersededReason = 'child-retired' AND supersededByAssignmentId IS NULL)
        )
    ),
    CHECK (
      status = 'notice-only'
      OR (
        ((currentRecipientSessionKey IS NOT NULL) != (currentRecipientUserId IS NOT NULL))
        AND recipientGeneration IS NOT NULL AND recipientReissueCount IS NOT NULL
        AND recipientReissueLimit IS NOT NULL
        AND (currentRecipientUserId IS NULL OR currentRecipientUserId = ownerUserId)
        AND (
          currentRecipientSessionKey IS NULL
          OR (rootMainHolder = 1 AND currentRecipientSessionKey = childSessionKey)
          OR (rootMainHolder = 0 AND currentRecipientSessionKey != childSessionKey)
        )
      )
    )
  );
  CREATE INDEX IF NOT EXISTS completion_escalations_child_status
    ON completion_escalations(childSessionKey, status);
  CREATE INDEX IF NOT EXISTS completion_escalations_assignment
    ON completion_escalations(assignmentId);
  CREATE UNIQUE INDEX IF NOT EXISTS completion_escalations_one_open_child
    ON completion_escalations(childSessionKey) WHERE status = 'open';

  CREATE TABLE IF NOT EXISTS completion_escalation_wakes (
    wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
    completionId TEXT NOT NULL REFERENCES completion_escalations(id),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('parent-notice','report-to-notice','deadline')),
    recipientGeneration INTEGER NULL CHECK (recipientGeneration >= 0),
    recipientReissueCount INTEGER NULL CHECK (recipientReissueCount >= 0),
    recipientSessionKey TEXT NULL REFERENCES sessions(sessionKey),
    recipientUserId TEXT NULL,
    CHECK (
      kind = 'report-to-notice'
        AND generation = 0
        AND recipientGeneration IS NULL AND recipientReissueCount IS NULL
        AND recipientSessionKey IS NULL AND recipientUserId IS NULL
      OR
      kind = 'parent-notice'
        AND (
          (generation = 0
            AND recipientGeneration IS NULL AND recipientReissueCount IS NULL
            AND recipientSessionKey IS NOT NULL AND recipientUserId IS NULL)
          OR
          (recipientGeneration IS NOT NULL AND recipientReissueCount IS NOT NULL
            AND ((recipientSessionKey IS NOT NULL) != (recipientUserId IS NOT NULL)))
        )
      OR
      kind = 'deadline'
        AND recipientGeneration IS NOT NULL AND recipientReissueCount IS NOT NULL
        AND recipientSessionKey IS NOT NULL AND recipientUserId IS NULL
    ),
    UNIQUE (completionId, generation, kind)
  );
  CREATE INDEX IF NOT EXISTS completion_escalation_wakes_completion
    ON completion_escalation_wakes(completionId, generation, kind);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Create one admitted terminal record and its wakes in the assignment close transaction."
  @spec open_terminal_in_txn(Txn.t(), map(), String.t(), map()) :: map() | :no_empty_epoch
  def open_terminal_in_txn(%Txn{} = txn, assignment, cause_kind, cause)
      when cause_kind in ["attest", "revocation"] do
    child = assignment.holderKey

    [[built_in]] =
      Txn.q(txn, "SELECT isBuiltIn FROM sessions WHERE sessionKey=?1", [child])

    resolution = Org.effective_parent_in_txn(txn, child)

    [[remaining]] =
      Txn.q(txn, "SELECT count(*) FROM assignments WHERE holderKey=?1 AND state='open'", [
        child
      ])

    if cause_kind == "revocation" and remaining > 0 do
      :no_empty_epoch
    else
      open_admitted_terminal_in_txn(
        txn,
        assignment,
        cause_kind,
        cause,
        built_in,
        resolution,
        remaining
      )
    end
  end

  defp open_admitted_terminal_in_txn(
         txn,
         assignment,
         cause_kind,
         cause,
         built_in,
         resolution,
         remaining
       ) do
    child = assignment.holderKey
    owner = resolution.owner_user_id
    terminal = terminal_cause!(cause_kind, cause, child)

    root_main = built_in == 1 and child == Org.personal_session_key(owner)
    parent = parent_route(txn, Map.put(resolution, :child_session_key, child), root_main)
    report_to_key = if(cause_kind == "attest", do: assignment.reportToSessionKey)
    report_to = report_to_route(txn, report_to_key, owner, parent)
    completion_id = "cn_" <> Tightbeam.Id.uuid4()
    generation = 0
    created_at = now()
    action_needed = remaining == 0
    status = if(action_needed, do: "open", else: "notice-only")

    recipient =
      if action_needed,
        do: initial_recipient(txn, resolution.session_key, parent, child, owner, root_main),
        else: nil

    reissue_limit = if(action_needed, do: recipient_reissue_limit!())
    session_recipient = recipient && recipient.session_key
    user_recipient = recipient && recipient.user_id
    notice_target = if(action_needed, do: action_notice_target(txn, recipient, owner))
    deadline_at = if(action_needed and session_recipient, do: created_at + deadline_ms())

    parent_wake_id =
      if (action_needed and not is_nil(notice_target)) or
           (not action_needed and parent.route_status in ["scheduled", "root-self"]) do
        id = wake_id(terminal.token, "parent-notice", generation)
        target = if(action_needed, do: notice_target, else: parent.session_key)

        schedule_prompt(
          txn,
          id,
          target,
          parent_prompt(
            completion_id,
            assignment,
            terminal,
            resolution.session_key,
            resolution.source,
            parent,
            report_to_key,
            remaining,
            root_main,
            recipient,
            generation,
            0,
            reissue_limit
          ),
          created_at
        )

        id
      end

    report_to_wake_id =
      if report_to.route_status == "scheduled" do
        id = wake_id(terminal.token, "report-to-notice", generation)

        schedule_prompt(
          txn,
          id,
          report_to_key,
          report_to_prompt(
            completion_id,
            assignment,
            terminal,
            resolution.session_key,
            resolution.source,
            parent,
            report_to_key,
            remaining
          ),
          created_at
        )

        id
      end

    deadline_wake_id =
      if action_needed and session_recipient do
        id = wake_id(terminal.token, "deadline", generation)
        schedule_deadline(txn, id, child, deadline_at)
        id
      end

    Txn.q(
      txn,
      """
      INSERT INTO completion_escalations
        (id, dedupeKey, causeKind, causeId, assignmentId, workItemId, childSessionKey,
         remainingOpenAssignments, closingAttestId, revocationId, outcome, causeBySession,
         causeByUser,
         ownerUserId, rootMainHolder, immediateParentSessionKey, parentSessionKey,
         parentResolutionSource, parentRouteStatus, reportToSessionKey,
         reportToRouteStatus, generation, currentRecipientSessionKey,
         currentRecipientUserId, recipientGeneration, recipientReissueCount,
         recipientReissueLimit,
         currentParentNoticeWakeId, reportToNoticeWakeId, deadlineWakeId,
         actionDeadlineAt, status, createdAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
              ?15, ?16, ?17, ?18, ?19, ?20, ?21, 0, ?22, ?23, ?24, ?25, ?26,
              ?27, ?28, ?29, ?30, ?31, ?32)
      """,
      [
        completion_id,
        "terminal:#{cause_kind}:#{terminal.id}",
        cause_kind,
        terminal.id,
        assignment.id,
        assignment.workItemId,
        child,
        remaining,
        terminal.closing_attest_id,
        terminal.revocation_id,
        terminal.outcome,
        terminal.by_session,
        terminal.by_user,
        owner,
        bool_int(root_main),
        resolution.session_key,
        parent.session_key,
        Atom.to_string(resolution.source),
        parent.route_status,
        report_to_key,
        report_to.route_status,
        session_recipient,
        user_recipient,
        if(action_needed, do: 0),
        if(action_needed, do: 0),
        reissue_limit,
        parent_wake_id,
        report_to_wake_id,
        deadline_wake_id,
        deadline_at,
        status,
        created_at
      ]
    )

    insert_membership(
      txn,
      parent_wake_id,
      completion_id,
      generation,
      "parent-notice",
      if(action_needed, do: 0),
      if(action_needed, do: 0),
      if(action_needed, do: session_recipient, else: parent.session_key),
      if(action_needed, do: user_recipient)
    )

    insert_membership(txn, report_to_wake_id, completion_id, generation, "report-to-notice")

    insert_membership(
      txn,
      deadline_wake_id,
      completion_id,
      generation,
      "deadline",
      0,
      0,
      session_recipient,
      nil
    )

    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_opened",
      completion_id,
      "causeKind=#{cause_kind} outcome=#{terminal.outcome} remainingOpenAssignments=#{remaining} principal=#{@process_principal}"
    )

    record_parent_failure(txn, completion_id, parent, generation)
    record_report_to_failure(txn, completion_id, report_to, generation)
    record_cross_owner_walk(txn, completion_id, recipient)
    record_owner_carrier_failure(txn, completion_id, recipient, notice_target, generation)
    fetch_in_txn!(txn, completion_id)
  end

  @doc "Supersede one live empty-session request inside a new assignment transaction."
  @spec supersede_open_for_assignment_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def supersede_open_for_assignment_in_txn(%Txn{} = txn, child_session_key, assignment_id) do
    case open_row_for_child(txn, child_session_key) do
      nil ->
        :ok

      row ->
        transition_superseded_in_txn(txn, row, "new-assignment", assignment_id)
    end
  end

  @doc "Consume a current completion deadline and reissue or terminalize its request."
  @spec reissue(DB.server(), Wakes.wake()) :: :ok
  def reissue(db, wake) do
    case DB.transaction(db, fn txn -> reissue_in_txn(txn, wake.wake_id) end) do
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end
  end

  @spec reissue_in_txn(Txn.t(), String.t()) :: :ok
  def reissue_in_txn(%Txn{} = txn, wake_id) do
    case fetch_by_deadline_in_txn(txn, wake_id) do
      %{status: "open", deadline_wake_id: ^wake_id} = row ->
        [[child_state]] =
          Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [row.child_session_key])

        open_assignment = oldest_open_assignment(txn, row.child_session_key)

        cond do
          open_assignment ->
            transition_superseded_in_txn(
              txn,
              row,
              "new-assignment",
              open_assignment.id,
              consume_deadline: true
            )

          child_state == "retired" ->
            transition_superseded_in_txn(txn, row, "child-retired", nil, consume_deadline: true)

          true ->
            reissue_open_in_txn(txn, row)
        end

      _ ->
        :ok
    end
  end

  @doc "Guard completion-linked prompt delivery against current exact-target rows."
  @spec admit_delivery_in_txn(Txn.t(), String.t(), String.t()) :: :ordinary | :deliver | :skip
  def admit_delivery_in_txn(%Txn{} = txn, wake_id, requested_session_key) do
    case delivery_row(txn, wake_id) do
      nil ->
        :ordinary

      %{kind: "deadline"} ->
        :skip

      row ->
        if deliverable?(txn, row, requested_session_key) do
          :deliver
        else
          dispose_undeliverable_delivery_in_txn(txn, row)
          :skip
        end
    end
  end

  @doc "List completion records visible to the typed caller."
  @spec notices(DB.server(), map()) :: map()
  def notices(db, call) do
    status = call.params[:status] || "open"
    child = call.params[:session_key]

    cond do
      status not in ["open", "all"] ->
        error("invalid_status", "status must be open or all")

      not (is_nil(child) or is_binary(child)) ->
        error("invalid_session", "session must be a session key")

      true ->
        {:ok, rows} =
          DB.query(
            db,
            "SELECT #{columns()} FROM completion_escalations " <>
              "WHERE (?1='all' OR status='open') AND (?2 IS NULL OR childSessionKey=?2) " <>
              "ORDER BY createdAt, id",
            [status, child]
          )

        records =
          rows
          |> Enum.map(&row/1)
          |> Enum.filter(&visible?(db, &1, call.principal))
          |> Enum.map(&project(db, &1))

        %{completionNotices: records}
    end
  end

  @doc "Apply all non-retire disposition precedence checks inside the action transaction."
  @spec preflight_disposition_in_txn(Txn.t(), String.t(), String.t(), term()) ::
          {:action, map()} | {:replay, map()} | {:error, map()}
  def preflight_disposition_in_txn(%Txn{} = txn, completion_id, decision, principal) do
    cond do
      decision not in ~w(retain park retire) ->
        {:error, error("invalid_decision", "decision must be retain, park, or retire")}

      true ->
        case fetch_in_txn(txn, completion_id) do
          nil -> {:error, error("unknown_completion", "unknown completion: #{completion_id}")}
          row -> preflight_existing_in_txn(txn, row, decision, principal)
        end
    end
  end

  @doc "Commit an explicit retain after preflight."
  @spec retain_in_txn(Txn.t(), String.t(), term()) :: map()
  def retain_in_txn(%Txn{} = txn, completion_id, principal) do
    row = fetch_in_txn!(txn, completion_id)
    root = root_main_now?(txn, row)
    terminal_status = if(root, do: "retained_root", else: "acknowledged")
    acknowledge_in_txn(txn, row, "retain", principal, terminal_status)
    fetch_in_txn!(txn, completion_id)
  end

  @doc "Record the reviewed park dependency refusal without acknowledging the request."
  @spec park_unavailable_in_txn(Txn.t(), String.t(), term()) :: map()
  def park_unavailable_in_txn(%Txn{} = txn, completion_id, principal) do
    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_park_failed",
      completion_id,
      "reason=park_dependency_unavailable principal=#{principal_string(principal)}"
    )

    %{
      code: "park_dependency_unavailable",
      completionId: completion_id,
      requestStatus: "open"
    }
  end

  @doc "Acknowledge any open completion request before the shared retirement mutation."
  @spec acknowledge_retire_in_txn(Txn.t(), String.t(), term()) :: :ok
  def acknowledge_retire_in_txn(%Txn{} = txn, child_session_key, principal) do
    case open_row_for_child(txn, child_session_key) do
      nil ->
        :ok

      row ->
        acknowledge_in_txn(txn, row, "retire", principal, "acknowledged")
        :ok
    end
  end

  @doc "Record a completion-specific retire deferral without scheduling an intent wake."
  @spec retire_deferred_in_txn(Txn.t(), String.t(), term(), [map()]) :: map()
  def retire_deferred_in_txn(%Txn{} = txn, completion_id, principal, deferred) do
    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_retire_deferred",
      completion_id,
      "reason=critical-lease principal=#{principal_string(principal)}"
    )

    %{
      code: "retire_deferred",
      completionId: completion_id,
      requestStatus: "open",
      deferred: deferred
    }
  end

  @doc "Fetch one projected completion after a successful command."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db, completion_id) do
    case DB.query(db, "SELECT #{columns()} FROM completion_escalations WHERE id=?1", [
           completion_id
         ]) do
      {:ok, [raw]} -> project(db, row(raw))
      _ -> nil
    end
  end

  defp preflight_existing_in_txn(txn, row, decision, principal) do
    cond do
      not principal_kind_allowed?(principal) ->
        {:error, error("principal_not_allowed", "a session or user principal is required")}

      not authorized_in_txn?(txn, row, principal) ->
        {:error,
         error("not_authorized", "the current completion recipient or owner user is required")}

      identical_replay?(row, decision, principal) and
          replay_principal_current?(txn, row, principal) ->
        {:replay, row}

      row.status in ["acknowledged", "retained_root"] ->
        {:error, error("request_not_open", "completion request is not open")}

      row.status == "notice-only" ->
        {:error, error("action_not_required", "completion did not empty the child session")}

      row.status == "superseded" ->
        {:error, error("request_superseded", "completion request was superseded")}

      not child_active?(txn, row.child_session_key) ->
        EventLog.lifecycle_in_txn(
          txn,
          "completion_escalation_state_inconsistent",
          row.id,
          "reason=child-not-active principal=#{principal_string(principal)}"
        )

        {:error, error("child_not_active", "completion child is not active")}

      assignment = oldest_open_assignment(txn, row.child_session_key) ->
        transition_superseded_in_txn(txn, row, "new-assignment", assignment.id)
        {:error, error("request_superseded", "completion request was superseded")}

      row.root_main_holder and decision in ["park", "retire"] ->
        {:error,
         %{
           code: "root_lifecycle_unsupported",
           completionId: row.id,
           requestStatus: "open",
           decision: decision
         }}

      true ->
        {:action, row}
    end
  end

  defp acknowledge_in_txn(txn, row, decision, principal, terminal_status) do
    {acted_session, acted_user} = acting_columns(principal)
    acted_at = now()

    Txn.q(
      txn,
      """
      UPDATE completion_escalations
      SET status=?2, decision=?3, actedBySession=?4, actedByUser=?5,
          actedAt=?6, deadlineWakeId=NULL, actionDeadlineAt=NULL
      WHERE id=?1 AND status='open'
      """,
      [row.id, terminal_status, decision, acted_session, acted_user, acted_at]
    )

    if Txn.changes(txn) != 1, do: raise("completion acknowledgment race")

    detail =
      if terminal_status == "retained_root",
        do: "decision=retain outcome=retained_root",
        else: "decision=#{decision}"

    EventLog.lifecycle_in_txn(txn, "completion_escalation_acknowledged", row.id, detail)
    cancel_terminal_wakes!(txn, row)
  end

  defp transition_superseded_in_txn(txn, row, reason, assignment_id, opts \\ []) do
    at = now()

    Txn.q(
      txn,
      """
      UPDATE completion_escalations
      SET status='superseded', supersededReason=?2, supersededByAssignmentId=?3,
          supersededAt=?4, deadlineWakeId=NULL, actionDeadlineAt=NULL
      WHERE id=?1 AND status='open'
      """,
      [row.id, reason, assignment_id, at]
    )

    if Txn.changes(txn) != 1, do: raise("completion supersede race")

    detail =
      if reason == "child-retired" do
        "reason=child-retired principal=#{@process_principal}"
      else
        "reason=new-assignment"
      end

    EventLog.lifecycle_in_txn(txn, "completion_escalation_superseded", row.id, detail)

    if Keyword.get(opts, :consume_deadline, false) do
      command = terminal_cancel_command(row.id)
      cancel_if_pending!(txn, row.current_parent_notice_wake_id, command)
      cancel_if_pending!(txn, row.report_to_notice_wake_id, command)
      fire_deadline!(txn, row.deadline_wake_id)
    else
      cancel_terminal_wakes!(txn, row)
    end

    :ok
  end

  defp reissue_open_in_txn(txn, row) do
    generation = row.generation + 1
    at = now()
    recipient = next_recipient(txn, row)
    target = action_notice_target(txn, recipient, row.owner_user_id)
    deadline_at = if(recipient.session_key, do: at + deadline_ms())

    deadline_id =
      if recipient.session_key, do: wake_id(cause_token(row), "deadline", generation)

    parent_id = if(target, do: wake_id(cause_token(row), "parent-notice", generation))

    if parent_id do
      assignment = assignment_for_prompt(txn, row.assignment_id)

      schedule_prompt(
        txn,
        parent_id,
        target,
        parent_prompt(
          row.id,
          assignment,
          terminal_from_row(row),
          row.immediate_parent_session_key,
          row.parent_resolution_source,
          %{route_status: row.parent_route_status},
          row.report_to_session_key,
          0,
          row.root_main_holder,
          recipient,
          recipient.recipient_generation,
          recipient.reissue_count,
          row.recipient_reissue_limit
        ),
        at
      )
    end

    if deadline_id, do: schedule_deadline(txn, deadline_id, row.child_session_key, deadline_at)

    insert_membership(
      txn,
      parent_id,
      row.id,
      generation,
      "parent-notice",
      recipient.recipient_generation,
      recipient.reissue_count,
      recipient.session_key,
      recipient.user_id
    )

    insert_membership(
      txn,
      deadline_id,
      row.id,
      generation,
      "deadline",
      recipient.recipient_generation,
      recipient.reissue_count,
      recipient.session_key,
      nil
    )

    if parent_id do
      EventLog.lifecycle_in_txn(
        txn,
        "completion_escalation_reissued",
        row.id,
        "generation=#{generation} recipientGeneration=#{recipient.recipient_generation} recipientReissueCount=#{recipient.reissue_count} recipient=#{recipient_principal(recipient)} principal=#{@process_principal}"
      )
    end

    cancel_replaced_parent!(txn, row.current_parent_notice_wake_id, parent_id)

    Txn.q(
      txn,
      """
      UPDATE completion_escalations
      SET generation=?2, currentRecipientSessionKey=?3, currentRecipientUserId=?4,
          recipientGeneration=?5, recipientReissueCount=?6,
          currentParentNoticeWakeId=?7, deadlineWakeId=?8, actionDeadlineAt=?9
      WHERE id=?1 AND status='open' AND deadlineWakeId=?10
      """,
      [
        row.id,
        generation,
        recipient.session_key,
        recipient.user_id,
        recipient.recipient_generation,
        recipient.reissue_count,
        parent_id,
        deadline_id,
        deadline_at,
        row.deadline_wake_id
      ]
    )

    if Txn.changes(txn) != 1, do: raise("completion reissue race")
    record_recipient_failure(txn, row, generation)
    record_cross_owner_walk(txn, row.id, recipient)
    record_owner_carrier_failure(txn, row.id, recipient, target, generation)
    fire_deadline!(txn, row.deadline_wake_id)
    :ok
  end

  defp dispose_undeliverable_delivery_in_txn(txn, row) do
    if row.wake_state == "pending" do
      cond do
        row.status in ["acknowledged", "retained_root", "superseded"] ->
          cancel_wake!(txn, row.wake_id, terminal_cancel_command(row.id))

        row.kind == "parent-notice" and is_binary(row.current_parent_notice_wake_id) and
            row.current_parent_notice_wake_id != row.wake_id ->
          cancel_wake!(
            txn,
            row.wake_id,
            replacement_cancel_command(row.current_parent_notice_wake_id)
          )

        true ->
          cancel_wake!(
            txn,
            row.wake_id,
            target_unresolvable_command("tightbeam:wake-scheduler", row.wake_id)
          )

          channel = delivery_channel(row)

          EventLog.lifecycle_in_txn(
            txn,
            "completion_escalation_undeliverable",
            row.id,
            "channel=#{channel} resolution=target-unresolvable reason=target-unresolvable generation=#{row.wake_generation} principal=#{@process_principal}"
          )
      end
    end

    :ok
  end

  defp deliverable?(txn, row, requested_session_key) do
    row.wake_state == "pending" and
      case row.kind do
        "report-to-notice" ->
          row.status in ["open", "notice-only"] and
            row.report_to_notice_wake_id == row.wake_id and
            requested_session_key == row.report_to_session_key and
            Txn.q(
              txn,
              "SELECT completionReportToSessionKey FROM assignments WHERE id=?1",
              [row.assignment_id]
            ) == [[row.report_to_session_key]] and
            active_owner_session?(txn, row.report_to_session_key, row.owner_user_id)

        "parent-notice" when row.status == "notice-only" ->
          row.current_parent_notice_wake_id == row.wake_id and
            requested_session_key == row.parent_session_key and
            row.member_session_key == row.parent_session_key and
            active_owner_session?(txn, row.parent_session_key, row.owner_user_id)

        "parent-notice" when row.status == "open" ->
          row.current_parent_notice_wake_id == row.wake_id and
            row.member_recipient_generation == row.recipient_generation and
            row.member_reissue_count == row.recipient_reissue_count and
            action_recipient_deliverable?(txn, row, requested_session_key)

        _ ->
          false
      end
  end

  defp action_recipient_deliverable?(txn, row, requested_session_key)
       when is_binary(row.member_session_key) do
    row.current_recipient_session_key == row.member_session_key and
      is_nil(row.member_user_id) and requested_session_key == row.member_session_key and
      active_owner_session?(txn, row.member_session_key, row.owner_user_id)
  end

  defp action_recipient_deliverable?(txn, row, requested_session_key)
       when is_binary(row.member_user_id) do
    carrier = Org.personal_session_key(row.owner_user_id)

    row.current_recipient_user_id == row.member_user_id and
      row.member_user_id == row.owner_user_id and requested_session_key == carrier and
      active_owner_session?(txn, carrier, row.owner_user_id)
  end

  defp action_recipient_deliverable?(_txn, _row, _requested_session_key), do: false

  defp delivery_channel(%{kind: "report-to-notice"}), do: "report-to"

  defp delivery_channel(row) do
    if row.wake_generation == 0 and row.member_session_key == row.parent_session_key,
      do: "parent",
      else: if(is_binary(row.member_user_id), do: "owner-root", else: "recipient")
  end

  defp parent_route(_txn, %{session_key: child, source: :owner_main}, true),
    do: %{session_key: child, route_status: "root-self", failure_reason: nil, foreign: false}

  defp parent_route(_txn, %{session_key: selected}, false) when not is_binary(selected),
    do: unavailable_parent(selected || "missing-parent", "parent-missing")

  defp parent_route(txn, %{session_key: selected, owner_user_id: owner} = resolution, false) do
    case Txn.q(
           txn,
           "SELECT ownerUserId, state FROM sessions WHERE sessionKey=?1",
           [selected]
         ) do
      [] ->
        unavailable_parent(selected, "parent-missing")

      [[^owner, _state]] when selected == resolution.child_session_key ->
        unavailable_parent(selected, "parent-cycle")

      [[^owner, "active"]] ->
        scheduled_parent(selected)

      [[^owner, _state]] ->
        unavailable_parent(selected, "parent-inactive")

      [[_foreign, _state]] ->
        unavailable_parent(selected, "parent-owner-mismatch", true)
    end
  end

  defp initial_recipient(_txn, _seed, _parent, child, _owner, true),
    do: recipient_session(child, 0, 0)

  defp initial_recipient(_txn, seed, %{route_status: "scheduled"}, _child, _owner, false),
    do: recipient_session(seed, 0, 0)

  defp initial_recipient(txn, seed, parent, child, owner, false) do
    visited = MapSet.new([child])
    recipient = walk_from_seed(txn, seed, child, owner, visited, 0)

    if parent.foreign and recipient.cross_owner_key == seed,
      do: %{recipient | cross_owner_key: nil},
      else: recipient
  end

  defp next_recipient(txn, row) do
    current = row.current_recipient_session_key

    cond do
      is_binary(current) and
        active_owner_session?(txn, current, row.owner_user_id) and
          row.recipient_reissue_count < row.recipient_reissue_limit ->
        recipient_session(
          current,
          row.recipient_generation,
          row.recipient_reissue_count + 1
        )

      is_binary(current) ->
        visited = visited_recipient_sessions(txn, row.id) |> MapSet.put(row.child_session_key)

        next_key =
          case Txn.q(txn, "SELECT spawnedBy FROM sessions WHERE sessionKey=?1", [current]) do
            [[spawned_by]] -> spawned_by
            [] -> nil
          end

        walk_ancestor(
          txn,
          next_key,
          row.child_session_key,
          row.owner_user_id,
          visited,
          row.recipient_generation + 1
        )

      true ->
        recipient_user(row.owner_user_id, row.recipient_generation, row.recipient_reissue_count)
    end
  end

  defp walk_from_seed(txn, seed, child, owner, visited, recipient_generation) do
    case Txn.q(txn, "SELECT ownerUserId,state,spawnedBy FROM sessions WHERE sessionKey=?1", [seed]) do
      [[^owner, "active", _]] when seed != child and not is_nil(seed) ->
        recipient_session(seed, recipient_generation, 0)

      [[^owner, _state, spawned_by]] ->
        walk_ancestor(
          txn,
          spawned_by,
          child,
          owner,
          MapSet.put(visited, seed),
          recipient_generation
        )

      [[_foreign, _state, _spawned_by]] ->
        recipient_user(owner, recipient_generation, 0, seed)

      [] ->
        recipient_user(owner, recipient_generation, 0)
    end
  end

  defp walk_ancestor(_txn, nil, _child, owner, _visited, generation),
    do: recipient_user(owner, generation, 0)

  defp walk_ancestor(txn, key, child, owner, visited, generation) do
    cond do
      key == child or MapSet.member?(visited, key) ->
        recipient_user(owner, generation, 0)

      true ->
        case Txn.q(
               txn,
               "SELECT ownerUserId,state,spawnedBy FROM sessions WHERE sessionKey=?1",
               [key]
             ) do
          [] ->
            recipient_user(owner, generation, 0)

          [[^owner, "active", _spawned_by]] ->
            recipient_session(key, generation, 0)

          [[^owner, _state, spawned_by]] ->
            walk_ancestor(txn, spawned_by, child, owner, MapSet.put(visited, key), generation)

          [[_foreign, _state, _spawned_by]] ->
            recipient_user(owner, generation, 0, key)
        end
    end
  end

  defp recipient_session(key, generation, count),
    do: %{
      session_key: key,
      user_id: nil,
      recipient_generation: generation,
      reissue_count: count,
      cross_owner_key: nil
    }

  defp recipient_user(user, generation, count, cross_owner_key \\ nil),
    do: %{
      session_key: nil,
      user_id: user,
      recipient_generation: generation,
      reissue_count: count,
      cross_owner_key: cross_owner_key
    }

  defp action_notice_target(_txn, %{session_key: key}, _owner) when is_binary(key), do: key

  defp action_notice_target(txn, %{user_id: owner}, owner) do
    carrier = Org.personal_session_key(owner)
    if active_owner_session?(txn, carrier, owner), do: carrier
  end

  defp visited_recipient_sessions(txn, completion_id) do
    Txn.q(
      txn,
      "SELECT recipientSessionKey FROM completion_escalation_wakes WHERE completionId=?1 AND recipientSessionKey IS NOT NULL",
      [completion_id]
    )
    |> Enum.reduce(MapSet.new(), fn [key], acc -> MapSet.put(acc, key) end)
  end

  defp scheduled_parent(key),
    do: %{session_key: key, route_status: "scheduled", failure_reason: nil, foreign: false}

  defp unavailable_parent(key, reason, foreign \\ false),
    do: %{session_key: key, route_status: "unavailable", failure_reason: reason, foreign: foreign}

  defp report_to_route(_txn, nil, _owner, _parent),
    do: %{route_status: "not-declared", failure_reason: nil}

  defp report_to_route(_txn, key, _owner, %{session_key: key, route_status: status})
       when status in ["scheduled", "root-self"],
       do: %{route_status: "shared-parent", failure_reason: nil}

  defp report_to_route(txn, key, owner, _parent) do
    case Txn.q(txn, "SELECT ownerUserId, state FROM sessions WHERE sessionKey=?1", [key]) do
      [[^owner, "active"]] ->
        %{route_status: "scheduled", failure_reason: nil}

      [] ->
        %{route_status: "unavailable", failure_reason: "report-to-missing"}

      [[^owner, _]] ->
        %{route_status: "unavailable", failure_reason: "report-to-inactive"}

      [[_foreign, _]] ->
        %{route_status: "unavailable", failure_reason: "report-to-owner-mismatch"}
    end
  end

  defp record_parent_failure(_txn, _id, %{route_status: status}, _generation)
       when status != "unavailable",
       do: :ok

  defp record_parent_failure(txn, id, parent, generation) do
    if parent.foreign and is_binary(parent.session_key) do
      EventLog.lifecycle_in_txn(
        txn,
        "completion_escalation_cross_owner_lineage",
        id,
        "parentSessionKey=#{parent.session_key} principal=#{@process_principal}"
      )
    end

    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_undeliverable",
      id,
      "channel=parent resolution=parent-unavailable reason=#{parent.failure_reason} generation=#{generation} principal=#{@process_principal}"
    )
  end

  defp record_report_to_failure(_txn, _id, %{route_status: status}, _generation)
       when status != "unavailable",
       do: :ok

  defp record_report_to_failure(txn, id, route, generation) do
    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_undeliverable",
      id,
      "channel=report-to resolution=target-unresolvable reason=#{route.failure_reason} generation=#{generation} principal=#{@process_principal}"
    )
  end

  defp record_cross_owner_walk(_txn, _id, nil), do: :ok
  defp record_cross_owner_walk(_txn, _id, %{cross_owner_key: nil}), do: :ok

  defp record_cross_owner_walk(txn, id, %{cross_owner_key: key}) do
    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_cross_owner_lineage",
      id,
      "recipientPathSessionKey=#{key} principal=#{@process_principal}"
    )
  end

  defp record_owner_carrier_failure(_txn, _id, nil, _target, _generation), do: :ok

  defp record_owner_carrier_failure(_txn, _id, %{user_id: nil}, _target, _generation),
    do: :ok

  defp record_owner_carrier_failure(_txn, _id, _recipient, target, _generation)
       when is_binary(target),
       do: :ok

  defp record_owner_carrier_failure(txn, id, _recipient, nil, generation) do
    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_undeliverable",
      id,
      "channel=owner-root resolution=target-unresolvable reason=owner-carrier-unavailable generation=#{generation} principal=#{@process_principal}"
    )
  end

  defp record_recipient_failure(txn, row, generation) do
    key = row.current_recipient_session_key

    reason =
      case Txn.q(txn, "SELECT ownerUserId,state FROM sessions WHERE sessionKey=?1", [key]) do
        [] -> "recipient-missing"
        [[owner, _state]] when owner != row.owner_user_id -> "recipient-owner-mismatch"
        [[_owner, state]] when state != "active" -> "recipient-inactive"
        _ -> nil
      end

    if reason do
      EventLog.lifecycle_in_txn(
        txn,
        "completion_escalation_undeliverable",
        row.id,
        "channel=recipient resolution=recipient-ineligible reason=#{reason} generation=#{generation} principal=#{@process_principal}"
      )
    end
  end

  defp schedule_prompt(txn, wake_id, session_key, prompt, due_at) do
    Wakes.schedule_in_txn(txn, %{
      wake_id: wake_id,
      session_key: session_key,
      origin: "process:tightbeam",
      prompt: prompt,
      consumer: "prompt",
      due_at: due_at,
      target_gate: 1,
      assignment_id: nil,
      work_item_id: nil
    })
  end

  defp schedule_deadline(txn, wake_id, child, due_at) do
    Wakes.schedule_in_txn(txn, %{
      wake_id: wake_id,
      session_key: child,
      origin: "process:tightbeam",
      prompt: nil,
      consumer: @deadline_consumer,
      due_at: due_at,
      assignment_id: nil,
      work_item_id: nil
    })
  end

  defp insert_membership(
         txn,
         wake_id,
         completion_id,
         generation,
         kind,
         recipient_generation \\ nil,
         recipient_reissue_count \\ nil,
         recipient_session_key \\ nil,
         recipient_user_id \\ nil
       )

  defp insert_membership(
         _txn,
         nil,
         _completion_id,
         _generation,
         _kind,
         _recipient_generation,
         _recipient_reissue_count,
         _recipient_session_key,
         _recipient_user_id
       ),
       do: :ok

  defp insert_membership(
         txn,
         wake_id,
         completion_id,
         generation,
         kind,
         recipient_generation,
         recipient_reissue_count,
         recipient_session_key,
         recipient_user_id
       ) do
    Txn.q(
      txn,
      """
      INSERT INTO completion_escalation_wakes
        (wakeId, completionId, generation, kind, recipientGeneration,
         recipientReissueCount, recipientSessionKey, recipientUserId)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      """,
      [
        wake_id,
        completion_id,
        generation,
        kind,
        recipient_generation,
        recipient_reissue_count,
        recipient_session_key,
        recipient_user_id
      ]
    )
  end

  defp cancel_terminal_wakes!(txn, row) do
    command = terminal_cancel_command(row.id)
    cancel_if_pending!(txn, row.current_parent_notice_wake_id, command)
    cancel_if_pending!(txn, row.report_to_notice_wake_id, command)
    cancel_if_pending!(txn, row.deadline_wake_id, command)
  end

  defp cancel_replaced_parent!(_txn, nil, _replacement), do: :ok

  defp cancel_replaced_parent!(txn, wake_id, replacement) do
    command =
      if is_binary(replacement),
        do: replacement_cancel_command(replacement),
        else: target_unresolvable_command(@process_id, wake_id)

    cancel_if_pending!(txn, wake_id, command)
  end

  defp cancel_if_pending!(_txn, nil, _command), do: :ok

  defp cancel_if_pending!(txn, wake_id, command) do
    case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id]) do
      [["pending"]] -> cancel_wake!(txn, wake_id, command)
      [[state]] when state in ["fired", "canceled"] -> :ok
      [] -> raise("completion references missing wake #{wake_id}")
    end
  end

  defp cancel_wake!(txn, wake_id, command) do
    if Wakes.cancel_in_txn(txn, Map.put(command, :wake_id, wake_id)) != true,
      do: raise("completion wake cancellation refused: #{wake_id}")

    :ok
  end

  defp terminal_cancel_command(completion_id) do
    %{
      requester: %{kind: "process", id: @process_id},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "completion_transition", id: completion_id},
      outcome: %{
        kind: "disposition",
        disposition_kind: "completion_transition",
        disposition_id: completion_id
      }
    }
  end

  defp replacement_cancel_command(replacement_wake_id) do
    %{
      requester: %{kind: "process", id: @process_id},
      reason_kind: "superseded",
      causal_source: %{kind: "wake", id: replacement_wake_id},
      outcome: %{kind: "replacement", replacement_wake_id: replacement_wake_id}
    }
  end

  defp target_unresolvable_command(requester_id, wake_id) do
    %{
      requester: %{kind: "process", id: requester_id},
      reason_kind: "target_unresolvable",
      causal_source: %{kind: "scheduler_delivery", id: wake_id},
      outcome: %{kind: "no_replacement"}
    }
  end

  defp fire_deadline!(txn, wake_id) do
    if not Wakes.fire_internal_in_txn(txn, wake_id, @deadline_consumer, now()),
      do: raise("completion deadline fire refused: #{wake_id}")

    :ok
  end

  defp parent_prompt(
         id,
         assignment,
         terminal,
         immediate_parent,
         resolution_source,
         parent,
         report_to,
         remaining,
         root,
         recipient,
         recipient_generation,
         recipient_reissue_count,
         recipient_reissue_limit
       ) do
    action_needed = remaining == 0

    body =
      if action_needed do
        """
        Child assignment slate became empty.
        completionId=#{id}
        assignmentId=#{assignment.id}
        workItemId=#{assignment.workItemId || "none"}
        childSessionKey=#{assignment.holderKey}
        causeKind=#{terminal.kind}
        causeId=#{terminal.id}
        closingAttestId=#{terminal.closing_attest_id || "none"}
        revocationId=#{terminal.revocation_id || "none"}
        outcome=#{terminal.outcome}
        causePrincipal=#{terminal.principal}
        immediateParentSessionKey=#{immediate_parent}
        parentResolutionSource=#{resolution_source}
        parentRoute=#{parent_route_label(parent.route_status)}
        reportToSessionKey=#{report_to || "none"}
        remainingOpenAssignments=#{remaining}
        actionNeeded=true
        recipientPrincipal=#{recipient_principal(recipient)}
        recipientGeneration=#{recipient_generation}
        recipientReissueCount=#{recipient_reissue_count}
        recipientReissueLimit=#{recipient_reissue_limit}
        """
        |> String.trim_trailing()
      else
        """
        Child completion recorded.
        completionId=#{id}
        assignmentId=#{assignment.id}
        workItemId=#{assignment.workItemId || "none"}
        childSessionKey=#{assignment.holderKey}
        closingAttestId=#{terminal.closing_attest_id}
        outcome=completed
        causePrincipal=#{terminal.principal}
        immediateParentSessionKey=#{immediate_parent}
        parentResolutionSource=#{resolution_source}
        parentRoute=#{parent_route_label(parent.route_status)}
        reportToSessionKey=#{report_to || "none"}
        remainingOpenAssignments=#{remaining}
        actionNeeded=false
        """
        |> String.trim_trailing()
      end

    cond do
      not action_needed ->
        body

      root ->
        body <>
          "\nChoose retain with `tightbeam completion-disposition #{id} --decision retain`. Tightbeam will not choose or auto-retain."

      true ->
        body <>
          "\nChoose retain, park, or retire with `tightbeam completion-disposition #{id} --decision <retain|park|retire>`. Tightbeam will not choose or auto-retire."
    end
  end

  defp report_to_prompt(
         id,
         assignment,
         terminal,
         immediate_parent,
         resolution_source,
         parent,
         report_to,
         remaining
       ) do
    """
    Child completion copied by explicit report-to.
    completionId=#{id}
    assignmentId=#{assignment.id}
    workItemId=#{assignment.workItemId || "none"}
    childSessionKey=#{assignment.holderKey}
    closingAttestId=#{terminal.closing_attest_id}
    outcome=completed
    causePrincipal=#{terminal.principal}
    immediateParentSessionKey=#{immediate_parent}
    parentResolutionSource=#{resolution_source}
    parentRoute=#{parent_route_label(parent.route_status)}
    reportToSessionKey=#{report_to}
    remainingOpenAssignments=#{remaining}
    actionNeeded=#{remaining == 0}
    This report is informational. It grants no disposition authority.
    """
    |> String.trim_trailing()
  end

  defp parent_route_label("scheduled"), do: "effective-parent"
  defp parent_route_label("unavailable"), do: "parent-unavailable"
  defp parent_route_label("root-self"), do: "root-self"

  defp open_row_for_child(txn, child) do
    case Txn.q(
           txn,
           "SELECT #{columns()} FROM completion_escalations WHERE childSessionKey=?1 AND status='open'",
           [child]
         ) do
      [raw] -> row(raw)
      [] -> nil
    end
  end

  defp fetch_by_deadline_in_txn(txn, wake_id) do
    case Txn.q(
           txn,
           "SELECT #{columns("ce")} FROM completion_escalations ce WHERE ce.deadlineWakeId=?1",
           [wake_id]
         ) do
      [raw] -> row(raw)
      [] -> nil
    end
  end

  defp fetch_in_txn(txn, completion_id) do
    case Txn.q(txn, "SELECT #{columns()} FROM completion_escalations WHERE id=?1", [completion_id]) do
      [raw] -> row(raw)
      [] -> nil
    end
  end

  defp fetch_in_txn!(txn, completion_id),
    do: fetch_in_txn(txn, completion_id) || raise("missing completion #{completion_id}")

  defp delivery_row(txn, wake_id) do
    case Txn.q(
           txn,
           """
           SELECT #{columns("ce")}, cew.generation, cew.kind,
                  cew.recipientGeneration, cew.recipientReissueCount,
                  cew.recipientSessionKey, cew.recipientUserId, w.state, w.wakeId
           FROM completion_escalation_wakes cew
           JOIN completion_escalations ce ON ce.id=cew.completionId
           JOIN wakes w ON w.wakeId=cew.wakeId
           WHERE cew.wakeId=?1
           """,
           [wake_id]
         ) do
      [raw] ->
        {completion_raw,
         [
           wake_generation,
           kind,
           member_recipient_generation,
           member_reissue_count,
           member_session_key,
           member_user_id,
           wake_state,
           id
         ]} =
          Enum.split(raw, length(column_names()))

        completion_raw
        |> row()
        |> Map.merge(%{
          wake_generation: wake_generation,
          kind: kind,
          member_recipient_generation: member_recipient_generation,
          member_reissue_count: member_reissue_count,
          member_session_key: member_session_key,
          member_user_id: member_user_id,
          wake_state: wake_state,
          wake_id: id
        })

      [] ->
        nil
    end
  end

  defp oldest_open_assignment(txn, child) do
    case Txn.q(
           txn,
           "SELECT id FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY openedAt,id LIMIT 1",
           [child]
         ) do
      [[id]] -> %{id: id}
      [] -> nil
    end
  end

  defp assignment_for_prompt(txn, id) do
    [[assignment_id, work_item_id, holder_key, report_to]] =
      Txn.q(
        txn,
        "SELECT id,workItemId,holderKey,completionReportToSessionKey FROM assignments WHERE id=?1",
        [id]
      )

    %{
      id: assignment_id,
      workItemId: work_item_id,
      holderKey: holder_key,
      reportToSessionKey: report_to
    }
  end

  defp visible?(db, row, {:user, user}) do
    row.owner_user_id == user or admin_user?(db, user)
  end

  defp visible?(db, row, {:session, session}) do
    active_owner_session?(db, session, row.owner_user_id) and
      (session == row.child_session_key or
         session == row.report_to_session_key or
         (row.status == "notice-only" and session == row.parent_session_key) or
         (row.status == "open" and session == row.current_recipient_session_key) or
         (row.status in ["acknowledged", "retained_root"] and
            session == row.acted_by_session))
  end

  defp visible?(_db, _row, _principal), do: false

  defp project(db, row) do
    parent_receipt = receipt(db, initial_parent_wake_id(db, row))
    request_receipt = receipt(db, row.current_parent_notice_wake_id)

    report_to =
      case row.report_to_route_status do
        "not-declared" ->
          nil

        status ->
          shared = status == "shared-parent"

          %{
            sessionKey: row.report_to_session_key,
            routeStatus: status,
            sharesParentNotice: shared,
            receipt:
              if(shared,
                do: parent_receipt,
                else: receipt(db, row.report_to_notice_wake_id)
              )
          }
      end

    %{
      id: row.id,
      dedupeKey: row.dedupe_key,
      causeKind: row.cause_kind,
      causeId: row.cause_id,
      assignmentId: row.assignment_id,
      workItemId: row.work_item_id,
      childSessionKey: row.child_session_key,
      rootMainHolder: row.root_main_holder,
      closingAttestId: row.closing_attest_id,
      revocationId: row.revocation_id,
      outcome: row.outcome,
      remainingOpenAssignments: row.remaining_open_assignments,
      cause: %{
        bySession: row.cause_by_session,
        byUser: row.cause_by_user,
        principal:
          if(row.cause_by_session,
            do: "session:#{row.cause_by_session}",
            else: "user:#{row.cause_by_user}"
          )
      },
      routing: %{
        parent: %{
          sessionKey: row.parent_session_key,
          resolutionSource: row.parent_resolution_source,
          routeStatus: row.parent_route_status,
          receipt: parent_receipt
        },
        reportTo: report_to
      },
      request: %{
        status: row.status,
        decision: row.decision,
        deadlineAt: row.action_deadline_at,
        generation: row.generation,
        currentRecipient: current_recipient_principal(row),
        recipientGeneration: row.recipient_generation,
        recipientReissueCount: row.recipient_reissue_count,
        recipientReissueLimit: row.recipient_reissue_limit,
        receipt: request_receipt,
        actedBySession: row.acted_by_session,
        actedByUser: row.acted_by_user,
        actedAt: row.acted_at,
        supersededReason: row.superseded_reason,
        supersededByAssignmentId: row.superseded_by_assignment_id,
        supersededAt: row.superseded_at
      },
      createdAt: row.created_at
    }
  end

  defp initial_parent_wake_id(db, row) do
    case DB.query(
           db,
           """
           SELECT wakeId FROM completion_escalation_wakes
           WHERE completionId=?1 AND kind='parent-notice' AND generation=0
             AND recipientSessionKey=?2
           LIMIT 1
           """,
           [row.id, row.parent_session_key]
         ) do
      {:ok, [[wake_id]]} -> wake_id
      _ -> nil
    end
  end

  defp current_recipient_principal(%{current_recipient_session_key: key}) when is_binary(key),
    do: "session:#{key}"

  defp current_recipient_principal(%{current_recipient_user_id: user}) when is_binary(user),
    do: "user:#{user}"

  defp current_recipient_principal(_row), do: nil

  defp receipt(_db, nil), do: %{state: "not-created", turnSeq: nil}

  defp receipt(db, wake_id) do
    case DB.query(
           db,
           """
           SELECT w.state, t.seq, t.status
           FROM wakes w
           LEFT JOIN turns t ON t.wakeId=w.wakeId
           WHERE w.wakeId=?1
           """,
           [wake_id]
         ) do
      {:ok, [[_wake_state, seq, status]]} when not is_nil(seq) ->
        %{state: status, turnSeq: seq}

      {:ok, [["pending", nil, nil]]} ->
        %{state: "pending", turnSeq: nil}

      {:ok, [["canceled", nil, nil]]} ->
        %{state: "canceled", turnSeq: nil}

      {:ok, [["fired", nil, nil]]} ->
        %{state: "inconsistent", turnSeq: nil}

      _ ->
        %{state: "not-created", turnSeq: nil}
    end
  end

  defp authorized_in_txn?(_txn, row, {:user, user}), do: row.owner_user_id == user

  defp authorized_in_txn?(txn, row, {:session, session}) do
    active_owner_session?(txn, session, row.owner_user_id) and
      session == row.current_recipient_session_key and
      (session != row.child_session_key or root_main_now?(txn, row))
  end

  defp authorized_in_txn?(_txn, _row, _principal), do: false

  defp identical_replay?(row, decision, {:session, session}),
    do: row.decision == decision and row.acted_by_session == session

  defp identical_replay?(row, decision, {:user, user}),
    do: row.decision == decision and row.acted_by_user == user

  defp identical_replay?(_row, _decision, _principal), do: false

  defp replay_principal_current?(txn, row, {:session, session}),
    do: active_owner_session?(txn, session, row.owner_user_id)

  defp replay_principal_current?(txn, row, {:user, user}),
    do:
      row.owner_user_id == user and
        Txn.q(txn, "SELECT 1 FROM users WHERE userId=?1", [user]) == [[1]]

  defp replay_principal_current?(_txn, _row, _principal), do: false

  defp root_main_now?(txn, row) do
    row.root_main_holder and row.child_session_key == Org.personal_session_key(row.owner_user_id) and
      Txn.q(
        txn,
        "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active' AND isBuiltIn=1 AND kind='main'",
        [row.child_session_key, row.owner_user_id]
      ) == [[1]]
  end

  defp child_active?(txn, child),
    do: Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [child]) == [["active"]]

  defp active_owner_session?(%Txn{} = txn, key, owner),
    do:
      is_binary(key) and
        Txn.q(
          txn,
          "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
          [key, owner]
        ) == [[1]]

  defp active_owner_session?(db, key, owner) do
    is_binary(key) and
      DB.query(
        db,
        "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
        [key, owner]
      ) == {:ok, [[1]]}
  end

  defp admin_user?(db, user),
    do: DB.query(db, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == {:ok, [[1]]}

  defp principal_kind_allowed?({kind, _}) when kind in [:session, :user], do: true
  defp principal_kind_allowed?(_), do: false

  defp acting_columns({:session, session}), do: {session, nil}
  defp acting_columns({:user, user}), do: {nil, user}

  def principal_string({:session, session}), do: "session:#{session}"
  def principal_string({:user, user}), do: "user:#{user}"
  def principal_string(_), do: "unknown"

  defp columns(alias_name \\ nil) do
    prefix = if alias_name, do: alias_name <> ".", else: ""

    column_names()
    |> Enum.map_join(",", &(prefix <> &1))
  end

  defp column_names do
    ~w(id dedupeKey causeKind causeId assignmentId workItemId childSessionKey remainingOpenAssignments
       closingAttestId revocationId outcome causeBySession causeByUser ownerUserId rootMainHolder
       immediateParentSessionKey parentSessionKey parentResolutionSource parentRouteStatus reportToSessionKey
       reportToRouteStatus generation currentRecipientSessionKey currentRecipientUserId
       recipientGeneration recipientReissueCount recipientReissueLimit
       currentParentNoticeWakeId reportToNoticeWakeId
       deadlineWakeId actionDeadlineAt status decision actedBySession actedByUser actedAt
       supersededReason supersededByAssignmentId supersededAt createdAt)
  end

  defp row([
         id,
         dedupe_key,
         cause_kind,
         cause_id,
         assignment_id,
         work_item_id,
         child_session_key,
         remaining_open_assignments,
         closing_attest_id,
         revocation_id,
         outcome,
         cause_by_session,
         cause_by_user,
         owner_user_id,
         root_main_holder,
         immediate_parent_session_key,
         parent_session_key,
         parent_resolution_source,
         parent_route_status,
         report_to_session_key,
         report_to_route_status,
         generation,
         current_recipient_session_key,
         current_recipient_user_id,
         recipient_generation,
         recipient_reissue_count,
         recipient_reissue_limit,
         current_parent_notice_wake_id,
         report_to_notice_wake_id,
         deadline_wake_id,
         action_deadline_at,
         status,
         decision,
         acted_by_session,
         acted_by_user,
         acted_at,
         superseded_reason,
         superseded_by_assignment_id,
         superseded_at,
         created_at
       ]) do
    %{
      id: id,
      dedupe_key: dedupe_key,
      cause_kind: cause_kind,
      cause_id: cause_id,
      assignment_id: assignment_id,
      work_item_id: work_item_id,
      child_session_key: child_session_key,
      remaining_open_assignments: remaining_open_assignments,
      closing_attest_id: closing_attest_id,
      revocation_id: revocation_id,
      outcome: outcome,
      cause_by_session: cause_by_session,
      cause_by_user: cause_by_user,
      owner_user_id: owner_user_id,
      root_main_holder: root_main_holder == 1,
      immediate_parent_session_key: immediate_parent_session_key,
      parent_session_key: parent_session_key,
      parent_resolution_source: parent_resolution_source,
      parent_route_status: parent_route_status,
      report_to_session_key: report_to_session_key,
      report_to_route_status: report_to_route_status,
      generation: generation,
      current_recipient_session_key: current_recipient_session_key,
      current_recipient_user_id: current_recipient_user_id,
      recipient_generation: recipient_generation,
      recipient_reissue_count: recipient_reissue_count,
      recipient_reissue_limit: recipient_reissue_limit,
      current_parent_notice_wake_id: current_parent_notice_wake_id,
      report_to_notice_wake_id: report_to_notice_wake_id,
      deadline_wake_id: deadline_wake_id,
      action_deadline_at: action_deadline_at,
      status: status,
      decision: decision,
      acted_by_session: acted_by_session,
      acted_by_user: acted_by_user,
      acted_at: acted_at,
      superseded_reason: superseded_reason,
      superseded_by_assignment_id: superseded_by_assignment_id,
      superseded_at: superseded_at,
      created_at: created_at
    }
  end

  defp wake_id("attest:" <> attest_id, "report-to-notice", _generation),
    do: "completion:attest:#{attest_id}:report-to-notice"

  defp wake_id(cause_token, kind, generation),
    do: "completion:#{cause_token}:#{kind}:#{generation}"

  defp terminal_cause!("attest", attest, child) do
    %{
      kind: "attest",
      id: attest.id,
      token: "attest:#{attest.id}",
      closing_attest_id: attest.id,
      revocation_id: nil,
      outcome: "completed",
      by_session: child,
      by_user: nil,
      principal: "session:#{child}"
    }
  end

  defp terminal_cause!("revocation", revocation, _child) do
    {by_session, by_user, principal} =
      case {revocation[:by_session], revocation[:by_user]} do
        {session, nil} when is_binary(session) -> {session, nil, "session:#{session}"}
        {nil, user} when is_binary(user) -> {nil, user, "user:#{user}"}
        _ -> raise("revocation cause requires one typed principal")
      end

    %{
      kind: "revocation",
      id: revocation.id,
      token: "revocation:#{revocation.id}",
      closing_attest_id: nil,
      revocation_id: revocation.id,
      outcome: "revoked",
      by_session: by_session,
      by_user: by_user,
      principal: principal
    }
  end

  defp terminal_from_row(row) do
    %{
      kind: row.cause_kind,
      id: row.cause_id,
      token: cause_token(row),
      closing_attest_id: row.closing_attest_id,
      revocation_id: row.revocation_id,
      outcome: row.outcome,
      by_session: row.cause_by_session,
      by_user: row.cause_by_user,
      principal:
        if(row.cause_by_session,
          do: "session:#{row.cause_by_session}",
          else: "user:#{row.cause_by_user}"
        )
    }
  end

  defp cause_token(row), do: "#{row.cause_kind}:#{row.cause_id}"

  defp recipient_principal(%{session_key: key}) when is_binary(key), do: "session:#{key}"
  defp recipient_principal(%{user_id: user}) when is_binary(user), do: "user:#{user}"

  defp recipient_reissue_limit! do
    case Application.get_env(:tightbeam, :prod_limit, 3) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _ -> raise("tightbeam :prod_limit must be a non-negative integer")
    end
  end

  defp deadline_ms,
    do:
      Application.get_env(
        :tightbeam,
        :completion_disposition_deadline_ms,
        @default_deadline_ms
      )

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0
  defp error(code, message), do: %{code: code, message: message}
  defp now, do: System.system_time(:millisecond)
end
