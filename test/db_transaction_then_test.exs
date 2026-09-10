defmodule Tightbeam.DBTransactionThenTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @tag :tmp_dir
  test "transaction_then commits durable evidence while retaining the writer fence", %{
    tmp_dir: tmp
  } do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "guard_transaction_then_runtime.exs",
      "guarded-transaction-then-fence: ok"
    )
  end

  defmodule OutboxSink do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_cast(message, parent) do
      send(parent, {:handoff, message})
      {:noreply, parent}
    end
  end

  setup context do
    if context[:outbox] do
      db = start_supervised!({DB, path: ":memory:", name: nil})
      sink = start_supervised!({OutboxSink, self()})
      :ok = DB.execute(db, "CREATE TABLE outbox_rows(id INTEGER PRIMARY KEY)")
      %{db: db, sink: sink}
    else
      :ok
    end
  end

  @tag :outbox
  test "ordinary commits drain FIFO only after commit and before next writer", %{
    db: db,
    sink: sink
  } do
    parent = self()

    first =
      Task.async(fn ->
        DB.transaction(db, fn txn ->
          Txn.q(txn, "INSERT INTO outbox_rows VALUES(1)")
          Txn.handoff(txn, sink, :first)
          Txn.handoff(txn, sink, :second)
          send(parent, :inside_first)

          receive do
            :release -> :one
          end
        end)
      end)

    assert_receive :inside_first

    second =
      Task.async(fn ->
        DB.transaction(db, fn txn ->
          Txn.q(txn, "INSERT INTO outbox_rows VALUES(2)")
          Txn.handoff(txn, sink, :third)
          :two
        end)
      end)

    refute_receive {:handoff, _}, 20
    refute Task.yield(second, 20)
    send(db, :release)
    assert {:ok, :one} = Task.await(first)
    assert {:ok, :two} = Task.await(second)
    assert_receive {:handoff, :first}
    assert_receive {:handoff, :second}
    assert_receive {:handoff, :third}
    assert {:ok, [[1], [2]]} = DB.query(db, "SELECT id FROM outbox_rows ORDER BY id")
  end

  @tag :outbox
  test "prepare rollback drops its queue and does not invoke recognition", %{db: db, sink: sink} do
    parent = self()

    assert {:error, %RuntimeError{}} =
             DB.transaction_then(
               db,
               fn txn ->
                 Txn.q(txn, "INSERT INTO outbox_rows VALUES(1)")
                 Txn.handoff(txn, sink, :discard)
                 raise "rollback"
               end,
               fn _, _ -> send(parent, :wrong_callback) end
             )

    assert {:ok, []} = DB.query(db, "SELECT id FROM outbox_rows")
    assert {:ok, :ok} = DB.transaction(db, &Txn.handoff(&1, sink, :fresh))
    assert_receive {:handoff, :fresh}
    refute_receive {:handoff, :discard}
    refute_receive :wrong_callback
  end

  @tag :outbox
  test "recognition has a distinct queue and retains row transitions and writer fence", %{
    db: db,
    sink: sink
  } do
    parent = self()

    task =
      Task.async(fn ->
        DB.transaction_then(
          db,
          fn txn ->
            DB.record_row_commit(txn, %{id: 1})
            Txn.q(txn, "INSERT INTO outbox_rows VALUES(1)")
            Txn.handoff(txn, sink, :prepare)
            txn
          end,
          fn txn, old ->
            assert_raise ArgumentError, fn -> Txn.handoff(old, sink, :old_phase) end
            assert DB.take_row_commits(txn) == [%{id: 1}]
            Txn.q(txn, "INSERT INTO outbox_rows VALUES(2)")
            Txn.handoff(txn, sink, :recognition)
            send(parent, :inside_recognition)

            receive do
              :release -> :recognized
            end
          end
        )
      end)

    assert_receive :inside_recognition
    assert_receive {:handoff, :prepare}
    refute_receive {:handoff, :recognition}, 20
    writer = Task.async(fn -> DB.transaction(db, fn _ -> :next end) end)
    refute Task.yield(writer, 20)
    send(db, :release)
    assert {:ok, :recognized} = Task.await(task)
    assert {:ok, :next} = Task.await(writer)
    assert_receive {:handoff, :recognition}
    refute_receive {:handoff, :old_phase}
    assert {:ok, [[1], [2]]} = DB.query(db, "SELECT id FROM outbox_rows ORDER BY id")
  end

  @tag :outbox
  test "recognition failure retains first commit and discards only second queue", %{
    db: db,
    sink: sink
  } do
    assert {:error, %RuntimeError{message: "recognition"}} =
             DB.transaction_then(
               db,
               fn txn ->
                 Txn.q(txn, "INSERT INTO outbox_rows VALUES(1)")
                 Txn.handoff(txn, sink, :durable)
               end,
               fn txn, :ok ->
                 Txn.q(txn, "INSERT INTO outbox_rows VALUES(2)")
                 Txn.handoff(txn, sink, :rolled_back)
                 raise "recognition"
               end
             )

    assert_receive {:handoff, :durable}
    refute_receive {:handoff, :rolled_back}
    assert {:ok, [[1]]} = DB.query(db, "SELECT id FROM outbox_rows")
    assert {:ok, :ok} = DB.transaction(db, &Txn.handoff(&1, sink, :next))
    assert_receive {:handoff, :next}
    refute_receive {:handoff, :durable}
  end

  @tag :outbox
  test "arity one keeps result and committed queue on callback failure", %{db: db, sink: sink} do
    assert {:ok, :published} =
             DB.transaction_then(
               db,
               fn txn ->
                 Txn.handoff(txn, sink, :one)
                 :prepared
               end,
               fn :prepared -> :published end
             )

    assert_receive {:handoff, :one}

    assert {:error, %RuntimeError{}} =
             DB.transaction_then(
               db,
               fn txn ->
                 Txn.q(txn, "INSERT INTO outbox_rows VALUES(1)")
                 Txn.handoff(txn, sink, :two)
                 txn
               end,
               fn old ->
                 assert_raise ArgumentError, fn -> Txn.handoff(old, sink, :invalid) end
                 raise "callback"
               end
             )

    assert_receive {:handoff, :two}
    refute_receive {:handoff, :invalid}
    assert {:ok, [[1]]} = DB.query(db, "SELECT id FROM outbox_rows")
  end

  @tag :outbox
  test "cross-process and escaped handles cannot queue in another live transaction", %{
    db: db,
    sink: sink
  } do
    assert {:ok, old} =
             DB.transaction(db, fn txn ->
               assert %ArgumentError{} =
                        Task.async(fn ->
                          try do
                            Txn.handoff(txn, sink, :cross)
                          rescue
                            e in ArgumentError -> e
                          end
                        end)
                        |> Task.await()

               txn
             end)

    assert_raise ArgumentError, fn -> Txn.handoff(old, sink, :escaped) end

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               assert_raise ArgumentError, fn -> Txn.handoff(old, sink, :stale) end
               Txn.handoff(txn, sink, :valid)
             end)

    assert_receive {:handoff, :valid}
    refute_receive {:handoff, _}
  end

  @tag :outbox
  test "stopped receiver cannot roll back committed state", %{db: db, sink: sink} do
    :ok = GenServer.stop(sink)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "INSERT INTO outbox_rows VALUES(1)")
               Txn.handoff(txn, sink, :undelivered)
             end)

    assert {:ok, [[1]]} = DB.query(db, "SELECT id FROM outbox_rows")
    refute_receive {:handoff, :undelivered}
  end

  @tag :outbox
  test "COMMIT refusal discards queued handoffs and leaves owner usable", %{db: db, sink: sink} do
    :ok = DB.execute(db, "CREATE TABLE parent_rows(id INTEGER PRIMARY KEY)")

    :ok =
      DB.execute(
        db,
        "CREATE TABLE child_rows(id INTEGER REFERENCES parent_rows(id) DEFERRABLE INITIALLY DEFERRED)"
      )

    assert {:error, _} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "INSERT INTO child_rows VALUES(99)")
               Txn.handoff(txn, sink, :bad_commit)
             end)

    assert {:ok, []} = DB.query(db, "SELECT id FROM child_rows")
    assert {:ok, :ok} = DB.transaction(db, &Txn.handoff(&1, sink, :after_failure))
    assert_receive {:handoff, :after_failure}
    refute_receive {:handoff, :bad_commit}
  end
end
