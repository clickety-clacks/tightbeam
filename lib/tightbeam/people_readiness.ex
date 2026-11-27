defmodule Tightbeam.PeopleReadiness do
  @moduledoc "Transient readiness hints for the durable people-message outbox."

  use GenServer

  alias Tightbeam.DB.Txn

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def changed_in_txn(txn), do: Txn.handoff(txn, __MODULE__, :changed)

  def wait(0, read), do: read.()

  def wait(timeout_ms, read) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(deadline, read)
  end

  defp wait_until(deadline, read) do
    case subscribe_and_read(deadline, read) do
      :recheck -> wait_until(deadline, read)
      result -> result
    end
  end

  defp subscribe_and_read(deadline, read) do
    case Process.whereis(__MODULE__) do
      nil ->
        unavailable()

      broker ->
        ref = :erlang.monitor(:process, broker, [{:alias, :demonitor}])

        try do
          # Registration is synchronous. A commit before it is visible to the
          # read, and a commit after it leaves a hint even before receive.
          case subscribe(broker, ref) do
            :ok -> read_or_wait(broker, ref, deadline, read)
            :unavailable -> unavailable()
          end
        after
          GenServer.cast(broker, {:unsubscribe, ref})
          Process.demonitor(ref, [:flush])

          receive do
            {:people_ready, ^ref} -> :ok
          after
            0 -> :ok
          end
        end
    end
  end

  defp subscribe(broker, ref) do
    GenServer.call(broker, {:subscribe, ref})
  catch
    :exit, _reason -> :unavailable
  end

  defp read_or_wait(broker, ref, deadline, read) do
    case read.() do
      %{records: []} = empty ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          empty
        else
          receive do
            {:people_ready, ^ref} -> :recheck
            {:DOWN, ^ref, :process, ^broker, _reason} -> unavailable()
          after
            remaining -> empty
          end
        end

      result ->
        result
    end
  end

  defp unavailable,
    do: %{code: "people_readiness_unavailable", message: "people queue readiness is restarting"}

  @impl true
  def init(waiters), do: {:ok, waiters}

  @impl true
  def handle_call({:subscribe, ref}, {pid, _}, waiters) do
    {:reply, :ok, Map.put(waiters, ref, {pid, Process.monitor(pid)})}
  end

  @impl true
  def handle_cast(:changed, waiters) do
    Enum.each(waiters, fn {ref, {_pid, monitor}} ->
      Process.demonitor(monitor, [:flush])
      send(ref, {:people_ready, ref})
    end)

    {:noreply, %{}}
  end

  def handle_cast({:unsubscribe, ref}, waiters) do
    case Map.pop(waiters, ref) do
      {{_pid, monitor}, remaining} ->
        Process.demonitor(monitor, [:flush])
        {:noreply, remaining}

      {nil, _} ->
        {:noreply, waiters}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, waiters) do
    {:noreply, Map.reject(waiters, fn {_ref, {_pid, candidate}} -> candidate == monitor end)}
  end
end
