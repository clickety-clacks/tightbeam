defmodule Tightbeam.OrgTest do
  use ExUnit.Case, async: false

  doctest Tightbeam.Org

  alias Tightbeam.{DB, Org}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Org.ensure_schema(name)
    %{db: name}
  end

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      },
      overrides
    )
  end

  test "create persists provenance, wire metadata, and boolean flags", %{db: db} do
    key = Org.personal_session_key("flynn")

    session =
      Org.create(db, base(%{session_key: key, kind: "main", is_built_in: true, adopted: true}))

    assert session.session_key == "agent:main:clawline:flynn:main"

    assert %{
             archetype: "default",
        host: "testhost",
             provider: "anthropic",
             state: "active",
             is_built_in: true,
             adopted: true
           } = session

    assert Org.get(db, key).display_name == "Main"

    {:ok, rows} =
      DB.query(db, "SELECT isBuiltIn, adopted, state FROM sessions WHERE sessionKey = ?1", [key])

    assert rows == [[1, 1, "active"]]
  end

  test "custom keys use the TypeScript s_ suffix format", %{db: db} do
    session = Org.create(db, base())
    assert session.session_key =~ ~r/^agent:main:clawline:flynn:main s_[0-9a-f]{8}$/
  end

  test "list scopes active sessions by owner unless admin and preserves ordering", %{db: db} do
    Org.create(db, base(%{session_key: "k2", order_index: 2}))
    Org.create(db, base(%{session_key: "k1", order_index: 1}))
    Org.create(db, base(%{session_key: "sam", owner_user_id: "sam", origin: "user:sam"}))

    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == ["k1", "k2"]
    assert length(Org.list_for_user(db, "flynn", true)) == 3

    retired = Org.retire(db, "k1")
    assert retired.state == "retired"
    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == ["k2"]

    {:ok, [["retired"]]} = DB.query(db, "SELECT state FROM sessions WHERE sessionKey = 'k1'")
  end

  test "spawned-by provenance is retained", %{db: db} do
    Org.create(db, base(%{session_key: "root", handle: "orchestrator:news"}))

    child =
      Org.create(
        db,
        base(%{
          session_key: "child",
          origin: "agent:orchestrator:news",
          spawned_by: "root",
          archetype: "reviewer",
          harness: "codex",
          provider: "openai",
          model: "gpt-5.6-sol[high]"
        })
      )

    assert child.spawned_by == "root"
    assert child.provider == "openai"
  end

  test "rename and set_model update the row", %{db: db} do
    original = Org.create(db, base(%{session_key: "k1"}))
    renamed = Org.rename(db, "k1", "Renamed")
    updated = Org.set_model(db, "k1", "gpt-5.6-sol[high]", "openai")

    assert renamed.display_name == "Renamed"
    assert updated.model == "gpt-5.6-sol[high]"
    assert updated.provider == "openai"
    assert updated.updated_at >= original.updated_at

    {:ok, rows} =
      DB.query(db, "SELECT displayName, model, provider FROM sessions WHERE sessionKey = 'k1'")

    assert rows == [["Renamed", "gpt-5.6-sol[high]", "openai"]]
  end

  test "pointer chain is append-only and current is latest", %{db: db} do
    Org.create(db, base(%{session_key: "k1"}))
    Org.append_pointer(db, "k1", "uuid-1", "created")
    Org.append_pointer(db, "k1", "uuid-2", "loaded")
    latest = Org.append_pointer(db, "k1", "uuid-3", "fallback")

    assert Org.current_pointer(db, "k1") == latest
    assert Enum.map(Org.pointer_chain(db, "k1"), & &1.reason) == ["created", "loaded", "fallback"]

    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM harness_pointers WHERE sessionKey = 'k1'")

    assert count == 3
  end

  test "schema constraints reject invalid enums and duplicate handles", %{db: db} do
    assert_raise Tightbeam.DB.Error, ~r/CHECK constraint/, fn ->
      Org.create(db, base(%{session_key: "bad", harness: "other"}))
    end

    Org.create(db, base(%{session_key: "one", handle: "agent"}))

    assert_raise Tightbeam.DB.Error, ~r/UNIQUE constraint/, fn ->
      Org.create(db, base(%{session_key: "two", handle: "agent"}))
    end

    assert_raise ArgumentError, "unknown session: missing", fn ->
      Org.rename(db, "missing", "Nope")
    end
  end
end
