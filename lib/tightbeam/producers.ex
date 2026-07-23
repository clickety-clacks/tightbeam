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
        run_local(job, workdir, runner)
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

  defp run_local(job, workdir, runner) do
    shell = System.find_executable("sh") || "/bin/sh"
    launcher = System.find_executable("python3") || raise "python3 is required for producer jobs"
    env = minimal_env(workdir)

    group_script =
      "import os,sys; pid=os.fork(); " <>
        "(os.setsid(), os.execv(sys.argv[1], sys.argv[1:])) if pid == 0 else None; " <>
        "print(f'TB_PGID:{pid}', flush=True); _,status=os.waitpid(pid,0); " <>
        "sys.exit(os.waitstatus_to_exitcode(status))"

    port =
      Port.open(
        {:spawn_executable, launcher},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, ["-c", group_script, shell, "-lc", job.command]},
          {:cd, workdir},
          {:env, env}
        ]
      )

    await_exit(
      port,
      System.monotonic_time(:millisecond) + job.timeout_ms,
      runner,
      job.id,
      nil
    )
  end

  defp await_exit(port, deadline, runner, job_id, process_group) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, output}} ->
        process_group = process_group || register_process_group(output, runner, job_id, port)
        await_exit(port, deadline, runner, job_id, process_group)

      {^port, {:exit_status, status}} ->
        {:ok, status}

      {^port, :closed} ->
        {:error, "cancelled"}
    after
      remaining ->
        kill_port(port, process_group)
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

  defp kill_port(port, process_group) do
    if Port.info(port) do
      os_pid = process_group || port |> Port.info(:os_pid) |> elem(1)
      kill_process_group(os_pid)
      Port.close(port)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp register_process_group(output, runner, job_id, port) do
    case Regex.run(~r/TB_PGID:(\d+)/, output) do
      [_, pid] ->
        os_pid = String.to_integer(pid)
        Tightbeam.ProducerRunner.register_process(runner, job_id, port, os_pid)
        os_pid

      nil ->
        nil
    end
  end

  defp kill_process_group(os_pid) do
    pid = Integer.to_string(os_pid)

    case System.cmd("ps", ["-o", "pgid=", "-p", pid], stderr_to_stdout: true) do
      {pgid, 0} ->
        if String.trim(pgid) == pid do
          System.cmd("kill", ["-TERM", "-#{pid}"], stderr_to_stdout: true)
        else
          kill_tree(pid)
        end

      _ ->
        kill_tree(pid)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp kill_tree(pid) do
    if System.find_executable("pkill"),
      do: System.cmd("pkill", ["-TERM", "-P", pid], stderr_to_stdout: true)

    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
  end

  defp local_holder(config, holder) do
    host = Placement.hosts(config.base_dir)[holder.host]
    if host && host.ssh == nil, do: :ok, else: {:error, "host-fail: remote holder deferred"}
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

  def register_process(server, job_id, port, os_pid),
    do: GenServer.call(server, {:register_process, job_id, port, os_pid})

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
       processes: %{}
     }, {:continue, :drain}}
  end

  @impl true
  def handle_continue(:drain, state), do: drain(state)

  @impl true
  def handle_cast(:drain, state), do: drain(state)

  def handle_cast({:unregister_process, job_id}, state) do
    {:noreply, update_in(state.processes, &Map.delete(&1, job_id))}
  end

  def handle_cast({:kill, job_id}, state) do
    case state.processes[job_id] do
      %{port: port, os_pid: os_pid} ->
        Task.start(fn -> best_effort_kill(port, os_pid) end)

      nil ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:register_process, job_id, port, os_pid}, _from, state) do
    {:reply, :ok, put_in(state.processes[job_id], %{port: port, os_pid: os_pid})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {job_id, tasks} = Map.pop(state.tasks, ref)
    if job_id, do: Producers.fail_running(state.db, job_id, "host-fail: producer task exited")
    drain(%{state | tasks: tasks})
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

  defp best_effort_kill(port, os_pid) do
    pid = Integer.to_string(os_pid)

    case System.cmd("ps", ["-o", "pgid=", "-p", pid], stderr_to_stdout: true) do
      {pgid, 0} ->
        if String.trim(pgid) == pid do
          System.cmd("kill", ["-TERM", "-#{pid}"], stderr_to_stdout: true)
        else
          kill_tree(pid)
        end

      _ ->
        kill_tree(pid)
    end

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp kill_tree(pid) do
    if System.find_executable("pkill"),
      do: System.cmd("pkill", ["-TERM", "-P", pid], stderr_to_stdout: true)

    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
  end
end
