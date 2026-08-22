defmodule Tightbeam.IdentityApply do
  @moduledoc """
  Durable identity-apply state and the database mutation seam shared by apply,
  turn admission, retirement, and crash recovery.

  An operation freezes one target revision and one ordered session cohort.
  Every external effect is bracketed by an outcome row and every executable
  outcome owns the session's admission fence until one safe terminal
  transaction removes it.
  """

  alias Tightbeam.{DB, EventLog, Identity, Ledger, Org}
  alias Tightbeam.DB.Txn

  @fence_pg_scope Tightbeam.IdentityApply.FenceNotifications

  defmodule FencedError do
    @moduledoc "A retirement attempted to cross a durable identity-apply fence."
    defexception [:session_key, :operation_id]

    @impl true
    def message(error) do
      "session #{error.session_key} is controlled by identity apply operation #{error.operation_id}"
    end
  end

  @type db :: DB.server()

  @apply_warning "Applying identity resets/reloads each selected session. If a turn is running, Tight Beam cancels that turn before reload. After a successful reload, Tight Beam queues exactly one new continuation turn from the durable transcript and assignment state. It does not retry the interrupted turn. If the caller is a selected agent session, that turn can end before the command receives its final response; before interruption, Tight Beam durably stages a continuation containing the operation ID and exact result command, then releases it after reload succeeds or the prior context is restored."

  @terminal ~w(succeeded failed)

  @ddl """
  CREATE TABLE IF NOT EXISTS identity_apply_operations (
    operationId TEXT PRIMARY KEY,
    requestPrincipal TEXT NOT NULL,
    requestVerb TEXT NOT NULL CHECK (requestVerb = 'identity-apply'),
    requestedAt INTEGER NOT NULL CHECK (requestedAt >= 0),
    idempotencyKey TEXT NOT NULL,
    normalizedRequest TEXT NOT NULL,
    selectorKind TEXT NOT NULL CHECK (selectorKind IN ('all','session')),
    selectorSessionKey TEXT,
    targetRevision TEXT NOT NULL,
    executionOwnerEpoch INTEGER NOT NULL CHECK (executionOwnerEpoch > 0),
    retryAttempt INTEGER NOT NULL DEFAULT 0 CHECK (retryAttempt >= 0),
    retryAdmissionBlockedBySession TEXT,
    selectedSessionKeys TEXT NOT NULL,
    executionCohortSessionKeys TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('running','completed')),
    completedAt INTEGER,
    UNIQUE (requestPrincipal, requestVerb, idempotencyKey),
    CHECK (
      (selectorKind = 'all' AND selectorSessionKey IS NULL) OR
      (selectorKind = 'session' AND selectorSessionKey IS NOT NULL)
    ),
    CHECK (
      (state = 'running' AND completedAt IS NULL) OR
      (state = 'completed' AND completedAt >= requestedAt)
    )
  );

  CREATE TABLE IF NOT EXISTS identity_apply_outcomes (
    outcomeId TEXT PRIMARY KEY,
    operationId TEXT NOT NULL REFERENCES identity_apply_operations(operationId),
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    attempt INTEGER NOT NULL CHECK (attempt > 0),
    phase TEXT NOT NULL CHECK (phase IN
      ('pending','interrupting','reloading','continuation-pending','succeeded','failed')),
    priorIdentityRevision TEXT,
    targetRevision TEXT NOT NULL,
    interruptedTurnSeq INTEGER,
    turnOutcome TEXT CHECK (turnOutcome IN
      ('not-running','canceled','delivered','failed','failed-unknown')),
    reloadOutcome TEXT NOT NULL DEFAULT 'not-completed'
      CHECK (reloadOutcome IN ('reloaded','not-completed')),
    continuationMessageId TEXT,
    continuationTurnSeq INTEGER,
    continuationPrompt TEXT,
    continuationIntentIdentity TEXT,
    continuationMaterialized INTEGER NOT NULL DEFAULT 0
      CHECK (continuationMaterialized IN (0,1)),
    fenceOwned INTEGER NOT NULL CHECK (fenceOwned IN (0,1)),
    executionOwnerEpoch INTEGER NOT NULL CHECK (executionOwnerEpoch > 0),
    executorWorkerId TEXT,
    priorContextSnapshot TEXT,
    snapshotState TEXT NOT NULL DEFAULT 'pending'
      CHECK (snapshotState IN ('pending','calling','stored')),
    snapshotAttempt INTEGER NOT NULL DEFAULT 0 CHECK (snapshotAttempt >= 0),
    snapshotRecoveryAttempt INTEGER NOT NULL DEFAULT 0 CHECK (snapshotRecoveryAttempt >= 0),
    generationRetryCount INTEGER NOT NULL DEFAULT 0 CHECK (generationRetryCount IN (0,1)),
    expectedIncarnation TEXT,
    expectedAdapterGeneration INTEGER,
    snapshotCallStartedAt INTEGER,
    snapshotCallDeadline INTEGER,
    effectPhase TEXT CHECK (effectPhase IN ('runner-stop','reload')),
    effectId TEXT,
    effectCreationEpoch INTEGER,
    effectOwnerEpoch INTEGER,
    effectCallKind TEXT CHECK (effectCallKind IN ('invoke','status')),
    effectCallStartedAt INTEGER,
    effectCallDeadline INTEGER,
    effectStatus TEXT CHECK (effectStatus IN
      ('not-started','in-progress','succeeded','failed')),
    effectReceipt TEXT,
    recoveryAttempt INTEGER NOT NULL DEFAULT 0 CHECK (recoveryAttempt >= 0),
    nextAttemptAt INTEGER,
    statusOnlyRecovery INTEGER NOT NULL DEFAULT 0 CHECK (statusOnlyRecovery IN (0,1)),
    recoveryCause TEXT CHECK (recoveryCause IN ('context_mismatch','nonrunnable')),
    normalizationState TEXT CHECK (normalizationState IN ('pending','calling')),
    normalizationDeadline INTEGER,
    normalizationNodeBudget INTEGER,
    normalizationWorkerId TEXT,
    errorCode TEXT,
    retryable INTEGER CHECK (retryable IN (0,1)),
    failureMaterialId TEXT,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    UNIQUE (operationId, sessionKey, attempt),
    UNIQUE (operationId, sessionKey, executionOwnerEpoch, continuationMessageId),
    CHECK (
      (phase IN ('succeeded','failed') AND fenceOwned = 0) OR
      (phase IN ('pending','interrupting','reloading','continuation-pending') AND fenceOwned = 1)
    ),
    CHECK (
      (phase = 'failed' AND errorCode IS NOT NULL AND retryable IS NOT NULL AND
       failureMaterialId IS NOT NULL) OR
      (phase != 'failed' AND errorCode IS NULL AND retryable IS NULL AND
       failureMaterialId IS NULL)
    )
  );
  CREATE INDEX IF NOT EXISTS identity_apply_outcomes_operation
    ON identity_apply_outcomes (operationId, sessionKey, attempt);

  CREATE TABLE IF NOT EXISTS identity_apply_fences (
    sessionKey TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
    operationId TEXT NOT NULL REFERENCES identity_apply_operations(operationId),
    outcomeId TEXT NOT NULL UNIQUE REFERENCES identity_apply_outcomes(outcomeId),
    executionOwnerEpoch INTEGER NOT NULL CHECK (executionOwnerEpoch > 0),
    createdAt INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS identity_apply_failure_materials (
    failureMaterialId TEXT PRIMARY KEY,
    operationId TEXT NOT NULL REFERENCES identity_apply_operations(operationId),
    sessionKey TEXT NOT NULL,
    attemptKind TEXT NOT NULL CHECK (attemptKind IN ('executable','retry-admission')),
    executableAttempt INTEGER,
    retryAttempt INTEGER,
    code TEXT NOT NULL,
    stage TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('gateway','ledger','database','codex','claude')),
    capturedAt INTEGER NOT NULL,
    rawSourceSha256 TEXT,
    rawByteCount INTEGER NOT NULL CHECK (rawByteCount >= 0),
    unclassifiedEnvelope TEXT NOT NULL,
    CHECK (
      (attemptKind = 'executable' AND executableAttempt > 0 AND retryAttempt IS NULL) OR
      (attemptKind = 'retry-admission' AND executableAttempt IS NULL AND retryAttempt > 0)
    )
  );

  CREATE TABLE IF NOT EXISTS identity_apply_adapter_effects (
    effectId TEXT PRIMARY KEY,
    operationId TEXT NOT NULL REFERENCES identity_apply_operations(operationId),
    sessionKey TEXT NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('runner-stop','reload')),
    creationEpoch INTEGER NOT NULL CHECK (creationEpoch > 0),
    request TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('not-started','in-progress','succeeded','failed')),
    receipt TEXT,
    updatedAt INTEGER NOT NULL,
    CHECK (
      (state IN ('not-started','in-progress') AND receipt IS NULL) OR
      (state IN ('succeeded','failed') AND receipt IS NOT NULL)
    )
  );

  CREATE TABLE IF NOT EXISTS identity_apply_capability_failures (
    host TEXT NOT NULL,
    harness TEXT NOT NULL,
    operationId TEXT NOT NULL REFERENCES identity_apply_operations(operationId),
    effectId TEXT NOT NULL REFERENCES identity_apply_adapter_effects(effectId),
    recoveryCause TEXT NOT NULL CHECK (recoveryCause IN ('context_mismatch','nonrunnable')),
    observedAt INTEGER NOT NULL CHECK (observedAt >= 0),
    PRIMARY KEY (host, harness)
  );
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @spec apply_warning() :: String.t()
  def apply_warning, do: @apply_warning

  @spec continuation_prompt(String.t()) :: String.t()
  def continuation_prompt(operation_id) do
    "Identity apply operation #{operation_id} finished processing this session. Continue from the durable transcript and current assignment state. If the apply interrupted a turn, do not assume its external side effects were rolled back.\n" <>
      "Inspect durable results with: tightbeam identity apply --operation #{operation_id}"
  end

  @spec continuation_message_id(String.t(), String.t()) :: String.t()
  def continuation_message_id(operation_id, session_key) do
    digest = sha256(operation_id <> "\0" <> session_key)
    "identity-apply-" <> digest
  end

  @spec effect_id(String.t(), String.t(), pos_integer(), String.t()) :: String.t()
  def effect_id(operation_id, session_key, creation_epoch, phase)
      when phase in ["runner-stop", "reload"] do
    sha256(
      operation_id <>
        "\0" <> session_key <> "\0" <> Integer.to_string(creation_epoch) <> "\0" <> phase
    )
  end

  @doc "True inside an existing transaction when a durable apply fence owns the session."
  @spec fenced_in_txn?(Txn.t(), String.t()) :: boolean()
  def fenced_in_txn?(%Txn{} = txn, session_key) do
    Txn.q(txn, "SELECT 1 FROM identity_apply_fences WHERE sessionKey=?1", [session_key]) != []
  end

  @spec fence_owner_in_txn(Txn.t(), String.t()) :: String.t() | nil
  def fence_owner_in_txn(%Txn{} = txn, session_key) do
    case Txn.q(txn, "SELECT operationId FROM identity_apply_fences WHERE sessionKey=?1", [
           session_key
         ]) do
      [[operation_id]] -> operation_id
      [] -> nil
    end
  end

  @spec ensure_unfenced_in_txn!(Txn.t(), String.t()) :: :ok
  def ensure_unfenced_in_txn!(%Txn{} = txn, session_key) do
    case fence_owner_in_txn(txn, session_key) do
      nil ->
        :ok

      operation_id ->
        raise FencedError, session_key: session_key, operation_id: operation_id
    end
  end

  @doc "Wake every process waiting for this session's durable fence to disappear."
  @spec notify_fence_released(String.t()) :: :ok
  def notify_fence_released(session_key) do
    group = {:tightbeam_identity_apply_fence, session_key}

    Enum.each(:pg.get_members(@fence_pg_scope, group), fn waiter ->
      send(waiter, {:identity_apply_fence_released, session_key})
    end)

    if Process.whereis(Tightbeam.LaneRegistry) do
      _ = Tightbeam.SessionLane.nudge(session_key)
    end

    :ok
  end

  @doc "Wait for the observable fence-release event, closing the join/read race."
  @spec await_fence_release(db(), String.t()) :: :ok
  def await_fence_release(db \\ DB, session_key) do
    group = {:tightbeam_identity_apply_fence, session_key}
    :ok = :pg.join(@fence_pg_scope, group, self())

    try do
      if fenced?(db, session_key) do
        receive do
          {:identity_apply_fence_released, ^session_key} -> await_fence_release(db, session_key)
        end
      else
        :ok
      end
    after
      :ok = :pg.leave(@fence_pg_scope, group, self())
    end
  end

  @spec fenced?(db(), String.t()) :: boolean()
  def fenced?(db \\ DB, session_key) do
    {:ok, rows} =
      DB.query(db, "SELECT 1 FROM identity_apply_fences WHERE sessionKey=?1", [session_key])

    rows != []
  end

  @doc "Boot gate: transfer every durable fence and nonterminal obligation to one fresh epoch."
  @spec adopt_all!(db()) :: [String.t()]
  def adopt_all!(db \\ DB) do
    now = now()

    {:ok, operation_ids} =
      DB.transaction(db, fn txn ->
        operation_ids =
          txn
          |> Txn.q("SELECT DISTINCT operationId FROM identity_apply_fences ORDER BY operationId")
          |> Enum.map(&hd/1)

        Enum.each(operation_ids, fn operation_id ->
          [[epoch]] =
            Txn.q(
              txn,
              "UPDATE identity_apply_operations SET executionOwnerEpoch=executionOwnerEpoch+1 WHERE operationId=?1 RETURNING executionOwnerEpoch",
              [operation_id]
            )

          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET executionOwnerEpoch=?2, effectOwnerEpoch=CASE WHEN effectId IS NULL THEN NULL ELSE ?2 END, executorWorkerId=NULL, updatedAt=?3 WHERE operationId=?1 AND phase IN ('pending','interrupting','reloading','continuation-pending')",
            [operation_id, epoch, now]
          )

          Txn.q(
            txn,
            "UPDATE identity_apply_fences SET executionOwnerEpoch=?2 WHERE operationId=?1",
            [operation_id, epoch]
          )

          event_in_txn(txn, operation_id, nil, "recovery-adopted", %{executionOwnerEpoch: epoch})
        end)

        operation_ids
      end)

    operation_ids
  end

  @doc "Create or replay one frozen operation in one transaction."
  @spec accept(db(), String.t(), map(), String.t(), keyword()) ::
          {:ok, String.t(), :new | :replay} | {:error, map()}
  def accept(db \\ DB, base_dir, selector, request_principal, opts \\ []) do
    key = Keyword.get(opts, :idempotency_key) || generated_key()
    normalized = normalized_request(selector)
    now = now()

    result =
      DB.transaction(db, fn txn ->
        case binding_in_txn(txn, request_principal, key) do
          nil ->
            sessions = selected_sessions_in_txn(txn, selector)

            if selector.kind == "session" and sessions == [] do
              {:error, %{code: "not_found", message: "no matching session"}}
            else
              case first_unsupported(txn, sessions, opts) do
                nil ->
                  operation_id = operation_id()
                  target_revision = Identity.live_revision!(base_dir)
                  session_keys = Enum.map(sessions, & &1.session_key)

                  insert_operation_in_txn(
                    txn,
                    operation_id,
                    request_principal,
                    key,
                    normalized,
                    selector,
                    target_revision,
                    session_keys,
                    now
                  )

                  executable =
                    Enum.reduce(sessions, [], fn session, cohort ->
                      case insert_initial_outcome_in_txn(
                             txn,
                             base_dir,
                             operation_id,
                             request_principal,
                             target_revision,
                             session,
                             now
                           ) do
                        :executable -> [session.session_key | cohort]
                        :terminal -> cohort
                      end
                    end)
                    |> Enum.reverse()

                  Txn.q(
                    txn,
                    "UPDATE identity_apply_operations SET executionCohortSessionKeys=?2 WHERE operationId=?1",
                    [operation_id, JSON.encode!(executable)]
                  )

                  maybe_complete_empty_in_txn(txn, operation_id, now)

                  event_in_txn(txn, operation_id, nil, "accepted", %{
                    selector: selector,
                    selectedSessionKeys: session_keys
                  })

                  {:ok, operation_id, :new}

                unsupported ->
                  {:error, unsupported_error(unsupported)}
              end
            end

          %{operation_id: operation_id, normalized_request: ^normalized} ->
            retry_or_replay_in_txn(
              txn,
              base_dir,
              operation_id,
              request_principal,
              now
            )

          %{operation_id: operation_id} ->
            {:error,
             %{
               code: "idempotency_conflict",
               message:
                 "idempotency key is already bound to identity apply operation #{operation_id}"
             }}
        end
      end)

    case result do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @spec operation(db(), String.t()) :: map() | nil
  def operation(db \\ DB, operation_id) do
    {:ok, operation_rows} =
      DB.query(
        db,
        "SELECT operationId, requestPrincipal, requestedAt, idempotencyKey, selectorKind, selectorSessionKey, targetRevision, state FROM identity_apply_operations WHERE operationId=?1",
        [operation_id]
      )

    case operation_rows do
      [] ->
        nil

      [
        [
          id,
          principal,
          requested_at,
          key,
          selector_kind,
          selector_key,
          revision,
          state
        ]
      ] ->
        {:ok, outcome_rows} =
          DB.query(
            db,
            "SELECT outcomeId, operationId, sessionKey, attempt, phase, priorIdentityRevision, targetRevision, interruptedTurnSeq, turnOutcome, reloadOutcome, continuationMessageId, continuationTurnSeq, errorCode, retryable, failureMaterialId, executionOwnerEpoch, effectPhase, effectId, effectStatus, nextAttemptAt, recoveryAttempt FROM identity_apply_outcomes WHERE operationId=?1 ORDER BY sessionKey, attempt",
            [operation_id]
          )

        latest =
          outcome_rows
          |> Enum.map(&outcome_from_row/1)
          |> Enum.group_by(& &1.session_key)
          |> Enum.map(fn {_session_key, attempts} -> Enum.max_by(attempts, & &1.attempt) end)
          |> Enum.sort_by(& &1.session_key)

        terminal? = Enum.all?(latest, &(&1.state in @terminal))
        applied = latest |> Enum.filter(&(&1.state == "succeeded")) |> Enum.map(& &1.session_key)
        failed = latest |> Enum.filter(&(&1.state == "failed")) |> Enum.map(& &1.session_key)

        %{
          state: if(terminal?, do: "completed", else: state),
          outcome: outcome_kind(latest, terminal?),
          operation_id: id,
          idempotency_key: key,
          identity_revision: revision,
          selector: %{kind: selector_kind, session_key: selector_key},
          requested_by: principal,
          requested_at: requested_at,
          applied: applied,
          failed: failed,
          sessions: Enum.map(latest, &public_outcome/1)
        }
    end
  end

  @spec pending_operation_ids(db()) :: [String.t()]
  def pending_operation_ids(db \\ DB) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT operationId FROM identity_apply_operations WHERE state='running' ORDER BY requestedAt, operationId"
      )

    Enum.map(rows, &hd/1)
  end

  @spec claim_outcomes(db(), String.t(), String.t()) :: [map()]
  def claim_outcomes(db \\ DB, operation_id, worker_id) do
    {:ok, outcomes} =
      DB.transaction(db, fn txn ->
        case Txn.q(
               txn,
               "SELECT executionOwnerEpoch FROM identity_apply_operations WHERE operationId=?1",
               [operation_id]
             ) do
          [[epoch]] ->
            Txn.q(
              txn,
              "UPDATE identity_apply_outcomes SET executorWorkerId=?3, updatedAt=?4 WHERE operationId=?1 AND executionOwnerEpoch=?2 AND phase IN ('pending','interrupting','reloading','continuation-pending') AND (executorWorkerId IS NULL OR executorWorkerId=?3)",
              [operation_id, epoch, worker_id, now()]
            )

            Txn.q(
              txn,
              "SELECT outcomeId, operationId, sessionKey, attempt, phase, priorIdentityRevision, targetRevision, interruptedTurnSeq, turnOutcome, reloadOutcome, continuationMessageId, continuationTurnSeq, errorCode, retryable, failureMaterialId, executionOwnerEpoch, effectPhase, effectId, effectStatus, nextAttemptAt, recoveryAttempt FROM identity_apply_outcomes WHERE operationId=?1 AND executionOwnerEpoch=?2 AND phase IN ('pending','interrupting','reloading','continuation-pending') AND executorWorkerId=?3 ORDER BY sessionKey",
              [operation_id, epoch, worker_id]
            )
            |> Enum.map(&outcome_from_row/1)

          [] ->
            []
        end
      end)

    outcomes
  end

  @spec release_worker(db(), String.t(), String.t(), pos_integer()) :: :ok
  def release_worker(db \\ DB, outcome_id, worker_id, epoch) do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE identity_apply_outcomes SET executorWorkerId=NULL, updatedAt=?4 WHERE outcomeId=?1 AND executorWorkerId=?2 AND executionOwnerEpoch=?3 AND phase IN ('pending','interrupting','reloading','continuation-pending')",
        [outcome_id, worker_id, epoch, now()]
      )

    :ok
  end

  @spec mark_snapshot_call(db(), map(), String.t(), integer(), integer()) :: :ok | :stale
  def mark_snapshot_call(db \\ DB, outcome, worker_id, started_at, deadline) do
    guarded_update(
      db,
      outcome,
      worker_id,
      "snapshotState='calling', snapshotAttempt=snapshotAttempt+1, snapshotCallStartedAt=?4, snapshotCallDeadline=?5, updatedAt=?4",
      [started_at, deadline]
    )
  end

  @spec store_snapshot_and_begin(db(), map(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, atom()}
  def store_snapshot_and_begin(db \\ DB, outcome, worker_id, snapshot, effect_request) do
    now = now()

    {:ok, result} =
      DB.transaction(db, fn txn ->
        with :ok <- owns_in_txn(txn, outcome, worker_id),
             :ok <- fence_owned_in_txn(txn, outcome),
             :ok <- active_session_in_txn(txn, outcome.session_key),
             :ok <- snapshot_matches?(txn, outcome, snapshot) do
          running =
            case Txn.q(
                   txn,
                   "SELECT seq, status FROM turns WHERE sessionKey=?1 AND status='running' ORDER BY seq LIMIT 1",
                   [outcome.session_key]
                 ) do
              [[seq, status]] -> {seq, status}
              [] -> nil
            end

          {phase, turn_seq, turn_outcome} =
            case running do
              {seq, _} ->
                if Ledger.finish_in_txn(txn, seq, "canceled") do
                  {"runner-stop", seq, "canceled"}
                else
                  {"reload", seq, observed_turn_outcome_in_txn(txn, seq)}
                end

              nil ->
                {"reload", nil, "not-running"}
            end

          effect_id =
            effect_id(
              outcome.operation_id,
              outcome.session_key,
              outcome.execution_owner_epoch,
              phase
            )

          request =
            effect_request
            |> Map.put(:prior_context, snapshot)
            |> Map.put(:interruptedTurnSeq, turn_seq)

          Txn.q(
            txn,
            "INSERT INTO identity_apply_adapter_effects (effectId, operationId, sessionKey, phase, creationEpoch, request, state, updatedAt) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'not-started', ?7)",
            [
              effect_id,
              outcome.operation_id,
              outcome.session_key,
              phase,
              outcome.execution_owner_epoch,
              JSON.encode!(request),
              now
            ]
          )

          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET phase=?4, priorContextSnapshot=?5, snapshotState='stored', expectedAdapterGeneration=COALESCE(expectedAdapterGeneration, ?12), interruptedTurnSeq=?6, turnOutcome=?7, effectPhase=?8, effectId=?9, effectCreationEpoch=?10, effectOwnerEpoch=?10, effectStatus='not-started', effectReceipt=NULL, effectCallKind=NULL, effectCallStartedAt=NULL, effectCallDeadline=NULL, updatedAt=?11 WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3",
            [
              outcome.outcome_id,
              outcome.execution_owner_epoch,
              worker_id,
              if(phase == "runner-stop", do: "interrupting", else: "reloading"),
              JSON.encode!(snapshot),
              turn_seq,
              turn_outcome,
              phase,
              effect_id,
              outcome.execution_owner_epoch,
              now,
              snapshot["adapterGeneration"] || snapshot[:adapter_generation]
            ]
          )

          event_in_txn(txn, outcome.operation_id, outcome.session_key, phase, %{
            effectId: effect_id,
            interruptedTurnSeq: turn_seq
          })

          {:ok, %{phase: phase, effect_id: effect_id, interrupted_turn_seq: turn_seq}}
        else
          {:retry, _reason} = retry -> retry
          {:error, _reason} = error -> error
          other -> {:error, other}
        end
      end)

    result
  end

  @spec begin_reload_after_stop(db(), map(), String.t(), map()) :: {:ok, String.t()} | :stale
  def begin_reload_after_stop(db \\ DB, outcome, worker_id, effect_request) do
    now = now()

    effect_id =
      effect_id(
        outcome.operation_id,
        outcome.session_key,
        outcome.execution_owner_epoch,
        "reload"
      )

    {:ok, result} =
      DB.transaction(db, fn txn ->
        with :ok <- owns_in_txn(txn, outcome, worker_id),
             :ok <- fence_owned_in_txn(txn, outcome) do
          [[snapshot]] =
            Txn.q(
              txn,
              "SELECT priorContextSnapshot FROM identity_apply_outcomes WHERE outcomeId=?1",
              [outcome.outcome_id]
            )

          request = Map.put(effect_request, :prior_context, JSON.decode!(snapshot))

          Txn.q(
            txn,
            "INSERT OR IGNORE INTO identity_apply_adapter_effects (effectId, operationId, sessionKey, phase, creationEpoch, request, state, updatedAt) VALUES (?1, ?2, ?3, 'reload', ?4, ?5, 'not-started', ?6)",
            [
              effect_id,
              outcome.operation_id,
              outcome.session_key,
              outcome.execution_owner_epoch,
              JSON.encode!(request),
              now
            ]
          )

          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET phase='reloading', effectPhase='reload', effectId=?4, effectCreationEpoch=?2, effectOwnerEpoch=?2, effectStatus='not-started', effectReceipt=NULL, effectCallKind=NULL, effectCallStartedAt=NULL, effectCallDeadline=NULL, updatedAt=?5 WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3",
            [outcome.outcome_id, outcome.execution_owner_epoch, worker_id, effect_id, now]
          )

          event_in_txn(txn, outcome.operation_id, outcome.session_key, "reloading", %{
            effectId: effect_id
          })

          {:ok, effect_id}
        else
          _ -> :stale
        end
      end)

    result
  end

  @spec record_effect_call(db(), map(), String.t(), String.t(), integer(), integer()) ::
          :ok | :stale
  def record_effect_call(db \\ DB, outcome, worker_id, call_kind, started_at, deadline)
      when call_kind in ["invoke", "status"] do
    guarded_update(
      db,
      outcome,
      worker_id,
      "effectCallKind=?4, effectCallStartedAt=?5, effectCallDeadline=?6, effectStatus='in-progress', updatedAt=?5",
      [call_kind, started_at, deadline]
    )
  end

  @spec record_effect_receipt(db(), map(), String.t(), map()) :: :ok | :stale
  def record_effect_receipt(db \\ DB, outcome, worker_id, receipt) do
    state = if receipt_state(receipt) == "succeeded", do: "succeeded", else: "failed"

    guarded_update(
      db,
      outcome,
      worker_id,
      "effectStatus=?4, effectReceipt=?5, updatedAt=?6",
      [state, JSON.encode!(receipt), now()]
    )
  end

  @spec effect_recovery_state(db(), String.t()) :: map()
  def effect_recovery_state(db \\ DB, outcome_id) do
    {:ok,
     [
       [
         snapshot,
         call_kind,
         status_only,
         recovery_cause,
         creation_epoch,
         owner_epoch
       ]
     ]} =
      DB.query(
        db,
        "SELECT priorContextSnapshot, effectCallKind, statusOnlyRecovery, recoveryCause, effectCreationEpoch, effectOwnerEpoch FROM identity_apply_outcomes WHERE outcomeId=?1",
        [outcome_id]
      )

    %{
      prior_context: snapshot && JSON.decode!(snapshot),
      call_kind: call_kind,
      status_only: status_only == 1,
      recovery_cause: recovery_cause,
      creation_epoch: creation_epoch,
      owner_epoch: owner_epoch
    }
  end

  @spec mark_status_only_recovery(db(), map(), String.t(), String.t()) :: :ok | :stale
  def mark_status_only_recovery(db \\ DB, outcome, worker_id, cause)
      when cause in ["context_mismatch", "nonrunnable"] do
    observed_at = now()

    {:ok, result} =
      DB.transaction(db, fn txn ->
        with :ok <- owns_in_txn(txn, outcome, worker_id),
             :ok <- fence_owned_in_txn(txn, outcome) do
          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET statusOnlyRecovery=1, recoveryCause=?4, updatedAt=?5 WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3",
            [outcome.outcome_id, outcome.execution_owner_epoch, worker_id, cause, observed_at]
          )

          [[host, harness]] =
            Txn.q(txn, "SELECT host, harness FROM sessions WHERE sessionKey=?1", [
              outcome.session_key
            ])

          Txn.q(
            txn,
            "INSERT INTO identity_apply_capability_failures (host, harness, operationId, effectId, recoveryCause, observedAt) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(host, harness) DO UPDATE SET operationId=excluded.operationId, effectId=excluded.effectId, recoveryCause=excluded.recoveryCause, observedAt=excluded.observedAt",
            [host, harness, outcome.operation_id, outcome.effect_id, cause, observed_at]
          )

          :ok
        else
          _ -> :stale
        end
      end)

    result
  end

  @spec reset_retryable_effect(db(), map(), String.t()) :: :ok | :stale
  def reset_retryable_effect(db \\ DB, outcome, worker_id) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        with :ok <- owns_in_txn(txn, outcome, worker_id),
             :ok <- fence_owned_in_txn(txn, outcome) do
          Txn.q(
            txn,
            "UPDATE identity_apply_adapter_effects SET state='not-started', receipt=NULL, updatedAt=?2 WHERE effectId=?1 AND state='failed'",
            [outcome.effect_id, now()]
          )

          if Txn.changes(txn) != 1, do: raise("retryable identity apply effect changed")

          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET effectStatus='not-started', statusOnlyRecovery=0, recoveryCause=NULL, nextAttemptAt=NULL, updatedAt=?4 WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3",
            [outcome.outcome_id, outcome.execution_owner_epoch, worker_id, now()]
          )

          if Txn.changes(txn) == 1, do: :ok, else: :stale
        else
          _ -> :stale
        end
      end)

    result
  end

  @spec mark_continuation_pending(db(), map(), String.t(), map()) :: :ok | :stale
  def mark_continuation_pending(db \\ DB, outcome, worker_id, receipt) do
    guarded_update(
      db,
      outcome,
      worker_id,
      "phase='continuation-pending', effectStatus='succeeded', effectReceipt=?4, reloadOutcome='reloaded', nextAttemptAt=NULL, updatedAt=?5",
      [JSON.encode!(receipt), now()]
    )
  end

  @spec commit_success(db(), map(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | :stale
  def commit_success(db \\ DB, outcome, worker_id, opts) do
    now = now()
    operation = Keyword.fetch!(opts, :operation)
    delivery_opts = Keyword.get(opts, :delivery_opts, [])

    result =
      DB.transaction(db, fn txn ->
        with :ok <- owns_in_txn(txn, outcome, worker_id),
             :ok <- fence_owned_in_txn(txn, outcome),
             [["continuation-pending", receipt_json]] <-
               Txn.q(
                 txn,
                 "SELECT phase, effectReceipt FROM identity_apply_outcomes WHERE outcomeId=?1",
                 [outcome.outcome_id]
               ),
             %{"state" => "succeeded", "targetRevision" => target_revision, "runnable" => true} <-
               JSON.decode!(receipt_json),
             true <- target_revision == operation.identity_revision do
          message_id = continuation_message_id(operation.operation_id, outcome.session_key)
          prompt = continuation_prompt(operation.operation_id)

          delivery =
            Tightbeam.Gateway.deliver_prompt_in_txn(
              txn,
              outcome.session_key,
              "process:tightbeam",
              prompt,
              [
                sender: "process:tightbeam",
                device_id: "process:tightbeam",
                client_message_id: message_id,
                request_ref: "identity-apply:#{operation.operation_id}",
                attachments: [
                  %{
                    type: "identity_apply",
                    operationId: operation.operation_id,
                    targetRevision: operation.identity_revision,
                    requestPrincipal: operation.requested_by
                  }
                ],
                identity_apply_cause: %{
                  operation_id: operation.operation_id,
                  target_revision: operation.identity_revision,
                  request_principal: operation.requested_by
                }
              ] ++ delivery_opts
            )

          turn_seq = delivery_turn_seq(txn, delivery)

          receipt = JSON.decode!(receipt_json)
          pointer_reason = Map.get(receipt, "pointerReason", "loaded")

          pointer_reason =
            if pointer_reason in ["created", "loaded", "fallback"],
              do: pointer_reason,
              else: "loaded"

          Org.append_pointer_in_txn(
            txn,
            outcome.session_key,
            Map.fetch!(receipt, "targetContextId"),
            pointer_reason
          )

          Txn.q(
            txn,
            "UPDATE sessions SET identityRevision=?2, updatedAt=?3 WHERE sessionKey=?1 AND state='active'",
            [outcome.session_key, operation.identity_revision, now]
          )

          if Txn.changes(txn) != 1, do: raise("post-reload session stamp unavailable")

          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET phase='succeeded', continuationMessageId=?4, continuationTurnSeq=?5, continuationPrompt=?6, continuationMaterialized=1, fenceOwned=0, executorWorkerId=NULL, nextAttemptAt=NULL, updatedAt=?7 WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3",
            [
              outcome.outcome_id,
              outcome.execution_owner_epoch,
              worker_id,
              message_id,
              turn_seq,
              prompt,
              now
            ]
          )

          if Txn.changes(txn) != 1, do: raise("post-reload outcome ownership changed")

          delete_fence_in_txn!(txn, outcome)
          maybe_complete_operation_in_txn(txn, outcome.operation_id, now)

          event_in_txn(txn, outcome.operation_id, outcome.session_key, "succeeded", %{
            continuationMessageId: message_id,
            continuationTurnSeq: turn_seq
          })

          {:ok, delivery}
        else
          _ -> :stale
        end
      end)

    case result do
      {:ok, value} -> value
      {:error, error} -> {:error, error}
    end
  end

  @spec fail_outcome(db(), map(), String.t(), String.t(), String.t(), term(), keyword()) ::
          {:ok, term()} | :stale
  def fail_outcome(db \\ DB, outcome, worker_id, code, stage, raw_failure, opts \\ []) do
    source = Keyword.get(opts, :source, "gateway")
    {message, _retryable} = error_policy(code, outcome.session_key, outcome.target_revision, nil)
    material_id = failure_material_id()
    envelope = Keyword.get(opts, :envelope) || controlled_envelope(raw_failure)
    raw_bytes = Keyword.get(opts, :raw_bytes)
    raw_hash = if is_binary(raw_bytes), do: sha256(raw_bytes), else: nil
    raw_count = if is_binary(raw_bytes), do: byte_size(raw_bytes), else: 0
    now = now()
    interrupted_caller = Keyword.get(opts, :interrupted_caller, false)
    operation = Keyword.get(opts, :operation)
    delivery_opts = Keyword.get(opts, :delivery_opts, [])

    {:ok, result} =
      DB.transaction(db, fn txn ->
        with :ok <- owns_in_txn(txn, outcome, worker_id),
             :ok <- fence_owned_in_txn(txn, outcome) do
          Txn.q(
            txn,
            "INSERT INTO identity_apply_failure_materials (failureMaterialId, operationId, sessionKey, attemptKind, executableAttempt, retryAttempt, code, stage, source, capturedAt, rawSourceSha256, rawByteCount, unclassifiedEnvelope) VALUES (?1, ?2, ?3, 'executable', ?4, NULL, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            [
              material_id,
              outcome.operation_id,
              outcome.session_key,
              outcome.attempt,
              code,
              stage,
              source,
              now,
              raw_hash,
              raw_count,
              JSON.encode!(envelope)
            ]
          )

          effective_code =
            if interrupted_caller,
              do: "self_apply_retry_requires_new_operation",
              else: code

          {effective_message, effective_retryable} =
            error_policy(
              effective_code,
              outcome.session_key,
              outcome.target_revision,
              material_id
            )

          delivery =
            if interrupted_caller do
              message_id = continuation_message_id(outcome.operation_id, outcome.session_key)
              prompt = continuation_prompt(outcome.operation_id)

              Tightbeam.Gateway.deliver_prompt_in_txn(
                txn,
                outcome.session_key,
                "process:tightbeam",
                prompt,
                [
                  sender: "process:tightbeam",
                  device_id: "process:tightbeam",
                  client_message_id: message_id,
                  attachments: [
                    %{
                      type: "identity_apply",
                      operationId: outcome.operation_id,
                      targetRevision: outcome.target_revision,
                      requestPrincipal: operation && operation.requested_by
                    }
                  ],
                  identity_apply_cause: %{
                    operation_id: outcome.operation_id,
                    target_revision: outcome.target_revision,
                    request_principal: operation && operation.requested_by
                  }
                ] ++ delivery_opts
              )
            end

          continuation_turn_seq = delivery && delivery_turn_seq(txn, delivery)

          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET phase='failed', reloadOutcome='not-completed', fenceOwned=0, executorWorkerId=NULL, errorCode=?4, retryable=?5, failureMaterialId=?6, continuationMaterialized=?7, continuationTurnSeq=?8, continuationPrompt=CASE WHEN ?7=1 THEN continuationPrompt ELSE NULL END, continuationMessageId=CASE WHEN ?7=1 THEN continuationMessageId ELSE NULL END, continuationIntentIdentity=CASE WHEN ?7=1 THEN continuationIntentIdentity ELSE NULL END, nextAttemptAt=NULL, normalizationState=NULL, normalizationWorkerId=NULL, updatedAt=?9 WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3",
            [
              outcome.outcome_id,
              outcome.execution_owner_epoch,
              worker_id,
              effective_code,
              bool_int(effective_retryable),
              material_id,
              bool_int(interrupted_caller),
              continuation_turn_seq,
              now
            ]
          )

          if Txn.changes(txn) != 1, do: raise("identity apply outcome ownership changed")

          delete_fence_in_txn!(txn, outcome)

          if effective_code == "self_apply_retry_requires_new_operation" do
            Txn.q(
              txn,
              "UPDATE identity_apply_operations SET retryAdmissionBlockedBySession=?2 WHERE operationId=?1",
              [outcome.operation_id, outcome.session_key]
            )
          end

          maybe_complete_operation_in_txn(txn, outcome.operation_id, now)

          event_in_txn(txn, outcome.operation_id, outcome.session_key, "failed", %{
            code: effective_code,
            message: effective_message,
            retryable: effective_retryable,
            failureMaterialId: material_id
          })

          {:ok, %{message: message, failure_material_id: material_id, delivery: delivery}}
        else
          _ -> :stale
        end
      end)

    result
  end

  @spec begin_failure_normalization(db(), map(), String.t(), String.t()) :: :ok | :stale
  def begin_failure_normalization(db \\ DB, outcome, worker_id, normalizer_worker_id) do
    started = now()

    guarded_update(
      db,
      outcome,
      worker_id,
      "normalizationState='calling', normalizationDeadline=?4, normalizationNodeBudget=65536, normalizationWorkerId=?5, updatedAt=?6",
      [started + 30_000, normalizer_worker_id, started]
    )
  end

  @spec schedule_recovery(db(), map(), String.t(), String.t(), integer()) :: :ok | :stale
  def schedule_recovery(db \\ DB, outcome, worker_id, kind, observed_at)
      when kind in [
             "adapter_unavailable",
             "timed_out",
             "post_reload_commit_unavailable",
             "prior_context_snapshot_unavailable"
           ] do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        with :ok <- owns_in_txn(txn, outcome, worker_id),
             :ok <- fence_owned_in_txn(txn, outcome) do
          recovery_column =
            if kind == "prior_context_snapshot_unavailable",
              do: "snapshotRecoveryAttempt",
              else: "recoveryAttempt"

          [[ordinal]] =
            Txn.q(
              txn,
              "SELECT #{recovery_column} FROM identity_apply_outcomes WHERE outcomeId=?1",
              [outcome.outcome_id]
            )

          next_at = observed_at + recovery_delay(ordinal)

          Txn.q(
            txn,
            "UPDATE identity_apply_outcomes SET #{recovery_column}=#{recovery_column}+1, nextAttemptAt=?4, executorWorkerId=NULL, updatedAt=?5 WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3",
            [outcome.outcome_id, outcome.execution_owner_epoch, worker_id, next_at, observed_at]
          )

          if Txn.changes(txn) != 1, do: raise("identity apply recovery ownership changed")

          [
            [
              call_kind,
              recovery_cause,
              snapshot_attempt,
              generation_retry,
              expected_inc,
              expected_gen,
              effect_creation_epoch,
              effect_call_deadline,
              snapshot_call_deadline
            ]
          ] =
            Txn.q(
              txn,
              "SELECT effectCallKind, recoveryCause, snapshotAttempt, generationRetryCount, expectedIncarnation, expectedAdapterGeneration, effectCreationEpoch, effectCallDeadline, snapshotCallDeadline FROM identity_apply_outcomes WHERE outcomeId=?1",
              [outcome.outcome_id]
            )

          event_id = recovery_event_id(outcome, ordinal, kind, call_kind)

          unless lifecycle_event_exists_in_txn?(txn, event_id) do
            common = %{
              eventId: event_id,
              executionOwnerEpoch: outcome.execution_owner_epoch,
              recoveryAttempt: ordinal,
              nextAttemptAt: next_at,
              recoveryOwner: outcome.execution_owner_epoch,
              supervisingWorkerId: worker_id,
              retryable: true
            }

            detail =
              case kind do
                "prior_context_snapshot_unavailable" ->
                  Map.merge(common, %{
                    message:
                      "Identity apply prior-context snapshot for session #{outcome.session_key} is unavailable; recovery will retry at #{next_at}.",
                    snapshotAttempt: snapshot_attempt,
                    generationRetryCount: generation_retry,
                    expectedIncarnation: expected_inc,
                    expectedAdapterGeneration: expected_gen,
                    callDeadline: snapshot_call_deadline
                  })

                "post_reload_commit_unavailable" ->
                  Map.merge(common, %{
                    message:
                      "Identity apply post-reload commit for session #{outcome.session_key} is unavailable; recovery will retry at #{next_at}.",
                    effectId: outcome.effect_id,
                    effectCreationEpoch: effect_creation_epoch
                  })

                effect_kind when effect_kind in ["adapter_unavailable", "timed_out"] ->
                  effect_detail =
                    Map.merge(common, %{
                      message:
                        "Identity apply adapter for session #{outcome.session_key} is unavailable; recovery will retry at #{next_at}.",
                      effectId: outcome.effect_id,
                      phase: outcome.effect_phase,
                      effectCreationEpoch: effect_creation_epoch,
                      callKind: call_kind
                    })

                  effect_detail =
                    if recovery_cause,
                      do: Map.put(effect_detail, :recoveryCause, recovery_cause),
                      else: effect_detail

                  if effect_kind == "timed_out",
                    do: Map.put(effect_detail, :callDeadline, effect_call_deadline),
                    else: effect_detail
              end

            event_in_txn(txn, outcome.operation_id, outcome.session_key, kind, detail)
          end

          :ok
        else
          _ -> :stale
        end
      end)

    result
  end

  @spec effect(db(), String.t()) :: map() | nil
  def effect(db \\ DB, effect_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT effectId, operationId, sessionKey, phase, creationEpoch, request, state, receipt FROM identity_apply_adapter_effects WHERE effectId=?1",
        [effect_id]
      )

    case rows do
      [[id, operation_id, session_key, phase, epoch, request, state, receipt]] ->
        %{
          effect_id: id,
          operation_id: operation_id,
          session_key: session_key,
          phase: phase,
          creation_epoch: epoch,
          request: JSON.decode!(request),
          state: state,
          receipt: receipt && JSON.decode!(receipt)
        }

      [] ->
        nil
    end
  end

  @spec start_effect(db(), String.t()) :: :started | :already_started | :terminal
  def start_effect(db \\ DB, effect_id) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE identity_apply_adapter_effects SET state='in-progress', updatedAt=?2 WHERE effectId=?1 AND state='not-started'",
          [effect_id, now()]
        )

        if Txn.changes(txn) == 1 do
          :started
        else
          case Txn.q(txn, "SELECT state FROM identity_apply_adapter_effects WHERE effectId=?1", [
                 effect_id
               ]) do
            [[state]] when state in ["succeeded", "failed"] -> :terminal
            [["in-progress"]] -> :already_started
            [] -> raise "unknown identity apply effect #{effect_id}"
          end
        end
      end)

    result
  end

  @spec finish_effect(db(), String.t(), map()) :: map()
  def finish_effect(db \\ DB, effect_id, receipt) do
    state = receipt_state(receipt)
    true = state in ["succeeded", "failed"]

    {:ok, _} =
      DB.query(
        db,
        "UPDATE identity_apply_adapter_effects SET state=?2, receipt=?3, updatedAt=?4 WHERE effectId=?1 AND state IN ('not-started','in-progress')",
        [effect_id, state, JSON.encode!(receipt), now()]
      )

    effect(db, effect_id).receipt
  end

  @spec stale_sessions(db(), String.t()) :: [map()]
  def stale_sessions(db \\ DB, live_revision) do
    db
    |> Org.list_for_user("", true)
    |> Enum.filter(&(&1.state == "active" and &1.identity_revision != live_revision))
    |> Enum.sort_by(& &1.session_key)
    |> Enum.map(&%{session_key: &1.session_key, identity_revision: &1.identity_revision})
  end

  @spec successful_relearn_result(db(), String.t()) :: map()
  def successful_relearn_result(db \\ DB, live_revision) do
    stale = stale_sessions(db, live_revision)

    %{
      state: "published",
      live_revision: live_revision,
      stale_sessions: stale,
      apply_command: if(stale == [], do: nil, else: "tightbeam identity apply --all"),
      apply_warning: @apply_warning
    }
  end

  defp insert_operation_in_txn(
         txn,
         operation_id,
         principal,
         key,
         normalized,
         selector,
         revision,
         session_keys,
         now
       ) do
    Txn.q(
      txn,
      "INSERT INTO identity_apply_operations (operationId, requestPrincipal, requestVerb, requestedAt, idempotencyKey, normalizedRequest, selectorKind, selectorSessionKey, targetRevision, executionOwnerEpoch, selectedSessionKeys, executionCohortSessionKeys, state) VALUES (?1, ?2, 'identity-apply', ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9, '[]', 'running')",
      [
        operation_id,
        principal,
        now,
        key,
        normalized,
        selector.kind,
        selector.session_key,
        revision,
        JSON.encode!(session_keys)
      ]
    )
  end

  defp retry_or_replay_in_txn(txn, base_dir, operation_id, principal, now) do
    [[target_revision, epoch, retry_attempt, blocked_by, state]] =
      Txn.q(
        txn,
        "SELECT targetRevision, executionOwnerEpoch, retryAttempt, retryAdmissionBlockedBySession, state FROM identity_apply_operations WHERE operationId=?1",
        [operation_id]
      )

    cohort =
      Txn.q(
        txn,
        "SELECT sessionKey, phase FROM identity_apply_outcomes WHERE operationId=?1 AND executionOwnerEpoch=?2 ORDER BY sessionKey",
        [operation_id, epoch]
      )

    if Enum.any?(cohort, fn [_session_key, phase] ->
         phase in ["pending", "interrupting", "reloading", "continuation-pending"]
       end) do
      {:error,
       %{
         code: "apply_cohort_in_progress",
         message:
           "Identity apply operation #{operation_id} still has a nonterminal session; retry after the current cohort completes.",
         retryable: true,
         operation_id: operation_id
       }}
    else
      cond do
        not is_nil(blocked_by) ->
          {:ok, operation_id, :replay}

        state != "completed" ->
          {:ok, operation_id, :replay}

        true ->
          candidates = retry_candidates_in_txn(txn, operation_id)

          if candidates == [] do
            {:ok, operation_id, :replay}
          else
            new_epoch = epoch + 1
            new_retry_attempt = retry_attempt + 1

            executable =
              Enum.reduce(candidates, [], fn candidate, acc ->
                case retry_candidate_in_txn(
                       txn,
                       base_dir,
                       operation_id,
                       principal,
                       target_revision,
                       new_epoch,
                       new_retry_attempt,
                       candidate,
                       now
                     ) do
                  :executable -> [candidate.session_key | acc]
                  :classified -> acc
                end
              end)
              |> Enum.reverse()

            Txn.q(
              txn,
              "UPDATE identity_apply_operations SET executionOwnerEpoch=?2, retryAttempt=?3, executionCohortSessionKeys=?4, state=?5, completedAt=?6 WHERE operationId=?1",
              [
                operation_id,
                new_epoch,
                new_retry_attempt,
                JSON.encode!(executable),
                if(executable == [], do: "completed", else: "running"),
                if(executable == [], do: now)
              ]
            )

            event_in_txn(txn, operation_id, nil, "retry-admitted", %{
              retryAttempt: new_retry_attempt,
              executionOwnerEpoch: new_epoch,
              executionCohortSessionKeys: executable
            })

            {:ok, operation_id, if(executable == [], do: :replay, else: :retry)}
          end
      end
    end
  end

  defp retry_candidates_in_txn(txn, operation_id) do
    Txn.q(
      txn,
      """
      SELECT o.outcomeId, o.sessionKey, o.attempt, o.executionOwnerEpoch,
             o.priorIdentityRevision, o.targetRevision, o.errorCode,
             o.failureMaterialId
      FROM identity_apply_outcomes o
      WHERE o.operationId=?1 AND o.phase='failed' AND o.retryable=1
        AND o.continuationMaterialized=0
        AND o.attempt=(
          SELECT MAX(i.attempt) FROM identity_apply_outcomes i
          WHERE i.operationId=o.operationId AND i.sessionKey=o.sessionKey
        )
      ORDER BY o.sessionKey
      """,
      [operation_id]
    )
    |> Enum.map(fn [outcome_id, session_key, attempt, epoch, prior, target, code, material] ->
      %{
        outcome_id: outcome_id,
        session_key: session_key,
        attempt: attempt,
        epoch: epoch,
        prior_revision: prior,
        target_revision: target,
        error_code: code,
        failure_material_id: material
      }
    end)
    |> Enum.filter(&retry_candidate_open_in_txn?(txn, &1))
  end

  defp retry_candidate_open_in_txn?(txn, candidate) do
    case Txn.q(
           txn,
           """
           SELECT json_extract(detail, '$.code'),
                  json_extract(detail, '$.retryable'),
                  json_extract(detail, '$.controlledCause')
           FROM lifecycle_events
           WHERE kind='identity_apply_retry_admission_result'
             AND json_extract(detail, '$.sourceOutcomeId')=?1
           ORDER BY id DESC LIMIT 1
           """,
           [candidate.outcome_id]
         ) do
      [] ->
        true

      [[_code, 0, _cause]] ->
        false

      [["apply_in_progress", 1, "fence:" <> recorded_owner]] ->
        fence_owner_in_txn(txn, candidate.session_key) != recorded_owner

      [[_code, 1, _cause]] ->
        true
    end
  end

  defp retry_candidate_in_txn(
         txn,
         base_dir,
         operation_id,
         principal,
         target_revision,
         new_epoch,
         retry_attempt,
         candidate,
         now
       ) do
    case Txn.q(
           txn,
           "SELECT identityRevision, state FROM sessions WHERE sessionKey=?1",
           [candidate.session_key]
         ) do
      [] ->
        retry_classification_in_txn(
          txn,
          operation_id,
          principal,
          target_revision,
          new_epoch,
          retry_attempt,
          candidate,
          nil,
          "session_retired",
          "missing-session",
          now
        )

        :classified

      [[current_revision, "retired"]] ->
        retry_classification_in_txn(
          txn,
          operation_id,
          principal,
          target_revision,
          new_epoch,
          retry_attempt,
          candidate,
          current_revision,
          "session_retired",
          "retired",
          now
        )

        :classified

      [[current_revision, "active"]] ->
        classification =
          case revision_relation(base_dir, current_revision, target_revision) do
            :valid ->
              case fence_owner_in_txn(txn, candidate.session_key) do
                nil -> nil
                owner -> {"apply_in_progress", "fence:#{owner}"}
              end

            {:error, code} ->
              {Atom.to_string(code), "revision-validation"}
          end

        case classification do
          nil ->
            outcome_id = outcome_id()
            next_attempt = candidate.attempt + 1
            caller? = principal == candidate.session_key

            Txn.q(
              txn,
              "INSERT INTO identity_apply_outcomes (outcomeId, operationId, sessionKey, attempt, phase, priorIdentityRevision, targetRevision, continuationMessageId, continuationPrompt, continuationIntentIdentity, fenceOwned, executionOwnerEpoch, expectedIncarnation, createdAt, updatedAt) VALUES (?1, ?2, ?3, ?4, 'pending', ?5, ?6, ?7, ?8, ?9, 1, ?10, ?11, ?12, ?12)",
              [
                outcome_id,
                operation_id,
                candidate.session_key,
                next_attempt,
                current_revision,
                target_revision,
                if(caller?, do: continuation_message_id(operation_id, candidate.session_key)),
                if(caller?, do: continuation_prompt(operation_id)),
                if(caller?, do: principal),
                new_epoch,
                session_incarnation_in_txn(txn, candidate.session_key),
                now
              ]
            )

            Txn.q(
              txn,
              "INSERT INTO identity_apply_fences (sessionKey, operationId, outcomeId, executionOwnerEpoch, createdAt) VALUES (?1, ?2, ?3, ?4, ?5)",
              [candidate.session_key, operation_id, outcome_id, new_epoch, now]
            )

            :executable

          {code, cause} ->
            retry_classification_in_txn(
              txn,
              operation_id,
              principal,
              target_revision,
              new_epoch,
              retry_attempt,
              candidate,
              current_revision,
              code,
              cause,
              now
            )

            :classified
        end
    end
  end

  defp retry_classification_in_txn(
         txn,
         operation_id,
         principal,
         target_revision,
         epoch,
         retry_attempt,
         candidate,
         current_revision,
         code,
         cause,
         now
       ) do
    material_id = failure_material_id()
    {message, retryable} = error_policy(code, candidate.session_key, target_revision, material_id)

    event_id =
      sha256(
        operation_id <>
          "\0" <>
          Integer.to_string(retry_attempt) <>
          "\0" <>
          Integer.to_string(epoch) <> "\0" <> candidate.session_key
      )

    Txn.q(
      txn,
      "INSERT INTO identity_apply_failure_materials (failureMaterialId, operationId, sessionKey, attemptKind, executableAttempt, retryAttempt, code, stage, source, capturedAt, rawSourceSha256, rawByteCount, unclassifiedEnvelope) VALUES (?1, ?2, ?3, 'retry-admission', NULL, ?4, ?5, 'retry-admission', 'gateway', ?6, NULL, 0, ?7)",
      [
        material_id,
        operation_id,
        candidate.session_key,
        retry_attempt,
        code,
        now,
        JSON.encode!(%{kind: "controlled-cause", cause: cause})
      ]
    )

    event_in_txn(txn, operation_id, candidate.session_key, "retry-admission-result", %{
      eventId: event_id,
      retryAttempt: retry_attempt,
      executionOwnerEpoch: epoch,
      sourceOutcomeId: candidate.outcome_id,
      priorCohortEpoch: candidate.epoch,
      requestedRevision: target_revision,
      currentRevision: current_revision,
      requestPrincipal: principal,
      controlledCause: cause,
      code: code,
      message: message,
      retryable: retryable,
      failureMaterialId: material_id
    })
  end

  defp insert_initial_outcome_in_txn(
         txn,
         base_dir,
         operation_id,
         principal,
         target_revision,
         session,
         now
       ) do
    outcome_id = outcome_id()
    message_id = continuation_message_id(operation_id, session.session_key)
    caller? = principal == session.session_key

    case revision_relation(base_dir, session.identity_revision, target_revision) do
      :valid ->
        case fence_owner_in_txn(txn, session.session_key) do
          nil ->
            Txn.q(
              txn,
              "INSERT INTO identity_apply_outcomes (outcomeId, operationId, sessionKey, attempt, phase, priorIdentityRevision, targetRevision, continuationMessageId, continuationPrompt, continuationIntentIdentity, fenceOwned, executionOwnerEpoch, expectedIncarnation, createdAt, updatedAt) VALUES (?1, ?2, ?3, 1, 'pending', ?4, ?5, ?6, ?7, ?8, 1, 1, ?9, ?10, ?10)",
              [
                outcome_id,
                operation_id,
                session.session_key,
                session.identity_revision,
                target_revision,
                if(caller?, do: message_id),
                if(caller?, do: continuation_prompt(operation_id)),
                if(caller?, do: principal),
                session_incarnation_in_txn(txn, session.session_key),
                now
              ]
            )

            Txn.q(
              txn,
              "INSERT INTO identity_apply_fences (sessionKey, operationId, outcomeId, executionOwnerEpoch, createdAt) VALUES (?1, ?2, ?3, 1, ?4)",
              [session.session_key, operation_id, outcome_id, now]
            )

            :executable

          _owner ->
            insert_terminal_rejection_in_txn(
              txn,
              operation_id,
              outcome_id,
              session,
              target_revision,
              "apply_in_progress",
              now
            )

            :terminal
        end

      {:error, code} ->
        insert_terminal_rejection_in_txn(
          txn,
          operation_id,
          outcome_id,
          session,
          target_revision,
          code,
          now
        )

        :terminal
    end
  end

  defp insert_terminal_rejection_in_txn(
         txn,
         operation_id,
         outcome_id,
         session,
         target_revision,
         code,
         now
       ) do
    material_id = failure_material_id()
    {message, retryable} = error_policy(code, session.session_key, target_revision, material_id)
    envelope = %{kind: "controlled-cause", code: code}

    Txn.q(
      txn,
      "INSERT INTO identity_apply_outcomes (outcomeId, operationId, sessionKey, attempt, phase, priorIdentityRevision, targetRevision, turnOutcome, reloadOutcome, fenceOwned, executionOwnerEpoch, errorCode, retryable, failureMaterialId, createdAt, updatedAt) VALUES (?1, ?2, ?3, 1, 'failed', ?4, ?5, 'not-running', 'not-completed', 0, 1, ?6, ?7, ?8, ?9, ?9)",
      [
        outcome_id,
        operation_id,
        session.session_key,
        session.identity_revision,
        target_revision,
        code,
        bool_int(retryable),
        material_id,
        now
      ]
    )

    Txn.q(
      txn,
      "INSERT INTO identity_apply_failure_materials (failureMaterialId, operationId, sessionKey, attemptKind, executableAttempt, retryAttempt, code, stage, source, capturedAt, rawSourceSha256, rawByteCount, unclassifiedEnvelope) VALUES (?1, ?2, ?3, 'executable', 1, NULL, ?4, 'admission', 'gateway', ?5, NULL, 0, ?6)",
      [material_id, operation_id, session.session_key, code, now, JSON.encode!(envelope)]
    )

    event_in_txn(txn, operation_id, session.session_key, "failed", %{
      code: code,
      message: message,
      retryable: retryable,
      failureMaterialId: material_id
    })
  end

  defp selected_sessions_in_txn(txn, %{kind: "all"}) do
    Txn.q(
      txn,
      "SELECT sessionKey FROM sessions WHERE state='active' ORDER BY sessionKey"
    )
    |> Enum.map(fn [session_key] -> session_from_txn(txn, session_key) end)
  end

  defp selected_sessions_in_txn(txn, %{kind: "session", session_key: session_key}) do
    case Txn.q(txn, "SELECT sessionKey FROM sessions WHERE sessionKey=?1 AND state='active'", [
           session_key
         ]) do
      [[^session_key]] -> [session_from_txn(txn, session_key)]
      [] -> []
    end
  end

  defp session_from_txn(txn, session_key) do
    [[key, identity_revision, harness, host]] =
      Txn.q(
        txn,
        "SELECT sessionKey, identityRevision, harness, host FROM sessions WHERE sessionKey=?1",
        [session_key]
      )

    %{session_key: key, identity_revision: identity_revision, harness: harness, host: host}
  end

  defp first_unsupported(txn, sessions, opts) do
    capabilities = Keyword.get(opts, :capabilities, fn _session -> :supported end)

    Enum.find(sessions, fn session ->
      capabilities.(session) != :supported or capability_failed_in_txn?(txn, session)
    end)
  end

  defp capability_failed_in_txn?(txn, session) do
    Txn.q(
      txn,
      "SELECT 1 FROM identity_apply_capability_failures WHERE host=?1 AND harness=?2",
      [session.host, session.harness]
    ) != []
  end

  defp unsupported_error(session) do
    %{
      code: "adapter_effect_recovery_unsupported",
      message:
        "Identity apply requires recoverable prior-context snapshot, runner-stop, and atomic recoverable runtime-context reload; session #{session.session_key} on host #{session.host} does not support that contract.",
      retryable: false
    }
  end

  defp binding_in_txn(txn, principal, key) do
    case Txn.q(
           txn,
           "SELECT operationId, normalizedRequest FROM identity_apply_operations WHERE requestPrincipal=?1 AND requestVerb='identity-apply' AND idempotencyKey=?2",
           [principal, key]
         ) do
      [[operation_id, normalized]] ->
        %{operation_id: operation_id, normalized_request: normalized}

      [] ->
        nil
    end
  end

  defp normalized_request(%{kind: "all"}), do: ~s({"selector":{"kind":"all","sessionKey":null}})

  defp normalized_request(%{kind: "session", session_key: session_key}) do
    JSON.encode!(%{selector: %{kind: "session", sessionKey: session_key}})
  end

  defp revision_relation(_base_dir, nil, _target), do: :valid
  defp revision_relation(_base_dir, revision, revision), do: :valid

  defp revision_relation(base_dir, prior, target),
    do: Identity.revision_relation(base_dir, prior, target)

  defp session_incarnation_in_txn(txn, session_key) do
    case Txn.q(
           txn,
           "SELECT sourceSessionRef FROM harness_pointers WHERE sessionKey=?1 ORDER BY id DESC LIMIT 1",
           [session_key]
         ) do
      [[source_ref]] ->
        "pointer:#{source_ref}"

      [] ->
        [[created_at]] =
          Txn.q(txn, "SELECT createdAt FROM sessions WHERE sessionKey=?1", [session_key])

        "unstarted:#{created_at}"
    end
  end

  defp snapshot_matches?(txn, outcome, snapshot) do
    current_incarnation = session_incarnation_in_txn(txn, outcome.session_key)
    snapshot_incarnation = snapshot["sessionIncarnation"] || snapshot[:session_incarnation]
    snapshot_generation = snapshot["adapterGeneration"] || snapshot[:adapter_generation]

    [[expected_incarnation, expected_generation, retry_count]] =
      Txn.q(
        txn,
        "SELECT expectedIncarnation, expectedAdapterGeneration, generationRetryCount FROM identity_apply_outcomes WHERE outcomeId=?1",
        [outcome.outcome_id]
      )

    incarnation_matches =
      snapshot_incarnation == current_incarnation and expected_incarnation == current_incarnation

    generation_matches = is_nil(expected_generation) or snapshot_generation == expected_generation

    cond do
      incarnation_matches and generation_matches ->
        :ok

      retry_count == 0 ->
        Txn.q(
          txn,
          "UPDATE identity_apply_outcomes SET snapshotState='pending', generationRetryCount=1, expectedIncarnation=?2, expectedAdapterGeneration=?3, executorWorkerId=NULL, updatedAt=?4 WHERE outcomeId=?1",
          [outcome.outcome_id, current_incarnation, snapshot_generation, now()]
        )

        {:retry, :snapshot_revalidation_mismatch}

      true ->
        {:error, :snapshot_revalidation_mismatch}
    end
  end

  defp active_session_in_txn(txn, session_key) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
      [["active"]] -> :ok
      _ -> {:error, :session_retired}
    end
  end

  defp owns_in_txn(txn, outcome, worker_id) do
    case Txn.q(
           txn,
           "SELECT 1 FROM identity_apply_outcomes WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3 AND phase IN ('pending','interrupting','reloading','continuation-pending')",
           [outcome.outcome_id, outcome.execution_owner_epoch, worker_id]
         ) do
      [[1]] -> :ok
      [] -> {:error, :stale_owner}
    end
  end

  defp fence_owned_in_txn(txn, outcome) do
    case Txn.q(
           txn,
           "SELECT 1 FROM identity_apply_fences WHERE sessionKey=?1 AND operationId=?2 AND outcomeId=?3 AND executionOwnerEpoch=?4",
           [
             outcome.session_key,
             outcome.operation_id,
             outcome.outcome_id,
             outcome.execution_owner_epoch
           ]
         ) do
      [[1]] -> :ok
      [] -> {:error, :fence_lost}
    end
  end

  defp delete_fence_in_txn!(txn, outcome) do
    Txn.q(
      txn,
      "DELETE FROM identity_apply_fences WHERE sessionKey=?1 AND operationId=?2 AND outcomeId=?3 AND executionOwnerEpoch=?4",
      [
        outcome.session_key,
        outcome.operation_id,
        outcome.outcome_id,
        outcome.execution_owner_epoch
      ]
    )

    if Txn.changes(txn) != 1, do: raise("identity apply fence ownership changed")
  end

  defp guarded_update(db, outcome, worker_id, set_clause, extra_params) do
    params = [outcome.outcome_id, outcome.execution_owner_epoch, worker_id] ++ extra_params

    {:ok, changes} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE identity_apply_outcomes SET #{set_clause} WHERE outcomeId=?1 AND executionOwnerEpoch=?2 AND executorWorkerId=?3 AND phase IN ('pending','interrupting','reloading','continuation-pending')",
          params
        )

        Txn.changes(txn)
      end)

    if changes == 1, do: :ok, else: :stale
  end

  defp observed_turn_outcome_in_txn(txn, seq) do
    case Txn.q(txn, "SELECT status FROM turns WHERE seq=?1", [seq]) do
      [["delivered"]] -> "delivered"
      [["failed"]] -> "failed"
      [["failed_unknown"]] -> "failed-unknown"
      [["canceled"]] -> "canceled"
      _ -> "failed-unknown"
    end
  end

  defp delivery_turn_seq(txn, {:appended, session_key, message, _opts}) do
    case Txn.q(
           txn,
           "SELECT seq FROM turns WHERE sessionKey=?1 AND messageId=?2 ORDER BY seq DESC LIMIT 1",
           [session_key, message.id]
         ) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  defp delivery_turn_seq(txn, {:duplicate, message}) do
    case Txn.q(txn, "SELECT seq FROM turns WHERE messageId=?1 ORDER BY seq DESC LIMIT 1", [
           message.id
         ]) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  defp delivery_turn_seq(_txn, _), do: nil

  defp maybe_complete_empty_in_txn(txn, operation_id, now) do
    case Txn.q(txn, "SELECT COUNT(*) FROM identity_apply_outcomes WHERE operationId=?1", [
           operation_id
         ]) do
      [[0]] ->
        Txn.q(
          txn,
          "UPDATE identity_apply_operations SET state='completed', completedAt=?2 WHERE operationId=?1",
          [operation_id, now]
        )

        event_in_txn(txn, operation_id, nil, "completed", %{outcome: "succeeded"})

      _ ->
        maybe_complete_operation_in_txn(txn, operation_id, now)
    end
  end

  defp maybe_complete_operation_in_txn(txn, operation_id, now) do
    case Txn.q(
           txn,
           "SELECT COUNT(*) FROM identity_apply_outcomes WHERE operationId=?1 AND phase IN ('pending','interrupting','reloading','continuation-pending')",
           [operation_id]
         ) do
      [[0]] ->
        Txn.q(
          txn,
          "UPDATE identity_apply_operations SET state='completed', completedAt=COALESCE(completedAt, ?2) WHERE operationId=?1",
          [operation_id, now]
        )

        event_in_txn(txn, operation_id, nil, "completed", %{})

      _ ->
        :ok
    end
  end

  defp event_in_txn(txn, operation_id, session_key, cause, detail) do
    subject = "#{operation_id}:#{session_key || "-"}:#{cause}:#{Map.get(detail, :eventId, now())}"

    [[target_revision, request_principal]] =
      Txn.q(
        txn,
        "SELECT targetRevision, requestPrincipal FROM identity_apply_operations WHERE operationId=?1",
        [operation_id]
      )

    EventLog.lifecycle_in_txn(
      txn,
      "identity_apply_#{String.replace(cause, "-", "_")}",
      subject,
      JSON.encode!(
        Map.merge(
          %{
            operationId: operation_id,
            sessionKey: session_key,
            targetRevision: target_revision,
            requestPrincipal: request_principal,
            cause: cause
          },
          detail
        )
      )
    )
  end

  defp lifecycle_event_exists_in_txn?(txn, event_id) do
    Txn.q(txn, "SELECT 1 FROM lifecycle_events WHERE subject LIKE ?1 LIMIT 1", ["%:#{event_id}"]) !=
      []
  end

  defp recovery_event_id(outcome, ordinal, kind, call_kind) do
    basis =
      if kind in ["post_reload_commit_unavailable", "prior_context_snapshot_unavailable"],
        do: outcome.outcome_id,
        else: outcome.effect_id

    suffix =
      if kind in ["adapter_unavailable", "timed_out"],
        do: call_kind || "status",
        else: kind

    sha256(to_string(basis) <> "\0" <> Integer.to_string(ordinal) <> "\0" <> suffix)
  end

  defp recovery_delay(ordinal), do: min(5_000 * Integer.pow(2, ordinal), 60_000)

  defp outcome_from_row([
         outcome_id,
         operation_id,
         session_key,
         attempt,
         phase,
         prior_revision,
         target_revision,
         interrupted_seq,
         turn_outcome,
         reload_outcome,
         continuation_message_id,
         continuation_turn_seq,
         error_code,
         retryable,
         material_id,
         epoch,
         effect_phase,
         effect_id,
         effect_status,
         next_attempt_at,
         recovery_attempt
       ]) do
    %{
      outcome_id: outcome_id,
      operation_id: operation_id,
      session_key: session_key,
      attempt: attempt,
      state: phase,
      prior_identity_revision: prior_revision,
      target_revision: target_revision,
      interrupted_turn_seq: interrupted_seq,
      turn_outcome: turn_outcome,
      reload_outcome: reload_outcome,
      continuation_message_id: continuation_message_id,
      continuation_turn_seq: continuation_turn_seq,
      error_code: error_code,
      retryable: int_bool(retryable),
      failure_material_id: material_id,
      execution_owner_epoch: epoch,
      effect_phase: effect_phase,
      effect_id: effect_id,
      effect_status: effect_status,
      next_attempt_at: next_attempt_at,
      recovery_attempt: recovery_attempt
    }
  end

  defp public_outcome(outcome) do
    %{
      session_key: outcome.session_key,
      state: outcome.state,
      attempts: outcome.attempt,
      prior_identity_revision: outcome.prior_identity_revision,
      identity_revision: outcome.target_revision,
      interrupted_turn_seq: outcome.interrupted_turn_seq,
      turn_outcome: outcome.turn_outcome || "not-running",
      reload_outcome: outcome.reload_outcome,
      continuation_message_id: outcome.continuation_message_id,
      continuation_turn_seq: outcome.continuation_turn_seq,
      error: public_error(outcome)
    }
  end

  defp public_error(%{state: "failed"} = outcome) do
    {message, _retryable} =
      error_policy(
        outcome.error_code,
        outcome.session_key,
        outcome.target_revision,
        outcome.failure_material_id
      )

    %{
      code: outcome.error_code,
      message: message,
      retryable: outcome.retryable,
      failure_material_id: outcome.failure_material_id
    }
  end

  defp public_error(_), do: nil

  defp outcome_kind(_outcomes, false), do: nil
  defp outcome_kind([], true), do: "succeeded"

  defp outcome_kind(outcomes, true) do
    succeeded = Enum.count(outcomes, &(&1.state == "succeeded"))
    failed = Enum.count(outcomes, &(&1.state == "failed"))

    cond do
      succeeded > 0 and failed > 0 -> "partial"
      succeeded > 0 -> "succeeded"
      true -> "failed"
    end
  end

  defp error_policy("self_apply_retry_requires_new_operation", session_key, _target, _material),
    do:
      {"Self-apply for session #{session_key} restored the prior context and delivered its recovery continuation; start a new identity apply operation with a new key.",
       false}

  defp error_policy("session_retired", session_key, _target, _material),
    do:
      {"Session #{session_key} retired before retry admission; this operation will not retry it.",
       false}

  defp error_policy("apply_in_progress", session_key, _target, _material),
    do:
      {"Another identity apply operation controls session #{session_key}; retry this operation.",
       true}

  defp error_policy("apply_superseded", session_key, target, _material),
    do:
      {"Session #{session_key} already uses a newer identity revision; this operation will not replace it with #{target}.",
       false}

  defp error_policy("identity_revision_unavailable", session_key, target, _material),
    do:
      {"Identity revision #{target} is unavailable or is not a valid successor for session #{session_key}.",
       false}

  defp error_policy("turn_interruption_failed", session_key, _target, _material),
    do:
      {"Tight Beam could not durably interrupt the running turn for session #{session_key}; retry this operation.",
       true}

  defp error_policy("harness_reload_failed", session_key, _target, _material),
    do:
      {"Tight Beam could not reload identity for session #{session_key}; retry this operation.",
       true}

  defp error_policy("internal_apply_failure", session_key, _target, material),
    do:
      {"Identity apply failed for session #{session_key} with an internal error; failure material is #{material}.",
       true}

  defp controlled_envelope(value) when is_map(value), do: %{kind: "controlled-cause", type: "map"}

  defp controlled_envelope(value) when is_atom(value),
    do: %{kind: "controlled-cause", type: Atom.to_string(value)}

  defp controlled_envelope(_), do: %{kind: "unsupported", type: "inspection-failure"}

  defp receipt_state(%{"state" => state}), do: state
  defp receipt_state(%{state: state}), do: state

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0
  defp int_bool(1), do: true
  defp int_bool(0), do: false
  defp int_bool(nil), do: nil

  defp operation_id, do: "iap_" <> random_id()
  defp outcome_id, do: "iao_" <> random_id()
  defp failure_material_id, do: "ifm_" <> random_id()
  defp generated_key, do: "generated_" <> random_id()
  defp random_id, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp now, do: System.system_time(:millisecond)
end
