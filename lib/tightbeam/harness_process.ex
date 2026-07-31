defmodule Tightbeam.HarnessProcess do
  @moduledoc """
  Durable identity and lifecycle for OS harness processes.

  A launch writes its row before opening the process. The launched process then
  writes its own PID and OS start time before `exec`, so later verification uses
  event-captured identity rather than a PID or command line reconstructed at
  teardown time.
  """

  alias Tightbeam.{DB, Id}

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  @ddl """
  CREATE TABLE IF NOT EXISTS harness_processes (
    launchId        TEXT PRIMARY KEY,
    adapterKey      TEXT NOT NULL,
    harness         TEXT NOT NULL,
    preset          TEXT NOT NULL,
    host             TEXT NOT NULL,
    ssh              TEXT,
    identityPath     TEXT NOT NULL,
    osPid            INTEGER,
    processStartedAt TEXT,
    state            TEXT NOT NULL CHECK (state IN
                     ('launching','running','park_requested','closed_gracefully',
                      'killed','exited','unconfirmed')),
    createdAt        INTEGER NOT NULL,
    parkRequestedAt  INTEGER,
    killSentAt       INTEGER,
    resolvedAt       INTEGER,
    lastError        TEXT
  );
  CREATE INDEX IF NOT EXISTS harness_processes_adapter_state
    ON harness_processes (adapterKey, state, createdAt);
  """

  @type row :: %{
          launch_id: String.t(),
          adapter_key: String.t(),
          harness: String.t(),
          preset: String.t(),
          host: String.t(),
          ssh: String.t() | nil,
          identity_path: String.t(),
          os_pid: pos_integer() | nil,
          process_started_at: String.t() | nil,
          state: String.t(),
          created_at: integer(),
          park_requested_at: integer() | nil,
          kill_sent_at: integer() | nil,
          resolved_at: integer() | nil,
          last_error: String.t() | nil
        }

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Insert the durable launch event and wrap the target command to record its identity."
  @spec prepare_launch(keyword(), DB.server(), tuple()) :: keyword()
  def prepare_launch(opts, db, {harness, preset, host} = key) do
    :ok = ensure_schema(db)
    launch_id = Id.ulid()
    ssh = Keyword.get(opts, :process_ssh)
    ps = Application.get_env(:tightbeam, :harness_process_ps, "ps")

    stderr_path = Keyword.get(opts, :stderr_path, "/dev/null")

    root =
      Keyword.get(opts, :process_identity_dir) || Keyword.get(opts, :home) ||
        Path.dirname(stderr_path)

    identity_path = Path.join([root, "harness-processes", launch_id <> ".identity"])
    if is_nil(ssh), do: File.mkdir_p!(Path.dirname(identity_path))

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO harness_processes
          (launchId, adapterKey, harness, preset, host, ssh, identityPath, state, createdAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'launching', ?8)
        """,
        [launch_id, key_name(key), to_string(harness), preset, host, ssh, identity_path, now()]
      )

    opts
    |> Keyword.put(:cmd, wrap_command(Keyword.fetch!(opts, :cmd), ssh, identity_path, ps))
    |> Keyword.put(:harness_process_launch_id, launch_id)
  end

  @doc "Read and persist the identity written by the launched process itself."
  @spec capture_identity(DB.server(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def capture_identity(db, launch_id, timeout_ms \\ 5_000) do
    row = fetch!(db, launch_id)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case await_identity(row, deadline) do
      {:ok, pid, started_at} ->
        {:ok, _} =
          DB.query(
            db,
            """
            UPDATE harness_processes
               SET osPid = ?2, processStartedAt = ?3, state = 'running', lastError = NULL
             WHERE launchId = ?1 AND state = 'launching'
            """,
            [launch_id, pid, started_at]
          )

        :ok

      {:error, reason} = error ->
        mark_unconfirmed(db, row, reason)
        error
    end
  end

  @doc "Atomically establish the durable park fence and return the launch it protects."
  @spec begin_park(DB.server(), tuple()) :: {:ok, row() | nil}
  def begin_park(db, key) do
    :ok = ensure_schema(db)
    at = now()

    {:ok, row} =
      DB.transaction(db, fn txn ->
        case latest_unresolved_in_txn(txn, key_name(key)) do
          nil ->
            nil

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

  @doc "True only for a durable unresolved park; normal running rows are not fences."
  @spec fenced?(DB.server(), tuple()) :: boolean()
  def fenced?(db, key) do
    :ok = ensure_schema(db)

    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM harness_processes WHERE adapterKey = ?1 AND state IN ('park_requested','unconfirmed')",
        [key_name(key)]
      )

    count > 0
  end

  @doc "Complete a park: grace, verified SIGKILL if needed, then absence confirmation."
  @spec park(DB.server(), row(), non_neg_integer()) :: :ok | {:error, term()}
  def park(db, row, grace_ms \\ 10_000) do
    row = recover_identity(db, row)

    case await_absence(row, System.monotonic_time(:millisecond) + grace_ms) do
      :absent -> resolve(db, row, "closed_gracefully")
      {:error, reason} -> unconfirmed(db, row, reason)
      :live -> kill_and_confirm(db, row)
    end
  end

  @doc "Reconcile every unresolved launch left by an earlier coordinator."
  @spec reconcile(DB.server()) :: :ok
  def reconcile(db) do
    :ok = ensure_schema(db)
    Enum.each(unresolved(db), &reconcile_row(db, &1))
    :ok
  end

  @doc "Reconcile the latest unresolved launch for one adapter after its BEAM owner goes down."
  @spec reconcile_key(DB.server(), tuple()) :: :ok | {:error, term()}
  def reconcile_key(db, key) do
    case latest_unresolved(db, key) do
      nil -> :ok
      row -> reconcile_row(db, row)
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
        SELECT launchId, adapterKey, harness, preset, host, ssh, identityPath, osPid,
               processStartedAt, state, createdAt, parkRequestedAt, killSentAt,
               resolvedAt, lastError
          FROM harness_processes ORDER BY createdAt DESC, launchId DESC
        """
      )

    Enum.map(rows, &decode_row/1)
  end

  defp reconcile_row(db, row) do
    row = recover_identity(db, row)

    case inspect_process(row) do
      :absent ->
        state = resolution_for_absence(row)
        resolve(db, row, state)

      :live ->
        kill_and_confirm(db, row)

      :zombie ->
        unconfirmed(db, row, :zombie)

      {:error, reason} ->
        unconfirmed(db, row, reason)
    end
  end

  defp kill_and_confirm(db, row) do
    with :ok <- send_sigkill(row) do
      {:ok, _} =
        DB.query(db, "UPDATE harness_processes SET killSentAt = ?2 WHERE launchId = ?1", [
          row.launch_id,
          now()
        ])

      case await_absence(row, System.monotonic_time(:millisecond) + 2_000) do
        :absent -> resolve(db, row, "killed")
        :live -> unconfirmed(db, row, :still_running_after_sigkill)
        {:error, reason} -> unconfirmed(db, row, reason)
      end
    else
      {:error, reason} -> unconfirmed(db, row, reason)
    end
  end

  defp await_absence(row, deadline) do
    case inspect_process(row) do
      :absent ->
        :absent

      :live ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          await_absence(row, deadline)
        else
          :live
        end

      :zombie ->
        {:error, :zombie}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_process(%{os_pid: nil}), do: {:error, :identity_missing}
  defp inspect_process(%{process_started_at: nil}), do: {:error, :identity_missing}

  defp inspect_process(row) do
    ps = Application.get_env(:tightbeam, :harness_process_ps, "ps")

    script = """
    started=$(#{shell_quote(ps)} -o lstart= -p "$1" 2>/dev/null) || exit 3
    state=$(#{shell_quote(ps)} -o stat= -p "$1" 2>/dev/null) || exit 3
    started=$(printf '%s' "$started" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    state=$(printf '%s' "$state" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    printf '%s\n%s\n' "$started" "$state"
    """

    case run_on_host(row, script, [Integer.to_string(row.os_pid)]) do
      {output, 0} ->
        case String.split(output, "\n", trim: true) do
          [started_at, state | _] when started_at == row.process_started_at ->
            if String.starts_with?(state, "Z"), do: :zombie, else: :live

          [_other_started_at, _state | _] ->
            :absent

          _ ->
            {:error, :identity_reply_invalid}
        end

      {_output, 3} ->
        :absent

      {output, status} ->
        {:error, {:process_inspection_failed, status, one_line(output)}}
    end
  end

  defp send_sigkill(row) do
    script = ~S|kill -9 "$1"|

    case run_on_host(row, script, [Integer.to_string(row.os_pid)]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:sigkill_failed, status, one_line(output)}}
    end
  end

  defp recover_identity(_db, %{os_pid: pid, process_started_at: started_at} = row)
       when is_integer(pid) and is_binary(started_at),
       do: row

  defp recover_identity(db, row) do
    case read_identity(row) do
      {:ok, pid, started_at} ->
        {:ok, _} =
          DB.query(
            db,
            "UPDATE harness_processes SET osPid = ?2, processStartedAt = ?3 WHERE launchId = ?1",
            [row.launch_id, pid, started_at]
          )

        %{row | os_pid: pid, process_started_at: started_at}

      {:error, _reason} ->
        row
    end
  end

  defp await_identity(row, deadline) do
    case read_identity(row) do
      {:ok, _pid, _started_at} = identity ->
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

  defp read_identity(row) do
    script = ~S|test -r "$1" && cat "$1"|

    case run_on_host(row, script, [row.identity_path]) do
      {output, 0} ->
        case output |> String.trim() |> String.split("\t", parts: 2) do
          [pid, started_at] ->
            case Integer.parse(pid) do
              {pid, ""} when pid > 0 and started_at != "" -> {:ok, pid, started_at}
              _ -> {:error, :identity_file_invalid}
            end

          _ ->
            {:error, :identity_file_invalid}
        end

      {output, status} ->
        {:error, {:identity_unavailable, status, one_line(output)}}
    end
  end

  defp run_on_host(%{ssh: nil}, script, args) do
    System.cmd("sh", ["-c", script, "tightbeam-process" | args], stderr_to_stdout: true)
  end

  defp run_on_host(%{ssh: destination}, script, args) do
    System.cmd(
      "ssh",
      @ssh_opts ++ [destination, "sh", "-c", shell_quote(script), "tightbeam-process" | args],
      stderr_to_stdout: true
    )
  end

  defp wrap_command(cmd, nil, identity_path, ps) do
    ["sh", "-c", launch_script(ps), "tightbeam-process", identity_path | cmd]
  end

  defp wrap_command(["ssh" | rest], destination, identity_path, ps) do
    {prefix, remote} = Enum.split_while(rest, &(&1 != destination))

    case remote do
      [^destination | remote_cmd] ->
        ["ssh" | prefix] ++
          [
            destination,
            "sh",
            "-c",
            shell_quote(launch_script(ps)),
            "tightbeam-process",
            identity_path
            | remote_cmd
          ]

      _ ->
        raise ArgumentError, "remote harness command does not contain its SSH destination"
    end
  end

  defp launch_script(ps) do
    """
    identity_path=$1
    shift
    started=$(#{shell_quote(ps)} -o lstart= -p "$$" 2>/dev/null) || exit 70
    started=$(printf '%s' "$started" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    test -n "$started" || exit 70
    umask 077
    mkdir -p "$(dirname "$identity_path")" || exit 70
    printf '%s\t%s\n' "$$" "$started" > "$identity_path" || exit 70
    exec "$@"
    """
  end

  defp latest_unresolved(db, key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT launchId, adapterKey, harness, preset, host, ssh, identityPath, osPid,
               processStartedAt, state, createdAt, parkRequestedAt, killSentAt,
               resolvedAt, lastError
          FROM harness_processes
         WHERE adapterKey = ?1 AND state IN ('launching','running','park_requested','unconfirmed')
         ORDER BY createdAt DESC, launchId DESC LIMIT 1
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
           SELECT launchId, adapterKey, harness, preset, host, ssh, identityPath, osPid,
                  processStartedAt, state, createdAt, parkRequestedAt, killSentAt,
                  resolvedAt, lastError
             FROM harness_processes
            WHERE adapterKey = ?1 AND state IN ('launching','running','park_requested','unconfirmed')
            ORDER BY createdAt DESC, launchId DESC LIMIT 1
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
        SELECT launchId, adapterKey, harness, preset, host, ssh, identityPath, osPid,
               processStartedAt, state, createdAt, parkRequestedAt, killSentAt,
               resolvedAt, lastError
          FROM harness_processes
         WHERE state IN ('launching','running','park_requested','unconfirmed')
         ORDER BY createdAt, launchId
        """
      )

    Enum.map(rows, &decode_row/1)
  end

  defp fetch!(db, launch_id) do
    {:ok, [row]} =
      DB.query(
        db,
        """
        SELECT launchId, adapterKey, harness, preset, host, ssh, identityPath, osPid,
               processStartedAt, state, createdAt, parkRequestedAt, killSentAt,
               resolvedAt, lastError
          FROM harness_processes WHERE launchId = ?1
        """,
        [launch_id]
      )

    decode_row(row)
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

  defp unconfirmed(db, row, reason) do
    mark_unconfirmed(db, row, reason)
    {:error, {:park_unconfirmed, reason}}
  end

  defp mark_unconfirmed(db, row, reason) do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE harness_processes SET state = 'unconfirmed', lastError = ?2 WHERE launchId = ?1",
        [row.launch_id, inspect(reason)]
      )

    :ok
  end

  defp resolution_for_absence(%{park_requested_at: at, kill_sent_at: nil}) when is_integer(at),
    do: "closed_gracefully"

  defp resolution_for_absence(%{kill_sent_at: at}) when is_integer(at), do: "killed"
  defp resolution_for_absence(_row), do: "exited"

  defp decode_row([
         launch_id,
         adapter_key,
         harness,
         preset,
         host,
         ssh,
         identity_path,
         os_pid,
         process_started_at,
         state,
         created_at,
         park_requested_at,
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
      identity_path: identity_path,
      os_pid: os_pid,
      process_started_at: process_started_at,
      state: state,
      created_at: created_at,
      park_requested_at: park_requested_at,
      kill_sent_at: kill_sent_at,
      resolved_at: resolved_at,
      last_error: last_error
    }
  end

  defp key_name({harness, preset, host}), do: "#{harness}:#{preset}@#{host}"
  defp now, do: System.system_time(:millisecond)
  defp one_line(value), do: value |> String.trim() |> String.replace(~r/\s+/, " ")
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
