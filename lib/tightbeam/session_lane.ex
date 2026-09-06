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
  alias Tightbeam.{DB, EventLog, Harness, HarnessProcess, Ledger, Placement, Rules}

  defstruct [
    :session_key,
    :db,
    :runner,
    :task_sup,
    terminal_publisher: nil,
    on_terminal: nil,
    task_ref: nil,
    task_pid: nil,
    current_seq: nil,
    current_message_id: nil
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
      on_terminal: Keyword.get(opts, :on_terminal, fn _, _ -> :ok end)
    }

    send(self(), :nudge)
    {:ok, state}
  end

  @impl true
  def handle_call(:cancel_current, _from, %{task_ref: nil} = state),
    do: {:reply, :not_running, state}

  def handle_call(:cancel_current, _from, state) do
    case Ledger.finish(state.db, state.current_seq, "canceled") do
      :ok ->
        state.on_terminal.(state.session_key, state.current_seq)
        reply = {:ok, %{seq: state.current_seq, message_id: state.current_message_id}}
        if is_pid(state.task_pid), do: Process.exit(state.task_pid, :kill)
        # The :DOWN for the killed task clears task_ref and drains; its
        # finalize hits :already_terminal (we won the CAS) — no double publish.
        {:reply, reply, state}

      :already_terminal ->
        {:reply, :not_running, state}
    end
  end

  def handle_call({:at_turn_boundary, _fun}, _from, %{task_ref: ref} = state)
      when not is_nil(ref),
      do: {:reply, :busy, state}

  def handle_call({:at_turn_boundary, fun}, _from, state), do: {:reply, {:ok, fun.()}, state}

  @impl true
  def handle_cast(:nudge, state), do: {:noreply, maybe_start(state)}

  @impl true
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

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

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
    case Ledger.claim_next(state.db, state.session_key, "lane:#{inspect(self())}") do
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

        {:error, %{reason: reason, terminal_publish: fun, record_in_txn: action}}
        when is_function(fun, 1) and is_function(action, 1) ->
          {"failed", error_text(reason), fun, action, nil}

        {:error, %{reason: reason, record_in_txn: action, after_commit: committed}}
        when is_function(action, 1) and is_function(committed, 1) ->
          {"failed", error_text(reason), nil, action, committed}

        {:error, %{reason: reason, terminal_publish: fun}} when is_function(fun, 1) ->
          {"failed", error_text(reason), fun, nil, nil}

        {:error, reason} ->
          {"failed", error_text(reason), nil, nil, nil}
      end

    {finish_result, recorded} =
      if in_txn do
        {:ok, {won, recorded}} =
          DB.transaction_then(
            state.db,
            fn txn ->
              if Ledger.finish_in_txn(txn, seq, terminal, error) do
                {true, in_txn.(txn)}
              else
                {false, nil}
              end
            end,
            fn txn, result ->
              Rules.row_commit_in_txn(txn, [])
              result
            end
          )

        {if(won, do: :ok, else: :already_terminal), recorded}
      else
        {Ledger.finish(state.db, seq, terminal, error), nil}
      end

    case finish_result do
      :ok ->
        if is_function(after_commit, 1), do: after_commit.(recorded)

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

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
