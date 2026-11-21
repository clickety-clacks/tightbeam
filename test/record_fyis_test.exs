defmodule Tightbeam.RecordFyisTest do
  @moduledoc """
  FYI storage accepts every record kind that states FYIs, and a database that
  carries the earlier attest-only shape is rebuilt with its rows kept.
  """

  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, RecordFyis, Schema}
  alias Tightbeam.DB.Txn

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "every FYI record kind is stored and read back", %{db: db} do
    kinds =
      ~w(attest assignment session decision_request harness_health_promotion harness_health_review)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Enum.each(kinds, fn kind ->
                 :ok = RecordFyis.put_in_txn(txn, kind, "rec_#{kind}", [RecordFyis.line(kind)])
               end)
             end)

    for kind <- kinds do
      assert %{("rec_" <> ^kind) => [line]} = RecordFyis.list_many(db, kind, ["rec_#{kind}"])
      assert line == "FYI: #{kind}; decide for yourself whether that is acceptable"
    end
  end

  test "the attest-only predecessor table is rebuilt with its rows kept", %{db: db} do
    line = RecordFyis.line("an earlier attest fact")

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               :ok = Txn.exec(txn, "DROP TABLE record_fyis")
               :ok = Txn.exec(txn, RecordFyis.attest_only_table_sql())

               Txn.q(
                 txn,
                 "INSERT INTO record_fyis (recordKind, recordId, fyi, createdAt) VALUES ('attest','att_1',?1,7)",
                 [JSON.encode!([line])]
               )

               :ok
             end)

    assert {:error, %{message: message}} =
             DB.query(
               db,
               "INSERT INTO record_fyis (recordKind, recordId, fyi, createdAt) VALUES ('assignment','asg_1','[]',1)"
             )

    assert message =~ "CHECK"

    assert :ok = RecordFyis.ensure_schema(db)
    assert :ok = RecordFyis.ensure_schema(db)

    assert %{"att_1" => [^line]} = RecordFyis.list_many(db, "attest", ["att_1"])
    assert {:ok, [[7]]} = DB.query(db, "SELECT createdAt FROM record_fyis WHERE recordId='att_1'")

    assert {:ok, :ok} =
             DB.transaction(db, &RecordFyis.put_in_txn(&1, "assignment", "asg_1", [line]))

    assert %{"asg_1" => [^line]} = RecordFyis.list_many(db, "assignment", ["asg_1"])
  end

  test "a table of any other shape is refused, not repaired", %{db: db} do
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               :ok = Txn.exec(txn, "DROP TABLE record_fyis")

               :ok =
                 Txn.exec(
                   txn,
                   "CREATE TABLE record_fyis (recordKind TEXT, recordId TEXT, fyi TEXT, createdAt INTEGER)"
                 )
             end)

    assert {:error, %Schema.ShapeError{message: "record_fyis_incompatible_shape" <> _}} =
             RecordFyis.ensure_schema(db)
  end
end
