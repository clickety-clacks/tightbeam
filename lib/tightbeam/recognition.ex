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
  CREATE TABLE pending_recognition (
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
    owner =
      case db do
        %DB.Migration{server: server} -> server
        server -> server
      end

    # The owner stamps its reader list at initialization. An empty list means
    # its private in-memory table was already created with the connection.
    in_memory? = :persistent_term.get({DB, GenServer.whereis(owner)}) == []

    case DB.transaction(db, fn txn ->
           id = "0.1.9/pending-recognition-v1"

           case Txn.q(txn, "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId=?1", [
                  id
                ]) do
             [[1]] ->
               :ok

             [] ->
               unless in_memory?, do: Txn.exec(txn, @ddl)

               Txn.q(
                 txn,
                 "INSERT INTO supervision_liveness_migrations(migrationId,appliedAt,affectedRows,cause,principal) VALUES(?1,?2,0,'release_upgrade','process:tightbeam')",
                 [id, now()]
               )

               :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def start_link(owner, ready \\ true), do: GenServer.start_link(__MODULE__, {owner, ready})

  def activate(%DB.Migration{server: db}), do: activate(db)

  def activate(db) do
    GenServer.cast(worker(db), :activate)
    :ok
  end

  defp worker(db), do: :persistent_term.get({__MODULE__, GenServer.whereis(db)}, nil)

  def record(txn, callback, result, transitions, opts) do
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
      now() +
        case txn.deadline do
          :infinity -> DB.call_timeout()
          deadline -> max(0, deadline - System.monotonic_time(:millisecond))
        end
    ])

    %Pending{id: id, result: result, transitions: transitions}
  end

  def inline(db, pending, callback, opts, deadline) do
    case invoke(db, pending, callback, true, deadline) do
      {:ok, result} ->
        if is_function(callback, 1), do: finish(db, pending.id)
        {:ok, result}

      {:error, _} ->
        if pid = worker(db), do: GenServer.cast(pid, :reschedule)
        Logger.error("post-commit recognition failed; returning committed result")
        # No failure bookkeeping is needed here: the primary commit already
        # contains the retry row, including a bounded first retry time.
        {:ok, Keyword.get(opts, :fallback, &Function.identity/1).(pending.result)}
    end
  end

  defp invoke(db, pending, callback, clear \\ true, deadline \\ nil)

  defp invoke(db, pending, callback, clear, deadline) when is_function(callback, 2) do
    safely(fn ->
      transaction = fn txn ->
        [[1]] = Txn.q(txn, "SELECT 1 FROM pending_recognition WHERE id=?1", [pending.id])
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
    delete = fn ->
      safely(fn ->
        DB.transaction(db, &Txn.q(&1, "DELETE FROM pending_recognition WHERE id=?1", [id]))
      end)
    end

    # Retry deletion once without publishing again. If both deletes fail, later
    # replay is at least once, just as after a crash following publication.
    case delete.() do
      {:ok, _} -> :ok
      {:error, _} -> delete.()
    end
  end

  @impl true
  def init({owner, ready}) do
    Process.monitor(owner)
    :persistent_term.put({__MODULE__, owner}, self())
    if ready, do: send(self(), :reschedule)
    Process.send_after(self(), :check_misses, 180_000)
    {:ok, %{db: owner, ready: ready, timer: nil, due_at: nil}}
  end

  @impl true
  def handle_cast(:activate, %{ready: false} = state) do
    {:noreply, schedule_retry(%{state | ready: true})}
  end

  def handle_cast(:activate, state), do: {:noreply, state}

  def handle_cast(:reschedule, state), do: {:noreply, schedule_retry(state)}

  @impl true
  def handle_info(:reschedule, state), do: {:noreply, schedule_retry(state)}

  def handle_info({:retry, due_at}, %{due_at: due_at} = state),
    do: handle_info(:retry, state)

  def handle_info({:retry, _}, state), do: {:noreply, state}

  def handle_info(:check_misses, state) do
    if state.ready do
      safely(fn ->
        DB.background_pass(fn ->
          case DB.query(
                 state.db,
                 "SELECT id, nextAt FROM pending_recognition WHERE flagged=0 AND nextAt<?1",
                 [now() - 60_000]
               ) do
            {:ok, rows} ->
              for [id, next_at] <- rows,
                  do: Tightbeam.SchedulerMisses.record(:recognition, id, max(0, now() - next_at))

              retry_pass(state)

            {:error, error} ->
              raise error
          end
        end)
      end)
    end

    Process.send_after(self(), :check_misses, 180_000)
    {:noreply, schedule_retry(state)}
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{db: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(:retry, state) do
    result = safely(fn -> DB.background_pass(fn -> retry_pass(state) end, :deferred) end)
    delay = if result in [:ok, nil], do: 0, else: 1_000

    if match?({:error, _}, result),
      do: Logger.error("pending recognition scan failed; retry deferred")

    {:noreply, schedule_retry(state, delay)}
  end

  defp schedule_retry(state, delay \\ 0)
  defp schedule_retry(%{ready: false} = state, _delay), do: state

  defp schedule_retry(state, delay) do
    case safely(fn ->
           DB.query(state.db, "SELECT MIN(nextAt) FROM pending_recognition WHERE flagged=0")
         end) do
      {:ok, [[due_at]]} ->
        if state.timer, do: Process.cancel_timer(state.timer)

        timer =
          if due_at, do: Process.send_after(self(), {:retry, due_at}, max(delay, due_at - now()))

        %{state | timer: timer, due_at: due_at}

      {:error, _} ->
        Process.send_after(self(), :reschedule, 1_000)
        state
    end
  end

  @impl true
  def terminate(_, %{db: db}) do
    if :persistent_term.get({__MODULE__, db}, nil) == self(),
      do: :persistent_term.erase({__MODULE__, db})
  end

  defp retry_pass(%{db: db}), do: retry_due(db, System.monotonic_time(:millisecond) + 900)

  defp retry_due(db, deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: retry_due_one(db, deadline)
  end

  defp retry_due_one(db, deadline) do
    case DB.query(
           db,
           "SELECT id,payload,attempts FROM pending_recognition WHERE flagged=0 AND nextAt<=?1 ORDER BY nextAt LIMIT 1",
           [now()]
         ) do
      {:ok, [[id, payload, attempts]]} ->
        case retry_one(db, id, payload, attempts) do
          {:error, error} -> raise error
          _ -> retry_due(db, deadline)
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
