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

  Quarantine: a turn recovered as failed_unknown quarantines its
  session; the lane will not start the next queued turn until the orphaned ACP
  request is observed resolved (Conn.pending_count hits 0 / orphan_resolved) or
  the adapter generation is recycled. E1 proves the mechanism with a fake; the
  coordinator generation wiring lands with the AdapterCoordinator.
  """

  use GenServer
  require Logger
  alias Tightbeam.{DB, Ledger, EventLog}

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
    current_message_id: nil,
    quarantined: false
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
  """
  @spec cancel_current(String.t()) ::
          {:ok, %{seq: integer(), message_id: String.t()}} | :not_running | :no_lane
  def cancel_current(session_key, cancel_boundary \\ nil) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] -> GenServer.call(pid, {:cancel_current, cancel_boundary})
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
  def handle_call({:cancel_current, _cancel_boundary}, _from, %{task_ref: nil} = state),
    do: {:reply, :not_running, state}

  def handle_call({:cancel_current, cancel_boundary}, _from, state) do
    finish =
      if is_function(cancel_boundary, 1),
        do: run_cancel_boundary(cancel_boundary, state),
        else: Ledger.finish(state.db, state.current_seq, "canceled")

    case finish do
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

  defp run_cancel_boundary(cancel_boundary, state) do
    cancel_boundary.(state.current_seq)
  rescue
    _ -> Ledger.finish(state.db, state.current_seq, "canceled")
  catch
    :exit, _ -> Ledger.finish(state.db, state.current_seq, "canceled")
  end

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
    finalize(state, seq, {:error, :task_crash})
    {:noreply, maybe_start(%{state | task_ref: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, %{task_ref: ref} = state) do
    {:noreply, maybe_start(%{state | task_ref: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp maybe_start(%{task_ref: ref} = state) when not is_nil(ref), do: state
  defp maybe_start(%{quarantined: true} = state), do: state

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
    end
  end

  defp finalize(state, seq, outcome) do
    {terminal, error, publish, in_txn, post_commit} =
      case outcome do
        {:ok, %{terminal_publish: fun}} when is_function(fun, 1) ->
          {"delivered", nil, fun, nil, nil}

        {:ok, _} ->
          {"delivered", nil, nil, nil, nil}

        {:error, %{reason: reason, terminal_publish: fun, adjudicate_in_txn: action} = attrs}
        when is_function(fun, 1) and is_function(action, 1) ->
          {"failed", inspect(reason), fun, action, Map.get(attrs, :post_commit)}

        {:error, %{reason: reason, terminal_publish: fun}} when is_function(fun, 1) ->
          {"failed", inspect(reason), fun, nil, nil}

        {:error, reason} ->
          {"failed", inspect(reason), nil, nil, nil}
      end

    finish_result =
      if in_txn do
        {:ok, won} =
          DB.transaction(state.db, fn txn ->
            if Ledger.finish_in_txn(txn, seq, terminal, error) do
              in_txn.(txn)
              true
            else
              false
            end
          end)

        if won, do: :ok, else: :already_terminal
      else
        Ledger.finish(state.db, seq, terminal, error)
      end

    case finish_result do
      :ok ->
        if is_function(post_commit, 0), do: post_commit.()

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
end
