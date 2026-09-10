defmodule Tightbeam.D1ReadTest do
  use Tightbeam.TestCase, async: true

  alias Tightbeam.{D1Read, DB, Devices, Harness, Org, Placement, Schema}

  setup do
    db = :"d1_read_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  @tag d1_delta: true
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

    assert %{changed: true} =
             Placement.set_env_overlay_with_firehose(
               db,
               "alpha",
               harness,
               "PRIVATE_TOKEN",
               "secret",
               "user:admin",
               %{
                 verb: "host-env-set",
                 origin: "user:admin",
                 principal: {:user, "admin"},
                 params: %{}
               }
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

  @tag :kungfu_protection
  test "available D1 routes retain fixed envelopes", ctx do
    for {path, resource, resource_key} <- [
          {"/api/config", "config", :config},
          {"/api/host-env", "host environment", :host_environment},
          {"/api/hosts", "hosts", :hosts},
          {"/api/users", "users", :users},
          {"/api/identity", "identity", :identity}
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

    newest_cursor = first_page["page"]["newestCursor"]
    assert get(ctx.opts, users_path <> "&after=" <> newest_cursor, ctx.admin.token).status == 200

    stale_version =
      newest_cursor
      |> decode_cursor()
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

  @tag rest_r7_encoder: true
  test "all shared collections retain exact missing and repeated principal refusals", ctx do
    for {path, resource} <- [
          {"/api/config", "config"},
          {"/api/host-env", "host environment"},
          {"/api/hosts", "hosts"},
          {"/api/users", "users"},
          {"/api/identity", "identity"},
          {"/api/kungfu", "kungfu"}
        ] do
      for {query, code} <- [
            {"", "invalid_message"},
            {"?limit=1", "invalid_message"},
            {"?asUser=", "invalid_message"},
            {"?asUser=admin&asUser=admin", "invalid_as_user"}
          ] do
        response = get(ctx.opts, path <> query, "tbc_d1_route")
        assert response.status == 400

        assert JSON.decode!(response.resp_body) ==
                 %{"schemaVersion" => 1, "resource" => resource, "error" => %{"code" => code}}

        assert get_resp_header(response, "cache-control") == ["no-store"]
      end

      invalid = get(ctx.opts, path <> "?asUser=admin&asUser=admin", "invalid-token")
      assert invalid.status == 401
      assert JSON.decode!(invalid.resp_body)["error"]["code"] == "auth_failed"
    end
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

  @tag :kungfu_protection
  test "kungfu collection and detail serve unchanged listed bytes with exact hashes", ctx do
    first = get(ctx.opts, "/api/kungfu", ctx.admin.token)
    assert first.status == 200
    assert get_resp_header(first, "cache-control") == ["no-store"]
    items = JSON.decode!(first.resp_body)["items"]
    assert items != []

    for item <- items do
      expected = Identity.public_kungfu(ctx.base_dir, item["name"])
      assert item["documents"] == expected["documents"]

      for doc <- item["documents"] do
        assert doc["path"] in ~w(README.md capabilities.md preferred-models.md)

        assert doc["sha256"] ==
                 :crypto.hash(:sha256, doc["content"]) |> Base.encode16(case: :lower)
      end

      detail = get(ctx.opts, "/api/kungfu/" <> item["name"], ctx.admin.token)
      assert detail.status == 200
      assert detail.resp_body =~ D1Read.encode(:kungfu, item)
    end

    assert get(ctx.opts, "/api/kungfu", ctx.admin.token).resp_body == first.resp_body
    assert get(ctx.opts, "/api/kungfu/no-such-bundle", ctx.admin.token).status == 404
  end

  @tag :kungfu_protection
  test "kungfu serving preserves prior auth principal visibility and query decisions", ctx do
    assert get(ctx.opts, "/api/kungfu", "invalid").status == 401
    assert get(ctx.opts, "/api/kungfu", "tbc_d1_route").status == 400
    invalid = get(ctx.opts, "/api/kungfu?unknown=value", ctx.admin.token)
    assert invalid.status == 400
    assert JSON.decode!(invalid.resp_body)["error"]["code"] == "invalid_filter"
    assert get(ctx.opts, "/api/kungfu?asUser=other", ctx.session.cli_token).status == 403
    hidden = get(ctx.opts, "/api/kungfu/no-such-bundle", ctx.operator.token)
    assert hidden.status == 404
    collection = get(ctx.opts, "/api/kungfu", ctx.operator.token)
    assert collection.status == 200
    assert JSON.decode!(collection.resp_body)["items"] == []
    assert get(ctx.opts, "/api/hosts", ctx.admin.token).status == 200
  end

  @tag d1_delta: true
  test "authenticated host REST notice and rebuild agree without widening host environment",
       ctx do
    alias Tightbeam.{StateResources, StateVisibility}
    alias Tightbeam.Firehose.{Hub, Rebuild}
    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self(), %{mode: :all, db: ctx.db, user_id: "admin", is_admin: true})

    call = %{
      verb: "register-host",
      principal: {:user, "admin"},
      origin: "user:admin",
      params: %{}
    }

    assert {:ok, _} =
             Placement.register_host_with_firehose(
               ctx.db,
               "alpha",
               %{
                 ssh: "operator@alpha",
                 base_dir: "/tmp/alpha",
                 cli_bin: "/tmp/tightbeam",
                 adapter_bin_dir: "/tmp/adapters"
               },
               call
             )

    _barrier = Hub.sequence(Hub, self())
    assert_received {:firehose_notice, %{"class" => "host.registered"} = notice}
    Hub.delivered(Hub, self())
    assert notice["payload"] == StateResources.host(StateResources.query_host(ctx.db, "alpha"))
    assert Map.keys(notice["payload"]) |> Enum.sort() == ["host", "rowVersion"]

    for {token, user, admin} <- [
          {ctx.admin.token, "admin", true},
          {ctx.operator.token, "operator", false},
          {ctx.session.cli_token, "admin", false}
        ] do
      response = get(ctx.opts, "/api/hosts/alpha", token)
      assert response.status == 200
      assert JSON.decode!(response.resp_body)["item"] == notice["payload"]
      assert StateVisibility.visible?(ctx.db, notice, user, admin)

      assert {:ok, notice["payload"]} ==
               Rebuild.fetch(ctx.db, "host.registered", notice["refs"], user, admin)
    end

    assert get(ctx.opts, "/api/hosts/alpha", "bad-token").status == 401
    assert conn(:get, "/api/hosts/alpha") |> Router.call(ctx.opts) |> Map.fetch!(:status) == 401

    assert JSON.decode!(get(ctx.opts, "/api/host-env", ctx.operator.token).resp_body)["items"] ==
             []

    harness = hd(Harness.all()).wire_name()

    assert %{changed: true, projection: %{row_version: version}} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               "alpha",
               harness,
               "D1_TEST_VALUE",
               "changed-private-value",
               "user:admin",
               %{call | verb: "host-env-set"}
             )

    assert is_integer(version) and version > 0
    environment = hd(D1Read.collection(ctx.db, ctx.base_dir, :host_environment, %{}))
    refs = Map.take(environment, ["host", "harness", "name"])
    assert :forbidden == Rebuild.fetch(ctx.db, "host_env.updated", refs, "operator", false)
    assert {:ok, rebuilt} = Rebuild.fetch(ctx.db, "host_env.updated", refs, "admin", true)
    assert rebuilt == environment
    assert rebuilt["value"] == nil
    assert rebuilt["valuePresent"] == true
    refute StateVisibility.config_visible?(false)
    refute StateVisibility.user_visible?(false)
    refute StateVisibility.host_environment_visible?(false)
  end

  @tag :tmp_dir
  @tag d1_guarded_restart: true
  test "stamped environment first change noop unset and guarded restart preserve canonical parity",
       %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_d1_restart.exs",
      "guarded-environment-parity: ok"
    )
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
