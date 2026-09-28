defmodule Tightbeam.SessionLane do
  @moduledoc """
  One GenServer per active session — the serialized turn runner. It owns no
  queue in memory: the Ledger is the queue. On a nudge it claims the next turn
  (Ledger enforces one-per-session in SQL), runs it as a monitored TurnTask,
  and on completion records the terminal state + publishes, then drains.

  Topology (monitors, never links — a turn crash must never take the lane down):
  - The TurnTask runs under a Task.Supervisor via async_nolink; the lane
    MONITORS it. Task crash → lane gets :DOWN, marks the turn failed, drains on.
  - The turn work itself calls the Adapter (a bounded call the TurnTask may
    block on — it is designed to wait and is monitored by the Conn, which
    cancels on its death).

  There is currently no interlock between an orphaned ACP request and the next
  queued turn.
  """

  use GenServer
  require Logger
  alias Tightbeam.StaleTurnSettlement
  alias Tightbeam.{DB, EventLog, Harness, HarnessHealth, HarnessProcess, Ledger, Placement}

  defstruct [
    :session_key,
    :db,
    :runner,
    :task_sup,
    :lane_owner,
    terminal_publisher: nil,
    on_terminal: nil,
    task_ref: nil,
    task_pid: nil,
    current_seq: nil,
    current_message_id: nil,
    current_owner_lease: nil,
    reservation_token: nil,
    reservation_owner_ref: nil,
    settlement_waiters: [],
    settlement_rechecking: false,
    deferred_drain: false
  ]

  @doc """
  Start a lane. Required opts: `:session_key`, `:task_sup`, `:runner`
  (`turn_map -> {:ok, result} | {:error, reason}` — injectable for tests).
  Registered in `Tightbeam.LaneRegistry`, so at most one lane per session.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    GenServer.start_link(__MODULE__, opts, name: via(session_key))
  end

  @doc "Registry via-name for a session's lane."
  @spec via(String.t()) :: {:via, module(), term()}
  def via(session_key), do: {:via, Registry, {Tightbeam.LaneRegistry, session_key}}

  @doc """
  Nudge the lane to check for work (from client post, wake, or reconciler).
  A doorbell, not a guarantee — the LaneManager scan is the liveness backstop,
  so a lost nudge is never lost work.
  """
  @spec nudge(String.t()) :: :ok | :no_lane
  def nudge(session_key) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] -> GenServer.cast(pid, :nudge)
      [] -> :no_lane
    end
  end

  @doc "Release only the task for a turn already terminalized by manager recovery."
  @spec release_recovered(String.t(), integer()) :: :ok | :no_lane
  def release_recovered(session_key, seq) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] -> GenServer.cast(pid, {:release_recovered, seq})
      [] -> :no_lane
    end
  end

  @doc "Reap running turns left by a dead lane."
  @spec reap_abandoned(String.t()) :: {:ok, [integer()]} | :active | :no_lane
  def reap_abandoned(session_key) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] -> GenServer.call(pid, :reap_abandoned, :infinity)
      [] -> :no_lane
    end
  end

  @doc "Clear one stranded running turn without invoking its provider."
  @spec clear_stranded(String.t(), integer(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, map()} | :no_lane
  def clear_stranded(session_key, seq, reason, idempotency_key, principal) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] ->
        GenServer.call(
          pid,
          {:clear_stranded, seq, reason, idempotency_key, principal},
          :infinity
        )

      [] ->
        :no_lane
    end
  end

  @doc """
  Cancel the turn in flight, if any. The LANE owns the kill: a CAS terminal
  transition to "canceled" first (if the TurnTask finishes in the same
  instant, the CAS decides the winner — exactly one terminal state either
  way), then the task is killed and the lane drains on. Returns
  {:ok, %{seq, message_id}} when this call won the transition; :not_running
  when no turn is in flight or the turn just finished.

  No timeout, for the same reason as `at_turn_boundary/2` — one decision, not two
  coincidences. This inherited `GenServer.call/2`'s 5s default while the lane only
  ever did fast work; `at_turn_boundary/2` made the lane occupiable for a whole
  adapter bounce, and the default became a deadline nobody chose. There is no edge
  here to gate on: this caller has no deadline of its own, and the work it queues
  behind is already bounded by the adapter's own timeouts, so something does
  eventually give. Waiting for the true answer beats inventing a second, smaller,
  unrelated number that turns a clean `:not_running` into a timeout exit.
  """
  @spec cancel_current(String.t()) ::
          {:ok, %{seq: integer(), message_id: String.t()}} | :not_running | :no_lane
  def cancel_current(session_key) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] -> GenServer.call(pid, :cancel_current, :infinity)
      [] -> :no_lane
    end
  end

  @doc """
  Stop the currently running turn only when it is attributed to an open
  assignment whose opener matches principal. The lane revalidates that relationship
  and its own ownership of the exact running turn in the terminal transaction.
  """
  @spec stop_assignment_turn(String.t(), String.t(), term(), String.t()) ::
          {:ok, %{seq: integer(), message_id: String.t()}} | {:error, atom()} | :no_lane
  def stop_assignment_turn(session_key, assignment_id, principal, reason) do
    cond do
      not is_binary(assignment_id) or assignment_id == "" ->
        {:error, :invalid_assignment_id}

      not is_binary(reason) or byte_size(reason) not in 1..512 or String.trim(reason) == "" ->
        {:error, :invalid_reason}

      true ->
        case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
          [{pid, _}] ->
            GenServer.call(
              pid,
              {:stop_assignment_turn, assignment_id, principal, reason},
              :infinity
            )

          [] ->
            :no_lane
        end
    end
  end

  @doc """
  Run `fun` at a turn boundary, or refuse — the lane IS the serialization point.

  The lane claims turns in its own message loop (`maybe_start/1`), so it cannot
  claim one while it is servicing this call: the caller's check and its act are
  atomic in the lane's mailbox, and a nudge arriving during `fun` waits there
  rather than racing it. `:busy` means a turn is already in flight.

  `fun` runs INSIDE the lane process and blocks it, which is the point; it must
  not call back into the same lane. There is no outer timeout because `fun`'s own
  work carries its own (the adapter's are 30-185s), and a shorter bound here
  would fire while the work it is guarding is still running. `cancel_current/1`
  is unbounded for the same reason — see there; the two are one decision.
  """
  @spec at_turn_boundary(String.t(), (-> result)) :: {:ok, result} | :busy | :no_lane
        when result: term()
  def at_turn_boundary(session_key, fun) when is_function(fun, 0) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] -> GenServer.call(pid, {:at_turn_boundary, fun}, :infinity)
      [] -> :no_lane
    end
  end

  @doc "Settle one exact stale turn while this lane holds mailbox serialization."
  @spec settle_stale(pid(), reference() | nil, StaleTurnSettlement.request()) ::
          {:ok, map()} | {:error, map()}
  def settle_stale(lane_pid, reservation_token, operator_request) when is_pid(lane_pid) do
    GenServer.call(
      lane_pid,
      {:settle_stale, reservation_token, operator_request},
      :infinity
    )
  end

  ## Server

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_key: Keyword.fetch!(opts, :session_key),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      task_sup: Keyword.fetch!(opts, :task_sup),
      # runner: (turn_map -> {:ok, result_map} | {:error, term}); injectable for tests
      runner: Keyword.fetch!(opts, :runner),
      # Wire-notifies terminals that have NO runner closure (task crash,
      # cancel races) — without it a crashed turn leaves the client's typing
      # indicator stuck forever. No-op default keeps unit tests standalone.
      terminal_publisher: Keyword.get(opts, :terminal_publisher, fn _ -> :ok end),
      on_terminal: Keyword.get(opts, :on_terminal, fn _, _ -> :ok end),
      lane_owner: "lane:#{inspect(self())}:#{System.unique_integer([:positive])}"
    }

    token = Keyword.get(opts, :settlement_reservation)
    if is_nil(token), do: send(self(), :nudge)
    owner = Keyword.get(opts, :settlement_owner)
    owner_ref = if not is_nil(token) and is_pid(owner), do: Process.monitor(owner)
    {:ok, %{state | reservation_token: token, reservation_owner_ref: owner_ref}}
  end

  @impl true
  def handle_call(:cancel_current, _from, %{task_ref: nil} = state),
    do: {:reply, :not_running, state}

  def handle_call(:cancel_current, _from, state),
    do: cancel_running_turn(state, nil)

  def handle_call({:stop_assignment_turn, _assignment_id, _principal, _reason}, _from, state)
      when is_nil(state.task_ref),
      do: {:reply, {:error, :not_running}, state}

  def handle_call(
        {:stop_assignment_turn, assignment_id, principal, reason},
        _from,
        state
      ) do
    cancel_running_turn(state, %{
      assignment_id: assignment_id,
      principal: principal,
      reason: reason
    })
  end

  defp cancel_running_turn(state, audit) do
    audit =
      if is_map(audit),
        do: Map.put(audit, :principal_ref, assignment_stop_principal_ref(audit.principal)),
        else: nil

    {:ok, {result, route_publication}} =
      DB.transaction_then(
        state.db,
        fn txn ->
          target =
            if is_nil(audit) do
              {:ok, state.current_message_id}
            else
              assignment_turn_stop_target_in_txn(
                txn,
                state,
                audit.assignment_id,
                audit.principal,
                audit.principal_ref
              )
            end

          case target do
            {:ok, message_id} ->
              ledger_opts =
                [owner_lease: state.current_owner_lease] ++
                  if(audit,
                    do: [
                      cause: "assignment-opener-stop",
                      principal: audit.principal_ref
                    ],
                    else: []
                  )

              if Ledger.finish_in_txn(txn, state.current_seq, "canceled", nil, ledger_opts) do
                if audit do
                  EventLog.lifecycle_in_txn(
                    txn,
                    "assignment_turn_stopped",
                    Integer.to_string(state.current_seq),
                    JSON.encode!(%{
                      "assignmentId" => audit.assignment_id,
                      "actor" => audit.principal_ref,
                      "reason" => audit.reason
                    })
                  )
                end

                {{:ok, message_id},
                 HarnessHealth.settle_other_route_in_txn(
                   txn,
                   state.current_seq,
                   "canceled",
                   System.system_time(:millisecond)
                 )}
              else
                {{:error, :not_running}, nil}
              end

            {:error, refusal} ->
              {{:error, refusal}, nil}
          end
        end,
        fn txn, result ->
          Tightbeam.Wakes.row_commit_in_txn(txn, [])
          result
        end
      )

    case result do
      {:ok, message_id} ->
        publish_route_publication(route_publication)
        state.on_terminal.(state.session_key, state.current_seq)
        reply = {:ok, %{seq: state.current_seq, message_id: message_id}}
        # Assignment stops rely on the ACP session/cancel notification sent by
        # the gateway. Keep the turn task alive until that cancellation returns
        # naturally; only the pre-existing generic cancel keeps its old task
        # teardown behavior.
        if is_nil(audit) and is_pid(state.task_pid), do: Process.exit(state.task_pid, :kill)
        {:reply, reply, state}

      {:error, :not_running} when is_nil(audit) ->
        {:reply, :not_running, state}

      {:error, refusal} ->
        {:reply, {:error, refusal}, state}
    end
  end

  def handle_call(:reap_abandoned, _from, %{reservation_token: token} = state)
      when not is_nil(token),
      do: {:reply, :active, state}

  def handle_call(:reap_abandoned, _from, %{task_ref: ref} = state) when not is_nil(ref) do
    # The manager can itself die after committing recovery but before sending
    # the release. Reconcile the durable terminal against this exact task too.
    case DB.query(state.db, "SELECT status FROM turns WHERE seq=?1", [state.current_seq]) do
      {:ok, [["failed_unknown"]]} ->
        seq = state.current_seq
        {:reply, {:ok, [seq]}, release_recovered_task(state)}

      {:ok, [[_status]]} ->
        {:reply, :active, state}
    end
  end

  def handle_call(:reap_abandoned, _from, state) do
    seqs =
      Ledger.recover_running_for_session(
        state.db,
        state.session_key,
        state.lane_owner <> ":recovery"
      )

    {:reply, {:ok, seqs}, maybe_start(state)}
  end

  def handle_call(
        {:clear_stranded, seq, reason, idempotency_key, principal},
        _from,
        %{task_ref: ref} = state
      )
      when not is_nil(ref) do
    case Ledger.clear_attempt(state.db, state.session_key, seq, reason, idempotency_key) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, :idempotency_conflict} ->
        {:reply,
         {:error,
          %{code: "idempotency_key_conflict", message: "idempotency key names another clear"}},
         state}

      {:error, storage_reason} ->
        {:reply, {:error, %{code: "stranded_clear_failed", message: inspect(storage_reason)}},
         state}

      :none ->
        _ = principal

        {:reply,
         {:error,
          %{code: "turn_active", message: "a live lane owns a turn; stranded clearing refused"}},
         state}
    end
  end

  def handle_call(
        {:clear_stranded, seq, reason, idempotency_key, principal},
        _from,
        state
      ) do
    case Ledger.clear_stranded(
           state.db,
           state.session_key,
           seq,
           reason,
           idempotency_key,
           principal
         ) do
      {:ok, %{replayed: true} = result} ->
        {:reply, {:ok, result}, maybe_start(state)}

      {:ok, %{seq: clear_seq, message_id: message_id, error: error, replayed: false} = result} ->
        state.terminal_publisher.(%{
          session_key: state.session_key,
          message_id: message_id,
          status: "failed_unknown",
          error: error
        })

        Ledger.mark_published(state.db, clear_seq)
        state.on_terminal.(state.session_key, clear_seq)
        {:reply, {:ok, result}, maybe_start(state)}

      {:error, :not_found} ->
        {:reply, {:error, %{code: "turn_not_found", message: "turn does not exist"}}, state}

      {:error, :not_running} ->
        {:reply, {:error, %{code: "turn_not_running", message: "turn is already terminal"}},
         state}

      {:error, :idempotency_conflict} ->
        {:reply,
         {:error,
          %{code: "idempotency_key_conflict", message: "idempotency key names another clear"}},
         state}

      {:error, reason} ->
        {:reply, {:error, %{code: "stranded_clear_failed", message: inspect(reason)}}, state}
    end
  end

  def handle_call({:at_turn_boundary, _fun}, _from, %{task_ref: ref} = state)
      when not is_nil(ref),
      do: {:reply, :busy, state}

  def handle_call({:at_turn_boundary, fun}, _from, state), do: {:reply, {:ok, fun.()}, state}

  # A nil follower does not own the reservation. Keep its call pending so the
  # rightful holder can enter the mailbox, then re-evaluate against its result.
  def handle_call(
        {:settle_stale, nil, request},
        from,
        %{reservation_token: token} = state
      )
      when not is_nil(token) do
    {:noreply, %{state | settlement_waiters: [{from, request} | state.settlement_waiters]}}
  end

  def handle_call(
        {:settle_stale, reservation_token, _request},
        _from,
        %{reservation_token: expected} = state
      )
      when not is_nil(expected) and reservation_token != expected do
    {:reply, ambiguous(), state}
  end

  def handle_call(
        {:settle_stale, reservation_token, _request},
        _from,
        %{reservation_token: nil} = state
      )
      when not is_nil(reservation_token) do
    {:reply, ambiguous(), state}
  end

  def handle_call(
        {:settle_stale, reservation_token, %{turn_seq: turn_seq}},
        _from,
        %{task_ref: ref, current_seq: turn_seq} = state
      )
      when not is_nil(ref) do
    state = release_reservation(state, reservation_token)
    {:reply, {:error, %{code: "turn_live", message: "the session lane is running a turn"}}, state}
  end

  def handle_call({:settle_stale, reservation_token, _request}, _from, %{task_ref: ref} = state)
      when not is_nil(ref) do
    state = state |> release_reservation(reservation_token) |> maybe_start()
    {:reply, ambiguous(), state}
  end

  def handle_call({:settle_stale, reservation_token, request}, _from, state) do
    reserved? = not is_nil(reservation_token)
    result = StaleTurnSettlement.settle(state.db, request)
    state = publish_settlement(state, result)
    state = release_reservation(state, reservation_token)
    state = if reserved? or match?({:ok, _result}, result), do: maybe_start(state), else: state
    {:reply, public_settlement_result(result), state}
  end

  @impl true
  def handle_cast({:release_recovered, seq}, %{current_seq: seq, task_ref: ref} = state)
      when not is_nil(ref) do
    {:noreply, release_recovered_task(state)}
  end

  def handle_cast({:release_recovered, _seq}, state), do: {:noreply, state}

  def handle_cast(:nudge, %{reservation_token: token} = state) when not is_nil(token),
    do: {:noreply, %{state | deferred_drain: true}}

  def handle_cast(:nudge, state), do: {:noreply, maybe_start(state)}

  @impl true
  def handle_info(:nudge, %{reservation_token: token} = state) when not is_nil(token),
    do: {:noreply, %{state | deferred_drain: true}}

  def handle_info(:nudge, state), do: {:noreply, maybe_start(state)}

  # TurnTask finished normally.
  def handle_info({ref, {seq, outcome}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    finalize(state, seq, outcome)
    {:noreply, maybe_start(%{state | task_ref: nil})}
  end

  # TurnTask crashed.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task_ref: ref, current_seq: seq} = state
      )
      when not is_nil(reason) do
    EventLog.lifecycle(state.db, "turn_task_crash", state.session_key, inspect(reason))
    finalize(state, seq, crash_outcome(reason, seq))
    {:noreply, maybe_start(%{state | task_ref: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, %{task_ref: ref} = state) do
    {:noreply, maybe_start(%{state | task_ref: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{reservation_owner_ref: ref} = state)
      when not is_nil(ref) do
    # An abandoned reservation cannot confer settlement authority on followers.
    Enum.each(state.settlement_waiters, fn {from, _request} ->
      GenServer.reply(from, ambiguous())
    end)

    state = %{state | settlement_waiters: []}
    {:noreply, state |> release_reservation(state.reservation_token) |> maybe_start()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp release_recovered_task(state) do
    # Recovery already won the terminal CAS. Kill the exact owned task and
    # detach its monitor before draining: queued old results/DOWN must not
    # finalize or clear the successor. A repeated or late recovery is a no-op.
    ref = state.task_ref
    pid = state.task_pid
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    Process.demonitor(ref, [:flush])

    state = %{
      state
      | task_ref: nil,
        task_pid: nil,
        current_seq: nil,
        current_message_id: nil,
        current_owner_lease: nil
    }

    maybe_start(state)
  end

  defp crash_outcome({%Placement.Refusal{} = refusal, _stacktrace}, _seq),
    do: {:error, refusal.message}

  defp crash_outcome(reason, seq) do
    record = fn txn ->
      Tightbeam.HarnessHealth.observe_terminal_in_txn(
        txn,
        seq,
        "task_crash",
        "turn task crashed: #{inspect(reason, limit: 20)}",
        "process:tightbeam"
      )
    end

    committed = fn publication ->
      if is_function(publication, 0), do: publication.()
    end

    {:error, %{reason: :task_crash, record_in_txn: record, after_commit: committed}}
  end

  defp maybe_start(%{settlement_rechecking: true} = state), do: state

  defp maybe_start(%{reservation_token: token} = state) when not is_nil(token), do: state

  defp maybe_start(%{task_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_start(state) do
    if Tightbeam.Application.draining?() do
      # Graceful deploy: no NEW claims while draining. Queued turns stay
      # durable in the ledger and run on the next boot; the in-flight turn
      # (handled above) finishes normally.
      state
    else
      claim_and_start(state)
    end
  end

  defp claim_and_start(state) do
    if harness_parked?(state) do
      state
    else
      claim_next(state)
    end
  end

  defp harness_parked?(state) do
    case DB.query(state.db, "SELECT harness,host FROM sessions WHERE sessionKey=?1", [
           state.session_key
         ]) do
      {:ok, [[harness, host]]} ->
        HarnessProcess.parked?(state.db, {Harness.parse!(harness).id(), "shared", host})

      {:ok, []} ->
        false
    end
  end

  defp claim_next(state) do
    case Ledger.claim_next(state.db, state.session_key, state.lane_owner) do
      {:ok, turn} ->
        runner = state.runner

        task =
          Task.Supervisor.async_nolink(state.task_sup, fn ->
            {turn.seq, runner.(Map.put(turn, :session_key, state.session_key))}
          end)

        state
        |> Map.put(:task_ref, task.ref)
        |> Map.put(:task_pid, task.pid)
        |> Map.put(:current_seq, turn.seq)
        |> Map.put(:current_message_id, turn.message_id)
        |> Map.put(:current_owner_lease, turn.owner_lease)

      :busy ->
        state

      :none ->
        state

      {:unclaimable, reason} ->
        # Backstop. `Ledger.enqueue_in_txn/2` refuses to write a turn nobody can
        # claim, so reaching here means a row predates that guard or a session
        # retired between the enqueue and this claim. Either way the wait is
        # over: no claim will ever move it, and a queued row that cannot move is
        # exactly the shape that hid six lost prompts. Aging it into `failed`
        # names the cause and publishes through the reconciler's terminal feed.
        seqs = Ledger.fail_unclaimable(state.db, state.session_key, reason)

        Logger.error(
          "aged #{length(seqs)} unclaimable turn(s) for #{state.session_key} into failed: " <>
            "#{reason} (seqs #{Enum.join(seqs, ",")})"
        )

        state
    end
  end

  defp finalize(state, seq, outcome) do
    {terminal, error, publish, in_txn, after_commit} =
      case outcome do
        {:ok, %{terminal_publish: fun, record_in_txn: action}}
        when is_function(fun, 1) and is_function(action, 1) ->
          after_commit = fn recorded ->
            if is_function(recorded, 0), do: recorded.()
          end

          {"delivered", nil, fun, action, after_commit}

        {:ok, %{terminal_publish: fun}} when is_function(fun, 1) ->
          {"delivered", nil, fun, nil, nil}

        {:ok, _} ->
          {"delivered", nil, nil, nil, nil}

        {:error,
         %{
           terminal: "failed_unknown",
           reason: reason,
           terminal_publish: fun,
           record_in_txn: action
         }}
        when is_function(fun, 1) and is_function(action, 1) ->
          after_commit = fn recorded ->
            if is_function(recorded, 0), do: recorded.()
          end

          {"failed_unknown", error_text(reason), fun, action, after_commit}

        {:error, %{reason: reason, terminal_publish: fun, record_in_txn: action}}
        when is_function(fun, 1) and is_function(action, 1) ->
          after_commit = fn recorded ->
            if is_function(recorded, 0), do: recorded.()
          end

          {"failed", error_text(reason), fun, action, after_commit}

        {:error, %{reason: reason, record_in_txn: action, after_commit: committed}}
        when is_function(action, 1) and is_function(committed, 1) ->
          {"failed", error_text(reason), nil, action, committed}

        {:error, %{reason: reason, terminal_publish: fun}} when is_function(fun, 1) ->
          {"failed", error_text(reason), fun, nil, nil}

        {:error, reason} ->
          {"failed", error_text(reason), nil, nil, nil}
      end

    transaction =
      DB.transaction_then(
        state.db,
        fn txn ->
          if Ledger.finish_in_txn(txn, seq, terminal, error,
               owner_lease: state.current_owner_lease
             ) do
            recorded = if is_function(in_txn, 1), do: in_txn.(txn), else: nil

            route_publication =
              HarnessHealth.settle_other_route_in_txn(
                txn,
                seq,
                terminal,
                System.system_time(:millisecond)
              )

            {true, {:terminal_recorded, recorded, route_publication}}
          else
            {false, nil}
          end
        end,
        fn txn, result ->
          Tightbeam.Wakes.row_commit_in_txn(txn, [])
          result
        end
      )

    case transaction do
      {:ok, {won, recorded}} ->
        finish_result(state, seq, terminal, error, publish, after_commit, won, recorded)

      {:error, reason} ->
        EventLog.lifecycle(
          state.db,
          "turn_finalize_transaction_failed",
          "#{state.session_key}:#{seq}",
          inspect(reason, limit: 20)
        )

        fallback =
          DB.transaction_then(
            state.db,
            fn txn ->
              if Ledger.finish_in_txn(txn, seq, terminal, error,
                   owner_lease: state.current_owner_lease
                 ) do
                route_publication =
                  HarnessHealth.settle_other_route_in_txn(
                    txn,
                    seq,
                    terminal,
                    System.system_time(:millisecond)
                  )

                {true, {:terminal_recorded, nil, route_publication}}
              else
                {false, nil}
              end
            end,
            fn txn, result ->
              Tightbeam.Wakes.row_commit_in_txn(txn, [])
              result
            end
          )

        case fallback do
          {:ok, {won, recorded}} ->
            finish_result(state, seq, terminal, error, publish, nil, won, recorded)

          {:error, fallback_reason} ->
            EventLog.lifecycle(
              state.db,
              "turn_finalize_fallback_failed",
              "#{state.session_key}:#{seq}",
              inspect(fallback_reason, limit: 20)
            )

            :ok
        end
    end
  end

  defp finish_result(state, seq, terminal, error, publish, after_commit, won, recorded) do
    {finish_result, recorded} = {if(won, do: :ok, else: :already_terminal), recorded}

    case finish_result do
      :ok ->
        {recorded, route_publication} = split_terminal_recorded(recorded)

        if is_function(after_commit, 1), do: after_commit.(recorded)
        publish_route_publication(route_publication)

        if publish do
          publish.(terminal)
        else
          state.terminal_publisher.(%{
            session_key: state.session_key,
            message_id: state.current_message_id,
            status: terminal,
            error: error
          })
        end

        publish_terminal(state, seq)
        state.on_terminal.(state.session_key, seq)

      :already_terminal ->
        :ok
    end
  end

  # At-least-once publication: the runner already broadcast the
  # assistant message + turn-state during the turn; here we ensure the terminal
  # row is marked published. The publisher hook is injected by the composition
  # root; in E1 the ledger's publishedAt marking is the observable seam.
  defp publish_terminal(state, seq), do: Ledger.mark_published(state.db, seq)

  defp publish_settlement(state, {:ok, %{won: true} = result}) do
    state.terminal_publisher.(%{
      session_key: state.session_key,
      message_id: result.message_id,
      status: result.status,
      error: result.stored_error
    })

    publish_terminal(state, result.turn_seq)
    state.on_terminal.(state.session_key, result.turn_seq)
    state
  end

  defp publish_settlement(state, _result), do: state

  defp release_reservation(%{reservation_token: nil} = state, nil), do: state

  defp release_reservation(%{reservation_token: token} = state, token)
       when not is_nil(token) do
    if state.reservation_owner_ref, do: Process.demonitor(state.reservation_owner_ref, [:flush])
    waiters = Enum.reverse(state.settlement_waiters)

    state = %{
      state
      | reservation_token: nil,
        reservation_owner_ref: nil,
        settlement_waiters: [],
        settlement_rechecking: true,
        deferred_drain: false
    }

    # Use the ordinary admission and settlement checks; a conflicting or live
    # request must retain its refusal rather than inherit the holder's success.
    Enum.reduce(waiters, state, fn {from, request}, acc ->
      {:reply, result, next} = handle_call({:settle_stale, nil, request}, from, acc)
      GenServer.reply(from, result)
      next
    end)
    |> Map.put(:settlement_rechecking, false)
  end

  defp release_reservation(state, _token), do: state

  defp public_settlement_result({:ok, result}),
    do: {:ok, Map.drop(result, [:message_id, :stored_error])}

  defp public_settlement_result(result), do: result

  defp assignment_turn_stop_target_in_txn(
         txn,
         state,
         assignment_id,
         principal,
         principal_ref
       ) do
    case DB.Txn.q(
           txn,
           """
           SELECT a.holderKey, a.state, a.openedByUser, a.openedBySession,
                  t.sessionKey, t.assignmentId, t.status, t.owner, t.messageId
           FROM assignments a
           JOIN turns t ON t.seq=?2
           WHERE a.id=?1
           """,
           [assignment_id, state.current_seq]
         ) do
      [
        [
          holder,
          assignment_state,
          opened_by_user,
          opened_by_session,
          turn_session,
          turn_assignment,
          turn_status,
          turn_owner,
          message_id
        ]
      ] ->
        opened_by =
          cond do
            is_binary(opened_by_user) -> "user:" <> opened_by_user
            is_binary(opened_by_session) -> "session:" <> opened_by_session
            true -> nil
          end

        cond do
          not is_binary(principal_ref) or opened_by != principal_ref ->
            {:error, :not_assignment_opener}

          assignment_state != "open" ->
            {:error, :assignment_not_open}

          holder != state.session_key ->
            {:error, :assignment_holder_changed}

          turn_session != state.session_key ->
            {:error, :turn_session_changed}

          turn_assignment != assignment_id ->
            {:error, :turn_not_attributed_to_assignment}

          turn_status != "running" ->
            {:error, :not_running}

          turn_owner != state.lane_owner ->
            {:error, :turn_owner_changed}

          not is_binary(state.current_owner_lease) ->
            {:error, :turn_owner_changed}

          principal != {:user, opened_by_user} and
              principal != {:session, opened_by_session} ->
            {:error, :not_assignment_opener}

          true ->
            {:ok, message_id}
        end

      [] ->
        {:error, :assignment_or_turn_not_found}
    end
  end

  defp assignment_stop_principal_ref({:user, user_id}) when is_binary(user_id),
    do: "user:" <> user_id

  defp assignment_stop_principal_ref({:session, session_key}) when is_binary(session_key),
    do: "session:" <> session_key

  defp assignment_stop_principal_ref(_), do: nil

  defp ambiguous,
    do: {:error, %{code: "turn_status_ambiguous", message: "turn liveness is ambiguous"}}

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(%{code: code} = reason) when is_binary(code), do: JSON.encode!(reason)
  defp error_text(%{"code" => code} = reason) when is_binary(code), do: JSON.encode!(reason)
  defp error_text(reason), do: inspect(reason)

  defp split_terminal_recorded({:terminal_recorded, recorded, route_publication}),
    do: {recorded, route_publication}

  defp split_terminal_recorded(recorded), do: {recorded, nil}

  defp publish_route_publication(nil), do: :ok

  defp publish_route_publication(%{plan: plan}) when is_list(plan),
    do: Tightbeam.EventLog.publish(plan)
end
