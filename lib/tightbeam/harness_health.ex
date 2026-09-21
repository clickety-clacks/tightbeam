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

  alias Tightbeam.{ConditionFacts, DB, EventLog, Harness, HarnessProcess, Id, Org}
  alias Tightbeam.DB.Txn

  @failure_classes ~w(
    auth-dead rate-limit-dead adapter_unavailable model_unavailable task_crash
    interrupted-outcome-unknown
  )
  @other_failure_class "other"
  @failure_evidence ~w(authoritative-provider terminal-failure)
  @evidence_window_ms 120_000
  @other_max_validity_ms 900_000

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
    reviewer TEXT,
    cause TEXT,
    closedAt INTEGER
  );

  CREATE TABLE IF NOT EXISTS harness_health_other_routes (
    incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
    recipient TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','admitted','resolved','skipped')),
    createdAt INTEGER NOT NULL,
    resolvedAt INTEGER,
    PRIMARY KEY (incidentId, ordinal)
  );

  CREATE TABLE IF NOT EXISTS harness_health_class_promotions (
    id TEXT PRIMARY KEY,
    descriptionDigest TEXT NOT NULL,
    namedClass TEXT NOT NULL,
    specRef TEXT NOT NULL,
    specSha256 TEXT NOT NULL,
    reviewArtifactId TEXT NOT NULL,
    reviewedClean INTEGER NOT NULL CHECK(reviewedClean IN (0,1)),
    state TEXT NOT NULL CHECK(state IN ('open','closed')),
    createdAt INTEGER NOT NULL,
    closedAt INTEGER
  );

  CREATE TABLE IF NOT EXISTS harness_health_other_review_events (
    id TEXT PRIMARY KEY,
    incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    eventKind TEXT NOT NULL,
    actor TEXT NOT NULL,
    payload TEXT NOT NULL,
    createdAt INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS harness_health_prod_suppressions (
    consumerKind TEXT NOT NULL,
    candidateId TEXT NOT NULL,
    harness TEXT NOT NULL,
    host TEXT NOT NULL,
    incidentIds TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    PRIMARY KEY (consumerKind, candidateId, harness, host)
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
  BEFORE UPDATE OF id,harness,host,failureClass,openedAt,openObservationId,openedFactId
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
     NEW.resolutionObservationId IS NOT NULL AND NEW.resolvedFactId IS NOT NULL AND
     EXISTS (
       SELECT 1 FROM harness_health_observations
       WHERE id = NEW.resolutionObservationId AND incidentId = OLD.id AND
             harness = OLD.harness AND host = OLD.host AND
             failureClass = OLD.failureClass AND evidenceKind = 'normal-turn-success'
     ))
    OR
    (OLD.state = 'open' AND NEW.state = 'expired' AND NEW.expiredAt IS NOT NULL AND
     NEW.expiryFactId IS NOT NULL)
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
    case maybe_upgrade_legacy_schema(db) do
      :ok ->
        case DB.execute(db, @ddl) do
          :ok ->
            case DB.transaction(db, &upgrade_other_schema_in_txn/1) do
              {:ok, :ok} -> :ok
              {:ok, result} -> result
              {:error, error} -> {:error, error}
            end

          error ->
            error
        end

      error ->
        error
    end
  end

  defp maybe_upgrade_legacy_schema(db) do
    if legacy_schema?(db) do
      case DB.transaction(db, &upgrade_other_schema_in_txn/1) do
        {:ok, :ok} -> :ok
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp legacy_schema?(db) do
    with {:ok, observations} <- DB.query(db, "PRAGMA table_info(harness_health_observations)"),
         {:ok, incidents} <- DB.query(db, "PRAGMA table_info(harness_health_incidents)"),
         true <- observations != [] and incidents != [] do
      observation_names = MapSet.new(observations, &Enum.at(&1, 1))
      incident_names = MapSet.new(incidents, &Enum.at(&1, 1))

      not MapSet.member?(observation_names, "descriptionDigest") or
        not MapSet.member?(incident_names, "descriptionDigest")
    else
      _ -> false
    end
  end

  defp upgrade_other_schema_in_txn(txn) do
    observation_columns = Txn.q(txn, "PRAGMA table_info(harness_health_observations)")
    incident_columns = Txn.q(txn, "PRAGMA table_info(harness_health_incidents)")

    add_missing_columns(txn, "harness_health_observations", observation_columns, [
      {"description", "TEXT"},
      {"descriptionDigest", "TEXT"},
      {"observedState", "TEXT"},
      {"evidenceMode", "TEXT"},
      {"exactObservedError", "TEXT"},
      {"exactProbe", "TEXT"},
      {"outputDigest", "TEXT"},
      {"recoveryCondition", "TEXT"},
      {"recoveryConditionDigest", "TEXT"},
      {"recoverySatisfied", "INTEGER"},
      {"notKnownClassReason", "TEXT"},
      {"validUntil", "INTEGER"},
      {"worldStatus", "TEXT"},
      {"redactionConfirmed", "INTEGER"}
    ])

    add_missing_columns(txn, "harness_health_incidents", incident_columns, [
      {"descriptionDigest", "TEXT"},
      {"expiresAt", "INTEGER"},
      {"expiredAt", "INTEGER"},
      {"expiryFactId", "INTEGER"}
    ])

    Txn.exec(
      txn,
      "CREATE INDEX IF NOT EXISTS harness_health_other_expiry ON harness_health_incidents (harness, host, failureClass, expiresAt, state)"
    )

    :ok
  end

  defp add_missing_columns(txn, table, existing, columns) do
    names = MapSet.new(existing, &Enum.at(&1, 1))

    for {name, definition} <- columns, not MapSet.member?(names, name) do
      Txn.exec(txn, "ALTER TABLE #{table} ADD COLUMN #{name} #{definition}")
    end
  end

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

      if failure_class == @other_failure_class do
        resolve_other_normal_turn_in_txn(txn, input, turn.seq)
      else
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

      case post_commit(result, Map.get(input, :conn_registry, Tightbeam.ConnRegistry)) do
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

    case other_idempotency(txn, principal_ref, input.idempotency_key) do
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
          strip_publication(result)
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

    case observation_by_correlation(txn, input.correlation_id) do
      nil -> resolve_other_open(txn, input)
      prior -> duplicate_or_refuse!(txn, prior, input, "normal-turn-success")
    end
  end

  @doc "Close the mandatory review for an other incident."
  @spec review_other(DB.server(), map()) :: {:ok, map()} | {:error, map()}
  def review_other(db \\ DB, input) do
    try do
      transaction!(db, &review_other_in_txn(&1, input))
      |> then(&{:ok, &1})
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

    if outcome == "reclassified" and Map.get(input, :named_class) not in @failure_classes,
      do: raise(ArgumentError, "invalid_review_outcome")

    cause = required_review_cause!(input)

    Txn.q(
      txn,
      """
      UPDATE harness_health_other_reviews
      SET state='closed', outcome=?2, namedClass=?3, reviewer=?4, cause=?5, closedAt=?6
      WHERE incidentId=?1 AND state='pending'
      """,
      [
        incident_id,
        outcome,
        Map.get(input, :named_class),
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

    %{incidentId: incident_id, state: "closed", outcome: outcome}
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
        session == custodian or session == source or same_owner_active?(txn, session, owner)

      {[[_, _, owner]], {:user, user}} ->
        user == owner or admin_user?(txn, user)

      {[[_, _, owner]], "user:" <> user} ->
        user == owner or admin_user?(txn, user)

      _ ->
        false
    end
  end

  @doc "List currently open incidents, oldest first."
  @spec active(DB.server()) :: [map()]
  def active(db \\ DB) do
    {:ok, rows} =
      DB.query(db, incident_sql() <> " WHERE state='open' ORDER BY openedAt,id")

    Enum.map(rows, &(incident(&1) |> with_repair_guidance()))
  end

  @doc "Read one incident with the evidence that names its affected work."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ DB, incident_id) do
    with {:ok, [row]} <- DB.query(db, incident_sql() <> " WHERE id=?1", [incident_id]) do
      incident = row |> incident() |> with_repair_guidance()

      {:ok, observations} =
        DB.query(
          db,
          observation_sql() <> " WHERE incidentId=?1 ORDER BY observedAt,id",
          [incident_id]
        )

      observations = Enum.map(observations, &observation/1)

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
        cause: input.cause,
        principal: input.principal,
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
    observed_at =
      integer_or_default(Map.get(input, :observed_at), System.system_time(:millisecond))

    exact_probe = required_bounded_string!(input, :exact_probe, 4_000)
    observed_state = required_bounded_string!(input, :observed_state, 2_000)
    recovery_condition = required_bounded_string!(input, :recovery_condition, 2_000)
    output_digest = bounded_string(Map.get(input, :output_digest), 64)

    unless sha256_digest?(output_digest) and Map.get(input, :recovery_satisfied) in [true, 1],
      do: raise(ArgumentError, "invalid_other_evidence")

    unless Map.get(input, :world_status) == "PROVEN" and
             bool_int(Map.get(input, :redaction_confirmed)) == 1,
           do: raise(ArgumentError, "invalid_other_evidence")

    %{
      correlation_id:
        other_correlation(
          Map.get(input, :principal, "process:tightbeam"),
          "harness-health-resolve-other",
          Map.get(input, :idempotency_key) || Map.get(input, :correlation_id) || Id.uuid4(),
          "resolve"
        ),
      harness: required_bounded_string!(input, :harness, 512),
      host: required_bounded_string!(input, :host, 512),
      failure_class: @other_failure_class,
      evidence_kind: "normal-turn-success",
      session_key: Map.get(input, :session_key),
      incident_id: Map.get(input, :incident_id),
      assignment_id: nil,
      observed_at: observed_at,
      cause: required_bounded_string!(input, :cause, 2_000),
      principal: principal_text(Map.get(input, :principal, "process:tightbeam")),
      observed_state: observed_state,
      evidence_mode: "probe_digest",
      exact_observed_error: nil,
      exact_probe: exact_probe,
      output_digest: output_digest,
      recovery_condition: recovery_condition,
      recovery_condition_digest: sha256(recovery_condition),
      recovery_satisfied: 1,
      valid_until: nil,
      world_status: "PROVEN",
      redaction_confirmed: true
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
    do: session_key == source or same_owner_active?(txn, session_key, owner)

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

  defp same_owner_active?(txn, session_key, owner) do
    Txn.q(
      txn,
      "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
      [session_key, owner]
    ) == [[1]]
  end

  defp admin_user?(txn, user),
    do: Txn.q(txn, "SELECT 1 FROM users WHERE userId=?1 AND isAdmin=1", [user]) == [[1]]

  defp create_other_review_in_txn(txn, incident_id, input, _recipient) do
    custodian = other_custodian(txn, input)

    Txn.q(
      txn,
      "INSERT INTO harness_health_other_reviews (incidentId,state,custodian,routeOrdinal) VALUES (?1,'pending',?2,0)",
      [incident_id, custodian]
    )

    Txn.q(
      txn,
      "INSERT INTO harness_health_other_routes (incidentId,ordinal,recipient,state,createdAt) VALUES (?1,0,?2,'pending',?3)",
      [incident_id, custodian, input.observed_at]
    )

    [[recurrence]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM harness_health_incidents WHERE harness=?1 AND host=?2 AND failureClass='other' AND descriptionDigest=?3",
        [input.harness, input.host, input.description_digest]
      )

    if recurrence > 1 do
      Txn.q(
        txn,
        "INSERT INTO harness_health_class_promotions (id,descriptionDigest,namedClass,specRef,specSha256,reviewArtifactId,reviewedClean,state,createdAt) VALUES (?1,?2,'pending','harness-health-other-v1', '', '',0,'open',?3)",
        ["hhcp_" <> Id.uuid4(), input.description_digest, input.observed_at]
      )
    end
  end

  defp other_custodian(txn, input) do
    case Txn.q(
           txn,
           "SELECT main.sessionKey FROM sessions affected JOIN sessions main ON main.ownerUserId=affected.ownerUserId WHERE affected.sessionKey=?1 AND main.kind='main' AND main.state='active' ORDER BY main.sessionKey LIMIT 1",
           [input.source_session_key]
         ) do
      [[session_key]] ->
        session_key

      [] ->
        case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [
               input.source_session_key
             ]) do
          [[owner]] -> "user:" <> owner
          [] -> "user:" <> input.principal
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

  defp resolve_other_normal_turn_in_txn(txn, input, seq) do
    case Txn.q(
           txn,
           incident_sql() <>
             " WHERE harness=?1 AND host=?2 AND failureClass='other' AND state='open' ORDER BY openedAt,id LIMIT 1",
           [input.harness, input.host]
         ) do
      [] ->
        :already_healthy

      [row] ->
        opening = observation_by_id(txn, Enum.at(row, 6))
        probe = "normal turn #{seq} delivered"

        input =
          Map.merge(input, %{
            observed_state: "normal turn delivered",
            exact_probe: probe,
            output_digest: sha256(probe),
            recovery_condition: opening.recovery_condition,
            recovery_condition_digest: opening.recovery_condition_digest,
            recovery_satisfied: 1,
            world_status: "PROVEN",
            redaction_confirmed: true,
            evidence_mode: "probe_digest"
          })

        resolve_other_in_txn(txn, input)
    end
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
      cause: input.cause,
      principal: input.principal
    }

    if input.failure_class == @other_failure_class do
      JSON.encode!(
        Map.merge(base, %{
          descriptionDigest:
            Map.get(input, :description_digest) || Map.get(input, :recovery_condition_digest),
          validUntil: Map.get(input, :valid_until)
        })
      )
    else
      JSON.encode!(base)
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
    audience = {:session, other_custodian(txn, input)}

    message =
      "[shared harness incident: other]\n\n" <>
        "The #{input.harness} harness on #{input.host} opened incident #{incident_id}. " <>
        "Evidence digest #{input.description_digest}; review is required and prodding is " <>
        "paused until the review or its bounded expiry at #{input.valid_until}."

    EventLog.notice_in_txn(
      txn,
      "harness_health_other_review",
      incident_id,
      lifecycle_detail(input, input.correlation_id),
      audience: audience,
      message: message,
      attention: :high
    )
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

  defp credential_shaped?(text) do
    Regex.match?(~r/-----BEGIN [^-]*PRIVATE KEY-----/, text) or
      Regex.match?(~r/(authorization|api[-_]key|token|password|secret)\s*[:=]\s*\S+/i, text) or
      Regex.match?(~r/\b(sk_|ghp_|github_pat_|tbc_|tbs_|tbt_|tbp_)[A-Za-z0-9_-]{8,}/, text)
  end

  defp principal_text({kind, value}), do: "#{kind}:#{value}"
  defp principal_text(value) when is_binary(value), do: value
  defp principal_text(value), do: inspect(value)

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

  defp other_idempotency(txn, principal_ref, idempotency_key) do
    case Txn.q(
           txn,
           "SELECT requestFingerprint,response FROM harness_health_other_idempotency WHERE principalRef=?1 AND operation='observe-other' AND idempotencyKey=?2",
           [principal_ref, idempotency_key]
         ) do
      [[fingerprint, response]] -> %{request_fingerprint: fingerprint, response: response}
      [] -> nil
    end
  end

  defp store_other_idempotency(txn, principal_ref, idempotency_key, fingerprint, {status, detail}) do
    Txn.q(
      txn,
      "INSERT INTO harness_health_other_idempotency (principalRef,operation,idempotencyKey,requestFingerprint,response) VALUES (?1,'observe-other',?2,?3,?4)",
      [
        principal_ref,
        idempotency_key,
        fingerprint,
        JSON.encode!(%{status: status, detail: detail})
      ]
    )
  end

  defp decode_other_idempotency(response) do
    decoded = JSON.decode!(response)

    unless decoded["status"] in ~w(opened attached duplicate) do
      raise ArgumentError, "invalid idempotency response #{inspect(decoded["status"])}"
    end

    {:duplicate, decoded["detail"]}
  end

  defp other_error_code(%ArgumentError{message: message}) do
    if message in ~w(missing_other_evidence invalid_other_evidence stale_other_evidence incident_expired secret_redaction_unconfirmed credential_shaped_evidence source_not_found source_not_active not_authorized idempotency_conflict review_not_pending invalid_review_outcome),
      do: message,
      else: "invalid_other_evidence"
  end

  defp post_commit(result, registry \\ Tightbeam.ConnRegistry)

  defp post_commit({_status, %{notice_publication: nil}}, _registry), do: nil

  defp post_commit({_status, %{notice_publication: publication}}, registry) do
    fn -> EventLog.publish(publication, conn_registry: registry) end
  end

  defp post_commit(_result, _registry), do: nil

  defp strip_publication({status, detail}),
    do: {status, Map.delete(detail, :notice_publication)}

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
