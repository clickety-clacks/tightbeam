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
      assert catch_exit(DB.query(db, "SELECT 1")) |> elem(0) == :timeout
    after
      :sys.resume(db)
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

  test "a bounded cleanup call can mask the original transaction timeout while the owner continues" do
    Application.put_env(:tightbeam, :db_call_timeout_ms, 25)
    db = start_supervised!({DB, path: ":memory:", name: nil})
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        try do
          DB.transaction(db, fn txn ->
            send(parent, :old_migration_entered)
            receive do: (:finish_old_migration -> :ok)
            DB.Txn.exec(txn, "CREATE TABLE old_migration_committed(id INTEGER)")
          end)
        catch
          :exit, reason ->
            send(parent, {:primary_timeout, reason})
            exit(reason)
        after
          DB.execute(db, "PRAGMA ignore_check_constraints=OFF")
        end
      end)

    assert_receive :old_migration_entered

    assert_receive {:primary_timeout,
                    {:timeout, {GenServer, :call, [^db, {:transaction, _}, 25]}}}

    assert_receive {:DOWN, ^monitor, :process, ^caller,
                    {:timeout,
                     {GenServer, :call,
                      [^db, {:execute, "PRAGMA ignore_check_constraints=OFF"}, 25]}}}

    send(db, :finish_old_migration)

    assert {:ok, [["old_migration_committed"]]} =
             DB.query(
               DB.migration_context(db),
               "SELECT name FROM sqlite_master WHERE name='old_migration_committed'"
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
