defmodule Tightbeam.AgentOwnershipTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, Schema}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "virtual Main is stable across materialization and separate for each user", %{db: db} do
    for owner <- ["one", "two"] do
      main = Org.personal_session_key(owner)
      child = create(db, "child-#{owner}", owner)
      assert Org.get(db, main) == nil
      assert child.topology_parent == main
      assert child.current_parent == nil
      assert child.spawned_by == nil
      assert child.owner_user_id == owner
      create(db, main, owner, %{kind: "main"})
      assert Org.topology_parent(db, main) == nil
      assert Org.get(db, child.session_key) == child
    end
  end

  test "explicit parents must be existing same-user agents", %{db: db} do
    create(db, "foreign", "two")

    for parent <- ["missing", "user:one", "process:test", "foreign"] do
      assert_raise ArgumentError, ~r/invalid organizational parent/, fn ->
        create(db, "rejected", "one", %{spawned_by: parent})
      end

      assert Org.get(db, "rejected") == nil
    end

    create(db, "parent", "one")
    assert create(db, "child", "one", %{spawned_by: "parent"}).topology_parent == "parent"
  end

  test "only canonical Main may be a root and Main cannot have a parent", %{db: db} do
    main = Org.personal_session_key("one")

    for {key, extra} <- [
          {"alternate", %{kind: "main"}},
          {main, %{}},
          {main, %{kind: "main", spawned_by: "parent"}},
          {"self", %{spawned_by: "self"}}
        ] do
      assert_raise ArgumentError, fn -> create(db, key, "one", extra) end
      assert Org.get(db, key) == nil
    end

    create(db, main, "one", %{kind: "main"})
    assert_raise Tightbeam.DB.Error, fn -> create(db, main, "one", %{kind: "main"}) end
  end

  defp create(db, key, owner, extra \\ %{}) do
    Org.create(
      db,
      Map.merge(
        %{
          session_key: key,
          display_name: key,
          owner_user_id: owner,
          origin: "user:#{owner}",
          archetype: "default",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: Model.new("fixture")
        },
        extra
      )
    )
  end
end
