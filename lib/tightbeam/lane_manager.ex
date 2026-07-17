defmodule Tightbeam.LaneManager do
  @moduledoc """
  The Reconciler (port-spec review #1 — liveness). The doorbell (SessionLane.
  nudge) is an optimization; THIS scan is the guarantee. At boot and every
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

  defstruct [:db, :lane_sup, :task_sup, :runner, :interval]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Force a reconcile pass now (also used by tests)."
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @doc "Ensure a lane exists for a session (idempotent) and nudge it."
  def ensure_lane(server \\ __MODULE__, session_key), do: GenServer.call(server, {:ensure_lane, session_key})

  @impl true
  def init(opts) do
    state = %__MODULE__{
      db: Keyword.get(opts, :db, Tightbeam.DB),
      lane_sup: Keyword.fetch!(opts, :lane_sup),
      task_sup: Keyword.fetch!(opts, :task_sup),
      runner: Keyword.fetch!(opts, :runner),
      interval: Keyword.get(opts, :interval, 5_000)
    }

    # Boot recovery happens before the first scan starts nudging lanes.
    Ledger.recover_running(state.db)
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

  @impl true
  def handle_info(:tick, state) do
    schedule(state.interval)
    {:noreply, do_reconcile(state)}
  end

  defp do_reconcile(state) do
    # Re-publish terminals whose publication may have been lost to a crash.
    for %{seq: seq} <- Ledger.unpublished_terminals(state.db), do: Ledger.mark_published(state.db, seq)

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
          {SessionLane, session_key: session_key, db: state.db, task_sup: state.task_sup, runner: state.runner}
        )
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
