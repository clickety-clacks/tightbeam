defmodule Tightbeam.Firehose.Hub do
  @moduledoc """
  Live-only fan-out for state-change notices.

  The hub keeps no history. A publisher casts one post-commit notice and the
  hub hands it to every authenticated change socket. Each socket owns its
  subscriptions, authorization, and per-connection sequence.
  """

  use GenServer

  @max_mailbox 1_000

  defstruct sockets: %{}

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @spec register(server(), pid()) :: :ok
  def register(server \\ __MODULE__, pid \\ self()),
    do: GenServer.call(server, {:register, pid})

  @spec unregister(server(), pid()) :: :ok
  def unregister(server \\ __MODULE__, pid \\ self()),
    do: GenServer.cast(server, {:unregister, pid})

  @spec publish(server(), map()) :: :ok
  def publish(server \\ __MODULE__, notice) when is_map(notice) do
    GenServer.cast(server, {:publish, notice})
  end

  @spec accepted(server(), GenServer.server() | nil, map(), term()) :: :ok
  def accepted(server \\ __MODULE__, db, call, result),
    do: GenServer.cast(server, {:accepted, db, call, result})

  @spec denied(server(), map(), map()) :: :ok
  def denied(server \\ __MODULE__, call, error),
    do: GenServer.cast(server, {:denied, call, error})

  @spec committed(server(), String.t(), map(), map()) :: :ok
  def committed(server \\ __MODULE__, class, payload, refs),
    do: GenServer.cast(server, {:committed, class, payload, refs})

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:register, pid}, _from, state) do
    case state.sockets[pid] do
      nil ->
        monitor = Process.monitor(pid)
        {:reply, :ok, %{state | sockets: Map.put(state.sockets, pid, monitor)}}

      _monitor ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:unregister, pid}, state) do
    {monitor, sockets} = Map.pop(state.sockets, pid)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:noreply, %{state | sockets: sockets}}
  end

  def handle_cast({:publish, notice}, state) do
    fanout(state, notice)
    {:noreply, state}
  end

  def handle_cast({:accepted, db, call, result}, state) do
    Enum.each(Tightbeam.Firehose.Publisher.accepted_notices(db, call, result), &fanout(state, &1))
    {:noreply, state}
  end

  def handle_cast({:denied, call, error}, state) do
    Enum.each(Tightbeam.Firehose.Publisher.denied_notices(call, error), &fanout(state, &1))
    {:noreply, state}
  end

  def handle_cast({:committed, class, payload, refs}, state) do
    fanout(state, Tightbeam.Firehose.Publisher.committed_notice(class, payload, refs))
    {:noreply, state}
  end

  defp fanout(state, notice) do
    Enum.each(state.sockets, fn {pid, _monitor} ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, length} when length >= @max_mailbox -> send(pid, :firehose_overflow)
        {:message_queue_len, _length} -> send(pid, {:firehose_notice, notice})
        nil -> :ok
      end
    end)
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    sockets =
      case state.sockets[pid] do
        ^monitor -> Map.delete(state.sockets, pid)
        _other -> state.sockets
      end

    {:noreply, %{state | sockets: sockets}}
  end
end
