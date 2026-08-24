defmodule Tightbeam.HarnessProcess do
  @moduledoc """
  Durable identity and lifecycle for OS harness processes.

  A launch writes its row before opening the process. A small POSIX launcher
  creates a new session, records its leader PID, process-group ID, boot marker,
  and per-launch token, then execs the harness. Parking authorizes that durable
  identity immediately before signalling the minted group. The row owns the
  identity file until the launch resolves to a terminal state.
  """

  alias Tightbeam.{DB, EventLog, Id}

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
  @command_timeout_ms 5_000
  @macos_lsof_path "/usr/sbin/lsof"
  # Debian/Ubuntu install lsof at /usr/bin; some distros keep the sbin legacy path.
  @linux_lsof_paths ["/usr/bin/lsof", "/usr/sbin/lsof"]
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
          boot_identity: String.t() | nil,
          identity_token: String.t() | nil,
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
               WHERE launchId = ?1 AND resolvedAt IS NULL
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
  @spec park(DB.server(), row()) :: :ok | :already_resolved | {:error, term()}
  def park(db, row) do
    with {:ok, row} <- recover_identity_until(db, row, deadline(identity_wait_ms())) do
      kill(db, row)
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
        :ok = complete_park_name(db, row.adapter_key)
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

        terminal_state = if row.state == "park_requested", do: "closed_gracefully", else: "exited"

        case reconcile_row(db, row, terminal_state) do
          :ok -> complete_park(db, key)
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

    :ok = complete_park(db, key)
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
               state, createdAt, parkRequestedAt,
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
        kill(db, row, terminal_state)
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
          case kill(db, recovered, "exited") do
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
  # process died with the machine — the park's success condition, observed.
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
  # group exists, and nothing can outlive the row. That is the park's success
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

  defp kill(db, row, terminal_state \\ "killed") do
    attempted_at = now()

    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE harness_processes
           SET killAttemptedAt = ?2
         WHERE launchId = ?1 AND resolvedAt IS NULL
        """,
        [row.launch_id, attempted_at]
      )

    case send_sigkill(row) do
      :ok ->
        sent_at = now()

        {:ok, _} =
          DB.query(
            db,
            """
            UPDATE harness_processes
               SET killSentAt = ?2
             WHERE launchId = ?1 AND resolvedAt IS NULL
            """,
            [row.launch_id, sent_at]
          )

        resolve(db, row, terminal_state)

      {:refused, reason} ->
        kill_failed(db, row, {:signal_refused, reason})

      {:error, reason} ->
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

  @doc """
  Assert the launched process group holds ZERO TCP LISTEN sockets (rails-critical launch
  invariant 3), for a harness in the `:shim` class (`Harness.requires_zero_listeners?/1`).

  Fail-closed: any LISTEN socket in the group, or a probe that cannot conclude, is `{:error, _}`
  and the caller refuses the launch. It samples a SETTLE WINDOW rather than once — captured live,
  `opencode acp` v1.18.18 binds an HTTP server on 127.0.0.1:4096 roughly 0.3–1.1s after spawn (see
  EVIDENCE/RAILS-FINDING-acp-http-listener.md), so a single point-in-time probe races the bind;
  the caller (`Acp.Adapter`) runs this only AFTER `initialize` returns, by which point the harness
  has booted. A running process's sockets are observable only at runtime, so a runtime assert is
  as structural as invariant 3 can be. HONEST RESIDUAL: neither a settle window nor a
  post-initialize probe can catch a listener bound strictly later — that gap is for the go-live
  adjudication. Local macOS host only for now; other operating systems and the remote probe are
  refused with named errors.
  """
  @spec assert_zero_listeners(DB.server(), String.t(), (integer() -> tuple())) ::
          :ok | {:error, term()}
  def assert_zero_listeners(db, launch_id, run \\ &lsof_listen_probe/1) do
    case fetch!(db, launch_id) do
      %{ssh: nil, process_group_id: pgid} when is_integer(pgid) ->
        case listener_probe(pgid, run) do
          {:ok, []} -> :ok
          {:ok, listeners} -> {:error, {:listeners_present, listeners}}
          {:error, reason} -> {:error, {:listener_probe_failed, reason}}
        end

      %{ssh: ssh} when not is_nil(ssh) ->
        {:error, :remote_listener_probe_unimplemented}

      _ ->
        {:error, :no_process_group_id}
    end
  end

  # Sample the process group's LISTEN sockets across a short SETTLE WINDOW, not once — a listener
  # can still be landing when the first sample runs (OpenCode's :4096 binds ~0.3–1.1s post-spawn).
  # ANY sample showing a listener fails immediately; an inconclusive sample (lsof error) fails
  # closed. All-empty across the window is the zero-listener pass. The window shrinks — never
  # eliminates — the late-bind race (see `assert_zero_listeners/2`).
  @listener_settle_samples 4
  @listener_settle_interval_ms 150

  defp listener_probe(pgid, run) do
    Enum.reduce_while(1..@listener_settle_samples, {:ok, []}, fn i, _acc ->
      case listener_sample(pgid, run) do
        {:ok, []} ->
          if i < @listener_settle_samples, do: Process.sleep(@listener_settle_interval_ms)
          {:cont, {:ok, []}}

        {:ok, _listeners} = present ->
          {:halt, present}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # The real probe (injectable for tests): `lsof -nP -a -g <pgid> -iTCP -sTCP:LISTEN -Fn` — the
  # LISTEN TCP sockets held by ANY process in the launched process group. Returns the runner's
  # `{output, status}` (or `{:error, :timeout}`) for `listener_sample/2` to classify.
  defp lsof_listen_probe(pgid) do
    # This runs in the gateway daemon, whose deliberately small PATH does not
    # include the sbin directories. Use absolute system paths per platform: an
    # unavailable probe must fail closed, but a PATH omission is not evidence
    # of a listener. Both supported platforms (darwin-aarch64, linux-x86_64)
    # resolve here; anything else is honestly unsupported.
    case :os.type() do
      {:unix, :darwin} ->
        lsof_listen_probe(pgid, @macos_lsof_path)

      {:unix, :linux} ->
        case Enum.find(@linux_lsof_paths, &match?({:ok, _}, lsof_executable(&1))) do
          nil -> {:error, {:lsof_executable_absent, @linux_lsof_paths}}
          path -> lsof_listen_probe(pgid, path)
        end

      _other ->
        {:error, :listener_probe_unsupported_os}
    end
  end

  defp lsof_listen_probe(pgid, lsof_path) do
    args = ["-nP", "-a", "-g", Integer.to_string(pgid), "-iTCP", "-sTCP:LISTEN", "-Fn"]

    with {:ok, executable} <- lsof_executable(lsof_path) do
      bounded_command(executable, args, 5_000)
    end
  end

  defp lsof_executable(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
        {:ok, path}

      {:ok, _stat} ->
        {:error, {:lsof_not_executable, path}}

      {:error, :enoent} ->
        {:error, {:lsof_executable_absent, path}}

      {:error, reason} ->
        {:error, {:lsof_executable_unavailable, path, reason}}
    end
  end

  @doc false
  def lsof_listen_probe_for_test(pgid, path \\ @macos_lsof_path),
    do: lsof_listen_probe(pgid, path)

  # `-a` ANDs the pgid and socket-state filters; `-Fn` prints one field per line, so a socket name
  # is an `n`-prefixed line. An empty selection is lsof exit 1 with no output — the zero-listener
  # case. A status outside {0,1}, or an `lsof:` diagnostic, is an inconclusive probe and fails
  # closed.
  defp listener_sample(pgid, run) do
    case run.(pgid) do
      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}

      {output, status} when status in [0, 1] ->
        lines = String.split(output, "\n", trim: true)

        cond do
          Enum.any?(lines, &String.starts_with?(&1, "lsof:")) ->
            {:error, {:lsof_diagnostic, one_line(output)}}

          true ->
            {:ok, Enum.filter(lines, &String.starts_with?(&1, "n"))}
        end

      {output, status} ->
        {:error, {:lsof_failed, status, one_line(output)}}
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
               state, createdAt, parkRequestedAt,
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
                  launchSequence, osPid, processGroupId, bootIdentity, identityToken,
                  state, createdAt, parkRequestedAt,
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
               launchSequence, osPid, processGroupId, bootIdentity, identityToken,
               state, createdAt, parkRequestedAt,
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
               launchSequence, osPid, processGroupId, bootIdentity, identityToken,
               state, createdAt, parkRequestedAt,
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

  defp clear_orphan_fences(db) do
    {:ok, _} =
      DB.query(
        db,
        """
        DELETE FROM harness_park_fences
         WHERE NOT EXISTS (
           SELECT 1
             FROM harness_processes
            WHERE harness_processes.adapterKey = harness_park_fences.adapterKey
              AND state IN ('launching','running','park_requested','kill_failed')
              AND resolvedAt IS NULL
         )
        """
      )

    :ok
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
      boot_identity: boot_identity,
      identity_token: identity_token,
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
