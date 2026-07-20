defmodule Tightbeam.Wire.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{Assets, DB, Devices, EventLog, Gateway, Org, Roles, Wakes}
  alias Tightbeam.Wire.Router

  setup do
    db = :"router_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [Assets, Devices, EventLog, Org, Roles, Wakes],
        do: :ok = module.ensure_schema(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-router-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)

    {:paired, device} =
      Devices.pair(db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    parent = self()

    handlers = %{
      "wake" => fn call ->
        send(parent, {:call, call})
        %{wake_id: "w_test"}
      end,
      "inspect" => fn call ->
        send(parent, {:call, call})
        %{sessions: [], wakes: []}
      end,
      "assign" => fn call ->
        send(parent, {:call, call})
        %{id: "asg_test"}
      end,
      "attest" => fn call ->
        send(parent, {:call, call})
        %{code: call.params[:return_code] || "not_holder"}
      end,
      "revoke-assignment" => fn call ->
        send(parent, {:call, call})
        %{code: call.params[:return_code] || "not_authorized"}
      end,
      "assignments" => fn call ->
        send(parent, {:call, call})
        %{assignments: []}
      end,
      "work-item-create" => fn call ->
        send(parent, {:call, call})
        %{id: "wi_test", title: call.params.title}
      end,
      "work-item-get" => fn call ->
        send(parent, {:call, call})

        if call.params[:return_code],
          do: %{code: call.params.return_code},
          else: %{workItem: %{id: call.params.work_item_id}, assignments: []}
      end,
      "work-item-list" => fn call ->
        send(parent, {:call, call})
        %{workItems: []}
      end,
      "work-item-update" => fn call ->
        send(parent, {:call, call})
        %{id: call.params.work_item_id, title: call.params[:title]}
      end
    }

    %{
      db: db,
      base_dir: base_dir,
      device: device,
      opts: [
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_test",
        session_status: fn _ -> nil end
      ]
    }
  end

  test "all work-item verbs route, preserve generic target behavior, and map unknown ids", ctx do
    target = create_session(ctx.db, "work-item-target", "flynn")

    for {verb, params} <- [
          {"work-item-create", %{title: "Create"}},
          {"work-item-get", %{workItemId: "wi_test"}},
          {"work-item-list", %{}},
          {"work-item-update", %{workItemId: "wi_test", title: "Update"}}
        ] do
      response =
        dispatch_cli(ctx, "tbc_test", %{
          verb: verb,
          asUser: "flynn",
          sessionKey: target.session_key,
          params: params
        })

      assert response.status == 200
      assert_receive {:call, %{verb: ^verb, session_key: "work-item-target"}}
    end

    missing =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "work-item-get",
        asUser: "flynn",
        params: %{workItemId: "missing", returnCode: "unknown_work_item"}
      })

    assert missing.status == 404
    assert JSON.decode!(missing.resp_body)["error"]["code"] == "unknown_work_item"
  end

  test "device routes require a device bearer", ctx do
    conn = Router.call(conn(:get, "/api/streams"), Router.init(ctx.opts))
    assert conn.status == 401
    assert JSON.decode!(conn.resp_body) == %{"error" => %{"code" => "auth_failed"}}

    conn =
      conn(:get, "/api/streams") |> put_req_header("authorization", "Bearer #{ctx.device.token}")

    conn = Router.call(conn, Router.init(ctx.opts))
    assert conn.status == 200
  end

  test "/api/streams refuses overrides as an unsupported transport", ctx do
    body =
      JSON.encode!(%{
        displayName: "Overridden",
        idempotencyKey: "unsupported-overrides",
        overrides: %{skills_add: ["review"]}
      })

    response =
      conn(:post, "/api/streams", body)
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(ctx.opts))

    assert response.status == 400

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "invalid_overrides",
               "message" => "overrides are unsupported on /api/streams; use /agent/dispatch"
             }
           }
  end

  test "agent dispatch enforces cli bearer, allowlist, and identity/target resolution", ctx do
    actor =
      Org.create(ctx.db, %{
        session_key: "orch",
        display_name: "Orchestrator",
        owner_user_id: "flynn",
        origin: "user:flynn",
        handle: "orchestrator:demo",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    Roles.create!(ctx.db, "orchestrator:demo", "flynn", actor.session_key)

    body =
      JSON.encode!(%{
        verb: "wake",
        as: "orchestrator:demo",
        role: "orchestrator:demo",
        params: %{prompt: "hi"}
      })

    unauth = Router.call(conn(:post, "/agent/dispatch", body), Router.init(ctx.opts))
    assert unauth.status == 401

    request =
      conn(:post, "/agent/dispatch", body) |> put_req_header("authorization", "Bearer tbc_test")

    response = Router.call(request, Router.init(ctx.opts))
    assert response.status == 200

    assert_receive {:call,
                    %{verb: "wake", origin: "agent:orchestrator:demo", session_key: "orch"}}

    disallowed =
      conn(:post, "/agent/dispatch", JSON.encode!(%{verb: "post", as_user: "flynn"}))
      |> put_req_header("authorization", "Bearer tbc_test")
      |> Router.call(Router.init(ctx.opts))

    assert disallowed.status == 400
  end

  test "typed target grammar distinguishes keys, users, and roles without unions", ctx do
    {:pending, _device} =
      Devices.pair(ctx.db, %{
        device_id: "mike-device",
        claimed_name: "Mike",
        platform: nil,
        model: nil
      })

    main_key = Org.personal_session_key("mike")

    Org.create(ctx.db, %{
      session_key: main_key,
      display_name: "Main",
      owner_user_id: "mike",
      origin: "user:mike",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    assert dispatch_wake(ctx, %{"userId" => "mike"}).status == 200
    assert_receive {:call, %{verb: "wake", session_key: ^main_key, target_role: nil}}

    # The type is the FIELD: "mike" as a role is a role lookup, never a user.
    bare_user = dispatch_wake(ctx, %{"role" => "mike"})
    assert bare_user.status == 404
    assert JSON.decode!(bare_user.resp_body)["error"]["message"] == "unknown role: mike"

    unknown_user = dispatch_wake(ctx, %{"userId" => "missing"})
    assert unknown_user.status == 404

    # Seam validation: retired field teaches; unions are refused.
    retired = dispatch_wake(ctx, %{"target" => "anything"})
    assert retired.status == 400
    assert JSON.decode!(retired.resp_body)["error"]["message"] =~ ~s("target" is retired)

    union = dispatch_wake(ctx, %{"role" => "x", "userId" => "mike"})
    assert union.status == 400

    assert JSON.decode!(union.resp_body)["error"]["message"] ==
             "exactly one of sessionKey, role, userId"

    key =
      Org.create(ctx.db, %{
        session_key: "agent:direct",
        display_name: "Direct",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    assert dispatch_wake(ctx, %{"sessionKey" => key.session_key}).status == 200
    assert_receive {:call, %{session_key: "agent:direct", target_role: nil}}

    unknown_key = dispatch_wake(ctx, %{"sessionKey" => "agent:missing"})
    assert unknown_key.status == 404
    assert JSON.decode!(unknown_key.resp_body)["error"]["message"] =~ "unknown sessionKey"

    Org.create(ctx.db, %{
      session_key: "role-session",
      display_name: "Role holder",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    Roles.create!(ctx.db, "mike", "flynn", "role-session")
    Roles.create!(ctx.db, "fallback", "mike", nil)

    assert dispatch_wake(ctx, %{"role" => "mike"}).status == 200

    assert_receive {:call,
                    %{
                      verb: "wake",
                      session_key: "role-session",
                      target_role: "mike",
                      role_fallback: false
                    }}

    assert dispatch_wake(ctx, %{"role" => "fallback"}).status == 200

    assert_receive {:call,
                    %{
                      session_key: ^main_key,
                      target_role: "fallback",
                      role_fallback: true
                    }}

    unknown = dispatch_wake(ctx, %{"role" => "unknown-role"})
    assert unknown.status == 404

    assert JSON.decode!(unknown.resp_body) == %{
             "error" => %{"code" => "not_found", "message" => "unknown role: unknown-role"}
           }
  end

  test "assignment typed-target teaching errors precede Dispatch and status classes are pinned",
       ctx do
    create_session(ctx.db, "holder-target", "flynn")

    missing =
      dispatch_cli(ctx, "tbc_test", %{verb: "assign", asProcess: "cron", params: %{subject: "x"}})

    assert missing.status == 400
    assert JSON.decode!(missing.resp_body)["error"]["code"] == "missing_target"

    wrong =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "assign",
        asProcess: "cron",
        userId: "flynn",
        params: %{subject: "x"}
      })

    assert wrong.status == 400
    assert JSON.decode!(wrong.resp_body)["error"]["code"] == "invalid_target_kind"

    union =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "assign",
        asProcess: "cron",
        sessionKey: "holder-target",
        role: "x",
        params: %{subject: "x"}
      })

    assert union.status == 400
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM events")

    forbidden =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "attest",
        asUser: "flynn",
        params: %{returnCode: "not_holder"}
      })

    assert forbidden.status == 403

    missing_assignment =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "attest",
        asUser: "flynn",
        params: %{returnCode: "unknown_assignment"}
      })

    assert missing_assignment.status == 404
  end

  test "org CLI reserves process:tightbeam while other process origins still attribute", ctx do
    target = create_session(ctx.db, "reserved-origin-target", "flynn")

    wake_handler = fn call ->
      wake =
        Wakes.schedule(ctx.db, %{
          session_key: call.session_key,
          target_role: nil,
          origin: call.origin,
          prompt: call.params.prompt,
          due_at: 0
        })

      send(self(), {:persisted_wake, wake})
      wake
    end

    handlers = ctx.opts |> Keyword.fetch!(:handlers) |> Map.put("wake", wake_handler)
    ctx = %{ctx | opts: Keyword.put(ctx.opts, :handlers, handlers)}

    rejected =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "wake",
        asProcess: "tightbeam",
        sessionKey: target.session_key,
        params: %{prompt: "forged"}
      })

    assert rejected.status == 403

    assert JSON.decode!(rejected.resp_body) == %{
             "error" => %{
               "code" => "reserved_origin",
               "message" => "process:tightbeam is reserved to the substrate"
             }
           }

    refute_received {:persisted_wake, _}
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM wakes")

    accepted =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "wake",
        asProcess: "ci",
        sessionKey: target.session_key,
        params: %{prompt: "build finished"}
      })

    assert accepted.status == 200
    assert_receive {:persisted_wake, %{origin: "process:ci", state: "pending"}}

    assert {:ok, [["process:ci", "pending"]]} =
             DB.query(ctx.db, "SELECT origin, state FROM wakes")
  end

  test "assign resolves bound and fallback roles and refuses unusable references", ctx do
    main = create_session(ctx.db, Org.personal_session_key("flynn"), "flynn")
    holder = create_session(ctx.db, "assign-holder", "flynn")
    retired = create_session(ctx.db, "assign-retired", "flynn")
    Roles.create!(ctx.db, "bound-assignment", "flynn", holder.session_key)
    Roles.create!(ctx.db, "fallback-assignment", "flynn", nil)
    Org.retire(ctx.db, retired.session_key)

    assert dispatch_cli(ctx, "tbc_test", %{
             verb: "assign",
             asUser: "flynn",
             role: "bound-assignment",
             params: %{subject: "x"}
           }).status == 200

    assert_receive {:call,
                    %{
                      verb: "assign",
                      session_key: "assign-holder",
                      target_role: "bound-assignment",
                      role_fallback: false
                    }}

    assert dispatch_cli(ctx, "tbc_test", %{
             verb: "assign",
             asUser: "flynn",
             role: "fallback-assignment",
             params: %{subject: "x"}
           }).status == 200

    assert_receive {:call,
                    %{
                      verb: "assign",
                      session_key: key,
                      target_role: "fallback-assignment",
                      role_fallback: true
                    }}

    assert key == main.session_key

    for body <- [
          %{verb: "assign", asUser: "flynn", role: "missing-assignment", params: %{subject: "x"}},
          %{verb: "assign", asUser: "flynn", sessionKey: "missing", params: %{subject: "x"}}
        ] do
      response = dispatch_cli(ctx, "tbc_test", body)
      assert response.status == 404
      assert JSON.decode!(response.resp_body)["error"]["code"] == "not_found"
    end

    response =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "assign",
        asUser: "flynn",
        sessionKey: retired.session_key,
        params: %{subject: "x"}
      })

    assert response.status == 400
    assert JSON.decode!(response.resp_body)["error"]["code"] == "session_retired"
  end

  test "acting as a role requires its active binding", ctx do
    holder =
      Org.create(ctx.db, %{
        session_key: "holder",
        display_name: "Holder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    Roles.create!(ctx.db, "held", "flynn", holder.session_key)
    Roles.create!(ctx.db, "vacant", "flynn", nil)

    held = dispatch_as_role(ctx, "held")
    assert held.status == 200
    assert_receive {:call, %{origin: "agent:held"}}

    vacant = dispatch_as_role(ctx, "vacant")
    assert vacant.status == 400
    assert JSON.decode!(vacant.resp_body)["error"]["message"] =~ "vacant"
  end

  test "session bearer enforces the identity ladder and threads the normative principal seam",
       ctx do
    holder = create_session(ctx.db, "holder-token", "flynn")
    sibling = create_session(ctx.db, "sibling-token", "mike")
    main = create_session(ctx.db, "main-token", "flynn", is_built_in: true, kind: "main")
    roleless = create_session(ctx.db, "roleless-token", "flynn")
    several = create_session(ctx.db, "several-token", "flynn")

    Roles.create!(ctx.db, "held", "flynn", holder.session_key)
    Roles.create!(ctx.db, "sibling", "mike", sibling.session_key)
    Roles.create!(ctx.db, "fallback", "mike", nil)
    Roles.create!(ctx.db, "alpha", "flynn", several.session_key)
    Roles.create!(ctx.db, "beta", "flynn", several.session_key)

    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", as: "held"}).status == 200
    assert_receive {:call, %{origin: "agent:held", principal: {:session, "holder-token"}}}

    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect"}).status == 200
    assert_receive {:call, %{origin: "agent:held", principal: {:session, "holder-token"}}}

    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", asUser: "flynn"}).status == 200
    assert_receive {:call, %{origin: "user:flynn", principal: {:session, "holder-token"}}}

    register_host =
      Gateway.handlers(%{
        db: ctx.db,
        base_dir: ctx.base_dir,
        default_harness: :claude,
        default_model: "fable",
        max_live_sessions_per_user: 50
      })["register-host"]

    File.mkdir_p!(ctx.base_dir)

    admin_ctx = %{
      ctx
      | opts: Keyword.update!(ctx.opts, :handlers, &Map.put(&1, "register-host", register_host))
    }

    admin =
      dispatch_cli(admin_ctx, holder.cli_token, %{
        verb: "register-host",
        asUser: "flynn",
        params: %{
          name: "worker",
          ssh: "worker",
          baseDir: "/srv/tightbeam",
          cliBin: "/srv/tightbeam/bin",
          adapterBinDir: "/srv/tightbeam/adapters"
        }
      })

    assert admin.status == 200, admin.resp_body

    assert dispatch_cli(ctx, main.cli_token, %{verb: "inspect"}).status == 200
    assert_receive {:call, %{origin: "user:flynn", principal: {:session, "main-token"}}}

    Roles.create!(ctx.db, "main-role", "flynn", main.session_key)
    assert dispatch_cli(ctx, main.cli_token, %{verb: "inspect"}).status == 200
    assert_receive {:call, %{origin: "agent:main-role", principal: {:session, "main-token"}}}

    assert dispatch_cli(ctx, "tbc_test", %{verb: "inspect", asUser: "flynn"}).status == 200
    assert_receive {:call, %{origin: "user:flynn", principal: {:user, "flynn"}}}

    assert dispatch_cli(ctx, "tbc_test", %{verb: "inspect", asProcess: "cron"}).status == 200
    assert_receive {:call, %{origin: "process:cron", principal: {:process, "cron"}}}

    assert dispatch_cli(ctx, "tbc_test", %{verb: "inspect", as: "held"}).status == 200
    assert_receive {:call, %{origin: "agent:held", principal: nil}}

    for role <- ["sibling", "fallback", "missing"] do
      response = dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", as: role})
      assert response.status == 403
      error = JSON.decode!(response.resp_body)["error"]
      assert error["code"] == "role_not_held"
      assert error["message"] =~ role
      assert error["message"] =~ "held"
    end

    wrong_user =
      dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", asUser: "mike"})

    assert wrong_user.status == 403

    assert JSON.decode!(wrong_user.resp_body)["error"] == %{
             "code" => "identity_not_yours",
             "message" => "this session belongs to flynn"
           }

    process = dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", asProcess: "cron"})
    assert process.status == 403
    assert JSON.decode!(process.resp_body)["error"]["code"] == "identity_not_yours"

    {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM events")
    no_role = dispatch_cli(ctx, roleless.cli_token, %{verb: "inspect"})
    assert no_role.status == 403
    assert JSON.decode!(no_role.resp_body)["error"]["code"] == "no_role"
    {:ok, [[after_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM events")
    assert after_count == before_count

    ambiguous = dispatch_cli(ctx, several.cli_token, %{verb: "inspect"})
    assert ambiguous.status == 400
    assert JSON.decode!(ambiguous.resp_body)["error"]["code"] == "ambiguous_identity"
    assert ambiguous.resp_body =~ "alpha"
    assert ambiguous.resp_body =~ "beta"

    assert dispatch_cli(ctx, "tbs_unknown", %{verb: "inspect"}).status == 401
    Org.retire(ctx.db, holder.session_key)
    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect"}).status == 401

    {:ok, principals} =
      DB.query(ctx.db, "SELECT principal FROM events ORDER BY id")

    assert ["session:holder-token"] in principals
    assert ["session:main-token"] in principals
    assert ["user:flynn"] in principals
    assert ["process:cron"] in principals
    assert [nil] in principals

    refute Enum.any?(principals, fn [value] ->
             is_binary(value) and String.contains?(value, "tbs_")
           end)
  end

  test "multipart upload returns asset metadata", ctx do
    response =
      ctx
      |> upload_conn(ctx.device, "hello-bytes", "pic.png", "image/png")
      |> Router.call(Router.init(ctx.opts))

    assert response.status == 200
    body = JSON.decode!(response.resp_body)
    assert body["assetId"] =~ ~r/^a_/
    assert body["mimeType"] == "image/png"
    assert body["size"] == 11
  end

  test "upload rejects files over 32 MiB", ctx do
    response =
      ctx
      |> upload_conn(
        ctx.device,
        :binary.copy(<<0>>, 32 * 1024 * 1024 + 1),
        "large.bin",
        "application/octet-stream"
      )
      |> Router.call(Router.init(ctx.opts))

    assert response.status == 413
    assert JSON.decode!(response.resp_body) == %{"error" => %{"code" => "payload_too_large"}}
  end

  test "upload rejects a missing file field", ctx do
    request =
      conn(:post, "/upload", %{"other" => "value"})
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")

    response = Router.call(request, Router.init(ctx.opts))
    assert response.status == 400

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "invalid_message",
               "message" => "multipart field 'file' required"
             }
           }
  end

  test "download is owner-scoped with admin override", ctx do
    other = approved_device(ctx.db, "d2", "Other")
    stranger = approved_device(ctx.db, "d3", "Stranger")

    upload =
      ctx
      |> upload_conn(other, "private-bytes", "private.txt", "text/plain")
      |> Router.call(Router.init(ctx.opts))

    asset_id = JSON.decode!(upload.resp_body)["assetId"]

    owner = download(ctx, other, asset_id)
    assert owner.status == 200
    assert get_resp_header(owner, "content-type") == ["text/plain"]
    assert owner.resp_body == "private-bytes"

    denied = download(ctx, stranger, asset_id)
    assert denied.status == 404
    assert JSON.decode!(denied.resp_body) == %{"error" => %{"code" => "not_found"}}

    admin = download(ctx, ctx.device, asset_id)
    assert admin.status == 200
    assert admin.resp_body == "private-bytes"
  end

  defp upload_conn(ctx, device, data, filename, content_type) do
    path = Path.join(ctx.base_dir, "upload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ctx.base_dir)
    File.write!(path, data)

    upload = %Plug.Upload{path: path, filename: filename, content_type: content_type}

    conn(:post, "/upload", %{"file" => upload})
    |> put_req_header("authorization", "Bearer #{device.token}")
  end

  defp approved_device(db, device_id, name) do
    {:pending, pending} =
      Devices.pair(db, %{device_id: device_id, claimed_name: name, platform: nil, model: nil})

    Devices.approve(db, pending.device_id)
  end

  defp download(ctx, device, asset_id) do
    conn(:get, "/download/#{asset_id}")
    |> put_req_header("authorization", "Bearer #{device.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp dispatch_wake(ctx, fields) when is_map(fields) do
    body =
      JSON.encode!(
        Map.merge(
          %{"verb" => "wake", "asUser" => "flynn", "params" => %{"prompt" => "hi"}},
          fields
        )
      )

    conn(:post, "/agent/dispatch", body)
    |> put_req_header("authorization", "Bearer tbc_test")
    |> Router.call(Router.init(ctx.opts))
  end

  defp dispatch_as_role(ctx, role) do
    body =
      JSON.encode!(%{
        "verb" => "inspect",
        "as" => role,
        "params" => %{}
      })

    conn(:post, "/agent/dispatch", body)
    |> put_req_header("authorization", "Bearer tbc_test")
    |> Router.call(Router.init(ctx.opts))
  end

  defp dispatch_cli(ctx, bearer, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(Map.put_new(body, :params, %{})))
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp create_session(db, key, owner, extra \\ []) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable",
      is_built_in: Keyword.get(extra, :is_built_in, false),
      kind: Keyword.get(extra, :kind, "custom")
    })
  end
end
