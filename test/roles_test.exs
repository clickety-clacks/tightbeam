defmodule Tightbeam.RolesTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{DB, Org, Roles}

  setup do
    db = :"roles_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    %{db: db}
  end

  test "Firehose role mutations publish through real Dispatch with owner-bound payloads", %{
    db: db
  } do
    alias Tightbeam.{Dispatch, Gateway, Firehose.Hub}
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('flynn',0,1)")
    session(db, Org.personal_session_key("flynn"), "flynn")
    target = session(db, "agent:role-target", "flynn")
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: false})
    handlers = Gateway.handlers(%{db: db})
    call = %{origin: "user:flynn", principal: {:user, "flynn"}, session_key: nil}

    for {verb, params, class} <- [
          {"role-create", %{name: "firehose-role"}, "role.created"},
          {"role-bind", %{name: "firehose-role", session_key: target.session_key}, "role.bound"},
          {"role-rm", %{name: "firehose-role"}, "role.removed"}
        ] do
      assert {:ok, _} =
               Dispatch.dispatch(db, handlers, Map.merge(call, %{verb: verb, params: params}))

      assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
      Hub.delivered(hub, self())
      assert_receive {:firehose_notice, %{"class" => ^class, "payload" => payload}}
      assert payload["name"] == "firehose-role"
      assert payload["ownerUserId"] == "flynn"
      if verb == "role-bind", do: assert(payload["boundSessionKey"] == target.session_key)
      Hub.delivered(hub, self())
      refute_receive {:firehose_notice, _}
    end

    assert Roles.get(db, "firehose-role") == nil

    silent_call =
      Map.merge(call, %{verb: "role-bind", params: %{name: "missing"}, firehose_in_txn: true})

    assert {:error, %{code: "unknown_role"}} =
             Roles.bind_with_firehose(db, "missing", target.session_key, silent_call)

    refute_receive {:firehose_notice, _}
  end

  test "Firehose role boundaries retain cross-tenant refusal and deletion rollback", %{db: db} do
    alias Tightbeam.{Dispatch, Gateway, Firehose.Hub}

    for user <- ["flynn", "other"] do
      {:ok, []} =
        DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES(?1,0,1)", [user])

      session(db, Org.personal_session_key(user), user)
    end

    target = session(db, "agent:other-target", "other")
    Roles.create!(db, "protected-role", "flynn", nil)
    before = Roles.get(db, "protected-role")
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: false})
    handlers = Gateway.handlers(%{db: db})

    for {user, verb, params} <- [
          {"other", "role-rm", %{name: "protected-role"}},
          {"flynn", "role-bind", %{name: "protected-role", session_key: target.session_key}}
        ] do
      call = %{
        verb: verb,
        origin: "user:" <> user,
        principal: {:user, user},
        session_key: nil,
        params: params
      }

      assert {:error, %{code: "denied"}} = Dispatch.dispatch(db, handlers, call)
      assert Roles.get(db, "protected-role") == before
    end

    # Discard no messages: inspect all delivered observations while acknowledging
    # the flow-controlled Hub, rejecting any state publication.
    for _ <- 1..2 do
      receive do
        {:firehose_notice, notice} ->
          assert notice["class"] == "verb.denied"
          Hub.delivered(hub, self())
      after
        100 -> :ok
      end
    end

    refute_receive {:firehose_notice, _}

    :ok =
      DB.execute(
        db,
        "CREATE TRIGGER role_delete_abort AFTER DELETE ON roles BEGIN SELECT RAISE(ABORT, 'synthetic role rollback'); END"
      )

    call = %{
      verb: "role-rm",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{name: "protected-role"},
      firehose_in_txn: true
    }

    failure =
      try do
        Roles.rm_with_firehose(db, "protected-role", call)
        :unexpected_success
      rescue
        error -> Exception.message(error)
      end

    assert is_binary(failure)
    assert failure =~ "synthetic role rollback"
    assert Roles.get(db, "protected-role") == before
    refute_receive {:firehose_notice, _}
  end

  test "create validates names, uniqueness, and active bindings", %{db: db} do
    active = session(db, "agent:active", "flynn")

    retired =
      session(db, "agent:retired", "flynn")
      |> then(&Org.retire(db, &1.session_key, "user:flynn", 1_000))

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

    retired =
      session(db, "agent:r", "flynn")
      |> then(&Org.retire(db, &1.session_key, "user:flynn", 1_000))

    Roles.create!(db, "zeta", "flynn", nil)
    Roles.create!(db, "alpha", "flynn", nil)

    assert Roles.get(db, "missing") == nil
    assert Enum.map(Roles.list(db), & &1.name) == ["alpha", "zeta"]
    assert {:error, %{code: "unknown_role"}} = Roles.bind(db, "missing", "agent:a")
    assert {:error, %{code: "unknown_session"}} = Roles.bind(db, "alpha", "agent:missing")
    assert {:error, %{code: "unknown_session"}} = Roles.bind(db, "alpha", retired.session_key)
    assert :ok = Roles.bind(db, "alpha", "agent:a")
    assert Roles.get(db, "alpha").bound_session_key == "agent:a"
    assert {:error, %{code: "unknown_session"}} = Roles.bind(db, "alpha", nil)
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

    Org.retire(db, stale.session_key, "user:flynn", 1_000)
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
      model: Model.new("fable")
    })
  end
end
