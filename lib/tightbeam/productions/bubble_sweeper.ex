defmodule Tightbeam.Productions.BubbleSweeper do
  @moduledoc """
  The bubble production's own recognition process (spec production-machine-v1
  §The cycle). Two feeds, one consumer:

  - THE WIRED EDGE: terminal commits cast `{:recognize, seq}` here — the fast
    path, fired from the lane hook. A cast, deliberately: recognition enqueues
    turns, and enqueueing rings the LaneManager, so recognition run INSIDE the
    LaneManager (as a synchronous hook would) is a call to self — the review
    that forced this module found exactly that deadlock on the boot path.
  - THE SWEEP: a durable cursor over the turns table, advanced in batches each
    tick and at boot. This is what makes recognition "provably reachable by a
    sweep": a crash between a terminal committing and its cast being served
    loses nothing, because the cursor has not passed it. Recognition is
    idempotent (the LHS is a pure function of committed state; the enqueue
    dedupes on wakeId), so the fast path and the sweep overlapping is free.

  Every recognition is crash-isolated: one turn's failure to recognize is
  logged and never takes the sweeper, the lanes, or the turn-end shift with
  it — the bubble must stay deletable without touching the failing turn's own
  three obligations.
  """

  use GenServer

  alias Tightbeam.DB
  alias Tightbeam.Productions.Bubble

  require Logger

  @cursor_name "bubble"
  @batch 200

  @ddl """
  CREATE TABLE IF NOT EXISTS production_cursors (
    name TEXT PRIMARY KEY,
    seq  INTEGER NOT NULL
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "The wired edge: fire-and-forget recognition of one committed terminal."
  @spec recognize(GenServer.server(), integer()) :: :ok
  def recognize(server \\ __MODULE__, seq), do: GenServer.cast(server, {:recognize, seq})

  @doc "One synchronous sweep pass — the test seam for cursor semantics."
  @spec sweep_now(GenServer.server()) :: non_neg_integer()
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    state = %{
      db: Keyword.get(opts, :db, Tightbeam.DB),
      interval: Keyword.get(opts, :interval, 5_000)
    }

    # Boot IS a sweep: whatever terminalized while no sweeper was alive —
    # boot-recovered failed_unknown rows, retire-drained cancels, and any
    # terminal whose cast was lost to a crash — is behind the cursor.
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_cast({:recognize, seq}, state) do
    recognize_one(state.db, seq)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, sweep(state.db), state}

  @impl true
  def handle_info(:tick, state) do
    sweep(state.db)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  # Advance the cursor over the CONTIGUOUS TERMINAL PREFIX, recognizing each
  # row. Contiguous, because seqs terminalize out of order: seq 5 can still be
  # running when seq 6 finishes, and a cursor that skipped past 5 would never
  # revisit it — the exact lost-recognition this sweep exists to prevent. A
  # still-pending row therefore blocks the cursor (bounded by one turn's
  # duration; the cast edge keeps serving everything ahead of it). The cursor
  # commits AFTER the prefix is recognized: a crash mid-batch re-runs from the
  # old cursor into idempotent recognitions, never past an unrecognized row.
  defp sweep(db) do
    cursor = read_cursor(db)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT seq, endedAt IS NOT NULL FROM turns
        WHERE seq > ?1
        ORDER BY seq LIMIT ?2
        """,
        [cursor, @batch]
      )

    prefix =
      rows
      |> Enum.take_while(fn [_seq, ended] -> ended == 1 end)
      |> Enum.map(&hd/1)

    Enum.each(prefix, &recognize_one(db, &1))

    case List.last(prefix) do
      nil ->
        0

      last ->
        {:ok, _} =
          DB.query(
            db,
            "INSERT INTO production_cursors (name, seq) VALUES (?1, ?2) " <>
              "ON CONFLICT(name) DO UPDATE SET seq = excluded.seq",
            [@cursor_name, last]
          )

        length(prefix)
    end
  end

  defp read_cursor(db) do
    case DB.query(db, "SELECT seq FROM production_cursors WHERE name = ?1", [@cursor_name]) do
      {:ok, [[seq]]} -> seq
      _ -> 0
    end
  end

  defp recognize_one(db, seq) do
    Bubble.recognize_terminal(db, seq)
  rescue
    error ->
      Logger.error(
        "bubble recognition of turn #{seq} crashed and was contained: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "bubble recognition of turn #{seq} crashed and was contained: #{inspect({kind, reason})}"
      )

      :ok
  end
end
