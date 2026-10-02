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

  @tag timeout: 120_000
  test "a large-base schema migration outlives the former 30s client timeout" do
    Application.delete_env(:tightbeam, :db_call_timeout_ms)
    assert DB.call_timeout() == 30_000
    db = start_supervised!({DB, path: ":memory:", name: nil})
    parent = self()

    {elapsed_us, result} =
      :timer.tc(fn ->
        DB.migration_transaction(
          db,
          :synthetic_large_base,
          ["PRAGMA ignore_check_constraints = ON"],
          ["PRAGMA ignore_check_constraints = OFF"],
          fn txn ->
            send(parent, :migration_started)

            :ok =
              Tightbeam.DB.Txn.exec(
                txn,
                "CREATE TABLE migration_fixture (id INTEGER PRIMARY KEY, payload INTEGER NOT NULL)"
              )

            # This is a real SQLite workload, not a sleep: the migration builds
            # a one-million-row fixture and performs a two-billion-row join
            # aggregate over it. It is deliberately large enough to exceed the
            # former 30s caller wait while remaining a small on-disk fixture.
            :ok =
              Tightbeam.DB.Txn.exec(txn, """
              WITH RECURSIVE series(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM series WHERE value < 1000000
              )
              INSERT INTO migration_fixture
              SELECT value, (value * 17) % 1000003 FROM series
              """)

            :ok =
              Tightbeam.DB.Txn.exec(
                txn,
                "CREATE TABLE migration_work_fanout (factor INTEGER PRIMARY KEY)"
              )

            :ok =
              Tightbeam.DB.Txn.exec(txn, """
              WITH RECURSIVE series(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM series WHERE value < 2000
              )
              INSERT INTO migration_work_fanout SELECT value FROM series
              """)

            [[checksum]] =
              Tightbeam.DB.Txn.q(txn, """
              SELECT sum(f.payload * w.factor)
              FROM migration_fixture AS f
              CROSS JOIN migration_work_fanout AS w
              """)

            send(parent, {:migration_work_complete, checksum})

            :ok =
              Tightbeam.DB.Txn.exec(
                txn,
                "CREATE TABLE migration_complete (id INTEGER PRIMARY KEY)"
              )

            :ok
          end
        )
      end)

    assert {:ok, :ok} = result
    assert elapsed_us >= 30_000_000

    assert_receive :migration_started
    assert_receive {:migration_work_complete, checksum} when is_integer(checksum) and checksum > 0
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")

    assert {:ok, [["migration_complete"]]} =
             DB.query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?1", [
               "migration_complete"
             ])
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
