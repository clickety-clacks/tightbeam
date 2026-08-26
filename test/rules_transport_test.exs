defmodule Tightbeam.RulesTransportTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{ConnRegistry, DB, EventLog, Org, Roles, Rules}
  alias Tightbeam.Wire.{Router, Socket}

  setup do
    db = :"rules_transport_db_#{System.unique_integer([:positive])}"
    registry = :"rules_transport_registry_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: registry})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "CREATE TABLE domain_mutations (transport TEXT NOT NULL)")

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-rule-transports-#{System.unique_integer([:positive])}"
      )

    rules_dir = Path.join(base_dir, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "denials.toml"), """
    [[rule]]
    name = "ws-denial"
    verb = "post"
    text = "websocket denied"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]

    [[rule]]
    name = "rest-denial"
    verb = "spawn"
    text = "rest denied"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]

    [[rule]]
    name = "agent-denial"
    verb = "inspect"
    text = "agent denied"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
    """)

    Rules.load!(base_dir, ["post", "spawn", "inspect"])
    parent = self()

    handlers =
      Map.new(["post", "spawn", "inspect", "tune"], fn verb ->
        {verb,
         fn _call ->
           send(parent, {:handler_invoked, verb})
           {:ok, _} = DB.query(db, "INSERT INTO domain_mutations VALUES (?1)", [verb])
           %{ok: true}
         end}
      end)

    device = allowlisted_device(db, "d1", "flynn", true)

    main =
      Org.create(db, %{
        session_key: Org.personal_session_key(device.user_id),
        display_name: "Main",
        kind: "main",
        is_built_in: true,
        owner_user_id: device.user_id,
        origin: "user:#{device.user_id}",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    actor =
      Org.create(db, %{
        session_key: "actor",
        display_name: "Actor",
        owner_user_id: device.user_id,
        origin: "user:#{device.user_id}",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(db, "operator", device.user_id, actor.session_key)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-rules-reset", [])
    end)

    router_opts = [
      db: db,
      base_dir: base_dir,
      handlers: handlers,
      cli_token: "tbc_test",
      session_status: fn _ -> nil end
    ]

    socket_deps = %{
      db: db,
      conn_registry: registry,
      handlers: handlers,
      defaults: %{
        archetype: "default",
        host: "testhost",
        harness: :claude,
        provider: :anthropic,
        model: Model.new("fable")
      },
      ping_interval_ms: 60_000,
      pong_timeout_ms: 60_000
    }

    %{
      db: db,
      device: device,
      main: main,
      router_opts: router_opts,
      socket_deps: socket_deps
    }
  end

  test "WS post, REST, and agent dispatch each deny before handlers with one audit row", ctx do
    {:ok, socket} = Socket.init(ctx.socket_deps)
    auth = %{"type" => "auth", "token" => ctx.device.token, "deviceId" => ctx.device.device_id}
    {:push, _frames, replaying} = Socket.handle_in({JSON.encode!(auth), opcode: :text}, socket)
    {:push, _frames, live} = Socket.handle_info(:finish_replay, replaying)

    message = %{
      "type" => "message",
      "id" => "c_denied",
      "content" => "no mutation",
      "sessionKey" => ctx.main.session_key
    }

    {:push, {:text, ws_frame}, _live} =
      Socket.handle_in({JSON.encode!(message), opcode: :text}, live)

    assert %{
             "type" => "error",
             "code" => "rule_denied",
             "message" => "ws-denial: websocket denied"
           } =
             JSON.decode!(ws_frame)

    rest_request =
      conn(
        :post,
        "/api/streams",
        JSON.encode!(%{displayName: "Denied", idempotencyKey: "idem-1"})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")

    rest_response = Router.call(rest_request, Router.init(ctx.router_opts))
    assert rest_response.status == 400
    assert JSON.decode!(rest_response.resp_body)["error"]["code"] == "rule_denied"

    agent_request =
      conn(:post, "/agent/dispatch", JSON.encode!(%{verb: "inspect", as: "operator"}))
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())

    agent_response = Router.call(agent_request, Router.init(ctx.router_opts))
    assert agent_response.status == 400

    assert JSON.decode!(agent_response.resp_body)["error"]["message"] ==
             "agent-denial: agent denied"

    refute_received {:handler_invoked, _}
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM domain_mutations")

    events = EventLog.events_after(ctx.db, 0, 10)

    assert Enum.map(events, &{&1.kind, &1.verb}) == [
             {"denied", "post"},
             {"denied", "spawn"},
             {"denied", "inspect"}
           ]
  end

  test "control responses retain the existing 200-with-error convention", ctx do
    path = Path.join(ctx.router_opts[:base_dir], "identity/rules/control.toml")

    File.write!(path, """
    [[rule]]
    name = "control-denial"
    verb = "tune"
    text = "control denied"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    """)

    Rules.load!(ctx.router_opts[:base_dir], ["post", "spawn", "inspect", "tune"])

    request =
      conn(
        :post,
        "/api/session-control",
        JSON.encode!(%{
          sessionKey: ctx.main.session_key,
          action: "set_model",
          model: "anything"
        })
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")

    response = Router.call(request, Router.init(ctx.router_opts))
    assert response.status == 200

    assert %{
             "ok" => false,
             "code" => "rule_denied",
             "message" => "control-denial: control denied"
           } = JSON.decode!(response.resp_body)

    refute_received {:handler_invoked, "tune"}
    assert [%{kind: "denied", verb: "tune"}] = EventLog.events_after(ctx.db, 0, 10)
  end
end
