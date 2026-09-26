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
  require Logger

  @adapter_readiness_timeout 185_000
  @adapter_checkout_timeout 190_000
  @shutdown_budget_ms 30_000
  # Match the DB owner's busy timeout so a contended durable write still has
  # room to finish before the supervisor's outer shutdown deadline.
  @shutdown_settlement_budget_ms 5_000
  # Give a park task a chance to close the port it owns before the coordinator
  # has to force-kill the task. Budgeted ahead of the settlement reserve inside
  # the park phase (terminate/2 subtracts it from the park deadline), so a
  # cancel that starts on time never spends the reserve — and never extends the
  # supervisor's shutdown budget. At zero the cooperative window is gone:
  # every outstanding park is brutal-killed, and the descendant reaping a
  # cancelled park performs before closing its port (HarnessProcess's
  # terminate_command_port/1) never runs — closing the port alone does not
  # reliably reap a shebang wrapper on every supported host, so a zero grace
  # trades orphaned helper descendants for the hundred milliseconds.
  @shutdown_cancel_grace_ms 100
  # The supervisor's shutdown timer starts at the exit signal; terminate/2's
  # deadline starts at callback entry, strictly later, and DB.transaction_until
  # grants a final commit already in flight remaining + 50ms past that deadline.
  # A supervisor allowance equal to the budget therefore brutal-kills the
  # coordinator mid-settlement — inside its own contract — destroying the
  # durable record the budget exists to protect. One second covers the 50ms
  # grant plus the worst observed signal-to-entry scheduling gap (261ms under
  # 4x CPU oversubscription) with ~3x headroom, and costs at most one extra
  # second when terminate/2 is genuinely wedged.
  @shutdown_supervisor_margin_ms 1_000

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

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      # The normal worker default (5s) is shorter than identity recovery plus
      # signal delivery. Let terminate/2 settle the durable process group:
      # derived from the configured budget, not the attribute, so a caller
      # raising shutdown_budget_ms is not killed before its own deadline, and
      # widened by the margin (see @shutdown_supervisor_margin_ms) so the
      # supervisor never reclaims time the callback's contract still owns.
      shutdown:
        Keyword.get(opts, :shutdown_budget_ms, @shutdown_budget_ms) +
          @shutdown_supervisor_margin_ms
    }
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

  @doc "Run one callback while adapter replacement is fenced to an exact generation."
  @spec with_generation_fence(GenServer.server(), adapter_key(), pos_integer(), map()) ::
          {:ok, term()} | {:error, term()}
  def with_generation_fence(server \\ __MODULE__, key, expected_generation, owner_scope) do
    GenServer.call(
      server,
      {:with_generation_fence, key, expected_generation, owner_scope},
      :infinity
    )
  catch
    :exit, reason -> {:error, {:coordinator_unavailable, reason}}
  end

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
    # Supervisor shutdown must reach terminate/2 before AdapterSupervisor goes
    # away, because that callback settles the OS process group it owns.
    Process.flag(:trap_exit, true)

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
       load_queue: %{},
       # The production child spec supplies the 30-second default. The
       # private overrides make deadline exhaustion deterministic in tests.
       shutdown_budget_ms: Keyword.get(opts, :shutdown_budget_ms, @shutdown_budget_ms),
       shutdown_settlement_budget_ms:
         Keyword.get(opts, :shutdown_settlement_budget_ms, @shutdown_settlement_budget_ms),
       shutdown_cancel_grace_ms:
         Keyword.get(opts, :shutdown_cancel_grace_ms, @shutdown_cancel_grace_ms),
       # Owner for cleanup that outlives terminate/2; see dispatch_late_cleanup/2.
       # Overridable so a standalone coordinator can be given its own owner.
       shutdown_cleanup_supervisor:
         Keyword.get(opts, :shutdown_cleanup_supervisor, Tightbeam.TurnTaskSupervisor)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    # One monotonic clock covers preparation, park attempts, durable settlement,
    # and nonblocking retirement. Reserve the final slice for settlement; if
    # either DB phase cannot finish, keep the outcome explicitly unresolved.
    deadline = System.monotonic_time(:millisecond) + state.shutdown_budget_ms
    settle_start = deadline - state.shutdown_settlement_budget_ms

    # A park phase that times out still owes every cancelled task the cancel
    # grace, so parking must surrender the clock one grace before the reserve
    # begins. Charging the grace to the reserve instead is what left settlement
    # with an already-spent slice under load: transaction_until refused, the
    # park rows kept their fence but lost their durable outcome.
    park_deadline = settle_start - state.shutdown_cancel_grace_ms

    {pending, state, preparation} = prepare_shutdown(state, park_deadline)

    results =
      case preparation do
        :ok ->
          if System.monotonic_time(:millisecond) >= park_deadline do
            budget_exhausted_results(pending)
          else
            pending
            |> start_shutdown_tasks(state.db)
            |> collect_shutdown_results(
              park_deadline,
              settle_start,
              state.shutdown_cancel_grace_ms
            )
          end

        {:error, reason} ->
          preparation_unresolved_results(pending, reason)
      end

    # Retirement's cutoff is the reserve boundary, not the park deadline: on
    # the happy path the grace window goes unused, and retirement may keep
    # using it right up to where the settlement reserve begins.
    {results, state, late_targets} = retire_shutdown_results(results, state, settle_start)

    # Durable settlement runs before any late cleanup, so it is reachable inside
    # the configured deadline no matter how many adapters were retained; the
    # cleanup those late entries still need is handed to its own owner after.
    settle_shutdown_results(results, state, deadline)
    dispatch_late_cleanup(late_targets, state)

    :ok
  end

  @impl true
  def handle_call({:adapter_for, key}, from, state) do
    entry = Map.get(state.adapters, key, fresh_entry())

    cond do
      reusable_entry?(entry) ->
        {:reply, checkout(entry), state}

      entry.circuit == :open ->
        {:reply, {:error, :degraded}, state}

      readiness_pending?(entry) ->
        {:noreply, add_waiter(key, from, state)}

      Tightbeam.HarnessProcess.fenced?(state.db, key) ->
        {:reply, {:error, {:park_fenced, key_name(key)}}, state}

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

  def handle_call(
        {:with_generation_fence, key, expected_generation, owner_scope},
        _from,
        state
      ) do
    entry = Map.get(state.adapters, key, fresh_entry())

    result =
      with true <- is_integer(expected_generation) and expected_generation > 0,
           %{lane_pid: lane_pid, gateway_pid: gateway_pid, callback: callback} <- owner_scope,
           true <- is_pid(lane_pid) and is_pid(gateway_pid) and lane_pid != gateway_pid,
           true <- Process.alive?(lane_pid) and Process.alive?(gateway_pid),
           true <- live_entry?(entry) and entry.ready,
           true <- entry.generation == expected_generation,
           true <- is_function(callback, 3) do
        run_generation_fence(entry, lane_pid, gateway_pid, callback)
      else
        _ -> {:error, :generation_unavailable}
      end

    {:reply, result, state}
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

      reusable_entry?(entry) ->
        {:reply, checkout(entry), state}

      readiness_pending?(entry) ->
        {:noreply, add_waiter(key, from, state)}

      authoritative? and live_entry?(entry) ->
        {:reply, checkout(entry), state}

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

  # OTP ignores the return value from a child's terminate/2 callback, and the
  # application master catches the application's stop callback as well. The
  # shutdown result therefore has to remain durable in the harness ledger and
  # lifecycle stream; returning an error here would falsely suggest that
  # Application.stop/1 can report the cleanup failure.
  defp prepare_shutdown(state, deadline) do
    keys = Map.keys(state.adapters)

    state =
      Enum.reduce(keys, state, fn key, state ->
        cancel_pending_starts(key, state)
      end)

    case Tightbeam.HarnessProcess.begin_park_many_until(state.db, keys, deadline) do
      {:ok, pending} ->
        {pending, state, :ok}

      {:error, reason} ->
        Logger.error(
          "adapter shutdown preparation unresolved before deadline: #{inspect(reason)}"
        )

        pending = Enum.map(keys, &{&1, :no_launch})
        {pending, state, {:error, reason}}
    end
  end

  defp preparation_unresolved_results(pending, reason) do
    Enum.map(pending, fn {key, process_row} ->
      {key, process_row, {:error, {:shutdown_preparation_unresolved, reason}}}
    end)
  end

  defp budget_exhausted_results(pending) do
    Enum.map(pending, fn {key, process_row} ->
      {key, process_row, {:error, :shutdown_budget_exhausted}}
    end)
  end

  # Park every recorded process group at once. A serial reduce made the
  # supervisor's 30-second shutdown allowance proportional to the number of
  # adapters, so later keys could never even reach begin_park/2 in a busy
  # gateway shutdown.
  defp start_shutdown_tasks(pending, db) do
    Enum.map(pending, fn {key, process_row} ->
      task =
        Task.async(fn ->
          shutdown_process(db, process_row)
        end)

      {key, process_row, task}
    end)
  end

  defp shutdown_process(_db, :no_launch), do: :ok

  defp shutdown_process(db, row) do
    try do
      Tightbeam.HarnessProcess.park(db, row)
    rescue
      error -> {:error, {:exception, error, __STACKTRACE__}}
    catch
      kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
    end
  end

  defp collect_shutdown_results(tasks, deadline, settle_start, cancel_grace_ms) do
    collect_shutdown_results(tasks, deadline, settle_start, cancel_grace_ms, [])
  end

  defp collect_shutdown_results([], _deadline, _settle_start, _cancel_grace_ms, results),
    do: Enum.reverse(results)

  defp collect_shutdown_results(
         [{key, process_row, task} = current | rest],
         deadline,
         settle_start,
         cancel_grace_ms,
         results
       ) do
    case Task.yield(task, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, result} ->
        collect_shutdown_results(rest, deadline, settle_start, cancel_grace_ms, [
          {key, process_row, result} | results
        ])

      {:exit, reason} ->
        collect_shutdown_results(rest, deadline, settle_start, cancel_grace_ms, [
          {key, process_row, {:error, {:shutdown_task_exit, reason}}} | results
        ])

      nil ->
        # Cancel every outstanding task together. Waiting for one task before
        # notifying the others would spend the reserved settlement slice on
        # serial cancellation and recreate the original adapter-count hazard.
        cancel_shutdown_tasks([current | rest])

        timed_out =
          collect_cancelled_shutdown_results([current | rest], settle_start, cancel_grace_ms)

        Enum.reverse(results) ++ timed_out
    end
  end

  defp cancel_shutdown_tasks(tasks) do
    Enum.each(tasks, fn {_key, _process_row, task} ->
      send(task.pid, {:tightbeam_shutdown_cancel, self()})
    end)
  end

  defp collect_cancelled_shutdown_results(tasks, settle_start, cancel_grace_ms) do
    # The park deadline already budgets one full grace ahead of the reserve, so
    # a cancel that starts on time gets all of it. When park collection overran
    # its own deadline, the grace is truncated at the reserve boundary rather
    # than allowed to spend the settlement slice: a brutal kill over an
    # unrecorded outcome beats a recorded outcome settlement can no longer
    # write.
    cancel_deadline =
      min(System.monotonic_time(:millisecond) + cancel_grace_ms, settle_start)

    yielded =
      Enum.map(tasks, fn {key, process_row, task} ->
        remaining = max(cancel_deadline - System.monotonic_time(:millisecond), 0)
        {key, process_row, task, Task.yield(task, remaining)}
      end)

    # Kill every task that outlived its grace before awaiting any of them, so
    # the DOWN waits overlap. Awaiting each kill inside the yield loop let the
    # waits accumulate serially, and on a starved scheduler their sum spent the
    # settlement reserve just like the unbudgeted grace did.
    Enum.each(yielded, fn
      {_key, _process_row, task, nil} -> Process.exit(task.pid, :kill)
      _ -> :ok
    end)

    Enum.map(yielded, fn {key, process_row, task, outcome} ->
      if outcome == nil do
        _ = Task.shutdown(task, :brutal_kill)
      end

      {key, process_row, {:error, :shutdown_budget_exhausted}}
    end)
  end

  # Retirement is deliberately before durable settlement so a cutoff can turn
  # every later entry into an explicit unresolved outcome while the reserved
  # settlement slice is still available to persist it. The old serial loop
  # retired entries after settlement and kept doing so past the supervisor's
  # deadline without a truthful durable result for the entries it never
  # reached.
  defp retire_shutdown_results(results, state, deadline) do
    retire_shutdown_results(results, state, deadline, [])
  end

  defp retire_shutdown_results([], state, _deadline, retired),
    do: {Enum.reverse(retired), state, []}

  defp retire_shutdown_results(
         [{key, process_row, result} | rest],
         state,
         deadline,
         retired
       ) do
    if System.monotonic_time(:millisecond) >= deadline do
      {late, targets} = late_shutdown_outcomes([{key, process_row, result} | rest], state)
      {Enum.reverse(retired) ++ late, state, targets}
    else
      state = retire_shutdown_adapter(key, state)
      retire_shutdown_results(rest, state, deadline, [{key, process_row, result} | retired])
    end
  end

  # Past the reserve boundary only the settlement reserve is left, so DECIDING
  # each late entry's outcome is all that may happen here. This is pure: it reads the
  # adapter map, builds the unresolved result, and captures the pid to act on
  # later. No cast, no exit, no logging — every one of those moved to
  # `dispatch_late_cleanup/2`, which runs AFTER durable settlement. That is what
  # makes settlement reachable inside the single configured deadline whatever the
  # retained-adapter count and whatever the logger is doing: a blocked logger
  # cannot delay a path that no longer logs.
  defp late_shutdown_outcomes(entries, state) do
    entries
    |> Enum.map(fn {key, process_row, _result} ->
      pid =
        case state.adapters[key] do
          %{pid: pid} when is_pid(pid) -> pid
          _ -> nil
        end

      {{key, process_row,
        {:error, {:shutdown_retirement_unresolved, :shutdown_budget_exhausted}}}, {key, pid}}
    end)
    |> Enum.unzip()
  end

  # Cleanup that must continue past the deadline, under an owner that is not us.
  #
  # The adapters still have to be closed and killed or their port-owned helper
  # trees outlive the coordinator — abandoning them is not an option. But doing
  # it on terminate/2's stack is what the V6 and V7 reviews both rejected: it
  # competes with the settlement reserve and dies at the supervisor's deadline.
  #
  # Tightbeam.TurnTaskSupervisor is started BEFORE the coordinator in the
  # rest_for_one root tree, so it is still alive here and shuts down after us.
  # It owns this work and bounds it by its own child shutdown. Durable outcomes
  # are already persisted by the time we reach this, so a task cut short leaves
  # the record truthful rather than silent, and the fences already written for
  # these keys are what make the remainder reapable.
  #
  # No demonitor here: a monitor may only be cleared by the process that set it,
  # and the coordinator's monitors die with the coordinator anyway.
  defp dispatch_late_cleanup([], _state), do: :ok

  defp dispatch_late_cleanup(targets, state) do
    cleanup = fn ->
      Enum.each(targets, fn {_key, pid} ->
        if is_pid(pid) do
          Tightbeam.Acp.Adapter.request_close(pid)
          if Process.alive?(pid), do: Process.exit(pid, :kill)
        end
      end)

      Logger.error(
        "adapter shutdown retirement late entry unresolved before deadline for " <>
          "#{length(targets)} adapter(s): " <> late_batch_names(targets)
      )
    end

    # start_child/2 is a call into the owner, so an absent owner EXITS rather
    # than returning an error tuple. Catching it matters: terminate/2 must not
    # die here, or the cleanup this function exists to guarantee is lost along
    # with the callback.
    handoff =
      try do
        Task.Supervisor.start_child(state.shutdown_cleanup_supervisor, cleanup)
      catch
        :exit, reason -> {:error, {:cleanup_owner_unavailable, reason}}
      end

    case handoff do
      {:ok, _pid} ->
        :ok

      # The owner is gone or was never started — a coordinator run standalone.
      # Running inline is still strictly better than the reviewed behaviour,
      # because durable settlement has already completed by now; say so rather
      # than drop the cleanup silently.
      other ->
        Logger.error(
          "adapter shutdown late cleanup owner #{inspect(state.shutdown_cleanup_supervisor)} " <>
            "unavailable (#{inspect(other)}); running cleanup inline after settlement"
        )

        cleanup.()
    end

    :ok
  end

  # The count above is the complete fact; the names are for the operator reading
  # the line. Naming every key would build an unbounded string, so the sample is
  # capped and the remainder is counted.
  @late_batch_named 20
  defp late_batch_names(targets) do
    named = Enum.take(targets, @late_batch_named)
    rest = length(targets) - length(named)
    names = Enum.map_join(named, ", ", fn {key, _pid} -> key_name(key) end)

    if rest > 0, do: names <> ", and #{rest} more", else: names
  end

  defp settle_shutdown_results(results, state, deadline) do
    case Tightbeam.HarnessProcess.settle_park_results_until(state.db, results, deadline) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "adapter shutdown durable outcomes unresolved before deadline: #{inspect(reason)}"
        )
    end

    Enum.reduce(results, state, fn {key, _process_row, result}, state ->
      if result not in [:ok, :already_resolved] do
        Logger.error("adapter shutdown cleanup failed for #{key_name(key)}: #{inspect(result)}")
      end

      state
    end)
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
  # records. Even with distinct successor generations, `adapterGen IS NULL`
  # covers both "checked this adapter out" and
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

  defp retire_shutdown_adapter(key, state) do
    case state.adapters[key] do
      %{pid: pid} when is_pid(pid) ->
        Tightbeam.Acp.Adapter.request_close(pid)

      _ ->
        :ok
    end

    retire_adapter(key, state)
  end

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
          timer = schedule_restart(state, key, generation, failures, circuit)

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

  def handle_info({:generation_fence_result, _id, _result}, state), do: {:noreply, state}
  def handle_info({:generation_fence_owner_lost, _fence, _owner}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

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
      %{generation: ^generation, pid: nil, circuit: :closed} = entry ->
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
    # Checkout may observe death before the monitor message is consumed. Retire
    # this instance's identity now; its retained monitor mapping still records
    # the delayed death, while the successor readiness owns a fresh generation.
    entry =
      if is_pid(entry.pid) and not Process.alive?(entry.pid) do
        %{entry | pid: nil, monitor: nil, ready: false, generation: entry.generation + 1}
      else
        entry
      end

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

    if settle?, do: reconcile_launch_generation(state.db, key)
    state
  end

  defp live_waiters(waiters) do
    Enum.filter(waiters, fn {_monitor, {pid, _tag}} -> Process.alive?(pid) end)
  end

  defp reconcile_launch_generation(db, key) do
    # Terminating the BEAM adapter proves only that its owner died. The
    # harness-exec process group can outlive that owner, especially while the
    # child is still blocked in initialize. Reconcile the durable launch before
    # starting its authoritative replacement so the old process tree is killed
    # or remains fenced on a loud cleanup failure.
    case Tightbeam.HarnessProcess.reconcile_key(db, key) do
      :ok ->
        :ok

      :already_resolved ->
        :ok

      {:error, reason} ->
        Logger.error(
          "adapter readiness generation cleanup failed for #{key_name(key)}: #{inspect(reason)}"
        )
    end
  end

  defp start_adapter_unfenced(key, entry, state, opts) do
    coordinator = self()
    generation = entry.generation
    token = entry.readiness_token

    opts =
      opts
      |> Keyword.put(:connection_generation, generation)
      |> Keyword.put(:on_ready, fn ->
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

        timer = schedule_restart(state, key, generation, failures, circuit)

        entry = %{
          entry
          | generation: generation,
            failures: failures,
            circuit: circuit,
            timer: timer,
            ready: false,
            last_failure: {generation, {:adapter_start_failed, start_reason}}
        }

        refusal = %{code: "adapter_start_failed", message: "Adapter failed to start"}

        state
        |> Map.put(:adapters, Map.put(state.adapters, key, entry))
        |> finish_readiness(key, {:error, refusal})
    end
  end

  defp run_generation_fence(entry, lane_pid, gateway_pid, callback) do
    {:ok, fence} =
      __MODULE__.GenerationFence.start([lane_pid, gateway_pid, entry.pid], self())

    owner = self()
    work_id = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            callback.(entry.pid, entry.generation, fn ->
              __MODULE__.GenerationFence.valid?(fence)
            end)
          rescue
            error -> {:error, {:callback_exception, error, __STACKTRACE__}}
          catch
            kind, reason -> {:error, {:callback_exit, kind, reason}}
          end

        send(owner, {:generation_fence_result, work_id, result})
      end)

    try do
      receive do
        {:generation_fence_result, ^work_id, callback_result} ->
          if __MODULE__.GenerationFence.valid?(fence),
            do: {:ok, callback_result},
            else: {:error, :owner_lost}

        {:generation_fence_owner_lost, ^fence, _owner_pid} ->
          {:error, :owner_lost}

        {:DOWN, ^monitor, :process, ^worker, reason} ->
          {:error, {:callback_exit, reason}}
      after
        30_000 -> {:error, :callback_timeout}
      end
    after
      # Invalidate before stopping work: a DB callback running in the DB process
      # must fail its final fence check even after this callback worker exits.
      __MODULE__.GenerationFence.stop(fence)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defmodule GenerationFence do
    @moduledoc false
    use GenServer

    def start(owners, observer), do: GenServer.start(__MODULE__, {owners, observer})
    def valid?(fence), do: GenServer.call(fence, :valid)
    def stop(fence), do: GenServer.stop(fence, :normal)

    @impl true
    def init({owners, observer}) do
      monitors = Map.new(owners, fn owner -> {Process.monitor(owner), owner} end)

      {:ok,
       %{
         valid: true,
         monitors: monitors,
         observer: observer,
         observer_monitor: Process.monitor(observer)
       }}
    end

    @impl true
    def handle_call(:valid, _from, state) do
      valid =
        state.valid and Process.alive?(state.observer) and
          Enum.all?(Map.values(state.monitors), &Process.alive?/1)

      {:reply, valid, %{state | valid: valid}}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _owner, _reason}, %{observer_monitor: ref} = state),
      do: {:stop, :normal, state}

    def handle_info({:DOWN, ref, :process, owner, _reason}, state) do
      if state.valid and Map.get(state.monitors, ref) == owner,
        do: send(state.observer, {:generation_fence_owner_lost, self(), owner})

      {:noreply, %{state | valid: false, monitors: Map.delete(state.monitors, ref)}}
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
  defp schedule_restart(_state, _key, _generation, _failures, :open), do: nil

  defp schedule_restart(state, key, generation, failures, :closed) do
    Process.send_after(
      self(),
      {:restart_adapter, key, generation},
      backoff(state, failures)
    )
  end

  defp ready_entry?(entry),
    do: entry.ready == true and is_pid(entry.pid) and Process.alive?(entry.pid)

  defp reusable_entry?(entry),
    do:
      entry.circuit == :closed and
        (ready_entry?(entry) or (not entry.rendezvous and live_entry?(entry)))

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
