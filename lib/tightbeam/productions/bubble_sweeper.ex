defmodule Tightbeam.Productions.BubbleSweeper do
  @moduledoc """
  Recognizes committed terminals from turn-end signals. A slow consistency
  check repairs missed signals using the durable terminal-prefix cursor.
  Acknowledgements ahead of that cursor prevent repeated recognition when
  turns finish out of order, including across a restart.
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
      interval: Keyword.get(opts, :interval, 180_000)
    }

    # Boot IS a sweep: whatever terminalized while no sweeper was alive —
    # boot-recovered failed_unknown rows, retire-drained cancels, and any
    # terminal whose cast was lost to a crash — is behind the cursor.
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_cast({:recognize, seq}, state) do
    DB.background_pass(fn ->
      if seq > read_cursor(state.db) and not acknowledged?(state.db, seq) do
        if recognize_one(state.db, seq) == :ok do
          acknowledge(state.db, seq)
          advance_cursor(state.db)
        end
      end
    end)

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

  # Keep out-of-order acknowledgements until the terminal prefix reaches them.
  defp sweep(db), do: DB.background_pass(fn -> sweep_pass(db) end, 0)

  defp sweep_pass(db) do
    cursor = read_cursor(db)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT seq, endedAt IS NOT NULL FROM turns AS t
        WHERE seq > ?1 AND endedAt IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM production_cursors WHERE name = 'bubble:' || t.seq
          )
        ORDER BY seq LIMIT ?2
        """,
        [cursor, @batch]
      )

    recognized =
      rows
      |> Enum.filter(fn [_seq, ended] -> ended == 1 end)
      |> Enum.reduce(0, fn [seq, _], count ->
        if acknowledged?(db, seq) do
          count
        else
          Tightbeam.SchedulerMisses.record(:bubble, seq)

          case recognize_one(db, seq) do
            :ok ->
              Process.delete({__MODULE__, seq})
              acknowledge(db, seq)
              count + 1

            {:error, %DB.Overloaded{}} ->
              count

            _ ->
              failures = Process.get({__MODULE__, seq}, 0) + 1

              if failures >= 5 do
                Logger.error("bubble recognition skipping turn #{seq} after #{failures} failures")
                Process.delete({__MODULE__, seq})
                acknowledge(db, seq)
              else
                Process.put({__MODULE__, seq}, failures)
              end

              count
          end
        end
      end)

    advance_cursor(db)
    recognized
  end

  defp acknowledged?(db, seq) do
    {:ok, rows} =
      DB.query(db, "SELECT seq FROM production_cursors WHERE name=?1", ["bubble:#{seq}"])

    rows != []
  end

  defp acknowledge(db, seq) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO production_cursors(name,seq) VALUES(?1,?2) ON CONFLICT(name) DO NOTHING",
        ["bubble:#{seq}", seq]
      )
  end

  defp advance_cursor(db) do
    cursor = read_cursor(db)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT seq, endedAt IS NOT NULL, EXISTS(SELECT 1 FROM production_cursors WHERE name='bubble:' || t.seq) FROM turns AS t WHERE seq>?1 ORDER BY seq LIMIT ?2",
        [cursor, @batch]
      )

    prefix = Enum.take_while(rows, fn [_seq, ended, acknowledged] -> ended == 1 and acknowledged == 1 end)

    if prefix != [] do
      last = prefix |> List.last() |> hd()

      {:ok, _} =
        DB.query(
          db,
          "INSERT INTO production_cursors(name,seq) VALUES('bubble',?1) ON CONFLICT(name) DO UPDATE SET seq=excluded.seq",
          [last]
        )

      clear_acknowledgements(db, last)
    end
  end

  defp clear_acknowledgements(db, last) do
    {:ok, _} =
      DB.query(db, "DELETE FROM production_cursors WHERE name LIKE 'bubble:%' AND seq<=?1", [last])
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
