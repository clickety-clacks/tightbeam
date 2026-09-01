defmodule Tightbeam.LaneManager do
  @moduledoc """
  The Reconciler — the liveness guarantee. The doorbell (SessionLane.nudge)
  is an optimization; THIS scan is the guarantee. At boot and every
  `interval` ms it:
  1. recovers running turns → failed_unknown (survives a crash that left a lane
     mid-turn),
  2. re-publishes any unpublished terminal rows (at-least-once publication),
  3. ensures a SessionLane exists for every session with pending work and
     nudges it.

  Lanes are named in Tightbeam.LaneRegistry (unique per session), so "start a
  lane if absent" is atomic and there is never more than one lane per session.
  """

  use GenServer
  alias Tightbeam.{Ledger, SessionLane}

  defstruct [
    :db,
    :lane_sup,
    :task_sup,
    :runner,
    :interval,
    :terminal_publisher,
    :on_terminal,
    :on_idle,
    :on_boot
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

  @impl true
  def init(opts) do
    state = %__MODULE__{
      db: Keyword.get(opts, :db, Tightbeam.DB),
      lane_sup: Keyword.fetch!(opts, :lane_sup),
      task_sup: Keyword.fetch!(opts, :task_sup),
      runner: Keyword.fetch!(opts, :runner),
      terminal_publisher: Keyword.get(opts, :terminal_publisher, fn _ -> :ok end),
      on_terminal: Keyword.get(opts, :on_terminal, fn _, _ -> :ok end),
      on_idle: Keyword.get(opts, :on_idle, fn _ -> :ok end),
      on_boot: Keyword.get(opts, :on_boot, fn -> :ok end),
      interval: Keyword.get(opts, :interval, 5_000)
    }

    # Boot recovery happens before the first scan starts nudging lanes.
    Ledger.recover_running(state.db)
    state.on_boot.()
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

  @impl true
  def handle_info(:tick, state) do
    schedule(state.interval)
    {:noreply, do_reconcile(state)}
  end

  defp do_reconcile(state) do
    # Re-publish terminals whose publication may have been lost to a crash —
    # to the WIRE, not just the ledger: without frames, a client whose turn
    # died with the gateway keeps a stuck typing indicator forever.
    for %{seq: seq} = row <- Ledger.unpublished_terminals(state.db) do
      state.terminal_publisher.(row)
      Ledger.mark_published(state.db, seq)
      state.on_terminal.(row.session_key, seq)
    end

    for session_key <- Ledger.pending_sessions(state.db) do
      ensure(state, session_key)
      SessionLane.nudge(session_key)
    end

    state
  end

  defp ensure(state, session_key) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          state.lane_sup,
          {SessionLane,
           session_key: session_key,
           db: state.db,
           task_sup: state.task_sup,
           runner: state.runner,
           terminal_publisher: state.terminal_publisher,
           on_terminal: state.on_terminal,
           on_idle: state.on_idle}
        )
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
