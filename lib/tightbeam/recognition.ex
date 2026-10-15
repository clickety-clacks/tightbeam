defmodule Tightbeam.Recognition do
  @moduledoc false
  use GenServer
  require Logger
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  defmodule Pending do
    @moduledoc false
    defstruct [:id, :result, :transitions]
  end

  # Callback terms are Erlang external terms, valid for the exact module build
  # that wrote them. An incompatible upgrade is flagged, never guessed at.
  @ddl """
  CREATE TABLE IF NOT EXISTS pending_recognition (
    id TEXT PRIMARY KEY,
    version INTEGER NOT NULL CHECK(version = 1),
    payload BLOB NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    nextAt INTEGER NOT NULL,
    flagged INTEGER NOT NULL DEFAULT 0 CHECK(flagged IN (0,1))
  )
  """
  @max_attempts 5

  def ensure_sqlite_schema(conn), do: Exqlite.Sqlite3.execute(conn, @ddl)

  def ensure_schema(db) do
    :ok = DB.execute(db, @ddl)

    case DB.query(db, "SELECT version FROM pending_recognition WHERE version<>1 LIMIT 1") do
      {:ok, []} ->
        :ok

      {:ok, [[version]]} ->
        raise DB.Error, message: "unknown pending recognition version #{inspect(version)}"

      {:error, error} ->
        raise error
    end
  end

  def start_link(owner, ready \\ true), do: GenServer.start_link(__MODULE__, {owner, ready})

  def activate(%DB.Migration{server: db}), do: activate(db)

  def activate(db) do
    GenServer.cast(worker(db), :activate)
    :ok
  end

  defp worker(db), do: :persistent_term.get({__MODULE__, GenServer.whereis(db)}, nil)

  def record(txn, callback, result, transitions, opts, caller) do
    id = Tightbeam.Id.uuid4()
    module = callback |> :erlang.fun_info(:module) |> elem(1)

    payload =
      :erlang.term_to_binary(
        {module, module.module_info(:md5), callback, result, transitions,
         Keyword.get(opts, :retry_deliveries, false)}
      )

    Txn.q(txn, "INSERT INTO pending_recognition(id,version,payload,nextAt) VALUES(?1,1,?2,?3)", [
      id,
      {:blob, payload},
      now() + 1_000
    ])

    Txn.handoff(txn, worker(self()), {:active, id, caller})
    %Pending{id: id, result: result, transitions: transitions}
  end

  def inline(db, pending, callback, opts, deadline) do
    try do
      case invoke(db, pending, callback, true, deadline) do
        {:ok, result} ->
          if is_function(callback, 1), do: finish(db, pending.id)
          {:ok, result}

        {:error, _} ->
          Logger.error("post-commit recognition failed; returning committed result")
          # No failure bookkeeping is needed here: the primary commit already
          # contains the retry row, including a bounded first retry time.
          {:ok, Keyword.get(opts, :fallback, &Function.identity/1).(pending.result)}
      end
    after
      if retry = worker(db), do: GenServer.cast(retry, {:release, pending.id})
    end
  end

  defp invoke(db, pending, callback, clear \\ true, deadline \\ nil)

  defp invoke(db, pending, callback, clear, deadline) when is_function(callback, 2) do
    safely(fn ->
      transaction = fn txn ->
        Enum.each(pending.transitions, &DB.record_row_commit(txn, &1))
        result = recognized_result!(call_callback!(callback, txn, pending.result), pending.result)
        # Clear the durable intent atomically with recognition's changes.
        if clear, do: Txn.q(txn, "DELETE FROM pending_recognition WHERE id=?1", [pending.id])
        result
      end

      if deadline,
        do: DB.transaction_until(db, transaction, deadline),
        else: DB.transaction(db, transaction)
    end)
  end

  defp invoke(_db, pending, callback, _clear, _deadline) when is_function(callback, 1),
    do: safely(fn -> {:ok, recognized_result!(callback.(pending.result), pending.result)} end)

  defp call_callback!(callback, txn, result) do
    callback.(txn, result)
  catch
    kind, _reason when kind in [:throw, :exit] ->
      raise DB.Error, message: "recognition callback #{kind}"
  end

  defp recognized_result!({:error, _} = error, original) when error != original,
    do: raise(DB.Error, message: "recognition returned an error")

  defp recognized_result!(result, _original), do: result

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp finish(db, id) do
    # Arity-two deletes in its own commit. Arity-one is at-least-once across a
    # process crash between publication and deletion, as any external outbox is.
    safely(fn ->
      DB.transaction(db, &Txn.q(&1, "DELETE FROM pending_recognition WHERE id=?1", [id]))
    end)

    :ok
  end

  @impl true
  def init({owner, ready}) do
    Process.monitor(owner)
    :persistent_term.put({__MODULE__, owner}, self())
    if ready, do: Process.send_after(self(), :retry, 1_000)
    {:ok, %{db: owner, ready: ready, active: %{}}}
  end

  @impl true
  def handle_cast(:activate, %{ready: false} = state) do
    Process.send_after(self(), :retry, 1_000)
    {:noreply, %{state | ready: true}}
  end

  def handle_cast(:activate, state), do: {:noreply, state}

  def handle_cast({:active, id, caller}, state) do
    {:noreply, %{state | active: Map.put(state.active, id, Process.monitor(caller))}}
  end

  def handle_cast({:release, id}, state) do
    if monitor = state.active[id], do: Process.demonitor(monitor, [:flush])
    {:noreply, %{state | active: Map.delete(state.active, id)}}
  end

  @impl true
  def handle_info({:DOWN, _, :process, owner, _}, %{db: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _, _}, state),
    do: {:noreply, %{state | active: Map.reject(state.active, fn {_, ref} -> ref == monitor end)}}

  def handle_info(:retry, state) do
    case safely(fn -> DB.background_pass(fn -> retry_pass(state) end) end) do
      {:error, _} -> Logger.error("pending recognition scan failed; retrying next tick")
      _ -> :ok
    end

    Process.send_after(self(), :retry, 1_000)
    {:noreply, state}
  end

  @impl true
  def terminate(_, %{db: db}) do
    if :persistent_term.get({__MODULE__, db}, nil) == self(),
      do: :persistent_term.erase({__MODULE__, db})
  end

  defp retry_pass(%{db: db, active: active}) do
    case DB.query(
           db,
           "SELECT id,payload,attempts FROM pending_recognition WHERE flagged=0 AND nextAt<=?1 ORDER BY nextAt LIMIT 1",
           [now()]
         ) do
      {:ok, [[id, payload, attempts]]} ->
        if Map.has_key?(active, id) do
          DB.transaction(
            db,
            &Txn.q(&1, "UPDATE pending_recognition SET nextAt=?2 WHERE id=?1", [id, now() + 1_000])
          )
        else
          retry_one(db, id, payload, attempts)
        end

      {:ok, []} ->
        :ok

      {:error, error} ->
        raise error
    end
  end

  defp retry_one(db, id, payload, attempts) do
    outcome =
      safely(fn ->
        {module, md5, callback, result, transitions, deliveries?} =
          :erlang.binary_to_term(payload)

        if module.module_info(:md5) != md5, do: raise("recognition callback build changed")

        case retry_invoke(
               db,
               %Pending{id: id, result: result, transitions: transitions},
               callback,
               deliveries?
             ) do
          {:ok, recognized} = success ->
            if deliveries?,
              do: Tightbeam.ConditionFacts.complete_deliveries(db, elem(recognized, 1))

            success

          error ->
            error
        end
      end)

    case outcome do
      {:ok, _result} ->
        finish(db, id)

      {:error, %DB.Overloaded{} = error} ->
        raise error

      {:error, _} ->
        attempts = attempts + 1
        flagged = if attempts >= @max_attempts, do: 1, else: 0
        Logger.error("pending recognition failed; attempt=#{attempts} flagged=#{flagged}")

        DB.transaction(db, fn txn ->
          Txn.q(
            txn,
            "UPDATE pending_recognition SET attempts=?2,nextAt=?3,flagged=?4 WHERE id=?1",
            [id, attempts, now() + trunc(:math.pow(2, attempts - 1)) * 1_000, flagged]
          )
        end)
    end
  end

  defp retry_invoke(db, pending, callback, deliveries?) when is_function(callback, 2),
    do: invoke(db, pending, callback, not deliveries?)

  defp retry_invoke(db, pending, callback, _deliveries?) do
    task = Task.async(fn -> invoke(db, pending, callback) end)

    case Task.yield(task, DB.call_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, %DB.DeadlineExceeded{}}
    end
  end

  defp now, do: System.system_time(:millisecond)
end
