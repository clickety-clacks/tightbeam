[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
import ExUnit.Assertions
alias Tightbeam.DB
{:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

try do
  :ok = Tightbeam.Schema.ensure_all(db)
  :ok = DB.execute(db, "CREATE TABLE reader_rows(id INTEGER)")
  {:ok, []} = DB.query(db, "INSERT INTO reader_rows VALUES(1)")
  parent = self()

  writer =
    Task.async(fn ->
      DB.transaction(db, fn txn ->
        DB.Txn.q(txn, "INSERT INTO reader_rows VALUES(2)")
        send(parent, :writer_holds_owner)
        receive do: (:release_writer -> :written)
      end)
    end)

  assert_receive :writer_holds_owner

  reader =
    Task.async(fn ->
      DB.query(
        db,
        "-- read committed rows\n/* independent reader */ SELECT id FROM reader_rows ORDER BY id"
      )
    end)

  assert {:ok, {:ok, [[1]]}} = Task.yield(reader, 1_000)
  send(db, :release_writer)
  assert {:ok, :written} = Task.await(writer)
  assert {:ok, [[1], [2]]} = DB.query(db, "SELECT id FROM reader_rows ORDER BY id")

  # A write CTE must still use the writer, never silently fail on a reader.
  assert {:ok, []} =
           DB.query(db, "WITH n AS (SELECT 3 AS id) INSERT INTO reader_rows SELECT id FROM n")

  assert {:ok, [[3]]} = DB.query(db, "SELECT id FROM reader_rows WHERE id=3")

  reader = DB.reader(db, "SELECT 1")
  assert is_pid(reader)

  same_reader_task = fn fun ->
    Enum.reduce_while(1..100, nil, fn _, _ ->
      task =
        Task.async(fn ->
          if DB.reader(db, "SELECT 1") == reader do
            send(parent, {:selected_reader, self()})
            receive do: (:run -> fun.())
          else
            :another_reader
          end
        end)

      receive do
        {:selected_reader, pid} ->
          {:halt, {task, pid}}

        {ref, :another_reader} when ref == task.ref ->
          Process.demonitor(ref, [:flush])
          {:cont, nil}
      after
        1_000 -> flunk("reader selection stalled")
      end
    end)
  end

  {slow, slow_pid} =
    same_reader_task.(fn ->
      DB.query_until(
        db,
        "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT id,(SELECT sum(x) FROM n) FROM reader_rows",
        [],
        System.monotonic_time(:millisecond) + 300
      )
    end)

  send(slow_pid, :run)
  # Wait until the selected connection is executing the long statement.
  wait_active = fn wait ->
    case :persistent_term.get({Tightbeam.DB.Reader, reader}, nil) do
      {_, _} ->
        :ok

      nil ->
        Process.sleep(1)
        wait.(wait)
    end
  end

  wait_active.(wait_active)
  Process.sleep(20)

  assert {:ok, :written} =
           DB.transaction(db, fn txn ->
             DB.Txn.q(txn, "INSERT INTO reader_rows VALUES(4)")
             :written
           end)

  {fresh, fresh_pid} =
    same_reader_task.(fn ->
      DB.query(db, "SELECT id FROM reader_rows ORDER BY id")
    end)

  send(fresh_pid, :run)
  assert {:error, %DB.DeadlineExceeded{}} = Task.await(slow, 2_000)
  assert {:ok, [[1], [2], [3], [4]]} = Task.await(fresh, 2_000)
  assert {:ok, [[0, 0, 0]]} = DB.query(db, "PRAGMA wal_checkpoint(TRUNCATE)")

  # A queued caller's timeout must not interrupt the active caller.
  :sys.suspend(reader)

  {expired, expired_pid} =
    same_reader_task.(fn ->
      DB.query_until(db, "SELECT 1", [], System.monotonic_time(:millisecond) + 20)
    end)

  send(expired_pid, :run)
  assert {:error, %DB.DeadlineExceeded{}} = Task.await(expired)
  :sys.resume(reader)
  {after_timeout, after_timeout_pid} = same_reader_task.(fn -> DB.query(db, "SELECT 42") end)
  send(after_timeout_pid, :run)
  assert {:ok, [[42]]} = Task.await(after_timeout)
after
  GenServer.stop(db)
end

IO.puts("guarded-readers: ok")
