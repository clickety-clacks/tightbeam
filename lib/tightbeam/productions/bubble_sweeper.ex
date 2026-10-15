defmodule Tightbeam.Productions.BubbleSweeper do
  @moduledoc """
  Recognizes committed terminals from turn-end signals. A slow consistency
  check repairs missed signals using the durable terminal-prefix cursor.
  An in-memory set prevents repeated recognition of out-of-order terminals
  until restart. Recognition is idempotent across restarts.
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
      interval: Keyword.get(opts, :interval, 180_000),
      recognized: MapSet.new(),
      missed: MapSet.new(),
      failures: %{},
      first_pass: true
    }

    # Boot IS a sweep: whatever terminalized while no sweeper was alive —
    # boot-recovered failed_unknown rows, retire-drained cancels, and any
    # terminal whose cast was lost to a crash — is behind the cursor.
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_cast({:recognize, seq}, state) do
    state =
      DB.background_pass(
        fn ->
          if seq > read_cursor(state.db) and not MapSet.member?(state.recognized, seq) and
               recognize_one(state.db, seq) == :ok do
            advance_cursor(%{state | recognized: MapSet.put(state.recognized, seq)})
          else
            state
          end
        end,
        state
      )

    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {count, state} = sweep(state)
    {:reply, count, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_count, state} = sweep(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  defp sweep(state), do: DB.background_pass(fn -> sweep_pass(state) end, {0, state})

  defp sweep_pass(state) do
    cursor = read_cursor(state.db)

    {:ok, rows} =
      DB.query(
        state.db,
        """
        SELECT seq, endedAt FROM turns
        WHERE seq > ?1 AND endedAt IS NOT NULL
          AND seq NOT IN (SELECT value FROM json_each(?3))
        ORDER BY seq LIMIT ?2
        """,
        [cursor, @batch, JSON.encode!(MapSet.to_list(state.recognized))]
      )

    cutoff = System.system_time(:millisecond) - 60_000

    {count, state} =
      Enum.reduce(rows, {0, state}, fn [seq, ended_at], {count, state} ->
        state =
          if not state.first_pass and ended_at < cutoff and not MapSet.member?(state.missed, seq) do
            Tightbeam.SchedulerMisses.record(:bubble, seq)
            %{state | missed: MapSet.put(state.missed, seq)}
          else
            state
          end

        case recognize_one(state.db, seq) do
          :ok ->
            {count + 1,
             %{
               state
               | recognized: MapSet.put(state.recognized, seq),
                 failures: Map.delete(state.failures, seq)
             }}

          {:error, %DB.Overloaded{}} ->
            {count, state}

          _ ->
            failures = Map.get(state.failures, seq, 0) + 1

            if failures >= 5 do
              Logger.error("bubble recognition skipping turn #{seq} after #{failures} failures")

              {count,
               %{
                 state
                 | recognized: MapSet.put(state.recognized, seq),
                   failures: Map.delete(state.failures, seq)
               }}
            else
              {count, %{state | failures: Map.put(state.failures, seq, failures)}}
            end
        end
      end)

    {count, advance_cursor(%{state | first_pass: false})}
  end

  defp advance_cursor(state) do
    cursor = read_cursor(state.db)

    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT seq, endedAt IS NOT NULL FROM turns WHERE seq>?1 ORDER BY seq LIMIT ?2",
        [cursor, @batch]
      )

    prefix =
      Enum.take_while(rows, fn [seq, ended] ->
        ended == 1 and MapSet.member?(state.recognized, seq)
      end)

    last = if prefix == [], do: cursor, else: prefix |> List.last() |> hd()

    if last > cursor do
      {:ok, _} =
        DB.query(
          state.db,
          "INSERT INTO production_cursors(name,seq) VALUES('bubble',?1) ON CONFLICT(name) DO UPDATE SET seq=excluded.seq",
          [last]
        )
    end

    %{
      state
      | recognized: MapSet.reject(state.recognized, &(&1 <= last)),
        missed: MapSet.reject(state.missed, &(&1 <= last))
    }
  end

  defp read_cursor(db) do
    case DB.query(db, "SELECT seq FROM production_cursors WHERE name = ?1", [@cursor_name]) do
      {:ok, [[seq]]} -> seq
      {:ok, []} -> 0
      {:error, error} -> raise error
    end
  end

  defp recognize_one(db, seq) do
    case Bubble.recognize_terminal(db, seq) do
      {:error, error} -> {:error, error}
      _ -> :ok
    end
  rescue
    error in DB.Overloaded ->
      Logger.debug("database overloaded; background pass deferred")
      {:error, error}

    error ->
      Logger.error(
        "bubble recognition of turn #{seq} crashed and was contained: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.error(
        "bubble recognition of turn #{seq} crashed and was contained: #{inspect({kind, reason})}"
      )

      {:error, {kind, reason}}
  end
end
