defmodule Tightbeam.DB.Reader do
  @moduledoc false
  use GenServer
  alias Exqlite.Sqlite3
  alias Tightbeam.{DB, DBObservation}

  def start_link(path), do: GenServer.start_link(__MODULE__, path)

  def query(reader, sql, params, envelope) do
    token = make_ref()
    budget = max(0, envelope.deadline - System.monotonic_time(:millisecond))

    try do
      GenServer.call(reader, {:query, token, sql, params, envelope}, budget)
    catch
      :exit, {:timeout, _} ->
        # The reader waits for acknowledgement before starting another query.
        # Interrupt only this request, never an earlier or subsequent caller.
        case :persistent_term.get({__MODULE__, reader}, nil) do
          {^token, conn} -> Sqlite3.interrupt(conn)
          _ -> :ok
        end

        exit({:timeout, {GenServer, :call, [:redacted, budget]}})
    after
      send(reader, {:ack, token})
    end
  end

  @impl true
  def init(path) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
    :ok = DB.load_topline_unicode(conn)
    {:ok, conn}
  end

  @impl true
  def handle_call({:query, token, sql, params, envelope}, {caller, _} = from, conn) do
    monitor = Process.monitor(caller)
    :persistent_term.put({__MODULE__, self()}, {token, conn})
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
    GenServer.reply(from, response)

    receive do
      {:ack, ^token} -> :ok
      {:DOWN, ^monitor, :process, ^caller, _} -> :ok
    end

    Process.demonitor(monitor, [:flush])
    :persistent_term.erase({__MODULE__, self()})
    {:noreply, conn}
  end

  @impl true
  def handle_info({:ack, _}, conn), do: {:noreply, conn}

  @impl true
  def terminate(_, conn) do
    :persistent_term.erase({__MODULE__, self()})
    Sqlite3.close(conn)
  end
end
