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

    The circuit protects AGENT CONNECTIONS from a dead harness. It has no
    authority over CREDENTIAL INSTALLATION, and the two must not be mixed
    (ruled 2026-08-14, after the credential-swap incident). Onboarding reaches
    the coordinator through `activate_provider_runtime/3`, which bypasses
    the circuit and clears the failure history before attempting — see
    `adapter_for_reply/4`. Otherwise a latched key vetoes the only call that
    can unlatch it: the circuit is guaranteed open exactly when a credential
    has stopped working, which is the only reason anyone replaces one, and the
    replacement could never be activated. Onboarding writes this state; it does
    not ask it for permission.
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
    GenServer.call(server, {:adapter_for, key}, 30_000)
  end

  @doc "The adapter checkout used by a claimed turn; it has no elapsed-time failure."
  @spec adapter_for_turn(GenServer.server(), adapter_key()) :: checkout()
  def adapter_for_turn(server \\ __MODULE__, key) do
    GenServer.call(server, {:adapter_for, key}, :infinity)
  end

  @doc """
  Install a credential's runtime: replace the adapter for `key` and clear the
  failure history of the credential being replaced.

  THE ONLY CALL THAT OUTRANKS ADAPTER HEALTH, and it is named rather than
  spelled as an extra argument on purpose (Sol xhigh, important 3). Authority
  used to ride on the old `adapter_for/3` — pass a context, get a circuit
  bypass — so
  any future caller that happened to supply context would silently acquire the
  right to override health policy. The credential lifecycle is the only thing
  entitled to it, and now the only thing that can say it.

  The circuit protects agent connections from a dead harness. It has no
  authority over credential installation: an operator installing a credential is
  not asking the coordinator's permission, and a latched key would otherwise
  veto the only call that can unlatch it (the credential-swap incident,
  2026-08-14). A park fence is NOT bypassed — that is an explicit lifecycle
  constraint, not a health verdict.
  """
  @spec activate_provider_runtime(GenServer.server(), adapter_key(), keyword()) :: checkout()
  def activate_provider_runtime(server, key, context) do
    GenServer.call(server, {:activate_provider_runtime, key, context}, 30_000)
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
       adapters: %{},
       monitors: %{},
       # Monitor refs of adapter INSTANCES that completed boot. Readiness on the
       # entry describes whichever adapter the entry currently points at, which
       # for an absorbed death is the REPLACEMENT — so a question about the
       # instance that just died has to be keyed on something unique to it, and
       # its monitor ref is exactly that.
       ready_refs: MapSet.new(),
       context_requests: %{},
       load_active: %{},
       load_queue: %{}
     }}
  end

  @impl true
  def handle_call({:adapter_for, key}, from, state) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      live_entry?(entry) ->
        {:reply, checkout(entry), state}

      Tightbeam.HarnessProcess.fenced?(state.db, key) ->
        {:reply, {:error, {:park_fenced, key_name(key)}}, state}

      entry.circuit == :open ->
        {:reply, {:error, :degraded}, state}

      true ->
        {:noreply, capture_adapter_context(key, {:checkout, from}, state)}
    end
  end

  def handle_call({:activate_provider_runtime, key, context}, _from, state) do
    adapter_for_reply(key, context, state, true)
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

  defp adapter_for_reply(key, context, state, authoritative? \\ false) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      # AUTHORITY COMES FIRST — ahead of the live-entry shortcut, deliberately
      # (Sol xhigh, blocking). This used to replace a live adapter only when the
      # context DIFFERED, so re-onboarding the same credential KIND — the common
      # case, and exactly what a subscription refresh is — matched the running
      # adapter and handed it straight back. A backoff retry that happened to
      # start an adapter moments before onboarding would then be returned as the
      # authoritative result, and the ceremony reported success while the runtime
      # was still on the credential the operator had just replaced. Same lie as
      # the incident, one layer down.
      #
      # A credential installation always gets a NEW adapter. The running one was
      # started for a credential that no longer exists; identical context does
      # not make it current.
      authoritative? ->
        # THE FENCE IS CHECKED BEFORE ANY CLOSE (Sol xhigh round 4, blocking).
        # `do_close_adapter/2` calls `complete_park/2`, which DELETES the fence
        # row -- so closing first and checking afterwards silently unparked a key
        # that another lifecycle operation had fenced, the precise opposite of
        # the contract this path claims to keep. A fenced key is not touched.
        if Tightbeam.HarnessProcess.fenced?(state.db, key) do
          # The replaced credential's health is still cleared: a fence blocks
          # STARTING, it does not make the old credential's failures true again,
          # and leaving them rebuilds the deadlock past the unpark (round 3).
          entry = reset_failure_history(entry, false)
          {:reply, {:error, {:park_fenced, key_name(key)}}, put_in(state.adapters[key], entry)}
        else
          authoritative_start(key, entry, state, context)
        end

      live_entry?(entry) ->
        {:reply, checkout(entry), state}

      Tightbeam.HarnessProcess.fenced?(state.db, key) ->
        {:reply, {:error, {:park_fenced, key_name(key)}}, state}

      # THE AUTHORITATIVE PATH — credential lifecycle only (the sole caller is
      # `start_provider_runtime`). Onboarding is a WRITER of adapter health, not
      # a reader gated by it, and conflating the two is what deadlocked
      # credential recovery: the circuit exists to protect agent connections
      # from a dead harness, and it was allowed to veto the one call that could
      # make that harness live again. The operator installing a credential is
      # not asking the coordinator's permission.
      #
      # It also RESETS the failure history first. Every failure counted on this
      # key was caused by a credential that no longer exists; carrying that
      # count onto its replacement is carrying a verdict about something gone.
      # Onboarding succeeds -> unlatched, count cleared, turns flow with no
      # gateway restart. Onboarding fails -> the failure counts normally,
      # because a freshly installed credential that cannot start an adapter is
      # real evidence about THIS credential.
      entry.circuit == :open ->
        {:reply, {:error, :degraded}, state}

      true ->
        {reply, state} = start_adapter(key, entry, state, context)
        {:reply, reply, state}
    end
  end

  # ADVANCES THE GENERATION, which is what actually invalidates an in-flight
  # restart (Sol xhigh, important 2). `Process.cancel_timer/1` returning false
  # means the {:restart_adapter, key, generation} message may already be in the
  # mailbox, and setting `timer: nil` does not remove it. The restart handler
  # matches on `%{generation: ^generation, pid: nil}`, so bumping here makes any
  # queued message for the old generation fall through its catch-all — including
  # the case where the authoritative start then fails synchronously and would
  # otherwise leave a second retry lane racing the scheduled backoff.
  #
  # Bumping is also semantically right: a credential change IS a new generation,
  # and lanes holding a stale one perform session/load lazily, exactly as after
  # any other adapter replacement.
  # `advanced?` means "do_close_adapter/2 RAN", not "it succeeded" (Sol xhigh
  # round 4). That function calls `cancel_pending_starts/2`, which advances the
  # generation BEFORE reconciliation, so it advances even when the durable kill
  # then fails. Keying the reset off the RESULT therefore advanced twice on that
  # path -- and "exactly one advance per activation" is the invariant every
  # lane's stamped generation depends on.
  defp authoritative_start(key, entry, state, context) do
    {state, advanced?} =
      if live_entry?(entry) do
        {_result, state} = do_close_adapter(key, state)
        {state, true}
      else
        {state, false}
      end

    entry =
      state.adapters
      |> Map.get(key, fresh_entry())
      |> reset_failure_history(advanced?)

    state = put_in(state.adapters[key], entry)
    {reply, state} = start_adapter(key, entry, state, context)
    {:reply, reply, state}
  end

  defp reset_failure_history(entry, generation_already_advanced?) do
    if is_reference(entry.timer), do: Process.cancel_timer(entry.timer)

    generation =
      if generation_already_advanced?, do: entry.generation, else: entry.generation + 1

    %{entry | failures: 0, circuit: :closed, timer: nil, generation: generation}
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
    requests =
      Enum.reduce(state.context_requests, state.context_requests, fn
        {request_ref, %{key: ^key, monitor: monitor, purpose: {:checkout, from}}}, requests ->
          Process.demonitor(monitor, [:flush])
          GenServer.reply(from, {:error, {:parked, key_name(key)}})
          Map.delete(requests, request_ref)

        {request_ref, %{key: ^key, monitor: monitor}}, requests ->
          Process.demonitor(monitor, [:flush])
          Map.delete(requests, request_ref)

        _, requests ->
          requests
      end)

    state = %{state | context_requests: requests}

    case state.adapters[key] do
      %{timer: timer} = entry ->
        if is_reference(timer), do: Process.cancel_timer(timer)
        put_in(state.adapters[key], %{entry | timer: nil, generation: entry.generation + 1})

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
    context_request = context_request_for_monitor(state.context_requests, ref)

    cond do
      match?({_request_ref, _request}, context_request) ->
        {request_ref, request} = context_request
        requests = Map.delete(state.context_requests, request_ref)
        state = %{state | context_requests: requests}

        {:noreply,
         finish_context_request(request, {:error, {:context_worker_exit, reason}}, state)}

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
        end

      load_slot = slot_for_monitor(state.load_active, ref) ->
        {machine, slot} = load_slot
        {:noreply, release_slot(machine, slot, state, false)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:adapter_ready, key, pid}, state) do
    case state.adapters[key] do
      %{pid: ^pid} = entry when is_pid(pid) ->
        entry = %{entry | failures: 0, circuit: :closed, ready: true, last_failure: nil}
        state = %{state | ready_refs: put_ready_ref(state.ready_refs, entry.monitor)}
        {:noreply, %{state | adapters: Map.put(state.adapters, key, entry)}}

      # A ready message from an instance this entry no longer points at. It
      # died between announcing and being heard; the entry now describes a
      # successor that has not booted, and crediting it would declare a
      # not-yet-serving adapter ready.
      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:restart_adapter, key, generation}, state) do
    case state.adapters[key] do
      %{generation: ^generation, pid: nil} = entry ->
        state = put_in(state.adapters[key], %{entry | timer: nil})

        if Tightbeam.HarnessProcess.fenced?(state.db, key) do
          {:noreply, state}
        else
          {:noreply, capture_adapter_context(key, {:restart, generation}, state)}
        end

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
    if Tightbeam.HarnessProcess.fenced?(state.db, key) do
      {{:error, {:park_fenced, key_name(key)}}, state}
    else
      start_adapter_unfenced(key, entry, state, context)
    end
  end

  defp start_adapter_unfenced(key, entry, state, context) do
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
      opts = adapter_opts.(key, adapter_context) |> Keyword.put(:db, state.db)

      opts =
        if Keyword.has_key?(opts, :process_identity_dir) do
          Tightbeam.HarnessProcess.prepare_launch(opts, state.db, key)
        else
          opts
        end

      # The message NAMES THE INSTANCE that booted. `on_ready` runs in the
      # adapter's own process, so self() here is that adapter. Without it the
      # coordinator can only credit whichever pid the entry holds when the
      # message is finally processed — and an adapter that dies between
      # announcing readiness and being heard would hand its credit to the
      # replacement, which has not booted.
      Keyword.put(opts, :on_ready, fn -> send(coordinator, {:adapter_ready, key, self()}) end)
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
        # reset only by {:adapter_ready, key, pid} — the completed-boot signal.
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
        if Tightbeam.HarnessProcess.fenced?(state.db, key) do
          state
        else
          {_reply, state} = start_adapter(key, entry, state, context)
          state
        end

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
        if Tightbeam.HarnessProcess.fenced?(state.db, key) do
          state
        else
          timer =
            Process.send_after(self(), {:restart_adapter, key, generation}, backoff(state, 1))

          entry = %{
            entry
            | timer: timer,
              last_failure: {generation, {:adapter_context_failed, reason}}
          }

          put_in(state.adapters[key], entry)
        end

      _ ->
        state
    end
  end

  defp put_ready_ref(ready_refs, monitor) when is_reference(monitor),
    do: MapSet.put(ready_refs, monitor)

  defp put_ready_ref(ready_refs, _monitor), do: ready_refs

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
