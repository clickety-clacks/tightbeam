defmodule Tightbeam.MementoStoragePortTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, MementoFacts, Mementos}
  alias Tightbeam.DB.Txn

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Mementos.ensure_schema(db)
    %{db: db}
  end

  test "current values change without rewriting the attributable history", %{db: db} do
    append(db, ["first"])
    append(db, ["second", "opaque:member"])
    append(db, [])

    assert Mementos.current(db, "work_item", "record", "example/evidence") == []

    assert Enum.map(Mementos.history(db, "work_item", "record").history, & &1.values) ==
             [["first"], ["second", "opaque:member"], []]

    assert {:error, _} = DB.query(db, "UPDATE memento_history SET valueJson='[]'")
    assert {:error, _} = DB.query(db, "DELETE FROM memento_history")

    assert {:error, %RuntimeError{}} =
             DB.transaction(db, fn txn ->
               Mementos.append_in_txn!(
                 txn,
                 "work_item",
                 "record",
                 [{"example/evidence", ["rolled back"]}],
                 {:session, "agent:example"},
                 "revision"
               )

               raise "abort"
             end)

    assert Mementos.current(db, "work_item", "record", "example/evidence") == []
    assert length(Mementos.history(db, "work_item", "record").history) == 3
  end

  test "history pages preserve append order and bind the cursor to one record", %{db: db} do
    for number <- 1..205, do: append(db, [Integer.to_string(number)])

    first = Mementos.history(db, "work_item", "record")
    second = Mementos.history(db, "work_item", "record", cursor: first.cursor)
    third = Mementos.history(db, "work_item", "record", cursor: second.cursor)

    assert Enum.map([first, second, third], &length(&1.history)) == [100, 100, 5]
    assert first.hasMore and second.hasMore and not third.hasMore

    assert Enum.map(first.history ++ second.history ++ third.history, & &1.values) ==
             Enum.map(1..205, &[Integer.to_string(&1)])

    error =
      assert_raise Mementos.Refusal, fn ->
        Mementos.history(db, "work_item", "another", cursor: first.cursor)
      end

    assert error.code == "memento_history_cursor"
  end

  test "declared facts distinguish an absent value from a cleared value", %{db: db} do
    declarations = %{
      revision: "revision",
      names: %{
        "example/evidence" => %{
          name: "evidence",
          qualified: "example/evidence",
          records: ["work_item", "attest"],
          many: true
        }
      }
    }

    Mementos.with_declarations(declarations, fn ->
      assert MementoFacts.type("work_item.has_memento.example/evidence") == :bool
      assert MementoFacts.type("call.memento_names") == {:list, :string}
      assert MementoFacts.type("assignment.memento.example/evidence") == nil

      assert MementoFacts.type(
               "assignment.latest_linked_review.memento_matches_call.example/evidence"
             ) ==
               :bool

      assert MementoFacts.type(
               "assignment.latest_linked_review.memento_matches_cutover_requirement.example/evidence"
             ) ==
               nil

      assert MementoFacts.record_value(
               db,
               "work_item",
               "record",
               "has_memento",
               "example/evidence"
             ) ==
               false

      append(db, ["opaque:value"])

      assert MementoFacts.record_value(db, "work_item", "record", "memento", "example/evidence") ==
               ["opaque:value"]

      assert MementoFacts.matches?(["opaque:value", "other"], ["other", "opaque:value"])
      refute MementoFacts.matches?(["opaque:value"], [])

      append(db, [])

      assert MementoFacts.record_value(
               db,
               "work_item",
               "record",
               "has_memento",
               "example/evidence"
             ) ==
               false
    end)
  end

  defp append(db, values) do
    assert {:ok, _} =
             DB.transaction(db, fn %Txn{} = txn ->
               Mementos.append_in_txn!(
                 txn,
                 "work_item",
                 "record",
                 [{"example/evidence", values}],
                 {:session, "agent:example"},
                 "revision"
               )
             end)
  end
end
