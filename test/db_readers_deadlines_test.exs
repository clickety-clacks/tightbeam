defmodule Tightbeam.DBReadersDeadlinesTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.DB

  @tag :tmp_dir
  test "WAL queries read committed state while the owner holds a write transaction", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(tmp, "guard_db_readers_runtime.exs", "guarded-readers: ok")
  end

  test "expired queued transaction never runs its callback" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    parent = self()
    :sys.suspend(db)

    caller = Task.async(fn ->
      DB.transaction_until(db, fn _ -> send(parent, :expired_callback) end,
        System.monotonic_time(:millisecond) + 30)
    end)

    assert {:error, %DB.DeadlineExceeded{}} = Task.await(caller)
    :sys.resume(db)
    assert {:ok, :barrier} = DB.transaction(db, fn _ -> :barrier end)
    refute_receive :expired_callback
  end

  test "a transaction checks the deadline before its next statement and rolls back" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = DB.execute(db, "CREATE TABLE deadline_rows(id INTEGER)")
    parent = self()
    deadline = System.monotonic_time(:millisecond) + 100

    result = DB.transaction_until(db, fn txn ->
      DB.Txn.q(txn, "INSERT INTO deadline_rows VALUES(1)")
      Process.sleep(110)
      DB.Txn.q(txn, "INSERT INTO deadline_rows VALUES(2)")
      send(parent, :statement_ran)
    end, deadline)

    assert {:error, %DB.DeadlineExceeded{}} = result
    refute_receive :statement_ran
    assert {:ok, []} = DB.query(db, "SELECT * FROM deadline_rows")
  end

  test "an overloaded owner refuses a new request without waiting" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :sys.suspend(db)
    on_exit(fn -> if Process.alive?(db), do: :sys.resume(db) end)
    # Valid owner requests hold the queue at its fixed bound without spawning callers.
    for _ <- 1..128 do
      send(db, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})
    end

    assert {:error, %DB.Overloaded{}} = DB.transaction(db, fn _ -> flunk("must not run") end)
    :sys.resume(db)
    assert {:ok, :barrier} = DB.transaction(DB.migration_context(db), fn _ -> :barrier end)
  end
end
