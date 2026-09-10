defmodule Tightbeam.FirehoseTransactionTraceTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  test "query tracing retains transaction owner and committed outbox across both phases" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = DB.execute(db, "CREATE TABLE trace_rows(id INTEGER PRIMARY KEY)")
    parent = self()

    assert {:ok, :done} =
             DB.transaction_then(
               db,
               fn txn ->
                 traced = Txn.observe_queries(txn, parent)
                 assert traced.outbox == txn.outbox
                 assert traced.outbox_owner == txn.outbox_owner
                 Txn.q(traced, "INSERT INTO trace_rows VALUES(?1)", [1])
                 Txn.handoff(traced, parent, :first)
                 :prepared
               end,
               fn txn, :prepared ->
                 traced =
                   Txn.observe_queries(txn, fn event -> send(parent, {:callback_trace, event}) end)

                 assert [[1]] = Txn.q(traced, "SELECT id FROM trace_rows", [])
                 Txn.handoff(traced, parent, :second)
                 :done
               end
             )

    assert_receive {:core_detail_trace, {:sql_query, "INSERT INTO trace_rows VALUES(?1)", [1]}}
    assert_receive {:"$gen_cast", :first}
    assert_receive {:callback_trace, {:sql_query, "SELECT id FROM trace_rows", []}}
    assert_receive {:"$gen_cast", :second}

    assert {:error, %RuntimeError{message: "rollback"}} =
             DB.transaction(db, fn txn ->
               traced = Txn.observe_queries(txn, parent)
               Txn.q(traced, "INSERT INTO trace_rows VALUES(?1)", [2])
               Txn.handoff(traced, parent, :rolled_back)
               raise "rollback"
             end)

    assert_receive {:core_detail_trace, {:sql_query, "INSERT INTO trace_rows VALUES(?1)", [2]}}
    refute_receive {:"$gen_cast", :rolled_back}
    assert {:ok, [[1]]} = DB.query(db, "SELECT id FROM trace_rows")
  end
end
