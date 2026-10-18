defmodule Tightbeam.RowReactionStoreTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Rules, Schema}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.{Plan, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "reaction-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(root, "schema_shape_runtime.exs")
    path = Path.join(prepared.base, "state.db")
    options = [path: path, name: nil, guard_inputs: [], payload_root: prepared.payload]
    db = start_supervised!({DB, options}, id: :reaction_db)
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "CREATE TABLE test_source (id TEXT PRIMARY KEY)")
    on_exit(fn -> File.rm_rf!(root) end)
    %{db: db, root: root, options: options}
  end

  defp event do
    %{
      "org" => "example",
      "id" => "transition-1",
      "kind" => "example",
      "row_id" => "row-1",
      "before" => nil,
      "after" => %{"revision" => 1},
      "principal" => %{"kind" => "user", "id" => "owner"},
      "at" => 10,
      "generation" => 1
    }
  end

  defp rails(target \\ "original", revision \\ "one") do
    [
      Plan.compile!(
        %{
          "name" => "notice",
          "family" => "example",
          "events" => ["example"],
          "when" => true,
          "effects" => [
            %{
              "slot" => "notice",
              "kind" => "notice",
              "when" => true,
              "value" => %{"session_key" => target, "prompt" => "notice"}
            }
          ]
        },
        %{"revision" => revision}
      )
    ]
  end

  test "source write and durable admission roll back together", %{db: db} do
    assert {:error, %RuntimeError{}} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "INSERT INTO test_source VALUES('source')")
               [_] = Store.admit_in_txn(txn, event(), %{}, rails(), 10)
               raise "source refused"
             end)

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM test_source")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM row_reaction_events")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM row_reaction_actions")
  end

  test "restart and source replay keep the original single admission", ctx do
    assert {:ok, [action]} =
             DB.transaction(ctx.db, &Store.admit_in_txn(&1, event(), %{}, rails(), 10))

    stop_supervised(:reaction_db)
    db = start_supervised!({DB, ctx.options}, id: :reaction_db)
    :ok = Schema.ensure_all(db)

    assert {:ok, [^action]} =
             DB.transaction(db, &Store.admit_in_txn(&1, event(), %{}, rails("different"), 20))

    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM row_reaction_actions")

    assert {:error, %ArgumentError{}} =
             DB.transaction(db, fn txn ->
               Store.admit_in_txn(
                 txn,
                 put_in(event(), ["after", "revision"], 2),
                 %{},
                 rails(),
                 30
               )
             end)
  end

  test "revision changes update pending identity then cancellation survives rollback", %{db: db} do
    {:ok, [initial]} = DB.transaction(db, &Store.admit_in_txn(&1, event(), %{}, rails(), 10))

    {:ok, [changed]} =
      DB.transaction(
        db,
        &Store.reconcile_in_txn(&1, "example", "transition-1", rails("changed", "two"), 20)
      )

    assert changed["id"] == initial["id"]
    assert changed["plan"]["value"]["session_key"] == "changed"
    assert changed["plan"]["provenance"]["revision"] == "two"

    {:ok, [canceled]} =
      DB.transaction(db, &Store.reconcile_in_txn(&1, "example", "transition-1", [], 30))

    assert canceled["status"] == "canceled"

    {:ok, [^canceled]} =
      DB.transaction(db, &Store.reconcile_in_txn(&1, "example", "transition-1", rails(), 40))
  end

  test "reevaluation exposes original rows alongside current rows", %{db: db} do
    rail =
      Plan.compile!(
        %{
          "name" => "provenance",
          "family" => "example",
          "events" => ["example"],
          "when" => true,
          "effects" => [
            %{
              "slot" => "notice",
              "kind" => "notice",
              "when" => true,
              "value" => %{
                "original" => %{"ref" => "facts.original.row.owner"},
                "current" => %{"ref" => "facts.row.owner"}
              }
            }
          ]
        },
        %{"revision" => "one"}
      )

    {:ok, [initial]} =
      DB.transaction(
        db,
        &Store.admit_in_txn(&1, event(), %{"row" => %{"owner" => "first"}}, [rail], 10)
      )

    assert initial["plan"]["value"] == %{"original" => "first", "current" => "first"}

    {:ok, [changed]} =
      DB.transaction(
        db,
        &Store.reconcile_in_txn(&1, "example", "transition-1", [rail], 20, %{
          "row" => %{"owner" => "second"},
          "original" => %{"row" => %{"owner" => "replacement"}}
        })
      )

    assert changed["id"] == initial["id"]
    assert changed["plan"]["value"] == %{"original" => "first", "current" => "second"}
  end

  test "accepted state commits with the effect and is immutable under reconciliation", %{db: db} do
    {:ok, [action]} = DB.transaction(db, &Store.admit_in_txn(&1, event(), %{}, rails(), 10))

    assert {:error, %RuntimeError{}} =
             DB.transaction(db, fn txn ->
               Store.accept_in_txn(txn, action["id"], %{"record" => "effect"}, 20)
               raise "effect failed"
             end)

    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "INSERT INTO test_source VALUES('effect')")
               Store.accept_in_txn(txn, action["id"], %{"record" => "effect"}, 30)
             end)

    {:ok, [accepted]} =
      DB.transaction(db, &Store.reconcile_in_txn(&1, "example", "transition-1", [], 40))

    assert accepted["status"] == "accepted"
    assert accepted["result"] == %{"record" => "effect"}
    assert accepted["attempts"] == 1
    assert {:ok, false} = DB.transaction(db, &Store.accept_in_txn(&1, action["id"], %{}, 50))
  end

  test "pending retry records failure and reevaluates current related rows", %{db: db} do
    [rail] = rails()
    [effect] = rail.effects

    selected = %{
      rail
      | effects: [%{effect | "value" => %{"session_key" => %{"ref" => "facts.target"}}}]
    }

    {:ok, [initial]} =
      DB.transaction(db, &Store.admit_in_txn(&1, event(), %{"target" => nil}, [selected], 10))

    {:ok, :ok} =
      DB.transaction(db, &Store.failure_in_txn(&1, initial["id"], "target unavailable", 20))

    {:ok, [retried]} =
      DB.transaction(
        db,
        &Store.reconcile_in_txn(&1, "example", "transition-1", [selected], 30, %{
          "target" => "available"
        })
      )

    assert retried["id"] == initial["id"]
    assert retried["status"] == "pending"
    assert retried["attempts"] == 1
    assert retried["last_error"] == "target unavailable"
    assert retried["plan"]["value"]["session_key"] == "available"

    assert {:ok, [[stored]]} =
             DB.query(db, "SELECT facts FROM row_reaction_events WHERE eventId='transition-1'")

    assert JSON.decode!(stored) == %{"target" => nil}
  end

  test "empty election cannot acquire new effects from later replay", %{db: db} do
    assert {:ok, []} = DB.transaction(db, &Store.admit_in_txn(&1, event(), %{}, [], 10))
    assert {:ok, []} = DB.transaction(db, &Store.admit_in_txn(&1, event(), %{}, rails(), 20))

    assert {:ok, []} =
             DB.transaction(
               db,
               &Store.reconcile_in_txn(&1, "example", "transition-1", rails(), 30)
             )
  end

  test "composed loading records bundle provenance and removal clears election", ctx do
    dir = Path.join(ctx.root, "identity/rules")
    File.mkdir_p!(dir)
    path = Path.join(dir, "example.toml")

    bytes = """
    [[reaction]]
    name = "example-notice"
    family = "example"
    events = ["example"]
    when = true
    effects = [{slot="notice",kind="notice",when=true,value={prompt="example"}}]
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    assert [] == Rules.load!(ctx.root, [], revision: "published-one")
    assert [seed] = Rules.reactions()
    assert seed.provenance["bundle"] == "seed"
    assert seed.provenance["revision"] == "published-one"
    assert seed.provenance["source"] == "rules/example.toml"

    assert seed.provenance["content_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    receipt = Path.join(ctx.root, "identity/kungfu/example/installed.toml")
    File.mkdir_p!(Path.dirname(receipt))
    File.write!(receipt, "name=\"example-bundle\"\npaths=[\"rules/example.toml\"]\n")
    Rules.load!(ctx.root, [])
    assert [learned] = Rules.reactions()
    assert learned.provenance["bundle"] == "example-bundle"
    File.rm!(path)
    Rules.load!(ctx.root, [])
    assert Rules.reactions() == []
  end

  test "malformed loaded reaction is unavailable rather than an empty election", ctx do
    path = Path.join(ctx.root, "identity/rules/bad.toml")
    File.mkdir_p!(Path.dirname(path))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[[reaction]]\nname='incomplete'\n")
    Rules.load!(ctx.root, [])
    assert_raise ArgumentError, ~r/reaction election unavailable/, fn -> Rules.reactions() end
  end
end
