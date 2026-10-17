defmodule Tightbeam.DBObservationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, DBObservation, Diagnostics, RequestContext, Wakes}
  alias Exqlite.Sqlite3

  setup do
    start_supervised!({Diagnostics, notify: self()})
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end
    end)

    db = start_supervised!({DB, path: ":memory:", name: nil})
    %{db: db}
  end

  test "ordinary calls retain actual 30000/5000 budgets", %{db: db} do
    Application.delete_env(:tightbeam, :db_call_timeout_ms)
    assert {:ok, [[5000]]} = DB.query(db, "PRAGMA busy_timeout")
    assert_receive {:diagnostic, %{event: "db_server_completed"} = record}
    assert record.budget_ms == 30_000
    assert record.sqlite_busy_budget_ms == 5_000
    assert record.callback_ms == nil
    assert record.result_class == "ok"
  end

  test "transaction APIs keep their raw wire tuples and recover the original callback", %{db: db} do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 30_000)
    parent = self()

    transaction_callback = fn _txn ->
      send(parent, {:callback_ran, :transaction})
      :transaction_value
    end

    deadline_callback = fn _txn ->
      send(parent, {:callback_ran, :deadline})
      :deadline_value
    end

    prepare = fn _txn ->
      send(parent, {:callback_ran, :prepare})
      :prepared
    end

    after_commit = fn _txn, result ->
      send(parent, {:callback_ran, :after_commit})
      {:recognized, result}
    end

    deadline = System.monotonic_time(:millisecond) + 4_000
    :sys.suspend(db)

    transaction_task = Task.async(fn -> DB.transaction(db, transaction_callback) end)

    deadline_task =
      Task.async(fn -> DB.transaction_until(db, deadline_callback, deadline) end)

    transaction_then_task = Task.async(fn -> DB.transaction_then(db, prepare, after_commit) end)

    try do
      messages = await_transaction_requests(db, 3, System.monotonic_time(:millisecond) + 1_000)

      requests =
        Enum.filter(messages, fn
          {:"$gen_call", _from, {:transaction, callback}} when is_function(callback, 1) ->
            true

          {:"$gen_call", _from, {:transaction_until, callback, _deadline}}
          when is_function(callback, 1) ->
            true

          {:"$gen_call", _from, {:transaction_then, prepare_callback, commit_callback}}
          when is_function(prepare_callback, 1) and is_function(commit_callback) ->
            true

          _ ->
            false
        end)

      assert length(requests) == 3

      refute Enum.any?(messages, fn
               {:"$gen_call", _from, {:db_call, _envelope, _payload}} -> true
               _ -> false
             end)

      by_operation =
        Map.new(requests, fn {:"$gen_call", _from, request} ->
          case request do
            {:transaction, wrapped} ->
              {:ok, envelope, original} = DBObservation.transaction_metadata(wrapped)
              assert original === transaction_callback
              {:transaction, envelope}

            {:transaction_until, wrapped, ^deadline} ->
              {:ok, envelope, original} = DBObservation.transaction_metadata(wrapped)
              assert original === deadline_callback
              {:transaction_until, envelope}

            {:transaction_then, wrapped, ^after_commit} ->
              {:ok, envelope, original} = DBObservation.transaction_metadata(wrapped)
              assert original === prepare
              {:transaction_then, envelope}
          end
        end)

      assert by_operation.transaction.operation == "db.transaction"
      assert by_operation.transaction.budget_ms == DB.call_timeout()
      assert by_operation.transaction.effect_kind == "write"
      assert by_operation.transaction_until.operation == "db.transaction"
      assert by_operation.transaction_until.budget_ms in 1..4_050
      assert by_operation.transaction_then.operation == "db.transaction"
      assert by_operation.transaction_then.budget_ms == DB.call_timeout()
    after
      if Process.alive?(db), do: :sys.resume(db)
    end

    assert {:ok, :transaction_value} = Task.await(transaction_task, 2_000)
    assert {:ok, :deadline_value} = Task.await(deadline_task, 2_000)

    assert {:ok, {:recognized, :prepared}} =
             Task.await(transaction_then_task, 2_000)

    for callback_name <- [:transaction, :deadline, :prepare, :after_commit] do
      assert_receive {:callback_ran, ^callback_name}, 1_000
    end

    events =
      for _ <- 1..6 do
        assert_receive {:diagnostic, %{operation: "db.transaction"} = event}, 1_000
        event
      end

    server_ids =
      for %{event: "db_server_completed", db_call_id: id} <- events, do: id

    caller_ids =
      for %{event: "db_caller_completed", db_call_id: id} <- events, do: id

    assert length(server_ids) == 3
    assert Enum.sort(server_ids) == Enum.sort(caller_ids)
    assert Enum.all?(events, &(&1.result_class == "ok"))
  end

  test "queued ordinary timeout rejects the late effect with null unobserved spans", %{db: db} do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 50)
    :sys.suspend(db)

    try do
      error =
        assert_raise DB.Timeout, fn -> DB.execute(db, "CREATE TABLE secret_sentinel (v TEXT)") end

      assert error.budget_ms == 50
      assert error.effect_state == "unknown"
      refute inspect(error) =~ "secret_sentinel"
      id = error.db_call_id
      assert_receive {:diagnostic, %{event: "db_call_abandoned", db_call_id: ^id} = abandoned}
      assert abandoned.queue_ms == nil
      assert abandoned.execute_ms == nil
      assert abandoned.callback_ms == nil
      :sys.resume(db)

      assert_receive {:diagnostic, %{event: "db_server_completed", db_call_id: ^id} = terminal},
                     1_000

      assert terminal.queue_ms >= 50
      # Expired owner work now reports its distinct deadline refusal class.
      assert terminal.result_class == "deadline_exceeded"
      assert terminal.execute_ms == nil
      assert terminal.callback_ms == nil

      assert Diagnostics.classify_db_timeout(Diagnostics.records(), id) ==
               "db_mailbox_queue_overrun"

      assert {:ok, []} =
               DB.query(db, "SELECT name FROM sqlite_master WHERE name='secret_sentinel'")

      refute inspect(Diagnostics.records()) =~ "secret_sentinel"
    after
      if Process.alive?(db), do: :sys.resume(db)
    end
  end

  test "queued explicit deadline preserves refusal and never runs the effect", %{db: db} do
    :sys.suspend(db)

    try do
      deadline = System.monotonic_time(:millisecond) + 50

      assert {:error, %DB.DeadlineExceeded{}} =
               DB.transaction_until(
                 db,
                 fn txn ->
                   DB.Txn.exec(txn, "CREATE TABLE forbidden_late_effect (v TEXT)")
                 end,
                 deadline
               )

      assert_receive {:diagnostic, %{event: "db_call_abandoned", db_call_id: id}}
      :sys.resume(db)

      assert_receive {:diagnostic, %{event: "db_server_completed", db_call_id: ^id} = terminal},
                     1_000

      assert terminal.callback_ms == nil
      assert terminal.sqlite_busy_budget_ms == nil
      # Expired owner work now reports its distinct deadline refusal class.
      assert terminal.result_class == "deadline_exceeded"
      assert terminal.cause == "deadline_exceeded"
      assert terminal.execute_ms == nil
      assert terminal.callback_sql_ms == nil
      assert terminal.callback_outside_sql_ms == nil
      assert terminal.sqlite_timeout_source == "none"
      assert is_integer(terminal.queue_ms)
      assert is_integer(terminal.total_ms)

      assert {:ok, []} =
               DB.query(db, "SELECT name FROM sqlite_master WHERE name='forbidden_late_effect'")

      assert {:ok, [[5000]]} = DB.query(db, "PRAGMA busy_timeout")
    after
      if Process.alive?(db), do: :sys.resume(db)
    end
  end

  test "explicit deadline records its resolved SQLite wait and restores ordinary budget", %{
    db: db
  } do
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:ok, [[budget]]} =
             DB.transaction_until(db, &DB.Txn.q(&1, "PRAGMA busy_timeout"), deadline)

    assert budget > 0 and budget <= 1_000
    assert_receive {:diagnostic, %{event: "db_server_completed"} = record}
    assert record.sqlite_busy_budget_ms == budget
    assert record.budget_ms <= 1_050
    assert {:ok, [[5000]]} = DB.query(db, "PRAGMA busy_timeout")
  end

  test "real reference fences retain refusal before and inside callback without false classifications",
       %{db: db} do
    assert {:ok, token, :clear} =
             DB.begin_reference_fence(db, ["coder"], fn _ -> {:ok, :clear} end)

    parent = self()

    for {label, run, callback?} <- [
          {"overlap",
           fn ->
             DB.begin_reference_fence(db, ["coder"], fn _ ->
               send(parent, :forbidden_fence_callback)
               {:ok, :never}
             end)
           end, false},
          {"transaction",
           fn ->
             DB.transaction(db, fn txn ->
               DB.Txn.assert_archetype_available!(txn, "coder")
               send(parent, :forbidden_fence_effect)
               :never
             end)
           end, true}
        ] do
      context = %{
        request_id: RequestContext.id("int_"),
        principal_kind: "internal",
        principal_ref: "internal:test"
      }

      assert {:error, %DB.ReferenceFenceError{archetypes: ["coder"]}} =
               RequestContext.bind(context, run)

      id = context.request_id
      assert_receive {:diagnostic, %{event: "db_server_completed", request_id: ^id} = record}
      assert_receive {:diagnostic, %{event: "db_caller_completed", request_id: ^id} = caller}

      for observation <- [record, caller] do
        assert observation.result_class == nil, label
        assert observation.cause == nil, label
        assert is_integer(observation.queue_ms)
        assert is_integer(observation.total_ms)
        assert observation.budget_ms == DB.call_timeout()
        assert observation.callback_sql_ms == nil

        if callback? do
          assert is_integer(observation.callback_ms)
          assert is_integer(observation.callback_outside_sql_ms)
          assert is_integer(observation.execute_ms)
        else
          assert observation.callback_ms == nil
          assert observation.callback_outside_sql_ms == nil
          assert observation.execute_ms == nil
          assert observation.sqlite_busy_budget_ms == nil
        end
      end
    end

    refute_received :forbidden_fence_callback
    refute_received :forbidden_fence_effect
    assert :ok = DB.end_reference_fence(db, token)

    assert {:ok, :available} =
             DB.transaction(db, fn txn ->
               DB.Txn.assert_archetype_available!(txn, "coder")
               :available
             end)
  end

  test "real fence check domain refusal keeps exact outcome and measured callback boundaries", %{
    db: db
  } do
    context = %{
      request_id: RequestContext.id("int_"),
      principal_kind: "internal",
      principal_ref: "internal:test"
    }

    refusal = %{code: "references_remain", private_detail: "private_domain_sentinel"}

    assert {:error, ^refusal} =
             RequestContext.bind(context, fn ->
               DB.begin_reference_fence(db, ["coder"], fn _ -> {:error, refusal} end)
             end)

    id = context.request_id
    assert_receive {:diagnostic, %{event: "db_server_completed", request_id: ^id} = record}
    assert_receive {:diagnostic, %{event: "db_caller_completed", request_id: ^id} = caller}

    for observation <- [record, caller] do
      assert observation.result_class == nil
      assert observation.cause == nil
      assert is_integer(observation.callback_ms)
      assert is_integer(observation.execute_ms)
      assert observation.callback_sql_ms == nil
      assert observation.sqlite_busy_budget_ms == 5_000
      refute inspect(observation) =~ "private_domain_sentinel"
    end

    # A refused check did not acquire the fence or damage the connection.
    assert {:ok, token, :clear} =
             DB.begin_reference_fence(db, ["coder"], fn _ -> {:ok, :clear} end)

    assert :ok = DB.end_reference_fence(db, token)
    assert {:ok, [[1]]} = DB.query(db, "SELECT 1")
  end

  test "actual Txn.exec locked refusal keeps MatchError and truthful SQLite class", %{db: db} do
    :ok = DB.execute(db, "CREATE TABLE locked_fixture (v TEXT)")
    :ok = DB.execute(db, "INSERT INTO locked_fixture VALUES ('a'), ('b')")

    context = %{
      request_id: RequestContext.id("int_"),
      principal_kind: "internal",
      principal_ref: "internal:test"
    }

    result =
      RequestContext.bind(context, fn ->
        DB.transaction(db, fn txn ->
          {:ok, cursor} = Sqlite3.prepare(txn.conn, "SELECT v FROM locked_fixture")
          {:row, _} = Sqlite3.step(txn.conn, cursor)

          try do
            DB.Txn.exec(txn, "DROP TABLE locked_fixture")
          after
            Sqlite3.release(txn.conn, cursor)
          end
        end)
      end)

    assert {:error, %MatchError{term: {:error, "database table is locked"}}} = result
    request_id = context.request_id

    assert_receive {:diagnostic,
                    %{event: "db_server_completed", request_id: ^request_id} = record}

    assert record.result_class == "sqlite_locked"
    assert record.cause == "sqlite_locked"

    assert_receive {:diagnostic,
                    %{
                      event: "db_caller_completed",
                      request_id: ^request_id,
                      result_class: "sqlite_locked",
                      cause: "sqlite_locked"
                    }}

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM locked_fixture")
  end

  @tag timeout: 20_000
  test "actual competing writer refuses BEGIN under unchanged 5000 SQLite budget", %{db: db} do
    path = Path.join(System.tmp_dir!(), "tightbeam-busy-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> File.rm!(path) end)
    # Attach a scratch database to the real memory owner; persistent gateway
    # admission remains untouched. BEGIN IMMEDIATE must lock this file too.
    :ok =
      DB.execute(db, "ATTACH DATABASE '" <> String.replace(path, "'", "''") <> "' AS competing")

    {:ok, lock} = Sqlite3.open(path)
    :ok = Sqlite3.execute(lock, "BEGIN IMMEDIATE")

    try do
      assert {:error, %MatchError{term: refusal}} =
               DB.transaction(db, fn _ -> flunk("refused BEGIN ran callback") end)

      assert refusal in [:busy, {:error, "database is locked"}]

      assert_receive {:diagnostic,
                      %{event: "db_server_completed", operation: "db.transaction"} = record}

      assert record.result_class == "sqlite_busy"
      assert record.sqlite_busy_budget_ms == 5_000
      assert record.callback_ms == nil
    after
      :ok = Sqlite3.execute(lock, "ROLLBACK")
      :ok = Sqlite3.close(lock)
    end

    assert {:ok, [[1]]} = DB.query(db, "SELECT 1")
  end

  test "callback bug and real non-lock SQLite error stay distinct", %{db: db} do
    assert {:error, %RuntimeError{}} = DB.transaction(db, fn _ -> raise "private_callback" end)
    assert_receive {:diagnostic, %{event: "db_server_completed", result_class: "callback_error"}}

    assert_receive {:diagnostic,
                    %{
                      event: "db_caller_completed",
                      result_class: "callback_error",
                      cause: "transaction_callback_error"
                    }}

    assert {:error, "no such table: database table is locked"} =
             DB.execute(db, ~s|SELECT 1 FROM "database table is locked"|)

    assert_receive {:diagnostic, %{event: "db_server_completed", result_class: "sqlite_error"}}

    assert_receive {:diagnostic,
                    %{
                      event: "db_caller_completed",
                      result_class: "sqlite_error",
                      cause: "sqlite_error"
                    }}

    refute inspect(Diagnostics.records()) =~ "private_callback"
  end

  test "inherited failed rollback preserves original result while reporting cleanup failure", %{
    db: db
  } do
    # Current .9 returns the original callback exception even when its rollback
    # fails. The caller receives its origin and secondary cause without changing
    # the transaction result, classification or reuse policy.
    parent = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result =
          DB.transaction(db, fn txn ->
            :ok = DB.Txn.exec(txn, "CREATE TABLE failed_rollback_report (id INTEGER)")
            :ok = DB.Txn.exec(txn, "ROLLBACK")
            raise "original_private_failure"
          end)

        send(parent, {:failed_rollback_result, result})
      end)

    result =
      receive do
        {:failed_rollback_result, transaction_result} -> transaction_result
      end

    assert {:error, %RuntimeError{message: "original_private_failure"} = error} = result

    diagnostic = Map.fetch!(error, :diagnostic)
    assert diagnostic["kind"] == "exception"
    assert diagnostic["operation"] == "db.transaction"
    assert diagnostic["phase"] == "callback"
    assert diagnostic["origin"] == "db_owner"
    assert diagnostic["exception"]["type"] =~ "RuntimeError"

    assert Enum.any?(diagnostic["exception"]["stacktrace"], fn frame ->
             String.contains?(frame, "db_observation_test.exs")
           end)

    assert diagnostic["cleanup"]["kind"] == "cleanup"
    assert diagnostic["cleanup"]["status"] == "unverified"
    assert diagnostic["cleanup"]["operation"] == "db.rollback"
    assert diagnostic["cleanup"]["phase"] == "rollback"
    assert diagnostic["cleanup"]["resultClass"] == "sqlite_error"
    refute log =~ "no transaction is active"
    refute log =~ "original_private_failure"

    assert_receive {:diagnostic,
                    %{event: "db_server_completed", operation: "db.transaction"} = record}

    assert record.result_class == "sqlite_error"
    assert record.cause == "sqlite_error"
    refute inspect(record) =~ "original_private_failure"

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name='failed_rollback_report'"
             )

    assert {:ok, [[1]]} = DB.query(db, "SELECT 1")
  end

  test "a failed BEGIN reports its known phase and preserves its MatchError outcome", %{db: db} do
    :ok = DB.execute(db, "BEGIN")
    parent = self()

    try do
      assert {:error, %MatchError{} = error} =
               DB.transaction(db, fn _txn ->
                 send(parent, :transaction_callback_ran)
                 :ok
               end)

      diagnostic = Map.fetch!(error, :diagnostic)
      assert diagnostic["operation"] == "db.transaction"
      assert diagnostic["phase"] == "begin"
      assert diagnostic["origin"] == "db_owner"
      refute Map.has_key?(diagnostic, "cleanup")
      refute_received :transaction_callback_ran
    after
      :ok = DB.execute(db, "ROLLBACK")
    end

    assert {:ok, [[1]]} = DB.query(db, "SELECT 1")
  end

  test "successful transactions keep their result and commit visibility", %{db: db} do
    assert {:ok, :committed} =
             DB.transaction(db, fn txn ->
               :ok = DB.Txn.exec(txn, "CREATE TABLE commit_phase_success (id INTEGER)")
               :committed
             end)

    assert_receive {:diagnostic, %{event: "db_server_completed", result_class: "ok"}}

    assert {:ok, [["commit_phase_success"]]} =
             DB.query(db, "SELECT name FROM sqlite_master WHERE name='commit_phase_success'")
  end

  test "rollback failure diagnostics redact and bound secondary error text" do
    sentinel = "synthetic-db-credential-7d33"
    raw = "authorization=#{sentinel} " <> String.duplicate("x", 9_000)

    diagnostic = DBObservation.cleanup_failure_diagnostic({:error, raw})
    rendered = inspect(diagnostic)

    assert diagnostic["kind"] == "cleanup"
    assert diagnostic["status"] == "unverified"
    assert diagnostic["resultClass"] == "sqlite_error"
    assert rendered =~ "truncated_string"
    assert rendered =~ "[REDACTED:secret_field]"
    refute rendered =~ sentinel
  end

  test "callback stall distinguishes owner execution from queue and sums SQL separately", %{
    db: db
  } do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 100)
    parent = self()

    task =
      Task.async(fn ->
        assert_raise DB.Timeout, fn ->
          DB.transaction(db, fn txn ->
            assert [[1]] = DB.Txn.q(txn, "SELECT 1")
            send(parent, {:inside_callback, self()})

            receive do
              :release_callback -> :ok
            end
          end)
        end
      end)

    assert_receive {:inside_callback, ^db}, 1_000
    failure = Task.await(task, 2_000)
    send(db, :release_callback)
    id = failure.db_call_id
    assert_receive {:diagnostic, %{event: "db_server_completed", db_call_id: ^id} = record}, 1_000
    assert record.queue_ms < 100
    assert record.callback_ms >= 100
    assert record.callback_outside_sql_ms >= 90
    assert record.execute_ms >= record.callback_sql_ms
    assert abs(record.callback_ms - record.callback_sql_ms - record.callback_outside_sql_ms) <= 1
    assert Diagnostics.classify_db_timeout(Diagnostics.records(), id) == "db_execute_overrun"
  end

  test "real wake scans correlate all calls and restore context across entries", %{db: db} do
    :ok = Tightbeam.Schema.ensure_all(db)

    scheduler =
      start_supervised!({Wakes, db: db, name: nil, tick_ms: 60_000, deliver: fn _ -> :ok end})

    assert :ok = Wakes.fire_due(scheduler)
    assert :ok = Wakes.fire_due(scheduler)
    # The scheduler replied after its synchronous DB calls. Barrier the owner,
    # then the sink: all owner records precede this response on the same sender.
    assert {:ok, [[1]]} = DB.query(db, "SELECT 1")
    records = Diagnostics.records()

    scans =
      Enum.filter(
        records,
        &(&1.event == "db_server_completed" and &1.operation == "wake.due_scan")
      )

    assert length(scans) == 2
    assert length(Enum.uniq_by(scans, & &1.request_id)) == 2

    for scan <- scans do
      assert scan.request_id =~ ~r/\Aint_[A-Za-z0-9_-]{22}\z/

      calls =
        Enum.filter(
          records,
          &(&1.event == "db_server_completed" and &1.request_id == scan.request_id)
        )

      assert length(calls) > 1
      assert length(Enum.uniq_by(calls, & &1.db_call_id)) == length(calls)
      assert Enum.all?(calls, &(&1.principal_ref == "internal:wake_scheduler"))
    end

    {:dictionary, dictionary} = Process.info(scheduler, :dictionary)
    refute List.keymember?(dictionary, {RequestContext, :current}, 0)
  end

  defp await_transaction_requests(db, expected, deadline) do
    case Process.info(db, :messages) do
      {:messages, messages} ->
        count = Enum.count(messages, &transaction_request?/1)

        cond do
          count >= expected ->
            messages

          System.monotonic_time(:millisecond) >= deadline ->
            flunk("expected #{expected} raw transaction requests, observed #{count}")

          true ->
            Process.sleep(2)
            await_transaction_requests(db, expected, deadline)
        end

      nil ->
        flunk("DB owner exited before transaction requests were queued")
    end
  end

  defp transaction_request?({:"$gen_call", _from, {:transaction, callback}}),
    do: is_function(callback, 1)

  defp transaction_request?({:"$gen_call", _from, {:transaction_until, callback, _deadline}}),
    do: is_function(callback, 1)

  defp transaction_request?({:"$gen_call", _from, {:transaction_then, prepare, after_commit}}),
    do: is_function(prepare, 1) and is_function(after_commit)

  defp transaction_request?(_), do: false
end
