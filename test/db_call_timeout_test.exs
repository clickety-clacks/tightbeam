defmodule Tightbeam.DBCallTimeoutTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{DB, Gateway}

  # The suspended owner answers nothing, so every call below waits out its own
  # timeout rather than racing real work. The elapsed bounds are deliberately
  # far above the timeout under test and far below the wait the test would see
  # if the wrong number won: each one falsifies a specific alternative, and load
  # cannot close the gap.
  @elapsed_bound_ms 10_000

  setup do
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end
    end)

    :ok
  end

  defp suspended_db do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :sys.suspend(db)
    on_exit(fn -> if Process.alive?(db), do: :sys.resume(db) end)
    db
  end

  defp elapsed_ms(fun) do
    {micros, result} = :timer.tc(fun)
    {div(micros, 1000), result}
  end

  test "an unconfigured call timeout is 30s" do
    Application.delete_env(:tightbeam, :db_call_timeout_ms)

    assert DB.call_timeout() == 30_000
  end

  test "a configured call timeout is used as given" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 1_234)

    assert DB.call_timeout() == 1_234
  end

  test "validation rejects anything that is not a positive integer" do
    for bad <- [0, -1, 5.0, "30000", :infinity, nil] do
      Application.put_env(:tightbeam, :db_call_timeout_ms, bad)

      error = assert_raise(ArgumentError, fn -> DB.validate_call_timeout!() end)

      assert error.message =~ ":db_call_timeout_ms"
      assert error.message =~ inspect(bad)
    end
  end

  test "a bad call timeout stops the DB owner starting" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 0)
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               DB.start_link(path: ":memory:", name: nil)

      assert message =~ ":db_call_timeout_ms"
    end)
  end

  test "an expired deadline is refused without waiting on the owner" do
    db = suspended_db()
    deadline = System.monotonic_time(:millisecond) - 1

    {elapsed, result} = elapsed_ms(fn -> DB.query_until(db, "SELECT 1", [], deadline) end)

    assert {:error, %DB.DeadlineExceeded{}} = result
    assert elapsed < @elapsed_bound_ms
  end

  test "an enclosing deadline shortens the configured call timeout" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 30_000)
    db = suspended_db()
    deadline = System.monotonic_time(:millisecond) + 150

    {elapsed, result} = elapsed_ms(fn -> DB.query_until(db, "SELECT 1", [], deadline) end)

    assert {:error, %DB.DeadlineExceeded{}} = result
    assert elapsed < @elapsed_bound_ms
  end

  test "the configured call timeout caps a distant deadline" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 100)
    db = suspended_db()
    deadline = System.monotonic_time(:millisecond) + 60_000

    {elapsed, result} = elapsed_ms(fn -> DB.query_until(db, "SELECT 1", [], deadline) end)

    assert {:error, %DB.DeadlineExceeded{}} = result
    assert elapsed < @elapsed_bound_ms
  end

  test "a live owner answers a deadline-bounded query normally" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    deadline = System.monotonic_time(:millisecond) + 30_000

    assert {:ok, [[1]]} = DB.query_until(db, "SELECT 1", [], deadline)
  end

  test "migration context covers query, DDL, transaction and guard calls without changing runtime bounds" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 20)
    db = start_supervised!({DB, path: ":memory:", name: nil})
    migration = DB.migration_context(db)

    for {operation, expected} <- [
          {fn -> DB.query(migration, "SELECT 1") end, {:ok, [[1]]}},
          {fn -> DB.execute(migration, "CREATE TABLE context_fixture(id INTEGER)") end, :ok},
          {fn -> DB.transaction(migration, fn _ -> :done end) end, {:ok, :done}},
          {fn -> DB.prepare_schema(migration) end, :ok},
          {fn -> DB.finish_schema(migration) end, :ok}
        ] do
      :sys.suspend(db)
      caller = Task.async(operation)
      # Synchronize on a call actually queued to the suspended owner before
      # timing the release; this is an injected queue delay, not migration work.
      await_queued_call(db)
      Process.send_after(self(), :resume_owner, 80)
      receive do: (:resume_owner -> :sys.resume(db))
      assert Task.await(caller) == expected
      assert DB.call_timeout() == 20
    end

    :sys.suspend(db)

    try do
      error = assert_raise(DB.Timeout, fn -> DB.query(db, "SELECT 1") end)

      assert error.operation == "db.query"
      assert error.budget_ms == 20
    after
      :sys.resume(db)
    end
  end

  test "a slow migration stays alive and reports progress before it finishes" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 20)
    db = start_supervised!({DB, path: ":memory:", name: nil})
    caller = self()
    gate = make_ref()
    filter_id = :"migration_progress_#{System.unique_integer([:positive])}"
    progress = "database startup call migration_transaction: still waiting"

    # Observe the real caller's progress log before releasing the migration.
    # A fixed callback sleep races the caller entering its five-second wait:
    # scheduler delay after send_request can consume any fixed margin.
    :ok =
      :logger.add_primary_filter(
        filter_id,
        {fn event, _ ->
           case event do
             %{meta: %{pid: ^caller}, msg: {:string, message}} ->
               if String.starts_with?(IO.iodata_to_binary(message), progress) do
                 send(caller, {:migration_progress, gate, System.monotonic_time(:millisecond)})
                 send(db, {:finish_migration, gate})
               end

             _ ->
               :ok
           end

           event
         end, nil}
      )

    on_exit(fn -> :logger.remove_primary_filter(filter_id) end)
    started = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert {:ok, :finished} =
                 DB.migration_transaction(db, :slow_step, [], [], fn _txn ->
                   receive do: ({:finish_migration, ^gate} -> :finished)
                 end)
      end)

    assert_received {:migration_progress, ^gate, progress_emitted_at}
    assert progress_emitted_at - started >= 5_000
    assert log =~ "database startup call migration_transaction: still waiting"
    assert log =~ "database startup call migration_transaction: finished"
    {progress_at, _} = :binary.match(log, progress)
    {finished_at, _} = :binary.match(log, "database startup call migration_transaction: finished")
    assert progress_at < finished_at
    assert DB.call_timeout() == 20
  end

  test "startup wait covers ordinary boot calls without changing the runtime timeout" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 20)
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :sys.suspend(db)

    caller = Task.async(fn -> DB.startup_wait(fn -> DB.query(db, "SELECT 1") end) end)
    await_queued_call(db)
    Process.sleep(80)
    :sys.resume(db)

    assert Task.await(caller) == {:ok, [[1]]}

    assert_raise DB.Timeout, fn ->
      :sys.suspend(db)

      try do
        DB.query(db, "SELECT 1")
      after
        :sys.resume(db)
      end
    end
  end

  defp await_queued_call(db) do
    case Process.info(db, :messages) do
      {:messages, [{:"$gen_call", _, _} | _]} ->
        :ok

      _ ->
        receive do
        after
          1 -> await_queued_call(db)
        end
    end
  end

  test "a failed schema migration rolls back and restores checks" do
    db = start_supervised!({DB, path: ":memory:", name: nil})

    assert {:error, %RuntimeError{message: "synthetic migration failure"}} =
             DB.migration_transaction(
               db,
               :synthetic_failure,
               ["PRAGMA ignore_check_constraints = ON"],
               ["PRAGMA ignore_check_constraints = OFF"],
               fn txn ->
                 :ok = Tightbeam.DB.Txn.exec(txn, "CREATE TABLE rolled_back (id INTEGER)")
                 raise "synthetic migration failure"
               end
             )

    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")

    assert {:ok, []} =
             DB.query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?1", [
               "rolled_back"
             ])
  end

  test "a partial migration prelude failure restores CHECK enforcement before returning" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    assert :ok = DB.execute(db, "CREATE TABLE checked(id INTEGER CHECK(id > 0))")

    assert {:error, %MatchError{}} =
             DB.migration_transaction(
               db,
               :prelude_failure,
               ["PRAGMA ignore_check_constraints=ON", "invalid SQL"],
               ["PRAGMA ignore_check_constraints=OFF"],
               fn _ -> flunk("prelude must refuse") end
             )

    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")
    assert {:error, reason} = DB.execute(db, "INSERT INTO checked VALUES(-1)")
    assert reason =~ "CHECK constraint failed"
  end

  test "an abandoned ordinary transaction rolls back before its next statement" do
    # This is a liveness budget for admission, not an elapsed-time assertion.
    # The callback must enter before it expires, then remain blocked until both
    # the real transaction call and its cleanup call have timed out.
    budget_ms = 2_000
    Application.put_env(:tightbeam, :db_call_timeout_ms, budget_ms)
    db = start_supervised!({DB, path: ":memory:", name: nil})
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        try do
          result =
            DB.transaction(db, fn txn ->
              DB.Txn.exec(txn, "CREATE TABLE old_migration_started(id INTEGER)")
              send(parent, {:old_migration_entered, System.monotonic_time(), txn.deadline})
              receive do: (:finish_old_migration -> :ok)
              DB.Txn.exec(txn, "CREATE TABLE old_migration_committed(id INTEGER)")
            end)

          send(parent, {:transaction_returned, result})
        rescue
          error in DB.Timeout ->
            send(parent, {:primary_timeout, error, System.monotonic_time()})
            reraise error, __STACKTRACE__
        after
          try do
            DB.execute(db, "PRAGMA ignore_check_constraints=OFF")
          rescue
            error in DB.Timeout -> reraise error, __STACKTRACE__
          end
        end
      end)

    # Lifecycle events inherit ExUnit's test timeout, rather than a separate
    # scheduling window for each message. An expired queued call must not pass
    # as an admitted transaction that was subsequently abandoned.
    entered_at =
      receive do
        {:old_migration_entered, entered_at, deadline} ->
          assert System.convert_time_unit(entered_at, :native, :millisecond) < deadline,
                 "callback admission must precede the transaction deadline"

          entered_at

        {:primary_timeout, _, _} ->
          flunk("transaction call timed out before callback admission")

        {:transaction_returned, result} ->
          flunk("transaction returned before callback admission: #{inspect(result)}")

        {:DOWN, ^monitor, :process, ^caller, reason} ->
          flunk("transaction caller exited before callback admission: #{inspect(reason)}")
      end

    receive do
      {:primary_timeout, error, timed_out_at} ->
        assert %DB.Timeout{operation: "db.transaction", budget_ms: ^budget_ms} = error
        assert entered_at < timed_out_at, "callback must enter before the caller times out"
    end

    receive do
      {:DOWN, ^monitor, :process, ^caller, reason} ->
        assert {%DB.Timeout{operation: "db.execute", budget_ms: ^budget_ms}, _stack} = reason
    end

    send(db, :finish_old_migration)

    assert {:ok, []} =
             DB.query(
               DB.migration_context(db),
               "SELECT name FROM sqlite_master WHERE name='old_migration_committed'"
             )

    # Work done before abandonment must roll back too, even if the next
    # statement was correctly refused before reaching SQLite.
    assert {:ok, []} =
             DB.query(
               DB.migration_context(db),
               "SELECT name FROM sqlite_master WHERE name='old_migration_started'"
             )
  end

  test "a restoration failure reports the primary error and closes the owner" do
    db = start_supervised!({DB, path: ":memory:", name: nil}, restart: :temporary)
    monitor = Process.monitor(db)

    log =
      capture_log(fn ->
        assert {:error, %DB.Error{message: message}} =
                 DB.migration_transaction(
                   db,
                   :restoration_failure,
                   ["PRAGMA ignore_check_constraints=ON"],
                   ["invalid restoration SQL", "PRAGMA ignore_check_constraints=OFF"],
                   fn _ -> raise "primary synthetic failure" end
                 )

        assert message =~ "primary synthetic failure"
        assert message =~ "pragma restoration failed"
        assert_receive {:DOWN, ^monitor, :process, ^db, %DB.Error{}}
      end)

    refute log =~ "transaction rolled back"
    refute Process.alive?(db)
  end

  @tag timeout: 20_000
  test "a gateway read survives a transient owner queue longer than the legacy 5s default" do
    Application.delete_env(:tightbeam, :db_call_timeout_ms)
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    parent = self()

    blocker =
      Task.async(fn ->
        DB.transaction(db, fn _txn ->
          send(parent, {:db_owner_blocked, self()})

          receive do
            :release_db_owner -> :ok
          end
        end)
      end)

    assert_receive {:db_owner_blocked, ^db}
    Process.send_after(db, :release_db_owner, 5_250)

    {elapsed, result} =
      elapsed_ms(fn ->
        Gateway.handlers(%{db: db})["work-item-list"].(%{
          principal: {:user, "flynn"},
          params: %{}
        })
      end)

    assert %{workItems: []} = result
    assert elapsed >= 5_000
    assert elapsed < 15_000
    assert {:ok, :ok} = Task.await(blocker, 10_000)
  end
end
