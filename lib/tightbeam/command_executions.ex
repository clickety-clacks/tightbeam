defmodule Tightbeam.CommandExecutions do
  @moduledoc """
  Durable evidence for one prepared host command.

  The database records intent and indexes the evidence. The detached host
  supervisor records what the kernel observed. A command is `started` only
  when the close-on-exec pipe closes without an error payload; turn or ACP
  progress is never used as a proxy for that event.

  Terminal history is retained indefinitely. Boot reconciliation selects only
  unresolved rows. A `started_unknown` row is re-examined for later durable
  receipts, but remains unknown indefinitely when no stronger evidence appears.
  """

  alias Tightbeam.{DB, Id}

  defmodule ReceiptError do
    @moduledoc false
    defexception [:message]
  end

  @ddl """
  CREATE TABLE IF NOT EXISTS command_executions (
    executionId          TEXT PRIMARY KEY,
    idempotencyKey       TEXT NOT NULL UNIQUE,
    holderSessionKey     TEXT NOT NULL,
    assignmentId         TEXT NOT NULL,
    turnIntent           TEXT NOT NULL,
    turnSeq              INTEGER,
    host                 TEXT NOT NULL,
    cwd                  TEXT NOT NULL,
    commandJson          TEXT NOT NULL,
    commandSha256        TEXT NOT NULL,
    cause                TEXT NOT NULL,
    principal            TEXT NOT NULL,
    preparedPath         TEXT NOT NULL,
    claimPath            TEXT NOT NULL,
    launcherIdentityPath TEXT NOT NULL,
    startedPath          TEXT NOT NULL,
    stdoutPath           TEXT NOT NULL,
    stderrPath           TEXT NOT NULL,
    notStartedPath       TEXT NOT NULL,
    terminalPath         TEXT NOT NULL,
    state                TEXT NOT NULL CHECK (state IN
                         ('prepared','not_started','started','finished','started_unknown')),
    osPid                INTEGER,
    processGroupId       INTEGER,
    preparedAt           INTEGER NOT NULL,
    startedAt            INTEGER,
    finishedAt           INTEGER,
    exitCode             INTEGER,
    signal               INTEGER,
    stdoutBytes          INTEGER,
    stdoutSha256         TEXT,
    stderrBytes          INTEGER,
    stderrSha256         TEXT,
    lastError            TEXT
  );
  CREATE INDEX IF NOT EXISTS command_executions_holder
    ON command_executions (holderSessionKey, preparedAt DESC);
  CREATE INDEX IF NOT EXISTS command_executions_assignment
    ON command_executions (assignmentId, preparedAt DESC);
  """

  @columns """
  executionId, idempotencyKey, holderSessionKey, assignmentId, turnIntent, turnSeq,
  host, cwd, commandJson, commandSha256, cause, principal, preparedPath, claimPath,
  launcherIdentityPath, startedPath, stdoutPath, stderrPath, notStartedPath, terminalPath,
  state, osPid, processGroupId, preparedAt, startedAt, finishedAt, exitCode, signal,
  stdoutBytes, stdoutSha256, stderrBytes, stderrSha256, lastError
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Prepare one single-use execution and its exact command receipt."
  @spec prepare(DB.server(), map()) :: map()
  def prepare(db \\ DB, attrs) do
    :ok = ensure_schema(db)
    values = prepare_values(attrs)

    result =
      case DB.transaction(db, fn txn ->
             case DB.Txn.q(
                    txn,
                    "SELECT #{@columns} FROM command_executions WHERE idempotencyKey = ?1",
                    [values.idempotency_key]
                  ) do
               [] ->
                 DB.Txn.q(
                   txn,
                   """
                   INSERT INTO command_executions
                     (executionId, idempotencyKey, holderSessionKey, assignmentId, turnIntent,
                      turnSeq, host, cwd, commandJson, commandSha256, cause, principal,
                      preparedPath, claimPath, launcherIdentityPath, startedPath, stdoutPath,
                      stderrPath, notStartedPath, terminalPath, state, preparedAt)
                   VALUES
                     (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                      ?15, ?16, ?17, ?18, ?19, ?20, 'prepared', ?21)
                   """,
                   [
                     values.execution_id,
                     values.idempotency_key,
                     values.holder_session_key,
                     values.assignment_id,
                     values.turn_intent,
                     values.turn_seq,
                     values.host,
                     values.cwd,
                     values.command_json,
                     values.command_sha256,
                     values.cause,
                     values.principal,
                     values.prepared_path,
                     values.claim_path,
                     values.launcher_identity_path,
                     values.started_path,
                     values.stdout_path,
                     values.stderr_path,
                     values.not_started_path,
                     values.terminal_path,
                     values.prepared_at
                   ]
                 )

                 {:new, values}

               [row] ->
                 existing = decode_row(row)

                 if same_intent?(existing, values) do
                   if File.exists?(existing.prepared_path) do
                     {:existing, existing}
                   else
                     raise File.Error,
                       reason: :enoent,
                       action: "read prepared receipt for existing execution",
                       path: existing.prepared_path
                   end
                 else
                   raise ArgumentError,
                         "idempotency key #{inspect(values.idempotency_key)} is already bound to another execution intent"
                 end
             end
           end) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end

    case result do
      {:existing, row} ->
        row

      {:new, values} ->
        write_json_once!(values.prepared_path, prepared_receipt(values))
        get!(db, values.execution_id)
    end
  end

  @doc "The helper command that consumes a prepared execution once."
  @spec helper_command(map(), String.t()) :: [String.t()]
  def helper_command(row, helper_path),
    do: [helper_path, "command-exec", row.prepared_path]

  @doc "Read one execution row."
  @spec get!(DB.server(), String.t()) :: map()
  def get!(db \\ DB, execution_id) do
    :ok = ensure_schema(db)

    case DB.query(
           db,
           "SELECT #{@columns} FROM command_executions WHERE executionId = ?1",
           [execution_id]
         ) do
      {:ok, [row]} -> decode_row(row)
      {:ok, []} -> raise ArgumentError, "unknown command execution #{inspect(execution_id)}"
    end
  end

  @doc "List execution evidence newest first."
  @spec list(DB.server()) :: [map()]
  def list(db \\ DB) do
    :ok = ensure_schema(db)

    {:ok, rows} =
      DB.query(db, "SELECT #{@columns} FROM command_executions ORDER BY preparedAt DESC")

    Enum.map(rows, &decode_row/1)
  end

  @doc "Record an explicit pre-launch refusal while atomically consuming the intent."
  @spec mark_not_started(DB.server(), String.t(), String.t()) :: map()
  def mark_not_started(db \\ DB, execution_id, reason) do
    row = get!(db, execution_id)

    with :ok <- claim_locally(row.claim_path),
         :ok <-
           write_json_once(row.not_started_path, %{
             executionId: execution_id,
             recordedAt: now(),
             error: reason
           }) do
      refresh(db, execution_id)
    else
      {:error, :eexist} ->
        raise ArgumentError, "command execution #{execution_id} is already consumed"

      {:error, reason} ->
        raise File.Error, reason: reason, action: "write", path: row.not_started_path
    end
  end

  @doc "Project the strongest durable receipt into the database."
  @spec refresh(DB.server(), String.t()) :: map()
  def refresh(db \\ DB, execution_id) do
    row = get!(db, execution_id)
    evidence = classify(row)
    :ok = persist_evidence(db, row, evidence)
    get!(db, execution_id)
  end

  @doc "Reconcile every prepared or non-terminal execution at gateway boot."
  @spec reconcile(DB.server()) :: :ok
  def reconcile(db \\ DB) do
    :ok = ensure_schema(db)

    unresolved(db)
    |> Enum.each(fn row ->
      try do
        maybe_settle_terminal_turn(row, db)
        reconcile_row(db, get!(db, row.execution_id))
      rescue
        error -> persist_reconciliation_error(db, row, error)
      end
    end)

    :ok
  end

  defp unresolved(db) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT #{@columns}
          FROM command_executions
         WHERE state IN ('prepared','started','started_unknown')
         ORDER BY preparedAt DESC
        """
      )

    Enum.map(rows, &decode_row/1)
  end

  defp maybe_settle_terminal_turn(%{state: "prepared", turn_seq: seq} = row, db)
       when is_integer(seq) do
    {:ok, turns} =
      DB.query(
        db,
        "SELECT 1 FROM turns WHERE seq = ?1 AND sessionKey = ?2 AND status IN ('delivered','canceled','failed','failed_unknown')",
        [seq, row.holder_session_key]
      )

    if turns == [] or receipt_exists?(row.launcher_identity_path) or
         receipt_exists?(row.started_path) do
      :ok
    else
      case claim_locally(row.claim_path) do
        :ok ->
          write_json_once!(row.not_started_path, %{
            executionId: row.execution_id,
            recordedAt: now(),
            error: "bound turn became terminal without a launcher identity"
          })

        {:error, :eexist} ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "write", path: row.claim_path
      end
    end
  end

  defp maybe_settle_terminal_turn(_row, _db), do: :ok

  defp reconcile_row(db, row) do
    case classify(row) do
      {:started, receipt} -> persist_started_unknown(db, row, receipt)
      evidence -> persist_evidence(db, row, evidence)
    end
  end

  defp classify(row) do
    terminal = read_receipt(row, row.terminal_path)
    not_started = read_receipt(row, row.not_started_path)
    started = read_receipt(row, row.started_path)
    launcher = read_receipt(row, row.launcher_identity_path)

    cond do
      terminal && not_started ->
        raise ReceiptError,
              "command execution #{row.execution_id} has conflicting terminal and not_started receipts"

      terminal && is_nil(started) ->
        raise ReceiptError,
              "command execution #{row.execution_id} has a terminal receipt without a started receipt"

      not_started && started ->
        raise ReceiptError,
              "command execution #{row.execution_id} has conflicting started and not_started receipts"

      terminal ->
        validate_terminal_evidence!(row, terminal)
        {:finished, terminal}

      not_started ->
        {:not_started, not_started}

      started && is_nil(launcher) ->
        raise ReceiptError,
              "command execution #{row.execution_id} has a started receipt without launcher identity"

      started ->
        {:started, started}

      launcher || receipt_exists?(row.claim_path) ->
        {:started_unknown, launcher || %{}}

      true ->
        {:prepared, %{}}
    end
  end

  defp persist_evidence(db, row, {state, receipt}) when state in [:prepared, :started_unknown] do
    launcher = read_receipt(row, row.launcher_identity_path) || receipt

    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE command_executions
           SET state = ?2, osPid = ?3, processGroupId = ?4, lastError = NULL
         WHERE executionId = ?1
        """,
        [row.execution_id, Atom.to_string(state), launcher["osPid"], launcher["processGroupId"]]
      )

    :ok
  end

  defp persist_evidence(db, row, {:started, receipt}) do
    launcher = read_receipt(row, row.launcher_identity_path) || %{}

    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE command_executions
           SET state = 'started', osPid = ?2, processGroupId = ?3, startedAt = ?4,
               lastError = NULL
         WHERE executionId = ?1
        """,
        [row.execution_id, receipt["osPid"], launcher["processGroupId"], receipt["startedAt"]]
      )

    :ok
  end

  defp persist_evidence(db, row, {:not_started, receipt}) do
    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE command_executions
           SET state = 'not_started', finishedAt = ?2, lastError = ?3
         WHERE executionId = ?1
        """,
        [row.execution_id, receipt["recordedAt"], receipt["error"]]
      )

    :ok
  end

  defp persist_evidence(db, row, {:finished, receipt}) do
    started = read_receipt(row, row.started_path) || %{}
    launcher = read_receipt(row, row.launcher_identity_path) || %{}

    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE command_executions
           SET state = 'finished', osPid = ?2, processGroupId = ?3, startedAt = ?4,
               finishedAt = ?5, exitCode = ?6, signal = ?7,
               stdoutBytes = ?8, stdoutSha256 = ?9,
               stderrBytes = ?10, stderrSha256 = ?11, lastError = NULL
         WHERE executionId = ?1
        """,
        [
          row.execution_id,
          started["osPid"],
          launcher["processGroupId"],
          started["startedAt"],
          receipt["finishedAt"],
          receipt["exitCode"],
          receipt["signal"],
          receipt["stdoutBytes"],
          receipt["stdoutSha256"],
          receipt["stderrBytes"],
          receipt["stderrSha256"]
        ]
      )

    :ok
  end

  defp persist_started_unknown(db, row, receipt) do
    launcher = read_receipt(row, row.launcher_identity_path) || %{}

    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE command_executions
           SET state = 'started_unknown', osPid = ?2, processGroupId = ?3,
               startedAt = ?4, lastError = NULL
         WHERE executionId = ?1
        """,
        [row.execution_id, receipt["osPid"], launcher["processGroupId"], receipt["startedAt"]]
      )

    :ok
  end

  defp persist_reconciliation_error(db, row, error) do
    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE command_executions
           SET state = 'started_unknown', lastError = ?2
         WHERE executionId = ?1
        """,
        [row.execution_id, "reconciliation refused: #{Exception.message(error)}"]
      )

    :ok
  end

  defp prepare_values(attrs) do
    command = Map.fetch!(attrs, :command)

    unless is_list(command) and command != [] and
             Enum.all?(command, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError, "command must be a non-empty list of non-empty strings"
    end

    execution_id = Map.get(attrs, :execution_id, Id.ulid())
    command_json = JSON.encode!(command)
    receipt_root = required_string!(attrs, :receipt_root)
    root = Path.join([receipt_root, "command-executions", execution_id])

    %{
      execution_id: execution_id,
      idempotency_key: required_string!(attrs, :idempotency_key),
      holder_session_key: required_string!(attrs, :holder_session_key),
      assignment_id: required_string!(attrs, :assignment_id),
      turn_intent: required_string!(attrs, :turn_intent),
      turn_seq: valid_turn_seq!(Map.get(attrs, :turn_seq)),
      host: required_string!(attrs, :host),
      cwd: required_string!(attrs, :cwd),
      command: command,
      command_json: command_json,
      command_sha256: sha256(command_json),
      cause: required_string!(attrs, :cause),
      principal: required_string!(attrs, :principal),
      prepared_path: Path.join(root, "prepared.json"),
      claim_path: Path.join(root, "claim"),
      launcher_identity_path: Path.join(root, "launcher.json"),
      started_path: Path.join(root, "started.json"),
      stdout_path: Path.join(root, "stdout"),
      stderr_path: Path.join(root, "stderr"),
      not_started_path: Path.join(root, "not_started.json"),
      terminal_path: Path.join(root, "terminal.json"),
      prepared_at: now()
    }
  end

  defp prepared_receipt(values) do
    %{
      executionId: values.execution_id,
      idempotencyKey: values.idempotency_key,
      holderSessionKey: values.holder_session_key,
      assignmentId: values.assignment_id,
      turnIntent: values.turn_intent,
      turnSeq: values.turn_seq,
      host: values.host,
      cwd: values.cwd,
      command: values.command,
      commandJson: values.command_json,
      commandSha256: values.command_sha256,
      cause: values.cause,
      principal: values.principal,
      claimPath: values.claim_path,
      launcherIdentityPath: values.launcher_identity_path,
      startedPath: values.started_path,
      stdoutPath: values.stdout_path,
      stderrPath: values.stderr_path,
      notStartedPath: values.not_started_path,
      terminalPath: values.terminal_path,
      preparedAt: values.prepared_at
    }
  end

  defp same_intent?(row, values) do
    row.holder_session_key == values.holder_session_key and
      row.assignment_id == values.assignment_id and row.turn_intent == values.turn_intent and
      row.turn_seq == values.turn_seq and row.host == values.host and row.cwd == values.cwd and
      row.command_json == values.command_json and row.command_sha256 == values.command_sha256 and
      row.cause == values.cause and row.principal == values.principal
  end

  defp required_string!(attrs, key) do
    case Map.fetch!(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end

  defp valid_turn_seq!(nil), do: nil
  defp valid_turn_seq!(value) when is_integer(value) and value > 0, do: value
  defp valid_turn_seq!(_value), do: raise(ArgumentError, "turn_seq must be a positive integer")

  defp claim_locally(path) do
    File.mkdir_p!(Path.dirname(path))

    case :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- :file.write(file, "claimed\n"),
               do: :file.sync(file)

        :ok = :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_json_once!(path, value) do
    case write_json_once(path, value) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end

  defp write_json_once(path, value) do
    File.mkdir_p!(Path.dirname(path))
    bytes = JSON.encode!(value) <> "\n"

    case :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- :file.write(file, bytes),
               do: :file.sync(file)

        :ok = :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_receipt(row, path) do
    case File.read(path) do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, receipt} when is_map(receipt) ->
            if receipt["executionId"] == row.execution_id do
              receipt
            else
              raise ReceiptError,
                    "command execution receipt at #{path} names another execution"
            end

          {:ok, _receipt} ->
            raise ReceiptError, "command execution receipt at #{path} is not a JSON object"

          {:error, reason} ->
            raise ReceiptError,
                  "command execution receipt at #{path} is invalid JSON: #{inspect(reason)}"
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: path
    end
  end

  defp validate_terminal_evidence!(row, receipt) do
    stdout = File.read!(row.stdout_path)
    stderr = File.read!(row.stderr_path)

    unless receipt["stdoutBytes"] == byte_size(stdout) and
             receipt["stdoutSha256"] == sha256(stdout) and
             receipt["stderrBytes"] == byte_size(stderr) and
             receipt["stderrSha256"] == sha256(stderr) do
      raise ReceiptError,
            "command execution #{row.execution_id} terminal output evidence does not match the captured bytes"
    end
  end

  defp receipt_exists?(path), do: File.exists?(path)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp now, do: System.system_time(:millisecond)

  defp decode_row([
         execution_id,
         idempotency_key,
         holder_session_key,
         assignment_id,
         turn_intent,
         turn_seq,
         host,
         cwd,
         command_json,
         command_sha256,
         cause,
         principal,
         prepared_path,
         claim_path,
         launcher_identity_path,
         started_path,
         stdout_path,
         stderr_path,
         not_started_path,
         terminal_path,
         state,
         os_pid,
         process_group_id,
         prepared_at,
         started_at,
         finished_at,
         exit_code,
         signal,
         stdout_bytes,
         stdout_sha256,
         stderr_bytes,
         stderr_sha256,
         last_error
       ]) do
    %{
      execution_id: execution_id,
      idempotency_key: idempotency_key,
      holder_session_key: holder_session_key,
      assignment_id: assignment_id,
      turn_intent: turn_intent,
      turn_seq: turn_seq,
      host: host,
      cwd: cwd,
      command: JSON.decode!(command_json),
      command_json: command_json,
      command_sha256: command_sha256,
      cause: cause,
      principal: principal,
      prepared_path: prepared_path,
      claim_path: claim_path,
      launcher_identity_path: launcher_identity_path,
      started_path: started_path,
      stdout_path: stdout_path,
      stderr_path: stderr_path,
      not_started_path: not_started_path,
      terminal_path: terminal_path,
      state: state,
      os_pid: os_pid,
      process_group_id: process_group_id,
      prepared_at: prepared_at,
      started_at: started_at,
      finished_at: finished_at,
      exit_code: exit_code,
      signal: signal,
      stdout_bytes: stdout_bytes,
      stdout_sha256: stdout_sha256,
      stderr_bytes: stderr_bytes,
      stderr_sha256: stderr_sha256,
      last_error: last_error
    }
  end
end
