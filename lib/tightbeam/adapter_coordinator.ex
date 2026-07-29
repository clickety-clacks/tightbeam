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
    death — crash or planned teardown alike — so a successor process is always
    a new generation and its ready token strictly outranks its predecessor's.
    Lanes stamp the generation they ran a turn against; a lane
    seeing a stale generation at next turn start performs session/load LAZILY
    (parent-spec rule: no eager mass re-adoption).
  - Backoff: restart with exponential backoff 1s → 60s cap. After the configured
    consecutive failures the circuit OPENS: the key is marked degraded,
    `adapter_for/2` returns {:error, :degraded} so affected turns fail fast
    with a clear reason, /version|/health reflects it, the gateway stays up.
    A successful restart closes the circuit and resets the count.
  - Re-adoption semaphore: at most the configured number of concurrent session/load
    calls per coordinator (no thundering herd after an adapter bounce). session/load
    failure → that session degraded + turn failed with reason.
  - Planned idle-reap is a coordinator action and its lifecycle event is
    flagged as planned — distinguishable from crashes in lifecycle_events.
  - The coordinator MONITORS adapters (never links); adapter death emits a
    lifecycle event with the exit reason and bumps the generation.
  - HEAL TOKEN: `{coordinatorEpoch, generation}`. The epoch is a DURABLE
    STRICTLY-MONOTONIC integer — one `coordinator_epochs` row inserted at each
    init, its AUTOINCREMENT rowid taken as the epoch. It must be strictly
    ordered, not merely usually: a ULID's random suffix ties arbitrarily WITHIN a
    millisecond (cross-review F2 found a descending pair in 10k draws), so a fast
    restart could mint a LOWER epoch, reject its own ready token as stale, and
    leave the hold wedged — the exact wedge this spec exists to remove.
    Generation is the per-key counter above, which RESETS on restart; comparing
    epoch-first then generation is what makes the comparison restart-stable, so a
    post-restart ready always outranks a token stamped under an older epoch
    (spec s4-operability-v1 §2). Readiness is tracked explicitly — a fresh entry
    has zero failures and a closed circuit without ever having booted, so only
    `{:adapter_ready, key}` may mark a key ready.
  - FAILURE MEMORY is ATTEMPT-SCOPED: `last_failure` records {generation, reason}
    and is only served to a caller asking about that same generation. A
    replacement adapter's death must never be labelled with its predecessor's
    reason (cross-review F4).
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

  @typedoc "Heal token: epoch-first, then generation (see the moduledoc)."
  @type heal_token :: {pos_integer(), non_neg_integer()}

  @doc """
  The heal token for `key` if that adapter is ready RIGHT NOW, else `:not_ready`
  — the LEVEL half of the heal trigger, for a hold that commits after a ready
  event already fired (the lost-edge case).
  """
  @spec ready_token(GenServer.server(), adapter_key()) :: {:ok, heal_token()} | :not_ready
  def ready_token(server \\ __MODULE__, key) do
    GenServer.call(server, {:ready_token, key})
  end

  @doc """
  The reason the adapter for `key` most recently DIED, or nil once it is ready
  again. Boot is lazy and fast-failing, so a turn's first call can arrive after
  the adapter is already gone and exit with a bare `:noproc` — the actionable
  spawn error would then be lost. Remembering the death here makes it available
  to whoever asks, instead of only to whoever happened to have a call pending
  (spec s4-operability-v1 §Defect 1).
  """
  @spec last_failure(GenServer.server(), adapter_key(), non_neg_integer()) :: term() | nil
  def last_failure(server \\ __MODULE__, key, generation) do
    GenServer.call(server, {:last_failure, key, generation})
  end

  @doc "The canonical key string `<harness>:<preset>@<host>`, exactly as /version renders it."
  @spec key_name(adapter_key()) :: String.t()
  def key_name({harness, archetype, host}), do: "#{harness}:#{archetype}@#{host}"

  @doc """
  Order two heal tokens: EPOCH first (ULID, so string order is mint order),
  then generation. `true` when `left` is strictly newer than `right`; a nil
  `right` (never probed) is always outranked.
  """
  @spec newer_token?(heal_token(), heal_token() | nil) :: boolean()
  def newer_token?(_left, nil), do: true

  def newer_token?({epoch, generation}, {prior_epoch, prior_generation}) do
    cond do
      epoch > prior_epoch -> true
      epoch < prior_epoch -> false
      true -> generation > prior_generation
    end
  end

  @doc """
  Mint the next coordinator epoch: a durable strictly-increasing integer. The
  AUTOINCREMENT rowid gives strict ordering across restarts for free, and the
  rows double as a record of every coordinator start.
  """
  @spec mint_epoch(GenServer.server()) :: pos_integer()
  def mint_epoch(db) do
    :ok = ensure_schema(db)

    {:ok, [[epoch]]} =
      Tightbeam.DB.query(db, "INSERT INTO coordinator_epochs (at) VALUES (?1) RETURNING seq", [
        System.system_time(:millisecond)
      ])

    epoch
  end

  @doc """
  The epoch counter's table. Created by the coordinator itself at init rather
  than by the org schema sweep, because the coordinator is also started directly
  (tests, tooling) and its epoch must be durable in every case.
  """
  @spec ensure_schema(GenServer.server()) :: :ok | {:error, term()}
  def ensure_schema(db) do
    Tightbeam.DB.execute(db, """
    CREATE TABLE IF NOT EXISTS coordinator_epochs (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      at  INTEGER NOT NULL
    );
    """)
  end

  @doc "Wire encoding for the `healToken` column: `\"<epoch>:<generation>\"`."
  @spec encode_token(heal_token()) :: String.t()
  def encode_token({epoch, generation}),
    do: Integer.to_string(epoch) <> ":" <> Integer.to_string(generation)

  @doc "Inverse of `encode_token/1`; nil for a NULL/unparsable column."
  @spec decode_token(String.t() | nil) :: heal_token() | nil
  def decode_token(nil), do: nil

  def decode_token(encoded) do
    with [epoch, generation] <- String.split(encoded, ":", parts: 2),
         {epoch, ""} <- Integer.parse(epoch),
         {generation, ""} <- Integer.parse(generation) do
      {epoch, generation}
    else
      _ -> nil
    end
  end

  @doc """
  Best-effort planned teardown of the currently running adapter for `key`.
  Bumps the generation: the successor's ready token must outrank every token
  stamped against the closed process, exactly as after a crash.
  """
  @spec close_adapter(GenServer.server(), adapter_key()) :: :ok
  def close_adapter(server \\ __MODULE__, key) do
    GenServer.call(server, {:close_adapter, key})
  rescue
    _reason -> :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       adapter_sup: Keyword.fetch!(opts, :adapter_sup),
       adapter_opts: Keyword.fetch!(opts, :adapter_opts),
       db: Keyword.get(opts, :db, Tightbeam.DB),
       backoff_base_ms: Keyword.get(opts, :backoff_base_ms, 1_000),
       load_soft_cap: Application.get_env(:tightbeam, :adapter_load_soft_cap, 3),
       failure_circuit: Application.get_env(:tightbeam, :adapter_failure_circuit, 5),
       epoch: mint_epoch(Keyword.get(opts, :db, Tightbeam.DB)),
       on_adapter_ready: Keyword.get(opts, :on_adapter_ready, fn _key_name, _token -> :ok end),
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

  def handle_call({:last_failure, key, generation}, _from, state) do
    # ATTEMPT-SCOPED: serve the reason only to the generation it belongs to. A
    # caller whose adapter died while the coordinator has not yet processed that
    # :DOWN gets nil, not the PREVIOUS attempt's reason — a generic reason is
    # honest, a wrong one is not.
    reply =
      case get_in(state.adapters, [key, :last_failure]) do
        {^generation, reason} -> reason
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:ready_token, key}, _from, state) do
    reply =
      case state.adapters[key] do
        %{ready: true, generation: generation} -> {:ok, {state.epoch, generation}}
        _ -> :not_ready
      end

    {:reply, reply, state}
  end

  def handle_call({:acquire_load_slot, borrower}, from, state) do
    if map_size(state.load_active) < state.load_soft_cap do
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

  def handle_call({:close_adapter, key}, _from, state) do
    case state.adapters[key] do
      %{pid: pid, monitor: ref} = entry when is_pid(pid) ->
        Process.demonitor(ref, [:flush])

        try do
          conn = Tightbeam.Acp.Adapter.conn(pid)
          Tightbeam.Acp.Conn.close(conn)
          GenServer.stop(conn)
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end

        # A planned teardown IS a death in the token algebra: without the bump,
        # the successor's ready re-mints the SAME {epoch, generation} token, and
        # a session re-held on that token (a credential stop/start landing in
        # its retry window) would never be swept (spec s4-operability-v1 §2).
        entry = %{entry | pid: nil, monitor: nil, ready: false, generation: entry.generation + 1}

        {:reply, :ok,
         %{
           state
           | adapters: Map.put(state.adapters, key, entry),
             monitors: Map.delete(state.monitors, ref)
         }}

      _ ->
        {:reply, :ok, state}
    end
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
          circuit = if failures >= state.failure_circuit, do: :open, else: :closed
          # The death belongs to the generation that DIED, not to the bumped one
          # the replacement will carry — that is the generation a turn holding
          # this adapter checked out, and the only one it can ask about.
          died_at = entry.generation
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
              timer: timer,
              ready: false,
              last_failure: {died_at, reason}
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
        entry = %{entry | failures: 0, circuit: :closed, ready: true, last_failure: nil}
        # EDGE half of the heal trigger. The hook is invoked with the FULL token
        # so the sweep can decide replay-vs-new without asking us back (and
        # without this process ever blocking on a DB transaction).
        state.on_adapter_ready.(key_name(key), {state.epoch, entry.generation})
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
        entry = %{
          entry
          | pid: pid,
            monitor: ref,
            generation: generation,
            timer: nil,
            ready: false
        }

        state = %{
          state
          | adapters: Map.put(state.adapters, key, entry),
            monitors: Map.put(state.monitors, ref, key)
        }

        {{:ok, pid, generation}, state}

      {:error, start_reason} ->
        failures = entry.failures + 1
        circuit = if failures >= state.failure_circuit, do: :open, else: :closed
        generation = max(entry.generation, 1)

        timer =
          Process.send_after(
            self(),
            {:restart_adapter, key, generation},
            backoff(state, failures)
          )

        entry = %{
          entry
          | generation: generation,
            failures: failures,
            circuit: circuit,
            timer: timer,
            ready: false,
            last_failure: {generation, {:adapter_start_failed, start_reason}}
        }

        {{:error, :degraded}, %{state | adapters: Map.put(state.adapters, key, entry)}}
    end
  end

  defp fresh_entry do
    %{
      pid: nil,
      monitor: nil,
      generation: 0,
      failures: 0,
      circuit: :closed,
      timer: nil,
      ready: false,
      last_failure: nil
    }
  end

  defp backoff(state, failures),
    do: min(state.backoff_base_ms * Integer.pow(2, max(failures - 1, 0)), 60_000)

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
