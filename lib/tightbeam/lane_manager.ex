defmodule Tightbeam.LaneManager do
  @moduledoc """
  Maintains lanes from admission, lane state reports and process monitors.
  Boot recovery and a slow consistency check repair work whose signal was lost.
  """

  use GenServer
  alias Tightbeam.{DB, HarnessHealth, Ledger, SessionLane}

  defstruct [
    :db,
    :name,
    :lane_sup,
    :task_sup,
    :runner,
    :interval,
    :terminal_publisher,
    :on_terminal,
    lanes: %{},
    reaping: %{}
  ]

  @doc """
  Start the reconciler. Required opts: `:lane_sup` (the lane
  DynamicSupervisor), `:task_sup`, `:runner` (passed through to lanes).
  Optional: `:db`, `:interval` (scan period, ms), `:name`. Boot recovery runs
  before the first scan.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Force a reconcile pass now (also used by tests)."
  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @doc "Ensure a lane exists for a session (idempotent) and nudge it."
  @spec ensure_lane(GenServer.server(), String.t()) :: :ok
  def ensure_lane(server \\ __MODULE__, session_key),
    do: GenServer.call(server, {:ensure_lane, session_key})

  @doc """
  Ensure a lane exists (idempotent) WITHOUT ringing its doorbell.

  For callers that need a session to have a boundary owner rather than need its
  work started — `identity apply` is the one. Nudging would make an idle lane
  claim a queued turn, so a caller that must not wait on queued work would have
  manufactured the very running turn it then defers to (tenet T-CONCURRENCY).
  A lane created here still self-nudges once from `init/1`; what this avoids is
  the caller ADDING a doorbell to a lane that already exists.
  """
  @spec ensure_lane_quiet(GenServer.server(), String.t()) :: :ok
  def ensure_lane_quiet(server \\ __MODULE__, session_key),
    do: GenServer.call(server, {:ensure_lane_quiet, session_key})

  @doc "Ensure an idle settlement lane, reserving a newly created lane before its first drain."
  @spec ensure_settlement_lane(GenServer.server(), String.t()) ::
          {:ok, pid(), reference() | nil} | {:error, :reservation_lost}
  def ensure_settlement_lane(server \\ __MODULE__, session_key),
    do: GenServer.call(server, {:ensure_settlement_lane, session_key}, :infinity)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      lane_sup: Keyword.fetch!(opts, :lane_sup),
      task_sup: Keyword.fetch!(opts, :task_sup),
      runner: Keyword.fetch!(opts, :runner),
      terminal_publisher: Keyword.get(opts, :terminal_publisher, fn _ -> :ok end),
      on_terminal: Keyword.get(opts, :on_terminal, fn _, _ -> :ok end),
      interval: Keyword.get(opts, :interval, 180_000)
    }

    # Boot recovery happens before the first scan starts nudging lanes.
    for seq <- Ledger.recover_running(state.db) do
      {:ok, [[session_key]]} =
        DB.query(state.db, "SELECT sessionKey FROM turns WHERE seq=?1", [seq])

      SessionLane.release_recovered(session_key, seq)
    end

    HarnessHealth.resume_other_routes(state.db)
    schedule(state.interval)
    {:ok, do_reconcile(state)}
  end

  @impl true
  def handle_call(:reconcile, _from, state), do: {:reply, :ok, do_reconcile(state)}

  def handle_call({:ensure_lane, session_key}, _from, state) do
    ensure(state, session_key)
    SessionLane.nudge(session_key)
    {:reply, :ok, state}
  end

  def handle_call({:ensure_lane_quiet, session_key}, _from, state) do
    ensure(state, session_key)
    {:reply, :ok, state}
  end

  def handle_call({:ensure_settlement_lane, session_key}, {owner, _tag}, state) do
    reply =
      case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
        [{pid, _}] ->
          {:ok, pid, nil}

        [] ->
          token = make_ref()

          case DynamicSupervisor.start_child(
                 state.lane_sup,
                 {SessionLane,
                  lane_opts(state, session_key,
                    settlement_reservation: token,
                    settlement_owner: owner
                  )}
               ) do
            {:ok, pid} -> {:ok, pid, token}
            {:error, {:already_started, _pid}} -> {:error, :reservation_lost}
            {:error, _reason} -> {:error, :reservation_lost}
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:lane_state, pid, session_key, seq}, state) do
    {ref, _, _} =
      Map.get_lazy(state.lanes, pid, fn -> {Process.monitor(pid), session_key, seq} end)

    {:noreply, %{state | lanes: Map.put(state.lanes, pid, {ref, session_key, seq})}}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state.interval)
    {:noreply, do_reconcile(state, true)}
  end

  def handle_info({ref, result}, state) when is_map_key(state.reaping, ref) do
    Process.demonitor(ref, [:flush])
    if match?({:ok, [_ | _]}, result), do: republish_terminals(state, false)
    {:noreply, %{state | reaping: Map.delete(state.reaping, ref)}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.lanes, pid) do
      {{^ref, key, _seq}, lanes} ->
        state = %{state | lanes: lanes}
        {:noreply, repair_lane(state, key)}

      _ ->
        {:noreply, %{state | reaping: Map.delete(state.reaping, ref)}}
    end
  end

  defp do_reconcile(state, detect \\ false) do
    DB.background_pass(fn -> reconcile_pass(state, detect) end, state)
  end

  defp reconcile_pass(state, detect) do
    republish_terminals(state, detect)

    Enum.reduce(Ledger.pending_sessions(state.db), state, fn session_key, acc ->
      active? =
        Enum.any?(acc.lanes, fn {_pid, {_ref, key, seq}} ->
          key == session_key and not is_nil(seq) and
            match?(
              {:ok, [["running"]]},
              DB.query(state.db, "SELECT status FROM turns WHERE seq=?1", [seq])
            )
        end)

      if detect and active? do
        acc
      else
        repair_lane(acc, session_key, detect)
      end
    end)
  end

  defp republish_terminals(state, detect) do
    DB.background_pass(fn ->
      # Re-publish terminals whose publication may have been lost to a crash —
      # to the WIRE, not just the ledger: without frames, a client whose turn
      # died with the gateway keeps a stuck typing indicator forever.
      for %{seq: seq} = row <- Ledger.unpublished_terminals(state.db) do
        if detect,
          do:
            Tightbeam.SchedulerMisses.record(
              :lane_terminal,
              seq,
              max(0, System.system_time(:millisecond) - row.ended_at)
            )

        state.terminal_publisher.(row)
        Ledger.mark_published(state.db, seq)
        state.on_terminal.(row.session_key, seq)
      end
    end)
  end

  defp repair_lane(state, session_key, detect \\ false) do
    ensure(state, session_key)

    if Enum.any?(state.reaping, fn {_ref, key} -> key == session_key end) do
      state
    else
      task =
        Task.Supervisor.async_nolink(state.task_sup, fn ->
          SessionLane.repair(session_key, detect)
        end)

      %{state | reaping: Map.put(state.reaping, task.ref, session_key)}
    end
  end

  defp ensure(state, session_key) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] ->
        if not Process.alive?(pid), do: start_lane(state, session_key)

      [] ->
        start_lane(state, session_key)
    end
  end

  defp start_lane(state, session_key) do
    DynamicSupervisor.start_child(state.lane_sup, {SessionLane, lane_opts(state, session_key)})
  end

  defp lane_opts(state, session_key, extra \\ []) do
    [
      session_key: session_key,
      lane_manager: state.name,
      db: state.db,
      task_sup: state.task_sup,
      runner: state.runner,
      terminal_publisher: state.terminal_publisher,
      on_terminal: state.on_terminal
    ] ++ extra
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
