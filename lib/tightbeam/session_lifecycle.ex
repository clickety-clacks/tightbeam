defmodule Tightbeam.SessionLifecycle do
  @moduledoc "Durable reversible PARK requests, outcomes, recovery, and same-session relaunch."

  alias Tightbeam.{DB, EventLog, Id, Org}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS session_lifecycle_states (
    sessionKey TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
    state TEXT NOT NULL CHECK (state IN ('active','parking','parked','retired')),
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    requestId TEXT,
    updatedAt INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS park_requests (
    requestId TEXT PRIMARY KEY,
    idempotencyKey TEXT NOT NULL,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    sessionGeneration INTEGER NOT NULL CHECK (sessionGeneration >= 1),
    principalKind TEXT NOT NULL CHECK (principalKind IN ('user','session','process')),
    principalId TEXT NOT NULL,
    authorityBasis TEXT NOT NULL CHECK (authorityBasis IN (
      'self_session','owner_user','administrator','completion_disposition',
      'harness_health_recovery','operator'
    )),
    policyBasis TEXT NOT NULL CHECK (policyBasis IN (
      'self_request','owner_request','administrator_request','operator_request',
      'completion_r11','harness_health_incident','retry_request'
    )),
    evidenceKind TEXT CHECK (evidenceKind IN (
      'completion_escalation','harness_health_observation'
    )),
    evidenceId TEXT,
    mode TEXT NOT NULL CHECK (mode IN ('graceful','immediate')),
    causeKind TEXT NOT NULL CHECK (causeKind IN (
      'manual','completion','harness_health_recovery','retry'
    )),
    causeId TEXT NOT NULL,
    retryOfRequestId TEXT REFERENCES park_requests(requestId),
    status TEXT NOT NULL CHECK (status = 'accepted'),
    acceptedAt INTEGER NOT NULL,
    UNIQUE (principalKind, principalId, sessionKey, idempotencyKey),
    CHECK (
      (causeKind = 'retry' AND retryOfRequestId IS NOT NULL AND causeId = retryOfRequestId)
      OR (causeKind != 'retry' AND retryOfRequestId IS NULL)
    ),
    CHECK (
      authorityBasis = 'completion_disposition' AND policyBasis = 'completion_r11'
        AND evidenceKind = 'completion_escalation' AND evidenceId IS NOT NULL
      OR authorityBasis = 'harness_health_recovery'
        AND policyBasis = 'harness_health_incident'
        AND evidenceKind = 'harness_health_observation' AND evidenceId IS NOT NULL
      OR authorityBasis NOT IN ('completion_disposition','harness_health_recovery')
        AND evidenceKind IS NULL AND evidenceId IS NULL
    )
  );
  CREATE INDEX IF NOT EXISTS park_requests_session
    ON park_requests(sessionKey, acceptedAt, requestId);

  CREATE TABLE IF NOT EXISTS park_outcomes (
    requestId TEXT PRIMARY KEY REFERENCES park_requests(requestId),
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    sessionGeneration INTEGER NOT NULL CHECK (sessionGeneration >= 1),
    principalKind TEXT NOT NULL CHECK (principalKind IN ('user','session','process')),
    principalId TEXT NOT NULL,
    authorityBasis TEXT NOT NULL,
    causeKind TEXT NOT NULL,
    causeId TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open','parked','park_failed')),
    closedAt INTEGER,
    resultingLifecycleState TEXT CHECK (
      resultingLifecycleState IN ('active','parking','parked','retired')
    ),
    recoveryState TEXT CHECK (
      recoveryState IN ('ready_for_relaunch','active_restored',
                        'fenced_unknown_liveness','retired')
    ),
    sessionIdentity TEXT NOT NULL,
    ownerUserId TEXT NOT NULL REFERENCES users(userId),
    roleBindings TEXT NOT NULL,
    assignmentLinks TEXT NOT NULL,
    workItemLinks TEXT NOT NULL,
    workspacePath TEXT NOT NULL,
    custodyOwner TEXT NOT NULL,
    worktreePreservationResult TEXT NOT NULL CHECK (worktreePreservationResult = 'preserved'),
    queuedTurnSeqs TEXT NOT NULL,
    pendingWakeIds TEXT NOT NULL,
    failureCode TEXT CHECK (failureCode IN (
      'runtime_settlement_failed','runtime_liveness_unknown','custody_snapshot_failed',
      'superseded_by_retire','recovery_interrupted'
    )),
    remedy TEXT CHECK (remedy IN (
      'retry_new_request','operator_recover','resolve_runtime_then_relaunch','none'
    )),
    CHECK (
      status = 'open' AND closedAt IS NULL AND resultingLifecycleState IS NULL
        AND recoveryState IS NULL AND failureCode IS NULL AND remedy IS NULL
      OR status = 'parked' AND closedAt IS NOT NULL
        AND resultingLifecycleState = 'parked' AND recoveryState = 'ready_for_relaunch'
        AND failureCode IS NULL AND remedy IS NULL
      OR status = 'park_failed' AND closedAt IS NOT NULL
        AND failureCode IS NOT NULL AND remedy IS NOT NULL
        AND (
          (resultingLifecycleState = 'active' AND recoveryState = 'active_restored')
          OR (resultingLifecycleState = 'parking'
              AND recoveryState = 'fenced_unknown_liveness')
          OR (resultingLifecycleState = 'retired' AND recoveryState = 'retired')
        )
    ),
    CHECK (
      status != 'park_failed'
      OR (
        (failureCode = 'runtime_settlement_failed'
          AND resultingLifecycleState = 'active' AND recoveryState = 'active_restored'
          AND remedy = 'retry_new_request')
        OR (failureCode = 'runtime_liveness_unknown'
          AND resultingLifecycleState = 'parking'
          AND recoveryState = 'fenced_unknown_liveness'
          AND remedy = 'resolve_runtime_then_relaunch')
        OR (failureCode = 'custody_snapshot_failed'
          AND resultingLifecycleState = 'active' AND recoveryState = 'active_restored'
          AND remedy = 'operator_recover')
        OR (failureCode = 'superseded_by_retire'
          AND resultingLifecycleState = 'retired' AND recoveryState = 'retired'
          AND remedy = 'none')
        OR (failureCode = 'recovery_interrupted'
          AND resultingLifecycleState = 'active' AND recoveryState = 'active_restored'
          AND remedy = 'operator_recover')
      )
    )
  );

  CREATE TABLE IF NOT EXISTS park_refusals (
    refusalId TEXT PRIMARY KEY,
    idempotencyKey TEXT,
    sessionKey TEXT,
    principalKind TEXT NOT NULL CHECK (principalKind IN ('user','session','process','unknown')),
    principalId TEXT NOT NULL,
    code TEXT NOT NULL CHECK (code IN (
      'not_authorized','session_not_active','lifecycle_contended','invalid_mode',
      'invalid_retry','unknown_session'
    )),
    causeKind TEXT NOT NULL,
    causeId TEXT NOT NULL,
    refusedAt INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS park_read_audits (
    readId TEXT PRIMARY KEY,
    requestId TEXT NOT NULL,
    principalKind TEXT NOT NULL CHECK (principalKind IN ('user','session','process','unknown')),
    principalId TEXT NOT NULL,
    admitted INTEGER NOT NULL CHECK (admitted IN (0,1)),
    readAt INTEGER NOT NULL
  );

  CREATE TRIGGER IF NOT EXISTS park_outcomes_closed_update
  BEFORE UPDATE ON park_outcomes
  WHEN OLD.status IN ('parked','park_failed')
  BEGIN
    SELECT RAISE(ABORT, 'closed park outcome is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS park_outcomes_delete
  BEFORE DELETE ON park_outcomes
  BEGIN
    SELECT RAISE(ABORT, 'park outcome is immutable');
  END;
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc false
  def ddl_for_migration, do: @ddl

  @doc "Accept or replay one PARK request and atomically close session intake."
  @spec request(DB.server(), map()) :: map()
  def request(db \\ DB, attrs) do
    :ok = ensure_schema(db)

    case DB.transaction(db, &request_in_txn(&1, attrs)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc "Transaction-owned PARK acceptance used by completion R12."
  @spec request_in_txn(Txn.t(), map()) :: map()
  def request_in_txn(%Txn{} = txn, attrs) do
    principal = Map.fetch!(attrs, :principal)
    session_key = Map.fetch!(attrs, :session_key)
    idempotency_key = Map.fetch!(attrs, :idempotency_key)
    mode = Map.get(attrs, :mode, "graceful")
    cause_kind = Map.get(attrs, :cause_kind, "manual")
    cause_id = Map.get(attrs, :cause_id, idempotency_key)
    retry_of = Map.get(attrs, :retry_of_request_id)
    {principal_kind, principal_id} = principal_columns(principal)

    replay =
      case Txn.q(
             txn,
             "SELECT requestId FROM park_requests WHERE principalKind=?1 AND principalId=?2 AND sessionKey=?3 AND idempotencyKey=?4",
             [principal_kind, principal_id, session_key, idempotency_key]
           ) do
        [[request_id]] -> fetch_in_txn!(txn, request_id)
        [] -> nil
      end

    if replay do
      Map.put(replay, :replay, true)
    else
      accept_new_in_txn(txn, attrs, %{
        principal: principal,
        principal_kind: principal_kind,
        principal_id: principal_id,
        session_key: session_key,
        idempotency_key: idempotency_key,
        mode: mode,
        cause_kind: cause_kind,
        cause_id: cause_id,
        retry_of: retry_of
      })
    end
  end

  defp accept_new_in_txn(txn, attrs, input) do
    session = Org.get_in_txn(txn, input.session_key)
    admission = authority_admission(txn, session, input.principal, attrs, input)
    fenced_retry? = fenced_unknown_liveness_retry?(txn, session, input, admission)

    refusal =
      cond do
        is_nil(session) ->
          "unknown_session"

        input.mode not in ["graceful", "immediate"] ->
          "invalid_mode"

        input.mode == "immediate" and
            admission[:basis] not in ["administrator", "operator", "harness_health_recovery"] ->
          "not_authorized"

        is_nil(admission) ->
          "not_authorized"

        not retry_valid?(txn, input.cause_kind, input.cause_id, input.retry_of) ->
          "invalid_retry"

        session.state != "active" and not fenced_retry? ->
          if session.state in ["parking", "parked"],
            do: "lifecycle_contended",
            else: "session_not_active"

        true ->
          nil
      end

    if refusal do
      record_refusal(txn, input, refusal)
    else
      accept_request(txn, session, input, admission, attrs, fenced_retry?)
    end
  end

  defp accept_request(txn, session, input, admission, attrs, fenced_retry?) do
    request_id = "pr_" <> Id.uuid4()
    generation = session.lifecycle_generation + 1
    accepted_at = now()
    snapshot = continuity_snapshot(txn, session, attrs)

    Txn.q(
      txn,
      """
      INSERT INTO park_requests
        (requestId,idempotencyKey,sessionKey,sessionGeneration,principalKind,principalId,
         authorityBasis,policyBasis,evidenceKind,evidenceId,mode,causeKind,causeId,
         retryOfRequestId,status,acceptedAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,'accepted',?15)
      """,
      [
        request_id,
        input.idempotency_key,
        input.session_key,
        generation,
        input.principal_kind,
        input.principal_id,
        admission.basis,
        admission.policy_basis,
        admission.evidence_kind,
        admission.evidence_id,
        input.mode,
        input.cause_kind,
        input.cause_id,
        input.retry_of,
        accepted_at
      ]
    )

    Txn.q(
      txn,
      """
      INSERT INTO park_outcomes
        (requestId,sessionKey,sessionGeneration,principalKind,principalId,authorityBasis,
         causeKind,causeId,status,sessionIdentity,ownerUserId,roleBindings,assignmentLinks,
         workItemLinks,workspacePath,custodyOwner,worktreePreservationResult,
         queuedTurnSeqs,pendingWakeIds)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'open',?9,?10,?11,?12,?13,?14,?15,
              'preserved',?16,?17)
      """,
      [
        request_id,
        input.session_key,
        generation,
        input.principal_kind,
        input.principal_id,
        admission.basis,
        input.cause_kind,
        input.cause_id,
        snapshot.identity,
        session.owner_user_id,
        snapshot.roles,
        snapshot.assignments,
        snapshot.work_items,
        snapshot.workspace_path,
        "session:#{input.session_key}",
        snapshot.turns,
        snapshot.wakes
      ]
    )

    if fenced_retry? do
      Txn.q(
        txn,
        """
        UPDATE sessions
        SET lifecycleGeneration=?2, lifecycleRequestId=?3,
            updatedAt=MAX(updatedAt + 1, ?4)
        WHERE sessionKey=?1 AND state='active' AND lifecycleGeneration=?5
          AND lifecycleRequestId=?6
        """,
        [
          input.session_key,
          generation,
          request_id,
          accepted_at,
          session.lifecycle_generation,
          input.retry_of
        ]
      )
    else
      Txn.q(
        txn,
        """
        UPDATE sessions
        SET lifecycleGeneration=?2, lifecycleRequestId=?3,
            updatedAt=MAX(updatedAt + 1, ?4)
        WHERE sessionKey=?1 AND state='active' AND lifecycleGeneration=?5
          AND lifecycleRequestId IS NULL
        """,
        [input.session_key, generation, request_id, accepted_at, session.lifecycle_generation]
      )
    end

    if Txn.changes(txn) != 1, do: raise("park lifecycle acceptance race")

    if fenced_retry? do
      Txn.q(
        txn,
        "UPDATE session_lifecycle_states SET generation=?2,requestId=?3,updatedAt=?4 WHERE sessionKey=?1 AND state='parking' AND generation=?5 AND requestId=?6",
        [
          input.session_key,
          generation,
          request_id,
          accepted_at,
          session.lifecycle_generation,
          input.retry_of
        ]
      )
    else
      Txn.q(
        txn,
        "INSERT INTO session_lifecycle_states (sessionKey,state,generation,requestId,updatedAt) VALUES (?1,'parking',?2,?3,?4) ON CONFLICT(sessionKey) DO UPDATE SET state='parking',generation=excluded.generation,requestId=excluded.requestId,updatedAt=excluded.updatedAt WHERE session_lifecycle_states.state='active'",
        [input.session_key, generation, request_id, accepted_at]
      )
    end

    if Txn.changes(txn) != 1, do: raise("park lifecycle fence race")

    EventLog.lifecycle_in_txn(
      txn,
      "session_park_accepted",
      request_id,
      audit_detail(input, admission)
    )

    fetch_in_txn!(txn, request_id)
  end

  @doc "Settle an accepted PARK through the injected per-session runtime boundary."
  @spec settle(DB.server(), String.t(), (map() -> :ok | {:error, term()})) :: map()
  def settle(db \\ DB, request_id, settle_runtime) when is_function(settle_runtime, 1) do
    request = get(db, request_id)

    cond do
      is_nil(request) ->
        %{code: "unknown_park_request", requestId: request_id}

      request.outcome.status != "open" ->
        request

      true ->
        result = settle_runtime.(request)

        if result == :pending do
          request
        else
          case DB.transaction(db, fn txn -> settle_in_txn(txn, request_id, result) end) do
            {:ok, settled} -> settled
            {:error, error} -> raise error
          end
        end
    end
  end

  @doc "Open PARK requests for deterministic boot and turn-terminal reconciliation."
  def open_requests(db \\ DB, session_key \\ nil) do
    :ok = ensure_schema(db)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT requestId FROM park_outcomes WHERE status='open' AND (?1 IS NULL OR sessionKey=?1) ORDER BY requestId",
        [session_key]
      )

    Enum.map(rows, fn [request_id] -> get(db, request_id) end)
  end

  @doc false
  def settle_in_txn(%Txn{} = txn, request_id, result) do
    request = fetch_in_txn!(txn, request_id)

    if request.outcome.status != "open" do
      request
    else
      session = Org.get_in_txn(txn, request.session_key)

      cond do
        session.state == "retired" ->
          close_failed(txn, request, "retired", "retired", "superseded_by_retire", "none")

        result == :ok and lifecycle_state_in_txn(txn, request.session_key) == "parking" and
            session.lifecycle_request_id == request_id ->
          close_parked(txn, request)

        match?({:error, :runtime_liveness_unknown}, result) ->
          close_failed(
            txn,
            request,
            "parking",
            "fenced_unknown_liveness",
            "runtime_liveness_unknown",
            "resolve_runtime_then_relaunch"
          )

        match?({:error, _}, result) ->
          restore_active(txn, request)

          close_failed(
            txn,
            request,
            "active",
            "active_restored",
            "runtime_settlement_failed",
            "retry_new_request"
          )

        true ->
          restore_active(txn, request)

          close_failed(
            txn,
            request,
            "active",
            "active_restored",
            "recovery_interrupted",
            "operator_recover"
          )
      end
    end
  end

  defp close_parked(txn, request) do
    at = now()

    Txn.q(
      txn,
      "UPDATE sessions SET updatedAt=MAX(updatedAt + 1,?3) WHERE sessionKey=?1 AND state='active' AND lifecycleRequestId=?2",
      [request.session_key, request.request_id, at]
    )

    if Txn.changes(txn) != 1, do: raise("park session state race")
    set_lifecycle_state(txn, request.session_key, "parking", "parked", request.request_id, at)
    close_outcome(txn, request.request_id, "parked", at, "parked", "ready_for_relaunch", nil, nil)
    EventLog.lifecycle_in_txn(txn, "session_parked", request.request_id, nil)
    fetch_in_txn!(txn, request.request_id)
  end

  defp close_failed(txn, request, lifecycle, recovery, failure, remedy) do
    at = now()

    close_outcome(
      txn,
      request.request_id,
      "park_failed",
      at,
      lifecycle,
      recovery,
      failure,
      remedy
    )

    EventLog.lifecycle_in_txn(
      txn,
      "session_park_failed",
      request.request_id,
      "failureCode=#{failure} recoveryState=#{recovery} remedy=#{remedy}"
    )

    fetch_in_txn!(txn, request.request_id)
  end

  defp close_outcome(txn, request_id, status, at, lifecycle, recovery, failure, remedy) do
    Txn.q(
      txn,
      """
      UPDATE park_outcomes
      SET status=?2,closedAt=?3,resultingLifecycleState=?4,recoveryState=?5,
          failureCode=?6,remedy=?7
      WHERE requestId=?1 AND status='open'
      """,
      [request_id, status, at, lifecycle, recovery, failure, remedy]
    )

    if Txn.changes(txn) != 1, do: raise("park outcome close race")
  end

  defp restore_active(txn, request) do
    Txn.q(
      txn,
      """
      UPDATE sessions SET lifecycleRequestId=NULL,updatedAt=MAX(updatedAt + 1,?3)
      WHERE sessionKey=?1 AND state='active' AND lifecycleRequestId=?2
      """,
      [request.session_key, request.request_id, now()]
    )

    set_lifecycle_state(txn, request.session_key, "parking", "active", nil, now())

    :ok
  end

  @doc "Close an open accepted PARK as lost to a terminal retirement CAS."
  def supersede_by_retire_in_txn(%Txn{} = txn, session_key) do
    case Txn.q(
           txn,
           "SELECT requestId FROM session_lifecycle_states WHERE sessionKey=?1 AND state='parking'",
           [session_key]
         ) do
      [[request_id]] when is_binary(request_id) ->
        request = fetch_in_txn!(txn, request_id)
        close_failed(txn, request, "retired", "retired", "superseded_by_retire", "none")
        set_lifecycle_state(txn, session_key, "parking", "retired", nil, now())
        :ok

      _ ->
        case Txn.q(
               txn,
               "SELECT requestId FROM session_lifecycle_states WHERE sessionKey=?1 AND state='parked'",
               [session_key]
             ) do
          [[_request_id]] ->
            set_lifecycle_state(txn, session_key, "parked", "retired", nil, now())
            :ok

          _ ->
            :ok
        end
    end
  end

  @doc "Authorize and reactivate the same parked Tightbeam session."
  def relaunch(db \\ DB, session_key, principal) do
    case DB.transaction(db, fn txn -> relaunch_in_txn(txn, session_key, principal) end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp relaunch_in_txn(txn, session_key, principal) do
    session = Org.get_in_txn(txn, session_key)

    cond do
      is_nil(session) ->
        %{code: "unknown_session"}

      lifecycle_state_in_txn(txn, session_key) != "parked" ->
        %{code: "session_not_parked"}

      not relaunch_authorized?(txn, session, principal) ->
        EventLog.lifecycle_in_txn(
          txn,
          "session_relaunch_refused",
          session_key,
          "code=not_authorized principal=#{principal_text(principal)}"
        )

        %{code: "not_authorized"}

      not parked_outcome?(txn, session.lifecycle_request_id) ->
        %{code: "park_outcome_not_successful"}

      true ->
        at = now()

        Txn.q(
          txn,
          """
          UPDATE sessions
          SET lifecycleGeneration=lifecycleGeneration+1,
              lifecycleRequestId=NULL,updatedAt=MAX(updatedAt + 1,?2)
          WHERE sessionKey=?1 AND state='active'
          """,
          [session_key, at]
        )

        if Txn.changes(txn) != 1, do: raise("session relaunch race")
        set_lifecycle_state(txn, session_key, "parked", "active", nil, at)

        EventLog.lifecycle_in_txn(
          txn,
          "session_relaunched",
          session_key,
          principal_text(principal)
        )

        %{ok: true, sessionKey: session_key, state: "active"}
    end
  end

  @doc "Read one request and its primitive outcome under owner/auditor admission."
  def read(db \\ DB, request_id, principal) do
    request = get(db, request_id)
    admitted = not is_nil(request) and visible?(db, request, principal)
    {kind, id} = principal_columns(principal)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO park_read_audits (readId,requestId,principalKind,principalId,admitted,readAt) VALUES (?1,?2,?3,?4,?5,?6)",
        ["pread_" <> Id.uuid4(), request_id, kind, id, if(admitted, do: 1, else: 0), now()]
      )

    if admitted, do: request, else: %{code: "not_found"}
  end

  def get(db \\ DB, request_id) do
    :ok = ensure_schema(db)

    case DB.query(
           db,
           "SELECT #{columns()} FROM park_requests pr JOIN park_outcomes po USING(requestId) WHERE pr.requestId=?1",
           [request_id]
         ) do
      {:ok, [row]} -> decode(row) |> with_retries(db)
      {:ok, []} -> nil
    end
  end

  defp fetch_in_txn!(txn, request_id) do
    [row] =
      Txn.q(
        txn,
        "SELECT #{columns()} FROM park_requests pr JOIN park_outcomes po USING(requestId) WHERE pr.requestId=?1",
        [request_id]
      )

    decode(row)
  end

  defp columns do
    "pr.requestId,pr.idempotencyKey,pr.sessionKey,pr.sessionGeneration," <>
      "pr.principalKind,pr.principalId,pr.authorityBasis,pr.policyBasis," <>
      "pr.evidenceKind,pr.evidenceId,pr.mode,pr.causeKind," <>
      "pr.causeId,pr.retryOfRequestId,pr.acceptedAt,po.status,po.closedAt," <>
      "po.resultingLifecycleState,po.recoveryState,po.sessionIdentity,po.ownerUserId," <>
      "po.roleBindings,po.assignmentLinks,po.workItemLinks,po.workspacePath," <>
      "po.custodyOwner,po.worktreePreservationResult,po.queuedTurnSeqs," <>
      "po.pendingWakeIds,po.failureCode,po.remedy"
  end

  defp decode([
         request_id,
         idempotency_key,
         session_key,
         generation,
         principal_kind,
         principal_id,
         basis,
         policy_basis,
         evidence_kind,
         evidence_id,
         mode,
         cause_kind,
         cause_id,
         retry_of,
         accepted_at,
         status,
         closed_at,
         lifecycle,
         recovery,
         identity,
         owner,
         roles,
         assignments,
         work_items,
         workspace,
         custody,
         preservation,
         turns,
         wakes,
         failure,
         remedy
       ]) do
    %{
      request_id: request_id,
      idempotency_key: idempotency_key,
      session_key: session_key,
      session_generation: generation,
      principal: %{kind: principal_kind, id: principal_id},
      authority_basis: basis,
      policy_basis: policy_basis,
      evidence: %{kind: evidence_kind, id: evidence_id},
      mode: mode,
      cause: %{kind: cause_kind, id: cause_id, retry_of_request_id: retry_of},
      accepted_at: accepted_at,
      outcome: %{
        status: status,
        closed_at: closed_at,
        resulting_lifecycle_state: lifecycle,
        recovery_state: recovery,
        session_identity: JSON.decode!(identity),
        owner_user_id: owner,
        role_bindings: JSON.decode!(roles),
        assignment_links: JSON.decode!(assignments),
        work_item_links: JSON.decode!(work_items),
        workspace_path: workspace,
        custody_owner: custody,
        worktree_preservation_result: preservation,
        queued_turn_seqs: JSON.decode!(turns),
        pending_wake_ids: JSON.decode!(wakes),
        failure_code: failure,
        remedy: remedy
      }
    }
  end

  defp with_retries(request, db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT requestId FROM park_requests WHERE retryOfRequestId=?1 ORDER BY acceptedAt,requestId",
        [request.request_id]
      )

    Map.put(request, :retry_request_ids, List.flatten(rows))
  end

  defp continuity_snapshot(txn, session, attrs) do
    assignments =
      Txn.q(
        txn,
        "SELECT id,workItemId FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY openedAt,id",
        [session.session_key]
      )
      |> Enum.map(fn [id, work_item_id] ->
        %{"assignmentId" => id, "workItemId" => work_item_id}
      end)

    work_items =
      assignments |> Enum.map(& &1["workItemId"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    roles =
      Txn.q(txn, "SELECT name FROM roles WHERE boundSessionKey=?1 ORDER BY name", [
        session.session_key
      ])
      |> List.flatten()

    turns =
      Txn.q(
        txn,
        "SELECT seq FROM turns WHERE sessionKey=?1 AND status='queued' ORDER BY seq",
        [session.session_key]
      )
      |> List.flatten()

    wakes =
      Txn.q(
        txn,
        "SELECT wakeId FROM wakes WHERE sessionKey=?1 AND state='pending' ORDER BY dueAt,wakeId",
        [session.session_key]
      )
      |> List.flatten()

    identity = %{
      "sessionKey" => session.session_key,
      "displayName" => session.display_name,
      "archetype" => session.archetype,
      "identityName" => session.identity_name,
      "identityRevision" => session.identity_revision,
      "harness" => session.harness,
      "provider" => session.provider,
      "host" => session.host,
      "handle" => session.handle,
      "operationalParent" => session.operational_parent
    }

    %{
      identity: JSON.encode!(identity),
      roles: JSON.encode!(roles),
      assignments: JSON.encode!(assignments),
      work_items: JSON.encode!(work_items),
      workspace_path: Map.get(attrs, :workspace_path, "unresolved:#{session.session_key}"),
      turns: JSON.encode!(turns),
      wakes: JSON.encode!(wakes)
    }
  end

  defp authority_admission(txn, session, principal, attrs, input) do
    requested = Map.get(attrs, :authority_basis)

    cond do
      is_nil(session) ->
        nil

      requested == "completion_disposition" and
          completion_authorized?(txn, session, principal, attrs) ->
        %{
          basis: requested,
          policy_basis: "completion_r11",
          evidence_kind: "completion_escalation",
          evidence_id: input.cause_id
        }

      requested == "harness_health_recovery" and
          principal == {:process, "tightbeam:harness-health"} ->
        health_park_admission(txn, session, input)

      requested == "operator" and match?({:user, _}, principal) and
          admin?(txn, elem(principal, 1)) ->
        ordinary_admission("operator", "operator_request", input)

      match?({:session, key} when key == session.session_key, principal) ->
        ordinary_admission("self_session", "self_request", input)

      match?({:user, owner} when owner == session.owner_user_id, principal) ->
        ordinary_admission("owner_user", "owner_request", input)

      match?({:user, _}, principal) and admin?(txn, elem(principal, 1)) ->
        ordinary_admission("administrator", "administrator_request", input)

      true ->
        nil
    end
  end

  defp ordinary_admission(basis, _policy_basis, %{cause_kind: "retry"}),
    do: %{basis: basis, policy_basis: "retry_request", evidence_kind: nil, evidence_id: nil}

  defp ordinary_admission(basis, policy_basis, _input),
    do: %{basis: basis, policy_basis: policy_basis, evidence_kind: nil, evidence_id: nil}

  defp health_park_admission(txn, session, input) do
    case Txn.q(
           txn,
           """
           SELECT hhrd.mode,hhrd.policyBasis,hhrd.evidenceObservationId
           FROM harness_health_recovery_decisions hhrd
           JOIN harness_health_incidents hhi ON hhi.id=hhrd.incidentId
           WHERE hhrd.decisionId=?1 AND hhrd.targetKind='session'
             AND hhrd.sessionKey=?2 AND hhrd.sessionGeneration=?3
             AND hhrd.action='park' AND hhrd.principal='tightbeam:harness-health'
             AND hhi.state='open'
           """,
           [input.cause_id, session.session_key, session.lifecycle_generation]
         ) do
      [[mode, "shared_harness_incident_hold", evidence_id]] when mode == input.mode ->
        %{
          basis: "harness_health_recovery",
          policy_basis: "harness_health_incident",
          evidence_kind: "harness_health_observation",
          evidence_id: evidence_id
        }

      _ ->
        nil
    end
  end

  defp completion_authorized?(txn, session, principal, attrs) do
    completion_id = Map.get(attrs, :cause_id)

    case Txn.q(
           txn,
           "SELECT childSessionKey,parentSessionKey,ownerUserId,status FROM completion_escalations WHERE id=?1",
           [completion_id]
         ) do
      [[child, parent, owner, "open"]] when child == session.session_key ->
        principal == {:user, owner} or principal == {:session, parent}

      _ ->
        false
    end
  end

  defp retry_valid?(txn, "retry", request_id, request_id) when is_binary(request_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM park_outcomes WHERE requestId=?1 AND status='park_failed'",
      [request_id]
    ) == [[1]]
  end

  defp retry_valid?(_txn, "retry", _cause_id, _retry_of), do: false
  defp retry_valid?(_txn, _cause_kind, _cause_id, nil), do: true
  defp retry_valid?(_txn, _cause_kind, _cause_id, _retry_of), do: false

  # The failed request is the fence token. Recovery may replace only that
  # exact token, and only after the ordinary owner/operator admission has
  # succeeded. Settlement still calls the runtime boundary; this CAS proves no
  # lifecycle fact beyond permission to try the named remedy again.
  defp fenced_unknown_liveness_retry?(txn, session, input, admission) do
    not is_nil(session) and input.cause_kind == "retry" and
      is_binary(input.retry_of) and input.cause_id == input.retry_of and
      admission[:basis] in ["owner_user", "administrator", "operator"] and
      Txn.q(
        txn,
        """
        SELECT 1
        FROM park_requests pr
        JOIN park_outcomes po USING(requestId)
        JOIN session_lifecycle_states sls ON sls.sessionKey=pr.sessionKey
        WHERE pr.requestId=?1 AND pr.sessionKey=?2
          AND pr.sessionGeneration=?3
          AND po.status='park_failed'
          AND po.resultingLifecycleState='parking'
          AND po.recoveryState='fenced_unknown_liveness'
          AND po.failureCode='runtime_liveness_unknown'
          AND po.remedy='resolve_runtime_then_relaunch'
          AND sls.state='parking' AND sls.generation=pr.sessionGeneration
          AND sls.requestId=pr.requestId
        """,
        [input.retry_of, input.session_key, session.lifecycle_generation]
      ) == [[1]]
  end

  defp record_refusal(txn, input, code) do
    refusal_id = "pref_" <> Id.uuid4()

    Txn.q(
      txn,
      """
      INSERT INTO park_refusals
        (refusalId,idempotencyKey,sessionKey,principalKind,principalId,code,causeKind,causeId,refusedAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
      """,
      [
        refusal_id,
        input.idempotency_key,
        input.session_key,
        input.principal_kind,
        input.principal_id,
        code,
        input.cause_kind,
        input.cause_id,
        now()
      ]
    )

    EventLog.lifecycle_in_txn(
      txn,
      "session_park_refused",
      refusal_id,
      "code=#{code} principal=#{input.principal_kind}:#{input.principal_id}"
    )

    %{code: code, refusal_id: refusal_id}
  end

  defp relaunch_authorized?(txn, session, {:user, user}),
    do: user == session.owner_user_id or admin?(txn, user)

  defp relaunch_authorized?(_txn, _session, _principal), do: false

  defp parked_outcome?(txn, request_id) when is_binary(request_id),
    do:
      Txn.q(txn, "SELECT 1 FROM park_outcomes WHERE requestId=?1 AND status='parked'", [
        request_id
      ]) == [[1]]

  defp parked_outcome?(_txn, _request_id), do: false

  defp lifecycle_state_in_txn(txn, session_key) do
    case Txn.q(txn, "SELECT state FROM session_lifecycle_states WHERE sessionKey=?1", [
           session_key
         ]) do
      [[state]] -> state
      [] -> "active"
    end
  end

  defp set_lifecycle_state(txn, session_key, from, to, request_id, at) do
    Txn.q(
      txn,
      "UPDATE session_lifecycle_states SET state=?3,requestId=?4,updatedAt=?5 WHERE sessionKey=?1 AND state=?2",
      [session_key, from, to, request_id, at]
    )

    if Txn.changes(txn) != 1, do: raise("session lifecycle state race")
    :ok
  end

  defp visible?(db, request, {:user, user}) do
    request.outcome.owner_user_id == user or
      DB.query(db, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == {:ok, [[1]]}
  end

  defp visible?(db, request, {:session, session_key}) do
    if request.cause.kind == "completion" do
      active_session?(db, session_key) and
        DB.query(
          db,
          "SELECT 1 FROM completion_escalations WHERE id=?1 AND parentSessionKey=?2",
          [request.cause.id, session_key]
        ) == {:ok, [[1]]}
    else
      DB.query(
        db,
        """
        SELECT 1
        FROM sessions s
        LEFT JOIN session_lifecycle_states sls USING(sessionKey)
        WHERE s.sessionKey=?1 AND s.ownerUserId=?2 AND s.state='active'
          AND COALESCE(sls.state,'active')='active'
        """,
        [session_key, request.outcome.owner_user_id]
      ) == {:ok, [[1]]}
    end
  end

  defp visible?(_db, _request, _principal), do: false

  defp active_session?(db, session_key) do
    DB.query(
      db,
      """
      SELECT 1 FROM sessions s
      LEFT JOIN session_lifecycle_states sls USING(sessionKey)
      WHERE s.sessionKey=?1 AND s.state='active' AND COALESCE(sls.state,'active')='active'
      """,
      [session_key]
    ) == {:ok, [[1]]}
  end

  defp admin?(txn, user),
    do: Txn.q(txn, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == [[1]]

  defp principal_columns({kind, id}) when kind in [:user, :session, :process] and is_binary(id),
    do: {Atom.to_string(kind), id}

  defp principal_columns(_), do: {"unknown", "unknown"}

  defp principal_text({kind, id}), do: "#{kind}:#{id}"
  defp principal_text(_), do: "unknown"

  defp audit_detail(input, admission) do
    "principal=#{input.principal_kind}:#{input.principal_id} authorityBasis=#{admission.basis} " <>
      "policyBasis=#{admission.policy_basis} " <>
      "cause=#{input.cause_kind}:#{input.cause_id} mode=#{input.mode}"
  end

  defp now, do: System.system_time(:millisecond)
end
