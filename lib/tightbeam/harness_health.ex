defmodule Tightbeam.HarnessHealth do
  @moduledoc """
  Durable incident foundation for shared harness failures.

  Observations are append-only evidence. An authoritative provider observation
  opens an incident immediately. Inferred failure evidence needs two distinct
  sessions on the same shared harness and in the same class inside the bounded
  window. Resolution appends normal-turn evidence and retracts the class fact;
  neither observations nor incidents are deleted.

  This module records and reads facts. Runtime classification, patrol
  suppression, blockers, probes, and normal-turn wiring remain at their locked
  producer and consumer seams.
  """

  alias Tightbeam.{ConditionFacts, DB, EventLog, Id}
  alias Tightbeam.DB.Txn

  @failure_classes ~w(auth-dead rate-limit-dead)
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
    failureClass  TEXT NOT NULL CHECK(failureClass IN ('auth-dead','rate-limit-dead')),
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
    failureClass            TEXT NOT NULL CHECK(failureClass IN ('auth-dead','rate-limit-dead')),
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

  @doc "Record failure evidence and open or attach to its incident atomically."
  @spec observe(DB.server(), map()) :: {:pending | :opened | :attached | :duplicate, map()}
  def observe(db \\ DB, input) do
    input = normalize_failure!(input)
    transaction!(db, &observe_in_txn(&1, input))
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
  @spec resolve(DB.server(), map()) :: {:resolved | :duplicate, map()} | :already_healthy
  def resolve(db \\ DB, input) do
    input = input |> Map.put(:evidence_kind, "normal-turn-success") |> normalize_common!()
    transaction!(db, &resolve_in_txn(&1, input))
  end

  @doc "The class-specific resolution mutation inside a caller-owned transaction."
  @spec resolve_in_txn(Txn.t(), map()) :: {:resolved | :duplicate, map()} | :already_healthy
  def resolve_in_txn(%Txn{} = txn, input) do
    input = input |> Map.put(:evidence_kind, "normal-turn-success") |> normalize_common!()
    validate_session_membership!(txn, input)

    case observation_by_correlation(txn, input.correlation_id) do
      nil -> resolve_open(txn, input)
      prior -> duplicate_or_refuse!(txn, prior, input, "normal-turn-success")
    end
  end

  @doc "List currently open incidents, oldest first."
  @spec active(DB.server()) :: [map()]
  def active(db \\ DB) do
    {:ok, rows} =
      DB.query(db, incident_sql() <> " WHERE state='open' ORDER BY openedAt,id")

    Enum.map(rows, &incident/1)
  end

  @doc "Read one incident with the evidence that names its affected work."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ DB, incident_id) do
    with {:ok, [row]} <- DB.query(db, incident_sql() <> " WHERE id=?1", [incident_id]) do
      incident = incident(row)

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

    snapshot_affected_work(txn, incident_id, input)

    observations_to_attach(txn, input)
    |> Enum.each(&attach_observation(txn, incident_id, &1))

    EventLog.lifecycle_in_txn(
      txn,
      "harness_health_incident_opened",
      incident_id,
      lifecycle_detail(input, opening_observation_id)
    )

    {:opened,
     %{
       id: incident_id,
       harness: input.harness,
       host: input.host,
       failureClass: input.failure_class,
       state: "open",
       openedAt: input.observed_at,
       openedFactId: fact_id,
       observationId: opening_observation_id
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

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
