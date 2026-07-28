defmodule Tightbeam.Producers do
  @moduledoc "Durable asynchronous mechanical verdict producers."

  alias Tightbeam.{Assignments, DB, Devices, EventLog, Org, Placement}
  alias Tightbeam.DB.Txn

  @persist_key __MODULE__
  @allowed_config_keys MapSet.new(["tests", "smoke", "timeout_ms"])
  @default_timeout_ms 600_000

  @ddl """
  CREATE TABLE IF NOT EXISTS producer_jobs (
    id TEXT PRIMARY KEY,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    kind TEXT NOT NULL,
    command TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('queued','running','done','failed','cancelled')),
    bySession TEXT NULL,
    byUser TEXT NULL,
    byHarness TEXT NULL,
    byProvider TEXT NULL,
    timeoutMs INTEGER NOT NULL,
    startedAt INTEGER NULL
  )
  """

  @producer_shapes %{
    "run-tests" => %{kind: "tests", producer: "build", verdict_kind: "tests-passed"},
    "run-smoke" => %{kind: "smoke", producer: "smoke", verdict_kind: "real-run-passed"}
  }

  @doc "Create the durable producer job table."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Load and validate the committed identity/producers.toml. A missing file is empty."
  @spec load!(String.t()) :: map()
  def load!(base_dir) do
    identity_dir = Path.join(base_dir, "identity")
    path = Path.join(identity_dir, "producers.toml")

    config =
      case committed_config(identity_dir) do
        :missing ->
          %{timeout_ms: @default_timeout_ms}

        {:ok, encoded} ->
          manifest =
            case Toml.decode(encoded) do
              {:ok, decoded} -> decoded
              {:error, error} -> raise ArgumentError, "#{path}: invalid TOML: #{inspect(error)}"
            end

          unknown =
            manifest |> Map.keys() |> MapSet.new() |> MapSet.difference(@allowed_config_keys)

          if MapSet.size(unknown) != 0 do
            raise ArgumentError,
                  "#{path}: unknown keys: #{unknown |> Enum.sort() |> Enum.join(", ")}"
          end

          tests = validate_command!(path, "tests", manifest["tests"])
          smoke = validate_command!(path, "smoke", manifest["smoke"])
          timeout_ms = Map.get(manifest, "timeout_ms", @default_timeout_ms)

          unless is_integer(timeout_ms) do
            raise ArgumentError, "#{path}: timeout_ms must be an integer"
          end

          %{tests: tests, smoke: smoke, timeout_ms: timeout_ms}
      end

    :persistent_term.put(@persist_key, config)
    config
  end

  @doc "The boot-loaded producer registry."
  @spec config() :: map()
  def config, do: :persistent_term.get(@persist_key, %{timeout_ms: @default_timeout_ms})

  @doc false
  def __handle__(db, verb, call, opts \\ [])

  def __handle__(db, verb, call, opts) when verb in ["run-tests", "run-smoke"] do
    accept(db, Map.fetch!(@producer_shapes, verb), call, opts)
  end

  def __handle__(db, "cancel-producer-job", call, opts) do
    cancel(db, call, opts)
  end

  @doc "Cancel every active job held by a retiring session through the shared CAS path."
  @spec cancel_for_holder(DB.server(), String.t(), keyword()) :: :ok
  def cancel_for_holder(db, holder_session, opts \\ []) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT p.id FROM producer_jobs AS p JOIN assignments AS a ON a.id = p.assignmentId WHERE a.holderKey = ?1 AND p.state IN ('queued','running')",
        [holder_session]
      )

    Enum.each(rows, fn [job_id] -> cancel_transition(db, job_id, opts) end)
    :ok
  end

  @doc false
  def recover(db) do
    {:ok, orphaned} =
      DB.transaction(db, fn txn ->
        rows =
          Txn.q(
            txn,
            "SELECT id, assignmentId, kind, command FROM producer_jobs WHERE state = 'running'"
          )

        Enum.flat_map(rows, fn [id, assignment_id, kind, command] ->
          Txn.q(
            txn,
            "UPDATE producer_jobs SET state = 'failed' WHERE id = ?1 AND state = 'running'",
            [id]
          )

          if Txn.changes(txn) == 1, do: [[id, assignment_id, kind, command]], else: []
        end)
      end)

    Enum.each(orphaned, fn [id, assignment_id, kind, command] ->
      producer_failed(db, assignment_id, id, kind, command, "orphaned")
    end)

    :ok
  end

  @doc false
  def claim_next(db) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        case Txn.q(
               txn,
               "SELECT #{job_columns()} FROM producer_jobs WHERE state = 'queued' ORDER BY rowid LIMIT 1"
             ) do
          [] ->
            nil

          [row] ->
            job = job(row)

            Txn.q(
              txn,
              "UPDATE producer_jobs SET state = 'running', startedAt = ?2 WHERE id = ?1 AND state = 'queued'",
              [job.id, now()]
            )

            if Txn.changes(txn) == 1, do: %{job | state: "running", started_at: now()}, else: nil
        end
      end)

    result
  end

  @doc false
  def execute(db, config, job, runner) do
    result =
      with %{holder_key: holder_key} <- assignment_holder(db, job.assignment_id),
           %{} = holder <- Org.get(db, holder_key),
           :ok <- local_holder(config, holder),
           workdir <- Placement.holder_workdir(config, holder) do
        run_local(db, job, workdir, runner)
      else
        nil -> {:error, "host-fail: holder unavailable"}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, 0} -> finish_success(db, job)
      {:ok, status} -> finish_failure(db, job, "exit #{status}")
      {:error, reason} -> finish_failure(db, job, reason)
    end
  rescue
    error -> finish_failure(db, job, "host-fail: #{Exception.message(error)}")
  after
    Tightbeam.ProducerRunner.unregister_process(runner, job.id)
  end

  @doc false
  def fail_running(db, job_id, reason) do
    case get(db, job_id) do
      %{state: "running"} = job -> finish_failure(db, job, reason)
      _ -> :noop
    end
  end

  @doc false
  def get(db, id) do
    {:ok, rows} = DB.query(db, "SELECT #{job_columns()} FROM producer_jobs WHERE id = ?1", [id])

    case rows do
      [row] -> job(row)
      [] -> nil
    end
  end

  defp accept(db, shape, call, opts) do
    with :ok <- allowed_principal(call.principal) do
      producer_config = Keyword.get(opts, :config, config())
      command = Map.get(producer_config, String.to_atom(shape.kind))
      timeout_ms = Map.fetch!(producer_config, :timeout_ms)

      {:ok, result} =
        DB.transaction(db, fn txn ->
          assignment_id = call.params[:assignment_id]

          case assignment_state(txn, assignment_id) do
            nil ->
              error("unknown_assignment", "unknown assignment: #{assignment_id}")

            state when state != "open" ->
              error("assignment_closed", "assignment is already closed")

            "open" ->
              if is_binary(command) do
                case active_job(txn, assignment_id, shape.kind) do
                  nil ->
                    insert_job(
                      txn,
                      assignment_id,
                      shape,
                      command,
                      timeout_ms,
                      call.principal
                    )

                  id ->
                    %{queued: id}
                end
              else
                error("producer_unconfigured", "producer #{shape.kind} is not configured")
              end
          end
        end)

      if Map.has_key?(result, :queued), do: nudge(Keyword.get(opts, :runner), result.queued)

      if result[:code] == "producer_unconfigured" do
        producer_failed(
          db,
          call.params[:assignment_id],
          nil,
          shape.kind,
          nil,
          "producer_unconfigured"
        )
      end

      result
    else
      %{code: _} = denied ->
        denied
    end
  end

  defp cancel(db, call, opts) do
    with :ok <- allowed_principal(call.principal),
         %{} = job <- get(db, call.params[:job_id]),
         :ok <- cancel_allowed(db, call.principal, job.assignment_id) do
      case cancel_transition(db, job.id, opts) do
        :cancelled -> %{cancelled: job.id}
        :noop -> %{cancelled: job.id, noop: true}
      end
    else
      nil -> error("unknown_producer_job", "unknown producer job")
      %{code: _} = denied -> denied
    end
  end

  defp cancel_transition(db, job_id, opts) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        case Txn.q(
               txn,
               "SELECT assignmentId, kind, command, state FROM producer_jobs WHERE id = ?1",
               [job_id]
             ) do
          [[assignment_id, kind, command, prior]] ->
            Txn.q(
              txn,
              "UPDATE producer_jobs SET state = 'cancelled' WHERE id = ?1 AND state IN ('queued','running')",
              [job_id]
            )

            if Txn.changes(txn) == 1,
              do: {:cancelled, prior, assignment_id, kind, command},
              else: :noop

          [] ->
            :noop
        end
      end)

    case result do
      {:cancelled, prior, assignment_id, kind, command} ->
        if prior == "running", do: kill(Keyword.get(opts, :runner), job_id)
        producer_failed(db, assignment_id, job_id, kind, command, "cancelled")
        :cancelled

      :noop ->
        :noop
    end
  end

  defp finish_success(db, job) do
    case DB.transaction(db, fn txn ->
           Txn.q(
             txn,
             "UPDATE producer_jobs SET state = 'done' WHERE id = ?1 AND state = 'running'",
             [job.id]
           )

           if Txn.changes(txn) == 1 do
             {:ok, _} =
               Assignments.insert_producer_verdict_in_txn(txn, %{
                 assignment_id: job.assignment_id,
                 verdict_kind: job.verdict_kind,
                 producer: job.producer,
                 producer_command: job.command,
                 by_session: job.by_session,
                 by_user: job.by_user,
                 by_harness: job.by_harness,
                 by_provider: job.by_provider
               })

             :done
           else
             :noop
           end
         end) do
      {:ok, result} -> result
      {:error, error} -> finish_failure(db, job, "verdict-fail: #{Exception.message(error)}")
    end
  end

  defp finish_failure(db, job, reason) do
    {:ok, won?} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE producer_jobs SET state = 'failed' WHERE id = ?1 AND state = 'running'",
          [job.id]
        )

        Txn.changes(txn) == 1
      end)

    if won?, do: producer_failed(db, job.assignment_id, job.id, job.kind, job.command, reason)
    if won?, do: :failed, else: :noop
  end

  defp run_local(db, job, workdir, runner) do
    shell = System.find_executable("sh") || "/bin/sh"
    env = minimal_env(workdir)

    port =
      Port.open(
        {:spawn_executable, shell},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args,
           [
             "-c",
             "kill -STOP $$; exec \"$1\" -lc \"$2\"",
             "tightbeam-producer",
             shell,
             job.command
           ]},
          {:cd, workdir},
          {:env, env}
        ]
      )

    os_pid = port |> Port.info(:os_pid) |> elem(1)
    # Capture identity while the group is still STOPped, before anything can
    # signal it — this is the value every later signal is checked against.
    started = process_started(os_pid)

    with :ok <- verify_process_group(os_pid),
         :ok <-
           Tightbeam.ProducerRunner.register_process(runner, job.id, port, os_pid, started),
         :ok <- continue_process_group(os_pid) do
      await_exit(
        db,
        job.id,
        port,
        System.monotonic_time(:millisecond) + job.timeout_ms,
        os_pid,
        started
      )
    else
      :cancelled ->
        kill_port(db, job.id, port, os_pid, started)
        {:error, "cancelled"}

      {:error, reason} ->
        kill_process(db, job.id, port, os_pid, started)
        {:error, reason}
    end
  end

  defp await_exit(db, job_id, port, deadline, process_group, started) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _output}} ->
        await_exit(db, job_id, port, deadline, process_group, started)

      {^port, {:exit_status, status}} ->
        {:ok, status}

      {^port, :closed} ->
        {:error, "cancelled"}
    after
      remaining ->
        kill_port(db, job_id, port, process_group, started)
        {:error, "timeout"}
    end
  end

  defp minimal_env(workdir) do
    inherited = for key <- Map.keys(System.get_env()), do: {String.to_charlist(key), false}
    path = System.get_env("PATH") || "/usr/bin:/bin"

    inherited ++
      [
        {~c"HOME", String.to_charlist(workdir)},
        {~c"PATH", String.to_charlist(path)}
      ]
  end

  defp kill(nil, _job_id), do: :ok
  defp kill(runner, job_id), do: Tightbeam.ProducerRunner.kill(runner, job_id)

  defp kill_port(db, job_id, port, process_group, started) do
    if Port.info(port) do
      kill_process_group(db, job_id, process_group, started)
      Port.close(port)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp verify_process_group(os_pid, attempts \\ 1_000)

  defp verify_process_group(_os_pid, 0),
    do: {:error, "host-fail: producer process group unavailable"}

  defp verify_process_group(os_pid, attempts) do
    pid = Integer.to_string(os_pid)

    case System.cmd("ps", ["-o", "pgid=,state=", "-p", pid], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(output) do
          # Stopped = state string BEGINS with T. macOS appends flag letters the
          # exact-match missed: s (session leader), N (niced — true whenever the
          # BEAM runs as a background job, which made this fail for every producer
          # spawned from a niced session), + (foreground). Match the first letter.
          [^pid, <<"T", _::binary>>] ->
            :ok

          [^pid, _state] ->
            Process.sleep(1)
            verify_process_group(os_pid, attempts - 1)

          _ ->
            {:error, "host-fail: producer process group unavailable"}
        end

      _ ->
        {:error, "host-fail: producer process group unavailable"}
    end
  rescue
    _ -> {:error, "host-fail: producer process group unavailable"}
  end

  defp continue_process_group(os_pid) do
    case System.cmd("kill", ["-CONT", "--", "-#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, "host-fail: producer process group unavailable"}
    end
  rescue
    _ -> {:error, "host-fail: producer process group unavailable"}
  end

  # A signal's ONLY failure channel on Unix is the exit status, so it must be read:
  # a kill that failed is otherwise byte-identical to one that worked, and the job
  # gets recorded cancelled while its process group keeps running in the holder's
  # workdir — the database lying about what is running.
  #
  # Identity first, and the identity is the process START TIME, not the command
  # line. The wrapper `exec`s, which rewrites argv completely — measured:
  # `/bin/sh -c kill -STOP $$; exec ... tightbeam-producer /bin/sh sleep 5` becomes
  # plain `sleep 5`. Comparing command lines therefore refuses EVERY signal after
  # CONT, silently disabling cancellation (that is how the first cut of this fix
  # broke two producer tests). Start time survives exec, is stable for the whole
  # life of the process, and a recycled pid cannot share it; `ps -o lstart=` returns
  # nothing once the process is gone. Resolution is one second, so a pid recycled
  # within the same second as its predecessor would collide — vanishingly unlikely,
  # and strictly better than signalling something unverified.
  #
  # The `tightbeam-producer` argv marker is what lets an operator census ATTRIBUTE a
  # leaked shell before signalling it. Every shape spawned here and by the test fixture
  # carries it except one: the `sleep` the fixture's park watchdog execs, whose argv is a
  # bare `sleep <n>`. It is inert and dies with its process group, so a census that finds
  # one at ppid 1 loses nothing by reaping it — but it is the single shape the marker
  # cannot reach, so do not read "no marker" as "not ours".
  #
  # Three outcomes, and the distinction is the point:
  #   :signalled      — the signal was delivered and the kernel accepted it.
  #   {:noop, why}    — the target is already gone (pid absent, or recycled and so
  #                     no longer ours). Nothing to kill; cancel is achieved.
  #   {:failed, why}  — the process is THERE and we did not kill it. The caller
  #                     must not report a clean cancel.
  defp signal_group(os_pid, expected_started, flag),
    do: signal_target(os_pid, expected_started, flag, "-#{os_pid}")

  defp signal_pid(os_pid, expected_started, flag),
    do: signal_target(os_pid, expected_started, flag, Integer.to_string(os_pid))

  defp signal_target(os_pid, nil, _flag, _target) do
    # Nothing captured. If the process is gone there was never anything to kill; if
    # it is STILL THERE we cannot prove it is ours, so refuse and say so.
    case process_started(os_pid) do
      nil -> {:noop, "pid #{os_pid} gone; no identity was captured"}
      _ -> {:failed, "no captured start time — refused to signal an unverifiable pid"}
    end
  end

  defp signal_target(os_pid, expected, flag, target) do
    case process_started(os_pid) do
      nil ->
        {:noop, "pid #{os_pid} already gone"}

      ^expected ->
        deliver_signal(flag, target)

      other ->
        {:noop,
         "pid #{os_pid} recycled — captured start #{inspect(expected)}, now " <>
           "#{inspect(other)}; " <>
           "NOT signalling"}
    end
  end

  # `--` is not decoration: it is what makes a process-group target portable.
  # BSD kill(1) (macOS) reads a leading `-` on the target as a process group;
  # procps-ng kill(1) (linux) reads it as another SIGNAL specification, ACCEPTS
  # the nonsense, delivers nothing, and exits 0 — measured on ubuntu 24.04 /
  # procps-ng 4.0.4: `kill -CONT -<pgid>` leaves the group in state T and reports
  # success, and `kill -CONT -999991` also reports success. That silent zero is
  # what made every local producer job on linux sit STOPped until its timeout,
  # and made every group cancel report :signalled without signalling. With `--`
  # both kills deliver, and both report exit 1 for a group that is not there.
  defp deliver_signal(flag, target) do
    case System.cmd("kill", [flag, "--", target], stderr_to_stdout: true) do
      {_output, 0} -> :signalled
      {output, code} -> {:failed, "kill #{flag} #{target} exited #{code}: #{String.trim(output)}"}
    end
  rescue
    error -> {:failed, "kill #{flag} #{target} raised: #{Exception.message(error)}"}
  catch
    kind, reason -> {:failed, "kill #{flag} #{target} threw: #{inspect({kind, reason})}"}
  end

  defp process_started(os_pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Named event row rather than a schema value: producer_jobs.state has no
  # "cancel attempted, outcome unknown" member and inventing one is a migration.
  # Idiom follows supervision.ex's best_effort_lifecycle — swallow, but leave a row.
  defp kill_failed(nil, _job_id, _detail), do: :ok

  defp kill_failed(db, job_id, detail) do
    EventLog.lifecycle(db, "producer_kill_failed", to_string(job_id), detail)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp kill_process(db, job_id, port, os_pid, expected_started) do
    outcome = signal_pid(os_pid, expected_started, "-KILL")
    if Port.info(port), do: Port.close(port)

    case outcome do
      {:failed, why} -> kill_failed(db, job_id, "KILL pid #{os_pid}: #{why}")
      _ -> :ok
    end

    outcome
  end

  @doc false
  def kill_process_group(db, job_id, os_pid, expected_started) do
    outcome = signal_group(os_pid, expected_started, "-TERM")

    case outcome do
      {:failed, why} -> kill_failed(db, job_id, "TERM group #{os_pid}: #{why}")
      _ -> :ok
    end

    outcome
  end

  defp local_holder(config, holder) do
    case Placement.hosts(config.base_dir)[holder.host] do
      nil ->
        {:error,
         "host-fail: no host named #{holder.host} is registered: assimilate it or correct the placement"}

      %{ssh: nil} ->
        :ok

      _remote ->
        {:error, "host-fail: remote holder deferred"}
    end
  end

  defp assignment_holder(db, assignment_id) do
    case DB.query(db, "SELECT holderKey FROM assignments WHERE id = ?1", [assignment_id]) do
      {:ok, [[holder_key]]} -> %{holder_key: holder_key}
      _ -> nil
    end
  end

  defp cancel_allowed(db, {:session, session}, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT 1 FROM assignments WHERE id = ?1 AND holderKey = ?2 UNION SELECT 1 FROM sessions AS s JOIN users AS u ON u.userId = s.ownerUserId WHERE s.sessionKey = ?2 AND u.isAdmin = 1 LIMIT 1",
        [assignment_id, session]
      )

    if rows == [], do: error("forbidden", "assignment holder or admin required"), else: :ok
  end

  defp cancel_allowed(db, {:user, user}, _assignment_id) do
    if match?(%{is_admin: true}, Devices.user(db, user)),
      do: :ok,
      else: error("forbidden", "assignment holder or admin required")
  end

  defp allowed_principal({:process, _}),
    do: error("process_denied", "process principals cannot use producer verbs")

  defp allowed_principal(nil),
    do: error("principal_required", "producer verbs require a user or session principal")

  defp allowed_principal({kind, _}) when kind in [:session, :user], do: :ok

  defp assignment_state(txn, id) do
    case Txn.q(txn, "SELECT state FROM assignments WHERE id = ?1", [id]) do
      [[state]] -> state
      [] -> nil
    end
  end

  defp active_job(txn, assignment_id, kind) do
    case Txn.q(
           txn,
           "SELECT id FROM producer_jobs WHERE assignmentId = ?1 AND kind = ?2 AND state IN ('queued','running') ORDER BY rowid LIMIT 1",
           [assignment_id, kind]
         ) do
      [[id]] -> id
      [] -> nil
    end
  end

  defp insert_job(txn, assignment_id, shape, command, timeout_ms, principal) do
    {by_session, by_user, by_harness, by_provider} = frozen_principal(txn, principal)
    id = producer_job_id()

    Txn.q(
      txn,
      "INSERT INTO producer_jobs (id, assignmentId, kind, command, state, bySession, byUser, byHarness, byProvider, timeoutMs) VALUES (?1, ?2, ?3, ?4, 'queued', ?5, ?6, ?7, ?8, ?9)",
      [
        id,
        assignment_id,
        shape.kind,
        command,
        by_session,
        by_user,
        by_harness,
        by_provider,
        timeout_ms
      ]
    )

    %{queued: id}
  end

  defp frozen_principal(txn, {:session, session}) do
    case Txn.q(txn, "SELECT harness, provider FROM sessions WHERE sessionKey = ?1", [session]) do
      [[harness, provider]] -> {session, nil, harness, provider}
      [] -> {session, nil, nil, nil}
    end
  end

  defp frozen_principal(_txn, {:user, user}), do: {nil, user, nil, nil}

  defp producer_failed(db, assignment_id, job_id, kind, command, reason) do
    EventLog.lifecycle(
      db,
      "producer_failed",
      to_string(assignment_id),
      inspect(%{jobId: job_id, kind: kind, command: command, reason: reason})
    )
  end

  defp nudge(nil, _job_id), do: :ok
  defp nudge(runner, _job_id), do: Tightbeam.ProducerRunner.nudge(runner)

  defp validate_command!(_path, _key, nil), do: nil
  defp validate_command!(_path, _key, value) when is_binary(value), do: value

  defp validate_command!(path, key, _),
    do: raise(ArgumentError, "#{path}: #{key} must be a command string")

  defp committed_config(identity_dir) do
    file = Path.join(identity_dir, "producers.toml")

    case System.cmd(
           "git",
           ["-C", identity_dir, "rev-parse", "--is-inside-work-tree"],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} ->
        committed_config_from_git(identity_dir)

      {message, status} ->
        if File.exists?(file),
          do:
            raise(
              "cannot read committed producer config (git #{status}): #{String.trim(message)}"
            ),
          else: :missing
    end
  rescue
    error in ErlangError ->
      if File.exists?(Path.join(identity_dir, "producers.toml")),
        do: raise("cannot read committed producer config: #{Exception.message(error)}"),
        else: :missing
  end

  defp committed_config_from_git(identity_dir) do
    case System.cmd(
           "git",
           ["-C", identity_dir, "show", "HEAD:producers.toml"],
           stderr_to_stdout: true
         ) do
      {encoded, 0} ->
        {:ok, encoded}

      {message, _status} ->
        if message =~ "does not exist in" or message =~ "exists on disk, but not in",
          do: :missing,
          else: raise("cannot read committed producer config: #{String.trim(message)}")
    end
  end

  defp producer_job_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    "pj_" <>
      Enum.join(
        [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
        "-"
      )
  end

  defp hex(value, width), do: value |> Integer.to_string(16) |> String.pad_leading(width, "0")
  defp now, do: System.system_time(:millisecond)
  defp error(code, message), do: %{code: code, message: message}

  defp job_columns do
    "id, assignmentId, kind, command, state, bySession, byUser, byHarness, byProvider, timeoutMs, startedAt"
  end

  defp job([
         id,
         assignment_id,
         kind,
         command,
         state,
         by_session,
         by_user,
         by_harness,
         by_provider,
         timeout_ms,
         started_at
       ]) do
    shape =
      Enum.find_value(@producer_shapes, fn {_verb, shape} -> if shape.kind == kind, do: shape end)

    %{
      id: id,
      assignment_id: assignment_id,
      kind: kind,
      command: command,
      state: state,
      by_session: by_session,
      by_user: by_user,
      by_harness: by_harness,
      by_provider: by_provider,
      timeout_ms: timeout_ms,
      started_at: started_at,
      producer: shape.producer,
      verdict_kind: shape.verdict_kind
    }
  end
end

defmodule Tightbeam.ProducerRunner do
  @moduledoc false
  use GenServer

  alias Tightbeam.Producers

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def nudge(server \\ __MODULE__), do: GenServer.cast(server, :drain)

  def register_process(server, job_id, port, os_pid, started),
    do: GenServer.call(server, {:register_process, job_id, port, os_pid, started})

  def unregister_process(server, job_id),
    do: GenServer.cast(server, {:unregister_process, job_id})

  def kill(server, job_id), do: GenServer.cast(server, {:kill, job_id})

  @impl true
  def init(opts) do
    db = Keyword.get(opts, :db, Tightbeam.DB)
    :ok = Producers.recover(db)

    {:ok,
     %{
       db: db,
       config: Keyword.fetch!(opts, :config),
       supervisor: Keyword.get(opts, :supervisor, Tightbeam.ProducerSupervisor),
       name: Keyword.get(opts, :name, __MODULE__),
       tasks: %{},
       processes: %{},
       pending_kills: MapSet.new()
     }, {:continue, :drain}}
  end

  @impl true
  def handle_continue(:drain, state), do: drain(state)

  @impl true
  def handle_cast(:drain, state), do: drain(state)

  def handle_cast({:unregister_process, job_id}, state) do
    {:noreply,
     state
     |> update_in([:processes], &Map.delete(&1, job_id))
     |> update_in([:pending_kills], &MapSet.delete(&1, job_id))}
  end

  def handle_cast({:kill, job_id}, state) do
    state =
      case state.processes[job_id] do
        %{port: port, os_pid: os_pid} = process ->
          db = state.db
          started = Map.get(process, :started)
          Task.start(fn -> best_effort_kill(db, job_id, port, os_pid, started) end)
          state

        nil ->
          if Enum.any?(state.tasks, fn {_ref, task_job_id} -> task_job_id == job_id end),
            do: update_in(state.pending_kills, &MapSet.put(&1, job_id)),
            else: state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:register_process, job_id, port, os_pid, started}, _from, state) do
    if MapSet.member?(state.pending_kills, job_id) do
      {:reply, :cancelled, update_in(state.pending_kills, &MapSet.delete(&1, job_id))}
    else
      {:reply, :ok,
       put_in(state.processes[job_id], %{port: port, os_pid: os_pid, started: started})}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {job_id, tasks} = Map.pop(state.tasks, ref)
    if job_id, do: Producers.fail_running(state.db, job_id, "host-fail: producer task exited")

    state =
      if job_id do
        %{
          state
          | tasks: tasks,
            processes: Map.delete(state.processes, job_id),
            pending_kills: MapSet.delete(state.pending_kills, job_id)
        }
      else
        %{state | tasks: tasks}
      end

    drain(state)
  end

  def handle_info(:drain_more, state), do: drain(state)

  defp drain(state) do
    case Producers.claim_next(state.db) do
      nil ->
        {:noreply, state}

      job ->
        child = {Task, fn -> Producers.execute(state.db, state.config, job, state.name) end}

        case DynamicSupervisor.start_child(state.supervisor, child) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            send(self(), :drain_more)
            {:noreply, put_in(state.tasks[ref], job.id)}

          {:error, reason} ->
            Producers.fail_running(state.db, job.id, "host-fail: #{inspect(reason)}")
            {:stop, {:producer_task_start_failed, reason}, state}
        end
    end
  end

  # "Best effort" still owes an honest record: nothing awaits this Task, so an
  # unobserved failure here is exactly how a job gets marked cancelled while its
  # group keeps running. Producers.kill_process_group/4 reads the exit status and
  # writes a producer_kill_failed row when the process is still there.
  defp best_effort_kill(db, job_id, port, os_pid, started) do
    Producers.kill_process_group(db, job_id, os_pid, started)

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
