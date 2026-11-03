defmodule Tightbeam.RetirementMigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema, Wakes}
  alias Tightbeam.DB.Txn

  setup do
    db = start_supervised!({DB, name: nil, path: ":memory:"})
    :ok = ensure_all_schemas(db)

    :ok =
      DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('retirement-owner',0,1)")

    ensure_main_session(db, "retirement-owner")
    key = Tightbeam.Org.personal_session_key("retirement-owner")

    wake =
      Wakes.schedule(db, %{
        session_key: key,
        origin: "user:retirement-owner",
        prompt: "ordinary notice",
        due_at: 253_402_300_799_000
      })

    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, %{
                 wake_id: wake.wake_id,
                 requester: %{kind: "user", id: "retirement-owner"},
                 reason_kind: "requester_withdrew",
                 causal_source: %{
                   kind: "verb_call",
                   accepted_event: %{
                     origin: "user:retirement-owner",
                     session_key: key,
                     principal: {:user, "retirement-owner"}
                   }
                 },
                 expected_origin: "user:retirement-owner",
                 outcome: %{kind: "no_replacement"}
               })
               |> case do
                 {:accepted_in_txn, _, %{canceled: true}} -> true
                 result -> result
               end
             end)

    rows = DB.query(db, "SELECT * FROM wake_cancellations")

    assert {:ok, :ok} =
             DB.migration_transaction(
               db,
               :retirement_predecessor_fixture,
               [],
               ["PRAGMA writable_schema=OFF"],
               fn txn ->
                 sql =
                   Schema.retirement_cancellation_predecessor_ddl()
                   |> String.replace("IF NOT EXISTS ", "")
                   |> String.trim()

                 [[version]] = Txn.q(txn, "PRAGMA schema_version")
                 Txn.exec(txn, "PRAGMA writable_schema=ON")

                 Txn.q(
                   txn,
                   "UPDATE sqlite_master SET sql=?1 WHERE name='wake_cancellations' AND type='table'",
                   [sql]
                 )

                 Txn.exec(txn, "PRAGMA schema_version=#{version + 1}")
                 Txn.exec(txn, "PRAGMA writable_schema=RESET")

                 Txn.q(
                   txn,
                   "DELETE FROM supervision_liveness_migrations WHERE migrationId='retirement-continuation-cancellation/v1'"
                 )

                 Txn.exec(
                   txn,
                   "DROP TABLE retirement_owner_transfers; DROP TABLE retirement_blockers; DROP TABLE unfinished_retirements;"
                 )

                 :ok
               end
             )

    %{db: db, rows: rows}
  end

  test "the exact predecessor upgrades without rewriting prior cancellations and restarts", %{
    db: db,
    rows: rows
  } do
    assert :ok = Schema.ensure_all(db)
    assert DB.query(db, "SELECT * FROM wake_cancellations") == rows

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM supervision_liveness_migrations WHERE migrationId='retirement-continuation-cancellation/v1'"
             )

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM unfinished_retirements")
    assert :ok = Schema.ensure_all(db)
    assert DB.query(db, "SELECT * FROM wake_cancellations") == rows
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "an unknown retirement table shape refuses instead of repairing it", %{db: db} do
    assert :ok = DB.execute(db, "CREATE TABLE unfinished_retirements(id TEXT PRIMARY KEY)")

    assert_raise Schema.ShapeError, ~r/malformed retirement schema/, fn ->
      Schema.ensure_all(db)
    end

    assert {:ok, [["CREATE TABLE unfinished_retirements(id TEXT PRIMARY KEY)"]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE name='unfinished_retirements'"
             )
  end
end
