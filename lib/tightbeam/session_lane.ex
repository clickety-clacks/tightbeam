defmodule Tightbeam.SessionLane do
  @moduledoc """
  One GenServer per active session — the serialized turn runner. It owns no
  queue in memory: the Ledger is the queue. On a nudge it claims the next turn
  (Ledger enforces one-per-session in SQL), runs it as a monitored TurnTask,
  and on completion records the terminal state + publishes, then drains.

  Topology (monitors, never links):
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
  alias Tightbeam.{Ledger, EventLog}

  @type runner :: (Ledger.turn() -> {:ok, term()} | {:error, term()})
  @type t :: %__MODULE__{
          session_key: String.t(),
          db: GenServer.server(),
          runner: runner(),
          task_sup: GenServer.server(),
          task_ref: reference() | nil,
          current_seq: integer() | nil,
          quarantined: boolean()
        }

  defstruct [
    :session_key,
    :db,
    :runner,
    :task_sup,
    task_ref: nil,
    current_seq: nil,
    quarantined: false
  ]

  @doc "Start the uniquely named serialized runner for one session."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    GenServer.start_link(__MODULE__, opts, name: via(session_key))
  end

  @doc "Build the unique Registry name for a session lane."
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_key), do: {:via, Registry, {Tightbeam.LaneRegistry, session_key}}

  @doc "Nudge the lane to check for work (from client post, wake, or reconciler)."
  @spec nudge(String.t()) :: :ok | :no_lane
  def nudge(session_key) do
    case Registry.lookup(Tightbeam.LaneRegistry, session_key) do
      [{pid, _}] -> GenServer.cast(pid, :nudge)
      [] -> :no_lane
    end
  end

  ## Server

  @doc "Initialize the lane and immediately schedule its first ledger check."
  @spec init(keyword()) :: {:ok, t()}
  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_key: Keyword.fetch!(opts, :session_key),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      task_sup: Keyword.fetch!(opts, :task_sup),
      # runner: (turn_map -> {:ok, result_map} | {:error, term}); injectable for tests
      runner: Keyword.fetch!(opts, :runner)
    }

    send(self(), :nudge)
    {:ok, state}
  end

  @doc "Handle a nudge without adding an in-memory queue."
  @spec handle_cast(:nudge, t()) :: {:noreply, t()}
  @impl true
  def handle_cast(:nudge, state), do: {:noreply, maybe_start(state)}

  @doc "Handle task completion, task death, and scheduled nudges while draining durably."
  @spec handle_info(term(), t()) :: {:noreply, t()}
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
    case Ledger.claim_next(state.db, state.session_key, "lane:#{inspect(self())}") do
      {:ok, turn} ->
        runner = state.runner

        task =
          Task.Supervisor.async_nolink(state.task_sup, fn ->
            {turn.seq, runner.(turn)}
          end)

        state
        |> Map.put(:task_ref, task.ref)
        |> Map.put(:current_seq, turn.seq)

      :busy ->
        state

      :none ->
        state
    end
  end

  defp finalize(state, seq, outcome) do
    {terminal, error} =
      case outcome do
        {:ok, _} -> {"delivered", nil}
        {:error, reason} -> {"failed", inspect(reason)}
      end

    case Ledger.finish(state.db, seq, terminal, error) do
      :ok -> publish_terminal(state, seq)
      :already_terminal -> :ok
    end
  end

  # At-least-once publication (review #2): the runner already broadcast the
  # assistant message + turn-state during the turn; here we ensure the terminal
  # row is marked published. The publisher hook is injected by the composition
  # root; in E1 the ledger's publishedAt marking is the observable seam.
  defp publish_terminal(state, seq), do: Ledger.mark_published(state.db, seq)
end
