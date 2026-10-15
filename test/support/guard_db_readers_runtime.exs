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

  writer = Task.async(fn ->
    DB.transaction(db, fn txn ->
      DB.Txn.q(txn, "INSERT INTO reader_rows VALUES(2)")
      send(parent, :writer_holds_owner)
      receive do: (:release_writer -> :written)
    end)
  end)

  assert_receive :writer_holds_owner
  reader = Task.async(fn -> DB.query(db, "SELECT id FROM reader_rows ORDER BY id") end)
  assert {:ok, {:ok, [[1]]}} = Task.yield(reader, 1_000)
  send(db, :release_writer)
  assert {:ok, :written} = Task.await(writer)
  assert {:ok, [[1], [2]]} = DB.query(db, "SELECT id FROM reader_rows ORDER BY id")

  # A write CTE must still use the writer, never silently fail on a reader.
  assert {:ok, []} = DB.query(db, "WITH n AS (SELECT 3 AS id) INSERT INTO reader_rows SELECT id FROM n")
  assert {:ok, [[3]]} = DB.query(db, "SELECT id FROM reader_rows WHERE id=3")
after
  GenServer.stop(db)
end
IO.puts("guarded-readers: ok")
