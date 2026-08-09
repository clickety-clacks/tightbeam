defmodule Tightbeam.Schema do
  @moduledoc "The single production-owned schema bootstrap for a Tightbeam database."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @schema_modules [
    Tightbeam.Ledger,
    Tightbeam.EventLog,
    Tightbeam.Assets,
    Tightbeam.Artifacts,
    Tightbeam.CausalEvents,
    Tightbeam.Devices,
    Tightbeam.Idempotency,
    Tightbeam.ConditionFacts,
    Tightbeam.SubagentMarkers,
    Tightbeam.Escalation,
    Tightbeam.Wakes,
    Tightbeam.Projection,
    Tightbeam.Org,
    Tightbeam.CriticalLeases,
    Tightbeam.Roles,
    Tightbeam.WorkItems,
    Tightbeam.Assignments,
    Tightbeam.EffortCheckin,
    Tightbeam.Placement,
    Tightbeam.RailRemedy,
    Tightbeam.Supervision,
    Tightbeam.WorkState,
    Tightbeam.Productions.BubbleSweeper,
    Tightbeam.HarnessProcess
  ]

  # The shape this build writes. Bump it when a production table changes in a
  # way that makes an older database unreadable, and give the refusal below a
  # sentence saying what changed.
  @shape "model-identity-v1"

  @supervision_liveness_objects [
    %{
      type: "table",
      name: "supervision_entitlements",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_entitlements (
        assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
        generation INTEGER NOT NULL CHECK (generation > 0),
        dueAt INTEGER,
        state TEXT NOT NULL CHECK (state IN ('armed','claimed','terminus')),
        lastAttemptGeneration INTEGER,
        claimClock INTEGER,
        basisKind TEXT NOT NULL CHECK (basisKind IN (
          'assignment_open','prod_scheduled','escalation_scheduled','policy_denied',
          'progress','no_terminal','parent_retirement','recovery_backfill'
        )),
        basisId TEXT NOT NULL,
        terminusAt INTEGER,
        cause TEXT NOT NULL CHECK (cause IN (
          'assignment_open','progress','deadline','new_terminal','pending_turn','pending_wake',
          'work_blocked','prod_scheduled','escalation_scheduled','policy_denied','no_terminal',
          'terminal_disposition','holder_retired','parent_elevated','terminus',
          'parent_target_retired','recovery_backfill','stale_generation'
        )),
        principal TEXT NOT NULL,
        supervisionIntervalMs INTEGER,
        CHECK (
          (state = 'armed' AND dueAt >= 0 AND supervisionIntervalMs > 0 AND
           claimClock IS NULL AND terminusAt IS NULL)
          OR
          (state = 'claimed' AND dueAt >= 0 AND supervisionIntervalMs > 0 AND
           claimClock >= 0 AND terminusAt IS NULL)
          OR
          (state = 'terminus' AND dueAt IS NULL AND supervisionIntervalMs IS NULL AND
           claimClock IS NULL AND lastAttemptGeneration IS NULL AND terminusAt >= 0)
        ),
        CHECK (
          lastAttemptGeneration IS NULL OR
          (lastAttemptGeneration > 0 AND lastAttemptGeneration <= generation)
        )
      )
      """
    },
    %{
      type: "table",
      name: "supervision_progress_absorptions",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_progress_absorptions (
        attestId TEXT PRIMARY KEY REFERENCES attests(id),
        assignmentId TEXT NOT NULL REFERENCES assignments(id),
        attestTs INTEGER NOT NULL CHECK (attestTs >= 0),
        generation INTEGER NOT NULL CHECK (generation > 0),
        recoveryBaseline INTEGER NOT NULL CHECK (recoveryBaseline IN (0,1)),
        cause TEXT NOT NULL CHECK (cause IN ('progress','recovery_backfill')),
        principal TEXT NOT NULL,
        CHECK (
          (recoveryBaseline = 0 AND cause = 'progress') OR
          (recoveryBaseline = 1 AND cause = 'recovery_backfill' AND
           principal = 'process:tightbeam')
        )
      )
      """
    },
    %{
      type: "table",
      name: "supervision_liveness_sidecar",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_liveness_sidecar (
        wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
        assignmentId TEXT NOT NULL REFERENCES assignments(id),
        controllerOrigin TEXT CHECK (controllerOrigin IN ('scheduled','retirement_elevation')),
        wakeKind TEXT CHECK (wakeKind IN ('prod','escalation')),
        controllerState TEXT CHECK (controllerState IN ('pending','settled')),
        chargedGeneration INTEGER CHECK (chargedGeneration > 0),
        transferEvidenceId TEXT,
        retirementEpoch INTEGER CHECK (retirementEpoch >= 0),
        retiringSessionKey TEXT REFERENCES sessions(sessionKey),
        retirementOutcomeKind TEXT CHECK (
          retirementOutcomeKind IN ('child_rearm','parent_elevation','main_elevation')
        ),
        retirementOutcomeId TEXT,
        retirementTargetSessionKey TEXT REFERENCES sessions(sessionKey),
        retirementCause TEXT CHECK (
          retirementCause IN ('parent_target_retired','legacy_parent_target_retired')
        ),
        retirementPrincipal TEXT,
        retirementActionNeeded INTEGER CHECK (retirementActionNeeded IN (0,1)),
        CHECK (
          (controllerOrigin IS NULL AND wakeKind IS NULL AND controllerState IS NULL AND
           chargedGeneration IS NULL)
          OR
          (controllerOrigin = 'scheduled' AND wakeKind IN ('prod','escalation') AND
           controllerState IN ('pending','settled') AND chargedGeneration > 0)
          OR
          (controllerOrigin = 'retirement_elevation' AND wakeKind = 'escalation' AND
           controllerState = 'settled' AND chargedGeneration IS NULL)
        ),
        CHECK (
          (transferEvidenceId IS NULL AND retirementEpoch IS NULL AND
           retiringSessionKey IS NULL AND retirementOutcomeKind IS NULL AND
           retirementOutcomeId IS NULL AND retirementTargetSessionKey IS NULL AND
           retirementCause IS NULL AND retirementPrincipal IS NULL AND
           retirementActionNeeded IS NULL)
          OR
          (transferEvidenceId IS NOT NULL AND retirementEpoch >= 0 AND
           retiringSessionKey IS NOT NULL AND retirementOutcomeKind IS NOT NULL AND
           retirementOutcomeId IS NOT NULL AND retirementCause IS NOT NULL AND
           retirementPrincipal IS NOT NULL AND retirementActionNeeded IN (0,1) AND
           ((retirementOutcomeKind = 'child_rearm' AND
             retirementTargetSessionKey IS NULL AND retirementActionNeeded = 0)
            OR
            (retirementOutcomeKind = 'parent_elevation' AND
             retirementTargetSessionKey IS NOT NULL AND retirementActionNeeded = 0)
            OR
            (retirementOutcomeKind = 'main_elevation' AND
             retirementTargetSessionKey IS NOT NULL AND retirementActionNeeded = 1)))
        ),
        CHECK (
          retirementCause IS NULL OR retirementCause = 'parent_target_retired' OR
          (retirementCause = 'legacy_parent_target_retired' AND
           retirementOutcomeKind = 'main_elevation' AND
           retirementPrincipal = 'process:tightbeam' AND retirementActionNeeded = 1)
        ),
        CHECK (controllerOrigin IS NOT NULL OR transferEvidenceId IS NOT NULL)
      )
      """
    },
    %{
      type: "table",
      name: "wake_cancellations",
      sql: """
      CREATE TABLE IF NOT EXISTS wake_cancellations (
        wakeId TEXT PRIMARY KEY,
        wakeState TEXT NOT NULL DEFAULT 'canceled' CHECK (wakeState = 'canceled'),
        canceledAt INTEGER NOT NULL CHECK (canceledAt >= 0),
        requesterKind TEXT NOT NULL CHECK (requesterKind IN ('user','session','process')),
        requesterId TEXT NOT NULL,
        reasonKind TEXT NOT NULL CHECK (reasonKind IN (
          'requester_withdrew','superseded','obligation_disposed',
          'routing_bracket_satisfied','target_retired','production_unmatched',
          'consumer_unavailable','target_unresolvable'
        )),
        causalSourceKind TEXT NOT NULL CHECK (causalSourceKind IN (
          'verb_call','wake','progress_attest','condition_fact','assignment_transition',
          'work_item_transition','decision_request','monitor_generation','routing_bracket',
          'session_transition','scheduler_delivery'
        )),
        causalSourceId TEXT NOT NULL,
        outcomeKind TEXT NOT NULL CHECK (
          outcomeKind IN ('replacement','disposition','no_replacement')
        ),
        replacementWakeId TEXT REFERENCES wakes(wakeId) DEFERRABLE INITIALLY DEFERRED,
        dispositionKind TEXT CHECK (dispositionKind IN (
          'assignment_transition','work_item_transition',
          'decision_request_transition','monitor_generation_transition'
        )),
        dispositionId TEXT,
        primaryWorkKind TEXT CHECK (primaryWorkKind IN ('assignment','work_item')),
        primaryWorkId TEXT,
        workImpactKind TEXT NOT NULL CHECK (
          workImpactKind IN ('no_linked_work','linked_work_not_open','linked_work_open')
        ),
        livenessTriggerKind TEXT CHECK (livenessTriggerKind IN (
          'supervision_entitlement','supervision_transfer','pending_wake','routing_bracket'
        )),
        livenessTriggerId TEXT,
        actionNeeded INTEGER NOT NULL CHECK (actionNeeded IN (0,1)),
        FOREIGN KEY (wakeId, wakeState, canceledAt)
          REFERENCES wakes(wakeId, state, canceledAt) DEFERRABLE INITIALLY DEFERRED,
        CHECK (
          (workImpactKind = 'no_linked_work' AND primaryWorkKind IS NULL AND
           primaryWorkId IS NULL)
          OR
          (workImpactKind IN ('linked_work_not_open','linked_work_open') AND
           primaryWorkKind IS NOT NULL AND primaryWorkId IS NOT NULL)
        ),
        CHECK (
          (outcomeKind = 'replacement' AND replacementWakeId IS NOT NULL AND
           replacementWakeId != wakeId AND dispositionKind IS NULL AND dispositionId IS NULL AND
           livenessTriggerKind IS NULL AND livenessTriggerId IS NULL AND actionNeeded = 0 AND
           workImpactKind != 'linked_work_not_open')
          OR
          (outcomeKind = 'disposition' AND replacementWakeId IS NULL AND
           dispositionKind IS NOT NULL AND dispositionId IS NOT NULL AND
           ((workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NOT NULL AND
             livenessTriggerId IS NOT NULL AND actionNeeded = 1)
            OR
            (workImpactKind != 'linked_work_open' AND livenessTriggerKind IS NULL AND
             livenessTriggerId IS NULL AND actionNeeded = 0)))
          OR
          (outcomeKind = 'no_replacement' AND replacementWakeId IS NULL AND
           dispositionKind IS NULL AND dispositionId IS NULL AND
           ((workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NOT NULL AND
             livenessTriggerId IS NOT NULL AND actionNeeded = 1)
            OR
            (workImpactKind != 'linked_work_open' AND livenessTriggerKind IS NULL AND
             livenessTriggerId IS NULL AND actionNeeded = 0)))
        ),
        CHECK (
          (reasonKind = 'requester_withdrew' AND causalSourceKind = 'verb_call' AND
           outcomeKind = 'no_replacement')
          OR
          (requesterKind = 'process' AND (
            (requesterId = 'tightbeam:wake-scheduler' AND
             ((reasonKind = 'production_unmatched' AND causalSourceKind = 'condition_fact' AND
               outcomeKind = 'no_replacement')
              OR
              (reasonKind IN ('consumer_unavailable','target_unresolvable') AND
               causalSourceKind = 'scheduler_delivery' AND outcomeKind = 'no_replacement')))
            OR
            (requesterId = 'tightbeam:work-items' AND
             reasonKind = 'routing_bracket_satisfied' AND
             causalSourceKind IN ('assignment_transition','work_item_transition','routing_bracket') AND
             outcomeKind IN ('replacement','disposition'))
            OR
            (requesterId = 'tightbeam:assignments' AND
             reasonKind = 'obligation_disposed' AND causalSourceKind = 'assignment_transition' AND
             outcomeKind = 'disposition')
            OR
            (requesterId = 'tightbeam:effort-checkin' AND
             ((reasonKind = 'superseded' AND
               causalSourceKind IN ('wake','monitor_generation','decision_request') AND
               outcomeKind = 'replacement')
              OR
              (reasonKind = 'obligation_disposed' AND
               causalSourceKind IN ('work_item_transition','decision_request','monitor_generation') AND
               outcomeKind = 'disposition')))
            OR
            (requesterId = 'tightbeam:supervision' AND reasonKind = 'superseded' AND
             causalSourceKind = 'progress_attest' AND outcomeKind = 'no_replacement')
            OR
            (requesterId = 'tightbeam:retirement' AND
             ((reasonKind = 'target_retired' AND causalSourceKind = 'session_transition' AND
               outcomeKind IN ('replacement','no_replacement'))
              OR
              (reasonKind = 'obligation_disposed' AND
               causalSourceKind = 'assignment_transition' AND outcomeKind = 'disposition')))
          ))
        )
      )
      """
    },
    %{
      type: "table",
      name: "supervision_liveness_epoch",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_liveness_epoch (
        id INTEGER PRIMARY KEY CHECK (id = 0),
        activatedAt INTEGER NOT NULL CHECK (activatedAt >= 0),
        cause TEXT NOT NULL CHECK (cause = 'schema_activation'),
        principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
      )
      """
    },
    %{
      type: "index",
      name: "supervision_progress_assignment",
      sql:
        "CREATE INDEX IF NOT EXISTS supervision_progress_assignment ON supervision_progress_absorptions(assignmentId, attestTs, attestId)"
    },
    %{
      type: "index",
      name: "supervision_liveness_assignment",
      sql:
        "CREATE INDEX IF NOT EXISTS supervision_liveness_assignment ON supervision_liveness_sidecar(assignmentId, wakeId)"
    },
    %{
      type: "index",
      name: "supervision_liveness_pending_controller",
      sql:
        "CREATE UNIQUE INDEX IF NOT EXISTS supervision_liveness_pending_controller ON supervision_liveness_sidecar(assignmentId) WHERE controllerState = 'pending'"
    },
    %{
      type: "index",
      name: "supervision_liveness_retirement_dedupe",
      sql:
        "CREATE UNIQUE INDEX IF NOT EXISTS supervision_liveness_retirement_dedupe ON supervision_liveness_sidecar(transferEvidenceId, retirementEpoch, retirementCause) WHERE transferEvidenceId IS NOT NULL"
    },
    %{
      type: "index",
      name: "wakes_cancellation_state",
      sql:
        "CREATE UNIQUE INDEX IF NOT EXISTS wakes_cancellation_state ON wakes(wakeId, state, canceledAt)"
    },
    %{
      type: "trigger",
      name: "wake_cancellations_pending_insert",
      sql: """
      CREATE TRIGGER IF NOT EXISTS wake_cancellations_pending_insert
      BEFORE INSERT ON wake_cancellations
      WHEN NOT EXISTS (
        SELECT 1 FROM wakes
        WHERE wakeId = NEW.wakeId AND state = 'pending' AND canceledAt IS NULL
      )
      BEGIN
        SELECT RAISE(ABORT, 'wake cancellation carrier requires a pending wake');
      END
      """
    },
    %{
      type: "trigger",
      name: "wakes_typed_cancellation_required",
      sql: """
      CREATE TRIGGER IF NOT EXISTS wakes_typed_cancellation_required
      BEFORE UPDATE OF state, canceledAt ON wakes
      WHEN NEW.state = 'canceled' AND OLD.state != 'canceled' AND NOT EXISTS (
        SELECT 1 FROM wake_cancellations c
        WHERE c.wakeId = NEW.wakeId AND c.wakeState = NEW.state AND
          c.canceledAt = NEW.canceledAt
      )
      BEGIN
        SELECT RAISE(ABORT, 'pending wake cancellation requires typed provenance');
      END
      """
    },
    %{
      type: "trigger",
      name: "wake_cancellations_append_only_update",
      sql: """
      CREATE TRIGGER IF NOT EXISTS wake_cancellations_append_only_update
      BEFORE UPDATE ON wake_cancellations
      BEGIN
        SELECT RAISE(ABORT, 'wake cancellation provenance is append-only');
      END
      """
    },
    %{
      type: "trigger",
      name: "wake_cancellations_append_only_delete",
      sql: """
      CREATE TRIGGER IF NOT EXISTS wake_cancellations_append_only_delete
      BEFORE DELETE ON wake_cancellations
      BEGIN
        SELECT RAISE(ABORT, 'wake cancellation provenance is append-only');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_liveness_retirement_immutable_update",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_liveness_retirement_immutable_update
      BEFORE UPDATE ON supervision_liveness_sidecar
      WHEN OLD.transferEvidenceId IS NOT NULL
      BEGIN
        SELECT RAISE(ABORT, 'supervision retirement outcome is immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_liveness_retirement_immutable_delete",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_liveness_retirement_immutable_delete
      BEFORE DELETE ON supervision_liveness_sidecar
      WHEN OLD.transferEvidenceId IS NOT NULL
      BEGIN
        SELECT RAISE(ABORT, 'supervision retirement outcome is immutable');
      END
      """
    }
  ]

  defmodule ShapeError do
    @moduledoc "A database whose shape this build cannot read. Never repaired in place."
    defexception [:message]
  end

  @doc """
  Create every production schema in dependency-safe order.

  Refuses a database this build cannot read. Every `ensure_schema/1` below is
  `CREATE TABLE IF NOT EXISTS`, which is silent about a table that already
  exists in an OLDER shape: it adds no column, so the first query naming one
  dies as an accidental `no such column`, and a column added by hand would be
  worse — `sessions.model` from before the structured identity holds packed
  values like `claude-fable-5[1m]`, which this build would read as a FAMILY.
  A wrong answer, from data that was right when it was written.

  So the shape is STAMPED at creation and CHECKED here, per the house rule: a
  missing or unknown stamp is a refusal and a bug report, never an inference.
  Note the direction — the one existence question below is asked to REFUSE,
  never to deduce a shape and accommodate it. Nothing here migrates, ALTERs,
  or sniffs stored DDL, and nothing should learn to.
  """
  @spec ensure_all(DB.server()) :: :ok
  def ensure_all(db) do
    :ok = ensure_stamp_table(db)
    :ok = check_shape(db)

    Enum.each(@schema_modules, fn module ->
      :ok = module.ensure_schema(db)
    end)

    activated_at = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           ensure_supervision_liveness_v1_in_txn(txn, activated_at)
         end) do
      {:ok, :ok} ->
        :ok

      {:error, %ShapeError{} = error} ->
        raise error

      {:error, error} ->
        raise ShapeError,
          message:
            "incompatible_supervision_liveness_v1: additive activation failed: #{Exception.message(error)}"
    end
  end

  @doc false
  @spec ensure_supervision_liveness_v1_in_txn(Txn.t()) :: :ok
  def ensure_supervision_liveness_v1_in_txn(%Txn{} = txn) do
    ensure_supervision_liveness_v1_in_txn(txn, System.system_time(:millisecond))
  end

  @doc false
  @spec ensure_supervision_liveness_v1_in_txn(Txn.t(), non_neg_integer()) :: :ok
  def ensure_supervision_liveness_v1_in_txn(%Txn{} = txn, activated_at) do
    ensure_supervision_liveness_v1_in_txn(txn, activated_at, [])
  end

  @doc false
  @spec ensure_supervision_liveness_v1_in_txn(Txn.t(), non_neg_integer(), keyword()) :: :ok
  def ensure_supervision_liveness_v1_in_txn(%Txn{} = txn, activated_at, opts)
      when is_integer(activated_at) and activated_at >= 0 and is_list(opts) do
    present = Enum.filter(@supervision_liveness_objects, &owned_object_present?(txn, &1))
    Enum.each(present, &validate_owned_object!(txn, &1))

    case length(present) do
      0 ->
        @supervision_liveness_objects
        |> Enum.with_index(1)
        |> Enum.each(fn {object, index} ->
          :ok = Txn.exec(txn, object.sql)
          validate_owned_object!(txn, object)
          maybe_interrupt_activation!(opts, index)
        end)

        Txn.q(
          txn,
          """
          INSERT INTO supervision_liveness_epoch
            (id, activatedAt, cause, principal)
          VALUES (0, ?1, 'schema_activation', 'process:tightbeam')
          """,
          [activated_at]
        )

        maybe_interrupt_activation!(opts, length(@supervision_liveness_objects) + 1)

      count when count == length(@supervision_liveness_objects) ->
        :ok

      _count ->
        missing =
          @supervision_liveness_objects
          |> Kernel.--(present)
          |> Enum.map_join(", ", & &1.name)

        incompatible_supervision_liveness!("incomplete additive shape; missing #{missing}")
    end

    validate_activation_epoch!(txn)
    :ok
  end

  def ensure_supervision_liveness_v1_in_txn(%Txn{}, _activated_at, _opts) do
    incompatible_supervision_liveness!("activation epoch must be a nonnegative integer")
  end

  defp owned_object_present?(txn, %{type: type, name: name}) do
    case Txn.q(
           txn,
           "SELECT 1 FROM sqlite_master WHERE type = ?1 AND name = ?2",
           [type, name]
         ) do
      [] -> false
      [[1]] -> true
      _rows -> incompatible_supervision_liveness!("duplicate owned object #{name}")
    end
  end

  defp validate_owned_object!(txn, %{type: type, name: name, sql: expected_sql}) do
    case Txn.q(
           txn,
           "SELECT sql FROM sqlite_master WHERE type = ?1 AND name = ?2",
           [type, name]
         ) do
      [[actual_sql]] when is_binary(actual_sql) ->
        if normalize_schema_sql(actual_sql) == normalize_schema_sql(expected_sql) do
          :ok
        else
          incompatible_supervision_liveness!("malformed owned object #{name}")
        end

      [] ->
        incompatible_supervision_liveness!("missing owned object #{name}")

      _rows ->
        incompatible_supervision_liveness!("duplicate owned object #{name}")
    end
  end

  defp normalize_schema_sql(sql) do
    sql
    |> String.downcase()
    |> String.replace(~r/\bif\s+not\s+exists\b/u, "")
    |> String.replace(~r/\s+/u, "")
    |> String.trim_trailing(";")
  end

  defp maybe_interrupt_activation!(opts, statement_index) do
    if Keyword.get(opts, :fail_after_statement) == statement_index do
      raise "forced activation interruption"
    end

    :ok
  end

  defp validate_activation_epoch!(txn) do
    case Txn.q(
           txn,
           "SELECT id, activatedAt, cause, principal FROM supervision_liveness_epoch ORDER BY id"
         ) do
      [[0, activated_at, "schema_activation", "process:tightbeam"]]
      when is_integer(activated_at) and activated_at >= 0 ->
        :ok

      _rows ->
        incompatible_supervision_liveness!("malformed supervision_liveness_epoch row")
    end
  end

  defp incompatible_supervision_liveness!(detail) do
    raise ShapeError, message: "incompatible_supervision_liveness_v1: #{detail}"
  end

  defp ensure_stamp_table(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS schema_stamp (
      shape     TEXT PRIMARY KEY,
      stampedAt INTEGER NOT NULL
    );
    """)
  end

  defp check_shape(db) do
    case DB.query(db, "SELECT shape FROM schema_stamp") do
      {:ok, [[@shape]]} ->
        :ok

      {:ok, []} ->
        # No stamp. Either a database this build is about to create, or one
        # written before stamping existed. Those are DIFFERENT, and telling
        # them apart is the whole point — an unstamped database with a
        # `sessions` table in it predates the structured model identity.
        unstamped(db)

      {:ok, [[found]]} ->
        raise ShapeError, """
        this Tightbeam database was written by a different build.

          stamped: #{found}
          this build: #{@shape}

        There is no migration. Move the database aside and let it be recreated.
        """

      # More than one shape stamped. Nothing writes a second row, so this is a
      # database in a state this build has no reading for — which is a refusal
      # like any other, not an unhandled case falling out as a CaseClauseError.
      {:ok, [_ | _] = rows} ->
        raise ShapeError, """
        this Tightbeam database carries MORE THAN ONE shape stamp.

          stamped: #{rows |> List.flatten() |> Enum.join(", ")}
          this build: #{@shape}

        Nothing in Tightbeam writes a second stamp, so this database was
        assembled by something else. Move it aside and let it be recreated.
        """
    end
  end

  # A FRESH DATABASE MUST NEVER BE REFUSED, which is why the stamp is written
  # HERE — before a single table exists — rather than after the modules run.
  # Stamped last, a bootstrap interrupted between `sessions` and the stamp left
  # an unstamped database WITH sessions, indistinguishable from a genuinely old
  # one, and the next boot refused a database this build had just created. The
  # absence class again: "interrupted fresh bootstrap" and "genuine old
  # database" sharing one representation.
  #
  # Stamping first cannot lose that way. Interrupted after the stamp, the next
  # boot reads its own shape and carries on creating what is missing, which is
  # exactly what `CREATE TABLE IF NOT EXISTS` is for.
  defp unstamped(db) do
    case DB.query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'") do
      {:ok, []} ->
        stamp(db)

      {:ok, [_ | _]} ->
        raise ShapeError, """
        this Tightbeam database predates the structured model identity (#{@shape}).

        Its `sessions` table carries no shape stamp, so its `model` column holds
        PACKED identifiers — `claude-fable-5[1m]` meaning a 1M-context model —
        and `thinkingLevel`/`modelContext` were never written. This build reads
        those three columns as separate fields, so it would take the whole
        packed string as the model's family and silently run the wrong model.

        There is no migration and nothing here will repair it. Move the database
        aside and let it be recreated.
        """
    end
  end

  defp stamp(db) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT OR IGNORE INTO schema_stamp (shape, stampedAt) VALUES (?1, ?2)",
        [@shape, System.system_time(:millisecond)]
      )

    :ok
  end
end
