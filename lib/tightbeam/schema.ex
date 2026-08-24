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
    Tightbeam.CommandExecutions,
    Tightbeam.EffortCheckin,
    Tightbeam.Placement,
    Tightbeam.RecurrenceSuppression,
    Tightbeam.RailRemedy,
    Tightbeam.Supervision,
    Tightbeam.WorkState,
    Tightbeam.Productions.BubbleSweeper,
    Tightbeam.HarnessProcess,
    Tightbeam.HarnessHealth
  ]

  # The shape this build writes. Bump it when a production table changes in a
  # way that makes an older database unreadable, and give the refusal below a
  # sentence saying what changed.
  @shape "pi-harness-v1"
  @operator_decision_shape "operator-decision-requests-v1"
  @model_identity_shape "model-identity-v1"
  @pi_provider_values "'anthropic','openai','opencode_go'" <>
                        if(Application.compile_env(:tightbeam, :fixture_harness, false),
                          do: ",'fixture_provider'",
                          else: ""
                        )

  @sessions_indexes_ddl """
  CREATE INDEX sessions_owner ON sessions (ownerUserId, state);
  CREATE UNIQUE INDEX sessions_cli_token ON sessions(cliToken);
  """

  # The one predecessor shape this build can migrate. This is deliberately a
  # complete target table, not an ALTER inferred from sqlite_master: the stamp
  # identifies the exact source contract, and this DDL names the exact target.
  # The temporary name also keeps the live request-site audit honest: this is a
  # bulk schema copy, not a new decision request that owes a prompt wake.
  @operator_decision_requests_ddl """
  CREATE TABLE decision_requests_new (
    id                TEXT PRIMARY KEY,
    kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort','operator')),
    raiserId          TEXT NOT NULL,
    raiserSessionKey  TEXT,
    ownerUserId       TEXT NOT NULL,
    assignmentId      TEXT,
    expecterSessionKey TEXT,
    expecterUserId    TEXT,
    lineageRung       INTEGER,
    effortGeneration  INTEGER,
    deadlineWakeId    TEXT,
    raisedAt          INTEGER NOT NULL,
    deadlineAt        INTEGER NOT NULL,
    statuteName       TEXT,
    actionKey         TEXT,
    question          TEXT NOT NULL,
    options           TEXT,
    context           TEXT NOT NULL,
    status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded')),
    decision          TEXT,
    rationale         TEXT,
    ruledBy           TEXT,
    ruledViaSessionKey TEXT,
    ruledAt           INTEGER,
    rulingFactId      INTEGER,
    consumedAt        INTEGER,
    parkWakeId        TEXT,
    withdrawnBy       TEXT,
    withdrawnReason   TEXT,
    withdrawnAt       INTEGER,
    CHECK (
      (kind = 'statute' AND statuteName IS NOT NULL AND actionKey IS NOT NULL
       AND expecterSessionKey IS NULL AND expecterUserId IS NULL
       AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
       AND ruledViaSessionKey IS NULL
       AND (decision IS NULL OR decision IN ('allow','deny','waived')))
      OR
      (kind = 'effort' AND raiserId = 'process:tightbeam'
       AND raiserSessionKey IS NULL
       AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
       AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
       AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
       AND ruledViaSessionKey IS NULL
       AND (decision IS NULL OR decision IN ('continue','dismiss')))
      OR
      (kind = 'operator'
       AND raiserSessionKey IS NOT NULL
       AND statuteName IS NULL AND actionKey IS NOT NULL
       AND expecterSessionKey IS NULL AND expecterUserId IS NULL
       AND lineageRung IS NULL AND effortGeneration IS NULL
       AND deadlineWakeId IS NULL
       AND options IS NOT NULL
       AND parkWakeId IS NULL AND consumedAt IS NULL
       AND status <> 'consumed'
       AND (
         (status = 'ruled'
          AND decision IS NOT NULL
          AND ruledBy = 'user:' || ownerUserId
          AND ruledAt IS NOT NULL AND rulingFactId IS NOT NULL)
         OR
         (status <> 'ruled'
          AND decision IS NULL AND rationale IS NULL
          AND ruledBy IS NULL AND ruledAt IS NULL AND rulingFactId IS NULL
          AND ruledViaSessionKey IS NULL)
       ))
    )
  );
  """

  @operator_decision_requests_indexes_ddl """
  CREATE INDEX decision_requests_owner
    ON decision_requests (ownerUserId, status);
  CREATE INDEX decision_requests_key
    ON decision_requests (raiserId, statuteName, actionKey);
  CREATE UNIQUE INDEX decision_requests_one_open
    ON decision_requests (raiserId, statuteName, actionKey)
    WHERE kind = 'statute' AND status = 'open';
  CREATE UNIQUE INDEX decision_requests_effort_generation
    ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
  CREATE UNIQUE INDEX decision_requests_operator_open
    ON decision_requests (ownerUserId, raiserId, actionKey)
    WHERE kind = 'operator' AND status = 'open';
  """

  @operator_messages_ddl """
  CREATE TABLE messages_new (
    seq                    INTEGER PRIMARY KEY AUTOINCREMENT,
    id                     TEXT NOT NULL UNIQUE,
    sessionKey             TEXT NOT NULL,
    role                   TEXT NOT NULL CHECK (role IN ('user','assistant')),
    content                TEXT NOT NULL,
    timestamp              INTEGER NOT NULL,
    sender                 TEXT,
    deviceId               TEXT,
    clientMessageId        TEXT,
    replyToMessageId       TEXT,
    replyToClientMessageId TEXT,
    llmVisibleMessageId    TEXT NOT NULL,
    attachments            TEXT NOT NULL DEFAULT '[]',
    attentionTier          INTEGER NOT NULL DEFAULT 0,
    messageType            TEXT,
    markerKind             TEXT CHECK (
      markerKind IS NULL OR markerKind IN ('harness-switch','model-retune','session-restart')
    ),
    markerFrom             TEXT,
    markerTo               TEXT,
    CHECK (
      (messageType IS 'marker' AND markerKind IS NOT NULL AND markerFrom IS NOT NULL AND markerTo IS NOT NULL)
      OR
      (messageType IS NOT 'marker' AND markerKind IS NULL AND markerFrom IS NULL AND markerTo IS NULL)
    )
  );
  """

  @operator_messages_indexes_ddl """
  CREATE INDEX messages_session ON messages (sessionKey, seq);
  CREATE UNIQUE INDEX messages_client_dedupe
    ON messages (sessionKey, deviceId, clientMessageId)
    WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL;
  """

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

  # Added after the v1 activation shipped, so this cannot join the all-or-none
  # activation list above: existing v1 databases legitimately have every base
  # object and not this trigger. It is still owned and shape-validated, and is
  # installed in the same schema transaction on the next boot.
  @supervision_liveness_enforcement_objects [
    %{
      type: "table",
      name: "supervision_liveness_receipt_state",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_liveness_receipt_state (
        assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
        artifactCursor INTEGER NOT NULL CHECK (artifactCursor >= 0),
        attestCursor INTEGER NOT NULL CHECK (attestCursor >= 0),
        workItemEventCursor INTEGER NOT NULL CHECK (workItemEventCursor >= 0),
        wakeCursor INTEGER NOT NULL CHECK (wakeCursor >= 0),
        baselineCause TEXT NOT NULL CHECK (baselineCause IN (
          'assignment_open','first_prod','recovery_backfill'
        )),
        baselinePrincipal TEXT NOT NULL
      )
      """
    },
    %{
      type: "table",
      name: "supervision_liveness_receipts",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_liveness_receipts (
        receiptId INTEGER PRIMARY KEY AUTOINCREMENT,
        assignmentId TEXT NOT NULL REFERENCES assignments(id),
        sourceKind TEXT NOT NULL CHECK (sourceKind IN (
          'artifact','work_item_update','verdict','checkpoint'
        )),
        sourceId TEXT NOT NULL,
        sourceAt INTEGER NOT NULL CHECK (sourceAt >= 0),
        acceptedAt INTEGER NOT NULL CHECK (acceptedAt >= 0),
        generation INTEGER NOT NULL CHECK (generation > 0),
        expiresAt INTEGER CHECK (expiresAt >= 0),
        UNIQUE (assignmentId, sourceKind, sourceId),
        CHECK (
          (sourceKind = 'checkpoint' AND expiresAt > acceptedAt)
          OR
          (sourceKind != 'checkpoint' AND expiresAt IS NULL)
        )
      )
      """
    },
    %{
      type: "index",
      name: "supervision_liveness_receipts_assignment",
      sql:
        "CREATE INDEX IF NOT EXISTS supervision_liveness_receipts_assignment ON supervision_liveness_receipts(assignmentId, receiptId)"
    },
    %{
      type: "table",
      name: "supervision_liveness_checkpoint_bindings",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_liveness_checkpoint_bindings (
        wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
        assignmentId TEXT NOT NULL REFERENCES assignments(id),
        holderSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
        sourceTurnSeq INTEGER NOT NULL REFERENCES turns(seq),
        boundAt INTEGER NOT NULL CHECK (boundAt >= 0),
        principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
      )
      """
    },
    %{
      type: "trigger",
      name: "supervision_checkpoint_binding_insert_coherent",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_checkpoint_binding_insert_coherent
      BEFORE INSERT ON supervision_liveness_checkpoint_bindings
      WHEN NOT EXISTS (
        SELECT 1
        FROM wakes w
        JOIN assignments a ON a.id=NEW.assignmentId
        JOIN turns t ON t.seq=NEW.sourceTurnSeq
        JOIN supervision_entitlements e ON e.assignmentId=a.id
        WHERE w.wakeId=NEW.wakeId
          AND w.sessionKey=NEW.holderSessionKey
          AND w.creatorSessionKey=NEW.holderSessionKey
          AND w.consumer='prompt' AND w.state='pending'
          AND w.dueAt > w.createdAt
          AND a.holderKey=NEW.holderSessionKey AND a.state='open'
          AND t.sessionKey=NEW.holderSessionKey AND t.status='running'
          AND t.assignmentId=NEW.assignmentId
          AND e.state IN ('armed','claimed')
      )
      BEGIN
        SELECT RAISE(ABORT, 'supervision checkpoint binding requires a running held assignment');
      END
      """
    },
    %{
      type: "table",
      name: "supervision_liveness_migrations",
      sql: """
      CREATE TABLE IF NOT EXISTS supervision_liveness_migrations (
        migrationId TEXT PRIMARY KEY,
        appliedAt INTEGER NOT NULL,
        affectedRows INTEGER NOT NULL CHECK (affectedRows >= 0),
        cause TEXT NOT NULL,
        principal TEXT NOT NULL
      )
      """
    },
    %{
      type: "trigger",
      name: "supervision_liveness_sidecar_insert_coherent",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_liveness_sidecar_insert_coherent
      BEFORE INSERT ON supervision_liveness_sidecar
      WHEN NOT EXISTS (
        SELECT 1 FROM wakes w
        WHERE w.wakeId=NEW.wakeId AND w.assignmentId=NEW.assignmentId
          AND w.consumer='prompt' AND w.origin='process:tightbeam'
      )
      OR (
        NEW.controllerOrigin IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM wakes w
          WHERE w.wakeId=NEW.wakeId AND w.assignmentId=NEW.assignmentId
            AND w.state='pending' AND w.consumer='prompt'
            AND w.origin='process:tightbeam'
            AND (
              (NEW.wakeKind='prod' AND w.reresolve IS NULL
               AND w.reresolveSeed IS NULL AND w.reresolveRung IS NULL)
              OR
              (NEW.wakeKind='escalation' AND w.reresolve='lineage'
               AND w.reresolveSeed IS NOT NULL AND w.reresolveRung > 0)
            )
        )
      )
      BEGIN
        SELECT RAISE(ABORT, 'supervision sidecar requires coherent pending wake');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_pending_controller_sidecar_update",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_pending_controller_sidecar_update
      BEFORE UPDATE ON supervision_liveness_sidecar
      WHEN OLD.controllerOrigin='scheduled' AND OLD.controllerState='pending'
        AND EXISTS (
          SELECT 1 FROM wakes w
          WHERE w.wakeId=OLD.wakeId AND w.assignmentId=OLD.assignmentId
            AND w.state='pending'
        )
        AND NOT (
          NEW.wakeId IS OLD.wakeId AND NEW.assignmentId IS OLD.assignmentId
          AND NEW.controllerOrigin IS OLD.controllerOrigin
          AND NEW.wakeKind IS OLD.wakeKind
          AND NEW.chargedGeneration IS OLD.chargedGeneration
          AND NEW.transferEvidenceId IS OLD.transferEvidenceId
          AND NEW.retirementEpoch IS OLD.retirementEpoch
          AND NEW.retiringSessionKey IS OLD.retiringSessionKey
          AND NEW.retirementOutcomeKind IS OLD.retirementOutcomeKind
          AND NEW.retirementOutcomeId IS OLD.retirementOutcomeId
          AND NEW.retirementTargetSessionKey IS OLD.retirementTargetSessionKey
          AND NEW.retirementCause IS OLD.retirementCause
          AND NEW.retirementPrincipal IS OLD.retirementPrincipal
          AND NEW.retirementActionNeeded IS OLD.retirementActionNeeded
          AND NEW.controllerState='settled'
        )
      BEGIN
        SELECT RAISE(ABORT, 'pending supervision controller permits settlement only');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_pending_controller_sidecar_delete",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_pending_controller_sidecar_delete
      BEFORE DELETE ON supervision_liveness_sidecar
      WHEN OLD.controllerOrigin='scheduled' AND OLD.controllerState='pending'
        AND EXISTS (
          SELECT 1 FROM wakes w
          WHERE w.wakeId=OLD.wakeId AND w.assignmentId=OLD.assignmentId
            AND w.state='pending'
        )
      BEGIN
        SELECT RAISE(ABORT, 'pending supervision controller sidecar is required');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_pending_controller_wake_identity_immutable",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_pending_controller_wake_identity_immutable
      BEFORE UPDATE OF wakeId, sessionKey, origin, consumer, assignmentId,
                       reresolve, reresolveSeed, reresolveRung
      ON wakes
      WHEN OLD.state='pending'
        AND EXISTS (
          SELECT 1 FROM supervision_liveness_sidecar s
          WHERE s.wakeId=OLD.wakeId AND s.assignmentId=OLD.assignmentId
            AND s.controllerOrigin='scheduled' AND s.controllerState='pending'
        )
        AND (
          NEW.wakeId IS NOT OLD.wakeId OR NEW.sessionKey IS NOT OLD.sessionKey
          OR NEW.origin IS NOT OLD.origin OR NEW.consumer IS NOT OLD.consumer
          OR NEW.assignmentId IS NOT OLD.assignmentId
          OR NEW.reresolve IS NOT OLD.reresolve
          OR NEW.reresolveSeed IS NOT OLD.reresolveSeed
          OR NEW.reresolveRung IS NOT OLD.reresolveRung
        )
      BEGIN
        SELECT RAISE(ABORT, 'pending supervision controller wake identity is immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_lineage_fire_requires_sidecar",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_lineage_fire_requires_sidecar
      BEFORE UPDATE OF state ON wakes
      WHEN OLD.state = 'pending' AND NEW.state = 'fired'
        AND NEW.consumer = 'prompt'
        AND NEW.origin = 'process:tightbeam'
        AND NEW.assignmentId IS NOT NULL
        AND NEW.reresolve = 'lineage'
        AND (
          NOT EXISTS (
            SELECT 1 FROM supervision_liveness_sidecar s
            WHERE s.wakeId = NEW.wakeId AND s.assignmentId = NEW.assignmentId
              AND s.wakeKind = 'escalation'
              AND (
                (s.controllerOrigin = 'scheduled' AND s.controllerState = 'settled'
                 AND s.chargedGeneration > 0)
                OR
                (s.controllerOrigin = 'retirement_elevation' AND s.controllerState = 'settled'
                 AND s.chargedGeneration IS NULL)
              )
          )
          OR NOT EXISTS (
            SELECT 1 FROM turns t
            WHERE t.wakeId = NEW.wakeId AND t.assignmentId = NEW.assignmentId
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'supervision lineage wake requires controller sidecar');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_fired_lineage_sidecar_required_delete",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_fired_lineage_sidecar_required_delete
      BEFORE DELETE ON supervision_liveness_sidecar
      WHEN EXISTS (
        SELECT 1 FROM wakes w
        WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
          AND w.state = 'fired' AND w.consumer = 'prompt'
          AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
      )
      BEGIN
        SELECT RAISE(ABORT, 'fired supervision lineage sidecar is required');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_fired_lineage_sidecar_identity_immutable",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_fired_lineage_sidecar_identity_immutable
      BEFORE UPDATE OF wakeId, assignmentId, controllerOrigin, wakeKind, controllerState,
                       chargedGeneration
      ON supervision_liveness_sidecar
      WHEN EXISTS (
        SELECT 1 FROM wakes w
        WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
          AND w.state = 'fired' AND w.consumer = 'prompt'
          AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
      )
      BEGIN
        SELECT RAISE(ABORT, 'fired supervision lineage sidecar identity is immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_fired_lineage_turn_immutable_update",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_fired_lineage_turn_immutable_update
      BEFORE UPDATE OF seq, sessionKey, wakeId, assignmentId ON turns
      WHEN EXISTS (
        SELECT 1 FROM wakes w
        WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
          AND w.state = 'fired' AND w.consumer = 'prompt'
          AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
      )
        AND (
          NEW.seq IS NOT OLD.seq OR NEW.sessionKey IS NOT OLD.sessionKey
          OR NEW.wakeId IS NOT OLD.wakeId OR NEW.assignmentId IS NOT OLD.assignmentId
        )
      BEGIN
        SELECT RAISE(ABORT, 'fired supervision lineage turn attribution is immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_fired_lineage_turn_immutable_delete",
      sql: """
      CREATE TRIGGER IF NOT EXISTS supervision_fired_lineage_turn_immutable_delete
      BEFORE DELETE ON turns
      WHEN EXISTS (
        SELECT 1 FROM wakes w
        WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
          AND w.state = 'fired' AND w.consumer = 'prompt'
          AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
      )
      BEGIN
        SELECT RAISE(ABORT, 'fired supervision lineage turn is required');
      END
      """
    }
  ]

  defmodule ShapeError do
    @moduledoc "A database whose stamped shape this build cannot read or migrate exactly."
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
  never to deduce a shape and accommodate it. The sole migration is selected
  by the exact `model-identity-v1` stamp; it does not sniff stored DDL.
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

    Enum.each(@supervision_liveness_enforcement_objects, fn object ->
      if owned_object_present?(txn, object) do
        validate_owned_object!(txn, object)
      else
        :ok = Txn.exec(txn, object.sql)
        validate_owned_object!(txn, object)
      end
    end)

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

      {:ok, [[@operator_decision_shape]]} ->
        migrate_pi_harness_v1(db)

      {:ok, [[@model_identity_shape]]} ->
        migrate_model_identity_v1(db)
        migrate_pi_harness_v1(db)

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

        This build can migrate #{@model_identity_shape} through
        #{@operator_decision_shape} to #{@shape}.

        No migration is defined for the stamped shape above. Keep the database
        in place and run a Tightbeam build that recognizes that exact stamp.
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

  defp migrate_model_identity_v1(db) do
    # SQLite checks child rows during DROP TABLE even when constraints are
    # deferred. The DB owner is the only connection and serializes this whole
    # call, so suspend enforcement around the transaction, verify every FK
    # before commit, and restore enforcement even when the transaction raises.
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    try do
      case DB.transaction(db, &migrate_model_identity_v1_in_txn/1) do
        {:ok, :ok} ->
          :ok

        {:error, %ShapeError{} = error} ->
          raise error

        {:error, error} ->
          raise ShapeError,
            message:
              "migration #{@model_identity_shape} -> #{@operator_decision_shape} failed and was rolled back: #{Exception.message(error)}"
      end
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys = ON")
    end
  end

  defp migrate_model_identity_v1_in_txn(%Txn{} = txn) do
    # Read every commissioned population before any DDL. A missing table is an
    # incompatible instance of the stamped predecessor and fails the transaction;
    # the values are preservation checks, never inputs used to infer a shape.
    [[decision_request_count]] = Txn.q(txn, "SELECT COUNT(*) FROM decision_requests")
    [[wake_count]] = Txn.q(txn, "SELECT COUNT(*) FROM wakes")
    [[message_count]] = Txn.q(txn, "SELECT COUNT(*) FROM messages")

    :ok =
      Txn.exec(txn, "ALTER TABLE decision_requests RENAME TO decision_requests_model_identity_v1")

    :ok =
      Txn.exec(
        txn,
        """
        DROP INDEX decision_requests_owner;
        DROP INDEX decision_requests_key;
        DROP INDEX decision_requests_one_open;
        DROP INDEX decision_requests_effort_generation;
        #{@operator_decision_requests_ddl}
        """
      )

    Txn.q(
      txn,
      """
      INSERT INTO decision_requests_new (
        id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
        expecterSessionKey, expecterUserId, lineageRung, effortGeneration,
        deadlineWakeId, raisedAt, deadlineAt, statuteName, actionKey, question,
        options, context, status, decision, rationale, ruledBy,
        ruledViaSessionKey, ruledAt, rulingFactId, consumedAt, parkWakeId,
        withdrawnBy, withdrawnReason, withdrawnAt
      )
      SELECT
        id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
        expecterSessionKey, expecterUserId, lineageRung, effortGeneration,
        deadlineWakeId, raisedAt, deadlineAt, statuteName, actionKey, question,
        options, context, status, decision, rationale, ruledBy,
        NULL, ruledAt, rulingFactId, consumedAt, parkWakeId,
        withdrawnBy, withdrawnReason, withdrawnAt
      FROM decision_requests_model_identity_v1
      """
    )

    if Txn.changes(txn) != decision_request_count do
      raise ShapeError,
        message:
          "migration #{@model_identity_shape} -> #{@operator_decision_shape} copied #{Txn.changes(txn)} of #{decision_request_count} decision requests"
    end

    [[^decision_request_count]] = Txn.q(txn, "SELECT COUNT(*) FROM decision_requests_new")
    [[^wake_count]] = Txn.q(txn, "SELECT COUNT(*) FROM wakes")

    :ok = Txn.exec(txn, @operator_messages_ddl)

    Txn.q(
      txn,
      """
      INSERT INTO messages_new (
        seq, id, sessionKey, role, content, timestamp, sender, deviceId,
        clientMessageId, replyToMessageId, replyToClientMessageId,
        llmVisibleMessageId, attachments, attentionTier,
        messageType, markerKind, markerFrom, markerTo
      )
      SELECT
        seq, id, sessionKey, role, content, timestamp, sender, deviceId,
        clientMessageId, replyToMessageId, replyToClientMessageId,
        llmVisibleMessageId, attachments, attentionTier,
        NULL, NULL, NULL, NULL
      FROM messages
      """
    )

    if Txn.changes(txn) != message_count do
      raise ShapeError,
        message:
          "migration #{@model_identity_shape} -> #{@operator_decision_shape} copied #{Txn.changes(txn)} of #{message_count} messages"
    end

    [[^message_count]] = Txn.q(txn, "SELECT COUNT(*) FROM messages_new")

    :ok =
      Txn.exec(
        txn,
        """
        DROP TABLE decision_requests_model_identity_v1;
        ALTER TABLE decision_requests_new RENAME TO decision_requests;
        #{@operator_decision_requests_indexes_ddl}
        DROP INDEX messages_session;
        DROP INDEX messages_client_dedupe;
        DROP TABLE messages;
        ALTER TABLE messages_new RENAME TO messages;
        #{@operator_messages_indexes_ddl}
        """
      )

    case Txn.q(txn, "PRAGMA foreign_key_check") do
      [] ->
        :ok

      rows ->
        raise ShapeError,
          message:
            "migration #{@model_identity_shape} -> #{@operator_decision_shape} left invalid foreign keys: #{inspect(rows)}"
    end

    Txn.q(
      txn,
      "UPDATE schema_stamp SET shape = ?1, stampedAt = ?2 WHERE shape = ?3",
      [@operator_decision_shape, System.system_time(:millisecond), @model_identity_shape]
    )

    if Txn.changes(txn) != 1 do
      raise ShapeError,
        message:
          "migration #{@model_identity_shape} -> #{@operator_decision_shape} lost its exact stamp transition"
    end

    :ok
  end

  defp migrate_pi_harness_v1(db) do
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    try do
      case DB.transaction(db, &migrate_pi_harness_v1_in_txn/1) do
        {:ok, :ok} ->
          :ok

        {:error, %ShapeError{} = error} ->
          raise error

        {:error, error} ->
          raise ShapeError,
            message:
              "migration #{@operator_decision_shape} -> #{@shape} failed and was rolled back: #{Exception.message(error)}"
      end
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys = ON")
    end
  end

  defp migrate_pi_harness_v1_in_txn(%Txn{} = txn) do
    [[session_count]] = Txn.q(txn, "SELECT COUNT(*) FROM sessions")

    :ok = Txn.exec(txn, pi_sessions_ddl())

    Txn.q(
      txn,
      """
      INSERT INTO sessions_new (
        sessionKey, displayName, kind, orderIndex, isBuiltIn, adopted,
        ownerUserId, origin, spawnedBy, handle, archetype, overrides,
        identityName, identityRevision, cliToken, harness, provider, model,
        thinkingLevel, modelContext, host, clearedThroughSeq, state, createdAt, updatedAt
      )
      SELECT
        sessionKey, displayName, kind, orderIndex, isBuiltIn, adopted,
        ownerUserId, origin, spawnedBy, handle, archetype, overrides,
        identityName, identityRevision, cliToken, harness, provider, model,
        thinkingLevel, modelContext, host, clearedThroughSeq, state, createdAt, updatedAt
      FROM sessions
      """
    )

    if Txn.changes(txn) != session_count do
      raise ShapeError,
        message:
          "migration #{@operator_decision_shape} -> #{@shape} copied #{Txn.changes(txn)} of #{session_count} sessions"
    end

    [[^session_count]] = Txn.q(txn, "SELECT COUNT(*) FROM sessions_new")

    :ok =
      Txn.exec(
        txn,
        """
        DROP INDEX sessions_owner;
        DROP INDEX sessions_cli_token;
        DROP TABLE sessions;
        ALTER TABLE sessions_new RENAME TO sessions;
        #{@sessions_indexes_ddl}
        """
      )

    case Txn.q(txn, "PRAGMA foreign_key_check") do
      [] ->
        :ok

      rows ->
        raise ShapeError,
          message:
            "migration #{@operator_decision_shape} -> #{@shape} left invalid foreign keys: #{inspect(rows)}"
    end

    Txn.q(
      txn,
      "UPDATE schema_stamp SET shape = ?1, stampedAt = ?2 WHERE shape = ?3",
      [@shape, System.system_time(:millisecond), @operator_decision_shape]
    )

    if Txn.changes(txn) != 1 do
      raise ShapeError,
        message:
          "migration #{@operator_decision_shape} -> #{@shape} lost its exact stamp transition"
    end

    :ok
  end

  defp pi_sessions_ddl do
    harnesses = Enum.map_join(Tightbeam.Harness.all(), ",", &"'#{&1.wire_name()}'")

    """
    CREATE TABLE sessions_new (
      sessionKey    TEXT PRIMARY KEY,
      displayName   TEXT NOT NULL,
      kind          TEXT NOT NULL DEFAULT 'custom' CHECK (kind IN ('main','dm','custom')),
      orderIndex    INTEGER NOT NULL DEFAULT 0,
      isBuiltIn     INTEGER NOT NULL DEFAULT 0,
      adopted       INTEGER NOT NULL DEFAULT 0,
      ownerUserId   TEXT NOT NULL,
      origin        TEXT NOT NULL,
      spawnedBy     TEXT,
      handle        TEXT UNIQUE,
      archetype     TEXT NOT NULL,
      overrides     TEXT,
      identityName  TEXT,
      identityRevision TEXT,
      cliToken      TEXT,
      harness       TEXT NOT NULL CHECK (harness IN (#{harnesses})),
      provider      TEXT NOT NULL CHECK (provider IN (#{@pi_provider_values})),
      model         TEXT NOT NULL,
      thinkingLevel TEXT,
      modelContext  TEXT,
      host          TEXT NOT NULL DEFAULT 'local',
      clearedThroughSeq INTEGER NOT NULL DEFAULT 0,
      state         TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','retired')),
      createdAt     INTEGER NOT NULL,
      updatedAt     INTEGER NOT NULL
    );
    """
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
