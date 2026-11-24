defmodule Tightbeam.RunningModel do
  @moduledoc """
  The one writer of the model each session is actually running.

  Adapters report what their harness read back; `Tightbeam.AdapterCoordinator`
  forwards only reports from the adapter instance and generation it currently
  holds, and tells this process when an instance is gone. Everything arrives in
  one mailbox, in order, from that one sender. The write is
  `Org.set_running_model/4`: it goes through the session mutation seam, so an
  unchanged report publishes nothing and a changed one bumps the session's row
  version and publishes the ordinary `session.updated` after commit.

  The value is stored, never probed: reading a session never loads an agent.
  Doubt resolves to null. Starting clears every stored value before any adapter
  can start (nothing is loaded yet), then asks live adapters, if this is a
  restart of the writer alone, to report again. A report is accepted only while
  its harness session is still the session's current pointer on the adapter's
  own harness and host.
  """
  use GenServer
  require Logger

  alias Tightbeam.{AdapterCoordinator, DB, Org}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "An adapter's report for one harness session: `%{id:, label:}` or nil."
  def report(server, key, generation, sid, report),
    do: cast(server, {:report, key, generation, sid, report})

  @doc "The adapter for `key` is gone: every model it was reporting is unknown."
  def adapter_gone(server, key), do: cast(server, {:adapter_gone, key})

  defp cast(server, message) do
    if GenServer.whereis(server), do: GenServer.cast(server, message)
    :ok
  end

  # The boot clear finishes inside init, so the supervisor starts the adapter
  # coordinator only after it: a clear can never erase a fresh report.
  @impl true
  def init(opts) do
    state = %{
      db: Keyword.get(opts, :db, DB),
      coordinator: Keyword.get(opts, :coordinator, AdapterCoordinator),
      pending: %{}
    }

    guarded(fn ->
      state.db |> running_sessions() |> Enum.each(&clear(state.db, &1.session_key))
    end)

    {:ok, state, {:continue, :resync}}
  end

  @impl true
  def handle_continue(:resync, state) do
    AdapterCoordinator.request_running_model_reports(state.coordinator)
    {:noreply, state}
  end

  # `pending` is the latest report per adapter and harness session id. It lets a
  # report that arrives before the gateway records its pointer (a harness reports
  # a new session's model first) apply when the pointer lands, and lets a new
  # pointer pick up a report already held. It is replaced by the next report,
  # dropped on unload (a nil report) and with its adapter.
  @impl true
  def handle_cast({:report, key, generation, sid, report}, state) do
    case state.pending[{key, sid}] do
      {held, _report} when held > generation ->
        {:noreply, state}

      _ ->
        pending =
          if report,
            do: Map.put(state.pending, {key, sid}, {generation, report}),
            else: Map.delete(state.pending, {key, sid})

        guarded(fn -> apply_report(state.db, key, sid, report, nil) end)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_cast({:pointer_recorded, session_key, sid}, state) do
    for {{key, ^sid}, {_generation, report}} <- state.pending do
      guarded(fn -> apply_report(state.db, key, sid, report, session_key) end)
    end

    {:noreply, state}
  end

  def handle_cast({:adapter_gone, key}, state) do
    guarded(fn ->
      state.db
      |> running_sessions()
      |> Enum.filter(&(Tightbeam.Gateway.adapter_key(&1) == key))
      |> Enum.each(&clear(state.db, &1.session_key))
    end)

    {:noreply, %{state | pending: Map.reject(state.pending, fn {{k, _sid}, _} -> k == key end)}}
  end

  defp apply_report(db, key, sid, report, only_session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT sessionKey FROM harness_pointers WHERE harnessSessionId = ?1",
        [
          sid
        ]
      )

    rows
    |> Enum.map(fn [session_key] -> session_key end)
    |> Enum.filter(&(is_nil(only_session_key) or &1 == only_session_key))
    |> Enum.each(fn session_key ->
      current? = fn txn, session ->
        Tightbeam.Gateway.adapter_key(session) == key and
          match?(
            %{harness_session_id: ^sid},
            Org.current_pointer_snapshot_in_txn(txn, session.session_key)
          )
      end

      Org.set_running_model(db, session_key, report, current?)
    end)
  end

  defp clear(db, session_key), do: Org.set_running_model(db, session_key, nil)

  defp running_sessions(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT sessionKey, harness, host FROM sessions WHERE runningModelId IS NOT NULL"
      )

    Enum.map(rows, fn [session_key, harness, host] ->
      %{session_key: session_key, harness: harness, host: host}
    end)
  end

  # A failed write must not take the writer down with it: the next report or
  # clear for that session corrects it.
  defp guarded(fun) do
    fun.()
  rescue
    error -> Logger.warning("running-model write failed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("running-model write failed: #{inspect({kind, reason})}")
  end
end
