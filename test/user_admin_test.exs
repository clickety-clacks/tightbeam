defmodule Tightbeam.UserAdminTest do
  use Tightbeam.TestCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{Assets, DB, Devices, Dispatch, Gateway, Model, Org, Roles, Schema, Toplines}
  alias Tightbeam.UserAdmin
  alias Tightbeam.SchemaShapeRuntimeFixture
  alias Tightbeam.Wire.{OperatorSession, Router}

  # Synthetic users only: "admin" is the cold-start admin, "guest" an ordinary user.
  setup do
    db = :"user_admin_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-user-admin-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)

    {:paired, admin_device} = pair(db, "admin-dev", "admin")
    handlers = Gateway.handlers(%{db: db, base_dir: base_dir})
    ctx = %{db: db, base_dir: base_dir, handlers: handlers, admin_device: admin_device}

    assert {:ok, _} = run(ctx, "add-user", "admin", %{user_id: "guest", is_admin: false})
    assert {:pending, _} = pair(db, "guest-dev", "guest")
    guest_device = Devices.approve(db, "guest-dev")
    assert guest_device.status == "allowlisted"

    Map.put(ctx, :guest_device, guest_device)
  end

  describe "R1/R2 users" do
    test "lists every user with provenance, devices, activity and owned counts", ctx do
      assert {:ok, %{users: rows}} = run(ctx, "users", "admin", %{})
      assert Enum.map(rows, & &1["userId"]) == ["admin", "guest"]
      [admin, guest] = rows

      assert %{
               "isAdmin" => true,
               "effectiveAdmin" => true,
               "state" => "active",
               "removedAt" => nil,
               "removedBy" => nil,
               "creation" => nil,
               "creationNote" => "no accepted add-user audit event",
               "devices" => %{"allowlisted" => 1, "pending" => 0, "denied" => 0}
             } = admin

      assert admin["actedAs"]["count"] >= 1

      assert %{
               "isAdmin" => false,
               "effectiveAdmin" => false,
               "state" => "active",
               "creation" => %{"principal" => "user:admin", "origin" => "user:admin"},
               "devices" => %{"allowlisted" => 1, "pending" => 0, "denied" => 0},
               "actedAs" => %{"count" => 0, "firstAt" => nil, "lastAt" => nil}
             } = guest

      refute Map.has_key?(guest, "creationNote")
      assert is_integer(guest["creation"]["eventId"])
      assert guest["owned"]["total"] == 0
      assert Enum.sort(Map.keys(guest["owned"])) == Enum.sort(owned_keys())

      rendered = inspect(rows)
      refute rendered =~ ctx.admin_device.token
      refute rendered =~ ctx.guest_device.token
      refute rendered =~ "admin-dev"
      refute rendered =~ "guest-dev"
    end

    test "a non-admin is refused with no user data", ctx do
      assert {:error, %{code: "forbidden"} = refusal} = run(ctx, "users", "guest", %{})
      refute Map.has_key?(refusal, :users)

      before = users_table(ctx.db)

      assert {:error, %{code: "forbidden"}} =
               run(ctx, "remove-user", "guest", %{user_id: "admin"})

      assert users_table(ctx.db) == before
    end
  end

  describe "R3/R4/R7 remove-user" do
    test "stamps removal in place, keeps history and leaks no token", ctx do
      assert {:ok, %{user: row}} = run(ctx, "remove-user", "admin", %{user_id: "guest"})

      assert %{
               "userId" => "guest",
               "state" => "removed",
               "removedBy" => "user:admin",
               "effectiveAdmin" => false
             } = row

      assert is_integer(row["removedAt"])

      assert %{removed_at: removed_at, removed_by: "user:admin"} = Devices.user(ctx.db, "guest")
      assert removed_at == row["removedAt"]

      # R4: the users row, its device and the add-user audit event all remain.
      assert Devices.by_id(ctx.db, "guest-dev").user_id == "guest"

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM events WHERE kind='verb' AND verb='add-user'"
               )

      assert {:ok, %{users: rows}} = run(ctx, "users", "admin", %{})
      states = Map.new(rows, &{&1["userId"], &1["state"]})
      assert states == %{"admin" => "active", "guest" => "removed"}
      assert Enum.find(rows, &(&1["userId"] == "guest"))["creation"]["principal"] == "user:admin"

      # R7: neither the result nor the audit row carries a token.
      assert {:ok, [[payload]]} =
               DB.query(
                 ctx.db,
                 "SELECT payload FROM events WHERE kind='verb' AND verb='remove-user'"
               )

      for text <- [payload, inspect(row)] do
        refute text =~ ctx.guest_device.token
        refute text =~ ctx.admin_device.token
        refute text =~ "tbt_"
      end
    end
  end

  describe "R5 after removal" do
    setup ctx do
      assert {:ok, _} = run(ctx, "remove-user", "admin", %{user_id: "guest"})
      :ok
    end

    test "no device of the removed user authenticates or obtains a token", ctx do
      assert Devices.by_token(ctx.db, ctx.guest_device.token) == nil
      assert {:refused, "user_removed"} = pair(ctx.db, "guest-dev", "guest")
      assert {:refused, "user_removed"} = pair(ctx.db, "guest-new-dev", "guest")
      assert Devices.by_id(ctx.db, "guest-new-dev") == nil
      assert Devices.by_id(ctx.db, "guest-dev").user_removed
    end

    test "writes naming the removed user are refused and write nothing", ctx do
      assert {:pending, _} = pair(ctx.db, "other-dev", "other")
      before = users_table(ctx.db)

      for {verb, params} <- [
            {"add-user", %{user_id: "guest", is_admin: false}},
            {"promote-user", %{user_id: "guest", is_admin: true}},
            {"approve-device", %{device_id: "other-dev", user_id: "guest"}}
          ] do
        assert {:error, %{code: "user_removed", message: message}} =
                 run(ctx, verb, "admin", params)

        assert message =~ "guest"
      end

      assert users_table(ctx.db) == before
      assert Devices.by_id(ctx.db, "other-dev").status == "pending"
    end

    test "a stored admin bit confers no standing once removed", ctx do
      assert {:ok, _} = run(ctx, "add-user", "admin", %{user_id: "deputy", is_admin: true})
      assert {:ok, _} = run(ctx, "remove-user", "admin", %{user_id: "deputy"})

      assert %{is_admin: false, stored_admin: true} = Devices.user(ctx.db, "deputy")
      assert {:error, %{code: "forbidden"}} = run(ctx, "users", "deputy", %{})

      assert {:ok, %{users: rows}} = run(ctx, "users", "admin", %{})

      assert %{"isAdmin" => true, "effectiveAdmin" => false} =
               Enum.find(rows, &(&1["userId"] == "deputy"))
    end

    test "an organization credential cannot select the removed user", ctx do
      opts = router_opts(ctx)

      for body <- [
            %{verb: "wake", asUser: "guest", params: %{prompt: "x"}},
            %{verb: "work-item-create", asUser: "guest", params: %{title: "x"}}
          ] do
        response = dispatch_cli(opts, body)
        assert response.status == 403
        assert %{"code" => "user_removed"} = JSON.decode!(response.resp_body)["error"]
      end

      for path <- ["/api/config?asUser=guest", "/api/sessions?asUser=guest"] do
        response = get_org(opts, path)
        assert response.status == 403
        assert %{"code" => "user_removed"} = JSON.decode!(response.resp_body)["error"]
      end

      assert {:error, "user_removed"} = OperatorSession.resolve_user(ctx.db, "guest")
      refute_received {:call, _}
    end

    test "a write naming the removed user as owner is refused; a filtered read is not", ctx do
      opts = router_opts(ctx)

      response =
        dispatch_cli(opts, %{
          verb: "work-item-create",
          asUser: "admin",
          params: %{title: "x", ownerUserId: "guest"}
        })

      assert response.status == 403
      assert %{"code" => "user_removed"} = JSON.decode!(response.resp_body)["error"]
      refute_received {:call, %{verb: "work-item-create"}}

      response =
        dispatch_cli(opts, %{
          verb: "work-item-list",
          asUser: "admin",
          params: %{ownerUserId: "guest"}
        })

      assert response.status == 200
      assert_received {:call, %{verb: "work-item-list"}}
    end
  end

  describe "R6 refusals" do
    test "each refusal names its reason and writes nothing", ctx do
      process_call = %{
        verb: "remove-user",
        origin: "process:fixture",
        session_key: nil,
        principal: {:process, "fixture"},
        params: %{user_id: "guest"}
      }

      before = users_table(ctx.db)

      assert {:error, %{code: "forbidden"}} =
               Dispatch.dispatch(ctx.db, ctx.handlers, process_call)

      assert {:error, %{code: "user_not_found"}} =
               run(ctx, "remove-user", "admin", %{user_id: "nobody"})

      assert {:error, %{code: "cannot_remove_self"}} =
               run(ctx, "remove-user", "admin", %{user_id: "admin"})

      assert users_table(ctx.db) == before

      assert {:ok, _} = run(ctx, "remove-user", "admin", %{user_id: "guest"})
      removed = users_table(ctx.db)

      assert {:error, %{code: "user_already_removed"}} =
               run(ctx, "remove-user", "admin", %{user_id: "guest"})

      assert users_table(ctx.db) == removed
    end

    test "a user owning a row of every kind is refused, every kind listed, nothing moved", ctx do
      assert {:ok, _} = run(ctx, "add-user", "admin", %{user_id: "owner", is_admin: false})
      seed_owned_rows!(ctx, "owner")
      before = users_table(ctx.db)
      {:ok, toplines} = DB.query(ctx.db, "SELECT id, ownerUserId FROM toplines ORDER BY id")

      assert {:error, %{code: "user_owns_rows", message: message}} =
               run(ctx, "remove-user", "admin", %{user_id: "owner"})

      assert message =~ "nothing was reassigned"

      for key <- UserAdmin.ownership_keys(), key != "decision_requests.expecterUserId(open)" do
        assert message =~ key <> ": "
      end

      # The closed topline counts as much as the open one.
      assert message =~ "toplines.ownerUserId: 2 (tl_owner_closed, tl_owner_open)"
      assert users_table(ctx.db) == before
      assert {:ok, ^toplines} =
               DB.query(ctx.db, "SELECT id, ownerUserId FROM toplines ORDER BY id")

      assert {:ok, %{users: rows}} = run(ctx, "users", "admin", %{})
      owned = Enum.find(rows, &(&1["userId"] == "owner"))["owned"]
      assert owned["total"] >= length(UserAdmin.ownership_keys()) - 1
    end

    test "an open request expecting the user blocks removal until it is not open", ctx do
      sql!(
        ctx.db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, raiserSessionKey, ownerUserId,
           expecterSessionKey, expecterUserId, raisedAt, question, context,
           status, askedOfRole)
        VALUES ('dr_expecting', 'agent', 'session:agent:raiser:app', 'agent:raiser:app',
                'admin', 'agent:raiser:app', 'guest', 1, 'Answer?', '{}', 'open', 'coder:x')
        """
      )

      assert {:error, %{code: "user_owns_rows", message: message}} =
               run(ctx, "remove-user", "admin", %{user_id: "guest"})

      assert message =~ "decision_requests.expecterUserId(open): 1 (dr_expecting)"

      sql!(
        ctx.db,
        "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = 'user:admin', " <>
          "withdrawnReason = 'synthetic', withdrawnAt = 2 WHERE id = 'dr_expecting'"
      )

      assert {:ok, %{user: %{"state" => "removed"}}} =
               run(ctx, "remove-user", "admin", %{user_id: "guest"})
    end

    test "a user named only in attribution fields is removable and keeps them", ctx do
      work_item!(ctx.db, "wi_attributed", "admin", "guest")

      assert {:ok, %{user: %{"state" => "removed"}}} =
               run(ctx, "remove-user", "admin", %{user_id: "guest"})

      assert {:ok, [["admin", "guest"]]} =
               DB.query(
                 ctx.db,
                 "SELECT ownerUserId, createdByUser FROM work_items WHERE id = 'wi_attributed'"
               )
    end
  end

  describe "R9 upgrade" do
    test "initialization upgrades the predecessor users table and keeps every row", ctx do
      SchemaShapeRuntimeFixture.downgrade_user_removal!(ctx.db)

      assert {:ok, [["session-identity-v1-0114"]]} =
               DB.query(ctx.db, "SELECT shape FROM schema_stamp")

      assert {:ok, [["userId"], ["isAdmin"], ["createdAt"]]} =
               DB.query(ctx.db, "SELECT name FROM pragma_table_info('users') ORDER BY cid")

      {:ok, users} = DB.query(ctx.db, "SELECT * FROM users ORDER BY userId")
      {:ok, devices} = DB.query(ctx.db, "SELECT * FROM devices ORDER BY deviceId")
      {:ok, events} = DB.query(ctx.db, "SELECT * FROM events ORDER BY id")

      for _boot <- 1..2 do
        assert :ok = Schema.ensure_all(ctx.db)

        assert {:ok, [["user-removal-v1-0114"]]} =
                 DB.query(ctx.db, "SELECT shape FROM schema_stamp")

        assert {:ok, ^users} =
                 DB.query(ctx.db, "SELECT userId, isAdmin, createdAt FROM users ORDER BY userId")

        assert {:ok, [[0]]} =
                 DB.query(
                   ctx.db,
                   "SELECT COUNT(*) FROM users WHERE removedAt IS NOT NULL OR removedBy IS NOT NULL"
                 )

        assert {:ok, ^devices} = DB.query(ctx.db, "SELECT * FROM devices ORDER BY deviceId")
        assert {:ok, ^events} = DB.query(ctx.db, "SELECT * FROM events ORDER BY id")
      end

      assert {:ok, %{user: %{"state" => "removed"}}} =
               run(ctx, "remove-user", "admin", %{user_id: "guest"})
    end
  end

  defp run(ctx, verb, actor, params) do
    Dispatch.dispatch(ctx.db, ctx.handlers, %{
      verb: verb,
      origin: "user:#{actor}",
      session_key: nil,
      principal: {:user, actor},
      params: params
    })
  end

  defp pair(db, device_id, claimed_name) do
    Devices.pair(db, %{
      device_id: device_id,
      claimed_name: claimed_name,
      platform: nil,
      model: nil
    })
  end

  # One synthetic row per spec §3 ownership column, plus a closed topline.
  defp seed_owned_rows!(ctx, owner) do
    db = ctx.db
    session = "agent:owner-session:app"

    Org.create(db, %{
      session_key: session,
      display_name: "Owner session",
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    Roles.create!(db, "owner-po", owner, session)
    work_item!(db, "wi_owner", owner)

    sql!(
      db,
      """
      INSERT INTO toplines
        (id, ownerUserId, title, state, createdActorKind, createdActorRef,
         createdAt, updatedAt, closedAt)
      VALUES ('tl_owner_open', ?1, 'Open', 'open', 'user', ?1, 1, 1, NULL),
             ('tl_owner_closed', ?1, 'Closed', 'closed', 'user', ?1, 1, 2, 2)
      """,
      [owner]
    )

    sql!(
      db,
      """
      INSERT INTO topline_work_memberships
        (id, toplineId, workItemId, ownerUserId, linkReason,
         linkedActorKind, linkedActorRef, linkedAt)
      VALUES ('tlm_owner', 'tl_owner_open', 'wi_owner', ?1, 'synthetic', 'user', ?1, 1)
      """,
      [owner]
    )

    sql!(
      db,
      """
      INSERT INTO wakes
        (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt, ownerUserId)
      VALUES ('w_owner', ?1, 'process:tightbeam', 'Choose placement', 'prompt', 40,
              'pending', 40, ?2)
      """,
      [session, owner]
    )

    {:ok, _} =
      DB.transaction(db, fn txn ->
        Toplines.open_placement_in_txn(txn, %{
          id: "tlp_owner",
          work_item_id: "wi_owner",
          owner_user_id: owner,
          cause: "created",
          cause_ref: "wi_owner",
          source_causal_event_seq: nil,
          actor_kind: "user",
          actor_ref: owner,
          at: 40,
          prompt_wake_id: "w_owner"
        })
      end)

    sql!(
      db,
      """
      INSERT INTO session_po_associations
        (sessionKey, ownerUserId, poRole, revision, noticeWakeId, setBy, cause,
         createdAt, updatedAt)
      VALUES (?1, ?2, 'owner-po', 1, 'w_owner', ?3, 'explicit_set', 1, 1)
      """,
      [session, owner, "user:#{owner}"]
    )

    Assets.put(db, ctx.base_dir, owner, "image/png", "pic.png", "synthetic-bytes")

    sql!(
      db,
      "INSERT INTO condition_facts (ts, kind, scope, origin, ownerUserId) " <>
        "VALUES (1, 'synthetic-ready', 'synthetic', ?1, ?2)",
      ["user:#{owner}", owner]
    )

    sql!(
      db,
      """
      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName,
         actionKey, question, context, status)
      VALUES ('dr_owner', 'statute', ?1, ?2, 1, 60001, 'synthetic', 'read',
              'Allow?', '{}', 'open')
      """,
      ["user:#{owner}", owner]
    )
  end

  defp work_item!(db, id, owner, creator \\ nil) do
    sql!(
      db,
      """
      INSERT INTO work_items
        (id, title, ownerUserId, state, createdByUser, createdContextKnown, createdAt)
      VALUES (?1, ?2, ?3, 'open', ?4, 1, 1)
      """,
      [id, "Work #{id}", owner, creator || owner]
    )

    sql!(db, "INSERT INTO work_item_versions (workItemId, rowVersion) VALUES (?1, 1)", [id])
  end

  defp sql!(db, sql, params \\ []) do
    {:ok, _} = DB.query(db, sql, params)
    :ok
  end

  defp users_table(db) do
    {:ok, rows} = DB.query(db, "SELECT * FROM users ORDER BY userId")
    rows
  end

  defp owned_keys, do: UserAdmin.ownership_keys() ++ ["total"]

  # The router reaches recording stubs, so a refused request is one that never
  # reaches its handler.
  defp router_opts(ctx) do
    parent = self()

    record = fn result ->
      fn call ->
        send(parent, {:call, call})
        result
      end
    end

    [
      db: ctx.db,
      base_dir: ctx.base_dir,
      cli_token: "tbc_test",
      session_status: fn _ -> nil end,
      handlers: %{
        "wake" => record.(%{wake_id: "w_test"}),
        "work-item-create" => record.(%{id: "wi_test"}),
        "work-item-list" => record.(%{workItems: []})
      }
    ]
  end

  defp dispatch_cli(opts, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(body))
    |> put_req_header("authorization", "Bearer tbc_test")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(opts))
  end

  defp get_org(opts, path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer tbc_test")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(opts))
  end
end
