defmodule Tightbeam.DevelopmentModeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Archetypes,
    DB,
    DevelopmentMode,
    Devices,
    Gateway,
    Harness,
    Identity,
    Model,
    Org,
    Schema,
    StateResources
  }

  alias Tightbeam.Firehose.Hub

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "development-mode-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    assert :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"development_mode_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    Devices.add_user(db, "flynn", true)
    Devices.add_user(db, "operator", false)

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir, db: db}
  end

  test "absent and idempotent off stay typed at revision zero; writes are closed and projected",
       ctx do
    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self())
    config = Gateway.handlers(%{base_dir: ctx.base_dir, db: ctx.db})["config"]

    assert %{
             setting: "development-mode",
             value: "off",
             enabled: false,
             revision: 0,
             config: nil
           } = config.(call("flynn", "get"))

    assert %{changed: false, value: "off", enabled: false, revision: 0, config: nil} =
             config.(call("flynn", "set", "off"))

    assert Org.get_setting(ctx.db, "development-mode") == nil
    assert StateResources.query_config(ctx.db, "development-mode") == nil

    assert %{code: "invalid_value"} = config.(call("flynn", "set", "ON"))
    assert %{code: "forbidden"} = config.(call("operator", "set", "on"))
    assert Org.get_setting(ctx.db, "development-mode") == nil

    ensure_main_session(ctx.db, "flynn")
    b = session(ctx.db, "agent:b")
    a = session(ctx.db, "agent:a")

    for materialized <- [b, a] do
      Org.set_served_snapshot(ctx.db, materialized.session_key, "identity-off", %{
        enabled: false,
        value: "off",
        revision: 0
      })
    end

    assert %{
             changed: true,
             value: "on",
             enabled: true,
             revision: 1,
             config: %{
               "key" => "development-mode",
               "value" => "on",
               "rowVersion" => 1
             },
             staleSessions: ["agent:a", "agent:b"],
             remedy: "tightbeam identity apply --all"
           } = config.(call("flynn", "set", "on"))

    assert_receive {:firehose_notice, %{"class" => "config.updated"}}
    Hub.delivered(Hub, self())

    assert %{changed: false, revision: 1} = config.(call("flynn", "set", "on"))
    _ = :sys.get_state(Hub)
    refute_received {:firehose_notice, %{"class" => "config.updated"}}
    assert StateResources.query_config(ctx.db, "development-mode").row_version == 1

    assert %{changed: true, value: "off", enabled: false, revision: 2} =
             config.(call("flynn", "set", "off"))
  end

  test "collision-free revisions do not depend on millisecond timestamps", ctx do
    :ok =
      DB.execute(ctx.db, """
      CREATE TRIGGER force_development_mode_insert_time
      AFTER INSERT ON org_settings
      WHEN NEW.key = 'development-mode'
      BEGIN
        UPDATE org_settings SET updatedAt = 123 WHERE key = NEW.key;
      END;
      CREATE TRIGGER force_development_mode_update_time
      AFTER UPDATE OF value ON org_settings
      WHEN NEW.key = 'development-mode'
      BEGIN
        UPDATE org_settings SET updatedAt = 123 WHERE key = NEW.key;
      END;
      """)

    first =
      transaction!(ctx.db, fn txn -> Org.put_development_mode_projected_in_txn(txn, "on") end)

    second =
      transaction!(ctx.db, fn txn -> Org.put_development_mode_projected_in_txn(txn, "off") end)

    assert first.projection.updated_at == 123
    assert second.projection.updated_at == 123
    assert first.projection.row_version == 1
    assert second.projection.row_version == 2
  end

  test "concurrent opposite writers serialize and preserve every semantic revision", ctx do
    parent = self()

    first =
      Task.async(fn ->
        DB.transaction(ctx.db, fn txn ->
          result = Org.put_development_mode_projected_in_txn(txn, "on")
          send(parent, {:first_writer_holds_transaction, self()})

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive {:first_writer_holds_transaction, transaction_owner}

    second =
      Task.async(fn ->
        transaction!(ctx.db, fn txn ->
          Org.put_development_mode_projected_in_txn(txn, "off")
        end)
      end)

    send(transaction_owner, :commit)

    assert {:ok, %{changed: true, projection: %{row_version: 1}}} = Task.await(first)
    assert %{changed: true, projection: %{row_version: 2}} = Task.await(second)
    assert DevelopmentMode.current(ctx.db) == %{enabled: false, value: "off", revision: 2}
  end

  test "status separates sorted stale materialized sessions from sessions with no context", ctx do
    main = ensure_main_session(ctx.db, "flynn")
    a = session(ctx.db, "agent:a")
    b = session(ctx.db, "agent:b")
    z = session(ctx.db, "agent:z")

    Org.set_served_snapshot(ctx.db, a.session_key, "identity-a", %{
      enabled: false,
      value: "off",
      revision: 0
    })

    Org.set_served_snapshot(ctx.db, b.session_key, "identity-b", %{
      enabled: false,
      value: "off",
      revision: 0
    })

    assert %{
             enabled: false,
             value: "off",
             revision: 0,
             stale_sessions: [],
             unmaterialized_sessions: unmaterialized
           } = DevelopmentMode.status(ctx.db)

    assert unmaterialized == [main.session_key, z.session_key] |> Enum.sort()

    transaction!(ctx.db, fn txn ->
      Org.put_development_mode_projected_in_txn(txn, "on")
    end)

    status = DevelopmentMode.status(ctx.db)
    assert status.stale_sessions == [a.session_key, b.session_key]
    assert status.unmaterialized_sessions == [main.session_key, z.session_key] |> Enum.sort()

    assert DevelopmentMode.wire_status(status) == %{
             enabled: true,
             value: "on",
             revision: 1,
             staleSessions: [a.session_key, b.session_key],
             unmaterializedSessions: [main.session_key, z.session_key] |> Enum.sort()
           }
  end

  test "legacy guidance refuses enablement until all six live blocks are removed", ctx do
    assert {:ok, _revision} = Identity.learn!(ctx.base_dir, "agentic-engineering", "test")
    Archetypes.load!(ctx.base_dir)

    legacy = """
    ## Debugging regime (mike's standing directive, 2026-08-06, until revoked)

    A silent
    workaround destroys the evidence this org exists to produce.

    Probe boundary (debugging regime)
    """

    names = ~w(default coder reviewer orchestrator recon spec-writer)

    for name <- names do
      Identity.edit!(ctx.base_dir, name, :guidance, legacy, "test")
    end

    config = Gateway.handlers(%{base_dir: ctx.base_dir, db: ctx.db})["config"]

    assert %{code: "legacy_guidance_present", paths: paths} =
             config.(call("flynn", "set", "on"))

    for name <- names do
      assert "guidance/#{name}.md" in paths
      Identity.edit!(ctx.base_dir, name, :guidance, "# #{name}\n", "test")
    end

    assert {:ok, _revision} = Identity.relearn!(ctx.base_dir, "test")
    assert Identity.development_mode_rollout_conflicts(ctx.base_dir) == []

    assert %{changed: true, enabled: true, revision: 1} =
             config.(call("flynn", "set", "on"))
  end

  test "one shipped fragment is composed exactly once for every installed archetype and harness",
       ctx do
    assert {:ok, live} = Identity.learn!(ctx.base_dir, "agentic-engineering", "test")
    Archetypes.load!(ctx.base_dir)
    fragment = development_fragment()

    off = %{enabled: false, value: "off", revision: 0}
    on = %{enabled: true, value: "on", revision: 1}

    for name <- Archetypes.names(), module <- Harness.all() do
      off_snapshot =
        Identity.snapshot_at!(ctx.base_dir, live, name, module.id(), development_mode: off)

      on_snapshot =
        Identity.snapshot_at!(ctx.base_dir, live, name, module.id(), development_mode: on)

      refute off_snapshot.guidance =~ fragment
      assert length(:binary.matches(on_snapshot.guidance, fragment)) == 1
      assert on_snapshot.revision == off_snapshot.revision
      assert on_snapshot.development_mode == on
    end

    {paths, 0} =
      System.cmd(
        "git",
        ["ls-tree", "-r", "--name-only", "tightbeam/live", "--", "guidance"],
        cd: Path.join(ctx.base_dir, "identity")
      )

    refute "guidance/development-mode.md" in String.split(paths, "\n", trim: true)
  end

  test "the canonical fragment names every internal specimen route and never posts externally" do
    fragment = development_fragment()

    assert fragment =~ "If you hold an assignment, file it on that assignment."
    assert fragment =~ "send the specimen to the nearest\n  active ancestor"
    assert fragment =~ "tightbeam artifact-record --kind"
    assert fragment =~ "do not address an inactive parent"
    assert fragment =~ "Ask the user for explicit permission for\n  that issue."
    assert fragment =~ "Do not post the issue until the\n  user grants that per-issue permission."
    refute fragment =~ "gh issue create"
  end

  defp call(user, action, value \\ nil) do
    params = %{action: action, setting: "development-mode"}
    params = if value, do: Map.put(params, :value, value), else: params
    %{verb: "config", origin: "user:#{user}", params: params}
  end

  defp session(db, key) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp transaction!(db, fun) do
    assert {:ok, result} = DB.transaction(db, fun)
    result
  end

  defp development_fragment do
    :tightbeam
    |> Application.app_dir("priv/guidance/development-mode.md")
    |> File.read!()
    |> String.trim_trailing()
  end
end
