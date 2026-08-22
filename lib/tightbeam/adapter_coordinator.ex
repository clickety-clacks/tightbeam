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
  - Readiness is tracked explicitly — a fresh entry
    has zero failures and a closed circuit without ever having booted, so only
    `{:adapter_ready, key, pid}` may mark a key ready, and only for the
    INSTANCE it names.
  - FAILURE MEMORY is ATTEMPT-SCOPED: `last_failure` records {generation, reason}
    and is only served to a caller asking about that same generation. A
    replacement adapter's death must never be labelled with its predecessor's
    reason (cross-review F4).
  """

  use GenServer

  @adapter_readiness_timeout 185_000
  @adapter_checkout_timeout 190_000

  @type adapter_key :: Tightbeam.Placement.adapter_key()

  @typedoc "What a lane needs to run a turn: the adapter pid and the generation it belongs to."
  @type checkout ::
          {:ok, pid(), generation :: pos_integer()}
          | {:error, term()}

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
    GenServer.call(server, {:adapter_for, key}, @adapter_checkout_timeout)
  end

  @doc "The adapter checkout used by a claimed turn; it has no elapsed-time failure."
  @spec adapter_for_turn(GenServer.server(), adapter_key()) :: checkout()
  def adapter_for_turn(server \\ __MODULE__, key) do
    GenServer.call(server, {:adapter_for, key}, @adapter_checkout_timeout)
  end

  @doc """
  Start or return an adapter using context already captured by the caller.

  Credential lifecycle transitions use this form because the lifecycle owner
  already knows the kind being installed and cannot synchronously answer a
  coordinator callback while it is waiting for the start result.
  """
  @spec adapter_for(GenServer.server(), adapter_key(), keyword()) :: checkout()
  def adapter_for(server, key, context) do
    GenServer.call(server, {:adapter_for, key, context}, @adapter_checkout_timeout)
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

  @doc "Durable launch ledger for operator diagnosis, newest launch first."
  @spec harness_processes(GenServer.server()) :: [Tightbeam.HarnessProcess.row()]
  def harness_processes(server \\ __MODULE__), do: GenServer.call(server, :harness_processes)

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

  @doc """
  Whether the adapter for `key` has completed boot RIGHT NOW.

  Readiness is entry state that only `{:adapter_ready, key, pid}` sets, so this
  is the one honest way to ask; `adapter_for/2` answers a different question and
  checks an adapter out to do it. Health is the substrate's to expose — this
  reports it and decides nothing.
  """
  @spec ready?(GenServer.server(), adapter_key()) :: boolean()
  def ready?(server \\ __MODULE__, key), do: GenServer.call(server, {:ready?, key})

  @doc "The canonical key string `<harness>:<preset>@<host>`, exactly as /version renders it."
  @spec key_name(adapter_key()) :: String.t()
  def key_name({harness, archetype, host}), do: "#{harness}:#{archetype}@#{host}"

  @doc """
  Best-effort planned teardown of the currently running adapter for `key`.
  Bumps the generation: the successor's ready token must outrank every token
  stamped against the closed process, exactly as after a crash.
  """
  @spec close_adapter(GenServer.server(), adapter_key()) :: :ok | {:error, term()}
  def close_adapter(server \\ __MODULE__, key) do
    GenServer.call(server, {:close_adapter, key}, 30_000)
  catch
    :exit, reason -> {:error, {:coordinator_unavailable, reason}}
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
    db = Keyword.get(opts, :db, Tightbeam.DB)
    :ok = Tightbeam.HarnessProcess.ensure_schema(db)
    :ok = Tightbeam.HarnessProcess.reconcile(db)
    :ok = Tightbeam.CommandExecutions.ensure_schema(db)
    :ok = Tightbeam.CommandExecutions.reconcile(db)

    {:ok,
     %{
       adapter_sup: Keyword.fetch!(opts, :adapter_sup),
       adapter_context: Keyword.fetch!(opts, :adapter_context),
       adapter_opts: Keyword.fetch!(opts, :adapter_opts),
       db: db,
       park_grace_ms: Keyword.get(opts, :park_grace_ms, 10_000),
       backoff_base_ms: Keyword.get(opts, :backoff_base_ms, 1_000),
       load_soft_cap: Application.get_env(:tightbeam, :adapter_load_soft_cap, 3),
       failure_circuit: Application.get_env(:tightbeam, :adapter_failure_circuit, 5),
       readiness_timeout_ms: Keyword.get(opts, :readiness_timeout_ms, @adapter_readiness_timeout),
       adapters: %{},
       monitors: %{},
       # Monitor refs of adapter INSTANCES that completed boot. Readiness on the
       # entry describes whichever adapter the entry currently points at, which
       # for an absorbed death is the REPLACEMENT — so a question about the
       # instance that just died has to be keyed on something unique to it, and
       # its monitor ref is exactly that.
       ready_refs: MapSet.new(),
       load_active: %{},
       load_queue: %{}
     }}
  end

  @impl true
  def handle_call({:adapter_for, key}, from, state) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      ready_entry?(entry) ->
        {:reply, checkout(entry), state}

      readiness_pending?(entry) ->
        {:noreply, add_waiter(key, from, state)}

      Tightbeam.HarnessProcess.fenced?(state.db, key) ->
        {:reply, {:error, {:park_fenced, key_name(key)}}, state}

      entry.circuit == :open ->
        {:reply, {:error, :degraded}, state}

      true ->
        {:noreply, begin_readiness(key, entry, state, :capture, from)}
    end
  end

  def handle_call({:adapter_for, key, context}, from, state) do
    adapter_for_reply(key, context, from, state, true)
  end

  def handle_call({:ready?, key}, _from, state) do
    {:reply, match?(%{ready: true}, state.adapters[key]), state}
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

  def handle_call(:harness_processes, _from, state) do
    {:reply, Tightbeam.HarnessProcess.list(state.db), state}
  end

  def handle_call(
        {:tightbeam_command, %Tightbeam.CommandEdge.CredentialPark{} = command},
        _from,
        state
      ) do
    command = Tightbeam.CommandEdge.validate_command!(command)

    {result, state} =
      Enum.reduce_while(command.adapter_keys, {:ok, state}, fn key, {:ok, state} ->
        case do_close_adapter(key, state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {{:error, _reason} = error, state} -> {:halt, {error, state}}
        end
      end)

    {:reply, result, state}
  end

  def handle_call({:close_adapter, key}, _from, state) do
    {result, state} = do_close_adapter(key, state)
    {:reply, result, state}
  end

  defp adapter_for_reply(key, context, from, state, authoritative?) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      authoritative? and readiness_pending?(entry) and
          entry.context != normalize_context(context) ->
        {:noreply, replace_pending_readiness(key, entry, state, context, from)}

      live_entry?(entry) and authoritative? and entry.context != normalize_context(context) ->
        case do_close_adapter(key, state) do
          {:ok, state} ->
            {:noreply, begin_readiness(key, state.adapters[key], state, context, from)}

          {{:error, _reason} = error, state} ->
            {:reply, error, state}
        end

      ready_entry?(entry) ->
        {:reply, checkout(entry), state}

      readiness_pending?(entry) ->
        {:noreply, add_waiter(key, from, state)}

      Tightbeam.HarnessProcess.fenced?(state.db, key) ->
        {:reply, {:error, {:park_fenced, key_name(key)}}, state}

      # THE CIRCUIT DOES NOT GATE CREDENTIAL INSTALLATION (the credential-swap
      # incident, 2026-08-14). It protects agent connections from a dead
      # harness; it has no authority over an operator installing a credential.
      # `authoritative?` is set only by the credential lifecycle, whose one
      # caller is `start_provider_runtime`.
      #
      # Conflating them deadlocked recovery by construction. The circuit is
      # guaranteed open exactly when a credential has stopped working — which is
      # the only reason anyone replaces one — so the latch vetoed the single
      # call that could unlatch it. Onboarding reported "Successfully logged in"
      # and then :degraded, the ceremony read that as a bad credential, and the
      # replacement was rolled back. Measured live: three onboardings left the
      # store still holding the original credential, and recovery needed an
      # operator restarting the gateway.
      entry.circuit == :open and not authoritative? ->
        {:reply, {:error, :degraded}, state}

      true ->
        {:noreply, begin_readiness(key, entry, state, context, from)}
    end
  end

  @impl true
  def handle_cast({:close_adapter, key}, state) do
    {_result, state} = do_close_adapter(key, state)
    {:noreply, state}
  end

  def handle_cast({:release_load_slot, machine, slot}, state) do
    {:noreply, release_slot(machine, slot, state)}
  end

  defp do_close_adapter(key, state) do
    {:ok, process_row} = Tightbeam.HarnessProcess.begin_park(state.db, key)
    state = cancel_pending_starts(key, state)

    exited? =
      case state.adapters[key] do
        %{pid: pid, monitor: monitor} when is_pid(pid) and is_reference(monitor) ->
          Tightbeam.Acp.Adapter.request_close(pid)

          case await_adapter_exit(monitor, pid, state.park_grace_ms) do
            # The park asked for :normal and got a FAULT: this adapter was
            # killed or crashed inside the park window. The selective receive
            # below is the only place that death is ever observed —
            # handle_info/2 never sees the :DOWN, and retire_adapter flushes
            # whatever arrives later — so dropping the reason here is the
            # difference between a recorded death and no record at all.
            # Recording is unconditional for a genuine death (#14); it is the
            # ACTION that stays behind park's state.
            {:exited, reason} when reason != :normal ->
              :ok =
                record_adapter_down(
                  state,
                  key,
                  MapSet.member?(state.ready_refs, monitor),
                  reason,
                  "absorbed=false parked=true"
                )

              true

            {:exited, :normal} ->
              true

            :grace_expired ->
              false
          end

        %{pid: pid} when is_pid(pid) ->
          Tightbeam.Acp.Adapter.request_close(pid)
          false

        _ ->
          false
      end

    reconcile_result =
      case process_row do
        :no_launch -> :ok
        _row when exited? -> Tightbeam.HarnessProcess.reconcile_key(state.db, key)
        row -> Tightbeam.HarnessProcess.park(state.db, row)
      end

    result = if reconcile_result == :already_resolved, do: :ok, else: reconcile_result
    state = retire_adapter(key, state)
    if result == :ok, do: Tightbeam.HarnessProcess.complete_park(state.db, key)

    {result, state}
  end

  # The REASON comes back, not just the fact of an exit. "Closed as asked" and
  # "was killed while we asked" are different deaths wearing the same boolean,
  # and only the reason tells them apart.
  defp await_adapter_exit(monitor, pid, grace_ms) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} -> {:exited, reason}
    after
      grace_ms -> :grace_expired
    end
  end

  defp cancel_pending_starts(key, state) do
    case state.adapters[key] do
      %{timer: timer} = entry ->
        if is_reference(timer), do: Process.cancel_timer(timer)

        state =
          if readiness_pending?(entry),
            do: terminate_readiness_generation(key, entry, state, true),
            else: state

        Enum.each(entry.waiters, fn {monitor, from} ->
          Process.demonitor(monitor, [:flush])
          GenServer.reply(from, {:error, {:parked, key_name(key)}})
        end)

        updated =
          if readiness_pending?(entry) do
            %{
              entry
              | timer: nil,
                generation: entry.generation + 1,
                pid: nil,
                monitor: nil,
                readiness_task: nil,
                readiness_monitor: nil,
                readiness_timer: nil,
                readiness_token: nil,
                waiters: []
            }
          else
            %{entry | timer: nil, generation: entry.generation + 1}
          end

        put_in(state.adapters[key], updated)

      _ ->
        state
    end
  end

  # A death is told to the sessions RESIDENT on the dead engine, not just to the
  # events table. "[adapter recovered]" already reaches those readers when the
  # replacement comes up; without this they only
  # ever saw the good news, and a turn that stopped for an engine fault read as
  # a prompt that vanished — with no marker of its own, because the failure
  # path publishes terminal turn-state and no chat line.
  # `state_detail` names the STATE the adapter died in — the caller knows it and
  # the row must carry it, because "absorbed" and "parked" are the two ways a
  # death reaches this function by a path other than a live monitor.
  defp record_adapter_down(state, key, was_ready?, reason, state_detail) do
    name = key_name(key)

    Tightbeam.EventLog.notice(
      state.db,
      "adapter_down",
      name,
      "#{inspect(reason)} #{state_detail}",
      audience: {:sessions, told_sessions(state.db, key, was_ready?)},
      attention: :normal,
      message:
        "[adapter down]\n\nThe #{name} engine stopped: #{inspect(reason)}. Anything " <>
          "that was running on it stopped with it. Tightbeam restarts the engine and " <>
          "releases this session when it is ready again."
    )
  end

  # Who is told. THE MESSAGE CLAIMS ONLY WHAT IS CERTAIN — this engine stopped —
  # so the audience needs no turn attribution, and with it goes a whole family
  # of ways to be wrong. Three reviews died on the attribution question: which
  # sessions a given adapter INSTANCE halted is not a fact this substrate
  # records. Generation is the only stamp and `start_adapter_unfenced/4` reuses
  # it for a replacement, so an instance is indistinguishable from its
  # successor; `adapterGen IS NULL` covers both "checked this adapter out" and
  # "has not reached checkout"; and the lane can finalize the turn from the same
  # death before this handler runs. Every predicate over that state is an
  # inference, and this message is read by a person.
  #
  # Attributing nothing is not a weaker claim, it is a TRUE one: an adapter
  # death takes the harness context of every session resident on the key,
  # whether or not that session had a turn in flight. That is worth a line in
  # each of their chats, and it is the counterpart of the "[adapter recovered]"
  # probe those same readers already get.
  #
  # ONE gate, on `ready`: a key whose adapter never finished booting was serving
  # nobody, and a boot-failure cascade (five deaths into an open circuit) would
  # otherwise post five lines to every session on the host. A death during boot
  # still gets its row; the turn that asked for it gets its own spawn error.
  defp told_sessions(_db, _key, false = _was_ready?), do: []

  defp told_sessions(db, {harness, "shared", host}, true) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        "SELECT sessionKey FROM sessions WHERE state = 'active' AND harness = ?1 AND host = ?2",
        [Atom.to_string(harness), host]
      )

    Enum.map(rows, fn [session_key] -> session_key end)
  end

  # Sessions reach a key the way the gateway builds one — harness and host,
  # shared archetype — so a key of any other shape is resident to nobody.
  defp told_sessions(_db, _key, _was_ready?), do: []

  defp retire_adapter(key, state) do
    case state.adapters[key] do
      %{pid: pid, monitor: monitor} = entry ->
        if is_reference(monitor), do: Process.demonitor(monitor, [:flush])
        if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)

        entry = %{entry | pid: nil, monitor: nil, ready: false, context: nil, timer: nil}

        %{
          state
          | adapters: Map.put(state.adapters, key, entry),
            monitors:
              if(is_reference(monitor),
                do: Map.delete(state.monitors, monitor),
                else: state.monitors
              ),
            ready_refs: MapSet.delete(state.ready_refs, monitor)
        }

      _ ->
        state
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    readiness_key = readiness_key_for_monitor(state.adapters, ref)

    cond do
      readiness_key != nil ->
        refusal = %{
          code: "adapter_readiness_failed",
          message: "Adapter readiness preflight exited: #{inspect(reason)}"
        }

        {:noreply, finish_readiness(state, readiness_key, {:error, {:launch_refused, refusal}})}

      key = state.monitors[ref] ->
        # Was the instance that just died a WORKING engine? Asked of the ref, so
        # the answer survives a replacement having already taken the entry over.
        was_ready? = MapSet.member?(state.ready_refs, ref)

        state = %{
          state
          | monitors: Map.delete(state.monitors, ref),
            ready_refs: MapSet.delete(state.ready_refs, ref)
        }

        entry = Map.fetch!(state.adapters, key)

        # Stale-:DOWN guard: adapter_for may observe a dead pid
        # (Process.alive? false) and start a replacement BEFORE this :DOWN is
        # processed. If the ref no longer matches the entry's current monitor,
        # the death was already absorbed by that replacement — treating it as
        # a fresh death would nil the new adapter's pid and schedule a
        # spurious restart (adapter leak). Dropping the ref is the cleanup.
        #
        # The guard covers the ACTION, not the RECORD (#14). An absorbed death
        # is still a death: a harness process really exited and whatever was
        # running on it really stopped. Recording inside the guard made a
        # fast-recovered fault indistinguishable from no fault at all — so the
        # record and its notice are unconditional here, and the absorbed ones
        # say so in their detail.
        absorbed? = entry.monitor != ref
        :ok = record_adapter_down(state, key, was_ready?, reason, "absorbed=#{absorbed?}")

        if absorbed? do
          {:noreply, state}
        else
          case Tightbeam.HarnessProcess.settle_proven_dead(state.db, key) do
            :ok ->
              :ok

            :already_resolved ->
              :ok
          end

          failures = entry.failures + 1

          circuit = if failures >= state.failure_circuit, do: :open, else: :closed

          # The death belongs to the generation that DIED, not to the bumped one
          # the replacement will carry — that is the generation a turn holding
          # this adapter checked out, and the only one it can ask about.
          died_at = entry.generation
          generation = entry.generation + 1

          timer =
            if circuit == :closed do
              Process.send_after(
                self(),
                {:restart_adapter, key, generation},
                backoff(state, failures)
              )
            end

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

          state = %{state | adapters: Map.put(state.adapters, key, entry)}

          state =
            if entry.waiters != [] do
              finish_readiness(state, key, {:error, {:adapter_unavailable, reason}})
            else
              state
            end

          {:noreply, state}
        end

      load_slot = slot_for_monitor(state.load_active, ref) ->
        {machine, slot} = load_slot
        {:noreply, release_slot(machine, slot, state, false)}

      true ->
        {:noreply, remove_waiter_monitor(ref, state)}
    end
  end

  def handle_info({:adapter_ready, key, pid, generation, token}, state) do
    case state.adapters[key] do
      %{pid: ^pid, generation: ^generation, readiness_token: ^token} = entry when is_pid(pid) ->
        entry = %{entry | failures: 0, circuit: :closed, ready: true, last_failure: nil}
        state = %{state | ready_refs: put_ready_ref(state.ready_refs, entry.monitor)}
        state = %{state | adapters: Map.put(state.adapters, key, entry)}
        {:noreply, finish_readiness(state, key, {:ok, pid, generation})}

      # A ready message from an instance this entry no longer points at. It
      # died between announcing and being heard; the entry now describes a
      # successor that has not booted, and crediting it would declare a
      # not-yet-serving adapter ready.
      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:adapter_ready, key, pid}, state) do
    generation = get_in(state.adapters, [key, :generation])
    token = get_in(state.adapters, [key, :readiness_token])
    handle_info({:adapter_ready, key, pid, generation, token}, state)
  end

  def handle_info({:adapter_readiness_result, key, generation, token, task, result}, state) do
    case state.adapters[key] do
      %{generation: ^generation, readiness_token: ^token, readiness_task: ^task} = entry ->
        Process.demonitor(entry.readiness_monitor, [:flush])

        case result do
          {:ok, opts, context} ->
            entry = %{entry | context: context}
            state = %{state | adapters: Map.put(state.adapters, key, entry)}
            {:noreply, start_adapter_unfenced(key, entry, state, opts)}

          {:error, refusal} ->
            {:noreply, finish_readiness(state, key, {:error, {:launch_refused, refusal}})}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:adapter_readiness_timeout, key, generation, token}, state) do
    case state.adapters[key] do
      %{generation: ^generation, readiness_token: ^token} = entry ->
        state = terminate_readiness_generation(key, entry, state, true)

        entry = %{
          entry
          | pid: nil,
            monitor: nil,
            ready: false,
            generation: entry.generation + 1
        }

        state = %{state | adapters: Map.put(state.adapters, key, entry)}

        refusal = %{code: "adapter_readiness_timeout", message: "Adapter readiness timed out"}
        {:noreply, finish_readiness(state, key, {:error, {:launch_refused, refusal}})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:restart_adapter, key, generation}, state) do
    case state.adapters[key] do
      %{generation: ^generation, pid: nil} = entry ->
        cond do
          readiness_pending?(entry) ->
            {:noreply, state}

          Tightbeam.HarnessProcess.fenced?(state.db, key) ->
            {:noreply, put_in(state.adapters[key], %{entry | timer: nil})}

          true ->
            state = put_in(state.adapters[key], %{entry | timer: nil})
            {:noreply, begin_readiness(key, entry, state, :capture, nil)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp begin_readiness(key, entry, state, context, from) do
    generation = max(entry.generation, 1)
    owner = self()
    token = make_ref()

    timer =
      Process.send_after(
        owner,
        {:adapter_readiness_timeout, key, generation, token},
        state.readiness_timeout_ms
      )

    adapter_opts = state.adapter_opts
    adapter_context = state.adapter_context
    db = state.db

    {task, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            resolved_context = if context == :capture, do: adapter_context.(key), else: context

            case adapter_opts.(key, resolved_context) do
              {:ok, opts} when is_list(opts) ->
                opts = Keyword.put(opts, :db, db)

                opts =
                  if Keyword.has_key?(opts, :process_identity_dir),
                    do: Tightbeam.HarnessProcess.prepare_launch(opts, db, key),
                    else: opts

                {:ok, opts, normalize_context(resolved_context)}

              {:error, refusal} ->
                {:error, refusal}

              opts when is_list(opts) ->
                opts = Keyword.put(opts, :db, db)

                opts =
                  if Keyword.has_key?(opts, :process_identity_dir),
                    do: Tightbeam.HarnessProcess.prepare_launch(opts, db, key),
                    else: opts

                {:ok, opts, normalize_context(resolved_context)}
            end
          rescue
            error ->
              {:error, %{code: "adapter_readiness_failed", message: Exception.message(error)}}
          end

        send(owner, {:adapter_readiness_result, key, generation, token, self(), result})
      end)

    entry = %{
      entry
      | generation: generation,
        context: if(context == :capture, do: :capturing, else: normalize_context(context)),
        readiness_task: task,
        readiness_monitor: monitor,
        readiness_timer: timer,
        readiness_token: token,
        ready: false,
        waiters: entry.waiters
    }

    state = %{state | adapters: Map.put(state.adapters, key, entry)}
    if from, do: add_waiter(key, from, state), else: state
  end

  defp replace_pending_readiness(key, entry, state, context, from) do
    waiters = live_waiters(entry.waiters)
    state = terminate_readiness_generation(key, entry, state, true)

    replacement = %{
      fresh_entry()
      | generation: entry.generation + 1,
        failures: entry.failures,
        circuit: entry.circuit,
        waiters: waiters
    }

    state = %{state | adapters: Map.put(state.adapters, key, replacement)}
    begin_readiness(key, replacement, state, context, from)
  end

  defp terminate_readiness_generation(key, entry, state, settle?) do
    cancel_timer_flush(
      entry.readiness_timer,
      {:adapter_readiness_timeout, key, entry.generation, entry.readiness_token}
    )

    if is_pid(entry.readiness_task) and Process.alive?(entry.readiness_task),
      do: Process.exit(entry.readiness_task, :kill)

    if is_reference(entry.readiness_monitor),
      do: Process.demonitor(entry.readiness_monitor, [:flush])

    state =
      if is_pid(entry.pid) do
        if is_reference(entry.monitor), do: Process.demonitor(entry.monitor, [:flush])
        _ = DynamicSupervisor.terminate_child(state.adapter_sup, entry.pid)

        %{
          state
          | monitors: Map.delete(state.monitors, entry.monitor),
            ready_refs: MapSet.delete(state.ready_refs, entry.monitor)
        }
      else
        state
      end

    if settle?, do: settle_launch_generation(state.db, key)
    state
  end

  defp live_waiters(waiters) do
    Enum.filter(waiters, fn {_monitor, {pid, _tag}} -> Process.alive?(pid) end)
  end

  defp settle_launch_generation(db, key) do
    case Tightbeam.HarnessProcess.settle_proven_dead(db, key) do
      :ok -> :ok
      :already_resolved -> :ok
    end
  rescue
    _ -> :ok
  end

  defp start_adapter_unfenced(key, entry, state, opts) do
    coordinator = self()
    generation = entry.generation
    token = entry.readiness_token

    opts =
      Keyword.put(opts, :on_ready, fn ->
        send(coordinator, {:adapter_ready, key, self(), generation, token})
      end)

    child = %{
      id: {Tightbeam.Acp.Adapter, key},
      start: {Tightbeam.Acp.Adapter, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }

    case DynamicSupervisor.start_child(state.adapter_sup, child) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        entry = %{
          entry
          | pid: pid,
            monitor: ref,
            ready: false,
            rendezvous: Keyword.get(opts, :readiness_rendezvous, false),
            readiness_task: nil,
            readiness_monitor: nil
        }

        state = %{
          state
          | adapters: Map.put(state.adapters, key, entry),
            monitors: Map.put(state.monitors, ref, key)
        }

        if Keyword.get(opts, :readiness_rendezvous, false) do
          state
        else
          reply_waiters(state, key, {:ok, pid, generation})
        end

      {:error, start_reason} ->
        failures = entry.failures + 1
        circuit = if failures >= state.failure_circuit, do: :open, else: :closed
        generation = max(entry.generation, 1)

        entry = %{
          entry
          | generation: generation,
            failures: failures,
            circuit: circuit,
            ready: false,
            last_failure: {generation, {:adapter_start_failed, start_reason}}
        }

        refusal = %{code: "adapter_start_failed", message: "Adapter failed to start"}

        state
        |> Map.put(:adapters, Map.put(state.adapters, key, entry))
        |> finish_readiness(key, {:error, refusal})
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
      context: nil,
      readiness_task: nil,
      readiness_monitor: nil,
      readiness_timer: nil,
      readiness_token: nil,
      rendezvous: false,
      waiters: []
    }
  end

  defp put_ready_ref(ready_refs, monitor) when is_reference(monitor),
    do: MapSet.put(ready_refs, monitor)

  defp put_ready_ref(ready_refs, _monitor), do: ready_refs

  defp ready_entry?(entry),
    do: entry.ready == true and is_pid(entry.pid) and Process.alive?(entry.pid)

  defp readiness_pending?(entry),
    do:
      is_pid(entry.readiness_task) or (entry.rendezvous and is_pid(entry.pid) and not entry.ready)

  defp add_waiter(key, from, state) do
    monitor = Process.monitor(elem(from, 0))
    update_in(state.adapters[key].waiters, &[{monitor, from} | &1])
  end

  defp finish_readiness(state, key, reply) do
    case state.adapters[key] do
      nil ->
        state

      entry ->
        cancel_timer_flush(
          entry.readiness_timer,
          {:adapter_readiness_timeout, key, entry.generation, entry.readiness_token}
        )

        Enum.each(entry.waiters, fn {monitor, from} ->
          Process.demonitor(monitor, [:flush])
          GenServer.reply(from, reply)
        end)

        entry = %{
          entry
          | readiness_task: nil,
            readiness_monitor: nil,
            readiness_timer: nil,
            readiness_token: nil,
            waiters: []
        }

        %{state | adapters: Map.put(state.adapters, key, entry)}
    end
  end

  defp reply_waiters(state, key, reply) do
    entry = state.adapters[key]

    Enum.each(entry.waiters, fn {monitor, from} ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, reply)
    end)

    put_in(state.adapters[key].waiters, [])
  end

  defp cancel_timer_flush(timer, message) when is_reference(timer) do
    case Process.cancel_timer(timer) do
      false ->
        receive do
          ^message -> :ok
        after
          0 -> :ok
        end

      _remaining ->
        :ok
    end
  end

  defp cancel_timer_flush(_timer, _message), do: :ok

  defp remove_waiter_monitor(ref, state) do
    adapters =
      Map.new(state.adapters, fn {key, entry} ->
        {key,
         %{entry | waiters: Enum.reject(entry.waiters, fn {monitor, _} -> monitor == ref end)}}
      end)

    %{state | adapters: adapters}
  end

  defp readiness_key_for_monitor(adapters, ref) do
    Enum.find_value(adapters, fn {key, entry} ->
      if entry.readiness_monitor == ref, do: key
    end)
  end

  defp live_entry?(entry), do: is_pid(entry.pid) and Process.alive?(entry.pid)
  defp checkout(entry), do: {:ok, entry.pid, entry.generation}
  defp normalize_context(context), do: context |> Map.new() |> Enum.sort()

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
