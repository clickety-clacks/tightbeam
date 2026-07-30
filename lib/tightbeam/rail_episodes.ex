defmodule Tightbeam.RailEpisodes do
  @moduledoc """
  THE single writer for malfunction-episode lifecycle (§A3/§B).

  Every open, attach and withdrawal is decided HERE, in one serialized process, in
  arrival order — never in SQL, never across a process gap. Two rounds of review died on
  the alternative: an ordering reconstructed after the fact from a cutoff read out of a
  table is always a window, and only the size of the window changes.

  The load-bearing property is WHEN the cutoff is minted. `decide` asks for a `position`
  BEFORE it runs a check; the actor's recovery hand-off arrives afterwards carrying it,
  and this process withdraws only episodes whose newest summons it holds as older than
  that position. So a verdict authorizes closing only what existed when its check
  STARTED: anything summoned during or after the check — fresh episode or attach onto an
  open one — is outside the authorized set by construction, however long the actor takes.
  A cutoff read after the verdict could always grow to include events the verdict never
  saw. This one cannot.

  Minting touches no episode state and is not an enforcement effect, which is what keeps
  `decide` effect-free (§B).

  Ordering state is `seq` plus the newest summons position per episode, held HERE. It is
  deliberately not in `lifecycle_events`: those are observability-only and never decision
  inputs (§E3), and reading them to decide a closure is the authority violation that sank
  the previous attempt. Episodes themselves stay durable in `decision_requests`.

  A restart empties the map, so every surviving episode reads as older than any later
  evaluation and the next healthy verdict closes it. That is the conservative direction
  and it is truthful: the episode really is older than the evaluation asking.
  """

  use GenServer

  alias Tightbeam.{DB, Escalation, EventLog}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Mint the cutoff for one check-tier evaluation, or `nil` when there is nothing to close.

  `nil` means this statute has no open episode, so the evaluation carries no recovery and
  `to_close` stays empty — a healthy check with nothing outstanding schedules no work.
  """
  @spec evaluating(DB.server(), String.t(), GenServer.server()) :: integer() | nil
  def evaluating(db, statute, server \\ __MODULE__) do
    call(server, {:evaluating, db, statute}, fn ->
      unavailable(db, statute, "evaluating")
      nil
    end)
  end

  @doc "Hand a malfunction's summons to the writer. Fails soft: the deny never depends on it."
  @spec summon(DB.server(), map(), map(), map(), GenServer.server()) :: :ok
  def summon(db, call, statute, ctx, server \\ __MODULE__) do
    call(server, {:summon, db, call, statute, ctx}, fn ->
      unavailable(db, statute_name(statute), "summon")
      :ok
    end)
  end

  @doc "Hand recovery to the writer for a verdict minted at `position`."
  @spec recovered(DB.server(), String.t(), integer(), GenServer.server()) :: :ok
  def recovered(db, statute, position, server \\ __MODULE__) do
    call(server, {:recovered, db, statute, position}, fn ->
      unavailable(db, statute, "recovered")
      :ok
    end)
  end

  @impl true
  def init(:ok), do: {:ok, %{seq: 0, last_summon: %{}}}

  @impl true
  def handle_call({:evaluating, db, statute}, _from, state) do
    state = %{state | seq: state.seq + 1}

    position = if Escalation.open_episodes(db, statute) == [], do: nil, else: state.seq

    {:reply, position, state}
  end

  def handle_call({:summon, db, call, statute, ctx}, _from, state) do
    state = %{state | seq: state.seq + 1}

    # Both outcomes stamp or skip inside this process, so an attach — which writes no
    # `decision_requests` row at all — is ordered exactly like a fresh open.
    state =
      case Escalation.summon(db, call, statute, ctx) do
        {:ok, id} -> put_in(state.last_summon[id], state.seq)
        :error -> state
      end

    {:reply, :ok, state}
  end

  def handle_call({:recovered, db, statute, position}, _from, state) do
    stale =
      db
      |> Escalation.open_episodes(statute)
      |> Enum.filter(&(Map.get(state.last_summon, &1, 0) < position))

    :ok = Escalation.withdraw_episodes(db, stale, statute)

    {:reply, :ok, %{state | last_summon: Map.drop(state.last_summon, stale)}}
  end

  # The writer is a named child; calling it when it is absent must not raise into a call
  # path that has already decided its denial (§B). Degrading is recorded rather than
  # silent — the deny is unaffected either way, the summons fails soft exactly as an
  # unreachable owner does, and recovery simply does not happen this evaluation and
  # resumes when the writer returns.
  defp call(server, message, on_unavailable) do
    GenServer.call(server, message)
  catch
    :exit, _ -> on_unavailable.()
  end

  defp unavailable(db, statute, verb) do
    EventLog.lifecycle(db, "rail_episode_writer_unavailable", statute || "unknown", verb)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp statute_name(statute), do: Map.get(statute, :name) || Map.get(statute, "name")
end
