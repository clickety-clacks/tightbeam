defmodule Tightbeam.SentinelSupervisor do
  @moduledoc """
  Runs every enabled sentinel on the gateway's host.

  The durable `sentinel_states` rows are the truth; this process reconciles running
  children to them at start and whenever a verb changes them. Each child runs the
  exact command bytes of the published identity, copied into its run directory
  under the base dir, with its own settings and nothing else of Tightbeam's
  environment. Its output is appended to `sentinel.log` there, and the command's
  SHA-256 is recorded on its state row and in the log.

  An exit restarts the child with backoff. After five consecutive exits that each
  came within a minute of their start, the sentinel is recorded `stopped` and the
  principal who last enabled it gets one wake. The wake is about supervision only;
  what the sentinel watches is its own business.
  """

  use GenServer
  require Logger

  alias Tightbeam.DB
  alias Tightbeam.Identity
  alias Tightbeam.Org
  alias Tightbeam.Placement
  alias Tightbeam.Roles
  alias Tightbeam.Sentinels
  alias Tightbeam.Wakes

  @fast_exit_ms 60_000
  @stop_after 5
  @max_backoff_ms 60_000

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Bring running children in line with the durable states. `restart` names a
  sentinel to restart from the current published bytes even if it is running.
  """
  @spec reconcile(GenServer.server(), [String.t()]) :: :ok
  def reconcile(server \\ __MODULE__, restart \\ []) do
    case GenServer.whereis(server) do
      nil -> :ok
      _pid -> GenServer.call(server, {:reconcile, restart}, 30_000)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      db: Keyword.fetch!(opts, :db),
      base_dir: Keyword.fetch!(opts, :base_dir),
      cli_bin: Keyword.fetch!(opts, :cli_bin),
      host: Keyword.get(opts, :host, Placement.local_host_name()),
      fast_exit_ms: Keyword.get(opts, :fast_exit_ms, @fast_exit_ms),
      backoff_unit_ms: Keyword.get(opts, :backoff_unit_ms, 1_000),
      children: %{},
      failures: %{}
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: {:noreply, do_reconcile(state, [])}

  @impl true
  def handle_call({:reconcile, restart}, _from, state) do
    state = Enum.reduce(restart, state, &stop_child(&2, &1))
    state = %{state | failures: Map.drop(state.failures, restart)}
    {:reply, :ok, do_reconcile(state, restart)}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case find_by_port(state, port) do
      {_qualified, child} -> IO.binwrite(child.log, data)
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case find_by_port(state, port) do
      {qualified, child} -> {:noreply, child_exited(state, qualified, child, status)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:restart, qualified}, state) do
    {:noreply, do_reconcile(state, [], [qualified])}
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state.children), &stop_child(state, &1))
    :ok
  end

  # Start every enabled sentinel that is not running (or is named in `restart`);
  # stop every running child whose row is no longer enabled. A sentinel waiting on
  # a backoff timer starts only when `due` names it.
  defp do_reconcile(state, restart, due \\ []) do
    states = Sentinels.states(state.db, state.host)
    enabled = for {qualified, %{state: "enabled"}} <- states, into: MapSet.new(), do: qualified

    state =
      state.children
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(enabled, &1))
      |> Enum.reduce(state, &stop_child(&2, &1))

    learned =
      if MapSet.size(enabled) == 0,
        do: %{revision: nil, sentinels: []},
        else: Identity.learned_sentinels(state.base_dir)

    Enum.reduce(enabled, state, fn qualified, acc ->
      waiting = Map.has_key?(acc.failures, qualified) and qualified not in due

      cond do
        Map.has_key?(acc.children, qualified) -> acc
        waiting and qualified not in restart -> acc
        true -> start_child(acc, qualified, learned)
      end
    end)
  end

  defp start_child(state, qualified, %{revision: revision, sentinels: sentinels}) do
    case Enum.find(sentinels, &(&1.qualified == qualified)) do
      nil ->
        reason = "the published identity does not declare #{qualified}"
        Sentinels.mark_stopped(state.db, state.host, qualified, reason)
        Logger.error("sentinel #{qualified} not started: #{reason}")
        state

      sentinel ->
        bytes = Identity.revision_file_bytes!(state.base_dir, revision, sentinel.command_path)
        sha256 = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        run_dir = Path.join([state.base_dir, "sentinels", sentinel.bundle, sentinel.name])
        File.mkdir_p!(run_dir)
        program = Path.join(run_dir, Path.basename(sentinel.command_path))
        File.rm(program)
        File.write!(program, bytes)
        File.chmod!(program, 0o755)
        log = File.open!(Path.join(run_dir, "sentinel.log"), [:append, :binary])
        started_at = System.system_time(:millisecond)

        IO.binwrite(
          log,
          "[tightbeam] #{iso(started_at)} start #{qualified} revision=#{revision} sha256=#{sha256}\n"
        )

        port =
          Port.open({:spawn_executable, program}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:cd, run_dir},
            {:env, child_env(state, sentinel)}
          ])

        # A child that exits at once has already closed its port; its exit status
        # still arrives as a message, so it is handled like any other exit.
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, os_pid} -> os_pid
            nil -> nil
          end

        :ok = Sentinels.mark_started(state.db, state.host, qualified, sha256, started_at)

        child = %{port: port, os_pid: os_pid, started_at: started_at, log: log}
        put_in(state.children[qualified], child)
    end
  end

  # The child's environment is the gateway's minus everything Tightbeam or the
  # release owns and minus the names it declares, plus the CLI on PATH, its own
  # attribution and exactly its own settings.
  defp child_env(state, sentinel) do
    scrubbed =
      for {name, _value} <- System.get_env(),
          String.starts_with?(name, "TIGHTBEAM_") or
            Tightbeam.ProductionIdentityEnv.production_identity?(name) or
            name in sentinel.requires,
          into: %{},
          do: {name, false}

    path = Enum.join([Path.dirname(state.cli_bin), System.get_env("PATH", "")], ":")

    scrubbed
    |> Map.merge(%{
      "PATH" => path,
      "TIGHTBEAM_BASE_DIR" => state.base_dir,
      "TIGHTBEAM_AS_PROCESS" => "sentinel:" <> sentinel.qualified
    })
    |> Map.merge(Map.new(Sentinels.settings(state.db, state.host, sentinel.qualified)))
    |> Enum.map(fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp child_exited(state, qualified, child, status) do
    ended_at = System.system_time(:millisecond)
    IO.binwrite(child.log, "[tightbeam] #{iso(ended_at)} exit #{qualified} status=#{status}\n")
    File.close(child.log)
    state = %{state | children: Map.delete(state.children, qualified)}

    fast? = ended_at - child.started_at < state.fast_exit_ms
    failures = if fast?, do: Map.get(state.failures, qualified, 0) + 1, else: 0

    if failures >= @stop_after do
      reason =
        "exited #{failures} times in a row within #{div(state.fast_exit_ms, 1000)}s " <>
          "of starting; last status #{status}"

      stop_after_failures(state, qualified, reason)
      %{state | failures: Map.delete(state.failures, qualified)}
    else
      delay = min(state.backoff_unit_ms * Integer.pow(2, max(failures - 1, 0)), @max_backoff_ms)
      Process.send_after(self(), {:restart, qualified}, delay)
      put_in(state.failures[qualified], failures)
    end
  end

  defp stop_after_failures(state, qualified, reason) do
    enabled_by = Sentinels.states(state.db, state.host)[qualified][:enabled_by]
    :ok = Sentinels.mark_stopped(state.db, state.host, qualified, reason)
    Logger.error("sentinel #{qualified} stopped on #{state.host}: #{reason}")

    prompt =
      "Sentinel #{qualified} on #{state.host} is stopped: it #{reason}. " <>
        "Its output is in #{Path.join([state.base_dir, "sentinels", qualified, "sentinel.log"])}. " <>
        "Run `tightbeam doctor` for its state; `tightbeam sentinel enable #{qualified}` restarts it."

    case principal_session(state.db, enabled_by) do
      {:ok, session_key} ->
        {:ok, _wake} =
          DB.transaction(state.db, fn txn ->
            Wakes.schedule_in_txn(txn, %{
              session_key: session_key,
              origin: "process:tightbeam",
              prompt: prompt,
              due_at: System.system_time(:millisecond),
              sender_scheduled: true
            })
          end)

        :ok

      :none ->
        Logger.error(
          "sentinel #{qualified} stop has no principal to wake (enabled by #{inspect(enabled_by)})"
        )
    end
  end

  defp principal_session(_db, "user:" <> user_id), do: {:ok, Org.personal_session_key(user_id)}

  defp principal_session(db, "agent:" <> role) do
    case Roles.resolve(db, role) do
      {:ok, session_key, _fallback} -> {:ok, session_key}
      {:error, _denial} -> :none
    end
  end

  defp principal_session(_db, _principal), do: :none

  defp stop_child(state, qualified) do
    case Map.pop(state.children, qualified) do
      {nil, _children} ->
        state

      {child, children} ->
        if child.os_pid,
          do:
            System.cmd("kill", ["-TERM", Integer.to_string(child.os_pid)], stderr_to_stdout: true)

        if Port.info(child.port), do: Port.close(child.port)

        IO.binwrite(
          child.log,
          "[tightbeam] #{iso(System.system_time(:millisecond))} stop #{qualified}\n"
        )

        File.close(child.log)
        %{state | children: children}
    end
  end

  defp find_by_port(state, port), do: Enum.find(state.children, fn {_q, c} -> c.port == port end)

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
