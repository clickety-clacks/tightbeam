defmodule Tightbeam.AdapterCoordinator do
  @moduledoc """
  Owner of adapter lifecycle (port spec §Adapter lifecycle — this module IS
  that section; no TS equivalent, the TS gateway restarted nothing).

  One `Tightbeam.Acp.Adapter` per adapter key `{harness, archetype, host}`
  (§Placement — a host is part of WHERE an adapter is, so it is part of WHICH
  adapter it is), started
  lazily under a DynamicSupervisor with restart: :temporary — the coordinator
  owns ALL restarts, so `normal` exits and crashes take the same path (no
  supervisor auto-restart racing the coordinator's bookkeeping).

  Invariants (binding):
  - GENERATION: a monotonic integer per adapter key, bumped on every adapter
    death/restart. Lanes stamp the generation they ran a turn against; a lane
    seeing a stale generation at next turn start performs session/load LAZILY
    (parent-spec rule: no eager mass re-adoption).
  - Backoff: restart with exponential backoff 1s → 60s cap. After 5
    consecutive failures the circuit OPENS: the key is marked degraded,
    `adapter_for/2` returns {:error, :degraded} so affected turns fail fast
    with a clear reason, /version|/health reflects it, the gateway stays up.
    A successful restart closes the circuit and resets the count.
  - Re-adoption semaphore: at most 3 concurrent session/load calls per
    coordinator (no thundering herd after an adapter bounce). session/load
    failure → that session degraded + turn failed with reason.
  - Planned idle-reap is a coordinator action and its lifecycle event is
    flagged as planned — distinguishable from crashes in lifecycle_events.
  - The coordinator MONITORS adapters (never links); adapter death emits a
    lifecycle event with the exit reason and bumps the generation.
  """

  use GenServer

  @type adapter_key :: Tightbeam.Placement.adapter_key()

  @typedoc "What a lane needs to run a turn: the adapter pid and the generation it belongs to."
  @type checkout :: {:ok, pid(), generation :: pos_integer()} | {:error, :degraded}

  @doc """
  Start the coordinator. Opts: `:adapter_sup` (the DynamicSupervisor),
  `:adapter_opts` fun (`adapter_key -> keyword` — cmd/home/cwd/env assembled
  by the composition root, incl. TIGHTBEAM_HOME + PATH with the CLI bin),
  `:db`, `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The adapter for a key, starting it lazily on first use. Returns the pid AND
  the current generation (the lane stamps it against the turn). Degraded key →
  {:error, :degraded} — fail the turn fast, never queue behind a dead adapter.
  """
  @spec adapter_for(GenServer.server(), adapter_key()) :: checkout()
  def adapter_for(server \\ __MODULE__, key) do
    GenServer.call(server, {:adapter_for, key}, 30_000)
  end

  @doc "Current generation for a key (0 if never started) — the lane's staleness probe."
  @spec generation(GenServer.server(), adapter_key()) :: non_neg_integer()
  def generation(server \\ __MODULE__, key) do
    GenServer.call(server, {:generation, key})
  end

  @doc """
  Run `fun` under the re-adoption semaphore (max 3 concurrent). Used by lanes
  performing lazy session/load after a generation bump.
  """
  @spec with_load_slot(GenServer.server(), (-> result)) :: result when result: term()
  def with_load_slot(server \\ __MODULE__, fun) do
    slot = GenServer.call(server, {:acquire_load_slot, self()}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release_load_slot, slot})
    end
  end

  @doc "Health projection for /version: per-key %{generation, circuit, consecutive_failures}."
  @spec health(GenServer.server()) :: %{optional(String.t()) => map()}
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       adapter_sup: Keyword.fetch!(opts, :adapter_sup),
       adapter_opts: Keyword.fetch!(opts, :adapter_opts),
       db: Keyword.get(opts, :db, Tightbeam.DB),
       backoff_base_ms: Keyword.get(opts, :backoff_base_ms, 1_000),
       adapters: %{},
       monitors: %{},
       load_active: %{},
       load_queue: :queue.new()
     }}
  end

  @impl true
  def handle_call({:adapter_for, key}, _from, state) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      entry.circuit == :open ->
        {:reply, {:error, :degraded}, state}

      is_pid(entry.pid) and Process.alive?(entry.pid) ->
        {:reply, {:ok, entry.pid, entry.generation}, state}

      true ->
        {reply, state} = start_adapter(key, entry, state)
        {:reply, reply, state}
    end
  end

  def handle_call({:generation, key}, _from, state) do
    {:reply, get_in(state.adapters, [key, :generation]) || 0, state}
  end

  def handle_call({:acquire_load_slot, borrower}, from, state) do
    if map_size(state.load_active) < 3 do
      {slot, state} = grant_slot(borrower, state)
      {:reply, slot, state}
    else
      {:noreply, %{state | load_queue: :queue.in({from, borrower}, state.load_queue)}}
    end
  end

  def handle_call(:health, _from, state) do
    health =
      Map.new(state.adapters, fn {key, entry} ->
        {key_name(key),
         %{
           generation: entry.generation,
           circuit: entry.circuit,
           consecutive_failures: entry.failures
         }}
      end)

    {:reply, health, state}
  end

  @impl true
  def handle_cast({:release_load_slot, slot}, state) do
    {:noreply, release_slot(slot, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      key = state.monitors[ref] ->
        state = %{state | monitors: Map.delete(state.monitors, ref)}
        entry = Map.fetch!(state.adapters, key)

        # Stale-:DOWN guard: adapter_for may observe a dead pid
        # (Process.alive? false) and start a replacement BEFORE this :DOWN is
        # processed. If the ref no longer matches the entry's current monitor,
        # the death was already absorbed by that replacement — treating it as
        # a fresh death would nil the new adapter's pid and schedule a
        # spurious restart (adapter leak). Dropping the ref is the cleanup.
        if entry.monitor == ref do
          :ok =
            Tightbeam.EventLog.lifecycle(state.db, "adapter_down", key_name(key), inspect(reason))

          failures = entry.failures + 1
          circuit = if failures >= 5, do: :open, else: :closed
          generation = entry.generation + 1
          delay = backoff(state, failures)
          timer = Process.send_after(self(), {:restart_adapter, key, generation}, delay)

          entry = %{
            entry
            | pid: nil,
              monitor: nil,
              generation: generation,
              failures: failures,
              circuit: circuit,
              timer: timer
          }

          {:noreply, %{state | adapters: Map.put(state.adapters, key, entry)}}
        else
          {:noreply, state}
        end

      slot = slot_for_monitor(state.load_active, ref) ->
        {:noreply, release_slot(slot, state, false)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:adapter_ready, key}, state) do
    case state.adapters[key] do
      %{pid: pid} = entry when is_pid(pid) ->
        entry = %{entry | failures: 0, circuit: :closed}
        {:noreply, %{state | adapters: Map.put(state.adapters, key, entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:restart_adapter, key, generation}, state) do
    case state.adapters[key] do
      %{generation: ^generation, pid: nil} = entry ->
        {_reply, state} = start_adapter(key, %{entry | timer: nil}, state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp start_adapter(key, entry, state) do
    # Opts building (incl. remote home delivery) is potentially expensive or
    # hangable — a fn defers it into the adapter's own process (lazy boot via
    # its handle_continue), so this coordinator NEVER blocks on a slow or
    # dead host. Boot failures arrive as :DOWN — the uniform recovery path.
    adapter_opts = state.adapter_opts
    coordinator = self()

    boot = fn ->
      adapter_opts.(key) ++ [on_ready: fn -> send(coordinator, {:adapter_ready, key}) end]
    end

    child = %{
      id: {Tightbeam.Acp.Adapter, key},
      start: {Tightbeam.Acp.Adapter, :start_link, [boot]},
      restart: :temporary,
      type: :worker
    }

    case DynamicSupervisor.start_child(state.adapter_sup, child) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        generation = max(entry.generation, 1)

        # Boot is LAZY: a spawned pid proves nothing. failures/circuit are
        # reset only by {:adapter_ready, key} — the completed-boot signal.
        entry = %{entry | pid: pid, monitor: ref, generation: generation, timer: nil}

        state = %{
          state
          | adapters: Map.put(state.adapters, key, entry),
            monitors: Map.put(state.monitors, ref, key)
        }

        {{:ok, pid, generation}, state}

      {:error, _reason} ->
        failures = entry.failures + 1
        circuit = if failures >= 5, do: :open, else: :closed
        generation = max(entry.generation, 1)
        timer = Process.send_after(self(), {:restart_adapter, key, generation}, backoff(state, failures))

        entry = %{
          entry
          | generation: generation,
            failures: failures,
            circuit: circuit,
            timer: timer
        }

        {{:error, :degraded}, %{state | adapters: Map.put(state.adapters, key, entry)}}
    end
  end

  defp fresh_entry do
    %{pid: nil, monitor: nil, generation: 0, failures: 0, circuit: :closed, timer: nil}
  end

  defp backoff(state, failures), do: min(state.backoff_base_ms * Integer.pow(2, max(failures - 1, 0)), 60_000)
  defp key_name({harness, archetype, host}), do: "#{harness}:#{archetype}@#{host}"

  defp grant_slot(borrower, state) do
    slot = make_ref()
    monitor = Process.monitor(borrower)
    active = Map.put(state.load_active, slot, %{borrower: borrower, monitor: monitor})
    {slot, %{state | load_active: active}}
  end

  defp release_slot(slot, state, demonitor? \\ true) do
    case Map.pop(state.load_active, slot) do
      {nil, _} ->
        state

      {%{monitor: monitor}, active} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])
        grant_next(%{state | load_active: active})
    end
  end

  defp grant_next(state) do
    case :queue.out(state.load_queue) do
      {:empty, _} ->
        state

      {{:value, {from, borrower}}, queue} ->
        if Process.alive?(borrower) do
          {slot, state} = grant_slot(borrower, %{state | load_queue: queue})
          GenServer.reply(from, slot)
          state
        else
          grant_next(%{state | load_queue: queue})
        end
    end
  end

  defp slot_for_monitor(active, ref) do
    Enum.find_value(active, fn {slot, entry} -> if entry.monitor == ref, do: slot end)
  end
end
