defmodule Tightbeam.AdminProjectionTest.QuerySpyDB do
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
    query = normalize_query(sql, params)

    if is_function(state.before_query, 2) do
      state.before_query.(elem(query, 0), elem(query, 1))
    end

    {:reply, GenServer.call(state.db, request), %{state | queries: [query | state.queries]}}
  end

  def handle_call(request, _from, state), do: {:reply, GenServer.call(state.db, request), state}

  defp normalize_query(sql, params),
    do: {sql |> String.replace(~r/\s+/, " ") |> String.trim(), params}
end

defmodule Tightbeam.AdminProjectionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    AdminProjection,
    Archetypes,
    Credentials,
    DB,
    Devices,
    Gateway,
    Harness,
    Identity,
    Org,
    Placement,
    Roles,
    Schema,
    StateResources,
    StateVisibility
  }

  alias Tightbeam.Firehose.{Hub, Publisher, Registry}
  alias Tightbeam.AdminProjectionTest.QuerySpyDB

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tb-admin-projection-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"admin_projection_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: Path.join(base_dir, "state.db"), name: db})
    :ok = Schema.ensure_all(db)
    :ok = AdminProjection.bootstrap_served(db, base_dir)

    {:paired, _device} =
      claim_org(db, %{
        device_id: "admin-projection-device",
        claimed_name: "flynn",
        platform: nil,
        model: nil
      })

    Devices.add_user(db, "operator", false)

    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self())

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir, db: db}
  end

  test "A1 maps every ruled class both ways and A6 uses the exact shared item bytes", ctx do
    call =
      firehose_call("config", %{action: "set", setting: "default-archetype", value: "default"})

    assert %{changed: true} =
             Tightbeam.Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})["config"].(call)

    assert_notice("verb.accepted")
    config_notice = assert_notice("config.updated")

    harness = hd(Harness.all()).wire_name()
    host = Placement.local_host_name()

    assert %{changed: true} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "SAFE_ADMIN_TEST",
               "never-on-the-wire",
               "user:flynn",
               firehose_call("host-env-set", %{})
             )

    assert_notice("verb.accepted")
    host_env_notice = assert_notice("host_env.updated")

    assert {:ok, %{changed: true}} =
             Placement.register_host_with_firehose(
               ctx.db,
               "alpha",
               %{
                 ssh: "secret-user@alpha",
                 base_dir: "/secret/alpha",
                 cli_bin: "/secret/bin",
                 adapter_bin_dir: "/secret/adapters"
               },
               firehose_call("register-host", %{})
             )

    assert_notice("verb.accepted")
    host_notice = assert_notice("host.registered")

    assert %{changed: true} =
             Devices.promote_user_with_firehose(
               ctx.db,
               "operator",
               firehose_call("promote-user", %{})
             )

    assert_notice("verb.accepted")
    user_notice = assert_notice("user.promoted")

    identity = hydrated_identity!(ctx.db, "served")
    kungfu = StateResources.query_kungfu(ctx.db, "agentic-engineering")

    cases = [
      %{
        class: "config.updated",
        resource: "config",
        raw: StateResources.query_config(ctx.db, "default-archetype"),
        notice: config_notice,
        primary_refs: ["key"],
        query: :query_config,
        serializer: :config,
        visibility: :config_visible?,
        version_source: "admin_projection_versions",
        fields: ~w(key value updatedAt rowVersion),
        resource_classes: ["config.updated"]
      },
      %{
        class: "host_env.updated",
        resource: "host environment",
        raw: StateResources.query_host_environment(ctx.db, host, harness, "SAFE_ADMIN_TEST"),
        notice: host_env_notice,
        primary_refs: ["host", "harness", "name"],
        query: :query_host_environment,
        serializer: :host_environment,
        visibility: :host_environment_visible?,
        version_source: "admin_projection_versions+host_environment_projection",
        fields: ~w(host harness name value valuePresent updatedAt rowVersion),
        resource_classes: ["host_env.updated"]
      },
      %{
        class: "host.registered",
        resource: "hosts",
        raw: StateResources.query_host(ctx.db, "alpha"),
        notice: host_notice,
        primary_refs: ["host"],
        query: :query_host,
        serializer: :host,
        visibility: :host_visible?,
        version_source: "admin_projection_versions",
        fields: ~w(host rowVersion),
        resource_classes: ["host.registered"]
      },
      %{
        class: "user.promoted",
        resource: "users",
        raw: StateResources.query_user(ctx.db, "operator"),
        notice: user_notice,
        primary_refs: ["userId"],
        query: :query_user,
        serializer: :user,
        visibility: :user_visible?,
        version_source: "admin_projection_versions",
        fields: ~w(userId isAdmin createdAt rowVersion),
        resource_classes: ["user.added", "user.promoted"]
      },
      %{
        class: "identity.updated",
        resource: "identity",
        raw: identity,
        notice: Publisher.committed_notice("identity.updated", identity, %{"name" => "served"}),
        primary_refs: ["name"],
        query: :query_identity,
        serializer: :identity,
        visibility: :identity_visible?,
        version_source: "admin_projection_versions.publication_stamp",
        fields: ~w(name liveRevision state sessionRevisions staleness conflicts rowVersion),
        resource_classes: ["identity.updated"]
      },
      %{
        class: "kungfu.updated",
        resource: "kungfu",
        raw: kungfu,
        notice:
          Publisher.committed_notice("kungfu.updated", kungfu, %{
            "name" => "agentic-engineering"
          }),
        primary_refs: ["name"],
        query: :query_kungfu,
        serializer: :kungfu,
        visibility: :kungfu_visible?,
        version_source: "admin_projection_versions.publication_stamp",
        fields:
          ~w(name purpose phrases rootArchetype installedRevision status documents rowVersion),
        resource_classes: ["kungfu.updated"]
      }
    ]

    Enum.each(cases, fn expected ->
      row = Map.fetch!(Registry.rows(), expected.class)
      detail_item = apply(StateResources, row.serializer, [expected.raw])
      notice_item = expected.notice["payload"]
      detail_bytes = StateResources.encode_admin_item(expected.resource, detail_item)
      notice_bytes = StateResources.encode_admin_item(expected.resource, notice_item)

      assert row.resource == expected.resource
      assert row.op == "upsert"
      assert row.primary_refs == expected.primary_refs
      assert row.query == expected.query
      assert row.serializer == expected.serializer
      assert row.visibility == expected.visibility
      assert row.version_source == expected.version_source
      assert Enum.sort(Map.keys(detail_item)) == Enum.sort(expected.fields)
      assert detail_bytes == notice_bytes
      assert Publisher.encode_wire_notice(expected.notice) =~ ~s("payload":#{detail_bytes})
      assert_field_order(detail_bytes, expected.fields)

      assert expected.notice["refs"]
             |> Map.keys()
             |> Enum.filter(&(&1 in row.primary_refs))
             |> Enum.sort() == Enum.sort(row.primary_refs)

      assert Registry.rows()
             |> Enum.flat_map(fn {class, candidate} ->
               if candidate.resource == expected.resource, do: [class], else: []
             end)
             |> Enum.sort() == expected.resource_classes

      assert_raise ArgumentError, ~r/extra or missing/, fn ->
        apply(StateResources, row.serializer, [Map.put(detail_item, "unexpected", true)])
      end

      assert_raise ArgumentError, ~r/extra or missing/, fn ->
        apply(StateResources, row.serializer, [Map.delete(detail_item, hd(expected.fields))])
      end
    end)
  end

  test "M1 collections preserve detail shapes, freeze filters and order, and exclude secrets",
       ctx do
    :ok = Org.put_setting(ctx.db, "a-public-fixture", "public-fixture-value")
    config_secret = "m1-config-secret-7f47f03c"
    :ok = Org.put_setting(ctx.db, "z-private-fixture", config_secret)

    host_secret = "m1-host-secret-808e4d89"

    for name <- ~w(alpha-fixture zeta-fixture) do
      assert {:ok, _entry} =
               Placement.register_host(ctx.db, name, %{
                 ssh: "#{host_secret}@#{name}",
                 base_dir: "/#{host_secret}/#{name}",
                 cli_bin: "/#{host_secret}/tightbeam",
                 adapter_bin_dir: "/#{host_secret}/adapters"
               })
    end

    Devices.add_user(ctx.db, "zeta-fixture", false)
    Devices.add_user(ctx.db, "alpha-fixture", false)

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               "UPDATE users SET createdAt = 42 WHERE userId IN ('alpha-fixture', 'zeta-fixture')"
             )

    harness = hd(Harness.all()).wire_name()
    host = Placement.local_host_name()
    host_environment_secret = "m1-host-environment-secret-caa884bc"

    assert %{changed: true} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "M1_COLLECTION_SECRET",
               host_environment_secret,
               "user:flynn",
               firehose_call("host-env-set", %{})
             )

    kungfu_detail = StateResources.query_kungfu(ctx.db, "agentic-engineering")

    extra_kungfu =
      kungfu_detail
      |> Map.drop(["rowVersion"])
      |> Map.merge(%{
        "name" => "zeta-fixture",
        "purpose" => "Ordering fixture.",
        "phrases" => [],
        "rootArchetype" => "fixture-root",
        "installedRevision" => nil,
        "status" => "available",
        "documents" => []
      })

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               AdminProjection.seed_stamp_in_txn(
                 txn,
                 "kungfu",
                 "zeta-fixture",
                 "m1-collection-fixture",
                 extra_kungfu,
                 42
               )

               :ok
             end)

    public_identity = StateResources.identity(hydrated_identity!(ctx.db, "served"))

    cases = [
      %{
        resource: "config",
        collection: &StateResources.query_config(ctx.db, &1),
        detail: StateResources.query_config(ctx.db, "a-public-fixture"),
        serializer: &StateResources.config/1,
        primary: & &1["key"],
        order: & &1["key"],
        filters: [%{"key" => "a-public-fixture"}]
      },
      %{
        resource: "host environment",
        collection: &StateResources.query_host_environment(ctx.db, &1),
        detail:
          StateResources.query_host_environment(
            ctx.db,
            host,
            harness,
            "M1_COLLECTION_SECRET"
          ),
        serializer: &StateResources.host_environment/1,
        primary: &{&1["host"], &1["harness"], &1["name"]},
        order: &{&1["host"], &1["harness"], &1["name"]},
        filters: [
          %{"host" => host},
          %{"harness" => harness},
          %{"name" => "M1_COLLECTION_SECRET"},
          %{
            "host" => host,
            "harness" => harness,
            "name" => "M1_COLLECTION_SECRET"
          }
        ]
      },
      %{
        resource: "hosts",
        collection: &StateResources.query_host(ctx.db, &1),
        detail: StateResources.query_host(ctx.db, "alpha-fixture"),
        serializer: &StateResources.host/1,
        primary: & &1["host"],
        order: & &1["host"],
        filters: [%{"host" => "alpha-fixture"}]
      },
      %{
        resource: "users",
        collection: &StateResources.query_user(ctx.db, &1),
        detail: StateResources.query_user(ctx.db, "alpha-fixture"),
        serializer: &StateResources.user/1,
        primary: & &1["userId"],
        order: &{&1["createdAt"], &1["userId"]},
        filters: [%{"userId" => "alpha-fixture"}]
      },
      %{
        resource: "identity",
        collection: &StateResources.query_identity(ctx.db, &1),
        detail: hydrated_identity!(ctx.db, "served"),
        serializer: &StateResources.identity/1,
        primary: & &1["name"],
        order: & &1["name"],
        filters: [
          %{"name" => "served"},
          %{"state" => public_identity["state"]},
          %{
            "name" => "served",
            "state" => public_identity["state"]
          }
        ]
      },
      %{
        resource: "kungfu",
        collection: &StateResources.query_kungfu(ctx.db, &1),
        detail: kungfu_detail,
        serializer: &StateResources.kungfu/1,
        primary: & &1["name"],
        order: & &1["name"],
        filters: [
          %{"status" => kungfu_detail["status"]},
          %{"rootArchetype" => kungfu_detail["rootArchetype"]},
          %{
            "status" => kungfu_detail["status"],
            "rootArchetype" => kungfu_detail["rootArchetype"]
          }
        ]
      }
    ]

    Enum.each(cases, fn test_case ->
      detail_item = test_case.serializer.(test_case.detail)
      collection_items = Enum.map(test_case.collection.(%{}), test_case.serializer)

      assert Enum.map(collection_items, test_case.order) ==
               collection_items |> Enum.map(test_case.order) |> Enum.sort()

      assert Enum.find(
               collection_items,
               &(test_case.primary.(&1) == test_case.primary.(detail_item))
             ) ==
               detail_item

      assert StateResources.encode_admin_item(test_case.resource, detail_item) ==
               StateResources.encode_admin_item(
                 test_case.resource,
                 Enum.find(
                   collection_items,
                   &(test_case.primary.(&1) == test_case.primary.(detail_item))
                 )
               )

      Enum.each(test_case.filters, fn filters ->
        filtered_items = Enum.map(test_case.collection.(filters), test_case.serializer)
        assert detail_item in filtered_items

        assert Enum.all?(filtered_items, fn item ->
                 Enum.all?(filters, fn {field, value} -> item[field] == value end)
               end)
      end)
    end)

    for {query, allowed_filter} <- [
          {&StateResources.query_config(ctx.db, &1), "key"},
          {&StateResources.query_host(ctx.db, &1), "host"},
          {&StateResources.query_user(ctx.db, &1), "userId"},
          {&StateResources.query_identity(ctx.db, &1), "name"},
          {&StateResources.query_kungfu(ctx.db, &1), "status"}
        ] do
      assert_raise ArgumentError, ~r/unsupported .* collection filter/, fn ->
        query.(%{"notAllowlisted" => "value"})
      end

      assert_raise ArgumentError, ~r/collection filter .* must be a string/, fn ->
        query.(%{allowed_filter => 1})
      end
    end

    config_items = Enum.map(StateResources.query_config(ctx.db, %{}), &StateResources.config/1)
    private_config = Enum.find(config_items, &(&1["key"] == "z-private-fixture"))
    assert private_config["value"] == nil

    collection_bytes =
      cases
      |> Enum.flat_map(fn test_case ->
        Enum.map(test_case.collection.(%{}), fn row ->
          row
          |> test_case.serializer.()
          |> then(&StateResources.encode_admin_item(test_case.resource, &1))
        end)
      end)
      |> Enum.join("\n")

    refute collection_bytes =~ config_secret
    refute collection_bytes =~ host_secret
    refute collection_bytes =~ host_environment_secret
  end

  test "M1 visibility makes only host inventory AU4 and preserves firehose seams", ctx do
    assert StateVisibility.host_visible?(true)
    assert StateVisibility.host_visible?(false)

    for predicate <- [
          :config_visible?,
          :host_environment_visible?,
          :user_visible?,
          :identity_visible?,
          :kungfu_visible?
        ] do
      assert apply(StateVisibility, predicate, [true])
      refute apply(StateVisibility, predicate, [false])
    end

    expected = %{
      "config.updated" => {:query_config, :config, :config_visible?},
      "host_env.updated" =>
        {:query_host_environment, :host_environment, :host_environment_visible?},
      "host.registered" => {:query_host, :host, :host_visible?},
      "user.added" => {:query_user, :user, :user_visible?},
      "user.promoted" => {:query_user, :user, :user_visible?},
      "identity.updated" => {:query_identity, :identity, :identity_visible?},
      "kungfu.updated" => {:query_kungfu, :kungfu, :kungfu_visible?}
    }

    assert Map.new(expected, fn {class, mapping} ->
             row = Map.fetch!(Registry.rows(), class)
             assert {row.query, row.serializer, row.visibility} == mapping
             {class, mapping}
           end) == expected

    host_notice = %{
      "class" => "host.registered",
      "refs" => %{"host" => "fixture"},
      "payload" => %{"host" => "fixture", "rowVersion" => 1}
    }

    assert StateVisibility.visible?(ctx.db, host_notice, "operator", false)

    for class <-
          ~w(config.updated host_env.updated user.added user.promoted identity.updated kungfu.updated) do
      refute StateVisibility.visible?(
               ctx.db,
               %{"class" => class, "refs" => %{}, "payload" => %{}},
               "operator",
               false
             )
    end
  end

  test "identity metadata lookups use the same canonical statement for known forbidden and unknown names",
       ctx do
    proxy = start_supervised!({QuerySpyDB, db: ctx.db})
    admin = principal_binding("flynn", true)
    forbidden = principal_binding("operator", false)

    assert {:ok, known_descriptor} =
             StateResources.query_identity(proxy, {:metadata, "served", make_ref(), admin})

    assert is_binary(known_descriptor)

    assert {:ok, forbidden_descriptor} =
             StateResources.query_identity(proxy, {:metadata, "served", make_ref(), forbidden})

    assert is_binary(forbidden_descriptor)

    assert {:ok, unknown_descriptor} =
             StateResources.query_identity(
               proxy,
               {:metadata, "missing-identity", make_ref(), admin}
             )

    assert is_binary(unknown_descriptor)

    assert [
             {known_sql, known_params},
             {forbidden_sql, forbidden_params},
             {unknown_sql, unknown_params}
           ] = QuerySpyDB.queries(proxy)

    assert known_sql ==
             "SELECT CASE WHEN v.rowVersion IS NULL THEN 0 ELSE 1 END AS present, v.rowVersion " <>
               "FROM (SELECT ?1 AS resource, ?2 AS primaryKey) AS seed " <>
               "LEFT JOIN admin_projection_versions AS v " <>
               "ON v.resource = seed.resource AND v.primaryKey = seed.primaryKey"

    assert forbidden_sql == known_sql
    assert unknown_sql == known_sql
    assert known_params == forbidden_params
    assert length(known_params) == 2
    assert length(unknown_params) == 2
  end

  test "identity visibility applies after metadata and hidden names leak no payload oracle",
       ctx do
    proxy = start_supervised!({QuerySpyDB, db: ctx.db})
    hidden = principal_binding("operator", false)
    visible = principal_binding("flynn", true)

    assert public_identity_or_absent(proxy, "served", hidden, false) == :absent
    assert public_identity_or_absent(proxy, "missing-identity", hidden, false) == :absent

    assert {:visible, %{"name" => "served"} = visible_identity} =
             public_identity_or_absent(proxy, "served", visible, true)

    assert [
             {hidden_known_sql, _hidden_known_params},
             {hidden_unknown_sql, _hidden_unknown_params},
             {visible_metadata_sql, _visible_metadata_params},
             {visible_hydration_sql, _visible_hydration_params}
           ] = QuerySpyDB.queries(proxy)

    assert hidden_known_sql ==
             "SELECT CASE WHEN v.rowVersion IS NULL THEN 0 ELSE 1 END AS present, v.rowVersion " <>
               "FROM (SELECT ?1 AS resource, ?2 AS primaryKey) AS seed " <>
               "LEFT JOIN admin_projection_versions AS v " <>
               "ON v.resource = seed.resource AND v.primaryKey = seed.primaryKey"

    assert hidden_unknown_sql == hidden_known_sql
    assert visible_metadata_sql == hidden_known_sql

    assert visible_identity ==
             StateResources.identity(hydrated_identity!(ctx.db, "served"))

    assert String.contains?(
             visible_hydration_sql,
             "SELECT item, rowVersion FROM admin_projection_versions"
           )

    assert String.contains?(visible_hydration_sql, "WHEN EXISTS(SELECT 1 FROM matched) THEN 'ok'")
  end

  test "identity hydration rejects wrong principals and request bindings before database access",
       ctx do
    proxy = start_supervised!({QuerySpyDB, db: ctx.db})
    admin = principal_binding("flynn", true)
    request_binding = make_ref()

    assert {:ok, descriptor} =
             StateResources.query_identity(proxy, {:metadata, "served", request_binding, admin})

    assert {:error, :invalid_identity_descriptor} =
             StateResources.query_identity(
               proxy,
               {:hydrate, descriptor, request_binding, principal_binding("operator", true)}
             )

    assert [{_metadata_sql, _metadata_params}] = QuerySpyDB.queries(proxy)

    assert {:error, :invalid_identity_descriptor} =
             StateResources.query_identity(
               proxy,
               {:hydrate, descriptor, make_ref(), admin}
             )

    assert [{_metadata_sql, _metadata_params}] = QuerySpyDB.queries(proxy)
  end

  test "identity staged seam rejects absent and malformed principals before payload access",
       ctx do
    proxy = start_supervised!({QuerySpyDB, db: ctx.db})
    request_binding = make_ref()

    assert {:error, :invalid_identity_descriptor} =
             StateResources.query_identity(proxy, {:metadata, "served", request_binding, nil})

    assert {:error, :invalid_identity_descriptor} =
             StateResources.query_identity(
               proxy,
               {:metadata, "served", request_binding, "user:flynn"}
             )

    assert [] = QuerySpyDB.queries(proxy)

    admin = principal_binding("flynn", true)

    assert {:ok, descriptor} =
             StateResources.query_identity(proxy, {:metadata, "served", request_binding, admin})

    assert [{_metadata_sql, _metadata_params}] = QuerySpyDB.queries(proxy)

    assert {:error, :invalid_identity_descriptor} =
             StateResources.query_identity(proxy, {:hydrate, descriptor, request_binding, nil})

    assert [{_metadata_sql, _metadata_params}] = QuerySpyDB.queries(proxy)

    assert {:error, :invalid_identity_descriptor} =
             StateResources.query_identity(
               proxy,
               {:hydrate, descriptor, request_binding, "user:flynn"}
             )

    assert [{_metadata_sql, _metadata_params}] = QuerySpyDB.queries(proxy)
  end

  test "identity descriptors stay reusable only inside the open operation and close before replay",
       ctx do
    proxy = start_supervised!({QuerySpyDB, db: ctx.db})
    principal = principal_binding("flynn", true)
    request_binding = make_ref()

    assert {:ok, descriptor} =
             StateResources.query_identity(
               proxy,
               {:metadata, "served", request_binding, principal}
             )

    assert {:ok, first} =
             StateResources.query_identity(
               proxy,
               {:hydrate, descriptor, request_binding, principal}
             )

    assert {:ok, second} =
             StateResources.query_identity(
               proxy,
               {:hydrate, descriptor, request_binding, principal}
             )

    assert first == second
    query_count = length(QuerySpyDB.queries(proxy))

    assert :ok = StateResources.query_identity(proxy, {:close, request_binding})

    assert {:error, :invalid_identity_descriptor} =
             StateResources.query_identity(
               proxy,
               {:hydrate, descriptor, request_binding, principal}
             )

    assert length(QuerySpyDB.queries(proxy)) == query_count
  end

  test "identity hydration reports stale after a row-version race", ctx do
    call = firehose_call("identity-edit", %{})
    entries = AdminProjection.served_entries(ctx.db, ctx.base_dir)
    identity = Enum.find(entries, &(&1.resource == "identity"))
    principal = principal_binding("flynn", true)
    request_binding = make_ref()

    assert {:ok, descriptor} =
             StateResources.query_identity(
               ctx.db,
               {:metadata, "served", request_binding, principal}
             )

    changed = put_in(identity.item["liveRevision"], "staged-race-next")

    assert {:ok, [_item]} = AdminProjection.stamp_publication(ctx.db, call, [changed])
    assert_notice("verb.accepted")
    assert_notice("identity.updated")

    assert :stale =
             StateResources.query_identity(
               ctx.db,
               {:hydrate, descriptor, request_binding, principal}
             )
  end

  test "identity-status binds org role calls to one resolved principal across a stale retry",
       ctx do
    create_session!(ctx.db, "agent:identity-role-primary", "flynn")
    create_session!(ctx.db, "agent:identity-role-rebound", "operator")
    Roles.create!(ctx.db, "identity-reviewer", "flynn", "agent:identity-role-primary")

    call = firehose_call("identity-edit", %{})
    entries = AdminProjection.served_entries(ctx.db, ctx.base_dir)
    identity = Enum.find(entries, &(&1.resource == "identity"))
    changed = put_in(identity.item["liveRevision"], "staged-role-retry")

    parent = self()
    {:ok, hook_state} = Agent.start_link(fn -> false end)

    proxy =
      start_supervised!(
        {QuerySpyDB,
         db: ctx.db,
         before_query: fn sql, _params ->
           if String.contains?(sql, "WITH observed AS") do
             should_fire = Agent.get_and_update(hook_state, fn fired -> {not fired, true} end)

             if should_fire do
               assert :ok = Roles.bind(ctx.db, "identity-reviewer", "agent:identity-role-rebound")
               assert {:ok, [_item]} = AdminProjection.stamp_publication(ctx.db, call, [changed])
               send(parent, :role_retry_rebound)
             end
           end
         end}
      )

    actual =
      Gateway.handlers(%{db: proxy, base_dir: ctx.base_dir})["identity-status"].(%{
        origin: "agent:identity-reviewer",
        principal: nil,
        params: %{}
      })

    assert_receive :role_retry_rebound
    assert actual.identity == StateResources.identity(hydrated_identity!(ctx.db, "served"))

    assert [
             {metadata_sql, _metadata_params},
             {hydration_sql, _hydration_params},
             {retry_metadata_sql, _retry_metadata_params},
             {retry_hydration_sql, _retry_hydration_params}
           ] = identity_stage_queries(proxy)

    assert metadata_sql == retry_metadata_sql
    assert String.contains?(hydration_sql, "WITH observed AS")
    assert retry_hydration_sql == hydration_sql
  end

  test "identity-status rechecks visibility after a stale refresh and stops before retry hydration",
       ctx do
    call = firehose_call("identity-edit", %{})
    entries = AdminProjection.served_entries(ctx.db, ctx.base_dir)
    identity = Enum.find(entries, &(&1.resource == "identity"))
    changed = put_in(identity.item["liveRevision"], "staged-visibility-loss")

    parent = self()
    {:ok, hook_state} = Agent.start_link(fn -> false end)

    proxy =
      start_supervised!(
        {QuerySpyDB,
         db: ctx.db,
         before_query: fn sql, _params ->
           if String.contains?(sql, "WITH observed AS") do
             should_fire = Agent.get_and_update(hook_state, fn fired -> {not fired, true} end)

             if should_fire do
               Devices.set_user_admin(ctx.db, "flynn", false)
               assert {:ok, [_item]} = AdminProjection.stamp_publication(ctx.db, call, [changed])
               send(parent, :visibility_lost_before_retry)
             end
           end
         end}
      )

    actual =
      Gateway.handlers(%{db: proxy, base_dir: ctx.base_dir})["identity-status"].(%{
        origin: "user:flynn",
        principal: nil,
        params: %{}
      })

    assert_receive :visibility_lost_before_retry
    assert actual.identity == nil

    assert [
             {metadata_sql, _metadata_params},
             {hydration_sql, _hydration_params},
             {retry_metadata_sql, _retry_metadata_params}
           ] = identity_stage_queries(proxy)

    assert metadata_sql == retry_metadata_sql
    assert String.contains?(hydration_sql, "WITH observed AS")
  end

  test "identity-status preserves the served identity through the staged query seam", ctx do
    call = %{origin: "user:flynn", params: %{}}

    expected = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})["identity-status"].(call)

    proxy = start_supervised!({QuerySpyDB, db: ctx.db})

    actual = Gateway.handlers(%{db: proxy, base_dir: ctx.base_dir})["identity-status"].(call)

    assert actual.identity == expected.identity

    assert Enum.any?(QuerySpyDB.queries(proxy), fn
             {"SELECT CASE WHEN v.rowVersion IS NULL THEN 0 ELSE 1 END AS present, v.rowVersion " <>
                  "FROM (SELECT ?1 AS resource, ?2 AS primaryKey) AS seed " <>
                  "LEFT JOIN admin_projection_versions AS v " <>
                  "ON v.resource = seed.resource AND v.primaryKey = seed.primaryKey",
              ["identity", "served"]} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(QuerySpyDB.queries(proxy), fn
             {sql, _params} when is_binary(sql) ->
               String.contains?(sql, "SELECT item, rowVersion FROM admin_projection_versions")

             _ ->
               false
           end)
  end

  test "identity sessionRevisions use Unicode key order above the BEAM map threshold" do
    numbered_keys =
      Enum.map(1..40, &"session-#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

    ordered_keys = ["alpha" | numbered_keys] ++ ["éclair", "Ωmega", "😀"]

    session_revisions =
      ordered_keys
      |> Enum.reverse()
      |> Map.new(fn key -> {key, "revision-for-#{key}"} end)

    raw = %{
      name: "served",
      live_revision: "live-revision",
      state: "ready",
      session_revisions: session_revisions,
      staleness: [],
      conflicts: [],
      row_version: 1
    }

    expected_map_bytes =
      "{" <>
        Enum.map_join(ordered_keys, ",", fn key ->
          JSON.encode!(key) <> ":" <> JSON.encode!(Map.fetch!(session_revisions, key))
        end) <> "}"

    item = StateResources.identity(raw)
    item_bytes = StateResources.encode_admin_item("identity", item)
    notice = Publisher.committed_notice("identity.updated", raw, %{"name" => "served"})
    wire_bytes = Publisher.encode_wire_notice(notice)

    assert item_bytes =~ ~s("sessionRevisions":#{expected_map_bytes})
    assert wire_bytes =~ ~s("payload":#{item_bytes})
  end

  test "DB-backed resources allocate only for material commits and retain absent markers", ctx do
    handlers = Tightbeam.Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})

    config_call =
      firehose_call("config", %{action: "set", setting: "default-archetype", value: "default"})

    assert %{changed: true} = handlers["config"].(config_call)
    assert_notice("verb.accepted")
    first_config = assert_notice("config.updated")["payload"]

    assert %{changed: false} = handlers["config"].(config_call)
    assert_notice("verb.accepted")
    refute_receive {:firehose_notice, %{"class" => "config.updated"}}

    assert StateResources.query_config(ctx.db, "default-archetype").row_version ==
             first_config["rowVersion"]

    :ok = Org.put_setting(ctx.db, "private-token", "tbc_config_secret_12345678")
    private_config = StateResources.query_config(ctx.db, "private-token")
    private_config_version = private_config.row_version
    assert StateResources.config(private_config)["value"] == nil
    refute JSON.encode!(StateResources.config(private_config)) =~ "config_secret"

    :ok = Org.put_setting(ctx.db, "private-token", "tbc_config_secret_12345678")

    assert StateResources.query_config(ctx.db, "private-token").row_version ==
             private_config_version

    harness = hd(Harness.all()).wire_name()
    host = Placement.local_host_name()
    call = firehose_call("host-env-set", %{})

    assert %{changed: true} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "ROTATING_SECRET",
               "first-secret",
               "user:flynn",
               call
             )

    assert_notice("verb.accepted")
    present = assert_notice("host_env.updated")["payload"]
    assert present["value"] == nil
    assert present["valuePresent"]

    assert %{changed: false} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "ROTATING_SECRET",
               "first-secret",
               "user:flynn",
               call
             )

    assert_notice("verb.accepted")
    refute_receive {:firehose_notice, %{"class" => "host_env.updated"}}

    assert %{changed: true} =
             Placement.unset_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "ROTATING_SECRET",
               firehose_call("host-env-unset", %{})
             )

    assert_notice("verb.accepted")
    absent = assert_notice("host_env.updated")["payload"]
    refute absent["valuePresent"]
    assert absent["rowVersion"] > present["rowVersion"]
    assert Placement.env_overlays(ctx.db) == []

    retained = StateResources.query_host_environment(ctx.db, host, harness, "ROTATING_SECRET")
    refute retained.value_present
    assert retained.row_version == absent["rowVersion"]

    assert %{changed: false, projection: ^retained} =
             Placement.unset_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "ROTATING_SECRET",
               firehose_call("host-env-unset", %{})
             )

    assert_notice("verb.accepted")
    refute_receive {:firehose_notice, %{"class" => "host_env.updated"}}

    assert %{changed: false, projection: nil} =
             Placement.unset_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "NEVER_EXISTED",
               firehose_call("host-env-unset", %{})
             )

    assert_notice("verb.accepted")
    refute_receive {:firehose_notice, %{"class" => "host_env.updated"}}

    assert %{changed: true} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "ROTATING_SECRET",
               "second-secret",
               "user:flynn",
               call
             )

    assert_notice("verb.accepted")
    reset = assert_notice("host_env.updated")["payload"]
    assert reset["valuePresent"]
    assert reset["rowVersion"] > absent["rowVersion"]

    created_at = StateResources.query_user(ctx.db, "operator").created_at

    assert %{changed: true} =
             Devices.promote_user_with_firehose(
               ctx.db,
               "operator",
               firehose_call("promote-user", %{})
             )

    assert_notice("verb.accepted")
    promoted = assert_notice("user.promoted")["payload"]
    assert promoted["createdAt"] == created_at

    assert %{changed: false} =
             Devices.promote_user_with_firehose(
               ctx.db,
               "operator",
               firehose_call("promote-user", %{})
             )

    assert_notice("verb.accepted")
    refute_receive {:firehose_notice, %{"class" => "user.promoted"}}
  end

  test "version floors serialize concurrent commits, roll back, and survive restart", ctx do
    versions =
      1..16
      |> Enum.map(fn _index ->
        Task.async(fn ->
          {:ok, version} =
            DB.transaction(ctx.db, fn txn ->
              AdminProjection.allocate_in_txn(
                txn,
                "config",
                "concurrent-key",
                System.system_time(:millisecond)
              )
            end)

          version
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.sort(versions) == Enum.to_list(1..16)

    assert {:error, %RuntimeError{message: "rollback"}} =
             DB.transaction(ctx.db, fn txn ->
               AdminProjection.allocate_in_txn(
                 txn,
                 "config",
                 "concurrent-key",
                 System.system_time(:millisecond)
               )

               raise "rollback"
             end)

    assert AdminProjection.version(ctx.db, "config", "concurrent-key") == 16

    assert {:error, %RuntimeError{message: "rollback with notice"}} =
             DB.transaction(ctx.db, fn txn ->
               updated_at = System.system_time(:millisecond)

               row_version =
                 AdminProjection.allocate_in_txn(
                   txn,
                   "config",
                   "rolled-back-key",
                   updated_at
                 )

               Publisher.committed_in_txn(
                 txn,
                 "config.updated",
                 %{
                   key: "rolled-back-key",
                   value: nil,
                   updated_at: updated_at,
                   row_version: row_version
                 },
                 %{"key" => "rolled-back-key"}
               )

               raise "rollback with notice"
             end)

    assert AdminProjection.version(ctx.db, "config", "rolled-back-key") == nil
    refute_receive {:firehose_notice, %{"class" => "config.updated"}}

    path = Path.join(ctx.base_dir, "state.db")
    :ok = stop_supervised(DB)
    {:ok, restarted} = DB.start_link(path: path, name: ctx.db)
    Process.unlink(restarted)
    :ok = Schema.ensure_all(ctx.db)

    assert AdminProjection.version(ctx.db, "config", "concurrent-key") == 16
  end

  test "publication stamps are byte-idempotent and failures leave a durable loud fault", ctx do
    call = firehose_call("identity-edit", %{})
    entries = AdminProjection.served_entries(ctx.db, ctx.base_dir)

    assert {:ok, []} = AdminProjection.stamp_publication(ctx.db, call, entries)
    assert_notice("verb.accepted")

    refute_receive {:firehose_notice, %{"class" => "identity.updated"}}
    refute_receive {:firehose_notice, %{"class" => "kungfu.updated"}}

    identity = Enum.find(entries, &(&1.resource == "identity"))
    changed = put_in(identity.item["liveRevision"], "published-next")

    assert {:ok, [_item]} = AdminProjection.stamp_publication(ctx.db, call, [changed])
    assert_notice("verb.accepted")
    assert_notice("identity.updated")

    before_failure = hydrated_identity!(ctx.db, "served")
    failed = put_in(changed.item["liveRevision"], "published-but-unstamped")

    assert {:error, %{code: "projection_stamp_failed"}} =
             AdminProjection.stamp_publication(ctx.db, call, [failed],
               before_stamp: fn _txn -> raise "forced stamp failure" end
             )

    refute_receive {:firehose_notice, _notice}
    assert hydrated_identity!(ctx.db, "served") == before_failure

    assert {:ok, [["projection_stamp_failed", detail]]} =
             DB.query(
               ctx.db,
               "SELECT code, detail FROM admin_projection_faults WHERE resource = 'identity' AND primaryKey = 'served'"
             )

    assert detail =~ "forced stamp failure"
  end

  test "a failed Git publication does not advance a stamp or emit state", ctx do
    before = hydrated_identity!(ctx.db, "served")
    identity_dir = Path.join(ctx.base_dir, "identity")
    main = git!(identity_dir, ["rev-parse", "main"])

    divergent =
      git!(identity_dir, [
        "-c",
        "user.name=projection-test",
        "-c",
        "user.email=projection@test.invalid",
        "commit-tree",
        "#{main}^{tree}",
        "-m",
        "divergent live"
      ])

    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/live", divergent])

    handler =
      Tightbeam.Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})["identity-edit"]

    assert_raise ArgumentError, "tightbeam/live cannot fast-forward to main", fn ->
      handler.(
        firehose_call("identity-edit", %{
          archetype: "default",
          content: "# unpublished identity change\n"
        })
      )
    end

    assert hydrated_identity!(ctx.db, "served") == before
    refute_receive {:firehose_notice, _notice}
  end

  test "fresh queries and buffered notices converge by primary key and rowVersion", ctx do
    handlers = Tightbeam.Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})
    notices = []

    assert %{changed: true} =
             handlers["config"].(
               firehose_call("config", %{
                 action: "set",
                 setting: "default-archetype",
                 value: "default"
               })
             )

    assert_notice("verb.accepted")
    notices = [assert_notice("config.updated") | notices]
    harness = hd(Harness.all()).wire_name()
    host = Placement.local_host_name()

    assert %{changed: true} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "REBUILD_SECRET",
               "never rebuild this value",
               "user:flynn",
               firehose_call("host-env-set", %{})
             )

    assert_notice("verb.accepted")
    notices = [assert_notice("host_env.updated") | notices]

    assert %{changed: true} =
             Placement.unset_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "REBUILD_SECRET",
               firehose_call("host-env-unset", %{})
             )

    assert_notice("verb.accepted")
    notices = [assert_notice("host_env.updated") | notices]

    assert {:ok, %{changed: true}} =
             Placement.register_host_with_firehose(
               ctx.db,
               "rebuild-alpha",
               %{
                 ssh: "secret-user@rebuild-alpha",
                 base_dir: "/secret/rebuild-alpha",
                 cli_bin: "/secret/cli",
                 adapter_bin_dir: "/secret/adapters"
               },
               firehose_call("register-host", %{})
             )

    assert_notice("verb.accepted")
    notices = [assert_notice("host.registered") | notices]

    assert %{changed: true} =
             Devices.promote_user_with_firehose(
               ctx.db,
               "operator",
               firehose_call("promote-user", %{})
             )

    assert_notice("verb.accepted")
    notices = [assert_notice("user.promoted") | notices]

    assert %{kungfu: "rebuild-demo"} =
             handlers["kungfu-scaffold"].(
               firehose_call("kungfu-scaffold", %{
                 name: "rebuild-demo",
                 purpose: "Prove safe rebuild convergence."
               })
             )

    assert_notice("verb.accepted")
    identity_notice = assert_notice("identity.updated")
    kungfu_notice = assert_notice("kungfu.updated")
    notices = [kungfu_notice, identity_notice | notices]

    fresh =
      [
        {"config", "default-archetype",
         StateResources.config(StateResources.query_config(ctx.db, "default-archetype"))},
        {"host environment", AdminProjection.key([host, harness, "REBUILD_SECRET"]),
         StateResources.host_environment(
           StateResources.query_host_environment(ctx.db, host, harness, "REBUILD_SECRET")
         )},
        {"hosts", "rebuild-alpha",
         StateResources.host(StateResources.query_host(ctx.db, "rebuild-alpha"))},
        {"users", "operator", StateResources.user(StateResources.query_user(ctx.db, "operator"))},
        {"identity", "served", StateResources.identity(hydrated_identity!(ctx.db, "served"))},
        {"kungfu", "rebuild-demo",
         StateResources.kungfu(StateResources.query_kungfu(ctx.db, "rebuild-demo"))}
      ]
      |> Map.new(fn {resource, key, item} ->
        {{resource, key}, {item["rowVersion"], StateResources.encode_admin_item(resource, item)}}
      end)

    buffered =
      notices
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn notice, model ->
        resource = notice["resource"]
        item = notice["payload"]
        key = notice_primary_key(notice)
        candidate = {item["rowVersion"], StateResources.encode_admin_item(resource, item)}

        Map.update(model, {resource, key}, candidate, fn {version, _bytes} = current ->
          if item["rowVersion"] > version, do: candidate, else: current
        end)
      end)

    assert buffered == fresh

    {_version, absent_bytes} =
      fresh[{"host environment", AdminProjection.key([host, harness, "REBUILD_SECRET"])}]

    refute absent_bytes =~ "never rebuild this value"
  end

  test "kungfu projection sanitizes content and excludes paths structurally", ctx do
    :ok = Org.put_setting(ctx.db, "private-token", "tbc_config_secret_12345678")

    config_item =
      ctx.db
      |> StateResources.query_config("private-token")
      |> StateResources.config()

    assert config_item["value"] == nil
    refute JSON.encode!(config_item) =~ "config_secret"

    assert {:ok, _entry} =
             Placement.register_host(ctx.db, "secret-host", %{
               ssh: "credential-user@secret-host",
               base_dir: "/home/credential-user/tightbeam",
               cli_bin: "/home/credential-user/tightbeam/bin/tightbeam",
               adapter_bin_dir: "/home/credential-user/.credentials"
             })

    host_item =
      ctx.db
      |> StateResources.query_host("secret-host")
      |> StateResources.host()

    refute JSON.encode!(host_item) =~ "credential-user"

    harness = hd(Harness.all()).wire_name()
    host = Placement.local_host_name()

    assert %{projection: host_environment} =
             Placement.set_env_overlay_with_firehose(
               ctx.db,
               host,
               harness,
               "SECRET_INJECTION",
               "host-environment-secret-12345678",
               "user:flynn",
               firehose_call("host-env-set", %{})
             )

    refute host_environment |> StateResources.host_environment() |> JSON.encode!() =~
             "host-environment-secret"

    source = Path.join(ctx.base_dir, "source-kungfu")
    File.mkdir_p!(source)

    File.write!(
      Path.join(source, "manifest.toml"),
      """
      purpose = "Safe projection test bundle."
      phrases = ["z phrase", "a phrase"]
      root_archetype = "default"
      """
    )

    banked_secret = "opaque-bank-value-7f4d3c2b1a998877"

    credential =
      Credentials.credential_path(
        ctx.base_dir,
        Placement.local_host_name(),
        :fixture_provider
      )

    File.mkdir_p!(Path.dirname(credential))
    File.write!(credential, banked_secret)

    secret_content = """
    token = tbs_1234567890abcdef
    authorization: Bearer credential-value-12345678
    password = credential-password-12345678
    api_key: sk-1234567890abcdef
    The banked value appears verbatim: #{banked_secret}
    -----BEGIN OPENSSH PRIVATE KEY-----
    private-material
    -----END OPENSSH PRIVATE KEY-----
    #{ctx.base_dir}/credentials/provider.json
    /home/alice/.ssh/id_ed25519
    """

    File.write!(Path.join(source, "capabilities.md"), secret_content)
    File.write!(Path.join(source, "preferred-models.md"), "models are public\n")
    File.write!(Path.join(source, "intake.md"), "non-allowlisted\n")

    Application.put_env(:tightbeam, :identity_source_dir, source)
    assert {:ok, _revision} = Identity.learn!(ctx.base_dir, "agentic-engineering", "user:flynn")

    identity_dir = Path.join(ctx.base_dir, "identity")

    File.ln_s!(
      "/home/alice/private",
      Path.join(identity_dir, "kungfu/agentic-engineering/README.md")
    )

    File.write!(Path.join(identity_dir, "kungfu/agentic-engineering/.hidden"), "hidden-secret")
    git!(identity_dir, ["add", "-A"])

    git!(identity_dir, [
      "-c",
      "user.name=projection-test",
      "-c",
      "user.email=projection@test.invalid",
      "commit",
      "-m",
      "test unsafe document shapes"
    ])

    live = git!(identity_dir, ["rev-parse", "main"])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/live", live])

    item = Identity.public_kungfu(ctx.base_dir, "agentic-engineering")
    assert item["phrases"] == ["a phrase", "z phrase"]

    assert Enum.map(item["documents"], & &1["path"]) ==
             ["capabilities.md", "preferred-models.md"]

    encoded = JSON.encode!(item)
    refute encoded =~ "1234567890abcdef"
    refute encoded =~ "credential-value"
    refute encoded =~ "credential-password"
    refute encoded =~ banked_secret
    refute encoded =~ "private-material"
    refute encoded =~ ctx.base_dir
    refute encoded =~ "/home/alice"
    refute encoded =~ "non-allowlisted"
    refute encoded =~ "hidden-secret"
    assert encoded =~ "[redacted-secret]"
    assert encoded =~ "[redacted-host-path]"

    raw_item = Map.put(item, "rowVersion", 1)
    shared_item = StateResources.kungfu(raw_item)
    shared_bytes = StateResources.encode_admin_item("kungfu", shared_item)

    notice =
      Publisher.committed_notice("kungfu.updated", raw_item, %{
        "name" => "agentic-engineering"
      })

    wire_bytes = Publisher.encode_wire_notice(notice)
    assert wire_bytes =~ ~s("payload":#{shared_bytes})
    refute shared_bytes =~ banked_secret
    refute wire_bytes =~ banked_secret

    assert_raise ArgumentError, ~r/invalid kungfu name/, fn ->
      Identity.public_kungfu(ctx.base_dir, "../agentic-engineering")
    end
  end

  defp firehose_call(verb, params) do
    %{
      verb: verb,
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: params,
      firehose_in_txn: true
    }
  end

  defp assert_notice(class) do
    assert_receive {:firehose_notice, %{"class" => ^class} = notice}
    Hub.delivered(Hub, self())
    notice
  end

  defp assert_field_order(bytes, fields) do
    positions =
      Enum.map(fields, fn field ->
        {position, _length} = :binary.match(bytes, JSON.encode!(field) <> ":")
        position
      end)

    assert positions == Enum.sort(positions)
  end

  defp public_identity_or_absent(db, name, principal_binding, is_admin) do
    request_binding = make_ref()

    try do
      assert {:ok, descriptor} =
               StateResources.query_identity(
                 db,
                 {:metadata, name, request_binding, principal_binding}
               )

      if StateVisibility.identity_visible?(is_admin) do
        assert {:ok, item} =
                 StateResources.query_identity(
                   db,
                   {:hydrate, descriptor, request_binding, principal_binding}
                 )

        {:visible, StateResources.identity(item)}
      else
        :absent
      end
    after
      assert :ok = StateResources.query_identity(db, {:close, request_binding})
    end
  end

  defp hydrated_identity!(db, name) do
    request_binding = make_ref()
    principal_binding = principal_binding("flynn", true)

    try do
      assert {:ok, descriptor} =
               StateResources.query_identity(
                 db,
                 {:metadata, name, request_binding, principal_binding}
               )

      assert {:ok, item} =
               StateResources.query_identity(
                 db,
                 {:hydrate, descriptor, request_binding, principal_binding}
               )

      item
    after
      assert :ok = StateResources.query_identity(db, {:close, request_binding})
    end
  end

  defp principal_binding(user_id, _is_admin), do: {:user, user_id}

  defp identity_stage_queries(proxy) do
    QuerySpyDB.queries(proxy)
    |> Enum.filter(fn
      {sql, ["identity", "served" | _rest]} when is_binary(sql) ->
        String.starts_with?(sql, "SELECT CASE WHEN v.rowVersion IS NULL THEN 0 ELSE 1 END") or
          String.contains?(sql, "WITH observed AS")

      _ ->
        false
    end)
  end

  defp create_session!(db, key, owner) do
    ensure_main_session(db, owner)

    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable"),
      host: "testhost"
    })
  end

  defp notice_primary_key(%{"resource" => "host environment", "refs" => refs}) do
    AdminProjection.key([refs["host"], refs["harness"], refs["name"]])
  end

  defp notice_primary_key(%{"resource" => "config", "refs" => refs}), do: refs["key"]
  defp notice_primary_key(%{"resource" => "hosts", "refs" => refs}), do: refs["host"]
  defp notice_primary_key(%{"resource" => "users", "refs" => refs}), do: refs["userId"]

  defp notice_primary_key(%{"resource" => resource, "refs" => refs})
       when resource in ~w(identity kungfu),
       do: refs["name"]

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed #{status}: #{output}"
    end
  end
end
