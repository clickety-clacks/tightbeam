defmodule Tightbeam.DBTransactionThenTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  test "transaction_then commits durable evidence while retaining the writer fence" do
    db = :transaction_then_db
    parent = self()

    path =
      Path.join(System.tmp_dir!(), "tightbeam-transaction-then-#{System.unique_integer()}.db")

    on_exit(fn -> File.rm(path) end)
    start_supervised!({DB, path: path, name: db})
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
            {:ok, observer} = Exqlite.Sqlite3.open(path)
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
    send(Process.whereis(db), :release_publication)

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
  end
end
