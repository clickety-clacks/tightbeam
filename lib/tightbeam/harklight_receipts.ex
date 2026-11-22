defmodule Tightbeam.HarklightReceipts do
  @moduledoc false

  use GenServer

  alias Tightbeam.{DB, HarklightFailures, Id}
  alias Tightbeam.DB.Txn

  @retry_delay 5_000

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS harklight_handoff_receipts (
      wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
      turnSeq INTEGER NOT NULL REFERENCES turns(seq),
      argv TEXT NOT NULL,
      opId TEXT NOT NULL UNIQUE,
      journalId TEXT,
      completedAt INTEGER
    );
    CREATE INDEX IF NOT EXISTS harklight_handoff_receipts_pending
      ON harklight_handoff_receipts(turnSeq,wakeId) WHERE completedAt IS NULL;
    """)
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def dispatched(turn_seq) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:dispatched, turn_seq})
    :ok
  end

  @impl true
  def init(opts) do
    send(self(), :drain)

    {:ok,
     %{
       db: Keyword.fetch!(opts, :db),
       opts: opts,
       turns: :all,
       task: nil,
       timer: nil
     }}
  end

  @impl true
  def handle_cast({:dispatched, turn_seq}, state) do
    state = %{state | turns: add_turn(state.turns, turn_seq)}
    {:noreply, start_drain(state)}
  end

  @impl true
  def handle_info(:drain, state), do: {:noreply, start_drain(%{state | timer: nil})}

  def handle_info({ref, {lookup, outstanding}}, %{task: {%Task{ref: ref}, turns}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    state =
      if lookup == :ok, do: state, else: %{state | turns: merge_turns(turns, state.turns)}

    state =
      if outstanding or lookup != :ok do
        delay = Keyword.get(state.opts, :retry_delay, @retry_delay)
        %{state | timer: Process.send_after(self(), :drain, delay)}
      else
        if MapSet.size(state.turns) > 0, do: start_drain(state), else: state
      end

    {:noreply, state}
  end

  defp add_turn(:all, _seq), do: :all
  defp add_turn(turns, seq), do: MapSet.put(turns, seq)

  defp merge_turns(:all, _turns), do: :all
  defp merge_turns(first, second), do: MapSet.union(first, second)

  defp start_drain(%{task: nil, timer: nil} = state) do
    %{db: db, opts: opts, turns: turns} = state
    task = Task.async(fn -> drain(db, turns, opts) end)
    %{state | task: {task, turns}, turns: MapSet.new()}
  end

  defp start_drain(state), do: state

  # The durable dispatch event is the source of owed receipts. Discovery on
  # startup also covers a crash before the in-memory dispatch notification.
  def drain(db, turns, opts \\ []) do
    case discover(db, turns) do
      :ok -> {:ok, process_pending(db, opts)}
      {:error, _reason} -> {:deferred, true}
    end
  end

  defp discover(db, :all), do: discover_turns(db, "IS NOT NULL", [])

  defp discover(db, turns) do
    Enum.reduce_while(turns, :ok, fn seq, :ok ->
      case discover_turns(db, "=?1", [seq]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Health recovery carries the original prompt into a new turn without a
  # wake. Use the source turn to find the wakes and the replacement to prove
  # dispatch and attribute the receipt.
  defp discover_turns(db, selector, params) do
    case DB.transaction(db, fn txn ->
           rows =
             Txn.q(
               txn,
               """
               WITH delivered_wakes(wakeId,turnSeq) AS (
                 SELECT w.wakeId,w.deliveredTurnSeq
                 FROM wakes w WHERE w.deliveredTurnSeq #{selector}

                 UNION ALL

                 SELECT w.wakeId,replacement.seq
                 FROM health_redelivery_attempts attempt
                 JOIN turns replacement
                   ON (replacement.seq=attempt.redeliveryTurnSeq OR
                       replacement.seq=attempt.cycleReleaseTurnSeq)
                   AND replacement.sessionKey=attempt.sessionKey
                   AND replacement.messageId=attempt.sourceMessageId
                 JOIN turns source
                   ON source.seq=attempt.sourceTurnSeq
                   AND source.sessionKey=attempt.sessionKey
                   AND source.messageId=attempt.sourceMessageId
                 JOIN wakes w ON w.deliveredTurnSeq=source.seq
                 WHERE replacement.seq #{selector}
               )
               SELECT DISTINCT d.wakeId,t.seq,e.rawLine,h.sessionKey,t.sessionKey,
                 COALESCE(json_extract(event.detail,'$.harklight_receipt_agent'),s.displayName)
               FROM delivered_wakes w
               JOIN turns t ON t.seq=w.turnSeq
               JOIN sessions s ON s.sessionKey=t.sessionKey
               JOIN turn_lifecycle_events event ON event.turnSeq=t.seq AND event.kind='prompt_dispatched'
               LEFT JOIN wake_retry_attempts retry ON retry.wakeId=w.wakeId
               JOIN harklight_wake_deliveries d ON d.wakeId=COALESCE(retry.rootWakeId,w.wakeId)
               JOIN harklight_wake_entries e ON e.handle=d.handle AND e.eventId=d.eventId
               JOIN harklight_wake_handles h ON h.handle=e.handle
               LEFT JOIN harklight_handoff_receipts receipt ON receipt.wakeId=d.wakeId
               WHERE receipt.wakeId IS NULL
                 AND e.entryKind IN ('discussion','terminal') AND e.entryAuthor='person'
                 AND json_extract(e.rawLine,'$.kind') IN ('entry','message')
               ORDER BY t.seq,e.feedCursor,d.wakeId
               """,
               params
             )

           Enum.each(rows, fn [wake, turn, line, owner, receiver, name] ->
             with {:ok, args} <- receipt_target(line) do
               args = args ++ ["--agent", name]
               args = if owner == receiver, do: args, else: args ++ ["--rerouted"]

               Txn.q(
                 txn,
                 """
                 INSERT INTO harklight_handoff_receipts(wakeId,turnSeq,argv,opId)
                 VALUES(?1,?2,?3,?4) ON CONFLICT(wakeId) DO NOTHING
                 """,
                 [wake, turn, JSON.encode!(args), Id.uuid4()]
               )
             end
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc false
  def receipt_target(line) do
    case JSON.decode(line) do
      {:ok, %{"kind" => "entry", "item_id" => item, "data" => %{"entry_id" => entry}}}
      when is_binary(item) and is_binary(entry) ->
        {:ok, ["receipt", "--item-id", item, "--entry-id", entry]}

      {:ok,
       %{
         "kind" => "message",
         "item_id" => item,
         "data" => %{"terminal" => %{"state" => "answered"}}
       }}
      when is_binary(item) ->
        {:ok, ["receipt", "--item-id", item]}

      _ ->
        :error
    end
  end

  defp process_pending(db, opts) do
    case DB.query(
           db,
           """
           SELECT argv,opId,journalId FROM harklight_handoff_receipts r
           WHERE r.completedAt IS NULL
             AND NOT EXISTS (SELECT 1 FROM harklight_operation_pauses p WHERE p.opId=r.opId)
             AND NOT EXISTS (SELECT 1 FROM harklight_operation_guards g WHERE g.opId=r.opId)
           ORDER BY r.turnSeq,r.wakeId
           """
         ) do
      {:ok, rows} ->
        Enum.reduce(rows, false, fn [argv, op, journal], pending ->
          result = process_receipt(db, opts, JSON.decode!(argv), op, journal)
          pending or result not in [:ok, :paused, :guarded]
        end)

      {:error, _reason} ->
        true
    end
  end

  def settle_paused(db, session_key, op, opts) do
    :global.trans({{__MODULE__, db, op}, self()}, fn ->
      case DB.query(
             db,
             """
             SELECT r.argv,r.journalId,p.diagnostic FROM harklight_handoff_receipts r
             LEFT JOIN harklight_operation_pauses p ON p.opId=r.opId
             LEFT JOIN harklight_operation_guards g ON g.opId=r.opId
             JOIN turns t ON t.seq=r.turnSeq
             WHERE r.opId=?1 AND t.sessionKey=?2 AND r.completedAt IS NULL
               AND (p.opId IS NOT NULL OR g.opId IS NOT NULL)
             """,
             [op, session_key]
           ) do
        {:ok, [[argv, journal, diagnostic]]} ->
          with {:ok, runner} <- runner(opts),
               {:ok, result} <-
                 HarklightFailures.guarded_attempt(db, op, :explicit, fn ->
                   recover_receipt(runner, JSON.decode!(argv), op, journal)
                 end),
               :ok <- settle_exact_receipt(db, op, result) do
            :ok
          else
            {pause, reason} when pause in [:paused, :pause_unrecorded] -> {:error, reason}
            _ -> {:error, diagnostic || HarklightFailures.guard_diagnostic(op)}
          end

        {:ok, []} ->
          :unknown

        {:error, _reason} ->
          {:error, "Tightbeam could not read the saved Harklight operation."}
      end
    end)
  end

  @doc false
  def acknowledge(db, wake, turn, opts) do
    case receipt_for_ack(db, wake) do
      {:ok, []} ->
        # The prompt is already dispatched. The receipt worker may not have
        # discovered this turn yet. Discover its rows before settling this wake.
        with :ok <- discover_turns(db, "=?1", [turn]) do
          acknowledge_receipt(db, opts, receipt_for_ack(db, wake))
        else
          _ -> acknowledge_receipt(db, opts, :unavailable)
        end

      row ->
        acknowledge_receipt(db, opts, row)
    end
  end

  defp receipt_for_ack(db, wake) do
    DB.query(
      db,
      "SELECT argv,opId,journalId,completedAt FROM harklight_handoff_receipts WHERE wakeId=?1",
      [wake]
    )
  end

  defp acknowledge_receipt(_db, _opts, {:ok, [[_argv, _op, _journal, completed]]})
       when is_integer(completed),
       do: :ok

  defp acknowledge_receipt(db, opts, {:ok, [[argv, op, journal, nil]]}) do
    case process_receipt(db, opts, JSON.decode!(argv), op, journal, :explicit) do
      :ok ->
        :ok

      {pause, reason} when pause in [:paused, :pause_unrecorded] ->
        {:error, reason}

      _ ->
        {:error,
         "Harklight has not confirmed this handoff. Retry acknowledgment for the same event."}
    end
  end

  defp acknowledge_receipt(_db, _opts, _row),
    do:
      {:error,
       "The dispatch receipt is not available yet. Retry acknowledgment for the same event."}

  defp process_receipt(db, opts, argv, op, journal, mode \\ :automatic) do
    :global.trans({{__MODULE__, db, op}, self()}, fn ->
      with {:ok, runner} <- runner(opts),
           {:ok, journal} <- bind_journal(db, runner, op, journal),
           {:ok, result} <-
             HarklightFailures.guarded_attempt(db, op, mode, fn ->
               recover_receipt(runner, argv, op, journal)
             end) do
        if mode == :explicit,
          do: settle_exact_receipt(db, op, result),
          else: settle_result(db, op, result)
      else
        {:error, "harklight_recovery_held"} -> :guarded
        error -> error
      end
    end)
  end

  defp recover_receipt(runner, argv, op, journal) when is_binary(journal) and journal != "" do
    case run_operation(runner, ["retry", "--op-id", op, "--journal-id", journal], op) do
      {[%{"kind" => "operation_absent", "op_id" => ^op, "journal_id" => ^journal}], 1} ->
        run_operation(runner, argv ++ ["--op-id", op], op)

      result ->
        result
    end
  end

  defp recover_receipt(_runner, _argv, _op, _journal), do: {:error, :pending}

  defp bind_journal(_db, _runner, _op, id) when is_binary(id), do: {:ok, id}

  defp bind_journal(db, runner, op, nil) do
    case run(runner, ["journal-id"]) do
      {[%{"kind" => "journal", "journal_id" => id}], 0} when is_binary(id) and id != "" ->
        case DB.query(
               db,
               "UPDATE harklight_handoff_receipts SET journalId=?2 WHERE opId=?1 AND journalId IS NULL RETURNING journalId",
               [op, id]
             ) do
          {:ok, [[^id]]} -> {:ok, id}
          _ -> {:error, :pending}
        end

      _ ->
        {:error, :pending}
    end
  end

  defp settle_result(db, op, result) do
    case settle_exact_receipt(db, op, result) do
      {:paused, _diagnostic} -> :paused
      {:pause_unrecorded, _diagnostic} -> :guarded
      {:error, :pending} -> retry_refused_receipt(db, op, result)
      other -> other
    end
  end

  defp settle_exact_receipt(
         db,
         op,
         {[
            %{
              "kind" => "committed",
              "operation" => "receipt",
              "op_id" => op,
              "response" => %{"status" => status}
            }
          ], 0}
       )
       when status in ["recorded", "already_recorded", "superseded"] do
    persist(db, "UPDATE harklight_handoff_receipts SET completedAt=?2 WHERE opId=?1", [
      op,
      System.system_time(:millisecond)
    ])
  end

  defp settle_exact_receipt(db, op, {:internal_error, operation, request_id}) do
    HarklightFailures.hold_operation(db, operation, op, request_id)
  end

  defp settle_exact_receipt(_db, _op, _result), do: {:error, :pending}

  defp retry_refused_receipt(
         db,
         op,
         {[%{"kind" => "refused", "operation" => "receipt", "op_id" => op}], exit}
       )
       when exit in [2, 5] do
    # A definite rejection did not record handoff. Only then may a later
    # attempt use a new key. Unknown outcomes keep both the key and journal.
    persist(
      db,
      """
      UPDATE harklight_handoff_receipts SET opId=?2, journalId=NULL WHERE opId=?1
      """,
      [op, Id.uuid4()]
    )

    {:error, :pending}
  end

  defp retry_refused_receipt(_db, _op, _result), do: {:error, :pending}

  defp persist(db, sql, params) do
    with {:ok, _} <- DB.query(db, sql, params), do: :ok
  end

  defp runner(opts) do
    case Keyword.get(opts, :runner) do
      runner when is_function(runner, 1) ->
        {:ok, runner}

      nil ->
        case System.find_executable("harklight-agent") do
          nil -> {:error, :pending}
          exe -> {:ok, fn argv -> System.cmd(exe, argv, stderr_to_stdout: true) end}
        end
    end
  end

  defp run_operation(runner, argv, op) do
    case run(runner, argv) do
      {frames, status} = result ->
        HarklightFailures.write_error(frames, status, op, ["receipt"]) || result

      error ->
        error
    end
  end

  defp run(runner, argv) do
    {output, status} = runner.(argv)

    frames =
      for line <- String.split(output, "\n", trim: true),
          {:ok, %{"kind" => _} = frame} <- [JSON.decode(line)],
          do: frame

    {frames, status}
  rescue
    _ -> {:error, :pending}
  catch
    _, _ -> {:error, :pending}
  end
end
