defmodule Tightbeam.Wire.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{Assets, DB, Devices, EventLog, Org, Roles}
  alias Tightbeam.Wire.Router

  setup do
    db = :"router_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    for module <- [Assets, Devices, EventLog, Org, Roles], do: :ok = module.ensure_schema(db)

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
end
