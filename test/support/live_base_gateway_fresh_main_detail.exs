import ExUnit.Assertions
import Plug.Conn
import Plug.Test
alias Tightbeam.{Devices, Gateway, Harness, Model, ModelCatalog, Org}

# A fresh organization on a host whose harnesses are not onboarded: the served
# model catalog has no entries, yet a user who pairs and connects is admitted
# to Main with the configured default selection. An admin reading that Main
# through the public session-detail route, with the org bearer and asUser, must
# get the session back.
Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
  # Plug.Test reads :plug's environment; this VM starts no applications.
  _ = Application.load(:plug)

  config = %{
    config
    | default_harness: :claude,
      default_model: Model.new("claude-sonnet-5", effort: "medium"),
      port: 0
  }

  children = Gateway.children(config)

  %{start: {Tightbeam.ListenerLifecycle, :start_listener, [bandit_opts, _owner]}} =
    List.last(children)

  {Tightbeam.Wire.Router, router_opts} = Keyword.fetch!(bandit_opts, :plug)

  admin = Devices.add_user(db, "detail-admin", true)
  assert admin.is_admin
  reader = Devices.add_user(db, "detail-reader", false)
  refute reader.is_admin

  {:pending, pending} =
    Devices.pair(db, %{
      device_id: "detail-reader-device",
      claimed_name: "detail-reader",
      platform: nil,
      model: nil
    })

  device = Devices.approve(db, pending.device_id, "detail-reader")
  assert device.user_id == "detail-reader"

  {:ok, catalog} =
    ModelCatalog.start_link(
      base_dir: base,
      db: db,
      hosts: fn -> %{} end,
      credential_status: fn _, _ -> {:needs_onboarding, :missing} end,
      credential_kind: fn _, _ -> :none end,
      sh: fn _ -> flunk("unexpected catalog shell") end,
      claude_fetch: fn _, _ -> flunk("unexpected catalog fetch") end
    )

  try do
    :sys.replace_state(catalog, fn state ->
      hosts = %{"testhost" => %{base_dir: base, ssh: nil}}

      entries =
        Map.new(Harness.all(), fn module ->
          {{"testhost", module.wire_name()},
           %{
             entries: [],
             derived_at: nil,
             attempted_at: state.now.(),
             reason: {:needs_onboarding, :missing},
             refreshing: false
           }}
        end)

      %{state | hosts: fn -> hosts end, entries: entries}
    end)

    assert Enum.all?(ModelCatalog.get(), fn {_key, entries} -> entries == [] end)

    {:ok, socket} = Tightbeam.Wire.Socket.init(router_opts)
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}

    assert {:push, _frames, _state} =
             Tightbeam.Wire.Socket.handle_in({JSON.encode!(auth), opcode: :text}, socket)

    key = Org.personal_session_key("detail-reader")

    assert %{kind: "main", harness: "claude", model: %Model{family: "claude-sonnet-5"}} =
             Org.get(db, key)

    org_token = base |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    response =
      conn(:get, "/api/sessions/#{URI.encode_www_form(key)}?asUser=detail-admin")
      |> put_req_header("authorization", "Bearer " <> org_token["cliToken"])
      |> Tightbeam.Wire.Router.call(router_opts)

    assert response.status == 200, response.resp_body
    body = JSON.decode!(response.resp_body)
    assert body["resource"] == "sessions"
    assert body["item"]["sessionKey"] == key
    assert body["item"]["ownerUserId"] == "detail-reader"
    assert body["item"]["harness"] == "claude"
    assert body["item"]["model"] == "claude-sonnet-5"
    assert body["item"]["thinkingLevel"] == "medium"
  after
    GenServer.stop(catalog)
  end
end)

IO.puts("guarded-gateway-fresh-main-detail: ok")
