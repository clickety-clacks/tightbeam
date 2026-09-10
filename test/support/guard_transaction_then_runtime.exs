[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
import ExUnit.Assertions
alias Tightbeam.{DB, Schema}
path = Path.join(base, "state.db")
{:ok, db} = DB.start_link(path: path, name: nil, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))
  alias Tightbeam.DB.Txn
  parent = self()
  :ok = DB.execute(db, "CREATE TABLE publication_markers (id INTEGER PRIMARY KEY)")

  publication =
    Task.async(fn ->
      DB.transaction_then(
        db,
        fn txn ->
          Txn.q(txn, "INSERT INTO publication_markers (id) VALUES (1)")
          :marker
        end,
        fn :marker ->
          {:ok, observer} = Exqlite.Sqlite3.open(path, mode: :readonly)
          rows = DB.run_query(observer, "SELECT id FROM publication_markers", [])
          :ok = Exqlite.Sqlite3.close(observer)
          send(parent, {:marker_visible, rows})

          receive do
            :release_publication -> :published
          end
        end
      )
    end)

  assert_receive {:marker_visible, [[1]]}

  queued_writer =
    Task.async(fn ->
      DB.transaction(db, fn txn ->
        Txn.q(txn, "INSERT INTO publication_markers (id) VALUES (2)")
        :written
      end)
    end)

  refute Task.yield(queued_writer, 50)
  send(db, :release_publication)

  assert {:ok, :published} = Task.await(publication)
  assert {:ok, :written} = Task.await(queued_writer)
  assert {:ok, [[1], [2]]} = DB.query(db, "SELECT id FROM publication_markers ORDER BY id")

  assert {:error, %RuntimeError{message: "publication crashed"}} =
           DB.transaction_then(
             db,
             fn txn ->
               Txn.q(txn, "INSERT INTO publication_markers (id) VALUES (3)")
               :marker
             end,
             fn :marker -> raise "publication crashed" end
           )

  assert {:ok, [[1], [2], [3]]} =
           DB.query(db, "SELECT id FROM publication_markers ORDER BY id")

  assert File.read!(Path.join(base, "build-owner.json")) == marker
  :ok = DB.assert_base_admitted!(db, base)
after
  if Process.alive?(db), do: GenServer.stop(db)
end

IO.puts("guarded-transaction-then-fence: ok")
