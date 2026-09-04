defmodule Tightbeam.RestReadPlaneD1Test.QuerySpyDB do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
  def queries(server), do: GenServer.call(server, :queries)

  @impl true
  def init(opts) do
    {:ok, %{db: Map.fetch!(opts, :db), queries: [], before_query: Map.get(opts, :before_query)}}
  end

  @impl true
  def handle_call(:queries, _from, state), do: {:reply, Enum.reverse(state.queries), state}

  def handle_call({:query, sql, params} = request, _from, state) do
    query = {sql |> String.replace(~r/\s+/, " ") |> String.trim(), params}

    if is_function(state.before_query, 2) do
      state.before_query.(elem(query, 0), elem(query, 1))
    end

    {:reply, GenServer.call(state.db, request), %{state | queries: [query | state.queries]}}
  end

  def handle_call(request, _from, state), do: {:reply, GenServer.call(state.db, request), state}
end

defmodule Tightbeam.RestReadPlaneD1Test do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    AdminProjection,
    Archetypes,
    CliCompatibility,
    DB,
    Devices,
    Harness,
    Identity,
    Org,
    Placement,
    Schema,
    StateResources
  }

  alias Tightbeam.Wire.Router
  alias Tightbeam.Firehose.{Publisher, Rebuild}
  alias Tightbeam.RestReadPlaneD1Test.QuerySpyDB

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-rest-d1-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"rest_d1_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:paired, admin_device} =
      claim_org(db, %{
        device_id: "admin-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    admin_session = ensure_main_session(db, "flynn")
    Devices.add_user(db, "operator", false)

    {:pending, _pending} =
      Devices.pair(db, %{
        device_id: "operator-device",
        claimed_name: "Operator",
        platform: nil,
        model: nil
      })

    operator_device = Devices.approve(db, "operator-device", "operator")
    operator_session = ensure_main_session(db, "operator")

    :ok = Org.put_setting(db, "default-archetype", "default")
    :ok = Org.put_setting(db, "default-priority", "private-priority-value")
    :ok = Org.put_setting(db, "alpha-fixture", "not-allowlisted-on-the-wire")
    :ok = Org.put_setting(db, "zeta-fixture", "also-not-allowlisted")

    for host <- ~w(alpha-host zeta-host) do
      assert {:ok, _entry} =
               Placement.register_host(db, host, %{
                 ssh: "secret@#{host}",
                 base_dir: "/secret/#{host}",
                 cli_bin: "/secret/tightbeam",
                 adapter_bin_dir: "/secret/adapters"
               })
    end

    harness = hd(Harness.all()).wire_name()

    catalog = %{
      {"alpha-host", harness} => [],
      {"zeta-host", harness} => []
    }

    for host <- ~w(alpha-host zeta-host), name <- ~w(ALPHA_ENV ZETA_ENV) do
      assert {:ok, _entry} =
               Placement.set_env_overlay(
                 db,
                 host,
                 harness,
                 name,
                 "host-environment-secret",
                 "user:flynn"
               )
    end

    :ok = AdminProjection.ensure_schema(db)
    :ok = AdminProjection.bootstrap_served(db, base_dir)

    inspect_handler = fn call ->
      %{
        "origin" => call.origin,
        "principal" => inspect(call.principal)
      }
    end

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{"inspect" => inspect_handler},
      cli_token: "tbc_rest_d1",
      cursor_signing: cursor_signing!(base_dir),
      model_catalog: catalog,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      base_dir: base_dir,
      opts: opts,
      admin_device: admin_device,
      admin_session: admin_session,
      operator_device: operator_device,
      operator_session: operator_session,
      harness: harness,
      catalog: catalog
    }
  end

  test "six shared-seam resources cross real HTTP with exact envelopes, item bytes, and cache",
       ctx do
    port = start_http!(ctx)
    kungfu_name = first_kungfu_name(ctx.db)

    cases = [
      {"config.collection", "config", "/api/config", "/api/config/default-archetype",
       StateResources.query_config(ctx.db, "default-archetype"), :config},
      {"host_environment.collection", "host environment", "/api/host-env", nil,
       StateResources.query_host_environment(ctx.db, "alpha-host", ctx.harness, "ALPHA_ENV"),
       :host_environment},
      {"hosts.collection", "hosts", "/api/hosts", "/api/hosts/alpha-host",
       StateResources.query_host(ctx.db, "alpha-host"), :host},
      {"users.collection", "users", "/api/users", "/api/users/flynn",
       StateResources.query_user(ctx.db, "flynn"), :user},
      {"identity.collection", "identity", "/api/identity", "/api/identity/served",
       hydrated_identity!(ctx.db, "served", {:user, "flynn"}), :identity},
      {"kungfu.collection", "kungfu", "/api/kungfu", "/api/kungfu/#{kungfu_name}",
       StateResources.query_kungfu(ctx.db, kungfu_name), :kungfu}
    ]

    for {route, resource, collection_path, detail_path, raw, serializer} <- cases do
      item = apply(StateResources, serializer, [raw])
      item_bytes = StateResources.encode_item(resource, item, ctx.catalog)
      {200, headers, collection_bytes} = http_get(port, collection_path, ctx.admin_device.token)
      collection = JSON.decode!(collection_bytes)

      assert application_header(headers, "content-type") == "application/json; charset=utf-8"
      assert application_header(headers, "cache-control") == "no-store"
      assert collection["schemaVersion"] == 1
      assert collection["resource"] == resource
      assert is_list(collection["items"])
      assert collection_bytes =~ item_bytes

      oldest = decode_cursor_payload(collection["page"]["oldestCursor"])
      newest = decode_cursor_payload(collection["page"]["newestCursor"])

      assert oldest["route"] == route
      assert newest["route"] == route
      assert oldest["direction"] == "before"
      assert newest["direction"] == "after"

      assert collection["page"] == %{
               "oldestCursor" => collection["page"]["oldestCursor"],
               "newestCursor" => collection["page"]["newestCursor"],
               "hasMoreBefore" => false,
               "hasMoreAfter" => false
             }

      if detail_path do
        {200, detail_headers, detail_bytes} =
          http_get(port, detail_path, ctx.admin_device.token)

        assert application_header(detail_headers, "cache-control") == "no-store"
        assert JSON.decode!(detail_bytes)["item"] == item
        assert detail_bytes =~ ~s("item":#{item_bytes})
      end
    end
  end

  test "REST and authoritative Firehose rebuild return the same six admin resources", ctx do
    kungfu_name = first_kungfu_name(ctx.db)

    cases = [
      {"config.updated", "config", "/api/config/default-archetype",
       %{"key" => "default-archetype"}},
      {"host_env.updated", "host environment",
       "/api/host-env?host=alpha-host&harness=#{ctx.harness}&name=ALPHA_ENV",
       %{"host" => "alpha-host", "harness" => ctx.harness, "name" => "ALPHA_ENV"}},
      {"host.registered", "hosts", "/api/hosts/alpha-host", %{"host" => "alpha-host"}},
      {"user.promoted", "users", "/api/users/flynn", %{"userId" => "flynn"}},
      {"identity.updated", "identity", "/api/identity/served", %{"name" => "served"}},
      {"kungfu.updated", "kungfu", "/api/kungfu/#{kungfu_name}", %{"name" => kungfu_name}}
    ]

    for {class, resource, path, refs} <- cases do
      response = get(ctx, path, ctx.admin_device.token)
      assert response.status == 200, class

      rest_item =
        case JSON.decode!(response.resp_body) do
          %{"item" => item} -> item
          %{"items" => [item]} -> item
        end

      assert {:ok, rebuilt_item} = Rebuild.fetch(ctx.db, class, refs, "flynn", true)
      assert rest_item == rebuilt_item, class

      item_bytes = StateResources.encode_item(resource, rebuilt_item, ctx.catalog)
      assert response.resp_body =~ item_bytes, class
    end
  end

  test "SR5 exposes only default-archetype and Publisher uses the same redacted bytes", ctx do
    rows =
      ctx.db
      |> StateResources.query_config(%{})
      |> Enum.map(&StateResources.config/1)

    assert Map.new(rows, &{&1["key"], &1["value"]}) == %{
             "alpha-fixture" => nil,
             "default-archetype" => "default",
             "default-priority" => nil,
             "zeta-fixture" => nil
           }

    detail = get(ctx, "/api/config/default-priority", ctx.admin_device.token)
    assert detail.status == 200
    item = JSON.decode!(detail.resp_body)["item"]
    assert item["value"] == nil

    item_bytes = StateResources.encode_item("config", item)

    notice =
      Publisher.encode_wire_notice(%{
        "class" => "config.updated",
        "op" => "upsert",
        "occurredAt" => 1,
        "refs" => %{"configKey" => "default-priority"},
        "payload" => item
      })

    assert notice =~ ~s("payload":#{item_bytes})
    refute notice =~ "private-priority-value"
  end

  test "bearer classes and transport-only asUser preserve dispatch principal semantics", ctx do
    cases = [
      {"org known admin", "/api/config?asUser=flynn", "tbc_rest_d1", 200, nil},
      {"org unknown user remains a user principal", "/api/hosts?asUser=unknown-user",
       "tbc_rest_d1", 200, nil},
      {"org missing asUser", "/api/config", "tbc_rest_d1", 400, "invalid_message"},
      {"org empty asUser", "/api/config?asUser=", "tbc_rest_d1", 400, "invalid_message"},
      {"org repeated asUser", "/api/config?asUser=flynn&asUser=flynn", "tbc_rest_d1", 400,
       "invalid_as_user"},
      {"session absent asUser stays a session", "/api/hosts", ctx.admin_session.cli_token, 200,
       nil},
      {"session empty asUser", "/api/hosts?asUser=", ctx.admin_session.cli_token, 403,
       "identity_not_yours"},
      {"session matching asUser becomes the owner user", "/api/config?asUser=flynn",
       ctx.admin_session.cli_token, 200, nil},
      {"session mismatching asUser", "/api/config?asUser=operator", ctx.admin_session.cli_token,
       403, "identity_not_yours"},
      {"device asUser is invalid", "/api/config?asUser=flynn", ctx.admin_device.token, 400,
       "invalid_as_user"},
      {"invalid bearer", "/api/config", "wrong", 401, "auth_failed"}
    ]

    for {label, path, bearer, status, code} <- cases do
      response = get(ctx, path, bearer)
      assert response.status == status, label
      assert get_resp_header(response, "cache-control") == ["no-store"]

      if code do
        assert JSON.decode!(response.resp_body)["error"]["code"] == code, label
      end
    end

    mismatch = get(ctx, "/api/config?asUser=operator", ctx.admin_session.cli_token)

    assert mismatch.resp_body ==
             ~s({"schemaVersion":1,"resource":"config","error":{"code":"identity_not_yours","message":"this session belongs to flynn"}})

    empty = get(ctx, "/api/hosts?asUser=", ctx.admin_session.cli_token)

    assert empty.resp_body ==
             ~s({"schemaVersion":1,"resource":"hosts","error":{"code":"identity_not_yours","message":"this session belongs to flynn"}})

    malformed = get(ctx, "/api/config?asUser=flynn%zz", "tbc_rest_d1")
    assert malformed.status == 400
    assert JSON.decode!(malformed.resp_body)["error"]["code"] == "malformed_query"

    assert JSON.decode!(get(ctx, "/api/config", ctx.operator_session.cli_token).resp_body)[
             "items"
           ] == []

    assert get(ctx, "/api/config/default-archetype", ctx.operator_session.cli_token).resp_body ==
             ~s({"schemaVersion":1,"resource":"config","error":{"code":"not_found"}})

    assert get(ctx, "/api/config/default-archetype", ctx.operator_session.cli_token).resp_body ==
             get(ctx, "/api/config/missing-setting", ctx.operator_session.cli_token).resp_body

    assert get(ctx, "/api/hosts/alpha-host", ctx.operator_session.cli_token).status == 200
    assert get(ctx, "/api/host-env/alpha-host", ctx.admin_device.token).status == 404

    parity_cases = [
      {"org known", "/api/hosts?asUser=flynn", "tbc_rest_d1", %{"asUser" => "flynn"}, 200, nil},
      {"org unknown", "/api/hosts?asUser=unknown-user", "tbc_rest_d1",
       %{"asUser" => "unknown-user"}, 200, nil},
      {"org empty", "/api/hosts?asUser=", "tbc_rest_d1", %{"asUser" => ""}, 400,
       "invalid_message"},
      {"org missing", "/api/hosts", "tbc_rest_d1", %{}, 400, "invalid_message"},
      {"session absent", "/api/hosts", ctx.admin_session.cli_token, %{}, 200, nil},
      {"session empty", "/api/hosts?asUser=", ctx.admin_session.cli_token, %{"asUser" => ""}, 403,
       "identity_not_yours"},
      {"session matching", "/api/hosts?asUser=flynn", ctx.admin_session.cli_token,
       %{"asUser" => "flynn"}, 200, nil},
      {"session mismatching", "/api/hosts?asUser=operator", ctx.admin_session.cli_token,
       %{"asUser" => "operator"}, 403, "identity_not_yours"}
    ]

    for {label, path, bearer, identity, status, code} <- parity_cases do
      direct = get(ctx, path, bearer)
      dispatch = dispatch(ctx, bearer, Map.merge(%{"verb" => "inspect"}, identity))

      assert direct.status == status, "#{label} direct GET"
      assert dispatch.status == status, "#{label} dispatch"

      if code do
        assert JSON.decode!(direct.resp_body)["error"]["code"] == code, label
        assert JSON.decode!(dispatch.resp_body)["error"]["code"] == code, label
      end
    end

    empty_dispatch =
      dispatch(ctx, ctx.admin_session.cli_token, %{"verb" => "inspect", "asUser" => ""})

    assert JSON.decode!(empty_dispatch.resp_body)["error"] == %{
             "code" => "identity_not_yours",
             "message" => "this session belongs to flynn"
           }
  end

  test "allowlisted filters compose OR within a field and AND across fields", ctx do
    response =
      get(
        ctx,
        "/api/config?key=zeta-fixture&key=alpha-fixture",
        ctx.admin_device.token
      )

    assert Enum.map(JSON.decode!(response.resp_body)["items"], & &1["key"]) ==
             ~w(alpha-fixture zeta-fixture)

    host_env =
      get(
        ctx,
        "/api/host-env?host=zeta-host&host=alpha-host&harness=#{ctx.harness}&name=ALPHA_ENV",
        ctx.admin_device.token
      )
      |> then(&JSON.decode!(&1.resp_body))

    assert Enum.map(host_env["items"], &{&1["host"], &1["harness"], &1["name"]}) == [
             {"alpha-host", ctx.harness, "ALPHA_ENV"},
             {"zeta-host", ctx.harness, "ALPHA_ENV"}
           ]

    assert JSON.decode!(
             get(ctx, "/api/users?userId=unknown-user", ctx.admin_device.token).resp_body
           )["items"] == []

    for path <- [
          "/api/users?status=active",
          "/api/config?unknown=value",
          "/api/config?key=",
          "/api/identity?state=unknown",
          "/api/kungfu?status=unknown",
          "/api/config?limit=0",
          "/api/config?limit=01",
          "/api/config?limit=1&limit=2",
          "/api/config?before=x&after=y"
        ] do
      response = get(ctx, path, ctx.admin_device.token)
      assert response.status == 400, path
      assert JSON.decode!(response.resp_body)["error"]["code"] == "invalid_filter", path
    end
  end

  test "tuple cursors page both directions, survive deletion, and bind filters and principals",
       ctx do
    for user <- ~w(cursor-a cursor-b cursor-c cursor-d) do
      Devices.add_user(ctx.db, user, false)
    end

    {:ok, _rows} =
      DB.query(
        ctx.db,
        "UPDATE users SET createdAt = 424242 WHERE userId LIKE 'cursor-%'",
        []
      )

    first = get(ctx, "/api/users?userId=cursor-a&userId=cursor-b&limit=1", ctx.admin_device.token)
    first_body = JSON.decode!(first.resp_body)
    assert Enum.map(first_body["items"], & &1["userId"]) == ["cursor-b"]
    boundary = first_body["page"]["oldestCursor"]
    after_boundary = first_body["page"]["newestCursor"]

    payload = decode_cursor_payload(boundary)

    assert Enum.sort(Map.keys(payload)) ==
             Enum.sort(
               ~w(direction filters principalId principalKind resource route tuple version)
             )

    assert payload["version"] == 1
    assert payload["route"] == "users.collection"
    assert payload["resource"] == "users"
    assert payload["direction"] == "before"
    assert payload["principalKind"] == "user"
    assert payload["principalId"] == "flynn"
    assert payload["tuple"] == [424_242, "cursor-b"]
    refute Map.has_key?(payload, "rowid")
    refute Map.has_key?(payload, "offset")

    org_page =
      get(
        ctx,
        "/api/users?asUser=flynn&userId=cursor-a&userId=cursor-b&limit=1",
        "tbc_rest_d1"
      )
      |> then(&JSON.decode!(&1.resp_body))

    forged_cursor =
      org_page["page"]["newestCursor"]
      |> decode_cursor_payload()
      |> Map.put("principalId", "operator")
      |> JSON.encode!()
      |> then(fn forged_payload ->
        rejected_secret = :crypto.hash(:sha256, "tbc_rest_d1:rest-d1")
        rejected_signature = :crypto.mac(:hmac, :sha256, rejected_secret, forged_payload)

        Base.url_encode64(forged_payload, padding: false) <>
          "." <> Base.url_encode64(rejected_signature, padding: false)
      end)

    forged =
      get(
        ctx,
        "/api/users?asUser=operator&userId=cursor-a&userId=cursor-b&after=#{forged_cursor}",
        "tbc_rest_d1"
      )

    assert forged.status == 400
    assert JSON.decode!(forged.resp_body)["error"]["code"] == "invalid_cursor"

    {:ok, _rows} = DB.query(ctx.db, "DELETE FROM users WHERE userId = 'cursor-b'", [])

    previous =
      get(
        ctx,
        "/api/users?userId=cursor-a&userId=cursor-b&limit=1&before=#{boundary}",
        ctx.admin_device.token
      )
      |> then(&JSON.decode!(&1.resp_body))

    assert Enum.map(previous["items"], & &1["userId"]) == ["cursor-a"]

    for {field, cursor} <- [{"after", boundary}, {"before", after_boundary}] do
      replay =
        get(
          ctx,
          "/api/users?userId=cursor-a&userId=cursor-b&#{field}=#{cursor}",
          ctx.admin_device.token
        )

      assert replay.status == 400
      assert JSON.decode!(replay.resp_body)["error"]["code"] == "invalid_cursor"
    end

    wrong_filter =
      get(ctx, "/api/users?userId=cursor-a&after=#{after_boundary}", ctx.admin_device.token)

    assert wrong_filter.status == 400
    assert JSON.decode!(wrong_filter.resp_body)["error"]["code"] == "invalid_cursor"

    wrong_resource = get(ctx, "/api/hosts?after=#{after_boundary}", ctx.admin_device.token)
    assert wrong_resource.status == 400
    assert JSON.decode!(wrong_resource.resp_body)["error"]["code"] == "invalid_cursor"

    wrong_principal =
      get(
        ctx,
        "/api/users?userId=cursor-a&userId=cursor-b&after=#{after_boundary}",
        ctx.operator_device.token
      )

    assert wrong_principal.status == 404
    assert JSON.decode!(wrong_principal.resp_body)["error"]["code"] == "not_found"

    malformed = get(ctx, "/api/users?after=#{after_boundary}x", ctx.admin_device.token)
    assert malformed.status == 400
    assert JSON.decode!(malformed.resp_body)["error"]["code"] == "invalid_cursor"

    {:ok, _rows} = DB.query(ctx.db, "UPDATE users SET isAdmin = 0 WHERE userId = 'flynn'", [])

    now_hidden =
      get(
        ctx,
        "/api/users?userId=cursor-a&userId=cursor-b&after=#{after_boundary}",
        ctx.admin_device.token
      )

    assert now_hidden.status == 200
    assert JSON.decode!(now_hidden.resp_body)["items"] == []
  end

  test "limit clamps at 500 and no cursor selects the newest page in tuple order", ctx do
    for index <- 1..501 do
      Devices.add_user(
        ctx.db,
        "page-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
        false
      )
    end

    response = get(ctx, "/api/users?limit=501", ctx.admin_device.token)
    body = JSON.decode!(response.resp_body)
    assert length(body["items"]) == 500
    assert body["items"] == Enum.sort_by(body["items"], &{&1["createdAt"], &1["userId"]})
    assert body["page"]["hasMoreBefore"]
    refute body["page"]["hasMoreAfter"]
  end

  test "a shared serializer refusal becomes closed projection_invalid with no partial item",
       ctx do
    {:ok, _rows} =
      DB.query(
        ctx.db,
        "UPDATE admin_projection_versions SET item = ?1 WHERE resource = 'identity' AND primaryKey = 'served'",
        [JSON.encode!(%{"name" => "served"})]
      )

    response = get(ctx, "/api/identity/served", ctx.admin_device.token)

    assert response.status == 500

    assert response.resp_body ==
             ~s({"schemaVersion":1,"resource":"identity","error":{"code":"projection_invalid"}})

    refute response.resp_body =~ ~s("item")
  end

  test "identity detail performs one metadata statement before denial and opens no payload",
       ctx do
    proxy = start_supervised!({QuerySpyDB, db: ctx.db})
    opts = Keyword.put(ctx.opts, :db, proxy)

    known = get_with_opts(opts, "/api/identity/served", ctx.operator_device.token)
    unknown = get_with_opts(opts, "/api/identity/missing-identity", ctx.operator_device.token)

    assert known.status == 404
    assert unknown.status == 404
    assert known.resp_body == unknown.resp_body
    assert get_resp_header(known, "cache-control") == ["no-store"]
    assert get_resp_header(unknown, "cache-control") == ["no-store"]

    all_queries = QuerySpyDB.queries(proxy)

    identity_queries =
      all_queries
      |> Enum.filter(fn {_sql, params} ->
        params in [["identity", "served"], ["identity", "missing-identity"]]
      end)

    assert [{known_sql, ["identity", "served"]}, {unknown_sql, ["identity", "missing-identity"]}] =
             identity_queries

    assert known_sql == unknown_sql
    refute String.contains?(known_sql, "item")

    refute Enum.any?(all_queries, fn {sql, _params} ->
             String.contains?(sql, "WITH observed AS")
           end)
  end

  test "identity collection applies shared visibility before its payload-bearing query", ctx do
    proxy = start_supervised!({QuerySpyDB, db: ctx.db})
    opts = Keyword.put(ctx.opts, :db, proxy)

    response = get_with_opts(opts, "/api/identity", ctx.operator_device.token)

    assert response.status == 200
    assert JSON.decode!(response.resp_body)["items"] == []

    refute Enum.any?(QuerySpyDB.queries(proxy), fn {sql, params} ->
             params == ["identity"] and String.contains?(sql, "SELECT item, rowVersion")
           end)
  end

  test "identity detail retries one stale race then returns canonical not_found", ctx do
    parent = self()

    proxy =
      start_supervised!(
        {QuerySpyDB,
         db: ctx.db,
         before_query: fn sql, params ->
           if match?(["identity", "served", 1, _row_version], params) and
                String.contains?(sql, "WITH observed AS") do
             {:ok, _rows} =
               DB.query(
                 ctx.db,
                 "UPDATE admin_projection_versions SET rowVersion = rowVersion + 1 WHERE resource = 'identity' AND primaryKey = 'served'",
                 []
               )

             send(parent, :identity_hydration_raced)
           end
         end}
      )

    response =
      get_with_opts(
        Keyword.put(ctx.opts, :db, proxy),
        "/api/identity/served",
        ctx.admin_device.token
      )

    assert response.status == 404

    assert response.resp_body ==
             ~s({"schemaVersion":1,"resource":"identity","error":{"code":"not_found"}})

    assert_received :identity_hydration_raced
    assert_received :identity_hydration_raced

    identity_queries =
      QuerySpyDB.queries(proxy)
      |> Enum.filter(fn {_sql, params} ->
        params == ["identity", "served"] or match?(["identity", "served", 1, _], params)
      end)

    assert length(identity_queries) == 4
  end

  test "D1 adds no REST serializer, projection, cursor module, or list seam" do
    source = File.read!(Path.expand("../lib/tightbeam/wire/router.ex", __DIR__))

    refute source =~ ~r/def(?:p)?\s+list_/
    refute source =~ "defmodule Tightbeam.RestCursor"
    refute source =~ "defmodule Tightbeam.RestEnvelope"
    refute source =~ ~r/def(?:p)?\s+rest_read\(/

    for class <-
          ~w(config.updated host_env.updated host.registered user.added identity.updated kungfu.updated) do
      row = Map.fetch!(Tightbeam.Firehose.Registry.rows(), class)
      assert is_atom(row.query)
      assert is_atom(row.serializer)
      assert is_atom(row.visibility)
      assert source =~ ~s(class: "#{class}")
    end
  end

  defp get(ctx, path, bearer) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp get_with_opts(opts, path, bearer) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> Router.call(Router.init(opts))
  end

  defp dispatch(ctx, bearer, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(body))
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-tightbeam-cli-version", CliCompatibility.required_version())
    |> Router.call(Router.init(ctx.opts))
  end

  defp start_http!(ctx) do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {Router, Router.init(ctx.opts)}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  defp http_get(port, path, bearer) do
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}")

    {:ok, {{_version, status, _reason}, headers, body}} =
      :httpc.request(
        :get,
        {url, [{~c"authorization", String.to_charlist("Bearer #{bearer}")}]},
        [{:timeout, 2_000}],
        body_format: :binary
      )

    {status, headers, body}
  end

  defp application_header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if key |> to_string() |> String.downcase() == name, do: to_string(value)
    end)
  end

  defp first_kungfu_name(db) do
    db
    |> StateResources.query_kungfu(%{})
    |> hd()
    |> Map.fetch!("name")
  end

  defp decode_cursor_payload(cursor) do
    [payload, _signature] = String.split(cursor, ".", parts: 2)
    payload |> Base.url_decode64!(padding: false) |> JSON.decode!()
  end

  defp hydrated_identity!(db, name, principal_binding) do
    request_binding = make_ref()

    try do
      {:ok, descriptor} =
        StateResources.query_identity(
          db,
          {:metadata, name, request_binding, principal_binding}
        )

      {:ok, identity} =
        StateResources.query_identity(
          db,
          {:hydrate, descriptor, request_binding, principal_binding}
        )

      identity
    after
      :ok = StateResources.query_identity(db, {:close, request_binding})
    end
  end
end
