defmodule Tightbeam.DB.Reader do
  @moduledoc false
  use GenServer
  alias Exqlite.Sqlite3
  alias Tightbeam.{DB, DBObservation}

  def start_link(path), do: GenServer.start_link(__MODULE__, path)

  def query(reader, sql, params, envelope) do
    budget = max(0, envelope.deadline - System.monotonic_time(:millisecond))
    GenServer.call(reader, {:query, sql, params, envelope}, budget)
  end

  @impl true
  def init(path) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
    :ok = DB.load_topline_unicode(conn)
    :ok = DB.enable_statement_cache(conn)
    {:ok, conn}
  end

  @impl true
  def handle_call({:query, sql, params, envelope}, _from, conn) do
    remaining = envelope.deadline - System.monotonic_time(:millisecond)

    # The timer covers the race where the caller times out just before this
    # request starts. Join it before admitting the next statement.
    {timer, timer_ref} =
      spawn_monitor(fn ->
        receive do
          :done -> :ok
        after
          max(0, remaining) -> Sqlite3.interrupt(conn)
        end
      end)

    reply =
      DBObservation.server(envelope, max(0, remaining), fn ->
        result =
          if remaining > 0,
            do: DB.read_query(conn, sql, params),
            else: {:error, %DB.DeadlineExceeded{}}

        result =
          if System.monotonic_time(:millisecond) >= envelope.deadline,
            do: {:error, %DB.DeadlineExceeded{}},
            else: result

        {:reply, result, nil}
      end)

    send(timer, :done)
    receive do: ({:DOWN, ^timer_ref, :process, ^timer, _} -> :ok)
    {:reply, response, nil} = reply
    {:reply, response, conn}
  end

  @impl true
  def terminate(_, conn) do
    :ok = DB.clear_statement_cache(conn)
    Sqlite3.close(conn)
  end
end
