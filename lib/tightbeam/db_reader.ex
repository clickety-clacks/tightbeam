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

  def read_transaction(reader, fun, timeout) when is_function(fun, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      GenServer.call(reader, {:read_transaction, fun, deadline}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, %DB.DeadlineExceeded{}}
      :exit, reason -> {:error, reason}
    end
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

  def handle_call({:read_transaction, fun, deadline}, _from, conn) do
    remaining = deadline - System.monotonic_time(:millisecond)

    {timer, timer_ref} =
      spawn_monitor(fn ->
        receive do
          :done -> :ok
        after
          max(0, remaining) -> Sqlite3.interrupt(conn)
        end
      end)

    result =
      if remaining > 0,
        do: run_read_transaction(conn, fun, deadline),
        else: {:error, %DB.DeadlineExceeded{}}

    send(timer, :done)
    receive do: ({:DOWN, ^timer_ref, :process, ^timer, _} -> :ok)
    {:reply, result, conn}
  end

  defp run_read_transaction(conn, fun, deadline) do
    txn = %DB.Txn{conn: conn, deadline: deadline}

    try do
      DB.Txn.ensure_before_deadline(txn)
      :ok = DB.execute_sql!(conn, "BEGIN")
      result = fun.(txn)
      DB.Txn.ensure_before_deadline(txn)
      :ok = DB.execute_sql!(conn, "COMMIT")
      {:ok, result}
    rescue
      error ->
        _ = Sqlite3.execute(conn, "ROLLBACK")
        {:error, error}
    end
  end

  @impl true
  def terminate(_, conn) do
    :ok = DB.clear_statement_cache(conn)
    Sqlite3.close(conn)
  end
end
