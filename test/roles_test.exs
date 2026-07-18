defmodule Tightbeam.RolesTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{DB, Org, Roles}

  setup do
    db = :"roles_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = Roles.ensure_schema(db)
    %{db: db}
  end

  test "create validates names, uniqueness, and active bindings", %{db: db} do
    active = session(db, "agent:active", "flynn")
    retired = session(db, "agent:retired", "flynn") |> then(&Org.retire(db, &1.session_key))

    assert %{name: "builder", bound_session_key: nil, owner_user_id: "flynn"} =
             Roles.create!(db, "builder", "flynn", nil)

    assert %{name: "review:lead", bound_session_key: "agent:active"} =
             Roles.create!(db, "review:lead", "flynn", active.session_key)

    assert {:error, %{code: "role_exists"}} = Roles.create!(db, "builder", "flynn", nil)
    assert {:error, %{code: "invalid_role_name"}} = Roles.create!(db, "Bad_Name", "flynn", nil)

    assert {:error, %{code: "invalid_role_name", message: agent_message}} =
             Roles.create!(db, "agent:reserved", "flynn", nil)

    assert agent_message =~ "reserved agent:"

    assert {:error, %{code: "invalid_role_name", message: user_message}} =
             Roles.create!(db, "user:reserved", "flynn", nil)

    assert user_message =~ "reserved user:"

    assert {:error, %{code: "unknown_session"}} =
             Roles.create!(db, "missing", "flynn", "agent:missing")

    assert {:error, %{code: "unknown_session"}} =
             Roles.create!(db, "retired", "flynn", retired.session_key)
  end

  test "bind, remove, get, and sorted list return every documented branch", %{db: db} do
    session(db, "agent:a", "flynn")
    retired = session(db, "agent:r", "flynn") |> then(&Org.retire(db, &1.session_key))
    Roles.create!(db, "zeta", "flynn", nil)
    Roles.create!(db, "alpha", "flynn", nil)

    assert Roles.get(db, "missing") == nil
    assert Enum.map(Roles.list(db), & &1.name) == ["alpha", "zeta"]
    assert {:error, %{code: "unknown_role"}} = Roles.bind(db, "missing", "agent:a")
    assert {:error, %{code: "unknown_session"}} = Roles.bind(db, "alpha", "agent:missing")
    assert {:error, %{code: "unknown_session"}} = Roles.bind(db, "alpha", retired.session_key)
    assert :ok = Roles.bind(db, "alpha", "agent:a")
    assert Roles.get(db, "alpha").bound_session_key == "agent:a"
    assert {:error, %{code: "unknown_role"}} = Roles.rm(db, "missing")
    assert :ok = Roles.rm(db, "alpha")
    assert Roles.get(db, "alpha") == nil
  end

  test "resolution pins active bindings and falls back for every other incarnation", %{db: db} do
    main = Org.personal_session_key("flynn")
    session(db, main, "flynn")
    active = session(db, "agent:held", "flynn")
    stale = session(db, "agent:stale", "flynn")

    Roles.create!(db, "unbound", "flynn", nil)
    Roles.create!(db, "held", "flynn", active.session_key)
    Roles.create!(db, "stale", "flynn", stale.session_key)

    assert {:ok, active.session_key, false} == Roles.resolve(db, "held")
    assert {:ok, main, true} == Roles.resolve(db, "unbound")

    Org.retire(db, stale.session_key)
    assert {:ok, main, true} == Roles.resolve(db, "stale")

    {:ok, _} = DB.query(db, "DELETE FROM sessions WHERE sessionKey = ?1", [stale.session_key])
    assert {:ok, main, true} == Roles.resolve(db, "stale")
    assert {:error, %{code: "unknown_role"}} = Roles.resolve(db, "missing")
  end

  defp session(db, session_key, owner) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })
  end
end
