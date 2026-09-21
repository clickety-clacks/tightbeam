import ExUnit.Assertions
alias Tightbeam.{Devices, Gateway, Harness, Model, ModelCatalog, Org}

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
  {:paired, _} =
    Devices.pair(db, %{
      device_id: "first-fixture",
      claimed_name: "First",
      platform: nil,
      model: nil
    })

  config = %{
    config
    | default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      port: 0
  }

  children = Gateway.children(config)
  {Bandit, bandit_opts} = List.last(children)
  {Tightbeam.Wire.Router, socket_deps} = Keyword.fetch!(bandit_opts, :plug)

  {:pending, pending} =
    Devices.pair(db, %{
      device_id: "fresh-empty",
      claimed_name: "Fresh Empty",
      platform: nil,
      model: nil
    })

  device = Devices.approve(db, pending.device_id)

  {:ok, catalog} =
    ModelCatalog.start_link(
      base_dir: base,
      db: db,
      hosts: fn -> %{} end,
      credential_status: fn _ -> flunk("unexpected credential probe") end,
      credential_kind: fn _ -> flunk("unexpected credential-kind probe") end,
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
             reason: :not_derived,
             refreshing: true
           }}
        end)

      %{state | hosts: fn -> hosts end, entries: entries}
    end)

    assert {[], {:unavailable, :not_derived}} =
             ModelCatalog.get("testhost", "claude", ModelCatalog)

    {:ok, socket} = Tightbeam.Wire.Socket.init(socket_deps)
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}

    assert {:push, _frames, _state} =
             Tightbeam.Wire.Socket.handle_in({JSON.encode!(auth), opcode: :text}, socket)

    assert %{harness: "claude", provider: "anthropic", model: %Model{family: "claude-fable-5"}} =
             Org.get(db, Org.personal_session_key(device.user_id))

    assert {[], {:unavailable, :not_derived}} =
             ModelCatalog.get("testhost", "claude", ModelCatalog)
  after
    GenServer.stop(catalog)
  end
end)

IO.puts("guarded-gateway-fresh-auth: ok")
