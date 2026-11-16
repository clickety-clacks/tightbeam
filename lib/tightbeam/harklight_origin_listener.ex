defmodule Tightbeam.HarklightOriginListener do
  @moduledoc false
  use GenServer
  require Logger

  alias Tightbeam.{
    DB,
    HarklightLifecycle,
    HarklightOrigin,
    HarklightWakes,
    Placement,
    Org,
    HarklightChild
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def cover(call, server \\ __MODULE__),
    do: GenServer.call(server, {:cover, call}, :infinity)

  def resume_handle(handle) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:resume_handle, handle})
    :ok
  end

  def resume_session(session_key) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:resume_session, session_key})
    :ok
  end

  def ensure_started(server \\ __MODULE__), do: GenServer.call(server, :ensure_started)

  def confirm(handle, complete? \\ false, server \\ __MODULE__),
    do: GenServer.call(server, {:confirm, handle, complete?}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :restore)

    child_opts =
      Keyword.get(opts, :child_opts, Application.get_env(:tightbeam, :harklight_child_opts, []))

    {:ok,
     %{
       db: Keyword.get(opts, :db, DB),
       runner: Keyword.get(opts, :runner),
       listener: Keyword.get(opts, :listener, fn manager -> listen(manager, child_opts) end),
       stop: Keyword.get(opts, :stop, &HarklightWakes.stop_for_origin/1),
       legacy_manager: Keyword.get(opts, :legacy_manager, HarklightWakes),
       migrations: %{},
       recover_moves: Keyword.get(opts, :recover_moves, true),
       worker: nil,
       port: nil,
       exit_status: nil
     }}
  end

  @impl true
  def handle_info(:restore, state) do
    state = start_listener(state)

    {:ok, rows} =
      DB.query(
        state.db,
        """
        SELECT m.handle FROM harklight_origin_moves m
        JOIN harklight_wake_handles h ON h.handle=m.handle
        WHERE m.state='moving' AND h.host=?1
        """,
        [Placement.local_host_name()]
      )

    # Resume only explicitly recorded moves; ordinary legacy handles never
    # acquire coverage because the gateway restarted.
    state =
      if state.recover_moves,
        do: Enum.reduce(rows, state, fn [handle], acc -> start_move(acc, handle, true, nil) end),
        else: state

    {:ok, confirmed} =
      DB.query(
        state.db,
        """
        SELECT m.handle FROM harklight_origin_moves m JOIN harklight_wake_handles h ON h.handle=m.handle
        WHERE m.confirmed=1 AND h.host=?1
        """,
        [Placement.local_host_name()]
      )

    Enum.each(confirmed, fn [handle] -> drain_confirmed(state, handle) end)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{worker: {pid, ref}} = state) do
    status = state.exit_status || {:worker_exit, reason}
    Logger.warning("Harklight origin listener stopped: #{inspect(status)}")
    # The Agent reconnects on transport loss. A terminal exit (especially 6,
    # replaced) must not cause a competing listener to be started here.
    {:noreply, %{state | worker: nil, port: nil, exit_status: status}}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_move(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, finish_move(state, ref, {:error, {:move_interrupted, reason}})}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:resume_handle, handle}, state) do
    drain_confirmed(state, handle)
    {:noreply, state}
  end

  def handle_cast({:resume_session, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        """
        SELECT m.handle FROM harklight_origin_moves m
        JOIN harklight_wake_handles h ON h.handle=m.handle WHERE h.sessionKey=?1 AND h.host=?2
        """,
        [session_key, Placement.local_host_name()]
      )

    Enum.each(rows, fn [handle] -> drain_confirmed(state, handle) end)
    {:noreply, state}
  end

  defp drain_confirmed(state, handle) do
    case DB.transaction(state.db, &HarklightOrigin.admission(&1, handle)) do
      {:ok, :confirmed} ->
        with :ok <- HarklightOrigin.drain(state.db, handle),
             do: HarklightLifecycle.acknowledge_pending(state.db, runner: state.runner)

      _ ->
        :ok
    end
  end

  @impl true
  def handle_call({:cover, call}, from, state) do
    handle = call.params[:handle]
    session = if is_binary(call[:session_key]), do: Org.get(state.db, call.session_key), else: nil

    valid? =
      Map.keys(call.params) == [:handle] and is_binary(handle) and
        call[:principal] == {:session, call[:session_key]} and
        call[:transport_session_key] == call[:session_key] and
        match?(%{state: "active"}, session) and session.host == Placement.local_host_name()

    if valid? do
      case HarklightWakes.begin_origin_move(handle, call.session_key, state.legacy_manager) do
        {:ok, _} ->
          state = start_listener(state)

          if state.worker,
            do: {:noreply, start_move(state, handle, false, from)},
            else: {:reply, move_result(handle, {:error, :origin_listener_stopped}), state}

        error ->
          {:reply, move_result(handle, error), state}
      end
    else
      {:reply,
       %{
         command: "cover",
         outcome: "refused",
         code: "harklight_owned_handle_required",
         reason: "Cover requires the conversation's active sending session on its original host."
       }, state}
    end
  end

  def handle_call(:ensure_started, _from, state) do
    state = start_listener(state)
    {:reply, if(state.worker, do: :ok, else: {:error, state.exit_status}), state}
  end

  def handle_call({:line, line}, {pid, _}, %{worker: {pid, _}} = state) do
    result = HarklightWakes.capture_origin_line(state.db, line)

    # Neither a foreign offer nor a buffered, unconfirmed offer may trigger any
    # Harklight action. Accepted events retain the established action receipts.
    if result == :ok,
      do: HarklightLifecycle.acknowledge_pending(state.db, runner: state.runner)

    {:reply, result, state}
  end

  def handle_call({:line, _line}, _from, state), do: {:reply, {:error, :stale_listener}, state}

  def handle_call({:confirm, handle, complete?}, _from, state) do
    result =
      with {:ok, _} <- HarklightOrigin.confirmed(state.db, handle, complete?),
           :ok <- HarklightOrigin.drain(state.db, handle) do
        HarklightLifecycle.acknowledge_pending(state.db, runner: state.runner)
        :ok
      end

    {:reply, result, state}
  end

  def handle_call({:port, port}, {pid, _}, %{worker: {pid, _}} = state),
    do: {:reply, :ok, %{state | port: port}}

  def handle_call({:exited, status}, {pid, _}, %{worker: {pid, _}} = state),
    do: {:reply, :ok, %{state | exit_status: status}}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.migrations, fn {_ref, move} -> Process.exit(move.pid, :shutdown) end)
    if state.port, do: close_port(state.port)
    if state.worker, do: Process.exit(elem(state.worker, 0), :shutdown)
    :ok
  end

  defp start_listener(%{worker: worker} = state) when not is_nil(worker), do: state

  defp start_listener(%{exit_status: status} = state) when not is_nil(status), do: state

  defp start_listener(state) do
    {:ok, rows} =
      DB.query(
        state.db,
        """
        SELECT 1 FROM harklight_origin_moves m
        JOIN harklight_wake_handles h ON h.handle=m.handle WHERE h.host=?1 LIMIT 1
        """,
        [Placement.local_host_name()]
      )

    if rows == [] do
      state
    else
      manager = self()
      {:ok, pid} = Task.start_link(fn -> state.listener.(manager) end)
      %{state | worker: {pid, Process.monitor(pid)}, exit_status: nil}
    end
  end

  defp listen(manager, opts) do
    Process.flag(:trap_exit, true)

    case System.find_executable("harklight-agent") do
      nil ->
        GenServer.call(manager, {:exited, :cli_missing})

      executable ->
        :ok = HarklightChild.await_stopped(:origin, opts)

        {:ok, port, initial} =
          HarklightChild.open(
            :origin,
            executable,
            ["listen", "--origin", "--follow"],
            Keyword.put(opts, :stderr_to_stdout, false)
          )

        try do
          :ok = GenServer.call(manager, {:port, port})
          true = Port.command(port, "continue\n")
          receive_lines(manager, port, initial)
        after
          close_port(port)
        end
    end
  end

  defp receive_lines(manager, port, pending) do
    receive do
      {^port, {:data, bytes}} ->
        lines = :binary.split(pending <> bytes, "\n", [:global])

        result =
          Enum.reduce_while(Enum.drop(lines, -1), :ok, fn line, :ok ->
            case GenServer.call(manager, {:line, line}, :infinity) do
              result when result in [:ok, :captured, :ignored] -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)

        if result == :ok,
          do: receive_lines(manager, port, List.last(lines)),
          else: GenServer.call(manager, {:exited, result})

      {^port, {:exit_status, status}} ->
        GenServer.call(manager, {:exited, status})

      {:EXIT, ^manager, reason} ->
        exit(reason)
    end
  end

  defp close_port(port) do
    HarklightChild.request_stop(port)
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp start_move(state, handle, restore?, waiter) do
    case Enum.find(state.migrations, fn {_, move} -> move.handle == handle end) do
      {ref, move} ->
        waiters = if waiter, do: [waiter | move.waiters], else: move.waiters
        %{state | migrations: Map.put(state.migrations, ref, %{move | waiters: waiters})}

      nil ->
        task =
          Task.async(fn ->
            with {:ok, runner} <- runner(state.runner) do
              HarklightOrigin.migrate(state.db, handle,
                runner: runner,
                stop: state.stop,
                restore: restore?
              )
            end
          end)

        move = %{handle: handle, pid: task.pid, waiters: if(waiter, do: [waiter], else: [])}
        %{state | migrations: Map.put(state.migrations, task.ref, move)}
    end
  end

  defp finish_move(state, ref, result) do
    case Map.pop(state.migrations, ref) do
      {nil, _} ->
        state

      {move, migrations} ->
        Enum.each(move.waiters, &GenServer.reply(&1, move_result(move.handle, result)))

        if result != :ok,
          do: Logger.warning("Harklight coverage move remains pending: #{inspect(result)}")

        %{state | migrations: migrations}
    end
  end

  defp move_result(handle, :ok), do: %{command: "cover", outcome: "covered", handle: handle}

  defp move_result(handle, {:pending, op_id}),
    do: %{
      command: "cover",
      outcome: "pending",
      handle: handle,
      op_id: op_id,
      reason:
        "The existing support operation is unresolved. Retry harklight-cover for this session."
    }

  defp move_result(handle, error),
    do: %{
      command: "cover",
      outcome: "pending",
      handle: handle,
      code: "harklight_coverage_unconfirmed",
      reason:
        "Coverage move is not complete: #{inspect(error)}. Retry harklight-cover for this session."
    }

  defp runner(fun) when is_function(fun, 1), do: {:ok, fun}

  defp runner(nil) do
    case System.find_executable("harklight-agent") do
      nil -> {:error, :harklight_cli_missing}
      executable -> {:ok, fn args -> System.cmd(executable, args, stderr_to_stdout: true) end}
    end
  end
end
