defmodule Tightbeam.HarnessProcess do
  @moduledoc """
  Durable identity and lifecycle for OS harness processes.

  A launch writes its row before opening the process. A small POSIX launcher
  creates a new session, records its leader PID, process-group ID, boot marker,
  and per-launch token, then execs the harness. Killing authorizes that durable
  identity immediately before signalling the minted group. The row owns the
  identity file until the launch resolves to a terminal state.
  """

  alias Tightbeam.{DB, EventLog, Id}

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
  @command_timeout_ms 5_000
  @old_schema_refusal "The database carries a pre-release harness_processes shape; it is not upgraded by design. Reset the database and restart Tightbeam."

  @process_ddl """
  CREATE TABLE IF NOT EXISTS harness_processes (
    launchId        TEXT PRIMARY KEY,
    adapterKey      TEXT NOT NULL,
    harness         TEXT NOT NULL,
    preset          TEXT NOT NULL,
    host             TEXT NOT NULL,
    ssh              TEXT,
    helperPath       TEXT NOT NULL,
    identityPath     TEXT NOT NULL,
    launchSequence   INTEGER NOT NULL,
    osPid            INTEGER,
    processGroupId   INTEGER,
    bootIdentity     TEXT,
    identityToken    TEXT,
    state            TEXT NOT NULL CHECK (state IN
                     ('launching','running','kill_requested','closed_gracefully',
                      'killed','kill_failed','exited')),
    createdAt        INTEGER NOT NULL,
    killRequestedAt  INTEGER,
    killAttemptedAt  INTEGER,
    killSentAt       INTEGER,
    resolvedAt       INTEGER,
    lastError        TEXT
  );
  """

  @ddl """
  #{@process_ddl}
  CREATE TABLE IF NOT EXISTS harness_kill_fences (
    adapterKey       TEXT PRIMARY KEY,
    requestedAt      INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS harness_kill_requests (
    requestId        TEXT PRIMARY KEY,
    launchId         TEXT REFERENCES harness_processes(launchId),
    adapterKey       TEXT NOT NULL,
    osPid            INTEGER CHECK (osPid > 0),
    processGroupId   INTEGER CHECK (processGroupId > 0),
    bootIdentity     TEXT,
    launchIdentity   TEXT,
    principalKind    TEXT NOT NULL CHECK (principalKind IN ('user','process')),
    principalId      TEXT NOT NULL,
    authorityBasis   TEXT NOT NULL CHECK (authorityBasis IN (
      'owner_user','administrator','operator','harness_health_recovery','retirement'
    )),
    causeKind        TEXT NOT NULL,
    causeId          TEXT NOT NULL,
    status           TEXT NOT NULL CHECK (status IN ('accepted','killed','kill_failed','refused')),
    refusalCode      TEXT CHECK (refusalCode IN ('not_authorized','identity_mismatch')),
    failureCode      TEXT CHECK (failureCode = 'delivery_failed'),
    signalResult     TEXT CHECK (signalResult IN ('sigkill_delivered','graceful_exit')),
    acceptedAt       INTEGER NOT NULL,
    closedAt         INTEGER,
    CHECK (
      status = 'accepted' AND osPid IS NOT NULL AND processGroupId IS NOT NULL
        AND launchId IS NOT NULL
        AND bootIdentity IS NOT NULL AND launchIdentity IS NOT NULL
        AND closedAt IS NULL AND refusalCode IS NULL
        AND failureCode IS NULL AND signalResult IS NULL
      OR status = 'killed' AND osPid IS NOT NULL AND processGroupId IS NOT NULL
        AND launchId IS NOT NULL
        AND bootIdentity IS NOT NULL AND launchIdentity IS NOT NULL
        AND closedAt IS NOT NULL AND refusalCode IS NULL
        AND failureCode IS NULL AND signalResult IS NOT NULL
      OR status = 'kill_failed' AND osPid IS NOT NULL AND processGroupId IS NOT NULL
        AND launchId IS NOT NULL
        AND bootIdentity IS NOT NULL AND launchIdentity IS NOT NULL
        AND closedAt IS NOT NULL AND refusalCode IS NULL
        AND failureCode = 'delivery_failed' AND signalResult IS NULL
      OR status = 'refused' AND closedAt IS NOT NULL AND refusalCode IS NOT NULL
        AND failureCode IS NULL AND signalResult IS NULL
    )
  );
  CREATE INDEX IF NOT EXISTS harness_kill_requests_launch
    ON harness_kill_requests(launchId, acceptedAt, requestId);
  CREATE TABLE IF NOT EXISTS harness_kill_request_sessions (
    requestId        TEXT NOT NULL REFERENCES harness_kill_requests(requestId),
    sessionKey       TEXT NOT NULL REFERENCES sessions(sessionKey),
    lifecycleGeneration INTEGER NOT NULL CHECK (lifecycleGeneration >= 0),
    PRIMARY KEY (requestId, sessionKey)
  );
  CREATE TABLE IF NOT EXISTS harness_kill_attempts (
    requestId        TEXT NOT NULL REFERENCES harness_kill_requests(requestId),
    attempt          INTEGER NOT NULL CHECK (attempt >= 1),
    attemptedAt      INTEGER NOT NULL,
    result           TEXT NOT NULL CHECK (result IN ('delivered','delivery_failed','identity_mismatch')),
    detail           TEXT,
    PRIMARY KEY (requestId, attempt)
  );
  CREATE TABLE IF NOT EXISTS harness_kill_read_audits (
    readId TEXT PRIMARY KEY,
    requestId TEXT NOT NULL,
    principalKind TEXT NOT NULL CHECK (principalKind IN ('user','session','process','unknown')),
    principalId TEXT NOT NULL,
    admitted INTEGER NOT NULL CHECK (admitted IN (0,1)),
    readAt INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS harness_health_recovery_decisions (
    decisionId TEXT PRIMARY KEY,
    incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    targetKind TEXT NOT NULL CHECK (targetKind IN ('process_group','session')),
    launchId TEXT REFERENCES harness_processes(launchId),
    sessionKey TEXT REFERENCES sessions(sessionKey),
    sessionGeneration INTEGER CHECK (sessionGeneration >= 0),
    harness TEXT NOT NULL,
    host TEXT NOT NULL,
    processGroupId INTEGER CHECK (processGroupId > 0),
    bootIdentity TEXT,
    launchIdentity TEXT,
    action TEXT NOT NULL CHECK (action IN ('kill','park')),
    mode TEXT NOT NULL CHECK (mode IN ('immediate','graceful')),
    policyBasis TEXT NOT NULL CHECK (policyBasis IN (
      'rate_limit_dead','shared_harness_incident_hold'
    )),
    evidenceObservationId TEXT NOT NULL REFERENCES harness_health_observations(id),
    principal TEXT NOT NULL CHECK (principal = 'tightbeam:harness-health'),
    createdAt INTEGER NOT NULL,
    CHECK (
      targetKind='process_group' AND action='kill' AND mode='immediate'
        AND policyBasis='rate_limit_dead' AND launchId IS NOT NULL
        AND sessionKey IS NULL AND sessionGeneration IS NULL
        AND processGroupId IS NOT NULL AND bootIdentity IS NOT NULL
        AND launchIdentity IS NOT NULL
      OR targetKind='session' AND action='park' AND mode='graceful'
        AND policyBasis='shared_harness_incident_hold' AND launchId IS NULL
        AND sessionKey IS NOT NULL AND sessionGeneration IS NOT NULL
        AND processGroupId IS NULL AND bootIdentity IS NULL AND launchIdentity IS NULL
    )
  );
  CREATE UNIQUE INDEX IF NOT EXISTS harness_health_one_kill_decision
    ON harness_health_recovery_decisions(incidentId) WHERE action='kill';
  CREATE UNIQUE INDEX IF NOT EXISTS harness_health_one_park_decision
    ON harness_health_recovery_decisions(incidentId,sessionKey,sessionGeneration)
    WHERE action='park';
  CREATE TRIGGER IF NOT EXISTS harness_health_recovery_decision_immutable_update
  BEFORE UPDATE ON harness_health_recovery_decisions
  BEGIN
    SELECT RAISE(ABORT, 'harness health recovery decision is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS harness_health_recovery_decision_immutable_delete
  BEFORE DELETE ON harness_health_recovery_decisions
  BEGIN
    SELECT RAISE(ABORT, 'harness health recovery decision is immutable');
  END;
  """

  @type row :: %{
          launch_id: String.t(),
          adapter_key: String.t(),
          harness: String.t(),
          preset: String.t(),
          host: String.t(),
          ssh: String.t() | nil,
          helper_path: String.t() | nil,
          identity_path: String.t(),
          launch_sequence: pos_integer(),
          os_pid: pos_integer() | nil,
          process_group_id: pos_integer() | nil,
          boot_identity: String.t() | nil,
          identity_token: String.t() | nil,
          state: String.t(),
          created_at: integer(),
          kill_requested_at: integer() | nil,
          kill_attempted_at: integer() | nil,
          kill_sent_at: integer() | nil,
          resolved_at: integer() | nil,
          last_error: String.t() | nil
        }

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    case DB.transaction(db, fn txn ->
           DB.Txn.exec(txn, @ddl)

           DB.Txn.exec(
             txn,
             "CREATE INDEX IF NOT EXISTS harness_processes_adapter_launch_sequence ON harness_processes (adapterKey, state, launchSequence)"
           )

           :ok
         end) do
      {:ok, :ok} ->
        :ok

      {:error, %MatchError{term: {:error, "no such column: launchSequence"}}} ->
        raise DB.Error, message: @old_schema_refusal

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  def ddl_for_migration, do: @ddl

  @doc "Insert the durable launch event and wrap the target command to record its identity."
  @spec prepare_launch(keyword(), DB.server(), tuple()) :: keyword()
  def prepare_launch(opts, db, {harness, preset, host} = key) do
    :ok = ensure_schema(db)
    launch_id = Id.ulid()
    ssh = Keyword.get(opts, :process_ssh)
    helper_path = Keyword.fetch!(opts, :process_helper)

    stderr_path = Keyword.get(opts, :stderr_path, "/dev/null")

    root =
      Keyword.get(opts, :process_identity_dir) || Keyword.get(opts, :home) ||
        Path.dirname(stderr_path)

    identity_path = Path.join([root, "harness-processes", launch_id <> ".identity"])
    if is_nil(ssh), do: File.mkdir_p!(Path.dirname(identity_path))

    case DB.transaction(db, fn txn ->
           case DB.Txn.q(
                  txn,
                  """
                  SELECT 1 FROM harness_processes
                   WHERE adapterKey = ?1
                     AND state IN ('launching','running','kill_requested','kill_failed')
                     AND resolvedAt IS NULL
                  UNION ALL
                  SELECT 1 FROM harness_kill_fences WHERE adapterKey = ?1
                  LIMIT 1
                  """,
                  [key_name(key)]
                ) do
             [] ->
               [[launch_sequence]] =
                 DB.Txn.q(
                   txn,
                   "SELECT COALESCE(MAX(launchSequence), 0) + 1 FROM harness_processes"
                 )

               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO harness_processes
                   (launchId, adapterKey, harness, preset, host, ssh, helperPath,
                    identityPath, launchSequence, state, createdAt)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'launching', ?10)
                 """,
                 [
                   launch_id,
                   key_name(key),
                   to_string(harness),
                   preset,
                   host,
                   ssh,
                   helper_path,
                   identity_path,
                   launch_sequence,
                   now()
                 ]
               )

               :ok

             [[1]] ->
               :fenced
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, :fenced} -> raise "adapter kill in progress for #{key_name(key)}"
    end

    opts
    |> Keyword.put(
      :cmd,
      wrap_command(Keyword.fetch!(opts, :cmd), ssh, helper_path, identity_path, launch_id)
    )
    |> Keyword.put(:harness_process_launch_id, launch_id)
  end

  @doc "Read and persist the identity written by the launched process itself."
  @spec capture_identity(DB.server(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def capture_identity(db, launch_id, timeout_ms \\ 5_000) do
    row = fetch!(db, launch_id)

    case await_identity(row, deadline(timeout_ms)) do
      {:ok, pid, process_group_id, boot_identity, identity_token} ->
        :ok =
          persist_identity(
            db,
            row,
            pid,
            process_group_id,
            boot_identity,
            identity_token,
            true
          )

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Atomically establish the durable kill fence and return the launch it protects."
  @spec begin_kill(DB.server(), tuple()) :: {:ok, row() | :no_launch}
  def begin_kill(db, key) do
    :ok = ensure_schema(db)
    DB.transaction(db, &begin_kill_in_txn(&1, key))
  end

  @doc "Establish the kill fence as part of a caller-owned incident transaction."
  @spec begin_kill_in_txn(DB.Txn.t(), tuple()) :: row() | :no_launch
  def begin_kill_in_txn(%DB.Txn{} = txn, key, attrs \\ %{}) do
    at = now()
    adapter_key = key_name(key)

    case latest_unresolved_in_txn(txn, adapter_key) do
      nil ->
        if map_size(attrs) == 0 do
          DB.Txn.q(
            txn,
            "INSERT OR IGNORE INTO harness_kill_fences (adapterKey, requestedAt) VALUES (?1, ?2)",
            [adapter_key, at]
          )

          :no_launch
        else
          refusal = create_no_launch_kill_refusal_in_txn(txn, key, adapter_key, attrs, at)

          # A rate-limit incident fences new claims even when there is no
          # process group to signal. The KILL request still closes as the
          # typed identity_mismatch refusal; this fence represents the open
          # health incident, not a successful KILL delivery.
          if no_launch_health_fence_authorized?(txn, key, attrs) do
            DB.Txn.q(
              txn,
              "INSERT OR IGNORE INTO harness_kill_fences (adapterKey, requestedAt) VALUES (?1, ?2)",
              [adapter_key, at]
            )
          end

          refusal
        end

      row ->
        requested = create_kill_request_in_txn(txn, row, attrs, at)

        if requested.kill_request_status == "refused" do
          requested
        else
          DB.Txn.q(
            txn,
            "INSERT OR IGNORE INTO harness_kill_fences (adapterKey, requestedAt) VALUES (?1, ?2)",
            [adapter_key, at]
          )

          DB.Txn.q(
            txn,
            """
            UPDATE harness_processes
               SET state = 'kill_requested', killRequestedAt = COALESCE(killRequestedAt, ?2)
             WHERE launchId = ?1 AND resolvedAt IS NULL
            """,
            [row.launch_id, at]
          )

          %{requested | state: "kill_requested", kill_requested_at: row.kill_requested_at || at}
        end
    end
  end

  defp create_no_launch_kill_refusal_in_txn(txn, key, adapter_key, attrs, at) do
    row = %{
      launch_id: nil,
      adapter_key: adapter_key,
      os_pid: nil,
      process_group_id: nil,
      boot_identity: nil,
      identity_token: nil
    }

    attrs = normalize_kill_attrs(attrs, row)
    {principal_kind, principal_id} = kill_principal(attrs.principal)
    request_id = "kr_" <> Id.uuid4()
    attached = no_launch_attached_sessions(txn, key, attrs.cause_id)

    create_identified_kill_request_in_txn(
      txn,
      row,
      attrs,
      attached,
      principal_kind,
      principal_id,
      request_id,
      no_launch_authority_refusal(txn, key, attrs) || "identity_mismatch",
      at
    )
  end

  defp no_launch_attached_sessions(txn, {harness, _preset, host}, session_key) do
    case DB.Txn.q(
           txn,
           "SELECT lifecycleGeneration FROM sessions WHERE sessionKey=?1 AND harness=?2 AND host=?3",
           [session_key, Atom.to_string(harness), host]
         ) do
      [[generation]] -> [%{session_key: session_key, generation: generation}]
      [] -> []
    end
  end

  defp no_launch_authority_refusal(txn, {harness, _preset, host}, attrs) do
    harness = Atom.to_string(harness)

    case {attrs.principal, attrs.authority_basis} do
      {{:user, user}, "owner_user"} ->
        if DB.Txn.q(
             txn,
             "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND harness=?3 AND host=?4",
             [attrs.cause_id, user, harness, host]
           ) == [[1]],
           do: nil,
           else: "not_authorized"

      {{:user, user}, basis} when basis in ["administrator", "operator"] ->
        if DB.Txn.q(txn, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == [[1]],
          do: nil,
          else: "not_authorized"

      {{:process, "tightbeam:retirement"}, "retirement"} ->
        if DB.Txn.q(
             txn,
             "SELECT 1 FROM sessions WHERE sessionKey=?1 AND harness=?2 AND host=?3",
             [attrs.cause_id, harness, host]
           ) == [[1]],
           do: nil,
           else: "not_authorized"

      {{:process, "tightbeam:harness-health"}, "harness_health_recovery"} ->
        if no_launch_health_fence_authorized?(txn, {harness, "shared", host}, attrs),
          do: nil,
          else: "not_authorized"

      _ ->
        "not_authorized"
    end
  end

  defp no_launch_health_fence_authorized?(
         txn,
         {harness, _preset, host},
         %{
           principal: {:process, "tightbeam:harness-health"},
           authority_basis: "harness_health_recovery",
           cause_kind: "harness_health_incident",
           cause_id: incident_id
         }
       ) do
    DB.Txn.q(
      txn,
      """
      SELECT 1 FROM harness_health_incidents
      WHERE id=?1 AND state='open' AND failureClass='rate-limit-dead'
        AND harness=?2 AND host=?3
      """,
      [incident_id, to_string(harness), host]
    ) == [[1]]
  end

  defp no_launch_health_fence_authorized?(_txn, _key, _attrs), do: false

  @doc "Create an authorized durable KILL request before any group signal."
  def request_kill(db, key, attrs) do
    :ok = ensure_schema(db)

    case DB.transaction(db, &begin_kill_in_txn(&1, key, attrs)) do
      {:ok, %{kill_request_status: "refused"} = row} ->
        {:error, %{code: row.kill_refusal_code, request_id: row.kill_request_id}}

      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        raise error
    end
  end

  @doc "Read one KILL request with its attached-session and retry-attempt audit."
  def kill_request(db \\ DB, request_id) do
    :ok = ensure_schema(db)

    with {:ok, [row]} <-
           DB.query(
             db,
             "SELECT requestId,launchId,adapterKey,osPid,processGroupId,bootIdentity,launchIdentity,principalKind,principalId,authorityBasis,causeKind,causeId,status,refusalCode,failureCode,signalResult,acceptedAt,closedAt FROM harness_kill_requests WHERE requestId=?1",
             [request_id]
           ) do
      {:ok, sessions} =
        DB.query(
          db,
          "SELECT sessionKey,lifecycleGeneration FROM harness_kill_request_sessions WHERE requestId=?1 ORDER BY sessionKey",
          [request_id]
        )

      {:ok, attempts} =
        DB.query(
          db,
          "SELECT attempt,attemptedAt,result,detail FROM harness_kill_attempts WHERE requestId=?1 ORDER BY attempt",
          [request_id]
        )

      decode_kill_request(row, sessions, attempts)
    else
      {:ok, []} -> nil
    end
  end

  def latest_kill_request(db \\ DB, key) do
    :ok = ensure_schema(db)

    case DB.query(
           db,
           "SELECT requestId FROM harness_kill_requests WHERE adapterKey=?1 ORDER BY acceptedAt DESC,rowid DESC LIMIT 1",
           [key_name(key)]
         ) do
      {:ok, [[request_id]]} -> kill_request(db, request_id)
      {:ok, []} -> nil
    end
  end

  def read_kill_request(db \\ DB, request_id, principal) do
    request = kill_request(db, request_id)
    admitted = not is_nil(request) and kill_request_visible?(db, request_id, principal)
    {kind, id} = kill_read_principal(principal)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO harness_kill_read_audits (readId,requestId,principalKind,principalId,admitted,readAt) VALUES (?1,?2,?3,?4,?5,?6)",
        ["kread_" <> Id.uuid4(), request_id, kind, id, if(admitted, do: 1, else: 0), now()]
      )

    if admitted, do: request, else: %{code: "not_found"}
  end

  defp kill_read_principal({kind, id}) when kind in [:user, :session, :process] and is_binary(id),
    do: {Atom.to_string(kind), id}

  defp kill_read_principal(_), do: {"unknown", "unknown"}

  defp kill_request_visible?(db, request_id, {:user, user}) do
    DB.query(db, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == {:ok, [[1]]} or
      match?(
        {:ok, [[1]]},
        DB.query(
          db,
          "SELECT 1 FROM harness_kill_request_sessions krs JOIN sessions s USING(sessionKey) WHERE krs.requestId=?1 AND s.ownerUserId=?2 LIMIT 1",
          [request_id, user]
        )
      )
  end

  defp kill_request_visible?(db, request_id, {:session, reader}) do
    match?(
      {:ok, [[1]]},
      DB.query(
        db,
        """
        SELECT 1
        FROM sessions reader
        LEFT JOIN session_lifecycle_states reader_lifecycle
          ON reader_lifecycle.sessionKey=reader.sessionKey
        JOIN harness_kill_request_sessions krs ON krs.requestId=?2
        JOIN sessions attached ON attached.sessionKey=krs.sessionKey
        WHERE reader.sessionKey=?1 AND reader.state='active'
          AND COALESCE(reader_lifecycle.state,'active')='active'
          AND reader.ownerUserId=attached.ownerUserId
        LIMIT 1
        """,
        [reader, request_id]
      )
    )
  end

  defp kill_request_visible?(_db, _request_id, _principal), do: false

  @doc "True only while an explicit durable kill fence stands for the key."
  @spec kill_fenced?(DB.server(), tuple()) :: boolean()
  def kill_fenced?(db, key) do
    :ok = ensure_schema(db)

    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM harness_kill_fences WHERE adapterKey = ?1", [
        key_name(key)
      ])

    count > 0
  end

  @doc "Read the explicit durable kill fence inside a caller-owned transaction."
  @spec kill_fenced_in_txn?(DB.Txn.t(), tuple()) :: boolean()
  def kill_fenced_in_txn?(%DB.Txn{} = txn, key) do
    [[count]] =
      DB.Txn.q(txn, "SELECT COUNT(*) FROM harness_kill_fences WHERE adapterKey = ?1", [
        key_name(key)
      ])

    count > 0
  end

  @doc "True while any unresolved durable launch or kill request fences the key."
  @spec fenced?(DB.server(), tuple()) :: boolean()
  def fenced?(db, key) do
    :ok = ensure_schema(db)

    {:ok, [[count]]} =
      DB.query(
        db,
        """
        SELECT
          (SELECT COUNT(*) FROM harness_processes
            WHERE adapterKey = ?1
              AND state IN ('launching','running','kill_requested','kill_failed')
              AND resolvedAt IS NULL) +
          (SELECT COUNT(*) FROM harness_kill_fences WHERE adapterKey = ?1)
        """,
        [key_name(key)]
      )

    count > 0
  end

  @doc "Release the per-key fence after the kill has reached a terminal state."
  @spec complete_kill(DB.server(), tuple()) :: :ok
  def complete_kill(db, key) do
    {:ok, :ok} = DB.transaction(db, &complete_kill_in_txn(&1, key))

    :ok
  end

  @doc "Release the kill fence as part of a caller-owned recovery transaction."
  @spec complete_kill_in_txn(DB.Txn.t(), tuple()) :: :ok
  def complete_kill_in_txn(%DB.Txn{} = txn, key) do
    DB.Txn.q(txn, "DELETE FROM harness_kill_fences WHERE adapterKey = ?1", [key_name(key)])

    :ok
  end

  @doc "Deliver SIGKILL to an authorized process group."
  @spec kill(DB.server(), row()) :: :ok | :already_resolved | {:error, term()}
  def kill(db, row) do
    with {:ok, row} <- recover_identity_until(db, row, deadline(identity_wait_ms())) do
      deliver_kill(db, row)
    else
      {:error, reason} -> unidentified(db, row, reason)
    end
  end

  @doc "Reconcile every unresolved launch left by an earlier coordinator."
  @spec reconcile(DB.server()) :: :ok
  def reconcile(db) do
    :ok = ensure_schema(db)

    Enum.each(unresolved(db), fn row ->
      :ok = ensure_fence(db, row.adapter_key)

      if reconcile_row(db, row) == :ok do
        :ok = complete_reconciled_park_name(db, row.adapter_key)
      end
    end)

    :ok = clear_orphan_fences(db)

    :ok
  end

  @doc "Reconcile the latest unresolved launch for one adapter after its BEAM owner goes down."
  @spec reconcile_key(DB.server(), tuple()) :: :ok | :already_resolved | {:error, term()}
  def reconcile_key(db, key) do
    case latest_unresolved(db, key) do
      nil ->
        :ok

      row ->
        :ok = ensure_fence(db, row.adapter_key)

        terminal_state = if row.state == "kill_requested", do: "closed_gracefully", else: "exited"

        case reconcile_row(db, row, terminal_state) do
          :ok -> complete_kill(db, key)
          :already_resolved -> :already_resolved
          {:error, _reason} = error -> error
        end
    end
  end

  @doc "Settle cleanup after the coordinator observes its current adapter instance die."
  @spec settle_proven_dead(DB.server(), tuple()) :: :ok | :already_resolved
  def settle_proven_dead(db, key) do
    :ok = ensure_schema(db)
    :ok = ensure_fence(db, key_name(key))

    result =
      case latest_unresolved(db, key) do
        nil -> :already_resolved
        row -> settle_proven_dead_row(db, row)
      end

    :ok = complete_kill(db, key)
    result
  end

  @doc "Operator-facing launch ledger, newest first."
  @spec list(DB.server()) :: [row()]
  def list(db \\ DB) do
    :ok = ensure_schema(db)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
               launchSequence, osPid, processGroupId, bootIdentity, identityToken,
               state, createdAt, killRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt,
               lastError
          FROM harness_processes ORDER BY launchSequence DESC
        """
      )

    Enum.map(rows, &decode_row/1)
  end

  defp reconcile_row(db, row, terminal_state \\ "killed") do
    with {:ok, row} <- recover_identity_until(db, row, deadline(identity_wait_ms())) do
      if reboot_orphan?(row) do
        reboot_orphan(db, row)
      else
        deliver_kill(db, row, terminal_state)
      end
    else
      {:error, reason} -> unidentified(db, row, reason)
    end
  end

  defp settle_proven_dead_row(db, row) do
    case recover_identity_until(db, row, deadline(identity_wait_ms())) do
      {:ok, recovered} ->
        if reboot_orphan?(recovered) do
          reboot_orphan(db, recovered)
        else
          case deliver_kill(db, recovered, "exited") do
            {:error, {:kill_failed, reason}} ->
              settle_cleanup_failure(db, recovered, "process_group_kill", reason)

            result ->
              result
          end
        end

      {:error, reason} ->
        settle_cleanup_failure(db, row, "identity_recovery", reason)
    end
  end

  # A recorded pid from a PREVIOUS OS BOOT names a process that cannot exist:
  # pids do not survive the kernel, so a boot-identity mismatch is proof the
  # process died with the machine — the kill's success condition, observed.
  # Before this clause, the signal helper correctly REFUSED to signal (that
  # pid may be reused by an unrelated process — the refusal is right) but the
  # refusal was recorded as kill_failed, which fences the key forever: a
  # machine reboot whose only job was recovery permanently disabled the
  # harness (gibson, 2026-08-05, fence standing since the morning's restart).
  #
  # LOCAL rows only: a remote row's boot identity belongs to the REMOTE
  # machine, and comparing it to ours would resolve a possibly-live process.
  # Remote reboot orphans keep the fence until someone reads the remote boot.
  defp reboot_orphan?(%{ssh: nil, boot_identity: recorded} = row) when is_binary(recorded) do
    case local_boot_identity(row) do
      {:ok, current} -> recorded != current
      {:error, _} -> false
    end
  end

  defp reboot_orphan?(_row), do: false

  defp reboot_orphan(db, row) do
    :ok =
      EventLog.lifecycle(
        db,
        "harness_launch_reboot_orphan",
        row.adapter_key,
        inspect(%{launch_id: row.launch_id, recorded_boot: row.boot_identity})
      )

    resolve(db, row, "exited")
  end

  # The comparison value comes from the SAME code that recorded it: the Rust
  # launcher's boot_identity(), via the helper's `boot-identity` subcommand on
  # the row's own helper_path. Deliberately NOT reimplemented in Elixir —
  # darwin's value includes st_birthtime, which the BEAM cannot read, and any
  # format drift would read live processes as reboot orphans and resolve
  # their fences. A helper that is missing or predates the subcommand answers
  # {:error, _}, and the row keeps its fence — refusal stays the default.
  defp local_boot_identity(%{helper_path: helper}) when is_binary(helper) do
    case bounded_command(helper, ["boot-identity"], command_timeout_ms()) do
      {output, 0} -> {:ok, String.trim(output)}
      {:error, :timeout} -> {:error, :boot_identity_timeout}
      {output, status} -> {:error, {:boot_identity_unavailable, status, one_line(output)}}
    end
  end

  defp local_boot_identity(_row), do: {:error, :no_helper}

  # An identity we cannot READ and a launch that never MINTED one are opposite
  # facts wearing the same error. The launcher creates the identity file before
  # it forks, so for a row that never captured a pid an absent file is the
  # launcher's own record that it never ran: no session was created, no process
  # group exists, and nothing can outlive the row. That is the kill's success
  # condition, not its failure — recorded as kill_failed it fenced the key
  # FOREVER over a process that never existed, and a crash anywhere between
  # `prepare_launch`'s INSERT and the spawn is enough to leave that row behind.
  #
  # Every other shape stays a refusal. A row that HAS a recorded pid is a
  # process we can no longer authorize a signal for, not a process we know is
  # gone; an invalid file, a read timeout, and a remote read (whose failure
  # cannot tell a missing file from an unreachable host) all keep the fence.
  # The caller's terminal state is not used: it names how the process ENDED,
  # and there was no process to kill or to close gracefully.
  defp unidentified(db, %{os_pid: nil} = row, {:identity_unavailable, :enoent}) do
    :ok =
      EventLog.lifecycle(
        db,
        "harness_launch_unlaunched",
        row.adapter_key,
        inspect(%{launch_id: row.launch_id, state: row.state})
      )

    resolve(db, row, "exited")
  end

  defp unidentified(db, row, reason), do: kill_failed(db, row, reason)

  defp deliver_kill(db, row, terminal_state \\ "killed") do
    attempted_at = now()
    request_id = open_kill_request_id(db, row)

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        DB.Txn.q(
          txn,
          "UPDATE harness_processes SET killAttemptedAt=?2 WHERE launchId=?1 AND resolvedAt IS NULL",
          [row.launch_id, attempted_at]
        )

        if request_id do
          DB.Txn.q(
            txn,
            "UPDATE harness_kill_requests SET status='accepted',closedAt=NULL,failureCode=NULL WHERE requestId=?1 AND status='kill_failed'",
            [request_id]
          )
        end

        :ok
      end)

    case send_sigkill(row) do
      :ok ->
        sent_at = now()

        record_kill_attempt(db, request_id, attempted_at, "delivered", nil)
        close_kill_request(db, request_id, "killed", "sigkill_delivered", nil)

        {:ok, _} =
          DB.query(
            db,
            "UPDATE harness_processes SET killSentAt=?2 WHERE launchId=?1 AND resolvedAt IS NULL",
            [row.launch_id, sent_at]
          )

        resolve(db, row, terminal_state)

      {:refused, reason} ->
        record_kill_attempt(db, request_id, attempted_at, "identity_mismatch", reason)
        close_kill_request(db, request_id, "refused", nil, "identity_mismatch")
        kill_failed(db, row, {:signal_refused, reason})

      {:error, reason} ->
        record_kill_attempt(db, request_id, attempted_at, "delivery_failed", inspect(reason))
        close_kill_request(db, request_id, "kill_failed", nil, nil)
        kill_failed(db, row, reason)
    end
  end

  defp send_sigkill(row) do
    case run_group_command(row, command_timeout_ms()) do
      {_output, 0} ->
        :ok

      {:error, :timeout} ->
        {:error, :sigkill_delivery_unconfirmed}

      {output, status} ->
        reason = one_line(output)

        if String.starts_with?(reason, "harness ") do
          {:refused, reason}
        else
          {:error, {:sigkill_not_delivered, status, reason}}
        end
    end
  end

  defp recover_identity_until(
         _db,
         %{
           os_pid: pid,
           process_group_id: pgid,
           boot_identity: boot_identity,
           identity_token: identity_token
         } = row,
         _deadline
       )
       when is_integer(pid) and is_integer(pgid) and is_binary(boot_identity) and
              is_binary(identity_token),
       do: {:ok, row}

  defp recover_identity_until(db, row, identity_deadline) do
    case await_identity(row, identity_deadline) do
      {:ok, pid, process_group_id, boot_identity, identity_token} ->
        :ok =
          persist_identity(
            db,
            row,
            pid,
            process_group_id,
            boot_identity,
            identity_token,
            false
          )

        {:ok,
         %{
           row
           | os_pid: pid,
             process_group_id: process_group_id,
             boot_identity: boot_identity,
             identity_token: identity_token
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_identity(row, :infinity) do
    case read_identity(row, command_timeout_ms()) do
      {:ok, _pid, _process_group_id, _boot_identity, _identity_token} = identity ->
        identity

      {:error, _reason} ->
        Process.sleep(25)
        await_identity(row, :infinity)
    end
  end

  defp await_identity(row, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    case read_identity(row, min(command_timeout_ms(), remaining_ms)) do
      {:ok, _pid, _process_group_id, _boot_identity, _identity_token} = identity ->
        identity

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          await_identity(row, deadline)
        else
          {:error, reason}
        end
    end
  end

  defp read_identity(row, timeout_ms) do
    case read_identity_file(row, timeout_ms) do
      {:ok, output} ->
        with [pid, process_group_id, boot_identity, launch_id] <-
               output |> String.trim() |> String.split("\t", parts: 4),
             {pid, ""} when pid > 0 <- Integer.parse(pid),
             {process_group_id, ""} when process_group_id > 0 <- Integer.parse(process_group_id),
             true <- pid == process_group_id,
             true <- launch_id == row.launch_id do
          {:ok, pid, process_group_id, boot_identity, launch_id}
        else
          _ -> {:error, :identity_file_invalid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_identity_file(%{ssh: nil, identity_path: path}, _timeout_ms) do
    case File.read(path) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, {:identity_unavailable, reason}}
    end
  end

  defp read_identity_file(%{ssh: destination, identity_path: path}, timeout_ms) do
    case bounded_command(
           "ssh",
           @ssh_opts ++ [destination, "cat", "--", shell_quote(path)],
           timeout_ms
         ) do
      {output, 0} -> {:ok, output}
      {:error, :timeout} -> {:error, :identity_read_timeout}
      {output, status} -> {:error, {:identity_unavailable, status, one_line(output)}}
    end
  end

  defp run_group_command(%{ssh: nil} = row, timeout_ms) do
    bounded_command(
      row.helper_path,
      ["harness-group" | group_args(row)],
      timeout_ms
    )
  end

  defp run_group_command(%{ssh: destination} = row, timeout_ms) do
    bounded_command(
      "ssh",
      @ssh_opts ++
        [
          destination,
          shell_quote(row.helper_path),
          "harness-group"
          | group_args(row)
        ],
      timeout_ms
    )
  end

  defp group_args(row) do
    [
      Integer.to_string(row.process_group_id),
      row.identity_path,
      row.boot_identity,
      row.identity_token
    ]
  end

  defp wrap_command(cmd, nil, helper_path, identity_path, launch_id) do
    [helper_path, "harness-exec", identity_path, launch_id, "--" | cmd]
  end

  defp wrap_command(["ssh" | rest], destination, helper_path, identity_path, launch_id) do
    {prefix, remote} = Enum.split_while(rest, &(&1 != destination))

    case remote do
      [^destination | remote_cmd] ->
        remote_cmd = if List.first(remote_cmd) == "exec", do: tl(remote_cmd), else: remote_cmd

        ["ssh" | prefix] ++
          [
            destination,
            "exec",
            helper_path,
            "harness-exec",
            identity_path,
            launch_id,
            "--"
            | remote_cmd
          ]

      _ ->
        raise ArgumentError, "remote harness command does not contain its SSH destination"
    end
  end

  defp bounded_command(executable, args, timeout_ms) do
    # `:spawn_executable` NEVER searches PATH -- it wants a real path and raises
    # `:enoent` for a bare name. Callers pass "ssh", so every remote identity read and
    # every remote `harness-group` failed before it was attempted, and the rescue below
    # dressed it as exit 127 with an Erlang message: it read as the SATELLITE refusing a
    # command that had in fact never left this machine. Resolving here keeps every call
    # site able to name its executable the way an operator would.
    case resolve_executable(executable) do
      {:ok, path} ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            {:args, args}
          ])

        await_command(port, [], deadline(timeout_ms))

      :error ->
        # Named as OURS, not as the remote's. The old shape blamed the far end.
        {"#{executable} is not on this gateway's PATH", 127}
    end
  rescue
    error -> {Exception.message(error), 127}
  end

  @doc false
  # Test seam. `bounded_command/3` is reachable only behind a real ssh or a real satellite
  # CLI, so the rule it depends on -- that a bare name is resolved rather than handed to a
  # spawner that cannot resolve it -- had no way to be proven. That is why the bug survived:
  # the suite was green with it.
  def resolve_executable_for_test(executable), do: resolve_executable(executable)

  defp resolve_executable(executable) do
    cond do
      # An absolute path the caller already resolved (a satellite's own CLI, say) is used
      # as given -- `find_executable` would reject it if it is not on PATH.
      String.contains?(executable, "/") ->
        if File.exists?(executable), do: {:ok, executable}, else: :error

      path = System.find_executable(executable) ->
        {:ok, path}

      true ->
        :error
    end
  end

  defp await_command(port, output, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      Port.close(port)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, bytes}} ->
          await_command(port, [bytes | output], deadline)

        {^port, {:exit_status, status}} ->
          {output |> Enum.reverse() |> IO.iodata_to_binary(), status}
      after
        remaining_ms ->
          Port.close(port)
          {:error, :timeout}
      end
    end
  end

  defp latest_unresolved(db, key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
               launchSequence, osPid, processGroupId, bootIdentity, identityToken,
               state, createdAt, killRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt,
               lastError
          FROM harness_processes
         WHERE adapterKey = ?1 AND state IN ('launching','running','kill_requested','kill_failed')
           AND resolvedAt IS NULL
         ORDER BY launchSequence DESC LIMIT 1
        """,
        [key_name(key)]
      )

    case rows do
      [row] -> decode_row(row)
      [] -> nil
    end
  end

  defp latest_unresolved_in_txn(txn, adapter_key) do
    case DB.Txn.q(
           txn,
           """
           SELECT launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
                  launchSequence, osPid, processGroupId, bootIdentity, identityToken,
                  state, createdAt, killRequestedAt,
                  killAttemptedAt, killSentAt, resolvedAt,
                  lastError
             FROM harness_processes
            WHERE adapterKey = ?1 AND state IN ('launching','running','kill_requested','kill_failed')
              AND resolvedAt IS NULL
            ORDER BY launchSequence DESC LIMIT 1
           """,
           [adapter_key]
         ) do
      [row] -> decode_row(row)
      [] -> nil
    end
  end

  defp unresolved(db) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
               launchSequence, osPid, processGroupId, bootIdentity, identityToken,
               state, createdAt, killRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt,
               lastError
          FROM harness_processes
         WHERE state IN ('launching','running','kill_requested','kill_failed')
           AND resolvedAt IS NULL
         ORDER BY launchSequence
        """
      )

    Enum.map(rows, &decode_row/1)
  end

  defp fetch!(db, launch_id) do
    {:ok, [row]} =
      DB.query(
        db,
        """
        SELECT launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
               launchSequence, osPid, processGroupId, bootIdentity, identityToken,
               state, createdAt, killRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt,
               lastError
          FROM harness_processes WHERE launchId = ?1
        """,
        [launch_id]
      )

    decode_row(row)
  end

  defp ensure_fence(db, adapter_key) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT OR IGNORE INTO harness_kill_fences (adapterKey, requestedAt) VALUES (?1, ?2)",
        [adapter_key, now()]
      )

    :ok
  end

  defp complete_reconciled_park_name(db, adapter_key) do
    incident_guard = rate_limit_incident_guard(db)

    {:ok, _} =
      DB.query(
        db,
        """
        DELETE FROM harness_kill_fences
         WHERE adapterKey = ?1
         #{incident_guard}
        """,
        [adapter_key]
      )

    :ok
  end

  defp clear_orphan_fences(db) do
    incident_guard = rate_limit_incident_guard(db)

    {:ok, _} =
      DB.query(
        db,
        """
        DELETE FROM harness_kill_fences
         WHERE NOT EXISTS (
           SELECT 1
             FROM harness_processes
            WHERE harness_processes.adapterKey = harness_kill_fences.adapterKey
              AND state IN ('launching','running','kill_requested','kill_failed')
              AND resolvedAt IS NULL
         )
         #{incident_guard}
        """
      )

    :ok
  end

  defp rate_limit_incident_guard(db) do
    if harness_health_schema?(db) do
      """
      AND NOT EXISTS (
        SELECT 1
          FROM harness_health_incidents
         WHERE state = 'open'
           AND failureClass = 'rate-limit-dead'
           AND harness || ':shared@' || host = harness_kill_fences.adapterKey
      )
      """
    else
      ""
    end
  end

  defp harness_health_schema?(db) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='harness_health_incidents'"
      )

    count == 1
  end

  defp resolve(db, row, state) do
    {:ok, resolved?} =
      DB.transaction(db, fn txn ->
        DB.Txn.q(
          txn,
          """
          UPDATE harness_processes
             SET state = ?2, resolvedAt = ?3, lastError = NULL
           WHERE launchId = ?1 AND resolvedAt IS NULL
          """,
          [row.launch_id, state, now()]
        )

        DB.Txn.changes(txn) == 1
      end)

    if resolved? do
      case remove_identity(row) do
        :ok ->
          :ok

        {:error, reason} ->
          :ok =
            EventLog.lifecycle(
              db,
              "identity_remove_failed",
              row.adapter_key,
              inspect(%{launch_id: row.launch_id, reason: reason})
            )

          :ok
      end
    else
      :already_resolved
    end
  end

  defp remove_identity(%{ssh: nil, identity_path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:identity_remove_failed, reason}}
    end
  end

  defp remove_identity(%{ssh: destination, identity_path: path}) do
    case bounded_command(
           "ssh",
           @ssh_opts ++ [destination, "rm", "-f", "--", shell_quote(path)],
           command_timeout_ms()
         ) do
      {_output, 0} -> :ok
      {:error, :timeout} -> {:error, :identity_remove_timeout}
      {output, status} -> {:error, {:identity_remove_failed, status, one_line(output)}}
    end
  end

  defp kill_failed(db, row, reason) do
    {:ok, recorded?} =
      DB.transaction(db, fn txn ->
        DB.Txn.q(
          txn,
          """
          UPDATE harness_processes
             SET state = 'kill_failed', lastError = ?2
           WHERE launchId = ?1 AND resolvedAt IS NULL
          """,
          [row.launch_id, inspect(reason)]
        )

        DB.Txn.changes(txn) == 1
      end)

    if recorded?, do: {:error, {:kill_failed, reason}}, else: :already_resolved
  end

  defp settle_cleanup_failure(db, row, phase, reason) do
    {:ok, recorded?} =
      DB.transaction(db, fn txn ->
        DB.Txn.q(
          txn,
          """
          UPDATE harness_processes
             SET state = 'exited', resolvedAt = ?2, lastError = ?3
           WHERE launchId = ?1 AND resolvedAt IS NULL
          """,
          [row.launch_id, now(), inspect(reason)]
        )

        if DB.Txn.changes(txn) == 1 do
          :ok =
            EventLog.lifecycle_in_txn(
              txn,
              "harness_cleanup_failed",
              row.adapter_key,
              inspect(%{launch_id: row.launch_id, phase: phase, reason: reason})
            )

          true
        else
          false
        end
      end)

    if recorded? do
      case remove_identity(row) do
        :ok ->
          :ok

        {:error, remove_reason} ->
          :ok =
            EventLog.lifecycle(
              db,
              "identity_remove_failed",
              row.adapter_key,
              inspect(%{launch_id: row.launch_id, reason: remove_reason})
            )

          :ok
      end
    else
      :already_resolved
    end
  end

  defp persist_identity(
         db,
         row,
         pid,
         process_group_id,
         boot_identity,
         identity_token,
         running?
       ) do
    state_update =
      if running? do
        ", state = CASE WHEN state = 'launching' THEN 'running' ELSE state END, " <>
          "lastError = CASE WHEN state = 'launching' THEN NULL ELSE lastError END"
      else
        ""
      end

    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE harness_processes
           SET osPid = ?2, processGroupId = ?3, bootIdentity = ?4,
               identityToken = ?5#{state_update}
         WHERE launchId = ?1 AND resolvedAt IS NULL
        """,
        [row.launch_id, pid, process_group_id, boot_identity, identity_token]
      )

    :ok
  end

  defp create_kill_request_in_txn(txn, row, attrs, at) do
    internal_without_org? = map_size(attrs) == 0
    attrs = normalize_kill_attrs(attrs, row)
    {principal_kind, principal_id} = kill_principal(attrs.principal)
    attached = if internal_without_org?, do: [], else: attached_sessions_in_txn(txn, row)

    # `begin_kill/2` is the pre-canonical internal fence seam used by isolated
    # lifecycle recovery. It carries no authenticated caller, so it cannot mint
    # a public KILL request. Canonical consumers call `request_kill/3`; this
    # branch preserves the existing fence/reconcile contract only.
    if internal_without_org? do
      Map.merge(row, %{
        kill_request_id: nil,
        kill_request_status: "accepted",
        kill_refusal_code: nil
      })
    else
      case matching_open_kill_request_in_txn(txn, row, attrs, principal_kind, principal_id) do
        [request_id, status] ->
          Map.merge(row, %{
            kill_request_id: request_id,
            kill_request_status: status,
            kill_refusal_code: nil
          })

        nil ->
          request_id = "kr_" <> Id.uuid4()
          record_health_recovery_decision_in_txn(txn, request_id, row, attrs, at)
          refusal = kill_authority_refusal(txn, row, attrs, attached)

          identity_refusal =
            case {row.os_pid, row.process_group_id, row.boot_identity, row.identity_token} do
              {pid, pgid, boot, launch}
              when is_integer(pid) and pid > 0 and is_integer(pgid) and pgid > 0 and
                     is_binary(boot) and is_binary(launch) ->
                nil

              _ ->
                "identity_mismatch"
            end

          create_identified_kill_request_in_txn(
            txn,
            row,
            attrs,
            attached,
            principal_kind,
            principal_id,
            request_id,
            refusal || identity_refusal,
            at
          )
      end
    end
  end

  defp matching_open_kill_request_in_txn(txn, row, attrs, principal_kind, principal_id) do
    case DB.Txn.q(
           txn,
           """
           SELECT requestId,status
           FROM harness_kill_requests
           WHERE launchId=?1 AND principalKind=?2 AND principalId=?3
             AND authorityBasis=?4 AND causeKind=?5 AND causeId=?6
             AND status IN ('accepted','kill_failed')
           ORDER BY acceptedAt DESC,rowid DESC
           LIMIT 1
           """,
           [
             row.launch_id,
             principal_kind,
             principal_id,
             attrs.authority_basis,
             attrs.cause_kind,
             attrs.cause_id
           ]
         ) do
      [request] -> request
      [] -> nil
    end
  end

  defp create_identified_kill_request_in_txn(
         txn,
         row,
         attrs,
         attached,
         principal_kind,
         principal_id,
         request_id,
         refusal,
         at
       ) do
    status = if refusal, do: "refused", else: "accepted"
    closed_at = if refusal, do: at, else: nil

    DB.Txn.q(
      txn,
      """
      INSERT INTO harness_kill_requests
        (requestId,launchId,adapterKey,osPid,processGroupId,bootIdentity,launchIdentity,
         principalKind,principalId,authorityBasis,causeKind,causeId,status,refusalCode,
         acceptedAt,closedAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)
      """,
      [
        request_id,
        row.launch_id,
        row.adapter_key,
        row.os_pid,
        row.process_group_id,
        row.boot_identity,
        row.identity_token,
        principal_kind,
        principal_id,
        attrs.authority_basis,
        attrs.cause_kind,
        attrs.cause_id,
        status,
        refusal,
        at,
        closed_at
      ]
    )

    Enum.each(attached, fn %{session_key: session_key, generation: generation} ->
      DB.Txn.q(
        txn,
        "INSERT INTO harness_kill_request_sessions (requestId,sessionKey,lifecycleGeneration) VALUES (?1,?2,?3)",
        [request_id, session_key, generation]
      )
    end)

    EventLog.lifecycle_in_txn(
      txn,
      if(refusal, do: "harness_kill_refused", else: "harness_kill_accepted"),
      request_id,
      "principal=#{principal_kind}:#{principal_id} authorityBasis=#{attrs.authority_basis} cause=#{attrs.cause_kind}:#{attrs.cause_id}" <>
        if(refusal, do: " refusal=#{refusal}", else: "")
    )

    Map.merge(row, %{
      kill_request_id: request_id,
      kill_request_status: status,
      kill_refusal_code: refusal
    })
  end

  defp open_kill_request_id(db, row) do
    case Map.get(row, :kill_request_id) do
      request_id when is_binary(request_id) ->
        request_id

      _ ->
        case DB.query(
               db,
               "SELECT requestId FROM harness_kill_requests WHERE launchId=?1 AND status IN ('accepted','kill_failed') ORDER BY acceptedAt DESC,rowid DESC LIMIT 1",
               [row.launch_id]
             ) do
          {:ok, [[request_id]]} -> request_id
          {:ok, []} -> nil
        end
    end
  end

  defp record_kill_attempt(_db, nil, _at, _result, _detail), do: :ok

  defp record_kill_attempt(db, request_id, at, result, detail) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO harness_kill_attempts (requestId,attempt,attemptedAt,result,detail) SELECT ?1,COALESCE(MAX(attempt),0)+1,?2,?3,?4 FROM harness_kill_attempts WHERE requestId=?1",
        [request_id, at, result, detail]
      )

    :ok
  end

  defp close_kill_request(_db, nil, _status, _signal_result, _refusal), do: :ok

  defp close_kill_request(db, request_id, status, signal_result, refusal) do
    {failure, refusal} =
      case status do
        "kill_failed" -> {"delivery_failed", nil}
        "refused" -> {nil, refusal}
        _ -> {nil, nil}
      end

    {:ok, _} =
      DB.query(
        db,
        "UPDATE harness_kill_requests SET status=?2,refusalCode=?3,failureCode=?4,signalResult=?5,closedAt=?6 WHERE requestId=?1 AND status IN ('accepted','kill_failed')",
        [request_id, status, refusal, failure, signal_result, now()]
      )

    :ok
  end

  defp normalize_kill_attrs(attrs, row) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    %{
      principal: Map.get(attrs, :principal, {:process, "tightbeam:harness-health"}),
      authority_basis: Map.get(attrs, :authority_basis, "harness_health_recovery"),
      cause_kind: Map.get(attrs, :cause_kind, "adapter_lifecycle"),
      cause_id: Map.get(attrs, :cause_id, row.adapter_key)
    }
  end

  defp kill_principal({:user, id}) when is_binary(id), do: {"user", id}
  defp kill_principal({:process, id}) when is_binary(id), do: {"process", id}
  defp kill_principal(_), do: {"process", "unknown"}

  defp attached_sessions_in_txn(txn, row) do
    DB.Txn.q(
      txn,
      """
      SELECT DISTINCT s.sessionKey,s.lifecycleGeneration
      FROM sessions s
      JOIN harness_pointers hp ON hp.sessionKey=s.sessionKey
      WHERE s.harness=?1 AND s.host=?2 AND s.state IN ('active','parking','parked','retired')
        AND hp.id=(SELECT MAX(hp2.id) FROM harness_pointers hp2 WHERE hp2.sessionKey=s.sessionKey)
      ORDER BY s.sessionKey
      """,
      [row.harness, row.host]
    )
    |> Enum.map(fn [session_key, generation] ->
      %{session_key: session_key, generation: generation}
    end)
  end

  defp record_health_recovery_decision_in_txn(
         txn,
         request_id,
         row,
         %{
           principal: {:process, "tightbeam:harness-health"},
           authority_basis: "harness_health_recovery",
           cause_kind: "harness_health_incident",
           cause_id: incident_id
         },
         at
       ) do
    DB.Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO harness_health_recovery_decisions
        (decisionId,incidentId,targetKind,launchId,harness,host,processGroupId,bootIdentity,
         launchIdentity,action,mode,policyBasis,evidenceObservationId,principal,createdAt)
      SELECT ?1,hhi.id,'process_group',?2,?3,?4,?5,?6,?7,'kill','immediate','rate_limit_dead',
             hhi.openObservationId,'tightbeam:harness-health',?9
      FROM harness_health_incidents hhi
      WHERE hhi.id=?8 AND hhi.state='open' AND hhi.failureClass='rate-limit-dead'
        AND hhi.harness=?3 AND hhi.host=?4
      """,
      [
        "hhrd_" <> request_id,
        row.launch_id,
        row.harness,
        row.host,
        row.process_group_id,
        row.boot_identity,
        row.identity_token,
        incident_id,
        at
      ]
    )

    :ok
  end

  defp record_health_recovery_decision_in_txn(_txn, _request_id, _row, _attrs, _at), do: :ok

  defp kill_authority_refusal(txn, row, attrs, attached) do
    attached_keys = MapSet.new(attached, & &1.session_key)

    case {attrs.principal, attrs.authority_basis} do
      {{:process, "tightbeam:harness-health"}, "harness_health_recovery"} ->
        if attrs.cause_kind == "harness_health_incident" and
             DB.Txn.q(
               txn,
               """
               SELECT 1 FROM harness_health_recovery_decisions
               WHERE incidentId=?1 AND launchId=?2 AND harness=?3 AND host=?4
                 AND targetKind='process_group'
                 AND processGroupId=?5 AND bootIdentity=?6 AND launchIdentity=?7
                 AND action='kill' AND mode='immediate' AND policyBasis='rate_limit_dead'
                 AND principal='tightbeam:harness-health'
               """,
               [
                 attrs.cause_id,
                 row.launch_id,
                 row.harness,
                 row.host,
                 row.process_group_id,
                 row.boot_identity,
                 row.identity_token
               ]
             ) == [[1]],
           do: nil,
           else: "not_authorized"

      {{:process, "tightbeam:retirement"}, "retirement"} ->
        if MapSet.member?(attached_keys, attrs.cause_id), do: nil, else: "not_authorized"

      {{:user, user}, basis} when basis in ["administrator", "operator"] ->
        if DB.Txn.q(txn, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == [[1]],
          do: nil,
          else: "not_authorized"

      {{:user, user}, "owner_user"} ->
        if Enum.any?(attached, fn %{session_key: key} ->
             DB.Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [key]) == [
               [user]
             ]
           end),
           do: nil,
           else: "not_authorized"

      _ ->
        "not_authorized"
    end
  end

  defp decode_kill_request(
         [
           request_id,
           launch_id,
           adapter_key,
           os_pid,
           pgid,
           boot,
           launch,
           principal_kind,
           principal_id,
           basis,
           cause_kind,
           cause_id,
           status,
           refusal,
           failure,
           signal_result,
           accepted_at,
           closed_at
         ],
         sessions,
         attempts
       ) do
    %{
      request_id: request_id,
      launch_id: launch_id,
      adapter_key: adapter_key,
      identity: %{os_pid: os_pid, process_group_id: pgid, boot: boot, launch: launch},
      principal: %{kind: principal_kind, id: principal_id},
      authority_basis: basis,
      cause: %{kind: cause_kind, id: cause_id},
      status: status,
      refusal_code: refusal,
      failure_code: failure,
      signal_result: signal_result,
      accepted_at: accepted_at,
      closed_at: closed_at,
      attached_sessions:
        Enum.map(sessions, fn [session_key, generation] ->
          %{session_key: session_key, lifecycle_generation: generation}
        end),
      attempts:
        Enum.map(attempts, fn [attempt, attempted_at, result, detail] ->
          %{attempt: attempt, attempted_at: attempted_at, result: result, detail: detail}
        end)
    }
  end

  defp decode_row([
         launch_id,
         adapter_key,
         harness,
         preset,
         host,
         ssh,
         helper_path,
         identity_path,
         launch_sequence,
         os_pid,
         process_group_id,
         boot_identity,
         identity_token,
         state,
         created_at,
         kill_requested_at,
         kill_attempted_at,
         kill_sent_at,
         resolved_at,
         last_error
       ]) do
    %{
      launch_id: launch_id,
      adapter_key: adapter_key,
      harness: harness,
      preset: preset,
      host: host,
      ssh: ssh,
      helper_path: helper_path,
      identity_path: identity_path,
      launch_sequence: launch_sequence,
      os_pid: os_pid,
      process_group_id: process_group_id,
      boot_identity: boot_identity,
      identity_token: identity_token,
      state: state,
      created_at: created_at,
      kill_requested_at: kill_requested_at,
      kill_attempted_at: kill_attempted_at,
      kill_sent_at: kill_sent_at,
      resolved_at: resolved_at,
      last_error: last_error
    }
  end

  defp key_name({harness, preset, host}), do: "#{harness}:#{preset}@#{host}"

  defp command_timeout_ms,
    do: Application.get_env(:tightbeam, :harness_process_command_timeout_ms, @command_timeout_ms)

  defp identity_wait_ms,
    do: Application.get_env(:tightbeam, :harness_process_identity_wait_ms, @command_timeout_ms)

  # An unbounded wait has no deadline to compute. `await_identity/2` already
  # matches `:infinity` as its own clause; adding it to a timestamp raised
  # ArithmeticError before that clause could ever be reached, so every adapter
  # boot died in `capture_identity/3`.
  defp deadline(:infinity), do: :infinity
  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp now, do: System.system_time(:millisecond)
  defp one_line(value), do: value |> String.trim() |> String.replace(~r/\s+/, " ")
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
