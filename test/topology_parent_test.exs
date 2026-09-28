defmodule Tightbeam.TopologyParentTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, Schema, StateResources}
  alias Tightbeam.Wire.Payloads

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "per-user Main roots and proxy children leave historical authority unchanged", %{db: db} do
    for owner <- ["one", "two"] do
      root = Org.personal_session_key(owner)
      session(db, root, owner, %{kind: "main", is_built_in: true})
      child = session(db, "child-#{owner}", owner)

      assert Org.topology_parent(db, root) == nil
      assert Org.get(db, root).topology_parent == nil
      assert Org.topology_parent(db, child.session_key) == root
      assert child.topology_parent == root
      assert child.owner_user_id == owner
      assert child.origin == "user:#{owner}"
      assert child.spawned_by == nil
      assert child.current_parent == nil
      assert Org.current_parent(db, child.session_key) == nil

      assert {:ok, [[^owner, nil]]} =
               DB.query(db, "SELECT ownerUserId,spawnedBy FROM sessions WHERE sessionKey=?1", [
                 child.session_key
               ])
    end

    assert Org.topology_parent(db, "missing") == nil
  end

  test "spawn lineage remains distinct from the user proxy fallback", %{db: db} do
    root = Org.personal_session_key("one")
    session(db, root, "one", %{kind: "main", is_built_in: true})
    session(db, "parent", "one")
    child = session(db, "child", "one", %{origin: "agent:parent", spawned_by: "parent"})

    assert child.topology_parent == "parent"
    assert Org.topology_parent(db, "child") == "parent"
    assert Org.current_parent(db, "child") == "parent"
    assert child.spawned_by == "parent"
    assert child.origin == "agent:parent"
  end

  test "a virtual Main root has the same identity after materialization", %{db: db} do
    root = Org.personal_session_key("one")
    child = session(db, "child", "one")
    assert Org.get(db, root) == nil
    assert child.topology_parent == root
    assert Org.topology_parent(db, "child") == root

    session(db, root, "one", %{kind: "main", is_built_in: true})
    assert Org.get(db, "child") == child
    assert Org.topology_parent(db, root) == nil
  end

  test "list, stream and canonical state projections share the organizational edge", %{db: db} do
    root = Org.personal_session_key("one")
    session(db, root, "one", %{kind: "main", is_built_in: true})
    child = session(db, "child", "one")

    assert Enum.find(Org.list_for_user(db, "one", false), &(&1.session_key == "child")) == child
    assert Enum.find(Org.list_all(db), &(&1.session_key == "child")) == child
    assert Payloads.stream_session(child)["topologyParent"] == root
    assert Payloads.stream_session(Org.get(db, root))["topologyParent"] == nil

    public = db |> StateResources.query_session("child") |> StateResources.session()
    assert public == StateResources.session(child)
    assert public["topologyParent"] == root
    assert public["spawnedBy"] == nil
    assert public["ownerUserId"] == "one"
    assert public["origin"] == "user:one"
  end

  defp session(db, key, owner, extra \\ %{}) do
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
