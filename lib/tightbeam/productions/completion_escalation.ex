defmodule Tightbeam.Productions.CompletionEscalation do
  @moduledoc "Durable exact-parent completion notices and explicit lifecycle disposition."

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
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    workItemId TEXT NULL REFERENCES work_items(id),
    childSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    remainingOpenAssignments INTEGER NOT NULL CHECK (remainingOpenAssignments >= 0),
    closingAttestId TEXT NOT NULL UNIQUE REFERENCES attests(id),
    outcome TEXT NOT NULL CHECK (outcome = 'completed'),
    causeBySession TEXT NOT NULL REFERENCES sessions(sessionKey),
    ownerUserId TEXT NOT NULL REFERENCES users(userId),
    rootMainHolder INTEGER NOT NULL CHECK (rootMainHolder IN (0,1)),
    immediateParentSessionKey TEXT NULL,
    parentSessionKey TEXT NULL,
    parentRouteStatus TEXT NOT NULL CHECK (
      parentRouteStatus IN ('scheduled','unavailable','root-self')
    ),
    reportToSessionKey TEXT NULL REFERENCES sessions(sessionKey),
    reportToRouteStatus TEXT NOT NULL CHECK (
      reportToRouteStatus IN ('not-declared','scheduled','shared-parent','unavailable')
    ),
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    currentParentNoticeWakeId TEXT NULL UNIQUE REFERENCES wakes(wakeId),
    reportToNoticeWakeId TEXT NULL UNIQUE REFERENCES wakes(wakeId),
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
      (parentRouteStatus = 'scheduled' AND rootMainHolder = 0
        AND parentSessionKey IS NOT NULL
        AND parentSessionKey IS immediateParentSessionKey
        AND currentParentNoticeWakeId IS NOT NULL)
      OR
      (parentRouteStatus = 'unavailable' AND rootMainHolder = 0
        AND parentSessionKey IS immediateParentSessionKey
        AND currentParentNoticeWakeId IS NULL)
      OR
      (parentRouteStatus = 'root-self' AND rootMainHolder = 1
        AND parentSessionKey = childSessionKey
        AND currentParentNoticeWakeId IS NOT NULL)
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
  CREATE INDEX IF NOT EXISTS completion_escalations_assignment
    ON completion_escalations(assignmentId);
  CREATE UNIQUE INDEX IF NOT EXISTS completion_escalations_one_open_child
    ON completion_escalations(childSessionKey) WHERE status = 'open';

  CREATE TABLE IF NOT EXISTS completion_escalation_wakes (
    wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
    completionId TEXT NOT NULL REFERENCES completion_escalations(id),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('parent-notice','report-to-notice','deadline')),
    UNIQUE (completionId, generation, kind)
  );
  CREATE INDEX IF NOT EXISTS completion_escalation_wakes_completion
    ON completion_escalation_wakes(completionId, generation, kind);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Create one completion record and its admitted wakes in the assignment close transaction."
  @spec open_in_txn(Txn.t(), map(), map()) :: map()
  def open_in_txn(%Txn{} = txn, assignment, attest) do
    child = assignment.holderKey

    [[owner, spawned_by, built_in]] =
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
    parent = parent_route(txn, child, owner, spawned_by, root_main)
    report_to_key = assignment.reportToSessionKey
    report_to = report_to_route(txn, report_to_key, owner, parent)
    completion_id = "cn_" <> Tightbeam.Id.uuid4()
    generation = 0
    created_at = now()
    action_needed = remaining == 0
    status = if(action_needed, do: "open", else: "notice-only")
    deadline_at = if(action_needed, do: created_at + deadline_ms())

    parent_wake_id =
      if parent.route_status in ["scheduled", "root-self"] do
        id = wake_id(attest.id, "parent-notice", generation)

        schedule_prompt(
          txn,
          id,
          parent.session_key,
          parent_prompt(
            completion_id,
            assignment,
            attest,
            spawned_by,
            parent,
            report_to_key,
            remaining,
            root_main
          ),
          created_at
        )

        id
      end

    report_to_wake_id =
      if report_to.route_status == "scheduled" do
        id = wake_id(attest.id, "report-to-notice", generation)

        schedule_prompt(
          txn,
          id,
          report_to_key,
          report_to_prompt(
            completion_id,
            assignment,
            attest,
            spawned_by,
            parent,
            report_to_key,
            remaining
          ),
          created_at
        )

        id
      end

    deadline_wake_id =
      if action_needed do
        id = wake_id(attest.id, "deadline", generation)
        schedule_deadline(txn, id, child, deadline_at)
        id
      end

    Txn.q(
      txn,
      """
      INSERT INTO completion_escalations
        (id, dedupeKey, assignmentId, workItemId, childSessionKey,
         remainingOpenAssignments, closingAttestId, outcome, causeBySession,
         ownerUserId, rootMainHolder, immediateParentSessionKey, parentSessionKey,
         parentRouteStatus, reportToSessionKey, reportToRouteStatus, generation,
         currentParentNoticeWakeId, reportToNoticeWakeId, deadlineWakeId,
         actionDeadlineAt, status, createdAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'completed', ?8, ?9, ?10, ?11, ?12,
              ?13, ?14, ?15, 0, ?16, ?17, ?18, ?19, ?20, ?21)
      """,
      [
        completion_id,
        "completion:" <> attest.id,
        assignment.id,
        assignment.workItemId,
        child,
        remaining,
        attest.id,
        child,
        owner,
        bool_int(root_main),
        if(root_main, do: nil, else: spawned_by),
        parent.session_key,
        parent.route_status,
        report_to_key,
        report_to.route_status,
        parent_wake_id,
        report_to_wake_id,
        deadline_wake_id,
        deadline_at,
        status,
        created_at
      ]
    )

    insert_membership(txn, parent_wake_id, completion_id, generation, "parent-notice")
    insert_membership(txn, report_to_wake_id, completion_id, generation, "report-to-notice")
    insert_membership(txn, deadline_wake_id, completion_id, generation, "deadline")

    EventLog.lifecycle_in_txn(txn, "completion_escalation_opened", completion_id, nil)
    record_parent_failure(txn, completion_id, parent, generation)
    record_report_to_failure(txn, completion_id, report_to, generation)
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
        {:error, error("not_authorized", "the exact completion parent or owner user is required")}

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
          actedAt=?6, deadlineWakeId=NULL
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
          supersededAt=?4, deadlineWakeId=NULL
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
    deadline_at = at + deadline_ms()
    parent = current_parent_route(txn, row)
    deadline_id = wake_id(row.closing_attest_id, "deadline", generation)

    parent_id =
      if parent.route_status in ["scheduled", "root-self"],
        do: wake_id(row.closing_attest_id, "parent-notice", generation)

    if parent_id do
      assignment = assignment_for_prompt(txn, row.assignment_id)
      attest = attest_for_prompt(txn, row.closing_attest_id)

      schedule_prompt(
        txn,
        parent_id,
        parent.session_key,
        parent_prompt(
          row.id,
          assignment,
          attest,
          row.immediate_parent_session_key,
          parent,
          row.report_to_session_key,
          0,
          row.root_main_holder
        ),
        at
      )
    end

    schedule_deadline(txn, deadline_id, row.child_session_key, deadline_at)
    insert_membership(txn, parent_id, row.id, generation, "parent-notice")
    insert_membership(txn, deadline_id, row.id, generation, "deadline")

    EventLog.lifecycle_in_txn(
      txn,
      "completion_escalation_reissued",
      row.id,
      "generation=#{generation} principal=#{@process_principal}"
    )

    cancel_replaced_parent!(txn, row.current_parent_notice_wake_id, parent_id)

    Txn.q(
      txn,
      """
      UPDATE completion_escalations
      SET generation=?2, parentRouteStatus=?3, currentParentNoticeWakeId=?4,
          deadlineWakeId=?5, actionDeadlineAt=?6
      WHERE id=?1 AND status='open' AND deadlineWakeId=?7
      """,
      [
        row.id,
        generation,
        parent.route_status,
        parent_id,
        deadline_id,
        deadline_at,
        row.deadline_wake_id
      ]
    )

    if Txn.changes(txn) != 1, do: raise("completion reissue race")
    record_parent_failure(txn, row.id, parent, generation)
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

          channel = if(row.kind == "parent-notice", do: "parent", else: "report-to")

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
    current? =
      case row.kind do
        "parent-notice" -> row.current_parent_notice_wake_id == row.wake_id
        "report-to-notice" -> row.report_to_notice_wake_id == row.wake_id
      end

    target =
      if(row.kind == "parent-notice", do: row.parent_session_key, else: row.report_to_session_key)

    declaration_current? =
      row.kind == "parent-notice" or
        Txn.q(
          txn,
          "SELECT completionReportToSessionKey FROM assignments WHERE id=?1",
          [row.assignment_id]
        ) == [[row.report_to_session_key]]

    row.wake_state == "pending" and row.status in ["open", "notice-only"] and current? and
      requested_session_key == target and declaration_current? and
      active_owner_session?(txn, target, row.owner_user_id)
  end

  defp parent_route(_txn, child, _owner, _spawned_by, true),
    do: %{session_key: child, route_status: "root-self", failure_reason: nil, foreign: false}

  defp parent_route(txn, _child, owner, spawned_by, false) do
    cond do
      is_nil(spawned_by) ->
        unavailable_parent(nil, "parent-missing")

      true ->
        case Txn.q(
               txn,
               "SELECT ownerUserId, state FROM sessions WHERE sessionKey=?1",
               [spawned_by]
             ) do
          [] -> unavailable_parent(spawned_by, "parent-missing")
          [[^owner, "active"]] -> scheduled_parent(spawned_by)
          [[^owner, _state]] -> unavailable_parent(spawned_by, "parent-inactive")
          [[_foreign, _state]] -> unavailable_parent(spawned_by, "parent-owner-mismatch", true)
        end
    end
  end

  defp current_parent_route(txn, %{root_main_holder: true} = row),
    do: parent_route(txn, row.child_session_key, row.owner_user_id, nil, true)

  defp current_parent_route(txn, row),
    do:
      parent_route(
        txn,
        row.child_session_key,
        row.owner_user_id,
        row.parent_session_key,
        false
      )

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

  defp insert_membership(_txn, nil, _completion_id, _generation, _kind), do: :ok

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

  defp parent_prompt(id, assignment, attest, immediate_parent, parent, report_to, remaining, root) do
    action_needed = remaining == 0

    body =
      """
      Child completion recorded.
      completionId=#{id}
      assignmentId=#{assignment.id}
      workItemId=#{assignment.workItemId || "none"}
      childSessionKey=#{assignment.holderKey}
      closingAttestId=#{attest.id}
      outcome=completed
      causePrincipal=session:#{assignment.holderKey}
      immediateParentSessionKey=#{immediate_parent || "none"}
      parentRoute=#{parent_route_label(parent.route_status)}
      reportToSessionKey=#{report_to || "none"}
      remainingOpenAssignments=#{remaining}
      actionNeeded=#{action_needed}
      """
      |> String.trim_trailing()

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

  defp report_to_prompt(id, assignment, attest, immediate_parent, parent, report_to, remaining) do
    """
    Child completion copied by explicit report-to.
    completionId=#{id}
    assignmentId=#{assignment.id}
    workItemId=#{assignment.workItemId || "none"}
    childSessionKey=#{assignment.holderKey}
    closingAttestId=#{attest.id}
    outcome=completed
    causePrincipal=session:#{assignment.holderKey}
    immediateParentSessionKey=#{immediate_parent || "none"}
    parentRoute=#{parent_route_label(parent.route_status)}
    reportToSessionKey=#{report_to}
    remainingOpenAssignments=#{remaining}
    actionNeeded=#{remaining == 0}
    This report is informational. Only the exact completion parent target or owner user can choose a disposition.
    """
    |> String.trim_trailing()
  end

  defp parent_route_label("scheduled"), do: "spawnedBy"
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
           SELECT #{columns("ce")}, cew.generation, cew.kind, w.state, w.wakeId
           FROM completion_escalation_wakes cew
           JOIN completion_escalations ce ON ce.id=cew.completionId
           JOIN wakes w ON w.wakeId=cew.wakeId
           WHERE cew.wakeId=?1
           """,
           [wake_id]
         ) do
      [raw] ->
        {completion_raw, [wake_generation, kind, wake_state, id]} = Enum.split(raw, 30)

        completion_raw
        |> row()
        |> Map.merge(%{
          wake_generation: wake_generation,
          kind: kind,
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

  defp attest_for_prompt(txn, id) do
    [[attest_id, by_session]] =
      Txn.q(txn, "SELECT id,bySession FROM attests WHERE id=?1", [id])

    %{id: attest_id, bySession: by_session}
  end

  defp visible?(db, row, {:user, user}) do
    row.owner_user_id == user or admin_user?(db, user)
  end

  defp visible?(db, row, {:session, session}) do
    active_owner_session?(db, session, row.owner_user_id) and
      session in [
        row.child_session_key,
        row.parent_session_key,
        row.report_to_session_key,
        row.acted_by_session
      ]
  end

  defp visible?(_db, _row, _principal), do: false

  defp project(db, row) do
    parent_receipt = receipt(db, row.current_parent_notice_wake_id)

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
      assignmentId: row.assignment_id,
      workItemId: row.work_item_id,
      childSessionKey: row.child_session_key,
      rootMainHolder: row.root_main_holder,
      closingAttestId: row.closing_attest_id,
      outcome: "completed",
      remainingOpenAssignments: row.remaining_open_assignments,
      cause: %{
        bySession: row.cause_by_session,
        principal: "session:#{row.cause_by_session}"
      },
      routing: %{
        parent: %{
          sessionKey: row.parent_session_key,
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
      ((row.root_main_holder and session == row.child_session_key and
          session == row.parent_session_key) or
         (session != row.child_session_key and session == row.parent_session_key))
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
        "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND isBuiltIn=1",
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

    ~w(id dedupeKey assignmentId workItemId childSessionKey remainingOpenAssignments
       closingAttestId outcome causeBySession ownerUserId rootMainHolder
       immediateParentSessionKey parentSessionKey parentRouteStatus reportToSessionKey
       reportToRouteStatus generation currentParentNoticeWakeId reportToNoticeWakeId
       deadlineWakeId actionDeadlineAt status decision actedBySession actedByUser actedAt
       supersededReason supersededByAssignmentId supersededAt createdAt)
    |> Enum.map_join(",", &(prefix <> &1))
  end

  defp row([
         id,
         dedupe_key,
         assignment_id,
         work_item_id,
         child_session_key,
         remaining_open_assignments,
         closing_attest_id,
         _outcome,
         cause_by_session,
         owner_user_id,
         root_main_holder,
         immediate_parent_session_key,
         parent_session_key,
         parent_route_status,
         report_to_session_key,
         report_to_route_status,
         generation,
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
      assignment_id: assignment_id,
      work_item_id: work_item_id,
      child_session_key: child_session_key,
      remaining_open_assignments: remaining_open_assignments,
      closing_attest_id: closing_attest_id,
      cause_by_session: cause_by_session,
      owner_user_id: owner_user_id,
      root_main_holder: root_main_holder == 1,
      immediate_parent_session_key: immediate_parent_session_key,
      parent_session_key: parent_session_key,
      parent_route_status: parent_route_status,
      report_to_session_key: report_to_session_key,
      report_to_route_status: report_to_route_status,
      generation: generation,
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

  defp wake_id(attest_id, "report-to-notice", _generation),
    do: "completion:#{attest_id}:report-to-notice"

  defp wake_id(attest_id, kind, generation),
    do: "completion:#{attest_id}:#{kind}:#{generation}"

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
