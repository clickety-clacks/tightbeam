defmodule Tightbeam.AdminProjectionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    AdminProjection,
    Archetypes,
    DB,
    Devices,
    Harness,
    Identity,
    Org,
    Placement,
    Schema,
    StateResources
  }

  alias Tightbeam.Firehose.{Hub, Publisher, Registry}

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

    Devices.add_user(db, "flynn", true)
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

    identity = StateResources.query_identity(ctx.db, "served")
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

    before_failure = StateResources.query_identity(ctx.db, "served")
    failed = put_in(changed.item["liveRevision"], "published-but-unstamped")

    assert {:error, %{code: "projection_stamp_failed"}} =
             AdminProjection.stamp_publication(ctx.db, call, [failed],
               before_stamp: fn _txn -> raise "forced stamp failure" end
             )

    refute_receive {:firehose_notice, _notice}
    assert StateResources.query_identity(ctx.db, "served") == before_failure

    assert {:ok, [["projection_stamp_failed", detail]]} =
             DB.query(
               ctx.db,
               "SELECT code, detail FROM admin_projection_faults WHERE resource = 'identity' AND primaryKey = 'served'"
             )

    assert detail =~ "forced stamp failure"
  end

  test "a failed Git publication does not advance a stamp or emit state", ctx do
    before = StateResources.query_identity(ctx.db, "served")
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

    assert StateResources.query_identity(ctx.db, "served") == before
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
        {"identity", "served",
         StateResources.identity(StateResources.query_identity(ctx.db, "served"))},
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

    secret_content = """
    token = tbs_1234567890abcdef
    authorization: Bearer credential-value-12345678
    password = credential-password-12345678
    api_key: sk-1234567890abcdef
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
    refute encoded =~ "private-material"
    refute encoded =~ ctx.base_dir
    refute encoded =~ "/home/alice"
    refute encoded =~ "non-allowlisted"
    refute encoded =~ "hidden-secret"
    assert encoded =~ "[redacted-secret]"
    assert encoded =~ "[redacted-host-path]"

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
