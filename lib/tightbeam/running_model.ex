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

  A write or clear that fails is kept and retried on a short, bounded backoff
  until it lands, so a value is never left standing because one attempt failed.

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

  @retry_cap_ms 5_000

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
  # coordinator only after it: a clear can never erase a fresh report. The writer
  # is owed work, so database overload is waited out; a real failure raises here,
  # because startup cannot go on with a value that may be stale.
  @impl true
  def init(opts) do
    DB.owed_work()

    state = %{
      db: Keyword.get(opts, :db, DB),
      coordinator: Keyword.get(opts, :coordinator, AdapterCoordinator),
      set: Keyword.get(opts, :set_running_model, &Org.set_running_model/4),
      retry_ms: Keyword.get(opts, :retry_ms, 100),
      # The latest report per adapter and harness session id.
      pending: %{},
      # Work that failed and will be tried again: `{key, sid} => report` for
      # reports, `key => loss sequence` for adapter losses.
      retry_reports: %{},
      lost: %{},
      attempts: %{},
      # The writer's own order of events. `written` is the sequence at which a
      # session last had a report stored, so a retried clear never erases a value
      # that arrived after the loss it is clearing.
      seq: 0,
      written: %{}
    }

    state.db |> running_sessions() |> Enum.each(&clear(state, &1.session_key))
    {:ok, state, {:continue, :resync}}
  end

  @impl true
  def handle_continue(:resync, state) do
    AdapterCoordinator.request_running_model_reports(state.coordinator)
    {:noreply, state}
  end

  # `pending` lets a report that arrives before the gateway records its pointer
  # (a harness reports a new session's model first) apply when the pointer lands,
  # and lets a new pointer pick up a report already held. It is replaced by the
  # next report, dropped on unload (a nil report) and with its adapter.
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

        state = %{state | pending: pending, seq: state.seq + 1}
        {:noreply, deliver(state, key, sid, report, nil)}
    end
  end

  def handle_cast({:pointer_recorded, session_key, sid}, state) do
    state =
      Enum.reduce(state.pending, state, fn
        {{key, ^sid}, {_generation, report}}, state ->
          deliver(%{state | seq: state.seq + 1}, key, sid, report, session_key)

        _other, state ->
          state
      end)

    {:noreply, state}
  end

  def handle_cast({:adapter_gone, key}, state) do
    state = %{state | seq: state.seq + 1}

    state = %{
      state
      | pending: Map.reject(state.pending, fn {{k, _sid}, _} -> k == key end),
        retry_reports: Map.reject(state.retry_reports, fn {{k, _sid}, _} -> k == key end)
    }

    {:noreply, clear_lost(state, key, state.seq)}
  end

  @impl true
  def handle_info({:retry_report, key, sid}, state) do
    # A nil report (an unload or refusal) is real work to retry, so ask for the key.
    case Map.fetch(state.retry_reports, {key, sid}) do
      :error -> {:noreply, state}
      {:ok, report} -> {:noreply, deliver(state, key, sid, report, nil)}
    end
  end

  def handle_info({:retry_loss, key}, state) do
    case state.lost[key] do
      nil -> {:noreply, state}
      loss_seq -> {:noreply, clear_lost(state, key, loss_seq)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Store a report. Success settles it; a failure keeps the latest report for this
  # session id and tries again, since an idle session may never report again.
  defp deliver(state, key, sid, report, only_session_key) do
    case apply_report(state, key, sid, report, only_session_key) do
      {:ok, outcomes} ->
        # Only a report that was stored or confirmed counts as newer than a loss;
        # one dropped as stale left the old value standing.
        stored =
          for {session_key, outcome} <- outcomes,
              outcome in [:changed, :unchanged],
              do: session_key

        written =
          if report,
            do: Enum.reduce(stored, state.written, &Map.put(&2, &1, state.seq)),
            else: state.written

        %{
          state
          | written: written,
            retry_reports: Map.delete(state.retry_reports, {key, sid}),
            attempts: Map.delete(state.attempts, {:report, key, sid})
        }

      :error ->
        state = %{state | retry_reports: Map.put(state.retry_reports, {key, sid}, report)}
        schedule(state, {:report, key, sid}, {:retry_report, key, sid})
    end
  end

  # Clear what an adapter's loss left behind, but only values older than the loss:
  # one stored since by a newer adapter is a valid report and stays.
  defp clear_lost(state, key, loss_seq) do
    result =
      try do
        state.db
        |> running_sessions()
        |> Enum.filter(&(Tightbeam.Gateway.adapter_key(&1) == key))
        |> Enum.filter(&(Map.get(state.written, &1.session_key, 0) <= loss_seq))
        |> Enum.map(&clear_ok?(state, &1.session_key))
        |> Enum.all?()
      rescue
        error -> log_failure(error) && false
      catch
        kind, reason -> log_failure({kind, reason}) && false
      end

    if result do
      %{
        state
        | lost: Map.delete(state.lost, key),
          attempts: Map.delete(state.attempts, {:loss, key})
      }
    else
      state = %{state | lost: Map.put(state.lost, key, loss_seq)}
      schedule(state, {:loss, key}, {:retry_loss, key})
    end
  end

  # Retries back off from `retry_ms` up to a few seconds and continue until the
  # work lands: the value is cleared or stored, never left stale.
  defp schedule(state, attempt_key, message) do
    attempt = Map.get(state.attempts, attempt_key, 0)

    Process.send_after(
      self(),
      message,
      min(state.retry_ms * Integer.pow(2, min(attempt, 10)), @retry_cap_ms)
    )

    %{state | attempts: Map.put(state.attempts, attempt_key, attempt + 1)}
  end

  defp apply_report(state, key, sid, report, only_session_key) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT DISTINCT sessionKey FROM harness_pointers WHERE harnessSessionId = ?1",
        [sid]
      )

    session_keys =
      rows
      |> Enum.map(fn [session_key] -> session_key end)
      |> Enum.filter(&(is_nil(only_session_key) or &1 == only_session_key))

    outcomes =
      Enum.map(session_keys, fn session_key ->
        current? = fn txn, session ->
          Tightbeam.Gateway.adapter_key(session) == key and
            match?(
              %{harness_session_id: ^sid},
              Org.current_pointer_snapshot_in_txn(txn, session.session_key)
            )
        end

        {session_key, state.set.(state.db, session_key, report, current?)}
      end)

    {:ok, outcomes}
  rescue
    error -> log_failure(error) && :error
  catch
    kind, reason -> log_failure({kind, reason}) && :error
  end

  defp clear(state, session_key), do: state.set.(state.db, session_key, nil, fn _, _ -> true end)

  defp clear_ok?(state, session_key) do
    clear(state, session_key)
    true
  rescue
    error -> log_failure(error) && false
  end

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

  defp log_failure(error) do
    Logger.warning("running-model write failed, will retry: #{inspect(error)}")
    true
  end
end
