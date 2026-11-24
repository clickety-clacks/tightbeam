defmodule Tightbeam.Capacity.Refresh do
  @moduledoc false
  use GenServer

  alias Tightbeam.Capacity.ReadPolicy

  @wait_ms :timer.seconds(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def read(server, account_id, mode) when mode in [:background, :wait, :snapshot] do
    ref = Process.alias()
    deadline = System.monotonic_time(:millisecond) + @wait_ms

    try do
      case GenServer.call(server, {:read, account_id, mode, ref}, @wait_ms) do
        {:waiting, retained} ->
          receive do
            {^ref, result} -> result
          after
            max(0, deadline - System.monotonic_time(:millisecond)) ->
              GenServer.cast(server, {:forget, account_id, ref})
              ReadPolicy.result(account_id, retained, %{code: "UPSTREAM_TIMEOUT"}, :retained)
          end

        result ->
          result
      end
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(server, {:forget, account_id, ref})
        ReadPolicy.result(account_id, nil, %{code: "UPSTREAM_TIMEOUT"}, :retained)
    after
      Process.unalias(ref)

      receive do
        {^ref, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  def trigger(server, account_id), do: GenServer.cast(server, {:trigger, account_id})

  @impl true
  def init(opts) do
    {:ok,
     %{
       entry: Keyword.fetch!(opts, :entry),
       collect: Keyword.fetch!(opts, :collect),
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       now: Keyword.get(opts, :now, fn -> System.system_time(:millisecond) end),
       active: %{},
       task_ids: %{}
     }}
  end

  @impl true
  def handle_call({:read, account_id, mode, ref}, _from, state) do
    entry = state.entry.(account_id)

    case ReadPolicy.action(entry, mode, state.now.()) do
      :held ->
        {:reply, result(account_id, entry, :retained), state}

      :snapshot ->
        source =
          if entry.sample && ReadPolicy.action(entry, :background, state.now.()) == :background,
            do: :retained,
            else: :snapshot

        {:reply, result(account_id, entry, source), state}

      :background ->
        {:reply, result(account_id, entry, :retained), start(state, account_id)}

      :wait ->
        state = start(state, account_id)
        state = update_in(state.active[account_id].waiters, &MapSet.put(&1, ref))
        {:reply, {:waiting, entry.sample}, state}
    end
  end

  @impl true
  def handle_cast({:trigger, account_id}, state) do
    entry = state.entry.(account_id)

    if ReadPolicy.action(entry, :wait, state.now.()) == :held do
      {:noreply, state}
    else
      {:noreply, start(state, account_id)}
    end
  end

  def handle_cast({:forget, account_id, ref}, state) do
    case state.active do
      %{^account_id => task} ->
        state = put_in(state.active[account_id].waiters, MapSet.delete(task.waiters, ref))
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, outcome}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, finish(state, ref, {:error, %{code: "UPSTREAM_UNAVAILABLE"}})}
  end

  defp start(state, account_id) do
    if Map.has_key?(state.active, account_id) do
      state
    else
      collect = state.collect
      attempted_at = state.now.()

      # The collector owns the lock and durable commit. A caller's deadline
      # detaches its waiter while collection and credential settlement continue.
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          collect.(account_id, attempted_at)
        end)

      %{
        state
        | active: Map.put(state.active, account_id, %{waiters: MapSet.new()}),
          task_ids: Map.put(state.task_ids, task.ref, account_id)
      }
    end
  end

  defp finish(state, ref, outcome) do
    case Map.pop(state.task_ids, ref) do
      {nil, _} ->
        state

      {account_id, task_ids} ->
        {task, active} = Map.pop!(state.active, account_id)
        result = outcome_result(state, account_id, outcome)
        for waiter <- task.waiters, do: send(waiter, {waiter, result})
        %{state | active: active, task_ids: task_ids}
    end
  end

  defp outcome_result(_, account_id, {:ok, entry}), do: result(account_id, entry, :refreshed)

  defp outcome_result(state, account_id, {:error, error}) do
    entry = state.entry.(account_id)
    result(account_id, %{entry | error: error}, :retained)
  end

  defp result(account_id, entry, source),
    do: ReadPolicy.result(account_id, entry.sample, entry.error, source)
end
