defmodule Tightbeam.Spinup.Flight do
  @moduledoc """
  Single-flight adapter provisioning per host — the design contract SMOKE §11
  step 43 surfaced by crashing a gateway mid-turn and watching the reboot.

  The adapters directory is SHARED across harnesses, and npm rewrites
  `node_modules` while it works: a provision for one harness momentarily
  unlinks another's already-installed binary. On the crashed boot the
  recovered turn's notice spawned claude into exactly that window and died
  with ENOENT — a failure whose cause was two seconds of internal churn.

  Two obligations, both edges, no numbers:
  - `run/2` serializes provisioning per host: a second provision for the same
    host queues behind the first instead of interleaving npm work in the same
    directory.
  - `await/1` lets a LAUNCH wait out a provision in flight for its host: it
    returns immediately when nothing is in flight (the permanent steady
    state), else when the current flight lands. The wait is bounded by the
    provision's own completion — reality, not a timeout — and a launch that
    then still finds no binary fails with the genuine ENOENT it earned.

  This never sits on the path of a prompt to a RUNNING agent (T-CONCURRENCY
  corollary): only an adapter BOOT consults it, and only lifecycle mutations
  run inside it.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc "Run `fun` as the single provisioning flight for `host`; queued if one is in flight."
  @spec run(GenServer.server(), String.t(), (-> result)) :: result when result: term()
  def run(server \\ __MODULE__, host, fun) do
    # A context with no Flight process (unit tests, bare Spinup use) has no
    # concurrent provisioning to serialize — run directly rather than refuse.
    if is_atom(server) and is_nil(GenServer.whereis(server)) do
      fun.()
    else
      :ok = GenServer.call(server, {:begin, host}, :infinity)

      try do
        fun.()
      after
        GenServer.call(server, {:land, host}, :infinity)
      end
    end
  end

  @doc "Return once no provisioning flight is up for `host` (immediately when idle)."
  @spec await(GenServer.server(), String.t()) :: :ok
  def await(server \\ __MODULE__, host) do
    if is_atom(server) and is_nil(GenServer.whereis(server)),
      do: :ok,
      else: GenServer.call(server, {:await, host}, :infinity)
  end

  @impl true
  def init(:ok), do: {:ok, %{flying: MapSet.new(), queued: %{}}}

  @impl true
  def handle_call({:begin, host}, from, state) do
    if MapSet.member?(state.flying, host) do
      {:noreply, enqueue(state, host, {:begin, from})}
    else
      {:reply, :ok, %{state | flying: MapSet.put(state.flying, host)}}
    end
  end

  def handle_call({:land, host}, _from, state) do
    waiters = state.queued |> Map.get(host, []) |> Enum.reverse()
    {begins, awaits} = Enum.split_with(waiters, &match?({:begin, _}, &1))

    case begins do
      [] ->
        # Runway clear: release every launch that was waiting out the churn.
        Enum.each(awaits, fn {:await, from} -> GenServer.reply(from, :ok) end)

        {:reply, :ok,
         %{
           state
           | flying: MapSet.delete(state.flying, host),
             queued: Map.delete(state.queued, host)
         }}

      [{:begin, next} | rest] ->
        # Hand the flight to the next queued provision. Launch awaiters keep
        # waiting — they need the churn STOPPED, not merely handed over.
        GenServer.reply(next, :ok)

        {:reply, :ok,
         %{state | queued: Map.put(state.queued, host, Enum.reverse(rest ++ awaits))}}
    end
  end

  def handle_call({:await, host}, from, state) do
    if MapSet.member?(state.flying, host) do
      {:noreply, enqueue(state, host, {:await, from})}
    else
      {:reply, :ok, state}
    end
  end

  defp enqueue(state, host, entry),
    do: %{state | queued: Map.update(state.queued, host, [entry], &[entry | &1])}
end
