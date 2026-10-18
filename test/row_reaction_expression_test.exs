defmodule Tightbeam.RowReactionExpressionTest do
  use ExUnit.Case, async: true
  alias Tightbeam.RowReactions.Expression

  defp ref(path), do: %{"ref" => path}
  defp op(name, args), do: %{"op" => name, "args" => args}

  defp collection(name, items, binding, value) do
    %{
      "op" => name,
      "items" => items,
      "as" => binding,
      if(name == "filter", do: "where", else: "value") => value
    }
  end

  defp evaluate(expression, facts) do
    Expression.validate!(expression)
    Expression.evaluate(expression, facts)
  end

  test "elected audience filters and order change over the same raw rows" do
    facts = %{
      "users" => [
        %{"id" => "older", "admin" => true, "created" => 1, "state" => "retired"},
        %{"id" => "later", "admin" => true, "created" => 2, "state" => "active"},
        %{"id" => "member", "admin" => false, "created" => 0, "state" => "active"}
      ]
    }

    selected =
      collection(
        "filter",
        ref("users"),
        "user",
        op("and", [
          op("eq", [ref("user.admin"), true]),
          op("eq", [ref("user.state"), "active"])
        ])
      )

    ordered = collection("sort", selected, "user", [ref("user.created"), ref("user.id")])
    assert %{"id" => "later"} = evaluate(op("first", [ordered]), facts)
    changed = collection("filter", ref("users"), "user", op("eq", [ref("user.state"), "active"]))

    assert %{"id" => "member"} =
             evaluate(
               op("first", [collection("sort", changed, "user", ref("user.created"))]),
               facts
             )

    assert nil == evaluate(op("first", [ordered]), %{"users" => []})
  end

  test "raw counts and elected cadence keep dedupe independent of recipient" do
    key =
      op("concat", [
        "identity-staleness:",
        ref("event.revision"),
        ":",
        op("text", [op("floor_divide", [ref("event.at"), 86_400_000])])
      ])

    id = op("concat", ["w_", op("sha256", [key])])
    snapshot = %{"event" => %{"revision" => "revision-a", "at" => 86_400_001}, "target" => "one"}
    assert evaluate(id, snapshot) == evaluate(id, Map.put(snapshot, "target", "two"))
    refute evaluate(id, snapshot) == evaluate(id, put_in(snapshot, ["event", "at"], 172_800_000))
    assert evaluate(key, snapshot) == "identity-staleness:revision-a:1"
    assert evaluate(op("gt", [op("count", [ref("late")]), 0]), %{"late" => ["one"]})
    refute evaluate(op("gt", [op("count", [ref("late")]), 1]), %{"late" => ["one"]})
  end

  test "missing facts do not manufacture lifecycle transitions" do
    refute evaluate(op("ne", [ref("before.state"), "closed"]), %{})
    assert evaluate(op("is_null", [ref("before.state")]), %{})
    assert false == evaluate(op("coalesce", [ref("missing"), false, true]), %{})
    expression = op("if", [op("is_null", [ref("before")]), "inserted", op("divide", [1, 0])])
    assert "inserted" == evaluate(expression, %{})
  end

  test "JSON tuple encoding preserves the existing terminal handoff identity" do
    source = %{
      source_kind: "attest",
      source_token: "receipt:one\"two",
      assignment_id: "assignment",
      work_item_id: nil,
      child_session_key: "child",
      owner_user_id: "owner",
      opened_by_kind: "session",
      opened_by_id: "parent",
      outcome: "completed",
      terminal_at: 10
    }

    {:ok, existing} = Tightbeam.Wakes.terminal_notification(source)

    identity =
      op("json", [
        ["terminal-child-owner-notification", ref("source.kind"), ref("source.id")]
      ])

    elected = op("concat", ["w_terminal_", op("sha256", [identity])])
    facts = %{"source" => %{"kind" => source.source_kind, "id" => source.source_token}}
    assert evaluate(elected, facts) == existing.wake_id
    assert evaluate(op("json", [nil]), %{}) == "null"
    assert evaluate(op("json", ["line\nnext"]), %{}) == "\"line\\nnext\""
  end

  test "collection bindings are local and record payloads preserve typed values" do
    expression = %{
      "ids" => collection("map", ref("rows"), "row", ref("row.id")),
      "outer" => ref("row.id"),
      "absent" => ref("missing")
    }

    assert %{"ids" => [1, 2], "outer" => "outside", "absent" => nil} ==
             evaluate(expression, %{
               "rows" => [%{"id" => 1}, %{"id" => 2}],
               "row" => %{"id" => "outside"}
             })
  end

  test "TOML data supplies the predicate without an executable callback" do
    {:ok, data} =
      Toml.decode("""
      [predicate]
      op = "gte"
      args = [{ref = "event.count"}, 3]
      """)

    refute evaluate(data["predicate"], %{"event" => %{"count" => 2}})
    assert evaluate(data["predicate"], %{"event" => %{"count" => 3}})
  end

  test "unsupported expressions and invalid operands fail explicitly" do
    for expression <- [
          %{"ref" => "event.id", "fallback" => true},
          op("callback", ["notify-attest"]),
          op("eq", [1])
        ] do
      assert_raise ArgumentError, fn -> Expression.validate!(expression) end
    end

    assert_raise ArgumentError, fn -> evaluate(op("gte", ["3", 2]), %{}) end
    assert_raise ArgumentError, fn -> evaluate(op("divide", [1, 0]), %{}) end
  end
end
