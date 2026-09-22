defmodule Tightbeam.HarnessHealth do
  @moduledoc """
  Durable incident foundation for shared harness failures.

  Observations are append-only evidence. An authoritative provider observation
  opens an incident immediately. Inferred failure evidence needs two distinct
  sessions on the same shared harness and in the same class inside the bounded
  window. Resolution appends normal-turn evidence and retracts the class fact;
  neither observations nor incidents are deleted.

  Runtime producers call the transaction-owned helpers here so a failed turn
  cannot commit without its evidence and a delivered turn cannot commit
  without clearing the affected shared harness. Recovery probing and process
  recycling remain outside this module.
  """

  alias Tightbeam.{
    ConditionFacts,
    DB,
    EventLog,
    Harness,
    HarnessProcess,
    Id,
    Ledger,
    Org,
    Wire.Payloads,
    Projection
  }

  alias Tightbeam.DB.Txn

  @failure_classes ~w(
    auth-dead rate-limit-dead adapter_unavailable model_unavailable task_crash
    interrupted-outcome-unknown
  )
  @other_failure_class "other"
  @prod_shape_consumers ["assignment_prodder"]
  @failure_evidence ~w(authoritative-provider terminal-failure)
  @evidence_window_ms 120_000
  @other_max_validity_ms 900_000
  @harness_health_schema_stamp "harness-health-other-v1-019"
  # Schema.ensure_all invokes module bootstraps before the repository's final
  # stamp is installed. HarnessHealth migrates only at the protected branch's
  # reviewed predecessor or PR31's final successor. The latter admits an
  # existing PR31 database to the same exact object-set migration.
  @harness_health_predecessor_stamps [
    "addressed-po-consultation-v1-019",
    "cursor-provider-v1-020"
  ]
  @legacy_object_set_sha256 "97ec5ee389c4f1b8d1b932dcfbc9fc59472a9c721a82968b013f63f54b52ebaf"
  @legacy_two_class_object_set_sha256 "be16933e4a429970358325fe941e258e6838e0e0b789a5d0b470bdb1269dcc3e"
  @target_object_set_sha256 "c811a7a0584197a7111e317f128b1bd9c08b21450511654b84f691ecc325a150"
  @target_object_names ~w(
    harness_health_observations harness_health_observation_window
    harness_health_observation_incident harness_health_incidents
    harness_health_one_open_class harness_health_other_one_open
    harness_health_incident_history harness_health_members harness_health_member_session
    harness_health_assignments harness_health_assignment_session harness_health_other_idempotency
    harness_health_other_reviews harness_health_other_routes harness_health_class_promotions
    harness_health_other_review_events harness_health_prod_suppressions harness_health_schema_stamp
    harness_health_observation_assignment_holder harness_health_observation_identity_immutable
    harness_health_observation_evidence_immutable
    harness_health_observation_attachment_once harness_health_observation_no_delete
    harness_health_incident_identity_immutable harness_health_incident_resolution_once
    harness_health_incident_no_delete harness_health_member_immutable_update
    harness_health_member_immutable_delete harness_health_assignment_holder
    harness_health_assignment_immutable_update harness_health_assignment_immutable_delete
    harness_health_other_route_target_unique harness_health_other_route_identity_immutable
    harness_health_other_route_terminal_once harness_health_other_review_event_append_only_update
    harness_health_other_route_pending_terminal harness_health_other_route_no_delete
    harness_health_other_review_event_append_only_delete harness_health_class_promotion_close_once
  )

  @observation_columns ~w(
    id correlation_id harness host failure_class evidence_kind session_key
    assignment_id observed_at cause principal incident_id description description_digest
    observed_state evidence_mode exact_observed_error exact_probe output_digest
    recovery_condition recovery_condition_digest recovery_satisfied not_known_class_reason
    valid_until world_status redaction_confirmed
  )a

  @incident_columns ~w(
    id harness host failure_class state opened_at open_observation_id opened_fact_id
    resolved_at resolution_observation_id resolved_fact_id description_digest expires_at
    expired_at expiry_fact_id
  )a

  @ddl """
  CREATE TABLE IF NOT EXISTS harness_health_observations (
    id            TEXT PRIMARY KEY,
    correlationId TEXT NOT NULL UNIQUE,
    harness       TEXT NOT NULL CHECK(length(trim(harness)) > 0),
    host          TEXT NOT NULL CHECK(length(trim(host)) > 0),
    failureClass  TEXT NOT NULL CHECK(failureClass IN (
                    'auth-dead','rate-limit-dead','adapter_unavailable','model_unavailable',
                    'task_crash','interrupted-outcome-unknown','other'
                  )),
    evidenceKind  TEXT NOT NULL CHECK(evidenceKind IN (
                    'authoritative-provider','terminal-failure','normal-turn-success'
                  )),
    sessionKey    TEXT REFERENCES sessions(sessionKey),
    assignmentId TEXT REFERENCES assignments(id),
    observedAt    INTEGER NOT NULL CHECK(observedAt >= 0),
    cause         TEXT NOT NULL CHECK(length(trim(cause)) > 0),
    principal     TEXT NOT NULL CHECK(length(trim(principal)) > 0),
    incidentId    TEXT REFERENCES harness_health_incidents(id)
                    DEFERRABLE INITIALLY DEFERRED,
    description TEXT,
    descriptionDigest TEXT,
    observedState TEXT,
    evidenceMode TEXT CHECK(evidenceMode IS NULL OR evidenceMode IN ('exact_error','probe_digest')),
    exactObservedError TEXT,
    exactProbe TEXT,
    outputDigest TEXT,
    recoveryCondition TEXT,
    recoveryConditionDigest TEXT,
    recoverySatisfied INTEGER CHECK(recoverySatisfied IS NULL OR recoverySatisfied IN (0,1)),
    notKnownClassReason TEXT,
    validUntil INTEGER,
    worldStatus TEXT CHECK(worldStatus IS NULL OR worldStatus IN ('PROVEN','UNKNOWN')),
    redactionConfirmed INTEGER CHECK(redactionConfirmed IS NULL OR redactionConfirmed IN (0,1)),
    CHECK(evidenceKind != 'terminal-failure' OR sessionKey IS NOT NULL),
    CHECK(evidenceKind != 'normal-turn-success' OR incidentId IS NOT NULL),
    CHECK(assignmentId IS NULL OR sessionKey IS NOT NULL),
    CHECK(failureClass != 'other' OR evidenceKind != 'authoritative-provider' OR
      (evidenceKind = 'authoritative-provider' AND
       description IS NOT NULL AND descriptionDigest IS NOT NULL AND
       observedState IS NOT NULL AND exactProbe IS NOT NULL AND
       recoveryCondition IS NOT NULL AND recoveryConditionDigest IS NOT NULL AND
       notKnownClassReason IS NOT NULL AND validUntil IS NOT NULL AND
       worldStatus IS NOT NULL AND redactionConfirmed = 1 AND
       recoverySatisfied IS NULL AND
       ((evidenceMode = 'exact_error' AND exactObservedError IS NOT NULL AND outputDigest IS NULL) OR
        (evidenceMode = 'probe_digest' AND exactObservedError IS NULL AND outputDigest IS NOT NULL)))),
    CHECK(failureClass != 'other' OR evidenceKind != 'normal-turn-success' OR
      (description IS NULL AND exactObservedError IS NULL AND recoveryCondition IS NULL AND
       notKnownClassReason IS NULL AND validUntil IS NULL AND
       observedState IS NOT NULL AND exactProbe IS NOT NULL AND
       evidenceMode = 'probe_digest' AND outputDigest IS NOT NULL AND
       recoveryConditionDigest IS NOT NULL AND recoverySatisfied = 1 AND
       worldStatus = 'PROVEN' AND redactionConfirmed = 1)),
    CHECK(failureClass = 'other' OR
      description IS NULL AND descriptionDigest IS NULL AND observedState IS NULL AND
      evidenceMode IS NULL AND exactObservedError IS NULL AND exactProbe IS NULL AND
      outputDigest IS NULL AND recoveryCondition IS NULL AND recoveryConditionDigest IS NULL AND
      recoverySatisfied IS NULL AND notKnownClassReason IS NULL AND validUntil IS NULL AND
      worldStatus IS NULL AND redactionConfirmed IS NULL)
  );
  CREATE INDEX IF NOT EXISTS harness_health_observation_window
    ON harness_health_observations
      (harness, host, failureClass, evidenceKind, observedAt, sessionKey);
  CREATE INDEX IF NOT EXISTS harness_health_observation_incident
    ON harness_health_observations (incidentId, observedAt, id);

  CREATE TABLE IF NOT EXISTS harness_health_incidents (
    id                      TEXT PRIMARY KEY,
    harness                 TEXT NOT NULL CHECK(length(trim(harness)) > 0),
    host                    TEXT NOT NULL CHECK(length(trim(host)) > 0),
    failureClass            TEXT NOT NULL CHECK(failureClass IN (
                              'auth-dead','rate-limit-dead','adapter_unavailable',
                              'model_unavailable','task_crash','interrupted-outcome-unknown','other'
                            )),
    state                   TEXT NOT NULL CHECK(state IN ('open','resolved','expired')),
    openedAt                INTEGER NOT NULL CHECK(openedAt >= 0),
    openObservationId       TEXT NOT NULL REFERENCES harness_health_observations(id)
                              DEFERRABLE INITIALLY DEFERRED,
    openedFactId            INTEGER REFERENCES condition_facts(id),
    resolvedAt              INTEGER,
    resolutionObservationId TEXT REFERENCES harness_health_observations(id)
                              DEFERRABLE INITIALLY DEFERRED,
    resolvedFactId          INTEGER REFERENCES condition_facts(id),
    descriptionDigest       TEXT,
    expiresAt               INTEGER,
    expiredAt               INTEGER,
    expiryFactId            INTEGER REFERENCES condition_facts(id),
    CHECK(
      (state = 'open' AND resolvedAt IS NULL AND resolutionObservationId IS NULL AND
       resolvedFactId IS NULL AND expiredAt IS NULL AND expiryFactId IS NULL)
      OR
      (state = 'resolved' AND resolvedAt >= openedAt AND
       resolutionObservationId IS NOT NULL AND expiredAt IS NULL AND
       (failureClass = 'other' OR resolvedFactId IS NOT NULL))
      OR
      (state = 'expired' AND expiredAt >= openedAt AND
       resolvedAt IS NULL AND resolutionObservationId IS NULL AND resolvedFactId IS NULL AND
       (failureClass = 'other' OR expiryFactId IS NOT NULL))
    ),
    CHECK(failureClass != 'other' OR
      (descriptionDigest IS NOT NULL AND expiresAt IS NOT NULL)),
    CHECK(failureClass = 'other' OR
      (descriptionDigest IS NULL AND expiresAt IS NULL AND expiredAt IS NULL AND expiryFactId IS NULL))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS harness_health_one_open_class
    ON harness_health_incidents (harness, host, failureClass)
    WHERE state = 'open' AND failureClass != 'other';
  CREATE UNIQUE INDEX IF NOT EXISTS harness_health_other_one_open
    ON harness_health_incidents (harness, host, descriptionDigest)
    WHERE state = 'open' AND failureClass = 'other';
  CREATE INDEX IF NOT EXISTS harness_health_incident_history
    ON harness_health_incidents (harness, host, openedAt, id);

  CREATE TABLE IF NOT EXISTS harness_health_members (
    incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    PRIMARY KEY (incidentId, sessionKey)
  );
  CREATE INDEX IF NOT EXISTS harness_health_member_session
    ON harness_health_members (sessionKey, incidentId);

  CREATE TABLE IF NOT EXISTS harness_health_assignments (
    incidentId   TEXT NOT NULL,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    sessionKey   TEXT NOT NULL REFERENCES sessions(sessionKey),
    PRIMARY KEY (incidentId, assignmentId),
    FOREIGN KEY (incidentId, sessionKey)
      REFERENCES harness_health_members(incidentId, sessionKey)
      DEFERRABLE INITIALLY DEFERRED
  );
  CREATE INDEX IF NOT EXISTS harness_health_assignment_session
    ON harness_health_assignments (sessionKey, incidentId);

  CREATE TABLE IF NOT EXISTS harness_health_other_idempotency (
    principalRef TEXT NOT NULL,
    operation TEXT NOT NULL,
    idempotencyKey TEXT NOT NULL,
    requestFingerprint TEXT NOT NULL,
    response TEXT NOT NULL,
    PRIMARY KEY (principalRef, operation, idempotencyKey)
  );

  CREATE TABLE IF NOT EXISTS harness_health_other_reviews (
    incidentId TEXT PRIMARY KEY REFERENCES harness_health_incidents(id),
    state TEXT NOT NULL CHECK(state IN ('pending','closed')),
    custodian TEXT NOT NULL,
    routeOrdinal INTEGER NOT NULL CHECK(routeOrdinal >= 0),
    outcome TEXT CHECK(outcome IS NULL OR outcome IN ('confirmed_other','reclassified','promotion_required')),
    namedClass TEXT,
    promotionCaseId TEXT,
    reviewer TEXT,
    cause TEXT,
    closedAt INTEGER,
    CHECK(outcome != 'reclassified' OR namedClass IS NOT NULL),
    CHECK(outcome = 'reclassified' OR namedClass IS NULL)
  );

  CREATE TABLE IF NOT EXISTS harness_health_other_routes (
    incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
    recipient TEXT NOT NULL,
    targetKind TEXT NOT NULL CHECK(targetKind IN ('session','owner_user')),
    targetRef TEXT NOT NULL,
    relation TEXT NOT NULL CHECK(relation IN ('parent','ancestor','owner_main','owner_user')),
    state TEXT NOT NULL CHECK(state IN ('skipped','pending','delivered','non_delivered','alerted')),
    closedReason TEXT,
    noticeWakeId TEXT,
    turnSeq INTEGER,
    createdAt INTEGER NOT NULL,
    resolvedAt INTEGER,
    settledAt INTEGER,
    CHECK(
      (state = 'skipped' AND closedReason IN ('inactive','foreign_owner','cycle','hop_limit')) OR
      (state = 'non_delivered' AND closedReason IN ('failed','failed_unknown','canceled','target_retired')) OR
      (state IN ('pending','delivered') AND closedReason IS NULL) OR
      (state = 'alerted' AND closedReason = 'no_active_main')
    ),
    PRIMARY KEY (incidentId, ordinal)
  );

  CREATE TABLE IF NOT EXISTS harness_health_class_promotions (
    id TEXT PRIMARY KEY,
    descriptionDigest TEXT NOT NULL UNIQUE,
    firstIncidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    secondIncidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    createdPrincipal TEXT NOT NULL CHECK(createdPrincipal = 'process:tightbeam'),
    state TEXT NOT NULL CHECK(state IN ('open','closed')),
    namedClass TEXT,
    specRef TEXT,
    specSha256 TEXT,
    reviewArtifactId TEXT,
    reviewAttestId TEXT REFERENCES attests(id),
    reviewedClean INTEGER CHECK(reviewedClean IS NULL OR reviewedClean IN (0,1)),
    closedBy TEXT,
    createdAt INTEGER NOT NULL,
    closedAt INTEGER,
    CHECK(
      (state = 'open' AND namedClass IS NULL AND specRef IS NULL AND specSha256 IS NULL AND
       reviewArtifactId IS NULL AND reviewAttestId IS NULL AND reviewedClean IS NULL AND
       closedBy IS NULL AND closedAt IS NULL)
      OR
      (state = 'closed' AND namedClass IS NOT NULL AND specRef IS NOT NULL AND
       specSha256 IS NOT NULL AND reviewArtifactId IS NOT NULL AND reviewAttestId IS NOT NULL AND
       reviewedClean = 1 AND closedBy IS NOT NULL AND closedAt IS NOT NULL)
    )
  );

  CREATE TABLE IF NOT EXISTS harness_health_other_review_events (
    id TEXT PRIMARY KEY,
    incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    eventKind TEXT NOT NULL,
    actor TEXT NOT NULL,
    payload TEXT NOT NULL,
    createdAt INTEGER NOT NULL
  );

  CREATE UNIQUE INDEX IF NOT EXISTS harness_health_other_route_target_unique
    ON harness_health_other_routes (incidentId, targetKind, targetRef)
    WHERE state != 'skipped';

  CREATE TRIGGER IF NOT EXISTS harness_health_other_route_identity_immutable
  BEFORE UPDATE OF incidentId,ordinal,recipient,targetKind,targetRef,relation,createdAt
  ON harness_health_other_routes
  BEGIN
    SELECT RAISE(ABORT, 'harness health route identity is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_other_route_terminal_once
  BEFORE UPDATE OF state,closedReason,noticeWakeId,turnSeq,resolvedAt,settledAt
  ON harness_health_other_routes
  WHEN OLD.state IN ('skipped','delivered','non_delivered','alerted') AND
       (NEW.state != OLD.state OR NEW.closedReason IS NOT OLD.closedReason OR
        NEW.noticeWakeId IS NOT OLD.noticeWakeId OR NEW.turnSeq IS NOT OLD.turnSeq OR
        NEW.resolvedAt IS NOT OLD.resolvedAt OR NEW.settledAt IS NOT OLD.settledAt)
  BEGIN
    SELECT RAISE(ABORT, 'harness health route is terminal and immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS harness_health_other_route_pending_terminal
  BEFORE UPDATE OF state ON harness_health_other_routes
  WHEN OLD.state = 'pending' AND NEW.state != 'pending' AND (
    NEW.state NOT IN ('delivered','non_delivered','alerted') OR
    (NEW.state = 'delivered' AND
      (NEW.closedReason IS NOT NULL OR NEW.resolvedAt IS NULL OR NEW.settledAt IS NULL)) OR
    (NEW.state = 'non_delivered' AND
      (NEW.closedReason NOT IN ('failed','failed_unknown','canceled','target_retired') OR
       NEW.resolvedAt IS NULL OR NEW.settledAt IS NULL)) OR
    (NEW.state = 'alerted' AND
      (NEW.closedReason IS NOT 'no_active_main' OR NEW.settledAt IS NULL))
  )
  BEGIN
    SELECT RAISE(ABORT, 'harness health route transition is invalid');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_other_route_no_delete
  BEFORE DELETE ON harness_health_other_routes
  BEGIN
    SELECT RAISE(ABORT, 'harness health route rows are immutable');
  END;


  CREATE TRIGGER IF NOT EXISTS harness_health_other_review_event_append_only_update
  BEFORE UPDATE ON harness_health_other_review_events
  BEGIN
    SELECT RAISE(ABORT, 'harness health review events are append-only');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_other_review_event_append_only_delete
  BEFORE DELETE ON harness_health_other_review_events
  BEGIN
    SELECT RAISE(ABORT, 'harness health review events are append-only');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_class_promotion_close_once
  BEFORE UPDATE OF state,namedClass,specRef,specSha256,reviewArtifactId,reviewAttestId,
                   reviewedClean,closedBy,closedAt
  ON harness_health_class_promotions
  WHEN OLD.state = 'closed' OR (OLD.state = 'open' AND NEW.state != 'closed')
  BEGIN
    SELECT RAISE(ABORT, 'harness health promotion closure is one-way');
  END;

  CREATE TABLE IF NOT EXISTS harness_health_prod_suppressions (
    consumerKind TEXT NOT NULL,
    candidateId TEXT NOT NULL,
    harness TEXT NOT NULL,
    host TEXT NOT NULL,
    incidentIds TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    PRIMARY KEY (consumerKind, candidateId, harness, host)
  );

  CREATE TABLE IF NOT EXISTS harness_health_schema_stamp (
    shape TEXT PRIMARY KEY,
    predecessorStamp TEXT NOT NULL,
    predecessorObjectSetSha256 TEXT NOT NULL,
    appliedAt INTEGER NOT NULL
  );

  CREATE TRIGGER IF NOT EXISTS harness_health_observation_assignment_holder
  BEFORE INSERT ON harness_health_observations
  WHEN NEW.assignmentId IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM assignments
    WHERE id = NEW.assignmentId AND holderKey = NEW.sessionKey
  )
  BEGIN
    SELECT RAISE(ABORT, 'harness health assignment must belong to its affected session');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_observation_identity_immutable
  BEFORE UPDATE OF id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,
                   assignmentId,observedAt,cause,principal
  ON harness_health_observations
  BEGIN
    SELECT RAISE(ABORT, 'harness health observation identity is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_observation_evidence_immutable
  BEFORE UPDATE OF description,descriptionDigest,observedState,evidenceMode,
                   exactObservedError,exactProbe,outputDigest,recoveryCondition,
                   recoveryConditionDigest,recoverySatisfied,notKnownClassReason,
                   validUntil,worldStatus,redactionConfirmed
  ON harness_health_observations
  BEGIN
    SELECT RAISE(ABORT, 'harness health evidence is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_observation_attachment_once
  BEFORE UPDATE OF incidentId ON harness_health_observations
  WHEN OLD.incidentId IS NOT NULL OR NEW.incidentId IS NULL
  BEGIN
    SELECT RAISE(ABORT, 'harness health observation attachment is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_observation_no_delete
  BEFORE DELETE ON harness_health_observations
  BEGIN
    SELECT RAISE(ABORT, 'harness health observation history is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_incident_identity_immutable
  BEFORE UPDATE OF id,harness,host,failureClass,openedAt,openObservationId,openedFactId,
                   descriptionDigest,expiresAt
  ON harness_health_incidents
  BEGIN
    SELECT RAISE(ABORT, 'harness health incident identity is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_incident_resolution_once
  BEFORE UPDATE OF state,resolvedAt,resolutionObservationId,resolvedFactId
  ON harness_health_incidents
  WHEN NOT (
    (OLD.state = 'open' AND OLD.resolvedAt IS NULL AND
     OLD.resolutionObservationId IS NULL AND OLD.resolvedFactId IS NULL AND
     NEW.state = 'resolved' AND NEW.resolvedAt IS NOT NULL AND
       NEW.resolutionObservationId IS NOT NULL AND
       (NEW.resolvedFactId IS NOT NULL OR
        (OLD.failureClass = 'other' AND NOT EXISTS (
          SELECT 1 FROM harness_health_incidents remaining
          WHERE remaining.id != OLD.id AND remaining.harness = OLD.harness AND
                remaining.host = OLD.host AND remaining.failureClass = 'other' AND
                remaining.state = 'open'
        ))) AND
     EXISTS (
       SELECT 1 FROM harness_health_observations
       WHERE id = NEW.resolutionObservationId AND incidentId = OLD.id AND
             harness = OLD.harness AND host = OLD.host AND
             failureClass = OLD.failureClass AND evidenceKind = 'normal-turn-success'
     ))
    OR
    (OLD.state = 'open' AND NEW.state = 'expired' AND NEW.expiredAt IS NOT NULL AND
     (NEW.expiryFactId IS NOT NULL OR
      (OLD.failureClass = 'other' AND NOT EXISTS (
        SELECT 1 FROM harness_health_incidents remaining
        WHERE remaining.id != OLD.id AND remaining.harness = OLD.harness AND
              remaining.host = OLD.host AND remaining.failureClass = 'other' AND
              remaining.state = 'open'
      ))))
  )
  BEGIN
    SELECT RAISE(ABORT, 'harness health incident may resolve exactly once');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_incident_no_delete
  BEFORE DELETE ON harness_health_incidents
  BEGIN
    SELECT RAISE(ABORT, 'harness health incident history is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_member_immutable_update
  BEFORE UPDATE ON harness_health_members
  BEGIN
    SELECT RAISE(ABORT, 'harness health membership history is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_member_immutable_delete
  BEFORE DELETE ON harness_health_members
  BEGIN
    SELECT RAISE(ABORT, 'harness health membership history is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_assignment_holder
  BEFORE INSERT ON harness_health_assignments
  WHEN NOT EXISTS (
    SELECT 1 FROM assignments
    WHERE id = NEW.assignmentId AND holderKey = NEW.sessionKey
  )
  BEGIN
    SELECT RAISE(ABORT, 'harness health assignment must belong to its affected member');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_assignment_immutable_update
  BEFORE UPDATE ON harness_health_assignments
  BEGIN
    SELECT RAISE(ABORT, 'harness health assignment history is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS harness_health_assignment_immutable_delete
  BEFORE DELETE ON harness_health_assignments
  BEGIN
    SELECT RAISE(ABORT, 'harness health assignment history is immutable');
  END;
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    case DB.query(db, "SELECT shape FROM schema_stamp") do
      {:ok, [[stamp]]} when stamp in @harness_health_predecessor_stamps ->
        ensure_current_schema(db)

      {:ok, [[@harness_health_schema_stamp]]} ->
        ensure_current_schema(db)

      {:ok, [[_intermediate_stamp]]} ->
        # Schema.ensure_all calls module bootstraps before the reviewed
        # execution-time predecessor exists. Preserve any old HarnessHealth
        # objects byte-for-byte and let the final pass perform the migration.
        :ok

      _ ->
        ensure_current_schema(db)
    end
  end

  defp ensure_current_schema(db) do
    case DB.query(
           db,
           "SELECT shape,predecessorStamp,predecessorObjectSetSha256 FROM harness_health_schema_stamp"
         ) do
      {:ok, [[@harness_health_schema_stamp, _predecessor, _object_set]]} ->
        validate_target_schema!(db)
        :ok

      {:ok, rows} when rows != [] ->
        raise_schema_conflict!("unknown target stamp #{inspect(rows)}")

      {:ok, []} ->
        migrate_predecessor!(db)

      {:error, _missing_stamp_table} ->
        case DB.query(
               db,
               "SELECT name FROM sqlite_schema WHERE name GLOB 'harness_health_*' ORDER BY name"
             ) do
          {:ok, []} ->
            create_fresh_schema!(db)

          {:ok, _objects} ->
            migrate_predecessor!(db)

          {:error, error} ->
            raise_schema_conflict!("cannot inspect predecessor objects: #{inspect(error)}")
        end
    end
  end

  defp create_fresh_schema!(db) do
    case DB.transaction(db, fn txn ->
           :ok = Txn.exec(txn, @ddl)

           Txn.q(
             txn,
             "INSERT INTO harness_health_schema_stamp (shape,predecessorStamp,predecessorObjectSetSha256,appliedAt) VALUES (?1,'fresh',?2,?3)",
             [
               @harness_health_schema_stamp,
               @target_object_set_sha256,
               System.system_time(:millisecond)
             ]
           )

           :ok
         end) do
      {:ok, :ok} ->
        validate_target_schema!(db)
        :ok

      {:error, error} ->
        raise_schema_conflict!("fresh schema creation failed: #{Exception.message(error)}")
    end
  end

  defp migrate_predecessor!(db) do
    {:ok, [[predecessor_stamp]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    unless predecessor_stamp in @harness_health_predecessor_stamps do
      raise_schema_conflict!("unknown predecessor stamp #{inspect(predecessor_stamp)}")
    end

    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")
    :ok = DB.execute(db, "PRAGMA legacy_alter_table=ON")

    try do
      case DB.transaction(db, fn txn -> copy_predecessor_in_txn(txn, predecessor_stamp) end) do
        {:ok, :ok} ->
          validate_target_schema!(db)
          :ok

        {:error, error} ->
          raise_schema_conflict!(
            "copy migration failed and was rolled back: #{Exception.message(error)}"
          )
      end
    after
      :ok = DB.execute(db, "PRAGMA legacy_alter_table=OFF")
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
  end

  defp copy_predecessor_in_txn(txn, predecessor_stamp) do
    layout = validate_predecessor_objects!(txn)

    predecessor_counts =
      for table <-
            ~w(harness_health_observations harness_health_incidents harness_health_members harness_health_assignments),
          into: %{} do
        [[count]] = Txn.q(txn, "SELECT COUNT(*) FROM #{table}")
        {table, count}
      end

    for name <- [
          "harness_health_observation_assignment_holder",
          "harness_health_observation_identity_immutable",
          "harness_health_observation_attachment_once",
          "harness_health_observation_no_delete",
          "harness_health_incident_identity_immutable",
          "harness_health_incident_resolution_once",
          "harness_health_incident_no_delete",
          "harness_health_member_immutable_update",
          "harness_health_member_immutable_delete",
          "harness_health_assignment_holder",
          "harness_health_assignment_immutable_update",
          "harness_health_assignment_immutable_delete"
        ],
        do: :ok = Txn.exec(txn, "DROP TRIGGER IF EXISTS #{name}")

    for name <- [
          "harness_health_observation_window",
          "harness_health_observation_incident",
          "harness_health_one_open_class",
          "harness_health_incident_history",
          "harness_health_member_session",
          "harness_health_assignment_session"
        ],
        do: :ok = Txn.exec(txn, "DROP INDEX IF EXISTS #{name}")

    for {table, legacy} <- [
          {"harness_health_observations", "harness_health_observations__pre_other"},
          {"harness_health_incidents", "harness_health_incidents__pre_other"},
          {"harness_health_members", "harness_health_members__pre_other"},
          {"harness_health_assignments", "harness_health_assignments__pre_other"}
        ],
        do: :ok = Txn.exec(txn, "ALTER TABLE #{table} RENAME TO #{legacy}")

    :ok = Txn.exec(txn, @ddl)

    Txn.q(
      txn,
      """
      INSERT INTO harness_health_observations
        (id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,assignmentId,
         observedAt,cause,principal,incidentId)
      SELECT id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,assignmentId,
             observedAt,cause,principal,incidentId
      FROM harness_health_observations__pre_other
      """
    )

    Txn.q(
      txn,
      """
      INSERT INTO harness_health_incidents
        (id,harness,host,failureClass,state,openedAt,openObservationId,openedFactId,
         resolvedAt,resolutionObservationId,resolvedFactId)
      SELECT id,harness,host,failureClass,state,openedAt,openObservationId,openedFactId,
             resolvedAt,resolutionObservationId,resolvedFactId
      FROM harness_health_incidents__pre_other
      """
    )

    Txn.q(
      txn,
      "INSERT INTO harness_health_members (incidentId,sessionKey) SELECT incidentId,sessionKey FROM harness_health_members__pre_other"
    )

    Txn.q(
      txn,
      "INSERT INTO harness_health_assignments (incidentId,assignmentId,sessionKey) SELECT incidentId,assignmentId,sessionKey FROM harness_health_assignments__pre_other"
    )

    copied_counts =
      for table <-
            ~w(harness_health_observations harness_health_incidents harness_health_members harness_health_assignments),
          into: %{} do
        [[count]] = Txn.q(txn, "SELECT COUNT(*) FROM #{table}")
        {table, count}
      end

    unless predecessor_counts == copied_counts,
      do:
        raise_schema_conflict!(
          "copy migration row-count proof failed: before=#{inspect(predecessor_counts)} after=#{inspect(copied_counts)}"
        )

    unless Txn.q(txn, "PRAGMA foreign_key_check") == [],
      do: raise(ArgumentError, "harness health copy migration left invalid foreign keys")

    EventLog.lifecycle_in_txn(
      txn,
      "harness_health_schema_migrated",
      @harness_health_schema_stamp,
      JSON.encode!(%{
        predecessorStamp: predecessor_stamp,
        predecessorObjectSetSha256:
          case layout do
            :six_class -> @legacy_object_set_sha256
            :two_class -> @legacy_two_class_object_set_sha256
          end,
        rowCounts: predecessor_counts,
        foreignKeyCheck: "ok"
      })
    )

    for table <- [
          "harness_health_observations__pre_other",
          "harness_health_incidents__pre_other",
          "harness_health_members__pre_other",
          "harness_health_assignments__pre_other"
        ],
        do: :ok = Txn.exec(txn, "DROP TABLE #{table}")

    digest =
      case layout do
        :six_class -> @legacy_object_set_sha256
        :two_class -> @legacy_two_class_object_set_sha256
      end

    Txn.q(
      txn,
      "INSERT INTO harness_health_schema_stamp (shape,predecessorStamp,predecessorObjectSetSha256,appliedAt) VALUES (?1,?2,?3,?4)",
      [
        @harness_health_schema_stamp,
        predecessor_stamp,
        digest,
        System.system_time(:millisecond)
      ]
    )

    :ok
  end

  defp validate_predecessor_objects!(txn) do
    expected =
      MapSet.new(~w(
        harness_health_observations harness_health_observation_window
        harness_health_observation_incident harness_health_incidents
        harness_health_one_open_class harness_health_incident_history
        harness_health_members harness_health_member_session
        harness_health_assignments harness_health_assignment_session
        harness_health_observation_assignment_holder
        harness_health_observation_identity_immutable
        harness_health_observation_attachment_once harness_health_observation_no_delete
        harness_health_incident_identity_immutable
        harness_health_incident_resolution_once harness_health_incident_no_delete
        harness_health_member_immutable_update harness_health_member_immutable_delete
        harness_health_assignment_holder harness_health_assignment_immutable_update
        harness_health_assignment_immutable_delete
      ))

    actual =
      Txn.q(
        txn,
        "SELECT name FROM sqlite_schema WHERE name GLOB 'harness_health_*' ORDER BY name"
      )
      |> List.flatten()
      |> MapSet.new()

    unless actual == expected,
      do: raise_schema_conflict!("predecessor object set is not exact: #{inspect(actual)}")

    object_set_sha256 =
      Txn.q(
        txn,
        "SELECT type,name,COALESCE(sql,'') FROM sqlite_schema WHERE name GLOB 'harness_health_*' ORDER BY type,name"
      )
      |> Enum.map(fn [type, name, sql] -> Enum.join([type, name, sql], "|") end)
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> sha256()

    layout =
      cond do
        object_set_sha256 == @legacy_object_set_sha256 -> :six_class
        object_set_sha256 == @legacy_two_class_object_set_sha256 -> :two_class
        true -> raise_schema_conflict!("predecessor object set digest is not exact")
      end

    observation_columns =
      Txn.q(txn, "PRAGMA table_info(harness_health_observations)")
      |> Enum.map(&Enum.at(&1, 1))

    incident_columns =
      Txn.q(txn, "PRAGMA table_info(harness_health_incidents)")
      |> Enum.map(&Enum.at(&1, 1))

    unless observation_columns ==
             ~w(id correlationId harness host failureClass evidenceKind sessionKey assignmentId observedAt cause principal incidentId) and
             incident_columns ==
               ~w(id harness host failureClass state openedAt openObservationId openedFactId resolvedAt resolutionObservationId resolvedFactId),
           do: raise_schema_conflict!("predecessor table columns are not exact")

    [[incident_sql]] =
      Txn.q(txn, "SELECT sql FROM sqlite_schema WHERE name='harness_health_incidents'")

    cond do
      layout == :six_class and String.contains?(incident_sql, "'adapter_unavailable'") ->
        layout

      layout == :two_class and String.contains?(incident_sql, "'auth-dead'") and
          String.contains?(incident_sql, "'rate-limit-dead'") ->
        layout

      true ->
        raise_schema_conflict!("predecessor class shape is not an admitted exact layout")
    end
  end

  defp validate_target_schema!(db) do
    {:ok, object_rows} =
      DB.query(
        db,
        "SELECT type,name,COALESCE(sql,'') FROM sqlite_schema WHERE name GLOB 'harness_health_*' ORDER BY type,name"
      )

    actual_objects = object_rows |> Enum.map(&Enum.at(&1, 1)) |> Enum.sort()

    unless actual_objects == Enum.sort(@target_object_names),
      do: raise_schema_conflict!("target object set is not exact")

    actual_digest = object_set_digest(object_rows)

    unless actual_digest == @target_object_set_sha256,
      do: raise_schema_conflict!("target object-set digest is not exact: #{actual_digest}")

    with {:ok, [[@harness_health_schema_stamp, predecessor, digest]]} <-
           DB.query(
             db,
             "SELECT shape,predecessorStamp,predecessorObjectSetSha256 FROM harness_health_schema_stamp"
           ),
         {:ok, observations} <- DB.query(db, "PRAGMA table_info(harness_health_observations)"),
         {:ok, incidents} <- DB.query(db, "PRAGMA table_info(harness_health_incidents)"),
         true <-
           Enum.map(observations, &Enum.at(&1, 1)) ==
             ~w(id correlationId harness host failureClass evidenceKind sessionKey assignmentId observedAt cause principal incidentId description descriptionDigest observedState evidenceMode exactObservedError exactProbe outputDigest recoveryCondition recoveryConditionDigest recoverySatisfied notKnownClassReason validUntil worldStatus redactionConfirmed),
         true <-
           Enum.map(incidents, &Enum.at(&1, 1)) ==
             ~w(id harness host failureClass state openedAt openObservationId openedFactId resolvedAt resolutionObservationId resolvedFactId descriptionDigest expiresAt expiredAt expiryFactId),
         true <-
           (predecessor == "fresh" and digest == @target_object_set_sha256) or
             (is_binary(digest) and byte_size(digest) == 64 and
                digest in [@legacy_object_set_sha256, @legacy_two_class_object_set_sha256]) do
      :ok
    else
      _ -> raise_schema_conflict!("target stamp or object set is incomplete")
    end
  end

  defp object_set_digest(rows) do
    data =
      rows
      |> Enum.map(fn [type, name, sql] -> Enum.join([type, name, sql], "|") end)
      |> Enum.join("\n")

    sha256(data <> "\n")
  end

  defp raise_schema_conflict!(message),
    do: raise(ArgumentError, "harness_health_other_schema_conflict: #{message}")

  @doc "The fixed inference window established by the reviewed patrol design."
  @spec evidence_window_ms() :: pos_integer()
  def evidence_window_ms, do: @evidence_window_ms

  @doc "Whether either incident class currently stands for one shared harness."
  @spec unavailable?(DB.server(), String.t(), String.t()) :: boolean()
  def unavailable?(db \\ DB, harness, host),
    do: ConditionFacts.harness_unavailable?(db, harness, host)

  @doc "Classify a terminal turn reason without collapsing auth and rate limiting."
  @spec classify_turn_failure(term()) :: String.t() | nil
  def classify_turn_failure(%{
        "data" => %{"codexErrorInfo" => "usageLimitExceeded"}
      }),
      do: "rate-limit-dead"

  def classify_turn_failure(%{"data" => %{"errorKind" => "rate_limit"}}),
    do: "rate-limit-dead"

  def classify_turn_failure(:task_crash), do: "task_crash"
  def classify_turn_failure({:task_crash, _}), do: "task_crash"
  def classify_turn_failure(:interrupted_outcome_unknown), do: "interrupted-outcome-unknown"

  def classify_turn_failure({:interrupted_outcome_unknown, _}),
    do: "interrupted-outcome-unknown"

  def classify_turn_failure(%{code: code})
      when code in ["adapter_unavailable", "model_unavailable"],
      do: code

  def classify_turn_failure(%{"code" => code})
      when code in ["adapter_unavailable", "model_unavailable"],
      do: code

  def classify_turn_failure(reason) do
    evidence = reason |> evidence_text() |> String.downcase()

    cond do
      contains_any?(evidence, [
        "interrupted: outcome unknown",
        "interrupted-outcome-unknown",
        "outcome unknown"
      ]) ->
        "interrupted-outcome-unknown"

      contains_any?(evidence, ["task_crash", "turn task crash", "turn-task-crash"]) ->
        "task_crash"

      contains_any?(evidence, [
        "model_unavailable",
        "model unavailable",
        "model is not available",
        "unknown model",
        "unsupported model"
      ]) ->
        "model_unavailable"

      contains_any?(evidence, [
        "adapter_unavailable",
        "adapter unavailable",
        "adapter for ",
        "coordinator_unavailable",
        "adapter boot",
        "adapter died",
        "adapter is degraded",
        "noproc"
      ]) ->
        "adapter_unavailable"

      contains_any?(evidence, [
        "rate limit",
        "rate_limit",
        "ratelimit",
        "too many requests",
        "quota exceeded",
        "usage limit",
        "weekly limit",
        "http 429",
        "status 429",
        "\"status\":429",
        "\"status_code\":429",
        "\"statuscode\":429",
        "status_code\" => 429",
        "statuscode\" => 429"
      ]) ->
        "rate-limit-dead"

      contains_any?(evidence, [
        "auth expired",
        "authentication expired",
        "authentication failed",
        "authentication required",
        "invalid token",
        "expired token",
        "token expired",
        "token revoked",
        "unauthorized",
        "unauthenticated",
        "http 401",
        "status 401",
        "\"status\":401",
        "\"status_code\":401",
        "\"statuscode\":401",
        "status_code\" => 401",
        "statuscode\" => 401"
      ]) ->
        "auth-dead"

      true ->
        nil
    end
  end

  @doc "Record classified turn-failure evidence inside the turn's terminal transaction."
  @spec observe_turn_failure_in_txn(Txn.t(), map(), map(), term(), term()) ::
          nil | (-> :ok)
  def observe_turn_failure_in_txn(%Txn{} = txn, session, turn, failed_stage, reason) do
    case classify_turn_failure(reason) do
      nil ->
        nil

      failure_class ->
        # A notification may name a child's assignment as its cause. Only
        # the executing session's own assignment is health attribution.
        assignment_id =
          case Txn.q(
                 txn,
                 """
                 SELECT a.id FROM turns t LEFT JOIN assignments a
                   ON a.id=t.assignmentId AND a.holderKey=t.sessionKey
                 WHERE t.seq=?1
                 """,
                 [turn.seq]
               ) do
            [[assignment_id]] -> assignment_id
            [] -> nil
          end

        result =
          observe_in_txn(txn, %{
            correlation_id: "harness-turn:#{turn.seq}:#{failure_class}",
            harness: to_string(session.harness),
            host: session.host,
            failure_class: failure_class,
            evidence_kind: "terminal-failure",
            session_key: turn.session_key,
            assignment_id: assignment_id,
            observed_at: System.system_time(:millisecond),
            cause: "stage=#{failed_stage} reason=#{evidence_text(reason)}",
            principal: turn.origin || "process:tightbeam"
          })

        post_commit(result)
    end
  end

  @doc "Record a terminal class whose owner is the lane or boot reconciler."
  @spec observe_terminal_in_txn(Txn.t(), integer(), String.t(), String.t(), String.t()) ::
          nil | (-> :ok)
  def observe_terminal_in_txn(%Txn{} = txn, seq, failure_class, cause, principal)
      when failure_class in @failure_classes do
    columns = Txn.q(txn, "PRAGMA table_info(sessions)") |> Enum.map(&Enum.at(&1, 1))

    rows =
      if "host" in columns and "harness" in columns do
        Txn.q(
          txn,
          """
          SELECT t.sessionKey,a.id,s.harness,s.host
          FROM turns t JOIN sessions s ON s.sessionKey=t.sessionKey
          LEFT JOIN assignments a ON a.id=t.assignmentId AND a.holderKey=t.sessionKey
          WHERE t.seq=?1
          """,
          [seq]
        )
      else
        []
      end

    case rows do
      [[session_key, assignment_id, harness, host]] ->
        result =
          observe_in_txn(txn, %{
            correlation_id: "harness-turn:#{seq}:#{failure_class}",
            harness: harness,
            host: host,
            failure_class: failure_class,
            evidence_kind: "terminal-failure",
            session_key: session_key,
            assignment_id: assignment_id,
            observed_at: System.system_time(:millisecond),
            cause: cause,
            principal: principal
          })

        post_commit(result)

      [] ->
        nil
    end
  end

  @doc "Resolve every open class for this shared harness inside a delivered-turn transaction."
  @spec resolve_normal_turn_in_txn(Txn.t(), map(), map()) :: :ok
  def resolve_normal_turn_in_txn(%Txn{} = txn, session, turn) do
    harness = to_string(session.harness)

    Txn.q(
      txn,
      """
      SELECT failureClass FROM harness_health_incidents
      WHERE harness=?1 AND host=?2 AND state='open'
      ORDER BY failureClass
      """,
      [harness, session.host]
    )
    |> List.flatten()
    |> Enum.each(fn failure_class ->
      input = %{
        correlation_id: "harness-turn:#{turn.seq}:normal-success:#{failure_class}",
        harness: harness,
        host: session.host,
        failure_class: failure_class,
        session_key: turn.session_key,
        assignment_id: nil,
        observed_at: System.system_time(:millisecond),
        cause: "normal turn #{turn.seq} delivered",
        principal: turn.origin || "process:tightbeam"
      }

      if failure_class != @other_failure_class do
        resolve_in_txn(txn, input)
      end
    end)

    :ok
  end

  @doc "Open an auth incident immediately from a provider-authoritative invalidation."
  @spec observe_provider_invalidation(DB.server(), String.t(), String.t(), term(), keyword()) ::
          {:opened | :attached | :duplicate, map()}
  def observe_provider_invalidation(db \\ DB, harness, host, event, opts \\ []) do
    observe(db, %{
      correlation_id: "provider-auth:" <> Id.uuid4(),
      harness: to_string(harness),
      host: host,
      failure_class: "auth-dead",
      evidence_kind: "authoritative-provider",
      session_key: nil,
      assignment_id: nil,
      observed_at: System.system_time(:millisecond),
      cause: evidence_text(event),
      principal: Keyword.get(opts, :principal, "process:tightbeam/provider"),
      conn_registry: Keyword.get(opts, :conn_registry, Tightbeam.ConnRegistry)
    })
  end

  @doc "Record failure evidence and open or attach to its incident atomically."
  @spec observe(DB.server(), map()) :: {:pending | :opened | :attached | :duplicate, map()}
  def observe(db \\ DB, input) do
    input = normalize_failure!(input)
    result = transaction!(db, &observe_in_txn(&1, input))

    case post_commit(result, Map.get(input, :conn_registry, Tightbeam.ConnRegistry)) do
      nil -> :ok
      publish -> publish.()
    end

    strip_publication(result)
  end

  @doc "The observation mutation inside a caller-owned transaction."
  @spec observe_in_txn(Txn.t(), map()) :: {:pending | :opened | :attached | :duplicate, map()}
  def observe_in_txn(%Txn{} = txn, input) do
    input = normalize_failure!(input)
    validate_session_membership!(txn, input)

    case observation_by_correlation(txn, input.correlation_id) do
      nil -> recognize_new_observation(txn, input)
      prior -> duplicate_or_refuse!(txn, prior, input, input.evidence_kind)
    end
  end

  @doc "Resolve one class-specific open incident on normal-turn success."
  @spec resolve(DB.server(), map()) ::
          {:resolved | :duplicate, map()} | :already_healthy | :repair_required
  def resolve(db \\ DB, input) do
    input = input |> Map.put(:evidence_kind, "normal-turn-success") |> normalize_common!()
    transaction!(db, &resolve_in_txn(&1, input))
  end

  @doc "The class-specific resolution mutation inside a caller-owned transaction."
  @spec resolve_in_txn(Txn.t(), map()) ::
          {:resolved | :duplicate, map()} | :already_healthy | :repair_required
  def resolve_in_txn(%Txn{} = txn, input) do
    input = input |> Map.put(:evidence_kind, "normal-turn-success") |> normalize_common!()
    validate_session_membership!(txn, input)

    if input.failure_class == "rate-limit-dead" and
         HarnessProcess.parked_in_txn?(txn, adapter_key(input.harness, input.host)) do
      :repair_required
    else
      case observation_by_correlation(txn, input.correlation_id) do
        nil -> resolve_open(txn, input)
        prior -> duplicate_or_refuse!(txn, prior, input, "normal-turn-success")
      end
    end
  end

  @doc "Admit an evidence-bearing provider observation for the open-ended other class."
  @spec observe_other(DB.server(), map()) ::
          {:opened | :attached | :duplicate, map()} | {:error, map()}
  def observe_other(db \\ DB, input) do
    try do
      input = normalize_other!(input)
      result = transaction!(db, &observe_other_in_txn(&1, input))

      case post_commit(result, Map.get(input, :conn_registry, Tightbeam.ConnRegistry), db) do
        nil -> :ok
        publish -> publish.()
      end

      strip_publication(result)
    rescue
      error in ArgumentError -> {:error, %{code: other_error_code(error), message: error.message}}
    end
  end

  @doc "The atomic evidence-bearing other admission mutation."
  @spec observe_other_in_txn(Txn.t(), map()) :: {:opened | :attached | :duplicate, map()}
  def observe_other_in_txn(%Txn{} = txn, input) do
    validate_other_source!(txn, input)
    principal_ref = principal_ref(input.principal)
    fingerprint = other_fingerprint(input)

    case other_idempotency(txn, principal_ref, input.idempotency_key, "observe-other") do
      nil ->
        expire_other_incidents_in_txn(txn, input.harness, input.host, input.observed_at)

        observation_id = insert_observation(txn, input, nil, "authoritative-provider")

        result =
          case other_open_incident(txn, input) do
            nil ->
              open_new_incident(txn, observation_id, input)

            incident ->
              attach_observation(txn, incident.id, observation_id)

              EventLog.lifecycle_in_txn(
                txn,
                "harness_health_evidence_attached",
                incident.id,
                lifecycle_detail(input, observation_id)
              )

              {:attached, Map.put(incident, :observationId, observation_id)}
          end

        store_other_idempotency(
          txn,
          principal_ref,
          input.idempotency_key,
          fingerprint,
          strip_publication(result),
          "observe-other"
        )

        result

      %{request_fingerprint: ^fingerprint, response: response} ->
        decode_other_idempotency(response)

      _ ->
        raise ArgumentError, "idempotency_conflict"
    end
  end

  @doc "Resolve an open other incident with explicit, matching recovery evidence."
  @spec resolve_other(DB.server(), map()) :: {:resolved | :duplicate, map()} | {:error, map()}
  def resolve_other(db \\ DB, input) do
    try do
      input = normalize_other_recovery!(input)
      transaction!(db, &resolve_other_in_txn(&1, input))
    rescue
      error in ArgumentError -> {:error, %{code: other_error_code(error), message: error.message}}
    end
  end

  @spec resolve_other_in_txn(Txn.t(), map()) :: {:resolved | :duplicate, map()} | :already_healthy
  def resolve_other_in_txn(%Txn{} = txn, input) do
    validate_session_membership!(txn, input)

    unless resolve_other_authorized?(txn, input.incident_id, input.principal_identity),
      do: raise(ArgumentError, "not_authorized")

    principal_ref = principal_ref(input.principal_identity)
    fingerprint = other_recovery_fingerprint(input)

    case other_idempotency(txn, principal_ref, input.idempotency_key, "resolve-other") do
      %{request_fingerprint: ^fingerprint, response: response} ->
        decode_other_idempotency(response)

      %{request_fingerprint: _different} ->
        raise ArgumentError, "idempotency_conflict"

      nil ->
        case observation_by_correlation(txn, input.correlation_id) do
          nil ->
            result = resolve_other_open(txn, input)

            if match?({:resolved, _}, result) do
              store_other_idempotency(
                txn,
                principal_ref,
                input.idempotency_key,
                fingerprint,
                result,
                "resolve-other"
              )
            end

            result

          prior ->
            result = duplicate_or_refuse!(txn, prior, input, "normal-turn-success")

            store_other_idempotency(
              txn,
              principal_ref,
              input.idempotency_key,
              fingerprint,
              result,
              "resolve-other"
            )

            result
        end
    end
  end

  @doc "Close the mandatory review for an other incident."
  @spec review_other(DB.server(), map()) :: {:ok, map()} | {:error, map()}
  def review_other(db \\ DB, input) do
    try do
      case transaction!(db, &review_other_in_txn(&1, input)) do
        {:reviewed, result} -> {:ok, result}
        {:duplicate, result} -> {:ok, result}
      end
    rescue
      error in ArgumentError -> {:error, %{code: other_error_code(error), message: error.message}}
    end
  end

  @doc false
  def review_other_in_txn(%Txn{} = txn, input) do
    incident_id = required_string!(input, :incident_id)
    outcome = required_string!(input, :outcome)
    principal = Map.get(input, :principal, "process:tightbeam")
    reviewer = principal_text(principal)
    idempotency_key = required_string!(input, :idempotency_key)
    fingerprint = review_fingerprint(input)

    case other_idempotency(txn, reviewer, idempotency_key, "review-other") do
      %{request_fingerprint: ^fingerprint, response: response} ->
        decode_other_idempotency(response)

      %{request_fingerprint: _different} ->
        raise ArgumentError, "idempotency_conflict"

      nil ->
        review_other_once_in_txn(
          txn,
          input,
          incident_id,
          outcome,
          principal,
          reviewer,
          idempotency_key,
          fingerprint
        )
    end
  end

  defp review_other_once_in_txn(
         txn,
         input,
         incident_id,
         outcome,
         principal,
         reviewer,
         idempotency_key,
         fingerprint
       ) do
    unless outcome in ~w(confirmed_other reclassified promotion_required),
      do: raise(ArgumentError, "invalid_review_outcome")

    unless review_authorized?(txn, incident_id, principal),
      do: raise(ArgumentError, "not_authorized")

    [[description_digest]] =
      Txn.q(
        txn,
        "SELECT descriptionDigest FROM harness_health_incidents WHERE id=?1 AND failureClass='other'",
        [incident_id]
      )

    [[recurrence]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM harness_health_incidents WHERE failureClass='other' AND descriptionDigest=?1",
        [description_digest]
      )

    if recurrence > 1 and outcome != "promotion_required",
      do: raise(ArgumentError, "invalid_review_outcome")

    if recurrence <= 1 and outcome == "promotion_required",
      do: raise(ArgumentError, "promotion_required")

    unless outcome != "reclassified" or Map.get(input, :named_class) in @failure_classes,
      do: raise(ArgumentError, "invalid_review_outcome")

    cause = required_review_cause!(input)

    promotion_case_id = promotion_case_id(txn, description_digest, recurrence)

    if recurrence > 1 and is_nil(promotion_case_id),
      do: raise(ArgumentError, "promotion_required")

    Txn.q(
      txn,
      """
      UPDATE harness_health_other_reviews
      SET state='closed', outcome=?2, namedClass=?3, promotionCaseId=?4,
          reviewer=?5, cause=?6, closedAt=?7
      WHERE incidentId=?1 AND state='pending'
      """,
      [
        incident_id,
        outcome,
        Map.get(input, :named_class),
        promotion_case_id,
        reviewer,
        cause,
        now(input)
      ]
    )

    if Txn.changes(txn) != 1, do: raise(ArgumentError, "review_not_pending")

    if outcome == "promotion_required" do
      Txn.q(
        txn,
        "UPDATE harness_health_other_reviews SET routeOrdinal=routeOrdinal+1 WHERE incidentId=?1",
        [incident_id]
      )
    end

    event = %{
      incidentId: incident_id,
      outcome: outcome,
      reviewer: reviewer,
      namedClass: Map.get(input, :named_class)
    }

    Txn.q(
      txn,
      "INSERT INTO harness_health_other_review_events (id,incidentId,eventKind,actor,payload,createdAt) VALUES (?1,?2,'review_closed',?3,?4,?5)",
      ["hhore_" <> Id.uuid4(), incident_id, reviewer, JSON.encode!(event), now(input)]
    )

    result = %{incidentId: incident_id, state: "closed", outcome: outcome}

    store_other_idempotency(
      txn,
      reviewer,
      idempotency_key,
      fingerprint,
      {:reviewed, result},
      "review-other"
    )

    {:reviewed, result}
  end

  defp required_review_cause!(input) do
    case Map.get(input, :cause) do
      cause when is_binary(cause) ->
        cause = String.trim(cause)
        if cause == "", do: raise(ArgumentError, "invalid_review_outcome"), else: cause

      _ ->
        raise ArgumentError, "invalid_review_outcome"
    end
  end

  @doc "Close an open recurrence promotion with the reviewed canonical contract."
  @spec close_other_promotion(DB.server(), map()) :: {:ok, map()} | {:error, map()}
  def close_other_promotion(db \\ DB, input) do
    try do
      result = transaction!(db, &close_other_promotion_in_txn(&1, input))

      case result do
        {:promotion_closed, detail} -> {:ok, detail}
        {:duplicate, detail} -> {:ok, detail}
      end
    rescue
      error in ArgumentError -> {:error, %{code: other_error_code(error), message: error.message}}
    end
  end

  defp close_other_promotion_in_txn(txn, input) do
    promotion_id = required_string!(input, :promotion_id)
    principal = normalize_principal!(Map.get(input, :principal, "process:tightbeam"))
    named_class = required_string!(input, :named_class)
    spec_artifact_id = required_string!(input, :spec_artifact_id)
    review_artifact_id = required_string!(input, :review_artifact_id)
    review_attest_id = required_string!(input, :review_attest_id)
    review_assignment_id = required_string!(input, :review_assignment_id)
    candidate_commit = required_string!(input, :candidate_commit)
    idempotency_key = required_string!(input, :idempotency_key)

    unless valid_promoted_class?(named_class),
      do: raise(ArgumentError, "invalid_promotion_close")

    provenance =
      verify_promotion_provenance!(
        txn,
        promotion_id,
        named_class,
        spec_artifact_id,
        review_artifact_id,
        review_attest_id,
        review_assignment_id,
        candidate_commit,
        input
      )

    spec_ref = provenance.spec_ref
    spec_sha256 = provenance.spec_sha256

    unless promotion_close_authorized?(txn, principal, promotion_id),
      do: raise(ArgumentError, "not_authorized")

    fingerprint =
      %{
        promotion_id: promotion_id,
        named_class: named_class,
        spec_ref: spec_ref,
        spec_sha256: spec_sha256,
        spec_artifact_id: spec_artifact_id,
        review_artifact_id: review_artifact_id,
        review_attest_id: review_attest_id,
        review_assignment_id: review_assignment_id,
        candidate_commit: candidate_commit
      }
      |> JSON.encode!()
      |> sha256()

    case other_idempotency(txn, principal_ref(principal), idempotency_key, "promotion-close") do
      %{request_fingerprint: ^fingerprint, response: response} ->
        decode_other_idempotency(response)

      %{request_fingerprint: _} ->
        raise ArgumentError, "idempotency_conflict"

      nil ->
        result =
          case Txn.q(
                 txn,
                 "SELECT state,namedClass,specRef,specSha256,reviewArtifactId,reviewAttestId,firstIncidentId FROM harness_health_class_promotions WHERE id=?1",
                 [promotion_id]
               ) do
            [
              [
                "closed",
                ^named_class,
                ^spec_ref,
                ^spec_sha256,
                ^review_artifact_id,
                ^review_attest_id,
                _first
              ]
            ] ->
              %{
                promotionId: promotion_id,
                state: "closed",
                namedClass: named_class,
                reviewAttestId: provenance.existing_review_attest_id || review_attest_id
              }

            [["closed", _named, _ref, _sha, _artifact, _attest, _first]] ->
              raise ArgumentError, "promotion_closed"

            [["open", nil, nil, nil, nil, nil, first_incident_id]] ->
              Txn.q(
                txn,
                """
                UPDATE harness_health_class_promotions
                SET state='closed',namedClass=?2,specRef=?3,specSha256=?4,
                    reviewArtifactId=?5,reviewAttestId=?6,reviewedClean=1,closedBy=?7,closedAt=?8
                WHERE id=?1 AND state='open'
                """,
                [
                  promotion_id,
                  named_class,
                  spec_ref,
                  spec_sha256,
                  review_artifact_id,
                  review_attest_id,
                  principal_text(principal),
                  System.system_time(:millisecond)
                ]
              )

              if Txn.changes(txn) != 1, do: raise(ArgumentError, "promotion_closed")

              Txn.q(
                txn,
                "INSERT INTO harness_health_other_review_events (id,incidentId,eventKind,actor,payload,createdAt) VALUES (?1,?2,'promotion_closed',?3,?4,?5)",
                [
                  "hhore_" <> Id.uuid4(),
                  first_incident_id,
                  principal_text(principal),
                  JSON.encode!(%{
                    promotionId: promotion_id,
                    namedClass: named_class,
                    specArtifactId: spec_artifact_id,
                    specRef: spec_ref,
                    specSha256: spec_sha256,
                    reviewArtifactId: review_artifact_id,
                    reviewAttestId: review_attest_id,
                    reviewAssignmentId: review_assignment_id,
                    reviewerSession: provenance.reviewer_session
                  }),
                  System.system_time(:millisecond)
                ]
              )

              %{
                promotionId: promotion_id,
                state: "closed",
                namedClass: named_class,
                reviewAttestId: review_attest_id
              }

            [] ->
              raise ArgumentError, "promotion_not_found"
          end

        store_other_idempotency(
          txn,
          principal_ref(principal),
          idempotency_key,
          fingerprint,
          {:promotion_closed, result},
          "promotion-close"
        )

        {:promotion_closed, result}
    end
  end

  defp verify_promotion_provenance!(
         txn,
         promotion_id,
         named_class,
         spec_artifact_id,
         review_artifact_id,
         review_attest_id,
         review_assignment_id,
         candidate_commit,
         input
       ) do
    [promotion] =
      case Txn.q(
             txn,
             "SELECT state,firstIncidentId,secondIncidentId,namedClass,specRef,specSha256,reviewArtifactId,reviewAttestId FROM harness_health_class_promotions WHERE id=?1",
             [promotion_id]
           ) do
        [] -> raise ArgumentError, "promotion_not_found"
        rows -> rows
      end

    [
      promotion_state,
      first_incident,
      second_incident,
      stored_named_class,
      stored_spec_ref,
      stored_spec_sha256,
      stored_review_artifact_id,
      stored_review_attest_id
    ] = promotion

    spec =
      case Txn.q(
             txn,
             "SELECT kind,originPath,contentSha256,workItemId FROM artifacts WHERE artifactId=?1",
             [spec_artifact_id]
           ) do
        [["spec", ref, sha, work_item_id]]
        when is_binary(ref) and is_binary(sha) and is_binary(work_item_id) ->
          if sha256_digest?(sha),
            do: %{spec_ref: ref, spec_sha256: sha, work_item_id: work_item_id},
            else: raise(ArgumentError, "invalid_promotion_close")

        _ ->
          raise ArgumentError, "invalid_promotion_close"
      end

    unless Txn.q(txn, "SELECT specRefName,specRefSha256 FROM work_items WHERE id=?1", [
             spec.work_item_id
           ]) == [[spec.spec_ref, spec.spec_sha256]],
           do: raise(ArgumentError, "invalid_promotion_close")

    review =
      case Txn.q(
             txn,
             "SELECT kind,contentSha256,workItemId FROM artifacts WHERE artifactId=?1",
             [review_artifact_id]
           ) do
        [["report", sha, work_item_id]] when is_binary(sha) and is_binary(work_item_id) ->
          if sha256_digest?(sha),
            do: %{content_sha256: sha, work_item_id: work_item_id},
            else: raise(ArgumentError, "invalid_promotion_close")

        _ ->
          raise ArgumentError, "invalid_promotion_close"
      end

    attest =
      case Txn.q(
             txn,
             "SELECT kind,assignmentId,verdictKind,bySession,byUser,artifactId,contentSha256,commitRefs FROM attests WHERE id=?1",
             [review_attest_id]
           ) do
        [
          [
            "verdict",
            ^review_assignment_id,
            "reviewed-clean",
            reviewer_session,
            reviewer_user,
            ^review_artifact_id,
            content_sha,
            commit_refs
          ]
        ]
        when is_binary(reviewer_session) and is_binary(content_sha) ->
          %{
            reviewer_session: reviewer_session,
            reviewer_user: reviewer_user,
            content_sha256: content_sha,
            commit_refs: commit_refs
          }

        _ ->
          raise ArgumentError, "invalid_promotion_close"
      end

    unless attest.content_sha256 == review.content_sha256 and
             commit_ref_matches?(attest.commit_refs, candidate_commit),
           do: raise(ArgumentError, "invalid_promotion_close")

    candidate_work_item_id = review_work_item_id(txn, review_assignment_id)

    unless review_assignment_id != promotion_id and
             is_binary(candidate_work_item_id) and
             review.work_item_id == candidate_work_item_id and
             spec.work_item_id == candidate_work_item_id and
             review_bound_to_candidate?(txn, review_assignment_id, attest.reviewer_session),
           do: raise(ArgumentError, "invalid_promotion_close")

    unless is_binary(first_incident) and is_binary(second_incident) and
             first_incident != second_incident and
             Txn.q(
               txn,
               "SELECT COUNT(*) FROM harness_health_incidents WHERE id IN (?1,?2) AND failureClass='other' AND descriptionDigest=(SELECT descriptionDigest FROM harness_health_class_promotions WHERE id=?3)",
               [first_incident, second_incident, promotion_id]
             ) == [[2]],
           do: raise(ArgumentError, "invalid_promotion_close")

    source_sessions =
      Txn.q(
        txn,
        "SELECT DISTINCT sessionKey FROM harness_health_observations WHERE id IN ((SELECT openObservationId FROM harness_health_incidents WHERE id=?1),(SELECT openObservationId FROM harness_health_incidents WHERE id=?2)) AND sessionKey IS NOT NULL",
        [first_incident, second_incident]
      )
      |> List.flatten()

    unless attest.reviewer_session not in source_sessions and
             attest.reviewer_session != principal_session(input),
           do: raise(ArgumentError, "invalid_promotion_close")

    if input[:spec_ref] && input.spec_ref != spec.spec_ref,
      do: raise(ArgumentError, "invalid_promotion_close")

    if input[:spec_sha256] && input.spec_sha256 != spec.spec_sha256,
      do: raise(ArgumentError, "invalid_promotion_close")

    existing_review_attest_id =
      if promotion_state == "closed" do
        unless stored_named_class == named_class and stored_spec_ref == spec.spec_ref and
                 stored_spec_sha256 == spec.spec_sha256 and
                 stored_review_artifact_id == review_artifact_id and
                 stored_review_attest_id == review_attest_id,
               do: raise(ArgumentError, "promotion_closed")

        stored_review_attest_id
      else
        nil
      end

    spec
    |> Map.put(:reviewer_session, attest.reviewer_session)
    |> Map.put(:reviewer_user, attest.reviewer_user)
    |> Map.put(:review_artifact_sha256, review.content_sha256)
    |> Map.put(:existing_review_attest_id, existing_review_attest_id)
  end

  defp review_bound_to_candidate?(txn, assignment_id, reviewer_session) do
    case Txn.q(
           txn,
           """
           SELECT review.holderKey,review.state,review.workItemId,review.reviewsAssignmentId,
                  candidate.id,candidate.holderKey,candidate.workItemId,candidate.reviewsAssignmentId
           FROM assignments review
           JOIN assignments candidate ON candidate.id=review.reviewsAssignmentId
           WHERE review.id=?1
           """,
           [assignment_id]
         ) do
      [
        [
          ^reviewer_session,
          state,
          review_work_item_id,
          _parent,
          _candidate_id,
          candidate_holder,
          candidate_work_item_id,
          nil
        ]
      ]
      when state in ["open", "closed"] and review_work_item_id == candidate_work_item_id and
             candidate_holder != reviewer_session ->
        true

      _ ->
        false
    end
  end

  defp review_work_item_id(txn, assignment_id) do
    case Txn.q(txn, "SELECT workItemId FROM assignments WHERE id=?1", [assignment_id]) do
      [[work_item_id]] -> work_item_id
      _ -> nil
    end
  end

  defp principal_session({:session, session}), do: session
  defp principal_session(_principal), do: nil

  defp promotion_close_authorized?(txn, {kind, value}, promotion_id)
       when kind in [:user, :session] do
    case kind do
      :user ->
        admin_user?(txn, value) or
          Txn.q(
            txn,
            "SELECT 1 FROM harness_health_class_promotions p JOIN harness_health_incidents i ON i.id IN (p.firstIncidentId,p.secondIncidentId) JOIN harness_health_observations o ON o.id=i.openObservationId JOIN sessions s ON s.sessionKey=o.sessionKey WHERE p.id=?1 AND s.ownerUserId=?2",
            [promotion_id, value]
          ) != []

      :session ->
        case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [value]) do
          [["active"]] ->
            Txn.q(
              txn,
              """
              SELECT o.sessionKey,s.ownerUserId,r.custodian
              FROM harness_health_class_promotions p
              JOIN harness_health_incidents i ON i.id IN (p.firstIncidentId,p.secondIncidentId)
              JOIN harness_health_observations o ON o.id=i.openObservationId
              JOIN sessions s ON s.sessionKey=o.sessionKey
              LEFT JOIN harness_health_other_reviews r ON r.incidentId=i.id
              WHERE p.id=?1
              """,
              [promotion_id]
            )
            |> Enum.any?(fn [source, owner, custodian] ->
              value == source or value == custodian or
                active_same_owner_ancestor?(txn, value, source, owner)
            end)

          _ ->
            false
        end
    end
  end

  defp promotion_close_authorized?(_txn, _principal, _promotion_id), do: false

  defp review_authorized?(txn, incident_id, principal) do
    rows =
      Txn.q(
        txn,
        """
        SELECT o.sessionKey,r.custodian,s.ownerUserId
        FROM harness_health_incidents i
        JOIN harness_health_observations o ON o.id=i.openObservationId
        JOIN harness_health_other_reviews r ON r.incidentId=i.id
        JOIN sessions s ON s.sessionKey=o.sessionKey
        WHERE i.id=?1
        """,
        [incident_id]
      )

    case {rows, principal} do
      {[[source, custodian, owner]], {:session, session}} ->
        session == custodian or session == source or
          active_same_owner_ancestor?(txn, session, source, owner)

      {[[_, _, owner]], {:user, user}} ->
        user == owner or admin_user?(txn, user)

      {[[_, _, owner]], "user:" <> user} ->
        user == owner or admin_user?(txn, user)

      _ ->
        false
    end
  end

  defp resolve_other_authorized?(txn, incident_id, principal) do
    rows =
      Txn.q(
        txn,
        """
        SELECT o.sessionKey,s.ownerUserId,r.custodian
        FROM harness_health_incidents i
        JOIN harness_health_observations o ON o.id=i.openObservationId
        JOIN sessions s ON s.sessionKey=o.sessionKey
        LEFT JOIN harness_health_other_reviews r ON r.incidentId=i.id
        WHERE i.id=?1 AND i.failureClass='other' AND i.state='open'
        """,
        [incident_id]
      )

    case {rows, principal} do
      {[[source, owner, custodian]], {:session, session}} ->
        session == source or session == custodian or
          active_same_owner_ancestor?(txn, session, source, owner)

      {[[_, owner, _]], {:user, user}} ->
        user == owner or admin_user?(txn, user)

      {[[_, owner, _]], "user:" <> user} ->
        user == owner or admin_user?(txn, user)

      _ ->
        false
    end
  end

  defp active_same_owner_ancestor?(txn, candidate, source, owner) do
    ancestor_chain(txn, source, owner, MapSet.new(), 0)
    |> Enum.any?(&(&1 == candidate))
  end

  defp ancestor_chain(_txn, _session, _owner, _seen, hop) when hop >= 32, do: []

  defp ancestor_chain(txn, session, owner, seen, hop) do
    if MapSet.member?(seen, session) do
      []
    else
      case Txn.q(
             txn,
             "SELECT spawnedBy,ownerUserId,state FROM sessions WHERE sessionKey=?1",
             [session]
           ) do
        [[nil, _owner, _state]] ->
          []

        [[parent, ^owner, "active"]] ->
          [parent | ancestor_chain(txn, parent, owner, MapSet.put(seen, session), hop + 1)]

        [[parent, ^owner, _state]] ->
          ancestor_chain(txn, parent, owner, MapSet.put(seen, session), hop + 1)

        [[_parent, _foreign_owner, _state]] ->
          []

        [] ->
          []
      end
    end
  end

  @doc "List currently open incidents, oldest first."
  @spec active(DB.server()) :: [map()]
  def active(db \\ DB) do
    {:ok, rows} =
      DB.query(db, incident_sql() <> " WHERE state='open' ORDER BY openedAt,id")

    Enum.map(rows, &(incident(&1) |> ordinary_incident() |> with_repair_guidance()))
  end

  @doc "Read one incident with the evidence that names its affected work."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ DB, incident_id) do
    with {:ok, [row]} <- DB.query(db, incident_sql() <> " WHERE id=?1", [incident_id]) do
      incident = row |> incident() |> ordinary_incident() |> with_repair_guidance()

      {:ok, observations} =
        DB.query(
          db,
          observation_sql() <> " WHERE incidentId=?1 ORDER BY observedAt,id",
          [incident_id]
        )

      observations = Enum.map(observations, &(observation(&1) |> ordinary_observation()))

      {:ok, members} =
        DB.query(
          db,
          "SELECT sessionKey FROM harness_health_members WHERE incidentId=?1 ORDER BY sessionKey",
          [incident_id]
        )

      {:ok, assignments} =
        DB.query(
          db,
          "SELECT assignmentId FROM harness_health_assignments WHERE incidentId=?1 ORDER BY assignmentId",
          [incident_id]
        )

      Map.merge(incident, %{
        observations: observations,
        affectedSessions: List.flatten(members),
        affectedAssignments: List.flatten(assignments)
      })
    else
      {:ok, []} -> nil
    end
  end

  @doc "Read exact other-incident evidence for an authorized source or custodian."
  @spec read_other_evidence(DB.server(), String.t(), term()) ::
          {:ok, map()} | {:error, map()}
  def read_other_evidence(db \\ DB, incident_id, principal) do
    try do
      transaction!(db, fn txn -> read_other_evidence_in_txn(txn, incident_id, principal) end)
    rescue
      error in ArgumentError -> {:error, %{code: other_error_code(error), message: error.message}}
    end
  end

  defp read_other_evidence_in_txn(txn, incident_id, principal) do
    principal = normalize_principal!(principal)

    case Txn.q(
           txn,
           """
           SELECT i.id,o.sessionKey,s.ownerUserId,r.custodian
           FROM harness_health_incidents i
           JOIN harness_health_observations o ON o.id=i.openObservationId
           JOIN sessions s ON s.sessionKey=o.sessionKey
           LEFT JOIN harness_health_other_reviews r ON r.incidentId=i.id
           WHERE i.id=?1 AND i.failureClass='other'
           """,
           [incident_id]
         ) do
      [[^incident_id, source, owner, custodian]] ->
        unless evidence_read_authorized?(txn, principal, source, owner, custodian),
          do: raise(ArgumentError, "not_authorized")

        [incident_row] = Txn.q(txn, incident_sql() <> " WHERE id=?1", [incident_id])

        incident = incident(incident_row)

        observations =
          Txn.q(
            txn,
            observation_sql() <> " WHERE incidentId=?1 ORDER BY observedAt,id",
            [incident_id]
          )
          |> Enum.map(&observation/1)

        review_notice =
          case Txn.q(
                 txn,
                 "SELECT ordinal,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 ORDER BY ordinal LIMIT 1",
                 [incident_id]
               ) do
            [[ordinal, notice_wake_id, turn_seq]] ->
              %{
                digest: incident.descriptionDigest,
                pointer: %{
                  incidentId: incident_id,
                  routeOrdinal: ordinal,
                  noticeWakeId: notice_wake_id,
                  turnSeq: turn_seq
                }
              }

            [] ->
              nil
          end

        {:ok, %{incident: incident, observations: observations, reviewNotice: review_notice}}

      [] ->
        raise ArgumentError, "evidence_not_found"
    end
  end

  defp evidence_read_authorized?(txn, {:session, session}, source, owner, custodian) do
    session == source or session == custodian or custodian == "session:" <> session or
      active_same_owner_ancestor?(txn, session, source, owner)
  end

  defp evidence_read_authorized?(txn, {:user, user}, _source, owner, _custodian),
    do: user == owner or admin_user?(txn, user)

  defp evidence_read_authorized?(_txn, "process:tightbeam", _source, _owner, _custodian),
    do: false

  defp evidence_read_authorized?(_txn, _principal, _source, _owner, _custodian), do: false

  defp recognize_new_observation(txn, input) do
    observation_id = insert_observation(txn, input, nil, input.evidence_kind)

    case open_incident(txn, input) do
      nil ->
        if input.evidence_kind == "authoritative-provider" or distinct_sessions(txn, input) >= 2 do
          open_new_incident(txn, observation_id, input)
        else
          {:pending, pending(txn, input, observation_id)}
        end

      incident ->
        attach_observation(txn, incident.id, observation_id)

        EventLog.lifecycle_in_txn(
          txn,
          "harness_health_evidence_attached",
          incident.id,
          lifecycle_detail(input, observation_id)
        )

        {:attached, Map.put(incident, :observationId, observation_id)}
    end
  end

  defp open_new_incident(txn, opening_observation_id, input) do
    case incident_recipient(txn, input) do
      :no_recipient ->
        refuse_incident_promotion(txn, opening_observation_id, input)

      {:ok, recipient} ->
        do_open_new_incident(txn, opening_observation_id, input, recipient)
    end
  end

  defp do_open_new_incident(txn, opening_observation_id, input, recipient) do
    incident_id = "hhi_" <> Id.uuid4()

    fact_id =
      if input.failure_class == @other_failure_class and
           active_other_count(txn, input.harness, input.host) > 0 do
        nil
      else
        %{fact_id: fact_id} =
          ConditionFacts.file_harness_health_in_txn(
            txn,
            input.harness,
            input.host,
            input.failure_class,
            :assert
          )

        fact_id
      end

    Txn.q(
      txn,
      """
      INSERT INTO harness_health_incidents
        (id,harness,host,failureClass,state,openedAt,openObservationId,openedFactId,
         descriptionDigest,expiresAt)
      VALUES (?1,?2,?3,?4,'open',?5,?6,?7,?8,?9)
      """,
      [
        incident_id,
        input.harness,
        input.host,
        input.failure_class,
        input.observed_at,
        opening_observation_id,
        fact_id,
        Map.get(input, :description_digest),
        if(input.failure_class == @other_failure_class, do: input.valid_until, else: nil)
      ]
    )

    if input.failure_class == "rate-limit-dead" do
      HarnessProcess.begin_park_in_txn(txn, adapter_key(input.harness, input.host))
    end

    snapshot_affected_work(txn, incident_id, input)

    if input.failure_class == @other_failure_class do
      create_other_review_in_txn(txn, incident_id, input, recipient)
    end

    observations_to_attach(txn, input)
    |> Enum.each(&attach_observation(txn, incident_id, &1))

    EventLog.lifecycle_in_txn(
      txn,
      "harness_health_incident_opened",
      incident_id,
      lifecycle_detail(input, opening_observation_id)
    )

    notice_publication = incident_notice_in_txn(txn, incident_id, input, recipient)

    {:opened,
     %{
       id: incident_id,
       harness: input.harness,
       host: input.host,
       failureClass: input.failure_class,
       state: "open",
       openedAt: input.observed_at,
       openedFactId: fact_id,
       observationId: opening_observation_id,
       notice_publication: notice_publication
     }}
  end

  defp refuse_incident_promotion(txn, observation_id, input) do
    EventLog.lifecycle_in_txn(
      txn,
      "harness_health_incident_refused",
      observation_id,
      JSON.encode!(%{
        observationId: observation_id,
        harness: input.harness,
        host: input.host,
        failureClass: input.failure_class,
        evidenceKind: input.evidence_kind,
        correlationId: input.correlation_id,
        principal: input.principal,
        causeClass:
          if(input.failure_class == @other_failure_class, do: "evidence", else: "failure"),
        reason: "no-active-main"
      })
    )

    {:pending,
     txn
     |> pending(input, observation_id)
     |> Map.put(:refusal, "no-active-main")}
  end

  defp resolve_open(txn, input) do
    case open_incident(txn, input) do
      nil ->
        :already_healthy

      incident ->
        observation_id = insert_observation(txn, input, incident.id, "normal-turn-success")
        attach_observation_references(txn, incident.id, observation_id)

        %{fact_id: fact_id} =
          ConditionFacts.file_harness_health_in_txn(
            txn,
            input.harness,
            input.host,
            input.failure_class,
            :retract
          )

        Txn.q(
          txn,
          """
          UPDATE harness_health_incidents
          SET state='resolved',resolvedAt=?2,resolutionObservationId=?3,resolvedFactId=?4
          WHERE id=?1 AND state='open'
          """,
          [incident.id, input.observed_at, observation_id, fact_id]
        )

        if Txn.changes(txn) != 1, do: raise("harness health incident resolution race")

        if input.failure_class == "rate-limit-dead" do
          HarnessProcess.complete_park_in_txn(txn, adapter_key(input.harness, input.host))
        end

        EventLog.lifecycle_in_txn(
          txn,
          "harness_health_incident_resolved",
          incident.id,
          lifecycle_detail(input, observation_id)
        )

        {:resolved,
         Map.merge(incident, %{
           state: "resolved",
           resolvedAt: input.observed_at,
           resolvedFactId: fact_id,
           resolutionObservationId: observation_id
         })}
    end
  end

  defp distinct_sessions(txn, input) do
    [[count]] =
      Txn.q(
        txn,
        """
        SELECT COUNT(DISTINCT sessionKey)
        FROM harness_health_observations
        WHERE harness=?1 AND host=?2 AND failureClass=?3
          AND evidenceKind='terminal-failure' AND incidentId IS NULL
          AND observedAt BETWEEN ?4 AND ?5
        """,
        window_params(input)
      )

    count
  end

  defp adapter_key(harness, host), do: {Harness.parse!(harness).id(), "shared", host}

  defp observations_to_attach(txn, input) do
    authoritative =
      if input.evidence_kind == "authoritative-provider" do
        [observation_by_correlation(txn, input.correlation_id).id]
      else
        []
      end

    inferred =
      Txn.q(
        txn,
        """
        SELECT id FROM harness_health_observations
        WHERE harness=?1 AND host=?2 AND failureClass=?3
          AND evidenceKind='terminal-failure' AND incidentId IS NULL
          AND observedAt BETWEEN ?4 AND ?5
        ORDER BY observedAt,id
        """,
        window_params(input)
      )
      |> List.flatten()

    Enum.uniq(authoritative ++ inferred)
  end

  defp window_params(input) do
    [
      input.harness,
      input.host,
      input.failure_class,
      max(0, input.observed_at - @evidence_window_ms),
      input.observed_at
    ]
  end

  defp insert_observation(txn, input, incident_id, evidence_kind) do
    observation_id = "hho_" <> Id.uuid4()

    Txn.q(
      txn,
      """
      INSERT INTO harness_health_observations
        (id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,assignmentId,
         observedAt,cause,principal,incidentId,description,descriptionDigest,observedState,
         evidenceMode,exactObservedError,exactProbe,outputDigest,recoveryCondition,
         recoveryConditionDigest,recoverySatisfied,notKnownClassReason,validUntil,worldStatus,
         redactionConfirmed)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26)
      """,
      [
        observation_id,
        input.correlation_id,
        input.harness,
        input.host,
        input.failure_class,
        evidence_kind,
        input.session_key,
        input.assignment_id,
        input.observed_at,
        input.cause,
        input.principal,
        incident_id,
        Map.get(input, :description),
        Map.get(input, :description_digest),
        Map.get(input, :observed_state),
        Map.get(input, :evidence_mode),
        Map.get(input, :exact_observed_error),
        Map.get(input, :exact_probe),
        Map.get(input, :output_digest),
        Map.get(input, :recovery_condition),
        Map.get(input, :recovery_condition_digest),
        Map.get(input, :recovery_satisfied),
        Map.get(input, :not_known_class_reason),
        Map.get(input, :valid_until),
        Map.get(input, :world_status),
        bool_int(Map.get(input, :redaction_confirmed))
      ]
    )

    observation_id
  end

  defp attach_observation(txn, incident_id, observation_id) do
    Txn.q(
      txn,
      "UPDATE harness_health_observations SET incidentId=?2 WHERE id=?1 AND incidentId IS NULL",
      [observation_id, incident_id]
    )

    if Txn.changes(txn) == 1 do
      attach_observation_references(txn, incident_id, observation_id)
    end
  end

  defp snapshot_affected_work(txn, incident_id, input) do
    Txn.q(
      txn,
      """
      INSERT INTO harness_health_members (incidentId,sessionKey)
      SELECT ?1,sessionKey FROM sessions
      WHERE harness=?2 AND host=?3 AND state='active'
      ORDER BY sessionKey
      """,
      [incident_id, input.harness, input.host]
    )

    Txn.q(
      txn,
      """
      INSERT INTO harness_health_assignments (incidentId,assignmentId,sessionKey)
      SELECT ?1,a.id,a.holderKey
      FROM assignments a
      JOIN harness_health_members m
        ON m.incidentId=?1 AND m.sessionKey=a.holderKey
      WHERE a.state='open'
      ORDER BY a.id
      """,
      [incident_id]
    )
  end

  defp attach_observation_references(txn, incident_id, observation_id) do
    observation = observation_by_id(txn, observation_id)

    if observation.session_key do
      Txn.q(
        txn,
        "INSERT OR IGNORE INTO harness_health_members (incidentId,sessionKey) VALUES (?1,?2)",
        [incident_id, observation.session_key]
      )

      if observation.assignment_id do
        Txn.q(
          txn,
          """
          INSERT OR IGNORE INTO harness_health_assignments
            (incidentId,assignmentId,sessionKey) VALUES (?1,?2,?3)
          """,
          [incident_id, observation.assignment_id, observation.session_key]
        )
      end
    end
  end

  defp duplicate_or_refuse!(txn, prior, input, evidence_kind) do
    if observation_identity(prior) ==
         observation_identity(%{input | evidence_kind: evidence_kind}) do
      result =
        if prior.incident_id,
          do: Map.put(incident_by_id(txn, prior.incident_id), :observationId, prior.id),
          else: pending(txn, input, prior.id)

      {:duplicate, result}
    else
      raise ArgumentError,
            "harness health correlation #{input.correlation_id} was already used for different evidence"
    end
  end

  defp pending(txn, input, observation_id) do
    %{
      observationId: observation_id,
      distinctSessions: distinct_sessions(txn, input),
      requiredSessions: 2
    }
  end

  defp observation_identity(observation) do
    base =
      Map.take(observation, [
        :correlation_id,
        :harness,
        :host,
        :failure_class,
        :evidence_kind,
        :session_key,
        :assignment_id,
        :observed_at,
        :cause,
        :principal
      ])

    if observation[:failure_class] == @other_failure_class do
      Map.merge(
        base,
        Map.take(observation, [
          :description_digest,
          :observed_state,
          :evidence_mode,
          :exact_observed_error,
          :exact_probe,
          :output_digest,
          :recovery_condition_digest,
          :recovery_satisfied,
          :not_known_class_reason,
          :valid_until,
          :world_status,
          :redaction_confirmed
        ])
      )
    else
      base
    end
  end

  defp observation_by_correlation(txn, correlation_id) do
    case Txn.q(txn, observation_sql() <> " WHERE correlationId=?1", [correlation_id]) do
      [row] -> observation(row)
      [] -> nil
    end
  end

  defp observation_by_id(txn, observation_id) do
    [row] = Txn.q(txn, observation_sql() <> " WHERE id=?1", [observation_id])
    observation(row)
  end

  defp open_incident(txn, input) do
    case Txn.q(
           txn,
           incident_sql() <> " WHERE harness=?1 AND host=?2 AND failureClass=?3 AND state='open'",
           [input.harness, input.host, input.failure_class]
         ) do
      [row] -> incident(row)
      [] -> nil
    end
  end

  defp other_open_incident(txn, input) do
    case Txn.q(
           txn,
           incident_sql() <>
             " WHERE harness=?1 AND host=?2 AND failureClass='other' AND state='open' AND descriptionDigest=?3",
           [input.harness, input.host, input.description_digest]
         ) do
      [row] -> incident(row)
      [] -> nil
    end
  end

  defp incident_by_id(txn, incident_id) do
    [row] = Txn.q(txn, incident_sql() <> " WHERE id=?1", [incident_id])
    incident(row)
  end

  defp observation_sql do
    """
    SELECT id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,
           assignmentId,observedAt,cause,principal,incidentId,description,descriptionDigest,
           observedState,evidenceMode,exactObservedError,exactProbe,outputDigest,
           recoveryCondition,recoveryConditionDigest,recoverySatisfied,notKnownClassReason,
           validUntil,worldStatus,redactionConfirmed
    FROM harness_health_observations
    """
  end

  defp incident_sql do
    """
    SELECT id,harness,host,failureClass,state,openedAt,openObservationId,openedFactId,
           resolvedAt,resolutionObservationId,resolvedFactId,descriptionDigest,expiresAt,
           expiredAt,expiryFactId
    FROM harness_health_incidents
    """
  end

  defp observation(row), do: Map.new(Enum.zip(@observation_columns, row))

  # Routine reads expose operational state only. Evidence-bearing fields stay
  # in the append-only store and require an explicit authorized evidence path;
  # they must not leak through ordinary list/get or lifecycle consumers.
  defp ordinary_incident(incident),
    do: Map.drop(incident, [:descriptionDigest])

  defp ordinary_observation(observation),
    do:
      Map.drop(observation, [
        :cause,
        :description,
        :description_digest,
        :observed_state,
        :evidence_mode,
        :exact_observed_error,
        :exact_probe,
        :output_digest,
        :recovery_condition,
        :recovery_condition_digest,
        :not_known_class_reason,
        :valid_until,
        :redaction_confirmed
      ])

  defp incident(row) do
    @incident_columns
    |> Enum.zip(row)
    |> Map.new()
    |> Map.new(fn
      {:failure_class, value} -> {:failureClass, value}
      {:opened_at, value} -> {:openedAt, value}
      {:open_observation_id, value} -> {:openObservationId, value}
      {:opened_fact_id, value} -> {:openedFactId, value}
      {:resolved_at, value} -> {:resolvedAt, value}
      {:resolution_observation_id, value} -> {:resolutionObservationId, value}
      {:resolved_fact_id, value} -> {:resolvedFactId, value}
      {:description_digest, value} -> {:descriptionDigest, value}
      {:expires_at, value} -> {:expiresAt, value}
      {:expired_at, value} -> {:expiredAt, value}
      {:expiry_fact_id, value} -> {:expiryFactId, value}
      entry -> entry
    end)
  end

  defp normalize_failure!(input) do
    input = normalize_common!(input)

    unless input.evidence_kind in @failure_evidence do
      raise ArgumentError,
            "unknown harness failure evidence kind: #{inspect(input.evidence_kind)}"
    end

    if input.evidence_kind == "terminal-failure" and is_nil(input.session_key) do
      raise ArgumentError, "terminal harness failure evidence requires a session_key"
    end

    input
  end

  defp normalize_other!(input) do
    principal = Map.get(input, :principal, "process:tightbeam")

    accepted_at =
      integer_or_default(Map.get(input, :accepted_at), System.system_time(:millisecond))

    observed_at = integer_or_default(Map.get(input, :observed_at), accepted_at)
    valid_until = integer_or_default(Map.get(input, :valid_until), nil)
    evidence_mode = required_string!(input, :evidence_mode)
    world_status = required_string!(input, :world_status)

    description = required_bounded_string!(input, :description, 2_000)
    observed_state = required_bounded_string!(input, :observed_state, 2_000)
    exact_probe = required_bounded_string!(input, :exact_probe, 4_000)
    recovery_condition = required_bounded_string!(input, :recovery_condition, 2_000)
    not_known_class_reason = required_bounded_string!(input, :not_known_class_reason, 2_000)

    unless observed_at <= accepted_at,
      do: raise(ArgumentError, "stale_other_evidence")

    unless is_integer(valid_until) and valid_until > accepted_at and
             valid_until <= observed_at + @other_max_validity_ms,
           do: raise(ArgumentError, "invalid_other_evidence")

    unless evidence_mode in ~w(exact_error probe_digest),
      do: raise(ArgumentError, "invalid_other_evidence")

    unless world_status in ~w(PROVEN UNKNOWN),
      do: raise(ArgumentError, "invalid_other_evidence")

    exact_observed_error = bounded_string(Map.get(input, :exact_observed_error), 8_000)
    output_digest = bounded_string(Map.get(input, :output_digest), 64)

    cond do
      evidence_mode == "exact_error" and (is_nil(exact_observed_error) or output_digest != nil) ->
        raise(ArgumentError, "invalid_other_evidence")

      evidence_mode == "probe_digest" and
          (exact_observed_error != nil or not sha256_digest?(output_digest)) ->
        raise(ArgumentError, "invalid_other_evidence")

      world_status == "UNKNOWN" and evidence_mode != "exact_error" ->
        raise(ArgumentError, "invalid_other_evidence")

      true ->
        :ok
    end

    unless bool_int(Map.get(input, :redaction_confirmed)) == 1,
      do: raise(ArgumentError, "secret_redaction_unconfirmed")

    evidence_for_redaction =
      Enum.join(
        [
          description,
          observed_state,
          exact_observed_error,
          exact_probe,
          recovery_condition,
          not_known_class_reason
        ],
        "\n"
      )

    if credential_shaped?(evidence_for_redaction),
      do: raise(ArgumentError, "credential_shaped_evidence")

    source_session_key =
      Map.get(input, :source_session_key) || Map.get(input, :session_key) ||
        raise(ArgumentError, "source_not_found")

    idempotency_key = required_string!(input, :idempotency_key)
    description_digest = sha256(description)

    %{
      correlation_id:
        other_correlation(principal, "harness-health-observe-other", idempotency_key, "open"),
      harness: required_bounded_string!(input, :harness, 512),
      host: required_bounded_string!(input, :host, 512),
      failure_class: @other_failure_class,
      evidence_kind: "authoritative-provider",
      session_key: source_session_key,
      source_session_key: source_session_key,
      assignment_id: nil,
      observed_at: observed_at,
      cause: "other:" <> description_digest,
      principal: principal_text(principal),
      principal_identity: principal,
      description: description,
      description_digest: description_digest,
      observed_state: observed_state,
      evidence_mode: evidence_mode,
      exact_observed_error: exact_observed_error,
      exact_probe: exact_probe,
      output_digest: output_digest,
      recovery_condition: recovery_condition,
      recovery_condition_digest: sha256(recovery_condition),
      recovery_satisfied: nil,
      not_known_class_reason: not_known_class_reason,
      valid_until: valid_until,
      world_status: world_status,
      redaction_confirmed: true,
      idempotency_key: idempotency_key,
      conn_registry: Map.get(input, :conn_registry, Tightbeam.ConnRegistry)
    }
  end

  defp normalize_other_recovery!(input) do
    principal = Map.get(input, :principal, "process:tightbeam")
    principal_identity = normalize_principal!(principal)
    idempotency_key = required_string!(input, :idempotency_key)
    incident_id = required_string!(input, :incident_id)

    accepted_at =
      integer_or_default(Map.get(input, :accepted_at), System.system_time(:millisecond))

    observed_at =
      integer_or_default(Map.get(input, :observed_at), accepted_at)

    exact_probe = required_bounded_string!(input, :exact_probe, 4_000)
    observed_state = required_bounded_string!(input, :observed_state, 2_000)
    recovery_condition_digest = required_string!(input, :recovery_condition_digest)
    cause = required_bounded_string!(input, :cause, 2_000)
    output_digest = bounded_string(Map.get(input, :output_digest), 64)

    unless sha256_digest?(output_digest) and sha256_digest?(recovery_condition_digest) and
             Map.get(input, :recovery_satisfied) in [true, 1],
           do: raise(ArgumentError, "invalid_recovery_evidence")

    unless Map.get(input, :world_status) == "PROVEN" and
             bool_int(Map.get(input, :redaction_confirmed)) == 1,
           do: raise(ArgumentError, "invalid_recovery_evidence")

    unless observed_at <= accepted_at,
      do: raise(ArgumentError, "stale_recovery_evidence")

    unless accepted_at - observed_at <= @evidence_window_ms,
      do: raise(ArgumentError, "stale_recovery_evidence")

    if credential_shaped?(Enum.join([observed_state, exact_probe, cause], "\n")),
      do: raise(ArgumentError, "credential_shaped_evidence")

    %{
      correlation_id:
        other_correlation(
          principal,
          "harness-health-resolve-other",
          idempotency_key,
          "resolve"
        ),
      harness: required_bounded_string!(input, :harness, 512),
      host: required_bounded_string!(input, :host, 512),
      failure_class: @other_failure_class,
      evidence_kind: "normal-turn-success",
      session_key: Map.get(input, :session_key),
      incident_id: incident_id,
      assignment_id: nil,
      observed_at: observed_at,
      cause: cause,
      principal: principal_text(principal),
      principal_identity: principal_identity,
      observed_state: observed_state,
      evidence_mode: "probe_digest",
      exact_observed_error: nil,
      exact_probe: exact_probe,
      output_digest: output_digest,
      recovery_condition: nil,
      recovery_condition_digest: recovery_condition_digest,
      recovery_satisfied: 1,
      valid_until: nil,
      world_status: "PROVEN",
      redaction_confirmed: true,
      idempotency_key: idempotency_key
    }
  end

  defp validate_other_source!(txn, input) do
    case Txn.q(
           txn,
           "SELECT ownerUserId,state FROM sessions WHERE sessionKey=?1 AND harness=?2 AND host=?3",
           [input.source_session_key, input.harness, input.host]
         ) do
      [[owner_user_id, "active"]] ->
        unless other_source_authorized?(
                 txn,
                 input.principal_identity,
                 input.source_session_key,
                 owner_user_id
               ),
               do: raise(ArgumentError, "not_authorized")

      [[_, _]] ->
        raise(ArgumentError, "source_not_active")

      [] ->
        raise(ArgumentError, "source_not_found")
    end
  end

  defp other_source_authorized?(txn, {:session, session_key}, source, owner),
    do: session_key == source or active_same_owner_ancestor?(txn, session_key, source, owner)

  defp other_source_authorized?(txn, {:user, user}, _source, owner),
    do: user == owner or admin_user?(txn, user)

  defp other_source_authorized?(txn, user, source, owner) when is_binary(user) do
    case user do
      "session:" <> session -> other_source_authorized?(txn, {:session, session}, source, owner)
      "user:" <> user_id -> other_source_authorized?(txn, {:user, user_id}, source, owner)
      _ -> false
    end
  end

  defp other_source_authorized?(_txn, _principal, _source, _owner), do: false

  defp admin_user?(txn, user),
    do: Txn.q(txn, "SELECT 1 FROM users WHERE userId=?1 AND isAdmin=1", [user]) == [[1]]

  defp create_other_review_in_txn(txn, incident_id, input, _recipient) do
    [[recurrence]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM harness_health_incidents WHERE failureClass='other' AND descriptionDigest=?1",
        [input.description_digest]
      )

    promotion_id =
      if recurrence > 1 do
        ensure_promotion_case_in_txn(txn, input.description_digest, input.observed_at)
      end

    routes = build_other_routes(txn, input)
    selected = Enum.find(routes, &(&1.state in ["pending", "alerted"]))
    custodian = selected.target_ref
    route_ordinal = selected.ordinal

    Txn.q(
      txn,
      "INSERT INTO harness_health_other_reviews (incidentId,state,custodian,routeOrdinal,promotionCaseId) VALUES (?1,'pending',?2,?3,?4)",
      [incident_id, custodian, route_ordinal, promotion_id]
    )

    Enum.each(routes, fn route ->
      Txn.q(
        txn,
        """
        INSERT INTO harness_health_other_routes
          (incidentId,ordinal,recipient,targetKind,targetRef,relation,state,closedReason,createdAt)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
        """,
        [
          incident_id,
          route.ordinal,
          route.recipient,
          route.target_kind,
          route.target_ref,
          route.relation,
          route.state,
          route.closed_reason,
          input.observed_at
        ]
      )
    end)
  end

  defp ensure_promotion_case_in_txn(txn, description_digest, created_at) do
    case Txn.q(
           txn,
           "SELECT id FROM harness_health_class_promotions WHERE descriptionDigest=?1",
           [description_digest]
         ) do
      [[id]] ->
        id

      [] ->
        [[first_id], [second_id]] =
          Txn.q(
            txn,
            """
            SELECT id FROM harness_health_incidents
            WHERE failureClass='other' AND descriptionDigest=?1
            ORDER BY openedAt,id LIMIT 2
            """,
            [description_digest]
          )

        id = "hhcp_" <> description_digest

        Txn.q(
          txn,
          """
          INSERT INTO harness_health_class_promotions
            (id,descriptionDigest,firstIncidentId,secondIncidentId,createdPrincipal,state,createdAt)
          VALUES (?1,?2,?3,?4,'process:tightbeam','open',?5)
          ON CONFLICT(descriptionDigest) DO NOTHING
          """,
          [id, description_digest, first_id, second_id, created_at]
        )

        id
    end
  end

  defp promotion_case_id(txn, description_digest, recurrence) when recurrence > 1 do
    case Txn.q(
           txn,
           "SELECT id FROM harness_health_class_promotions WHERE descriptionDigest=?1 AND state='open'",
           [description_digest]
         ) do
      [[id]] -> id
      [] -> nil
    end
  end

  defp promotion_case_id(_txn, _description_digest, _recurrence), do: nil

  defp build_other_routes(txn, input) do
    owner =
      case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [
             input.source_session_key
           ]) do
        [[owner]] -> owner
        [] -> nil
      end

    {walked, next_ordinal} =
      walk_other_ancestors(
        txn,
        input.source_session_key,
        owner,
        input.harness,
        input.host,
        0,
        MapSet.new(),
        []
      )

    append_other_owner_fallback(txn, walked, owner, next_ordinal)
  end

  defp append_other_owner_fallback(txn, walked, owner, ordinal) do
    case owner &&
           Txn.q(
             txn,
             "SELECT sessionKey FROM sessions WHERE ownerUserId=?1 AND kind='main' AND state='active' ORDER BY sessionKey LIMIT 1",
             [owner]
           ) do
      [[main]] ->
        if Enum.any?(walked, fn route ->
             route.target_kind == "session" and route.target_ref == main and
               route.state != "skipped"
           end) do
          walked
        else
          walked ++
            [
              %{
                ordinal: ordinal,
                recipient: main,
                target_kind: "session",
                target_ref: main,
                relation: "owner_main",
                state: "pending",
                closed_reason: nil
              }
            ]
        end

      _ when is_binary(owner) ->
        walked ++
          [
            %{
              ordinal: ordinal,
              recipient: "user:" <> owner,
              target_kind: "owner_user",
              target_ref: "user:" <> owner,
              relation: "owner_user",
              state: "pending",
              closed_reason: nil
            }
          ]

      _ ->
        walked ++
          [
            %{
              ordinal: ordinal,
              recipient: "user:unknown",
              target_kind: "owner_user",
              target_ref: "user:unknown",
              relation: "owner_user",
              state: "pending",
              closed_reason: nil
            }
          ]
    end
  end

  defp walk_other_ancestors(_txn, nil, _owner, _harness, _host, ordinal, _seen, routes),
    do: {routes, ordinal}

  defp walk_other_ancestors(_txn, _session, _owner, _harness, _host, ordinal, _seen, routes)
       when ordinal >= 32,
       do:
         {routes ++
            [
              %{
                ordinal: ordinal,
                recipient: "user:unknown",
                target_kind: "owner_user",
                target_ref: "user:unknown",
                relation: "ancestor",
                state: "skipped",
                closed_reason: "hop_limit"
              }
            ], ordinal + 1}

  defp walk_other_ancestors(txn, session, owner, harness, host, ordinal, seen, routes) do
    cond do
      MapSet.member?(seen, session) ->
        {routes ++
           [
             %{
               ordinal: ordinal,
               recipient: session,
               target_kind: "session",
               target_ref: session,
               relation: "ancestor",
               state: "skipped",
               closed_reason: "cycle"
             }
           ], ordinal + 1}

      true ->
        case Txn.q(
               txn,
               """
               SELECT child.spawnedBy,parent.ownerUserId,parent.state,parent.harness,parent.host
               FROM sessions child
               LEFT JOIN sessions parent ON parent.sessionKey=child.spawnedBy
               WHERE child.sessionKey=?1
               """,
               [session]
             ) do
          [[parent, ^owner, state, _parent_harness, _parent_host]] when is_binary(parent) ->
            route =
              if state == "active" and parent != session and not MapSet.member?(seen, parent) do
                %{
                  ordinal: ordinal,
                  recipient: parent,
                  target_kind: "session",
                  target_ref: parent,
                  relation: if(ordinal == 0, do: "parent", else: "ancestor"),
                  state: "pending",
                  closed_reason: nil
                }
              else
                %{
                  ordinal: ordinal,
                  recipient: parent,
                  target_kind: "session",
                  target_ref: parent,
                  relation: if(ordinal == 0, do: "parent", else: "ancestor"),
                  state: "skipped",
                  closed_reason: "inactive"
                }
              end

            walk_other_ancestors(
              txn,
              parent,
              owner,
              harness,
              host,
              ordinal + 1,
              MapSet.put(seen, session),
              routes ++ [route]
            )

          [[_parent, _owner, _state, _parent_harness, _parent_host]] ->
            {routes ++
               [
                 %{
                   ordinal: ordinal,
                   recipient: session,
                   target_kind: "session",
                   target_ref: session,
                   relation: "ancestor",
                   state: "skipped",
                   closed_reason: "foreign_owner"
                 }
               ], ordinal + 1}

          [] ->
            {routes ++
               [
                 %{
                   ordinal: ordinal,
                   recipient: session,
                   target_kind: "session",
                   target_ref: session,
                   relation: "ancestor",
                   state: "skipped",
                   closed_reason: "foreign_owner"
                 }
               ], ordinal + 1}
        end
    end
  end

  defp resolve_other_open(txn, input) do
    {where, params} =
      case Map.get(input, :incident_id) do
        nil ->
          {
            " WHERE harness=?1 AND host=?2 AND failureClass='other' AND state='open' ORDER BY openedAt,id LIMIT 1",
            [input.harness, input.host]
          }

        incident_id ->
          {
            " WHERE id=?1 AND harness=?2 AND host=?3 AND failureClass='other' AND state='open'",
            [incident_id, input.harness, input.host]
          }
      end

    case Txn.q(txn, incident_sql() <> where, params) do
      [] ->
        :already_healthy

      [row] ->
        incident = incident(row)
        opening = observation_by_id(txn, incident.openObservationId)

        if incident.expiresAt && input.observed_at >= incident.expiresAt do
          expire_other_incidents_in_txn(txn, input.harness, input.host, input.observed_at)
          raise ArgumentError, "incident_expired"
        end

        unless input.recovery_condition_digest == opening.recovery_condition_digest,
          do: raise(ArgumentError, "invalid_other_evidence")

        input = Map.put(input, :description_digest, opening.description_digest)
        recovery_observation = Map.put(input, :recovery_condition, nil)

        observation_id =
          insert_observation(txn, recovery_observation, incident.id, "normal-turn-success")

        attach_observation_references(txn, incident.id, observation_id)

        fact_id =
          if active_other_count(txn, input.harness, input.host) == 1 do
            %{fact_id: fact_id} =
              ConditionFacts.file_harness_health_in_txn(
                txn,
                input.harness,
                input.host,
                @other_failure_class,
                :retract
              )

            fact_id
          end

        Txn.q(
          txn,
          "UPDATE harness_health_incidents SET state='resolved',resolvedAt=?2,resolutionObservationId=?3,resolvedFactId=?4 WHERE id=?1 AND state='open'",
          [incident.id, input.observed_at, observation_id, fact_id]
        )

        if Txn.changes(txn) != 1, do: raise("harness other incident resolution race")

        EventLog.lifecycle_in_txn(
          txn,
          "harness_health_incident_resolved",
          incident.id,
          lifecycle_detail(input, observation_id)
        )

        {:resolved,
         Map.merge(incident, %{
           state: "resolved",
           resolvedAt: input.observed_at,
           resolvedFactId: fact_id,
           resolutionObservationId: observation_id
         })}
    end
  end

  defp active_other_count(txn, harness, host) do
    [[count]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM harness_health_incidents WHERE harness=?1 AND host=?2 AND failureClass='other' AND state='open'",
        [harness, host]
      )

    count
  end

  defp expire_other_incidents_in_txn(txn, harness, host, now) do
    rows =
      Txn.q(
        txn,
        incident_sql() <>
          " WHERE harness=?1 AND host=?2 AND failureClass='other' AND state='open' AND expiresAt<=?3 ORDER BY expiresAt,id",
        [harness, host, now]
      )

    Enum.each(rows, fn row ->
      incident = incident(row)

      fact_id =
        if active_other_count(txn, harness, host) == 1 do
          %{fact_id: fact_id} =
            ConditionFacts.file_harness_health_in_txn(
              txn,
              harness,
              host,
              @other_failure_class,
              :retract
            )

          fact_id
        end

      Txn.q(
        txn,
        "UPDATE harness_health_incidents SET state='expired',expiredAt=?2,expiryFactId=?3 WHERE id=?1 AND state='open'",
        [incident.id, now, fact_id]
      )

      EventLog.lifecycle_in_txn(
        txn,
        "harness_health_incident_expired",
        incident.id,
        JSON.encode!(%{incidentId: incident.id, expiredAt: now})
      )
    end)

    :ok
  end

  @doc "The single transaction-owned availability gate for every prod-shaped consumer."
  @spec prod_shape_gate_in_txn(Txn.t(), String.t(), String.t(), integer()) ::
          :available | {:unavailable, map()}
  def prod_shape_gate_in_txn(%Txn{} = txn, harness, host, now) do
    expire_other_incidents_in_txn(txn, harness, host, now)

    rows =
      Txn.q(
        txn,
        "SELECT id,failureClass,expiresAt FROM harness_health_incidents WHERE harness=?1 AND host=?2 AND state='open' ORDER BY openedAt,id",
        [harness, host]
      )

    case rows do
      [] ->
        :available

      incidents ->
        {:unavailable,
         %{
           incidentIds: Enum.map(incidents, &Enum.at(&1, 0)),
           failureClasses: Enum.map(incidents, &Enum.at(&1, 1)),
           earliestExpiryAt:
             incidents
             |> Enum.map(&Enum.at(&1, 2))
             |> Enum.reject(&is_nil/1)
             |> Enum.min(fn -> nil end)
         }}
    end
  end

  @doc "Run the shared prod-shape gate for a consumer whose caller has no transaction."
  @spec prod_shape_gate(DB.server(), String.t(), String.t()) :: :available | {:unavailable, map()}
  def prod_shape_gate(db \\ DB, harness, host) do
    case DB.transaction(db, fn txn ->
           prod_shape_gate_in_txn(txn, harness, host, System.system_time(:millisecond))
         end) do
      {:ok, result} -> result
      {:error, _} -> {:unavailable, %{incidentIds: [], failureClasses: [], earliestExpiryAt: nil}}
    end
  end

  @doc "Gate and deduplicate a prod-shaped action in one transaction."
  @spec prod_shape_act_in_txn(
          Txn.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          (-> term())
        ) :: term()
  def prod_shape_act_in_txn(%Txn{} = txn, consumer_kind, candidate_id, harness, host, callback)
      when is_function(callback, 0) do
    unless consumer_kind in @prod_shape_consumers do
      raise ArgumentError, "unreviewed_prod_shape_consumer"
    end

    case prod_shape_gate_in_txn(txn, harness, host, System.system_time(:millisecond)) do
      :available ->
        callback.()

      {:unavailable, gate} ->
        Txn.q(
          txn,
          "INSERT OR IGNORE INTO harness_health_prod_suppressions (consumerKind,candidateId,harness,host,incidentIds,createdAt) VALUES (?1,?2,?3,?4,?5,?6)",
          [
            consumer_kind,
            candidate_id,
            harness,
            host,
            JSON.encode!(gate.incidentIds),
            System.system_time(:millisecond)
          ]
        )

        {:suppressed, gate}
    end
  end

  defp normalize_common!(input) do
    input =
      input
      |> Map.put_new(:session_key, nil)
      |> Map.put_new(:assignment_id, nil)

    unless input.failure_class in @failure_classes do
      raise ArgumentError, "unknown harness failure class: #{inspect(input.failure_class)}"
    end

    input
  end

  defp validate_session_membership!(_txn, %{session_key: nil}), do: :ok

  defp validate_session_membership!(txn, input) do
    case Txn.q(
           txn,
           "SELECT 1 FROM sessions WHERE sessionKey=?1 AND harness=?2 AND host=?3",
           [input.session_key, input.harness, input.host]
         ) do
      [[1]] ->
        :ok

      [] ->
        raise ArgumentError, "harness health evidence session must use the affected harness"
    end
  end

  defp lifecycle_detail(input, observation_id) do
    base = %{
      observationId: observation_id,
      harness: input.harness,
      host: input.host,
      failureClass: input.failure_class,
      evidenceKind: input.evidence_kind,
      correlationId: input.correlation_id,
      principal: input.principal
    }

    if input.failure_class == @other_failure_class do
      JSON.encode!(Map.put(base, :causeClass, "evidence"))
    else
      JSON.encode!(Map.put(base, :cause, input.cause))
    end
  end

  defp incident_recipient(txn, %{failure_class: "auth-dead"} = input),
    do: auth_blocker_recipient(txn, input)

  defp incident_recipient(_txn, _input), do: {:ok, :automatic}

  defp incident_notice_in_txn(
         _txn,
         _incident_id,
         %{failure_class: "rate-limit-dead"},
         _recipient
       ),
       do: nil

  defp incident_notice_in_txn(txn, incident_id, %{failure_class: "auth-dead"} = input, recipient)
       when is_binary(recipient) do
    [[assignment_count]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM harness_health_assignments WHERE incidentId=?1",
        [incident_id]
      )

    message =
      "[shared harness authentication unavailable]\n\n" <>
        "The #{input.harness} harness on #{input.host} rejected its credential. " <>
        "Incident #{incident_id} records #{assignment_count} affected open assignment(s). " <>
        "A human must restore this credential. Ordinary agent retries and alerts for this " <>
        "harness are suppressed until a normal turn succeeds."

    EventLog.notice_in_txn(
      txn,
      "harness_health_auth_blocker",
      incident_id,
      lifecycle_detail(input, input.correlation_id),
      audience: {:session, recipient},
      message: message,
      attention: :high
    )
  end

  defp incident_notice_in_txn(txn, incident_id, %{failure_class: "other"} = input, :automatic) do
    [[target_kind, target_ref, route_ordinal]] =
      Txn.q(
        txn,
        "SELECT targetKind,targetRef,ordinal FROM harness_health_other_routes WHERE incidentId=?1 AND ((state='pending') OR (state='alerted' AND settledAt IS NULL)) AND noticeWakeId IS NULL AND turnSeq IS NULL ORDER BY ordinal LIMIT 1",
        [incident_id]
      )

    message =
      "[shared harness incident: other]\n\n" <>
        "The #{input.harness} harness on #{input.host} opened incident #{incident_id}. " <>
        "Evidence has been retained; review is required and prodding is paused until the " <>
        "review or its bounded expiry."

    if target_kind == "owner_user" do
      EventLog.notice_in_txn(
        txn,
        "harness_health_other_review",
        incident_id,
        lifecycle_detail(input, input.correlation_id),
        audience: :record_only,
        message: message,
        attention: :high
      )

      owner_user = String.replace_prefix(target_ref, "user:", "")

      case Txn.q(
             txn,
             "SELECT kind FROM condition_facts WHERE scope=?1 AND kind IN ('user-alerted','user-alert-cleared') ORDER BY id DESC LIMIT 1",
             [owner_user]
           ) do
        [["user-alerted"]] ->
          :already_standing

        _ ->
          ConditionFacts.file_in_txn(txn, %{
            kind: "user-alerted",
            scope: owner_user,
            origin: "process:tightbeam",
            owner_user_id: owner_user
          })
      end

      Txn.q(
        txn,
        "UPDATE harness_health_other_routes SET state='alerted',closedReason='no_active_main',noticeWakeId=NULL,turnSeq=NULL,settledAt=?3 WHERE incidentId=?1 AND ordinal=?2 AND state='pending' AND settledAt IS NULL",
        [incident_id, route_ordinal, input.observed_at]
      )

      %{
        kind: :other_route,
        plan: [],
        tokenless: true,
        incident_id: incident_id,
        ordinal: route_ordinal,
        settled_at: input.observed_at
      }
    else
      EventLog.lifecycle_in_txn(
        txn,
        "harness_health_other_review",
        incident_id,
        lifecycle_detail(input, input.correlation_id)
      )

      {:appended, marker} =
        Projection.append_substrate_in_txn(txn, target_ref, message, :high)

      wake_id = "other-review:#{incident_id}:#{target_ref}"

      {:ok, turn_seq} =
        Ledger.enqueue_in_txn(txn, %{
          session_key: target_ref,
          message_id: marker.id,
          wake_id: wake_id,
          request_ref: "other-review:#{incident_id}",
          origin: "process:tightbeam",
          prompt: message
        })

      [[owner]] =
        Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [target_ref])

      Txn.q(
        txn,
        "UPDATE harness_health_other_routes SET state='pending',noticeWakeId=?3,turnSeq=?4,settledAt=NULL WHERE incidentId=?1 AND ordinal=?2 AND state='pending' AND noticeWakeId IS NULL AND turnSeq IS NULL",
        [incident_id, route_ordinal, wake_id, turn_seq]
      )

      %{
        kind: :other_route,
        plan: [{target_ref, owner, marker.seq, Payloads.server_message(marker)}],
        tokenless: false,
        incident_id: incident_id,
        ordinal: route_ordinal,
        settled_at: input.observed_at
      }
    end
  end

  defp incident_notice_in_txn(txn, incident_id, input, :automatic) do
    audience =
      case Txn.q(
             txn,
             """
             SELECT DISTINCT s.ownerUserId
             FROM harness_health_members m
             JOIN sessions s ON s.sessionKey=m.sessionKey
             WHERE m.incidentId=?1
             ORDER BY s.ownerUserId
             LIMIT 1
             """,
             [incident_id]
           ) do
        [[owner_user_id]] -> {:session, Org.personal_session_key(owner_user_id)}
        [] -> :record_only
      end

    [[assignment_count]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM harness_health_assignments WHERE incidentId=?1",
        [incident_id]
      )

    guidance = repair_guidance(input.failure_class)

    message =
      "[shared harness incident: #{input.failure_class}]\n\n" <>
        "The #{input.harness} harness on #{input.host} opened incident #{incident_id}, " <>
        "covering #{assignment_count} affected open assignment(s). " <>
        guidance.message <> " Prodding for this harness is suppressed until repair succeeds."

    EventLog.notice_in_txn(
      txn,
      if(input.failure_class == "auth-dead",
        do: "harness_health_auth_blocker",
        else: "harness_health_repair_required"
      ),
      incident_id,
      lifecycle_detail(input, input.correlation_id),
      audience: audience,
      message: message,
      attention: :high
    )
  end

  defp auth_blocker_recipient(txn, input) do
    affected_main =
      Txn.q(
        txn,
        """
        SELECT DISTINCT main.sessionKey
        FROM sessions affected
        JOIN sessions main ON main.ownerUserId=affected.ownerUserId
        WHERE affected.harness=?1 AND affected.host=?2 AND affected.state='active'
          AND main.kind='main' AND main.state='active'
        ORDER BY affected.ownerUserId, main.sessionKey
        LIMIT 1
        """,
        [input.harness, input.host]
      )

    case affected_main do
      [[session_key]] ->
        {:ok, session_key}

      [] ->
        case Txn.q(
               txn,
               """
               SELECT sessionKey FROM sessions
               WHERE kind='main' AND state='active'
               ORDER BY ownerUserId, sessionKey
               LIMIT 1
               """
             ) do
          [[session_key]] -> {:ok, session_key}
          [] -> :no_recipient
        end
    end
  end

  defp with_repair_guidance(incident),
    do: Map.put(incident, :repair, repair_guidance(incident.failureClass))

  defp repair_guidance("model_unavailable"),
    do: %{
      action: "tune",
      requires: ["model"],
      message:
        "An opener or admin must tune the holder to an explicitly named available catalog model."
    }

  defp repair_guidance("adapter_unavailable"),
    do: %{
      action: "restart",
      requires: [],
      message: "An opener or admin must restart the holder's shared harness adapter."
    }

  defp repair_guidance("task_crash"),
    do: %{
      action: "restart",
      requires: [],
      message:
        "An opener or admin must restart the shared adapter before retrying the failed turn."
    }

  defp repair_guidance("interrupted-outcome-unknown"),
    do: %{
      action: "rerun",
      requires: ["outcome=not-completed"],
      message:
        "An opener or admin must reconcile the external outcome, then explicitly rerun the terminal turn only when it did not complete."
    }

  defp repair_guidance("rate-limit-dead"),
    do: %{
      action: "resume",
      requires: [],
      message:
        "The harness remains parked until an opener or admin explicitly resumes it after the limit clears."
    }

  defp repair_guidance("auth-dead"),
    do: %{
      action: "resume",
      requires: [],
      message:
        "A human must restore this credential. Then an opener or admin explicitly resumes the holder."
    }

  defp repair_guidance("other"),
    do: %{
      action: "review",
      requires: ["living-authority", "bounded-expiry"],
      message:
        "A living authority must review this evidence; the incident pauses prodding until review or its bounded expiry."
    }

  defp required_string!(input, key) do
    case Map.get(input, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: raise(ArgumentError, "invalid_other_evidence"), else: value

      _ ->
        raise ArgumentError, "invalid_other_evidence"
    end
  end

  defp required_bounded_string!(input, key, max) do
    value = required_string!(input, key)

    if String.length(value) > max, do: raise(ArgumentError, "invalid_other_evidence")
    value
  end

  defp bounded_string(nil, _max), do: nil

  defp bounded_string(value, max) when is_binary(value) do
    value = String.trim(value)

    if value == "",
      do: nil,
      else:
        if(String.length(value) <= max,
          do: value,
          else: raise(ArgumentError, "invalid_other_evidence")
        )
  end

  defp bounded_string(_value, _max), do: raise(ArgumentError, "invalid_other_evidence")

  defp integer_or_default(nil, default), do: default
  defp integer_or_default(value, _default) when is_integer(value), do: value
  defp integer_or_default(_value, _default), do: raise(ArgumentError, "invalid_other_evidence")

  defp bool_int(true), do: 1
  defp bool_int(1), do: 1
  defp bool_int(false), do: 0
  defp bool_int(0), do: 0
  defp bool_int(nil), do: nil
  defp bool_int(_), do: 0

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp sha256_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_promoted_class?(value) when is_binary(value) do
    value != @other_failure_class and value not in @failure_classes and
      byte_size(value) <= 64 and Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, value)
  end

  defp valid_promoted_class?(_value), do: false

  defp commit_ref_matches?(encoded, candidate) when is_binary(encoded) and is_binary(candidate) do
    with true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, candidate),
         {:ok, refs} when is_list(refs) <- JSON.decode(encoded) do
      Enum.any?(refs, fn ref -> is_map(ref) and ref["commit"] == candidate end)
    else
      _ -> false
    end
  end

  defp commit_ref_matches?(_encoded, _candidate), do: false

  defp credential_shaped?(text) do
    Regex.match?(~r/-----BEGIN [^-]*PRIVATE KEY-----/, text) or
      Regex.match?(~r/(authorization|api[-_]key|token|password|secret)\s*[:=]\s*\S+/i, text) or
      Regex.match?(~r/\b(sk_|ghp_|github_pat_|tbc_|tbs_|tbt_|tbp_)[A-Za-z0-9_-]{8,}/, text)
  end

  defp principal_text({kind, value}), do: "#{kind}:#{value}"
  defp principal_text(value) when is_binary(value), do: value
  defp principal_text(value), do: inspect(value)

  defp normalize_principal!({kind, value}) when kind in [:session, :user] and is_binary(value),
    do: {kind, value}

  defp normalize_principal!("session:" <> value) when value != "", do: {:session, value}
  defp normalize_principal!("user:" <> value) when value != "", do: {:user, value}
  defp normalize_principal!("process:tightbeam"), do: "process:tightbeam"
  defp normalize_principal!(_), do: raise(ArgumentError, "not_authorized")

  defp principal_ref(principal), do: principal_text(principal)

  defp other_correlation(principal, mutation, idempotency_key, phase) do
    canonical = principal_text(principal)
    digest = sha256(canonical <> <<0>> <> mutation <> <<0>> <> idempotency_key)
    "other-#{phase}:" <> digest
  end

  defp now(input), do: Map.get(input, :observed_at, System.system_time(:millisecond))

  defp other_fingerprint(input) do
    input
    |> Map.take([
      :harness,
      :host,
      :source_session_key,
      :description,
      :observed_state,
      :evidence_mode,
      :exact_observed_error,
      :exact_probe,
      :output_digest,
      :recovery_condition,
      :not_known_class_reason,
      :observed_at,
      :valid_until,
      :world_status
    ])
    |> JSON.encode!()
    |> sha256()
  end

  defp review_fingerprint(input) do
    input
    |> Map.take([:incident_id, :outcome, :named_class, :cause])
    |> Map.put(:principal, principal_text(Map.get(input, :principal, "process:tightbeam")))
    |> JSON.encode!()
    |> sha256()
  end

  defp other_recovery_fingerprint(input) do
    input
    |> Map.take([
      :incident_id,
      :harness,
      :host,
      :session_key,
      :observed_at,
      :cause,
      :observed_state,
      :exact_probe,
      :output_digest,
      :recovery_condition_digest,
      :recovery_satisfied,
      :world_status,
      :redaction_confirmed
    ])
    |> JSON.encode!()
    |> sha256()
  end

  defp other_idempotency(txn, principal_ref, idempotency_key, operation) do
    case Txn.q(
           txn,
           "SELECT requestFingerprint,response FROM harness_health_other_idempotency WHERE principalRef=?1 AND operation=?2 AND idempotencyKey=?3",
           [principal_ref, operation, idempotency_key]
         ) do
      [[fingerprint, response]] -> %{request_fingerprint: fingerprint, response: response}
      [] -> nil
    end
  end

  defp store_other_idempotency(
         txn,
         principal_ref,
         idempotency_key,
         fingerprint,
         {status, detail},
         operation
       ) do
    Txn.q(
      txn,
      "INSERT INTO harness_health_other_idempotency (principalRef,operation,idempotencyKey,requestFingerprint,response) VALUES (?1,?2,?3,?4,?5)",
      [
        principal_ref,
        operation,
        idempotency_key,
        fingerprint,
        JSON.encode!(%{status: status, detail: strip_publication(detail)})
      ]
    )
  end

  defp decode_other_idempotency(response) do
    decoded = JSON.decode!(response)

    unless decoded["status"] in ~w(opened attached duplicate resolved reviewed promotion_closed) do
      raise ArgumentError, "invalid idempotency response #{inspect(decoded["status"])}"
    end

    {:duplicate, decoded["detail"]}
  end

  defp other_error_code(%ArgumentError{message: message}) do
    if message in ~w(missing_other_evidence invalid_other_evidence stale_other_evidence stale_recovery_evidence invalid_recovery_evidence incident_expired secret_redaction_unconfirmed credential_shaped_evidence source_not_found source_not_active not_authorized evidence_not_found idempotency_conflict review_not_pending invalid_review_outcome promotion_required invalid_promotion_close promotion_closed promotion_not_found),
      do: message,
      else: "invalid_other_evidence"
  end

  @doc false
  @spec settle_other_route_in_txn(Txn.t(), integer(), String.t(), integer()) :: map() | nil
  def settle_other_route_in_txn(%Txn{} = txn, turn_seq, terminal_state, settled_at)
      when is_integer(turn_seq) do
    reason =
      case terminal_state do
        "delivered" -> nil
        :delivered -> nil
        "canceled" -> "canceled"
        :canceled -> "canceled"
        "target_retired" -> "target_retired"
        :target_retired -> "target_retired"
        "failed" -> "failed"
        :failed -> "failed"
        _ -> "failed_unknown"
      end

    current =
      case Txn.q(
             txn,
             """
             SELECT r.incidentId,r.ordinal
             FROM harness_health_other_routes r
             LEFT JOIN turns t ON t.wakeId=r.noticeWakeId
             WHERE (r.turnSeq=?1 OR t.seq=?1) AND r.state IN ('pending','alerted')
             ORDER BY r.ordinal LIMIT 1
             """,
             [turn_seq]
           ) do
        [[incident_id, ordinal]] -> {incident_id, ordinal}
        [] -> nil
      end

    case current do
      nil ->
        nil

      {incident_id, ordinal} ->
        if reason do
          Txn.q(
            txn,
            "UPDATE harness_health_other_routes SET state='non_delivered',closedReason=?3,resolvedAt=?4,settledAt=?4 WHERE incidentId=?1 AND ordinal=?2 AND state IN ('pending','alerted')",
            [incident_id, ordinal, reason, settled_at]
          )
        else
          Txn.q(
            txn,
            "UPDATE harness_health_other_routes SET state='delivered',closedReason=NULL,resolvedAt=?3,settledAt=?3 WHERE incidentId=?1 AND ordinal=?2 AND state IN ('pending','alerted')",
            [incident_id, ordinal, settled_at]
          )
        end

        if Txn.changes(txn) != 1 do
          nil
        else
          Txn.q(
            txn,
            "UPDATE harness_health_other_reviews SET custodian=(SELECT recipient FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=?2),routeOrdinal=?2 WHERE incidentId=?1 AND state='pending'",
            [incident_id, ordinal]
          )

          if reason do
            advance_other_route_in_txn(txn, incident_id, settled_at)
          else
            nil
          end
        end
    end
  end

  defp settle_other_route_notice_in_txn(txn, incident_id, ordinal, publication, settled_at) do
    case publication do
      [] ->
        Txn.q(
          txn,
          "UPDATE harness_health_other_routes SET state='non_delivered',closedReason='target_retired',resolvedAt=?3,settledAt=?3 WHERE incidentId=?1 AND ordinal=?2 AND state IN ('pending','alerted')",
          [incident_id, ordinal, settled_at]
        )

      _ ->
        :ok
    end

    if Txn.changes(txn) == 1 do
      advance_other_route_in_txn(txn, incident_id, settled_at)
    else
      nil
    end
  end

  defp advance_other_route_in_txn(txn, incident_id, settled_at) when is_binary(incident_id) do
    next =
      case Txn.q(
             txn,
             "SELECT ordinal FROM harness_health_other_routes WHERE incidentId=?1 AND state IN ('pending','alerted') AND noticeWakeId IS NULL AND turnSeq IS NULL AND settledAt IS NULL ORDER BY ordinal LIMIT 1",
             [incident_id]
           ) do
        [[ordinal]] -> ordinal
        [] -> nil
      end

    Txn.q(
      txn,
      """
      UPDATE harness_health_other_reviews
      SET routeOrdinal=COALESCE(?2,
        (SELECT COALESCE(MAX(ordinal)+1,0) FROM harness_health_other_routes WHERE incidentId=?1))
      WHERE incidentId=?1 AND state='pending'
        AND routeOrdinal < COALESCE(?2,
          (SELECT COALESCE(MAX(ordinal)+1,0) FROM harness_health_other_routes WHERE incidentId=?1))
      """,
      [incident_id, next]
    )

    case next do
      nil -> nil
      _ordinal -> publish_next_other_route_in_txn(txn, incident_id, settled_at)
    end
  end

  defp publish_next_other_route_in_txn(txn, incident_id, settled_at) do
    input =
      case Txn.q(
             txn,
             """
             SELECT i.harness,i.host,i.failureClass,o.evidenceKind,o.correlationId,o.principal
             FROM harness_health_incidents i
             JOIN harness_health_observations o ON o.id=i.openObservationId
             WHERE i.id=?1
             """,
             [incident_id]
           ) do
        [[harness, host, failure_class, evidence_kind, correlation_id, principal]] ->
          %{
            harness: harness,
            host: host,
            failure_class: failure_class,
            evidence_kind: evidence_kind,
            correlation_id: correlation_id,
            principal: principal,
            observed_at: settled_at
          }

        [] ->
          nil
      end

    if input do
      case incident_notice_in_txn(txn, incident_id, input, :automatic) do
        %{kind: :other_route, plan: [], tokenless: true} = publication ->
          publication

        %{kind: :other_route, plan: []} = publication ->
          settle_other_route_notice_in_txn(
            txn,
            publication.incident_id,
            publication.ordinal,
            publication.plan,
            publication.settled_at
          )

        %{kind: :other_route} = publication ->
          publication

        _ ->
          nil
      end
    end
  end

  @doc false
  @spec resume_other_routes(DB.server()) :: :ok
  def resume_other_routes(db \\ DB) do
    publications =
      transaction!(db, fn txn ->
        marked =
          Txn.q(
            txn,
            "SELECT r.incidentId,r.ordinal,r.turnSeq,t.status FROM harness_health_other_routes r LEFT JOIN turns t ON t.seq=r.turnSeq WHERE r.state='pending' AND r.turnSeq IS NOT NULL ORDER BY r.incidentId,r.ordinal",
            []
          )
          |> Enum.flat_map(fn [incident_id, ordinal, turn_seq, status] ->
            case reconcile_marked_other_route_in_txn(
                   txn,
                   incident_id,
                   ordinal,
                   turn_seq,
                   status,
                   System.system_time(:millisecond)
                 ) do
              %{kind: :other_route} = publication -> [publication]
              _ -> []
            end
          end)

        fresh =
          Txn.q(
            txn,
            "SELECT DISTINCT incidentId FROM harness_health_other_routes WHERE state='pending' AND noticeWakeId IS NULL AND turnSeq IS NULL AND settledAt IS NULL ORDER BY incidentId",
            []
          )
          |> Enum.flat_map(fn [incident_id] ->
            case publish_next_other_route_in_txn(
                   txn,
                   incident_id,
                   System.system_time(:millisecond)
                 ) do
              %{kind: :other_route} = publication -> [publication]
              _ -> []
            end
          end)

        marked ++ fresh
      end)

    Enum.each(publications, fn publication ->
      EventLog.publish(publication.plan)
    end)

    :ok
  end

  defp reconcile_marked_other_route_in_txn(
         txn,
         _incident_id,
         _ordinal,
         turn_seq,
         status,
         settled_at
       )
       when status in ~w(delivered canceled failed failed_unknown) do
    settle_other_route_in_txn(txn, turn_seq, status, settled_at)
  end

  defp reconcile_marked_other_route_in_txn(
         _txn,
         _incident_id,
         _ordinal,
         _turn_seq,
         _status,
         _settled_at
       ),
       do: nil

  defp post_commit(result, registry \\ Tightbeam.ConnRegistry, db \\ DB)

  defp post_commit({_status, %{notice_publication: nil}}, _registry, _db), do: nil

  defp post_commit(
         {_status, %{notice_publication: %{kind: :other_route} = publication}},
         registry,
         db
       ) do
    fn ->
      EventLog.publish(publication.plan, conn_registry: registry)

      # A non-empty publication is only an enqueue into the connection
      # registry. Keep the route pending until the delivery/terminal callback
      # settles it; treating publication as delivery loses the retry rung.
      if publication.plan == [] and not Map.get(publication, :tokenless, false) do
        case DB.transaction(db, fn txn ->
               settle_other_route_notice_in_txn(
                 txn,
                 publication.incident_id,
                 publication.ordinal,
                 publication.plan,
                 publication.settled_at
               )
             end) do
          {:ok, %{kind: :other_route, plan: next_plan}} when is_list(next_plan) ->
            EventLog.publish(next_plan, conn_registry: registry)

          _ ->
            :ok
        end
      end

      :ok
    end
  end

  defp post_commit({_status, %{notice_publication: publication}}, registry, _db) do
    fn -> EventLog.publish(publication, conn_registry: registry) end
  end

  defp post_commit(_result, _registry, _db), do: nil

  defp strip_publication({status, detail}),
    do: {status, Map.delete(detail, :notice_publication)}

  defp strip_publication(detail) when is_map(detail),
    do: Map.delete(detail, :notice_publication)

  defp contains_any?(text, patterns), do: Enum.any?(patterns, &String.contains?(text, &1))

  defp evidence_text(evidence) when is_binary(evidence), do: evidence

  defp evidence_text(evidence) do
    try do
      JSON.encode!(evidence)
    rescue
      _ -> inspect(evidence, limit: 50, printable_limit: 4_000)
    end
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
