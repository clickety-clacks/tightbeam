defmodule Tightbeam.D1ReadTest do
  use Tightbeam.TestCase, async: true

  alias Tightbeam.{D1Read, DB, Devices, Harness, Org, Placement, Schema}

  setup do
    db = :"d1_read_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "the seam serializes config and host environment with values redacted", %{db: db} do
    :ok = Org.put_setting(db, "default-archetype", "default")
    :ok = Org.put_setting(db, "private-priority", "secret")

    assert [default, private] = D1Read.collection(db, "/unused", :config, %{})
    assert default["value"] == "default"
    assert private["value"] == nil

    assert D1Read.encode(:config, private) ==
             ~s({"key":"private-priority","value":null,"updatedAt":#{private["updatedAt"]},"rowVersion":#{private["rowVersion"]}})

    assert {:ok, _host} =
             Placement.register_host(db, "alpha", %{
               ssh: "operator@alpha",
               base_dir: "/private/alpha",
               cli_bin: "/private/tightbeam",
               adapter_bin_dir: "/private/adapters"
             })

    harness = hd(Harness.all()).wire_name()

    assert {:ok, _overlay} =
             Placement.set_env_overlay(
               db,
               "alpha",
               harness,
               "PRIVATE_TOKEN",
               "secret",
               "user:admin"
             )

    assert [environment] = D1Read.collection(db, "/unused", :host_environment, %{})
    assert environment["value"] == nil
    assert environment["valuePresent"] == true
    refute D1Read.encode(:host_environment, environment) =~ "secret"
  end

  test "the seam reads current users in stable public tuple order", %{db: db} do
    Devices.add_user(db, "zeta", false)
    Devices.add_user(db, "alpha", true)

    users = D1Read.collection(db, "/unused", :users, %{})

    assert Enum.map(users, & &1["userId"]) == ["alpha", "zeta"]
    assert Enum.all?(users, &(is_boolean(&1["isAdmin"]) and is_integer(&1["rowVersion"])))
  end
end

defmodule Tightbeam.D1ReadRouteTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{D1Read, DB, Devices, Harness, Identity, Org, Placement, Schema}
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-d1-route-#{System.unique_integer([:positive])}")

    :initialized = Identity.init!(base_dir)

    db = :"d1_route_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:paired, admin} =
      Devices.pair(db, %{device_id: "d1-admin", claimed_name: "admin", platform: nil, model: nil})

    {:pending, _} =
      Devices.pair(db, %{
        device_id: "d1-operator",
        claimed_name: "operator",
        platform: nil,
        model: nil
      })

    operator = Devices.approve(db, "d1-operator", "operator")
    session = ensure_main_session(db, "admin")

    for user <- ~w(alpha beta zeta) do
      Devices.add_user(db, user, false)
    end

    for host <- ~w(alpha beta zeta) do
      assert {:ok, _host} =
               Placement.register_host(db, host, %{
                 ssh: "operator@#{host}",
                 base_dir: "/tmp/#{host}",
                 cli_bin: "/tmp/tightbeam",
                 adapter_bin_dir: "/tmp/adapters"
               })
    end

    :ok = Org.put_setting(db, "default-archetype", "default")

    harness = hd(Harness.all()).wire_name()

    assert {:ok, _overlay} =
             Placement.set_env_overlay(
               db,
               "alpha",
               harness,
               "D1_TEST_VALUE",
               "redacted",
               "user:admin"
             )

    opts =
      Router.init(
        db: db,
        base_dir: base_dir,
        handlers: %{},
        cli_token: "tbc_d1_route",
        session_status: fn _ -> nil end
      )

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{db: db, base_dir: base_dir, opts: opts, admin: admin, operator: operator, session: session}
  end

  test "all six D1 routes provide fixed envelopes, ordered bytes, and no-store", ctx do
    for {path, resource, resource_key} <- [
          {"/api/config", "config", :config},
          {"/api/host-env", "host environment", :host_environment},
          {"/api/hosts", "hosts", :hosts},
          {"/api/users", "users", :users},
          {"/api/identity", "identity", :identity},
          {"/api/kungfu", "kungfu", :kungfu}
        ] do
      response = get(ctx.opts, path, ctx.admin.token)
      assert response.status == 200, "#{path}: #{response.resp_body}"
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert JSON.decode!(response.resp_body)["resource"] == resource
      assert JSON.decode!(response.resp_body)["schemaVersion"] == 1

      for item <- D1Read.collection(ctx.db, ctx.base_dir, resource_key, %{}) do
        assert response.resp_body =~ D1Read.encode(resource_key, item)
      end
    end

    users = get(ctx.opts, "/api/users?userId=alpha&userId=beta&userId=zeta", ctx.admin.token)

    assert JSON.decode!(users.resp_body)["items"] |> Enum.map(& &1["userId"]) ==
             ~w(alpha beta zeta)

    assert get(ctx.opts, "/api/config/default-archetype", ctx.admin.token).status == 200
    assert get(ctx.opts, "/api/hosts/alpha", ctx.admin.token).status == 200
    assert get(ctx.opts, "/api/users/alpha", ctx.admin.token).status == 200
  end

  test "users and session host cursors replay in both directions with fixed tuple bytes",
       ctx do
    users_path = "/api/users?userId=alpha&userId=beta&userId=zeta&limit=1"
    first = get(ctx.opts, users_path, ctx.admin.token)
    first_page = JSON.decode!(first.resp_body)
    assert Enum.map(first_page["items"], & &1["userId"]) == ["zeta"]

    users_payload = decode_cursor(first_page["page"]["oldestCursor"])

    assert Enum.sort(Map.keys(users_payload)) ==
             Enum.sort(
               ~w(direction filters principalId principalKind resource route tuple version)
             )

    assert users_payload["tuple"] == ["zeta"]

    assert first_page["page"]["oldestCursor"] ==
             users_payload
             |> JSON.encode!()
             |> Base.url_encode64(padding: false)

    previous =
      get(
        ctx.opts,
        users_path <> "&before=" <> first_page["page"]["oldestCursor"],
        ctx.admin.token
      )

    previous_page = JSON.decode!(previous.resp_body)
    assert Enum.map(previous_page["items"], & &1["userId"]) == ["beta"]

    forward =
      get(
        ctx.opts,
        users_path <> "&after=" <> previous_page["page"]["newestCursor"],
        ctx.admin.token
      )

    assert Enum.map(JSON.decode!(forward.resp_body)["items"], & &1["userId"]) == ["zeta"]

    stale_principal =
      get(
        ctx.opts,
        users_path <> "&after=" <> first_page["page"]["newestCursor"],
        ctx.operator.token
      )

    assert stale_principal.status == 400
    assert JSON.decode!(stale_principal.resp_body)["error"]["code"] == "invalid_cursor"

    malformed = get(ctx.opts, users_path <> "&after=not-a-cursor", ctx.admin.token)
    assert malformed.status == 400
    assert JSON.decode!(malformed.resp_body)["error"]["code"] == "invalid_cursor"

    stale_version =
      users_payload
      |> Map.put("version", 0)
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    stale = get(ctx.opts, users_path <> "&after=" <> stale_version, ctx.admin.token)
    assert stale.status == 400
    assert JSON.decode!(stale.resp_body)["error"]["code"] == "invalid_cursor"

    hosts_path = "/api/hosts?host=alpha&host=beta&host=zeta&limit=1"
    hosts = get(ctx.opts, hosts_path, ctx.session.cli_token) |> then(&JSON.decode!(&1.resp_body))
    assert Enum.map(hosts["items"], & &1["host"]) == ["zeta"]

    hosts_before =
      get(
        ctx.opts,
        hosts_path <> "&before=" <> hosts["page"]["oldestCursor"],
        ctx.session.cli_token
      )
      |> then(&JSON.decode!(&1.resp_body))

    assert Enum.map(hosts_before["items"], & &1["host"]) == ["beta"]

    hosts_after =
      get(
        ctx.opts,
        hosts_path <> "&after=" <> hosts_before["page"]["newestCursor"],
        ctx.session.cli_token
      )
      |> then(&JSON.decode!(&1.resp_body))

    assert Enum.map(hosts_after["items"], & &1["host"]) == ["zeta"]
  end

  test "D1 preserves auth, visibility, error bytes, and cache", ctx do
    assert get(ctx.opts, "/api/config?asUser=admin", "tbc_d1_route").status == 200
    assert get(ctx.opts, "/api/hosts?host=alpha", ctx.session.cli_token).status == 200
    assert get(ctx.opts, "/api/hosts", "bad-token").status == 401

    invalid = get(ctx.opts, "/api/config?unknown=value", ctx.admin.token)
    assert invalid.status == 400
    assert JSON.decode!(invalid.resp_body)["error"]["code"] == "invalid_filter"

    hidden = get(ctx.opts, "/api/config/default-archetype", ctx.operator.token)
    missing = get(ctx.opts, "/api/config/missing", ctx.admin.token)

    assert hidden.status == 404
    assert missing.status == 404
    assert hidden.resp_body == missing.resp_body
    assert get_resp_header(hidden, "cache-control") == ["no-store"]
    assert get_resp_header(missing, "cache-control") == ["no-store"]
  end

  defp get(opts, path, bearer) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> Router.call(opts)
  end

  defp decode_cursor(cursor) do
    cursor |> Base.url_decode64!(padding: false) |> JSON.decode!()
  end
end
