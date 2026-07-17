defmodule Tightbeam.Wire.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{DB, Devices, EventLog, Org}
  alias Tightbeam.Wire.Router

  setup do
    db = :"router_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    for module <- [Devices, EventLog, Org], do: :ok = module.ensure_schema(db)

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
      device: device,
      opts: [db: db, handlers: handlers, cli_token: "tbc_test", session_status: fn _ -> nil end]
    }
  end

  test "device routes require a device bearer", ctx do
    conn = Router.call(conn(:get, "/api/streams"), Router.init(ctx.opts))
    assert conn.status == 401
    assert JSON.decode!(conn.resp_body) == %{"error" => %{"code" => "auth_failed"}}

    conn = conn(:get, "/api/streams") |> put_req_header("authorization", "Bearer #{ctx.device.token}")
    conn = Router.call(conn, Router.init(ctx.opts))
    assert conn.status == 200
  end

  test "agent dispatch enforces cli bearer, allowlist, and identity/target resolution", ctx do
    Org.create(ctx.db, %{
      session_key: "orch",
      display_name: "Orchestrator",
      owner_user_id: "flynn",
      origin: "user:flynn",
      handle: "orchestrator:demo",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    body =
      JSON.encode!(%{
        verb: "wake",
        as: "orchestrator:demo",
        target: "orchestrator:demo",
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
end
