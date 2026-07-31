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
    calls per machine (no thundering herd after an adapter bounce, and no machine
    queues behind another machine's recovery). session/load failure → that session
    degraded + turn failed with reason.
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
  `:adapter_context` fun (`adapter_key -> keyword`) capturing lower-tier state
  before the Adapter starts; `:adapter_opts` fun
  (`(adapter_key, context) -> keyword` — cmd/home/cwd/env assembled lazily by
  the Adapter, incl. TIGHTBEAM_HOME + PATH with the CLI bin),
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

  @doc """
  Start or return an adapter using context already captured by the caller.

  Credential lifecycle transitions use this form because the lifecycle owner
  already knows the kind being installed and cannot synchronously answer a
  coordinator callback while it is waiting for the start result.
  """
  @spec adapter_for(GenServer.server(), adapter_key(), keyword()) :: checkout()
  def adapter_for(server, key, context) do
    GenServer.call(server, {:adapter_for, key, context}, 30_000)
  end

  @doc """
  Run `fun` under the machine's re-adoption semaphore (max 3 concurrent). Used
  by lanes performing lazy session/load after a generation bump.
  """
  @spec with_load_slot(GenServer.server(), String.t(), (-> result)) :: result when result: term()
  def with_load_slot(server \\ __MODULE__, machine, fun) do
    slot = GenServer.call(server, {:acquire_load_slot, machine, self()}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release_load_slot, machine, slot})
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

  @doc """
  Request planned teardown without synchronously entering the coordinator.

  Used by lower-tier lifecycle owners whose notification must not wait on the
  coordinator or on the Adapter it is closing.
  """
  @spec request_close_adapter(GenServer.server(), adapter_key()) :: :ok
  def request_close_adapter(server \\ __MODULE__, key) do
    GenServer.cast(server, {:close_adapter, key})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       adapter_sup: Keyword.fetch!(opts, :adapter_sup),
       adapter_context: Keyword.fetch!(opts, :adapter_context),
       adapter_opts: Keyword.fetch!(opts, :adapter_opts),
       db: Keyword.get(opts, :db, Tightbeam.DB),
       backoff_base_ms: Keyword.get(opts, :backoff_base_ms, 1_000),
       load_soft_cap: Application.get_env(:tightbeam, :adapter_load_soft_cap, 3),
       failure_circuit: Application.get_env(:tightbeam, :adapter_failure_circuit, 5),
       epoch: mint_epoch(Keyword.get(opts, :db, Tightbeam.DB)),
       on_adapter_ready: Keyword.get(opts, :on_adapter_ready, fn _key_name, _token -> :ok end),
       adapters: %{},
       monitors: %{},
       context_requests: %{},
       load_active: %{},
       load_queue: %{}
     }}
  end

  @impl true
  def handle_call({:adapter_for, key}, from, state) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      entry.circuit == :open ->
        {:reply, {:error, :degraded}, state}

      live_entry?(entry) ->
        {:reply, checkout(entry), state}

      true ->
        {:noreply, capture_adapter_context(key, {:checkout, from}, state)}
    end
  end

  def handle_call({:adapter_for, key, context}, _from, state) do
    adapter_for_reply(key, context, state, true)
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

  def handle_call({:acquire_load_slot, machine, borrower}, from, state) do
    if map_size(machine_active(state, machine)) < state.load_soft_cap do
      {slot, state} = grant_slot(machine, borrower, state)
      {:reply, slot, state}
    else
      queue = :queue.in({from, borrower}, machine_queue(state, machine))
      {:noreply, %{state | load_queue: Map.put(state.load_queue, machine, queue)}}
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
    {:reply, :ok, do_close_adapter(key, state)}
  end

  defp adapter_for_reply(key, context, state, authoritative? \\ false) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      entry.circuit == :open ->
        {:reply, {:error, :degraded}, state}

      live_entry?(entry) and authoritative? and entry.context != normalize_context(context) ->
        state = do_close_adapter(key, state)
        {reply, state} = start_adapter(key, state.adapters[key], state, context)
        {:reply, reply, state}

      live_entry?(entry) ->
        {:reply, checkout(entry), state}

      true ->
        {reply, state} = start_adapter(key, entry, state, context)
        {:reply, reply, state}
    end
  end

  @impl true
  def handle_cast({:close_adapter, key}, state) do
    {:noreply, do_close_adapter(key, state)}
  end

  def handle_cast({:release_load_slot, machine, slot}, state) do
    {:noreply, release_slot(machine, slot, state)}
  end

  defp do_close_adapter(key, state) do
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
        entry = %{
          entry
          | pid: nil,
            monitor: nil,
            ready: false,
            generation: entry.generation + 1,
            context: nil
        }

        %{
          state
          | adapters: Map.put(state.adapters, key, entry),
            monitors: Map.delete(state.monitors, ref)
        }

      _ ->
        state
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    context_request = context_request_for_monitor(state.context_requests, ref)

    cond do
      match?({_request_ref, _request}, context_request) ->
        {request_ref, request} = context_request
        requests = Map.delete(state.context_requests, request_ref)
        state = %{state | context_requests: requests}

        {:noreply,
         finish_context_request(request, {:error, {:context_worker_exit, reason}}, state)}

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
              context: nil,
              last_failure: {died_at, reason}
          }

          {:noreply, %{state | adapters: Map.put(state.adapters, key, entry)}}
        else
          {:noreply, state}
        end

      load_slot = slot_for_monitor(state.load_active, ref) ->
        {machine, slot} = load_slot
        {:noreply, release_slot(machine, slot, state, false)}

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
        state = put_in(state.adapters[key], %{entry | timer: nil})
        {:noreply, capture_adapter_context(key, {:restart, generation}, state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:adapter_context_captured, request_ref, result}, state) do
    case Map.pop(state.context_requests, request_ref) do
      {nil, requests} ->
        {:noreply, %{state | context_requests: requests}}

      {%{monitor: monitor} = request, requests} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | context_requests: requests}
        {:noreply, finish_context_request(request, result, state)}
    end
  end

  defp start_adapter(key, entry, state, context) do
    # Context is resolved before Adapter boot. Generic reads arrive from a
    # monitored worker; credential-lifecycle starts supply their known context.
    adapter_context = context

    # Opts building (incl. remote home delivery) is potentially expensive or
    # hangable — a fn defers it into the adapter's own process (lazy boot via
    # its handle_continue), so this coordinator NEVER blocks on a slow or
    # dead host. Boot failures arrive as :DOWN — the uniform recovery path.
    adapter_opts = state.adapter_opts
    coordinator = self()

    boot = fn ->
      adapter_opts.(key, adapter_context) ++
        [on_ready: fn -> send(coordinator, {:adapter_ready, key}) end]
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
            ready: false,
            context: normalize_context(adapter_context)
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
      last_failure: nil,
      context: nil
    }
  end

  defp capture_adapter_context(key, purpose, state) do
    owner = self()
    request_ref = make_ref()
    adapter_context = state.adapter_context

    {_pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, adapter_context.(key)}
          rescue
            error -> {:error, {:error, error, __STACKTRACE__}}
          catch
            kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
          end

        send(owner, {:adapter_context_captured, request_ref, result})
      end)

    request = %{key: key, purpose: purpose, monitor: monitor}
    %{state | context_requests: Map.put(state.context_requests, request_ref, request)}
  end

  defp finish_context_request(%{key: key, purpose: {:checkout, from}}, {:ok, context}, state) do
    {:reply, reply, state} = adapter_for_reply(key, context, state)
    GenServer.reply(from, reply)
    state
  end

  defp finish_context_request(%{purpose: {:checkout, from}}, {:error, reason}, state) do
    GenServer.reply(from, {:error, {:adapter_context_failed, reason}})
    state
  end

  defp finish_context_request(
         %{key: key, purpose: {:restart, generation}},
         {:ok, context},
         state
       ) do
    case state.adapters[key] do
      %{generation: ^generation, pid: nil} = entry ->
        {_reply, state} = start_adapter(key, entry, state, context)
        state

      _ ->
        state
    end
  end

  defp finish_context_request(
         %{key: key, purpose: {:restart, generation}},
         {:error, reason},
         state
       ) do
    case state.adapters[key] do
      %{generation: ^generation, pid: nil} = entry ->
        timer = Process.send_after(self(), {:restart_adapter, key, generation}, backoff(state, 1))

        entry = %{
          entry
          | timer: timer,
            last_failure: {generation, {:adapter_context_failed, reason}}
        }

        put_in(state.adapters[key], entry)

      _ ->
        state
    end
  end

  defp live_entry?(entry), do: is_pid(entry.pid) and Process.alive?(entry.pid)
  defp checkout(entry), do: {:ok, entry.pid, entry.generation}
  defp normalize_context(context), do: context |> Map.new() |> Enum.sort()

  defp context_request_for_monitor(requests, monitor) do
    Enum.find(requests, fn {_request_ref, request} -> request.monitor == monitor end)
  end

  defp backoff(state, failures),
    do: min(state.backoff_base_ms * Integer.pow(2, max(failures - 1, 0)), 60_000)

  defp grant_slot(machine, borrower, state) do
    slot = make_ref()
    monitor = Process.monitor(borrower)

    active =
      Map.put(machine_active(state, machine), slot, %{borrower: borrower, monitor: monitor})

    load_active = Map.put(state.load_active, machine, active)
    {slot, %{state | load_active: load_active}}
  end

  defp release_slot(machine, slot, state, demonitor? \\ true) do
    case Map.pop(machine_active(state, machine), slot) do
      {nil, _} ->
        state

      {%{monitor: monitor}, active} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])

        state =
          %{state | load_active: put_unless_empty(state.load_active, machine, active)}

        grant_next(machine, state)
    end
  end

  defp grant_next(machine, state) do
    case :queue.out(machine_queue(state, machine)) do
      {:empty, _} ->
        %{state | load_queue: Map.delete(state.load_queue, machine)}

      {{:value, {from, borrower}}, queue} ->
        state = %{state | load_queue: put_queue(state.load_queue, machine, queue)}

        if Process.alive?(borrower) do
          {slot, state} = grant_slot(machine, borrower, state)
          GenServer.reply(from, slot)
          state
        else
          grant_next(machine, state)
        end
    end
  end

  defp slot_for_monitor(active, ref) do
    Enum.find_value(active, fn {machine, slots} ->
      Enum.find_value(slots, fn {slot, entry} ->
        if entry.monitor == ref, do: {machine, slot}
      end)
    end)
  end

  defp machine_active(state, machine), do: Map.get(state.load_active, machine, %{})
  defp machine_queue(state, machine), do: Map.get(state.load_queue, machine, :queue.new())

  defp put_unless_empty(map, key, entries) when map_size(entries) == 0, do: Map.delete(map, key)
  defp put_unless_empty(map, key, entries), do: Map.put(map, key, entries)

  defp put_queue(map, key, queue) do
    if :queue.is_empty(queue), do: Map.delete(map, key), else: Map.put(map, key, queue)
  end
end
