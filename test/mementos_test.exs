defmodule Tightbeam.MementosTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Mementos}
  alias Tightbeam.DB.Txn

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Mementos.ensure_schema(db)
    root = Path.join(System.tmp_dir!(), "mementos-#{System.unique_integer([:positive])}")

    for bundle <- ~w(alpha beta) do
      dir = Path.join([root, "identity", "kungfu", bundle])
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "manifest.toml"), """
      [[mementos]]
      name = "target"
      records = ["work_item"]
      [[mementos]]
      name = "evidence"
      records = ["attest", "assignment"]
      many = true
      """)
    end

    Tightbeam.Rules.load!(root, [], revision: "published-revision")
    on_exit(fn -> File.rm_rf!(root) end)
    %{db: db}
  end

  test "declarations reject unknown keys, duplicates and invalid cardinality" do
    declaration = %{"name" => "target", "records" => ["work_item"]}
    assert [%{name: "target", many: false}] = Mementos.declarations!([declaration], "manifest")

    for {entries, message} <- [
          {[Map.put(declaration, "kind", "branch")], ~r/target.*unknown keys kind/},
          {[declaration, declaration], ~r/declares memento target twice/},
          {[Map.put(declaration, "records", [])], ~r/nonempty subset/},
          {[Map.put(declaration, "records", ["session"])], ~r/nonempty subset/},
          {[Map.put(declaration, "many", 1)], ~r/many must be boolean/}
        ] do
      assert_raise ArgumentError, message, fn -> Mementos.declarations!(entries, "manifest") end
    end
  end

  test "name and value admission preserves opaque order and names precise refusals" do
    assert [{"alpha/evidence", ["PR 12, merged", "x"]}] =
             Mementos.prepare!("attest", [{"alpha/evidence", ["PR 12, merged", "x", "x"]}])

    for {kind, entries, code} <- [
          {"work_item", [{"target", ["main"]}], "ambiguous_memento"},
          {"work_item", [{"absent", ["main"]}], "unknown_memento"},
          {"assignment", [{"alpha/target", ["main"]}], "memento_record_kind"},
          {"work_item", [{"alpha/target", ["a", "b"]}], "memento_single_value"},
          {"attest", [{"alpha/evidence", [String.duplicate("x", 1025)]}], "memento_value_bounds"},
          {"attest", [{"alpha/evidence", [<<255>>]}], "memento_value_bounds"},
          {"attest", [{"alpha/evidence", ["a\0b"]}], "memento_value_bounds"}
        ] do
      error = assert_raise Mementos.Refusal, fn -> Mementos.prepare!(kind, entries) end
      assert error.code == code
    end
  end

  test "current values and clears do not rewrite append-only history", %{db: db} do
    append(db, "first")
    append(db, "PR 12, merged")
    assert Mementos.current(db, "work_item", "record", "alpha/target") == ["PR 12, merged"]
    assert Mementos.current(db, "work_item", "record") == %{"alpha/target" => ["PR 12, merged"]}
    append(db, [])
    assert Mementos.current(db, "work_item", "record", "alpha/target") == []

    assert Enum.map(Mementos.history(db, "work_item", "record").history, & &1.values) ==
             [["first"], ["PR 12, merged"], []]

    assert {:error, _} = DB.query(db, "UPDATE memento_history SET valueJson='[]'")
    assert {:error, _} = DB.query(db, "DELETE FROM memento_history")
  end

  test "a rollback restores both current value and history", %{db: db} do
    append(db, "before")

    assert {:error, %RuntimeError{}} =
             DB.transaction(db, fn txn ->
               Mementos.append_in_txn!(
                 txn,
                 "work_item",
                 "record",
                 [{"alpha/target", ["after"]}],
                 {:user, "author"},
                 "published-revision"
               )

               raise "abort"
             end)

    assert Mementos.current(db, "work_item", "record", "alpha/target") == ["before"]
    assert length(Mementos.history(db, "work_item", "record").history) == 1
  end

  test "history cursors resume without duplicates and are bound to their request", %{db: db} do
    for n <- 1..250, do: append(db, Integer.to_string(n))
    first = Mementos.history(db, "work_item", "record")
    second = Mementos.history(db, "work_item", "record", cursor: first.cursor)
    third = Mementos.history(db, "work_item", "record", cursor: second.cursor)
    assert [100, 100, 50] == Enum.map([first, second, third], &length(&1.history))
    assert first.hasMore and second.hasMore and not third.hasMore
    assert third.cursor == nil

    assert Enum.map(first.history ++ second.history ++ third.history, & &1.values) ==
             Enum.map(1..250, &[Integer.to_string(&1)])

    error =
      assert_raise Mementos.Refusal, fn ->
        Mementos.history(db, "work_item", "other", cursor: first.cursor)
      end

    assert error.code == "memento_history_cursor"
  end

  test "history caps the encoded response even for maximum escaped payloads", %{db: db} do
    values = for n <- 1..32, do: String.pad_leading(Integer.to_string(n), 1024, "\n")

    assert {:ok, _} =
             DB.transaction(db, fn txn ->
               for _ <- 1..20 do
                 Mementos.append_in_txn!(
                   txn,
                   "assignment",
                   "record",
                   [{"alpha/evidence", values}],
                   {:user, "author"},
                   "published-revision"
                 )
               end
             end)

    page = Mementos.history(db, "assignment", "record", limit: 1000)
    assert page.hasMore
    assert page.history != []
    assert byte_size(JSON.encode!(page)) <= 1_048_576
    rest = Mementos.history(db, "assignment", "record", cursor: page.cursor)
    assert length(page.history ++ rest.history) == 20
  end

  test "current and history queries use direct indexed access", %{db: db} do
    append(db, "current")

    {:ok, rows} =
      DB.query(
        db,
        """
        EXPLAIN QUERY PLAN SELECT valueJson FROM memento_current
        WHERE recordKind=?1 AND recordId=?2 AND name=?3
        """,
        ["work_item", "record", "alpha/target"]
      )

    assert Enum.any?(rows, fn row -> String.contains?(List.last(row), "SEARCH") end)
    refute Enum.any?(rows, fn row -> String.contains?(List.last(row), "SCAN") end)

    {:ok, rows} =
      DB.query(
        db,
        """
        EXPLAIN QUERY PLAN SELECT id,valueJson FROM memento_history
        WHERE recordKind=?1 AND recordId=?2 AND name=?3 AND id>?4 ORDER BY id LIMIT 100
        """,
        ["work_item", "record", "alpha/target", 0]
      )

    assert Enum.any?(rows, fn row -> String.contains?(List.last(row), "memento_history_key") end)
    refute Enum.any?(rows, fn row -> String.contains?(List.last(row), "SCAN") end)
  end

  defp append(db, value) do
    values = if is_list(value), do: value, else: [value]

    assert {:ok, _} =
             DB.transaction(db, fn %Txn{} = txn ->
               Mementos.append_in_txn!(
                 txn,
                 "work_item",
                 "record",
                 [{"alpha/target", values}],
                 {:user, "author"},
                 "published-revision"
               )
             end)
  end
end
