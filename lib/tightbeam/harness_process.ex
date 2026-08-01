defmodule Tightbeam.HarnessProcess do
  @moduledoc """
  Durable identity and lifecycle for OS harness processes.

  A launch writes its row before opening the process. A small POSIX launcher
  creates a new session, records its process-group ID, then execs the harness.
  Parking targets that minted group, not one member of the tree.
  """

  alias Tightbeam.{DB, Id}

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
  @command_timeout_ms 5_000

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
    state            TEXT NOT NULL CHECK (state IN
                     ('launching','running','park_requested','closed_gracefully',
                      'killed','kill_failed','exited')),
    createdAt        INTEGER NOT NULL,
    parkRequestedAt  INTEGER,
    killAttemptedAt  INTEGER,
    killSentAt       INTEGER,
    resolvedAt       INTEGER,
    lastError        TEXT
  );
  """

  @ddl """
  #{@process_ddl}
  CREATE TABLE IF NOT EXISTS harness_park_fences (
    adapterKey       TEXT PRIMARY KEY,
    requestedAt      INTEGER NOT NULL
  );
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
          state: String.t(),
          created_at: integer(),
          park_requested_at: integer() | nil,
          kill_attempted_at: integer() | nil,
          kill_sent_at: integer() | nil,
          resolved_at: integer() | nil,
          last_error: String.t() | nil
        }

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    :ok = DB.execute(db, @ddl)

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        names = MapSet.new(DB.Txn.q(txn, "PRAGMA table_info(harness_processes)"), &Enum.at(&1, 1))

        for {name, declaration} <- [
              {"helperPath", "TEXT"},
              {"processGroupId", "INTEGER"},
              {"launchSequence", "INTEGER"},
              {"killAttemptedAt", "INTEGER"}
            ],
            not MapSet.member?(names, name) do
          DB.Txn.exec(txn, "ALTER TABLE harness_processes ADD COLUMN #{name} #{declaration}")
        end

        DB.Txn.q(
          txn,
          "UPDATE harness_processes SET launchSequence = rowid WHERE launchSequence IS NULL"
        )

        [[table_sql]] =
          DB.Txn.q(txn, "SELECT sql FROM sqlite_master WHERE name = 'harness_processes'")

        if String.contains?(table_sql, "'unconfirmed'") do
          DB.Txn.exec(txn, "ALTER TABLE harness_processes RENAME TO harness_processes_previous")
          DB.Txn.exec(txn, @process_ddl)

          DB.Txn.exec(
            txn,
            """
            INSERT INTO harness_processes
              (launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
               launchSequence, osPid, processGroupId, state, createdAt, parkRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt, lastError)
            SELECT launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
                   launchSequence, osPid, processGroupId,
                   CASE state WHEN 'unconfirmed' THEN 'kill_failed' ELSE state END,
                   createdAt, parkRequestedAt, killAttemptedAt, killSentAt, resolvedAt,
                   lastError
              FROM harness_processes_previous
            """
          )

          DB.Txn.exec(txn, "DROP TABLE harness_processes_previous")
        end

        :ok
      end)

    :ok =
      DB.execute(
        db,
        "CREATE INDEX IF NOT EXISTS harness_processes_adapter_launch_sequence ON harness_processes (adapterKey, state, launchSequence)"
      )

    :ok
  end

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
                     AND state IN ('launching','running','park_requested','kill_failed')
                     AND resolvedAt IS NULL
                  UNION ALL
                  SELECT 1 FROM harness_park_fences WHERE adapterKey = ?1
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
      {:ok, :fenced} -> raise "adapter park in progress for #{key_name(key)}"
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
      {:ok, process_group_id} ->
        :ok = persist_identity(db, row, process_group_id, true)

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Atomically establish the durable park fence and return the launch it protects."
  @spec begin_park(DB.server(), tuple()) :: {:ok, row() | :no_launch}
  def begin_park(db, key) do
    :ok = ensure_schema(db)
    at = now()

    {:ok, row} =
      DB.transaction(db, fn txn ->
        DB.Txn.q(
          txn,
          "INSERT OR IGNORE INTO harness_park_fences (adapterKey, requestedAt) VALUES (?1, ?2)",
          [key_name(key), at]
        )

        case latest_unresolved_in_txn(txn, key_name(key)) do
          nil ->
            :no_launch

          row ->
            DB.Txn.q(
              txn,
              """
              UPDATE harness_processes
                 SET state = 'park_requested', parkRequestedAt = COALESCE(parkRequestedAt, ?2)
               WHERE launchId = ?1
              """,
              [row.launch_id, at]
            )

            %{row | state: "park_requested", park_requested_at: row.park_requested_at || at}
        end
      end)

    {:ok, row}
  end

  @doc "True while any unresolved durable launch or park request fences the key."
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
              AND state IN ('launching','running','park_requested','kill_failed')
              AND resolvedAt IS NULL) +
          (SELECT COUNT(*) FROM harness_park_fences WHERE adapterKey = ?1)
        """,
        [key_name(key)]
      )

    count > 0
  end

  @doc "Release the per-key fence after the park has reached a terminal state."
  @spec complete_park(DB.server(), tuple()) :: :ok
  def complete_park(db, key) do
    {:ok, _} =
      DB.query(db, "DELETE FROM harness_park_fences WHERE adapterKey = ?1", [key_name(key)])

    :ok
  end

  @doc "Deliver SIGKILL to a parked process group."
  @spec park(DB.server(), row()) :: :ok | {:error, term()}
  def park(db, row) do
    with {:ok, row} <- recover_identity_until(db, row, deadline(identity_wait_ms())) do
      kill(db, row)
    else
      {:error, reason} -> kill_failed(db, row, reason)
    end
  end

  @doc "Reconcile every unresolved launch left by an earlier coordinator."
  @spec reconcile(DB.server()) :: :ok
  def reconcile(db) do
    :ok = ensure_schema(db)

    Enum.each(unresolved(db), fn row ->
      :ok = ensure_fence(db, row.adapter_key)

      if reconcile_row(db, row) == :ok do
        :ok = complete_park_name(db, row.adapter_key)
      end
    end)

    :ok
  end

  @doc "Reconcile the latest unresolved launch for one adapter after its BEAM owner goes down."
  @spec reconcile_key(DB.server(), tuple()) :: :ok | {:error, term()}
  def reconcile_key(db, key) do
    case latest_unresolved(db, key) do
      nil ->
        :ok

      row ->
        :ok = ensure_fence(db, row.adapter_key)

        result =
          resolve(
            db,
            row,
            if(row.state == "park_requested", do: "closed_gracefully", else: "exited")
          )

        if result == :ok, do: complete_park(db, key)
        result
    end
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
               launchSequence, osPid, processGroupId, state, createdAt, parkRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt,
               lastError
          FROM harness_processes ORDER BY launchSequence DESC
        """
      )

    Enum.map(rows, &decode_row/1)
  end

  defp reconcile_row(db, row) do
    with {:ok, row} <- recover_identity_until(db, row, deadline(identity_wait_ms())) do
      kill(db, row)
    else
      {:error, reason} -> kill_failed(db, row, reason)
    end
  end

  defp kill(db, row) do
    attempted_at = now()

    {:ok, _} =
      DB.query(db, "UPDATE harness_processes SET killAttemptedAt = ?2 WHERE launchId = ?1", [
        row.launch_id,
        attempted_at
      ])

    case send_sigkill(row) do
      :ok ->
        sent_at = now()

        {:ok, _} =
          DB.query(db, "UPDATE harness_processes SET killSentAt = ?2 WHERE launchId = ?1", [
            row.launch_id,
            sent_at
          ])

        resolve(db, row, "killed")

      {:error, reason} ->
        kill_failed(db, row, reason)
    end
  end

  defp send_sigkill(row) do
    case run_group_command(row, command_timeout_ms()) do
      {_output, 0} -> :ok
      {:error, :timeout} -> {:error, :sigkill_timeout}
      {output, status} -> {:error, {:sigkill_failed, status, one_line(output)}}
    end
  end

  defp recover_identity_until(
         _db,
         %{process_group_id: pgid} = row,
         _deadline
       )
       when is_integer(pgid),
       do: {:ok, row}

  defp recover_identity_until(db, row, identity_deadline) do
    case await_identity(row, identity_deadline) do
      {:ok, process_group_id} ->
        :ok = persist_identity(db, row, process_group_id, false)

        {:ok,
         %{
           row
           | os_pid: process_group_id,
             process_group_id: process_group_id
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_identity(row, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    case read_identity(row, min(command_timeout_ms(), remaining_ms)) do
      {:ok, _process_group_id} = identity ->
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
        with {process_group_id, ""} when process_group_id > 0 <-
               output |> String.trim() |> Integer.parse() do
          {:ok, process_group_id}
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
      ["harness-group", Integer.to_string(row.process_group_id)],
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
          "harness-group",
          Integer.to_string(row.process_group_id)
        ],
      timeout_ms
    )
  end

  defp wrap_command(cmd, nil, helper_path, identity_path, _launch_id) do
    [helper_path, "harness-exec", identity_path, "--" | cmd]
  end

  defp wrap_command(["ssh" | rest], destination, helper_path, identity_path, _launch_id) do
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
            "--"
            | remote_cmd
          ]

      _ ->
        raise ArgumentError, "remote harness command does not contain its SSH destination"
    end
  end

  defp bounded_command(executable, args, timeout_ms) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, args}
      ])

    await_command(port, [], deadline(timeout_ms))
  rescue
    error -> {Exception.message(error), 127}
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
               launchSequence, osPid, processGroupId, state, createdAt, parkRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt,
               lastError
          FROM harness_processes
         WHERE adapterKey = ?1 AND state IN ('launching','running','park_requested','kill_failed')
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
                  launchSequence, osPid, processGroupId, state, createdAt, parkRequestedAt,
                  killAttemptedAt, killSentAt, resolvedAt,
                  lastError
             FROM harness_processes
            WHERE adapterKey = ?1 AND state IN ('launching','running','park_requested','kill_failed')
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
               launchSequence, osPid, processGroupId, state, createdAt, parkRequestedAt,
               killAttemptedAt, killSentAt, resolvedAt,
               lastError
          FROM harness_processes
         WHERE state IN ('launching','running','park_requested','kill_failed')
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
               launchSequence, osPid, processGroupId, state, createdAt, parkRequestedAt,
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
        "INSERT OR IGNORE INTO harness_park_fences (adapterKey, requestedAt) VALUES (?1, ?2)",
        [adapter_key, now()]
      )

    :ok
  end

  defp complete_park_name(db, adapter_key) do
    {:ok, _} =
      DB.query(db, "DELETE FROM harness_park_fences WHERE adapterKey = ?1", [adapter_key])

    :ok
  end

  defp resolve(db, row, state) do
    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE harness_processes
           SET state = ?2, resolvedAt = ?3, lastError = NULL
         WHERE launchId = ?1
        """,
        [row.launch_id, state, now()]
      )

    :ok
  end

  defp kill_failed(db, row, reason) do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE harness_processes SET state = 'kill_failed', lastError = ?2 WHERE launchId = ?1",
        [row.launch_id, inspect(reason)]
      )

    {:error, {:kill_failed, reason}}
  end

  defp persist_identity(
         db,
         row,
         process_group_id,
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
        "UPDATE harness_processes SET osPid = ?2, processGroupId = ?2#{state_update} WHERE launchId = ?1",
        [row.launch_id, process_group_id]
      )

    :ok
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
         state,
         created_at,
         park_requested_at,
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
      state: state,
      created_at: created_at,
      park_requested_at: park_requested_at,
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

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp now, do: System.system_time(:millisecond)
  defp one_line(value), do: value |> String.trim() |> String.replace(~r/\s+/, " ")
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
