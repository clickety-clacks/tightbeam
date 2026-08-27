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
  @failure_evidence ~w(authoritative-provider terminal-failure)
  @evidence_window_ms 120_000

  @observation_columns ~w(
    id correlation_id harness host failure_class evidence_kind session_key
    assignment_id observed_at cause principal incident_id
  )a

  @incident_columns ~w(
    id harness host failure_class state opened_at open_observation_id opened_fact_id
    resolved_at resolution_observation_id resolved_fact_id
  )a

  @ddl """
  CREATE TABLE IF NOT EXISTS harness_health_observations (
    id            TEXT PRIMARY KEY,
    correlationId TEXT NOT NULL UNIQUE,
    harness       TEXT NOT NULL CHECK(length(trim(harness)) > 0),
    host          TEXT NOT NULL CHECK(length(trim(host)) > 0),
    failureClass  TEXT NOT NULL CHECK(failureClass IN (
                    'auth-dead','rate-limit-dead','adapter_unavailable','model_unavailable',
                    'task_crash','interrupted-outcome-unknown'
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
    CHECK(evidenceKind != 'terminal-failure' OR sessionKey IS NOT NULL),
    CHECK(evidenceKind != 'normal-turn-success' OR incidentId IS NOT NULL),
    CHECK(assignmentId IS NULL OR sessionKey IS NOT NULL)
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
                              'model_unavailable','task_crash','interrupted-outcome-unknown'
                            )),
    state                   TEXT NOT NULL CHECK(state IN ('open','resolved')),
    openedAt                INTEGER NOT NULL CHECK(openedAt >= 0),
    openObservationId       TEXT NOT NULL REFERENCES harness_health_observations(id)
                              DEFERRABLE INITIALLY DEFERRED,
    openedFactId            INTEGER NOT NULL REFERENCES condition_facts(id),
    resolvedAt              INTEGER,
    resolutionObservationId TEXT REFERENCES harness_health_observations(id)
                              DEFERRABLE INITIALLY DEFERRED,
    resolvedFactId          INTEGER REFERENCES condition_facts(id),
    CHECK(
      (state = 'open' AND resolvedAt IS NULL AND resolutionObservationId IS NULL AND
       resolvedFactId IS NULL)
      OR
      (state = 'resolved' AND resolvedAt >= openedAt AND
       resolutionObservationId IS NOT NULL AND resolvedFactId IS NOT NULL)
    )
  );
  CREATE UNIQUE INDEX IF NOT EXISTS harness_health_one_open_class
    ON harness_health_incidents (harness, host, failureClass) WHERE state = 'open';
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
    OLD.state = 'open' AND OLD.resolvedAt IS NULL AND
    OLD.resolutionObservationId IS NULL AND OLD.resolvedFactId IS NULL AND
    NEW.state = 'resolved' AND NEW.resolvedAt IS NOT NULL AND
    NEW.resolutionObservationId IS NOT NULL AND NEW.resolvedFactId IS NOT NULL AND
    EXISTS (
      SELECT 1 FROM harness_health_observations
      WHERE id = NEW.resolutionObservationId AND incidentId = OLD.id AND
            harness = OLD.harness AND host = OLD.host AND
            failureClass = OLD.failureClass AND evidenceKind = 'normal-turn-success'
    )
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
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

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
        assignment_id =
          case Txn.q(txn, "SELECT assignmentId FROM turns WHERE seq=?1", [turn.seq]) do
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
          SELECT t.sessionKey,t.assignmentId,s.harness,s.host
          FROM turns t JOIN sessions s ON s.sessionKey=t.sessionKey
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
      resolve_in_txn(txn, %{
        correlation_id: "harness-turn:#{turn.seq}:normal-success:#{failure_class}",
        harness: harness,
        host: session.host,
        failure_class: failure_class,
        session_key: turn.session_key,
        assignment_id: nil,
        observed_at: System.system_time(:millisecond),
        cause: "normal turn #{turn.seq} delivered",
        principal: turn.origin || "process:tightbeam"
      })
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
    incident_id = "hhi_" <> Id.uuid4()

    %{fact_id: fact_id} =
      ConditionFacts.file_harness_health_in_txn(
        txn,
        input.harness,
        input.host,
        input.failure_class,
        :assert
      )

    Txn.q(
      txn,
      """
      INSERT INTO harness_health_incidents
        (id,harness,host,failureClass,state,openedAt,openObservationId,openedFactId)
      VALUES (?1,?2,?3,?4,'open',?5,?6,?7)
      """,
      [
        incident_id,
        input.harness,
        input.host,
        input.failure_class,
        input.observed_at,
        opening_observation_id,
        fact_id
      ]
    )

    if input.failure_class == "rate-limit-dead" do
      HarnessProcess.begin_park_in_txn(txn, adapter_key(input.harness, input.host))
    end

    snapshot_affected_work(txn, incident_id, input)

    observations_to_attach(txn, input)
    |> Enum.each(&attach_observation(txn, incident_id, &1))

    EventLog.lifecycle_in_txn(
      txn,
      "harness_health_incident_opened",
      incident_id,
      lifecycle_detail(input, opening_observation_id)
    )

    notice_publication = incident_notice_in_txn(txn, incident_id, input)

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
         observedAt,cause,principal,incidentId)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
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
        incident_id
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

  defp incident_by_id(txn, incident_id) do
    [row] = Txn.q(txn, incident_sql() <> " WHERE id=?1", [incident_id])
    incident(row)
  end

  defp observation_sql do
    """
    SELECT id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,
           assignmentId,observedAt,cause,principal,incidentId
    FROM harness_health_observations
    """
  end

  defp incident_sql do
    """
    SELECT id,harness,host,failureClass,state,openedAt,openObservationId,openedFactId,
           resolvedAt,resolutionObservationId,resolvedFactId
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
    JSON.encode!(%{
      observationId: observation_id,
      harness: input.harness,
      host: input.host,
      failureClass: input.failure_class,
      evidenceKind: input.evidence_kind,
      correlationId: input.correlation_id,
      cause: input.cause,
      principal: input.principal
    })
  end

  defp incident_notice_in_txn(_txn, _incident_id, %{failure_class: "rate-limit-dead"}),
    do: nil

  defp incident_notice_in_txn(txn, incident_id, input) do
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

  defp post_commit(result, registry \\ Tightbeam.ConnRegistry)

  defp post_commit({_status, %{notice_publication: nil}}, _registry), do: nil

  defp post_commit({_status, %{notice_publication: publication}}, registry) do
    fn -> EventLog.complete_notice(publication, conn_registry: registry) end
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
