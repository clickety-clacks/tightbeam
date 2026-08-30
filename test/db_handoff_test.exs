defmodule Tightbeam.DBHandoffTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  defmodule Sink do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
    def init(opts), do: {:ok, opts[:parent]}

    def handle_cast(message, parent) do
      send(parent, message)
      {:noreply, parent}
    end
  end

  test "handoffs follow forced interleaved commit order and run after commit" do
    db = :ordered_handoff_db
    sink = :ordered_handoff_sink
    parent = self()

    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Sink, name: sink, parent: parent})
    :ok = DB.execute(db, "CREATE TABLE ordered_handoffs (id INTEGER PRIMARY KEY)")

    first =
      Task.async(fn ->
        DB.transaction(db, fn txn ->
          Txn.q(txn, "INSERT INTO ordered_handoffs (id) VALUES (1)")
          Txn.handoff(txn, sink, {:committed, 1, db})
          send(parent, :first_inside)

          receive do
            :release_first -> :ok
          end

          :first
        end)
      end)

    assert_receive :first_inside
    db_pid = Process.whereis(db)
    :erlang.trace(db_pid, true, [:receive])

    second =
      Task.async(fn ->
        DB.transaction(db, fn txn ->
          Txn.q(txn, "INSERT INTO ordered_handoffs (id) VALUES (2)")
          Txn.handoff(txn, sink, {:committed, 2, db})
          :second
        end)
      end)

    assert_receive {:trace, ^db_pid, :receive, {:"$gen_call", _from, {:transaction, _fun}}}
    :erlang.trace(db_pid, false, [:receive])
    send(db_pid, :release_first)

    assert {:ok, :first} = Task.await(first)
    assert {:ok, :second} = Task.await(second)

    assert_receive {:committed, 1, ^db}
    assert {:ok, rows} = DB.query(db, "SELECT id FROM ordered_handoffs ORDER BY id")
    assert rows == [[1], [2]]
    assert_receive {:committed, 2, ^db}
  end

  test "a rollback discards its handoffs" do
    db = :rollback_handoff_db
    sink = :rollback_handoff_sink

    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Sink, name: sink, parent: self()})

    assert {:error, %RuntimeError{message: "rollback"}} =
             DB.transaction(db, fn txn ->
               Txn.handoff(txn, sink, :must_not_publish)
               raise "rollback"
             end)

    refute_receive :must_not_publish
  end

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
