defmodule Tightbeam.TerminalCredentialFailure do
  @moduledoc """
  Durable authority for terminal catalog credential failures.

  The incident key is `{host, harness}`.  This owner never reads credential
  material: it consumes only typed catalog outcomes and the ids of committed
  `credential-present` facts.  Its incidents are deliberately separate from
  `HarnessHealth`, whose normal-turn resolver must never clear this state.
  """

  alias Tightbeam.{ConditionFacts, Credentials, DB, EventLog, Id, Org, Projection}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @class "terminal_credential_failure"
  @assert_kind "catalog-terminal-credential-failure"
  @retract_kind "catalog-terminal-credential-restored"
  @device_id "process:tightbeam:terminal-credential"

  @ddl """
  CREATE TABLE IF NOT EXISTS terminal_credential_incidents (
    id                 TEXT PRIMARY KEY,
    class              TEXT NOT NULL CHECK(class = 'terminal_credential_failure'),
    state              TEXT NOT NULL CHECK(state IN ('open','resolved')),
    host               TEXT NOT NULL CHECK(length(trim(host)) > 0),
    harness            TEXT NOT NULL CHECK(length(trim(harness)) > 0),
    provider           TEXT NOT NULL CHECK(length(trim(provider)) > 0),
    openedAt           INTEGER NOT NULL CHECK(openedAt >= 0),
    openingWatermark   INTEGER NOT NULL CHECK(openingWatermark >= 0),
    openingObservationId TEXT NOT NULL UNIQUE,
    assertionFactId    INTEGER NOT NULL,
    statementId        TEXT NOT NULL UNIQUE,
    recoveryState      TEXT NOT NULL CHECK(recoveryState IN ('idle','claimed','outcome_unknown')),
    claimedFactId      INTEGER,
    pendingFactId      INTEGER,
    consumedFactId     INTEGER,
    lastOutcomeClass   TEXT CHECK(lastOutcomeClass IN ('final_401','transient_failure','empty_catalog','catalog_published')),
    resolvedAt         INTEGER,
    resolutionFactId   INTEGER,
    CHECK(
      (state = 'open' AND resolvedAt IS NULL AND resolutionFactId IS NULL)
      OR
      (state = 'resolved' AND resolvedAt >= openedAt AND resolutionFactId IS NOT NULL)
    ),
    CHECK(
      (recoveryState = 'idle' AND claimedFactId IS NULL)
      OR
      (recoveryState IN ('claimed','outcome_unknown') AND claimedFactId IS NOT NULL)
    ),
    CHECK(pendingFactId IS NULL OR pendingFactId > openingWatermark),
    CHECK(consumedFactId IS NULL OR consumedFactId > openingWatermark)
  );
  CREATE UNIQUE INDEX IF NOT EXISTS terminal_credential_one_open_key
    ON terminal_credential_incidents(host, harness) WHERE state = 'open';
  CREATE INDEX IF NOT EXISTS terminal_credential_open_provider
    ON terminal_credential_incidents(host, provider, state, openingWatermark);

  CREATE TABLE IF NOT EXISTS terminal_credential_observations (
    id            TEXT PRIMARY KEY,
    correlationId TEXT NOT NULL UNIQUE,
    incidentId    TEXT NOT NULL REFERENCES terminal_credential_incidents(id),
    kind          TEXT NOT NULL CHECK(kind IN (
                    'opening','suppression-activated','recovery-claim',
                    'recovery-outcome','resolution'
                  )),
    sourceKind    TEXT NOT NULL CHECK(length(trim(sourceKind)) > 0),
    principal     TEXT NOT NULL CHECK(length(trim(principal)) > 0),
    factId        INTEGER,
    outcomeClass  TEXT CHECK(outcomeClass IN (
                    'final_401','transient_failure','empty_catalog','catalog_published'
                  )),
    observedAt    INTEGER NOT NULL CHECK(observedAt >= 0)
  );
  CREATE INDEX IF NOT EXISTS terminal_credential_observation_incident
    ON terminal_credential_observations(incidentId, observedAt, id);

  CREATE TABLE IF NOT EXISTS terminal_credential_redirects (
    incidentId      TEXT NOT NULL REFERENCES terminal_credential_incidents(id),
    requestIdentity TEXT NOT NULL CHECK(length(trim(requestIdentity)) > 0),
    destinationHost TEXT NOT NULL CHECK(length(trim(destinationHost)) > 0),
    observedAt      INTEGER NOT NULL CHECK(observedAt >= 0),
    PRIMARY KEY(incidentId, requestIdentity)
  );
  CREATE INDEX IF NOT EXISTS terminal_credential_redirect_destinations
    ON terminal_credential_redirects(incidentId, destinationHost);

  CREATE TABLE IF NOT EXISTS terminal_credential_deliveries (
    statementId TEXT NOT NULL,
    incidentId  TEXT NOT NULL REFERENCES terminal_credential_incidents(id),
    adminUserId TEXT NOT NULL REFERENCES users(userId),
    state       TEXT NOT NULL CHECK(state IN ('pending','delivered','resolved')),
    messageId   TEXT,
    updatedAt   INTEGER NOT NULL CHECK(updatedAt >= 0),
    PRIMARY KEY(statementId, adminUserId),
    UNIQUE(messageId),
    CHECK(
      (state = 'pending' AND messageId IS NULL)
      OR (state = 'delivered' AND messageId IS NOT NULL)
      OR state = 'resolved'
    )
  );
  CREATE INDEX IF NOT EXISTS terminal_credential_delivery_incident
    ON terminal_credential_deliveries(incidentId, state, adminUserId);

  CREATE TRIGGER IF NOT EXISTS terminal_credential_incident_identity_immutable
  BEFORE UPDATE OF id,class,host,harness,provider,openedAt,openingWatermark,
                   openingObservationId,assertionFactId,statementId
  ON terminal_credential_incidents
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential incident identity is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_incident_no_delete
  BEFORE DELETE ON terminal_credential_incidents
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential incident history is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_resolution_immutable
  BEFORE UPDATE OF state,resolvedAt,resolutionFactId
  ON terminal_credential_incidents
  WHEN OLD.state = 'resolved'
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential resolution is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_observation_immutable
  BEFORE UPDATE ON terminal_credential_observations
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential observation is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_observation_no_delete
  BEFORE DELETE ON terminal_credential_observations
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential observation history is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_redirect_immutable
  BEFORE UPDATE ON terminal_credential_redirects
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential redirect is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_redirect_no_delete
  BEFORE DELETE ON terminal_credential_redirects
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential redirect history is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_delivery_identity_immutable
  BEFORE UPDATE OF statementId,incidentId,adminUserId,messageId
  ON terminal_credential_deliveries
  WHEN OLD.messageId IS NOT NULL OR NEW.messageId IS NULL
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential delivery identity is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS terminal_credential_delivery_no_delete
  BEFORE DELETE ON terminal_credential_deliveries
  BEGIN
    SELECT RAISE(ABORT, 'terminal credential delivery history is immutable');
  END;
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc false
  @spec ensure_schema_in_txn(Txn.t()) :: :ok
  def ensure_schema_in_txn(%Txn{} = txn), do: Txn.exec(txn, @ddl)

  @spec class() :: String.t()
  def class, do: @class

  @spec scope(String.t(), String.t()) :: String.t()
  def scope(host, harness), do: JSON.encode!([host, harness])

  @spec open?(DB.server(), String.t(), String.t()) :: boolean()
  def open?(db \\ DB, host, harness), do: not is_nil(get_open(db, host, harness))

  @spec get_open(DB.server(), String.t(), String.t()) :: map() | nil
  def get_open(db \\ DB, host, harness) do
    case DB.query(db, incident_select() <> " WHERE state='open' AND host=?1 AND harness=?2", [
           host,
           harness
         ]) do
      {:ok, [row]} -> incident(row)
      {:ok, []} -> nil
    end
  end

  @spec active(DB.server()) :: [map()]
  def active(db \\ DB) do
    {:ok, rows} = DB.query(db, incident_select() <> " WHERE state='open' ORDER BY openedAt,id")
    Enum.map(rows, &incident/1)
  end

  @spec views(DB.server()) :: [map()]
  def views(db \\ DB) do
    active(db)
    |> Enum.map(&view(db, &1))
  end

  @doc "Read current terminal views without starting or mutating the org database."
  @spec readonly_views(String.t()) :: [map()]
  def readonly_views(base_dir) do
    path = Path.join(base_dir, "state.db")

    if File.exists?(path) do
      {:ok, conn} = Exqlite.Sqlite3.open(path, mode: :readonly)

      try do
        case sqlite_rows(conn, "SELECT shape FROM schema_stamp") do
          [["terminal-credential-failure-v1-019"]] -> readonly_views_from_conn(conn)
          _other_shape -> []
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    else
      []
    end
  end

  @spec open(DB.server(), map()) :: {:opened | :existing, map()}
  def open(db \\ DB, input) do
    case DB.transaction(db, &open_in_txn(&1, input)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @spec open_in_txn(Txn.t(), map()) :: {:opened | :existing, map()}
  def open_in_txn(%Txn{} = txn, input) do
    host = nonempty!(input, :host)
    harness = nonempty!(input, :harness)
    provider = nonempty!(input, :provider)
    principal = nonempty(input, :principal, "process:tightbeam/model-catalog")
    source_kind = nonempty(input, :source_kind, "catalog-final-401")
    correlation_id = nonempty(input, :correlation_id, "catalog-final-401:" <> Id.uuid4())
    now = Map.get(input, :observed_at, System.system_time(:millisecond))

    case get_open_in_txn(txn, host, harness) do
      nil ->
        incident_id = "tcf_" <> Id.uuid4()
        observation_id = "tcfo_" <> Id.uuid4()
        statement_id = "terminal-credential:" <> incident_id

        watermark =
          credential_watermark(txn, host, credential_fact_provider(harness, provider))

        fact =
          ConditionFacts.file_in_txn(txn, %{
            kind: @assert_kind,
            scope: scope(host, harness),
            origin: "process:tightbeam"
          })

        Txn.q(
          txn,
          """
          INSERT INTO terminal_credential_incidents
            (id,class,state,host,harness,provider,openedAt,openingWatermark,
             openingObservationId,assertionFactId,statementId,recoveryState)
          VALUES (?1,?2,'open',?3,?4,?5,?6,?7,?8,?9,?10,'idle')
          """,
          [
            incident_id,
            @class,
            host,
            harness,
            provider,
            now,
            watermark,
            observation_id,
            fact.fact_id,
            statement_id
          ]
        )

        insert_observation(
          txn,
          observation_id,
          correlation_id,
          incident_id,
          "opening",
          source_kind,
          principal,
          nil,
          nil,
          now
        )

        insert_observation(
          txn,
          "tcfo_" <> Id.uuid4(),
          "suppression:" <> incident_id,
          incident_id,
          "suppression-activated",
          "incident-open",
          "process:tightbeam",
          nil,
          nil,
          now
        )

        lifecycle(txn, "opened", incident_id, host, harness, nil)
        lifecycle(txn, "suppression_activated", incident_id, host, harness, nil)
        seed_admin_deliveries_in_txn(txn, incident_id, now)
        {:opened, get_in_txn(txn, incident_id)}

      existing ->
        insert_observation(
          txn,
          "tcfo_" <> Id.uuid4(),
          correlation_id,
          existing.id,
          "opening",
          source_kind,
          principal,
          nil,
          nil,
          now,
          on_conflict: :ignore
        )

        {:existing, get_in_txn(txn, existing.id)}
    end
  end

  @spec statement(DB.server() | Txn.t(), String.t()) :: String.t() | nil
  def statement(source, incident_id) do
    case query(
           source,
           "SELECT host,harness,provider FROM terminal_credential_incidents WHERE id=?1 AND state='open'",
           [incident_id]
         ) do
      [[host, harness, provider]] ->
        statement_for(host, harness, provider, redirect_destinations(source, incident_id))

      [] ->
        nil
    end
  end

  @spec record_redirect_in_txn(Txn.t(), String.t(), String.t(), String.t()) ::
          :recorded | :duplicate
  def record_redirect_in_txn(%Txn{} = txn, incident_id, request_identity, destination_host) do
    now = System.system_time(:millisecond)

    case get_in_txn(txn, incident_id) do
      nil ->
        :duplicate

      %{host: ^destination_host} ->
        raise ArgumentError, "terminal credential redirect destination must differ from source"

      incident ->
        Txn.q(
          txn,
          "INSERT OR IGNORE INTO terminal_credential_redirects (incidentId,requestIdentity,destinationHost,observedAt) VALUES (?1,?2,?3,?4)",
          [incident_id, request_identity, destination_host, now]
        )

        if Txn.changes(txn) == 1 do
          lifecycle(
            txn,
            "redirect_observed",
            incident_id,
            incident.host,
            incident.harness,
            "destination=#{destination_host}"
          )

          if incident.state == "open", do: reconcile_incident_in_txn(txn, incident_id, now)
          :recorded
        else
          :duplicate
        end
    end
  end

  @spec claim_recoveries(DB.server(), pos_integer()) :: [map()]
  def claim_recoveries(db \\ DB, fact_id) when is_integer(fact_id) and fact_id > 0 do
    case DB.transaction(db, &claim_recoveries_in_txn(&1, fact_id)) do
      {:ok, claims} -> claims
      {:error, error} -> raise error
    end
  end

  @spec claim_recoveries_in_txn(Txn.t(), pos_integer()) :: [map()]
  def claim_recoveries_in_txn(%Txn{} = txn, fact_id) do
    case Txn.q(
           txn,
           "SELECT scope FROM condition_facts WHERE id=?1 AND kind='credential-present'",
           [fact_id]
         ) do
      [[scope]] ->
        with [host, provider] <- String.split(scope, ":", parts: 2) do
          Txn.q(
            txn,
            incident_select() <> " WHERE state='open' AND host=?1 ORDER BY id",
            [host]
          )
          |> Enum.map(&incident/1)
          |> Enum.filter(&(credential_fact_provider(&1.harness, &1.provider) == provider))
          |> Enum.flat_map(&claim_incident_in_txn(txn, &1, fact_id))
        else
          _ -> []
        end

      [] ->
        []
    end
  end

  @spec resume_recoveries(DB.server()) :: [map()]
  def resume_recoveries(db \\ DB) do
    case DB.transaction(db, fn txn ->
           resumes =
             Txn.q(
               txn,
               incident_select() <>
                 " WHERE state='open' AND recoveryState='claimed' ORDER BY id"
             )
             |> Enum.map(fn row ->
               i = incident(row)

               Txn.q(
                 txn,
                 "UPDATE terminal_credential_incidents SET recoveryState='outcome_unknown' WHERE id=?1 AND state='open' AND recoveryState='claimed' AND claimedFactId=?2",
                 [i.id, i.claimed_fact_id]
               )

               %{
                 incident_id: i.id,
                 host: i.host,
                 harness: i.harness,
                 fact_id: i.claimed_fact_id
               }
             end)

           new_claims =
             Txn.q(txn, incident_select() <> " WHERE state='open' ORDER BY id")
             |> Enum.map(&incident/1)
             |> Enum.flat_map(fn incident ->
               case Txn.q(
                      txn,
                      "SELECT MAX(id) FROM condition_facts WHERE kind='credential-present' AND scope=?1",
                      [
                        incident.host <>
                          ":" <>
                          credential_fact_provider(incident.harness, incident.provider)
                      ]
                    ) do
                 [[fact_id]] when is_integer(fact_id) ->
                   claim_incident_in_txn(txn, incident, fact_id)

                 _ ->
                   []
               end
             end)

           resumes ++ new_claims
         end) do
      {:ok, claims} -> claims
      {:error, error} -> raise error
    end
  end

  @spec finish_recovery(DB.server(), String.t(), pos_integer(), String.t()) ::
          {:resolved, map()} | {:open, map(), map() | nil} | :stale
  def finish_recovery(db \\ DB, incident_id, fact_id, outcome_class)
      when outcome_class in ~w(final_401 transient_failure empty_catalog catalog_published) do
    case DB.transaction(db, &finish_recovery_in_txn(&1, incident_id, fact_id, outcome_class)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp finish_recovery_in_txn(txn, incident_id, fact_id, "catalog_published" = outcome) do
    case get_in_txn(txn, incident_id) do
      %{state: "open", claimed_fact_id: ^fact_id} = incident ->
        now = System.system_time(:millisecond)

        resolution =
          ConditionFacts.file_in_txn(txn, %{
            kind: @retract_kind,
            scope: scope(incident.host, incident.harness),
            origin: "process:tightbeam"
          })

        Txn.q(
          txn,
          """
          UPDATE terminal_credential_incidents
          SET state='resolved', recoveryState='idle', claimedFactId=NULL, pendingFactId=NULL,
              consumedFactId=?2,lastOutcomeClass=?3,resolvedAt=?4,resolutionFactId=?5
          WHERE id=?1 AND state='open' AND claimedFactId=?2
          """,
          [incident_id, fact_id, outcome, now, resolution.fact_id]
        )

        insert_observation(
          txn,
          "tcfo_" <> Id.uuid4(),
          "recovery-outcome:#{incident_id}:#{fact_id}",
          incident_id,
          "recovery-outcome",
          "credential-present",
          "process:tightbeam",
          fact_id,
          outcome,
          now
        )

        insert_observation(
          txn,
          "tcfo_" <> Id.uuid4(),
          "resolution:#{incident_id}",
          incident_id,
          "resolution",
          "catalog-published",
          "process:tightbeam",
          fact_id,
          outcome,
          now
        )

        Txn.q(
          txn,
          "UPDATE terminal_credential_deliveries SET state='resolved',updatedAt=?2 WHERE incidentId=?1 AND state<>'resolved'",
          [incident_id, now]
        )

        lifecycle(
          txn,
          "recovery_outcome",
          incident_id,
          incident.host,
          incident.harness,
          "outcome=#{outcome}"
        )

        lifecycle(txn, "resolved", incident_id, incident.host, incident.harness, nil)
        {:resolved, get_in_txn(txn, incident_id)}

      _ ->
        :stale
    end
  end

  defp finish_recovery_in_txn(txn, incident_id, fact_id, outcome) do
    case get_in_txn(txn, incident_id) do
      %{state: "open", claimed_fact_id: ^fact_id} = incident ->
        now = System.system_time(:millisecond)
        next_fact = incident.pending_fact_id

        {state, claimed, pending, successor} =
          if is_integer(next_fact) and next_fact > fact_id do
            {"claimed", next_fact, nil,
             %{
               incident_id: incident.id,
               host: incident.host,
               harness: incident.harness,
               fact_id: next_fact
             }}
          else
            {"idle", nil, nil, nil}
          end

        Txn.q(
          txn,
          """
          UPDATE terminal_credential_incidents
          SET recoveryState=?3,claimedFactId=?4,pendingFactId=?5,
              consumedFactId=?2,lastOutcomeClass=?6
          WHERE id=?1 AND state='open' AND claimedFactId=?2
          """,
          [incident_id, fact_id, state, claimed, pending, outcome]
        )

        insert_observation(
          txn,
          "tcfo_" <> Id.uuid4(),
          "recovery-outcome:#{incident_id}:#{fact_id}",
          incident_id,
          "recovery-outcome",
          "credential-present",
          "process:tightbeam",
          fact_id,
          outcome,
          now
        )

        lifecycle(
          txn,
          "recovery_outcome",
          incident_id,
          incident.host,
          incident.harness,
          "outcome=#{outcome}"
        )

        if successor do
          insert_observation(
            txn,
            "tcfo_" <> Id.uuid4(),
            "recovery-claim:#{incident.id}:#{successor.fact_id}",
            incident.id,
            "recovery-claim",
            "credential-present",
            "process:tightbeam",
            successor.fact_id,
            nil,
            now
          )

          lifecycle(
            txn,
            "recovery_claimed",
            incident.id,
            incident.host,
            incident.harness,
            "fact=#{successor.fact_id}"
          )
        end

        {:open, get_in_txn(txn, incident_id), successor}

      _ ->
        :stale
    end
  end

  @spec reconcile_all(DB.server()) :: :ok
  def reconcile_all(db \\ DB) do
    case DB.transaction(db, fn txn ->
           now = System.system_time(:millisecond)

           Txn.q(
             txn,
             "SELECT id FROM terminal_credential_incidents WHERE state='open' ORDER BY id"
           )
           |> List.flatten()
           |> Enum.each(&reconcile_incident_in_txn(txn, &1, now))
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  @spec reconcile_admin_in_txn(Txn.t(), String.t()) :: :ok
  def reconcile_admin_in_txn(%Txn{} = txn, user_id) do
    now = System.system_time(:millisecond)

    Txn.q(txn, "SELECT id FROM terminal_credential_incidents WHERE state='open' ORDER BY id")
    |> List.flatten()
    |> Enum.each(fn incident_id -> reconcile_delivery_in_txn(txn, incident_id, user_id, now) end)

    :ok
  end

  @spec reconcile_personal_session_in_txn(Txn.t(), String.t()) :: :ok
  def reconcile_personal_session_in_txn(%Txn{} = txn, user_id),
    do: reconcile_admin_in_txn(txn, user_id)

  defp claim_incident_in_txn(txn, incident, fact_id) do
    floor =
      Enum.max([
        incident.opening_watermark,
        incident.consumed_fact_id || 0,
        incident.claimed_fact_id || 0
      ])

    cond do
      fact_id <= floor ->
        []

      incident.recovery_state in ["claimed", "outcome_unknown"] ->
        Txn.q(
          txn,
          "UPDATE terminal_credential_incidents SET pendingFactId=MAX(COALESCE(pendingFactId,0),?2) WHERE id=?1 AND state='open'",
          [incident.id, fact_id]
        )

        []

      true ->
        now = System.system_time(:millisecond)

        Txn.q(
          txn,
          "UPDATE terminal_credential_incidents SET recoveryState='claimed',claimedFactId=?2 WHERE id=?1 AND state='open' AND recoveryState='idle'",
          [incident.id, fact_id]
        )

        if Txn.changes(txn) == 1 do
          insert_observation(
            txn,
            "tcfo_" <> Id.uuid4(),
            "recovery-claim:#{incident.id}:#{fact_id}",
            incident.id,
            "recovery-claim",
            "credential-present",
            "process:tightbeam",
            fact_id,
            nil,
            now
          )

          lifecycle(
            txn,
            "recovery_claimed",
            incident.id,
            incident.host,
            incident.harness,
            "fact=#{fact_id}"
          )

          [
            %{
              incident_id: incident.id,
              host: incident.host,
              harness: incident.harness,
              fact_id: fact_id
            }
          ]
        else
          []
        end
    end
  end

  defp seed_admin_deliveries_in_txn(txn, incident_id, now) do
    Txn.q(txn, "SELECT userId FROM users WHERE isAdmin=1 ORDER BY userId")
    |> List.flatten()
    |> Enum.each(&reconcile_delivery_in_txn(txn, incident_id, &1, now))
  end

  defp reconcile_incident_in_txn(txn, incident_id, now) do
    seed_admin_deliveries_in_txn(txn, incident_id, now)
    :ok
  end

  defp view(source, incident) do
    destinations = redirect_destinations(source, incident.id)

    %{
      incident_id: incident.id,
      class: incident.class,
      state: incident.state,
      host: incident.host,
      harness: incident.harness,
      provider: incident.provider,
      statement_id: incident.statement_id,
      redirect_destinations: destinations,
      canonical_statement:
        statement_for(incident.host, incident.harness, incident.provider, destinations)
    }
  end

  defp readonly_views_from_conn(conn) do
    sqlite_rows(
      conn,
      "SELECT id,class,state,host,harness,provider,statementId FROM terminal_credential_incidents WHERE state='open' ORDER BY openedAt,id"
    )
    |> Enum.map(fn [id, class, state, host, harness, provider, statement_id] ->
      destinations =
        sqlite_rows(
          conn,
          "SELECT DISTINCT destinationHost FROM terminal_credential_redirects WHERE incidentId=?1 ORDER BY destinationHost",
          [id]
        )
        |> List.flatten()

      %{
        incident_id: id,
        class: class,
        state: state,
        host: host,
        harness: harness,
        provider: provider,
        statement_id: statement_id,
        redirect_destinations: destinations,
        canonical_statement: statement_for(host, harness, provider, destinations)
      }
    end)
  end

  defp sqlite_rows(conn, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp redirect_destinations(source, incident_id) do
    query(
      source,
      "SELECT DISTINCT destinationHost FROM terminal_credential_redirects WHERE incidentId=?1 ORDER BY destinationHost",
      [incident_id]
    )
    |> List.flatten()
  end

  defp statement_for(host, harness, provider, destinations) do
    redirect_state =
      case destinations do
        [] -> "not yet observed; lawful alternate routing remains enabled"
        hosts -> Enum.join(hosts, ", ")
      end

    onboard = onboarding_command(harness, provider)

    "#{host} lost #{harness}: its #{provider} credential was rejected. Redirect destination: " <>
      "#{redirect_state}. #{host} needs a human " <>
      "sign-in for #{harness}; run on #{host}: #{onboard} " <>
      "(replace <adminUserId> with your own administrator id)."
  end

  defp credential_fact_provider("pi", "opencode_go"), do: "opencode_go"
  defp credential_fact_provider("pi", _named_local_provider), do: "local_openai"
  defp credential_fact_provider(_harness, provider), do: provider

  defp onboarding_command(harness, provider) do
    command =
      harness
      |> onboarding_provider(provider)
      |> Credentials.onboard_command()
      |> String.replace("<userId>", "<adminUserId>")

    if harness == "pi" and provider != "opencode_go" do
      String.replace(command, "<provider-name>", provider)
    else
      command
    end
  end

  defp onboarding_provider("pi", "opencode_go"), do: :opencode_go
  defp onboarding_provider("pi", _named_local_provider), do: :local_openai
  defp onboarding_provider(_harness, "openai"), do: :openai
  defp onboarding_provider(_harness, "anthropic"), do: :anthropic
  defp onboarding_provider(_harness, "cursor"), do: :cursor
  defp onboarding_provider(_harness, "fixture_provider"), do: :fixture_provider

  defp reconcile_delivery_in_txn(txn, incident_id, user_id, now) do
    incident = get_in_txn(txn, incident_id)

    eligible? =
      Txn.q(txn, "SELECT 1 FROM users WHERE userId=?1 AND isAdmin=1", [user_id]) == [[1]]

    cond do
      is_nil(incident) or incident.state != "open" ->
        Txn.q(
          txn,
          "UPDATE terminal_credential_deliveries SET state='resolved',updatedAt=?3 WHERE incidentId=?1 AND adminUserId=?2 AND state='pending'",
          [incident_id, user_id, now]
        )

        :ok

      not eligible? ->
        :ok

      true ->
        Txn.q(
          txn,
          """
          INSERT OR IGNORE INTO terminal_credential_deliveries
            (statementId,incidentId,adminUserId,state,messageId,updatedAt)
          VALUES (?1,?2,?3,'pending',NULL,?4)
          """,
          [incident.statement_id, incident.id, user_id, now]
        )

        target = Org.personal_session_key(user_id)

        active? =
          Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [target]) ==
            [[1]]

        if active?, do: deliver_in_txn(txn, incident, user_id, target, now)
        :ok
    end
  end

  defp deliver_in_txn(txn, incident, user_id, target, now) do
    content = statement(txn, incident.id)

    case Txn.q(
           txn,
           "SELECT state,messageId FROM terminal_credential_deliveries WHERE statementId=?1 AND adminUserId=?2",
           [incident.statement_id, user_id]
         ) do
      [["pending", nil]] ->
        case Projection.append_in_txn(txn, %{
               session_key: target,
               role: "assistant",
               message_type: "substrate",
               content: content,
               sender: "process:tightbeam",
               device_id: @device_id,
               client_message_id: incident.statement_id <> ":" <> user_id,
               attention_tier: Projection.attention_tier(:high)
             }) do
          {status, message} when status in [:appended, :duplicate] ->
            Txn.q(
              txn,
              "UPDATE terminal_credential_deliveries SET state='delivered',messageId=?3,updatedAt=?4 WHERE statementId=?1 AND adminUserId=?2 AND state='pending'",
              [incident.statement_id, user_id, message.id, now]
            )

            Publisher.message_in_txn(txn, target, message, user_id)

          {:conflict, _message} ->
            raise "terminal credential standing identity conflicted"
        end

      [["delivered", message_id]] ->
        Txn.q(txn, "UPDATE messages SET content=?2,timestamp=?3 WHERE id=?1 AND content<>?2", [
          message_id,
          content,
          now
        ])

        if Txn.changes(txn) == 1 do
          [message] = message_by_id(txn, message_id)
          Publisher.message_in_txn(txn, target, message, user_id)
        end

      [["resolved", _]] ->
        :ok
    end
  end

  defp message_by_id(txn, id) do
    Txn.q(
      txn,
      "SELECT seq,id,sessionKey,role,messageType,content,timestamp,sender,deviceId,clientMessageId,replyToMessageId,replyToClientMessageId,llmVisibleMessageId,attachments,attentionTier FROM messages WHERE id=?1",
      [id]
    )
    |> Enum.map(fn [
                     seq,
                     mid,
                     session_key,
                     role,
                     message_type,
                     content,
                     timestamp,
                     sender,
                     device_id,
                     client_message_id,
                     reply_id,
                     reply_client_id,
                     visible_id,
                     attachments,
                     attention
                   ] ->
      %{
        seq: seq,
        id: mid,
        session_key: session_key,
        role: role,
        message_type: message_type,
        content: content,
        timestamp: timestamp,
        sender: sender,
        device_id: device_id,
        client_message_id: client_message_id,
        reply_to_message_id: reply_id,
        reply_to_client_message_id: reply_client_id,
        llm_visible_message_id: visible_id,
        attachments: JSON.decode!(attachments),
        attention_tier: attention
      }
    end)
  end

  defp credential_watermark(txn, host, provider) do
    case Txn.q(
           txn,
           "SELECT COALESCE(MAX(id),0) FROM condition_facts WHERE kind='credential-present' AND scope=?1",
           [host <> ":" <> provider]
         ) do
      [[id]] -> id
    end
  end

  defp lifecycle(txn, suffix, incident_id, host, harness, detail) do
    kind = "terminal_credential_" <> suffix
    payload = %{incidentId: incident_id, host: host, harness: harness, detail: detail}

    EventLog.lifecycle_in_txn(
      txn,
      kind,
      incident_id,
      "host=#{host} harness=#{harness}" <> if(detail, do: " " <> detail, else: "")
    )

    Publisher.lifecycle_in_txn(
      txn,
      "lifecycle." <> kind,
      payload,
      %{"incidentId" => incident_id, "host" => host, "harness" => harness}
    )
  end

  defp insert_observation(
         txn,
         id,
         correlation_id,
         incident_id,
         kind,
         source_kind,
         principal,
         fact_id,
         outcome,
         observed_at,
         opts \\ []
       ) do
    conflict = if Keyword.get(opts, :on_conflict) == :ignore, do: "OR IGNORE", else: ""

    Txn.q(
      txn,
      "INSERT #{conflict} INTO terminal_credential_observations (id,correlationId,incidentId,kind,sourceKind,principal,factId,outcomeClass,observedAt) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
      [
        id,
        correlation_id,
        incident_id,
        kind,
        source_kind,
        principal,
        fact_id,
        outcome,
        observed_at
      ]
    )
  end

  defp get_open_in_txn(txn, host, harness) do
    case Txn.q(txn, incident_select() <> " WHERE state='open' AND host=?1 AND harness=?2", [
           host,
           harness
         ]) do
      [row] -> incident(row)
      [] -> nil
    end
  end

  defp get_in_txn(txn, id) do
    case Txn.q(txn, incident_select() <> " WHERE id=?1", [id]) do
      [row] -> incident(row)
      [] -> nil
    end
  end

  defp incident_select do
    """
    SELECT id,class,state,host,harness,provider,openedAt,openingWatermark,
           openingObservationId,assertionFactId,statementId,recoveryState,
           claimedFactId,pendingFactId,consumedFactId,lastOutcomeClass,
           resolvedAt,resolutionFactId
    FROM terminal_credential_incidents
    """
  end

  defp incident([
         id,
         class,
         state,
         host,
         harness,
         provider,
         opened_at,
         watermark,
         opening_observation_id,
         assertion_fact_id,
         statement_id,
         recovery_state,
         claimed_fact_id,
         pending_fact_id,
         consumed_fact_id,
         last_outcome_class,
         resolved_at,
         resolution_fact_id
       ]) do
    %{
      id: id,
      class: class,
      state: state,
      host: host,
      harness: harness,
      provider: provider,
      opened_at: opened_at,
      opening_watermark: watermark,
      opening_observation_id: opening_observation_id,
      assertion_fact_id: assertion_fact_id,
      statement_id: statement_id,
      recovery_state: recovery_state,
      claimed_fact_id: claimed_fact_id,
      pending_fact_id: pending_fact_id,
      consumed_fact_id: consumed_fact_id,
      last_outcome_class: last_outcome_class,
      resolved_at: resolved_at,
      resolution_fact_id: resolution_fact_id
    }
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp nonempty!(input, key) do
    case Map.fetch!(input, key) do
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "#{key} must be non-empty, got: #{inspect(value)}"
    end
  end

  defp nonempty(input, key, default) do
    case Map.get(input, key, default) do
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "#{key} must be non-empty, got: #{inspect(value)}"
    end
  end
end
