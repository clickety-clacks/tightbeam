defmodule Tightbeam.Identity.RailScopeMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Identity, Schema}
  alias Tightbeam.Identity.RailScopeMigration
  alias Tightbeam.Identity.Provenance

  @kungfu "sample-kungfu"
  @archetype "org-example-analyst"
  @rule "sample-rule"
  @seed_statutes %{
    "github-auth" => "rails/github-auth.toml",
    "tightbeam-probe" => "rails/tightbeam-probe.toml"
  }
  @seed_reactions %{
    "assignment-terminal-handoff" => "rules/row-reaction-handoff.toml"
  }
  @legacy_reaction_fixture_dir Path.expand(
                                 "fixtures/rail-scope-migration/legacy-reactions",
                                 __DIR__
                               )

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "rail-scope-migration-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir}
  end

  test "migration publication produces a staleness notice for a session on the prior revision",
       ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    seed_migration_rows!(db)
    Tightbeam.Devices.add_user(db, "sample-owner", true)
    ensure_main_session(db, "sample-owner")
    prior = Identity.live_revision!(ctx.base_dir)
    Tightbeam.Org.set_identity_revision(db, "session-fixture", prior)
    :ok = Tightbeam.AdminProjection.bootstrap_served(db, ctx.base_dir)

    report = RailScopeMigration.run!(ctx.base_dir, db)
    revision = report["result_revision"]
    refute revision == prior
    # Boot's later bootstrap must not hide the migration's publication.
    :ok = Tightbeam.AdminProjection.bootstrap_served(db, ctx.base_dir)

    {:ok, seq} =
      Tightbeam.Ledger.enqueue(db, %{
        session_key: "session-fixture",
        message_id: "migration-staleness-turn",
        origin: "user:sample-owner",
        prompt: "fixture"
      })

    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE turns SET status='delivered', startedAt=?2, endedAt=?2 WHERE seq=?1",
               [seq, now]
             )

    assert {:scheduled, 1, ^revision} =
             Tightbeam.Gateway.identity_staleness_alarm_for_test(db, now)

    target = Tightbeam.Org.personal_session_key("sample-owner")

    assert {:ok, [[^target, prompt]]} =
             DB.query(db, "SELECT sessionKey,prompt FROM wakes WHERE origin='process:tightbeam'")

    assert prompt =~ revision
    assert :already_notified = Tightbeam.Gateway.identity_staleness_alarm_for_test(db, now)
  end

  @briefing_source "rules/briefings.toml"
  @briefing_namespaced_source "kungfu/harklight-decision-briefings/rules/briefings.toml"
  @briefing_destination "rules/harklight-decision-request-briefing.toml"

  test "configured 0.1.16 briefings keep their owner and route across upgrade", ctx do
    init_briefing_fixture!(ctx.base_dir, true)
    identity_dir = Path.join(ctx.base_dir, "identity")
    original = File.read!(Path.join(identity_dir, @briefing_source))
    db = start_db!()
    Tightbeam.Devices.add_user(db, "briefing-test-owner", true)

    for key <- ["briefing-compiler", "briefing-consumer"] do
      Tightbeam.Org.create(db, %{
        session_key: key,
        display_name: key,
        kind: "custom",
        owner_user_id: "briefing-test-owner",
        origin: "user:briefing-test-owner",
        archetype: "default",
        host: Tightbeam.Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Tightbeam.Model.new("fable")
      })
    end

    first = RailScopeMigration.run!(ctx.base_dir, db)
    migrated = File.read!(Path.join(identity_dir, @briefing_destination))
    # Scope insertion is the only byte change, including the configured fields.
    assert String.replace(migrated, "archetypes = [\"*\"]\n", "") == original
    refute File.exists?(Path.join(identity_dir, @briefing_source))
    refute File.exists?(Path.join(identity_dir, @briefing_namespaced_source))

    receipt =
      Toml.decode!(
        File.read!(Path.join(identity_dir, "kungfu/harklight-decision-briefings/installed.toml"))
      )

    refute @briefing_source in receipt["paths"]
    refute @briefing_destination in receipt["paths"]
    assert Provenance.owner_for_path(ctx.base_dir, @briefing_destination) == :substrate

    handlers = Tightbeam.Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    Tightbeam.Rules.load!(ctx.base_dir, Map.keys(handlers))
    on_exit(fn -> Tightbeam.Rules.load!("/missing-briefing-migration-reset", []) end)

    request =
      Tightbeam.Escalation.operator_ask(db, %{
        verb: "operator-ask",
        origin: "agent:briefing-compiler",
        principal: {:session, "briefing-compiler"},
        session_key: "briefing-compiler",
        transport_session_key: "briefing-compiler",
        params:
          Tightbeam.TestSupport.OperatorAskFixture.link(db, "briefing-compiler", %{
            question: "Which option?"
          })
      })

    assert is_binary(request.id)

    assert {:ok, [["briefing-consumer"]]} =
             DB.query(
               db,
               "SELECT sessionKey FROM wakes WHERE origin='remedy:harklight-decision-request-briefing'"
             )

    revision = git!(identity_dir, ["rev-parse", "main"])
    assert RailScopeMigration.run!(ctx.base_dir, db) == first
    assert git!(identity_dir, ["rev-parse", "main"]) == revision
    assert File.read!(Path.join(identity_dir, @briefing_destination)) == migrated
  end

  test "a legacy briefing with explicit wildcard scope is still written at its new path", ctx do
    init_briefing_fixture!(ctx.base_dir, true)
    identity_dir = Path.join(ctx.base_dir, "identity")
    source = Path.join(identity_dir, @briefing_source)
    bytes = File.read!(source) |> String.replace("verb =", "archetypes = [\"*\"]\nverb =")
    File.write!(source, bytes)
    commit_fixture!(identity_dir, "fixture: explicitly scoped legacy briefing")
    assert %{"status" => "complete"} = RailScopeMigration.run!(ctx.base_dir, start_db!())
    assert File.read!(Path.join(identity_dir, @briefing_destination)) == bytes
    refute File.exists?(source)
  end

  test "an already namespaced learned briefing also relocates", ctx do
    init_briefing_fixture!(ctx.base_dir, true)
    identity_dir = Path.join(ctx.base_dir, "identity")
    source = Path.join(identity_dir, @briefing_source)
    bytes = File.read!(source)
    File.mkdir_p!(Path.dirname(Path.join(identity_dir, @briefing_namespaced_source)))
    File.rename!(source, Path.join(identity_dir, @briefing_namespaced_source))
    receipt = Path.join(identity_dir, "kungfu/harklight-decision-briefings/installed.toml")

    File.write!(
      receipt,
      String.replace(File.read!(receipt), @briefing_source, @briefing_namespaced_source)
    )

    commit_fixture!(identity_dir, "fixture: namespaced learned briefing")
    assert %{"status" => "complete"} = RailScopeMigration.run!(ctx.base_dir, start_db!())
    migrated = File.read!(Path.join(identity_dir, @briefing_destination))
    assert String.replace(migrated, "archetypes = [\"*\"]\n", "") == bytes
    refute File.exists?(Path.join(identity_dir, @briefing_namespaced_source))
  end

  test "an organization-owned flat briefing remains substrate law", ctx do
    init_briefing_fixture!(ctx.base_dir, true)
    identity_dir = Path.join(ctx.base_dir, "identity")
    File.rm!(Path.join(identity_dir, "kungfu/harklight-decision-briefings/installed.toml"))
    commit_fixture!(identity_dir, "fixture: organization-owned flat briefing")
    assert %{"status" => "complete"} = RailScopeMigration.run!(ctx.base_dir, start_db!())
    assert File.exists?(Path.join(identity_dir, @briefing_source))
    refute File.exists?(Path.join(identity_dir, @briefing_destination))
  end

  test "unconfigured learned briefings migrate without error", ctx do
    init_briefing_fixture!(ctx.base_dir, false)
    assert %{"status" => "complete"} = RailScopeMigration.run!(ctx.base_dir, start_db!())
    bytes = File.read!(Path.join([ctx.base_dir, "identity", @briefing_destination]))
    assert bytes =~ "CONFIGURE_OWNER_ID"
    assert bytes =~ "CONFIGURE_DECISION_BRIEFING_ROLE"
    refute File.exists?(Path.join([ctx.base_dir, "identity", @briefing_source]))
  end

  test "never-learned briefings migrate without error", ctx do
    Identity.init!(ctx.base_dir)
    identity_dir = Path.join(ctx.base_dir, "identity")
    File.rm!(Path.join(identity_dir, @briefing_destination))
    commit_fixture!(identity_dir, "fixture: before briefing substrate seed existed")
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/upstream", "main"])
    assert %{"status" => "complete"} = RailScopeMigration.run!(ctx.base_dir, start_db!())
    refute File.exists?(Path.join([ctx.base_dir, "identity", @briefing_source]))
  end

  test "an existing substrate briefing keeps its configuration", ctx do
    init_briefing_fixture!(ctx.base_dir, true)
    identity_dir = Path.join(ctx.base_dir, "identity")

    existing =
      File.read!(Path.join(identity_dir, @briefing_source))
      |> String.replace("briefing-consumer", "existing-consumer")
      |> String.replace("verb =", "archetypes = [\"*\"]\nverb =")

    File.write!(Path.join(identity_dir, @briefing_destination), existing)
    commit_fixture!(identity_dir, "fixture: existing substrate briefing")
    assert %{"status" => "complete"} = RailScopeMigration.run!(ctx.base_dir, start_db!())
    assert File.read!(Path.join(identity_dir, @briefing_destination)) == existing
    assert File.read!(Path.join(identity_dir, @briefing_namespaced_source)) =~ "briefing-consumer"
  end

  defp init_briefing_fixture!(base_dir, configured?) do
    Identity.init!(base_dir)
    identity_dir = Path.join(base_dir, "identity")
    # Released 0.1.16 learns rules flat; its receipt supplies bundle ownership.
    legacy = File.read!(Path.join(__DIR__, "fixtures/rail-scope-migration/legacy-briefings.toml"))

    File.rm!(Path.join(identity_dir, @briefing_destination))
    File.mkdir_p!(Path.dirname(Path.join(identity_dir, @briefing_source)))
    File.write!(Path.join(identity_dir, @briefing_source), legacy)

    File.mkdir_p!(Path.join(identity_dir, "kungfu/harklight-decision-briefings"))

    File.write!(
      Path.join(identity_dir, "kungfu/harklight-decision-briefings/installed.toml"),
      "name = \"harklight-decision-briefings\"\npaths = #{inspect([@briefing_source])}\n"
    )

    commit_fixture!(identity_dir, "fixture: learned 0.1.16 briefing rule")
    # Released learn imports the unconfigured bundle into upstream before the
    # organization configures its main branch. Both refs have the flat path.
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/upstream", "main"])

    if configured? do
      configured =
        legacy
        |> String.replace("user:CONFIGURE_OWNER_ID", "user:briefing-test-owner")
        |> String.replace(
          "target_role = \"CONFIGURE_DECISION_BRIEFING_ROLE\"",
          "target_session = \"briefing-consumer\""
        )

      File.write!(Path.join(identity_dir, @briefing_source), configured)
      commit_fixture!(identity_dir, "fixture: configure learned briefing on main")
    end
  end

  test "receipt-owned files migrate once and preserve later agentless rails", ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    seed_migration_rows!(db)

    first = RailScopeMigration.run!(ctx.base_dir, db)
    identity_dir = Path.join(ctx.base_dir, "identity")

    assert first["status"] == "complete"
    refute File.exists?(Path.join(identity_dir, "rules/row-reaction-assignment-inactivity.toml"))
    assert is_binary(first["result_revision"])

    for name <- Map.keys(@seed_reactions) do
      assert_single_rail_definition!(ctx.base_dir, "reaction", name)
    end

    # The 2-hour reminder no longer ships: its legacy copy goes and is not replanted.
    refute File.exists?(Path.join(identity_dir, "rules/row-reaction-terminal-action.toml"))

    refute identity_dir
           |> Path.join("**/*.toml")
           |> Path.wildcard()
           |> Enum.any?(&(File.read!(&1) =~ ~s(name = "terminal-child-action-reminder")))

    assert Path.join(identity_dir, "kungfu/#{@kungfu}/archetypes/#{@archetype}.toml")
           |> File.exists?()

    refute File.exists?(Path.join(identity_dir, "archetypes/#{@archetype}.toml"))

    assert {:ok, [["#{@kungfu}.#{@archetype}"]]} =
             DB.query(db, "SELECT archetype FROM sessions WHERE sessionKey='session-fixture'")

    assert {:ok, [["#{@kungfu}.#{@archetype}"]]} =
             DB.query(db, "SELECT value FROM org_settings WHERE key='default-archetype'")

    assert {:ok, [[scope]]} =
             DB.query(db, "SELECT archetypes FROM subtree_guidance_entries WHERE name='guide'")

    assert JSON.decode!(scope) == ["#{@kungfu}.#{@archetype}"]

    qualified_rule = "#{@kungfu}.#{@rule}"
    qualified_condition = "#{@kungfu}.#{@archetype}"

    assert {:ok, [[^qualified_rule]]} =
             DB.query(db, "SELECT statute FROM rail_remedy_episodes WHERE subject='s'")

    assert {:ok, [[^qualified_rule]]} =
             DB.query(db, "SELECT statuteName FROM escalation_waivers WHERE id='waiver-fixture'")

    assert {:ok, [[^qualified_rule, ^qualified_rule, "remedy:" <> ^qualified_rule]]} =
             DB.query(
               db,
               "SELECT deliveryRule,selectedPolicyName,origin FROM wakes WHERE wakeId='wake-fixture'"
             )

    assert {:ok, [[^qualified_rule]]} =
             DB.query(db, "SELECT statuteName FROM decision_requests WHERE id='decision-fixture'")

    migrated_rule =
      identity_dir
      |> Path.join("kungfu/#{@kungfu}/rules/sample.toml")
      |> File.read!()
      |> Toml.decode!()
      |> Map.fetch!("rule")
      |> hd()

    assert migrated_rule["archetypes"] == [qualified_condition]
    assert Enum.any?(migrated_rule["deny_when"], &(&1["value"] == qualified_condition))

    for table <- ~w(
          recurrence_suppression_episodes
          recurrence_suppression_deliveries
          recurrence_suppression_fact_observations
          recurrence_suppression_receipts
          recurrence_suppression_events
        ) do
      assert {:ok, [[^qualified_rule]]} = DB.query(db, "SELECT statute FROM #{table}")
    end

    receipt =
      identity_dir
      |> Path.join("kungfu/#{@kungfu}/installed.toml")
      |> File.read!()
      |> Toml.decode!()

    assert "kungfu/#{@kungfu}/archetypes/#{@archetype}.toml" in receipt["paths"]
    assert "archetypes/#{@archetype}.toml" not in receipt["paths"]

    migration_revision = git!(identity_dir, ["rev-parse", "tightbeam/live"])
    rows_before = migration_rows(db)
    report_before = File.read!(Path.join(ctx.base_dir, "rail-scope-migration-report.json"))

    agentless_path = Path.join(identity_dir, "rules/post-upgrade-agentless.toml")

    agentless_bytes = """
    [[rule]]
    name = "post-upgrade-agentless"
    verb = "assign"
    text = "preserve agentless behavior"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    """

    File.write!(agentless_path, agentless_bytes)
    git!(identity_dir, ["add", "-A"])
    git!(identity_dir, ["commit", "-m", "fixture: author post-upgrade agentless rail"])
    post_upgrade_revision = git!(identity_dir, ["rev-parse", "main"])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/live", post_upgrade_revision])

    second = RailScopeMigration.run!(ctx.base_dir, db)
    third = RailScopeMigration.run!(ctx.base_dir, db)

    assert second["status"] == "complete"
    assert second["result_revision"] == migration_revision
    assert third == second
    assert git!(identity_dir, ["rev-parse", "main"]) == post_upgrade_revision
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == post_upgrade_revision
    assert migration_rows(db) == rows_before
    assert File.read!(agentless_path) == agentless_bytes
    refute Map.has_key?(Toml.decode!(agentless_bytes)["rule"] |> hd(), "archetypes")

    assert File.read!(Path.join(ctx.base_dir, "rail-scope-migration-report.json")) ==
             report_before

    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM rail_scope_migrations")

    loaded = Tightbeam.Archetypes.load!(ctx.base_dir)
    assert Map.has_key?(loaded, "#{@kungfu}.#{@archetype}")
  end

  test "a report file cannot mark unmigrated database rows complete", ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    seed_migration_rows!(db)

    stale_report = %{
      "schema" => "tightbeam-rail-scope-migration/v1",
      "status" => "complete",
      "source_revision" => "previous-database",
      "result_revision" => "previous-database"
    }

    File.write!(
      Path.join(ctx.base_dir, "rail-scope-migration-report.json"),
      JSON.encode!(stale_report)
    )

    report = RailScopeMigration.run!(ctx.base_dir, db)
    assert report["result_revision"] != "previous-database"

    assert {:ok, [["#{@kungfu}.#{@archetype}"]]} =
             DB.query(db, "SELECT archetype FROM sessions WHERE sessionKey='session-fixture'")

    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM rail_scope_migrations")
  end

  test "migration preserves org TOML comments and unrelated bytes", ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    dir = Path.join(ctx.base_dir, "identity")

    bytes = """
    # Organization topology explanation.
    [[rule]]
    name  = 'topology-example' # keep this note
    verb = 'post'
    text = 'Explain the organization policy.'
    deny_when = [ # keep this layout
      { fact = 'target.archetype', op = 'eq', value = '#{@archetype}' }, # rationale
    ]
    """

    File.write!(Path.join(dir, "rules/topology.toml"), bytes)
    commit_fixture!(dir, "fixture: org topology")
    RailScopeMigration.run!(ctx.base_dir, db)

    expected =
      bytes
      |> String.replace("[[rule]]\n", "[[rule]]\narchetypes = [\"*\"]\n")
      |> String.replace("value = '#{@archetype}'", "value = '#{@kungfu}.#{@archetype}'")

    assert File.read!(Path.join(dir, "rules/topology.toml")) == expected
  end

  test "a learned completion review rail gains its accountable-notice declaration", ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    dir = Path.join(ctx.base_dir, "identity")

    legacy =
      "test/support/fixtures/kungfu/agentic-engineering/rules/engineering.toml"
      |> File.read!()
      |> String.split("\n# Posture gate")
      |> hd()
      |> String.replace(~r/^archetypes = .*\n/m, "")
      |> String.replace("accountable_notice = true\n", "")

    refute legacy =~ "accountable_notice"
    File.write!(Path.join(dir, "rules/engineering.toml"), legacy)
    commit_fixture!(dir, "fixture: learned 0.1.16 completion review rail")
    assert %{"status" => "complete"} = RailScopeMigration.run!(ctx.base_dir, db)

    migrated = File.read!(Path.join(dir, "rules/engineering.toml"))
    assert migrated =~ "accountable_notice = true"

    # The migrated copy loads and keeps the rail's behaviour.
    handlers = Tightbeam.Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    on_exit(fn -> Tightbeam.Rules.load!("/missing-accountable-notice-reset", []) end)

    assert rules = Tightbeam.Rules.load!(ctx.base_dir, Map.keys(handlers))
    assert [rule] = Enum.filter(rules, &(&1.short_name == "completion-requires-review"))
    assert rule.remedy.accountable_notice
  end

  test "migrated relearn preserves substrate namesakes and merges org kungfu edits", ctx do
    init_fixture!(ctx.base_dir, verb: "post")
    db = start_db!()

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) VALUES('substrate-pdo','pdo','sample-owner','user:sample-owner','pdo','claude','anthropic','sample-model',1,1)"
             )

    dir = Path.join(ctx.base_dir, "identity")
    pdo_bytes = "name = \"pdo\"\nskills = []\nwhere = [\"*\"]\n"
    File.write!(Path.join(dir, "archetypes/pdo.toml"), pdo_bytes)
    rule_path = Path.join(dir, "rules/sample.toml")

    rule_bytes =
      File.read!(rule_path)
      |> String.replace(
        "deny_when =",
        "# clause rationale\n# retained detail one\n# retained detail two\n# retained detail three\n# retained detail four\ndeny_when ="
      )

    File.write!(rule_path, rule_bytes)
    manifest_path = Path.join(dir, "kungfu/#{@kungfu}/manifest.toml")
    File.write!(manifest_path, File.read!(manifest_path) <> "purpose = \"Migration fixture.\"\n")
    commit_fixture!(dir, "fixture: legacy upstream content")

    # Model the old learn graph: upstream has shipped files but no receipt;
    # main has the receipt and subsequently authors organization changes.
    files =
      git!(dir, ["ls-tree", "-r", "--name-only", "main"])
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.ends_with?(&1, "/installed.toml"))
      |> Map.new(&{&1, File.read!(Path.join(dir, &1))})

    git!(dir, ["switch", "tightbeam/upstream"])
    for name <- File.ls!(dir), name != ".git", do: File.rm_rf!(Path.join(dir, name))

    for {relative, bytes} <- files do
      path = Path.join(dir, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", "fixture: old upstream without receipts"])
    git!(dir, ["switch", "main"])
    git!(dir, ["merge", "--no-ff", "tightbeam/upstream", "-m", "fixture: old learn"])
    org_pdo = pdo_bytes <> "# Organization-owned pdo customization.\n"
    File.write!(Path.join(dir, "archetypes/pdo.toml"), org_pdo)
    File.write!(rule_path, String.replace(rule_bytes, "sample rule", "organization rule text"))
    commit_fixture!(dir, "fixture: org edits after learn")

    RailScopeMigration.run!(ctx.base_dir, db)
    upstream = git!(dir, ["rev-parse", "tightbeam/upstream"])
    assert git!(dir, ["merge-base", "main", upstream]) == upstream
    assert git!(dir, ["ls-tree", "--name-only", upstream, "--", "archetypes/pdo.toml"]) == ""

    bundle_root = Path.join(ctx.base_dir, "bundles")
    source = Path.join(bundle_root, @kungfu)

    for relative <- ["archetypes/#{@archetype}.toml", "rules/sample.toml", "manifest.toml"] do
      bytes = git!(dir, ["show", "#{upstream}:kungfu/#{@kungfu}/#{relative}"]) <> "\n"

      bytes =
        if relative == "rules/sample.toml",
          do: String.replace(bytes, "op = \"eq\"", "op = \"ne\""),
          else: bytes

      path = Path.join(source, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    File.write!(Path.join(source, "archetypes/pdo.toml"), pdo_bytes)
    previous = Application.get_env(:tightbeam, :kungfu_bundle_root_dir)
    Application.put_env(:tightbeam, :kungfu_bundle_root_dir, bundle_root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tightbeam, :kungfu_bundle_root_dir, previous),
        else: Application.delete_env(:tightbeam, :kungfu_bundle_root_dir)
    end)

    assert {:ok, candidate} = Identity.relearn!(ctx.base_dir, "test")
    assert {:ok, _} = Identity.publish_live!(ctx.base_dir, candidate)
    assert File.read!(Path.join(dir, "archetypes/pdo.toml")) == org_pdo
    assert Provenance.owner_for_path(ctx.base_dir, "archetypes/pdo.toml") == :substrate

    assert Provenance.owner_for_path(ctx.base_dir, "kungfu/#{@kungfu}/archetypes/pdo.toml") ==
             {:kungfu, @kungfu}

    names = Tightbeam.Archetypes.load!(ctx.base_dir)
    assert Map.has_key?(names, "pdo") and Map.has_key?(names, "#{@kungfu}.pdo")
    merged = File.read!(Path.join(dir, "kungfu/#{@kungfu}/rules/sample.toml"))
    assert merged =~ "organization rule text"
    assert merged =~ "op = \"ne\""
    assert merged =~ "# retained detail four"
    assert Identity.status(ctx.base_dir).state == :ready

    assert {:ok, [["pdo"]]} =
             DB.query(db, "SELECT archetype FROM sessions WHERE sessionKey='substrate-pdo'")

    # Overlapping edits still use the existing conflict/abort flow, with a
    # qualified path and no change to the last published org customization.
    live = Identity.live_revision!(ctx.base_dir)
    shipped_rule = Path.join(source, "rules/sample.toml")

    File.write!(
      shipped_rule,
      String.replace(File.read!(shipped_rule), "sample rule", "new upstream text")
    )

    assert {:conflict, ["kungfu/#{@kungfu}/rules/sample.toml"]} =
             Identity.relearn!(ctx.base_dir, "test")

    assert Identity.live_revision!(ctx.base_dir) == live
    assert :ok = Identity.abort_relearn!(ctx.base_dir)
    assert File.read!(Path.join(dir, "archetypes/pdo.toml")) == org_pdo
    assert File.read!(Path.join(dir, "kungfu/#{@kungfu}/rules/sample.toml")) == merged
  end

  test "upgrade seeds substrate statutes and learning keeps each moved reaction singular", ctx do
    init_seed_upgrade_fixture!(ctx.base_dir)
    db = start_db!()

    migration = RailScopeMigration.run!(ctx.base_dir, db)
    identity_dir = Path.join(ctx.base_dir, "identity")

    assert migration["status"] == "complete"

    for {name, relative} <- @seed_statutes do
      identity_path = Path.join(identity_dir, relative)
      seed_path = Path.join([:code.priv_dir(:tightbeam), "seed", relative])

      assert File.read!(identity_path) == File.read!(seed_path)
      assert_single_rail_definition!(ctx.base_dir, "statute", name)
    end

    for name <- Map.keys(@seed_reactions) do
      assert_single_rail_definition!(ctx.base_dir, "reaction", name)
    end

    assert {:ok, _revision} = Identity.learn!(ctx.base_dir, "agentic-engineering", "test")

    for name <- Map.keys(@seed_reactions) do
      assert_single_rail_definition!(ctx.base_dir, "reaction", name)
    end

    for {name, _relative} <- @seed_statutes do
      assert_single_rail_definition!(ctx.base_dir, "statute", name)
    end
  end

  test "an unfinished identity relearn merge stops the upgrade before serving", ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    seed_migration_rows!(db)

    identity_dir = Path.join(ctx.base_dir, "identity")
    revision = git!(identity_dir, ["rev-parse", "main"])
    rows_before = migration_rows(db)

    File.write!(
      Path.join([identity_dir, ".git", "MERGE_HEAD"]),
      String.duplicate("a", 40) <> "\n"
    )

    assert_raise ArgumentError, ~r/rail scoping migration stopped/, fn ->
      RailScopeMigration.run!(ctx.base_dir, db)
    end

    assert git!(identity_dir, ["rev-parse", "main"]) == revision
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == revision
    assert migration_rows(db) == rows_before
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM rail_scope_migrations")

    report =
      ctx.base_dir
      |> Path.join("rail-scope-migration-report.json")
      |> File.read!()
      |> JSON.decode!()

    assert report["status"] == "stopped"

    assert [%{"file" => "identity/.git/MERGE_HEAD", "owner_action" => owner_action}] =
             report["stops"]

    assert owner_action ==
             "complete or abort the identity relearn merge, then restart Tightbeam"
  end

  test "a completed migration permits published-law recovery during a relearn merge", ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    seed_migration_rows!(db)

    complete = RailScopeMigration.run!(ctx.base_dir, db)
    identity_dir = Path.join(ctx.base_dir, "identity")
    revision = git!(identity_dir, ["rev-parse", "main"])
    rows_before = migration_rows(db)
    report_before = File.read!(Path.join(ctx.base_dir, "rail-scope-migration-report.json"))

    File.write!(
      Path.join([identity_dir, ".git", "MERGE_HEAD"]),
      String.duplicate("b", 40) <> "\n"
    )

    assert RailScopeMigration.run!(ctx.base_dir, db) == complete

    recovered_revision =
      Identity.with_recovery_law!(ctx.base_dir, fn recovery_base, live_revision ->
        assert File.dir?(Path.join(recovery_base, "identity"))

        assert File.regular?(
                 Path.join(
                   recovery_base,
                   "identity/kungfu/#{@kungfu}/archetypes/#{@archetype}.toml"
                 )
               )

        live_revision
      end)

    assert recovered_revision == git!(identity_dir, ["rev-parse", "tightbeam/live"])
    assert git!(identity_dir, ["rev-parse", "main"]) == revision
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == revision
    assert migration_rows(db) == rows_before
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM rail_scope_migrations")

    assert File.read!(Path.join(ctx.base_dir, "rail-scope-migration-report.json")) ==
             report_before

    assert complete["status"] == "complete"
  end

  test "a database failure rolls back identity files and migrated rows", ctx do
    init_fixture!(ctx.base_dir)
    db = start_db!()
    seed_migration_rows!(db)

    identity_dir = Path.join(ctx.base_dir, "identity")
    revision = git!(identity_dir, ["rev-parse", "main"])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/upstream", revision])
    rows_before = migration_rows(db)

    migrated_archetype =
      Path.join(identity_dir, "kungfu/#{@kungfu}/archetypes/#{@archetype}.toml")

    :ok =
      DB.execute(db, """
      CREATE TRIGGER refuse_rail_scope_migration
      BEFORE INSERT ON rail_scope_migrations
      BEGIN SELECT RAISE(ABORT, 'fixture marker refusal'); END;
      """)

    assert_raise DB.Error, fn ->
      RailScopeMigration.run!(ctx.base_dir, db)
    end

    assert git!(identity_dir, ["rev-parse", "main"]) == revision
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == revision
    assert File.exists?(Path.join(identity_dir, "archetypes/#{@archetype}.toml"))
    refute File.exists?(migrated_archetype)
    assert git!(identity_dir, ["rev-parse", "tightbeam/upstream"]) == revision
    assert migration_rows(db) == rows_before
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM rail_scope_migrations")
  end

  test "a foreign-only in comparison stops before changing identity or rows", ctx do
    init_fixture!(ctx.base_dir,
      rule_condition: ~s({ fact = "target.archetype", op = "in", value = ["support-agent"] })
    )

    db = start_db!()
    seed_migration_rows!(db)
    identity_dir = Path.join(ctx.base_dir, "identity")
    revision = git!(identity_dir, ["rev-parse", "main"])
    before_rows = migration_rows(db)

    assert_raise ArgumentError, ~r/rail scoping migration stopped/, fn ->
      RailScopeMigration.run!(ctx.base_dir, db)
    end

    assert git!(identity_dir, ["rev-parse", "main"]) == revision
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == revision
    assert migration_rows(db) == before_rows

    assert File.read!(Path.join(ctx.base_dir, "rail-scope-migration-report.json")) =~
             "always false for the owning kungfu"
  end

  test "a foreign-only equality comparison stops before changing identity", ctx do
    init_fixture!(ctx.base_dir,
      rule_condition: ~s({ fact = "target.archetype", op = "eq", value = "support-agent" })
    )

    plan = RailScopeMigration.plan!(ctx.base_dir)

    assert Enum.any?(plan.stops, fn stop ->
             stop["comparison"] =~ "target.archetype eq" and
               stop["comparison"] =~ "always false"
           end)
  end

  test "removing every condition from a required list stops migration", ctx do
    init_fixture!(ctx.base_dir,
      rule_condition: ~s({ fact = "target.archetype", op = "not_in", value = ["support-agent"] })
    )

    plan = RailScopeMigration.plan!(ctx.base_dir)

    assert Enum.any?(
             plan.stops,
             &String.contains?(&1["comparison"], "emptied required deny_when")
           )
  end

  test "foreign-only ne and not_in comparisons are removed when another condition remains", ctx do
    for op <- ["ne", "not_in"] do
      base_dir = Path.join(ctx.base_dir, op)
      value = if op == "not_in", do: "[\"support-agent\"]", else: "\"support-agent\""

      init_fixture!(base_dir,
        rule_condition: ~s({ fact = "target.archetype", op = "#{op}", value = #{value} }),
        include_own_condition: true
      )

      plan = RailScopeMigration.plan!(base_dir)
      assert plan.stops == []

      migrated = Map.fetch!(plan.writes, "kungfu/#{@kungfu}/rules/sample.toml")
      [rule] = Toml.decode!(migrated)["rule"]

      assert length(rule["deny_when"]) == 1
      assert rule["deny_when"] |> hd() |> Map.fetch!("value") == "#{@kungfu}.#{@archetype}"
      assert Enum.any?(plan.removed_entries, &(&1["file"] == "rules/sample.toml"))
    end
  end

  test "a record-fact foreign comparison stops instead of being stripped", ctx do
    init_fixture!(ctx.base_dir,
      verb: "assign",
      rule_condition:
        ~s({ fact = "assignment.holder_archetype", op = "not_in", value = ["support-agent"] })
    )

    plan = RailScopeMigration.plan!(ctx.base_dir)

    assert Enum.any?(plan.stops, &String.contains?(&1["comparison"], "record fact"))
  end

  test "same short rail names across sources remain allowed until a bare live row is ambiguous",
       ctx do
    init_fixture!(ctx.base_dir)
    add_second_kungfu_rule!(ctx.base_dir)

    plan = RailScopeMigration.plan!(ctx.base_dir)
    refute Enum.any?(plan.stops, &String.contains?(&1["comparison"], "multiple owners"))
    assert plan.rail_map[@rule] == :ambiguous
  end

  test "duplicate receipt claims are reported from the unchanged source revision", ctx do
    init_fixture!(ctx.base_dir)
    identity_dir = Path.join(ctx.base_dir, "identity")
    duplicate_dir = Path.join(identity_dir, "kungfu/other-kungfu")
    File.mkdir_p!(duplicate_dir)

    File.write!(
      Path.join(duplicate_dir, "installed.toml"),
      "name = \"other-kungfu\"\npaths = [\"archetypes/#{@archetype}.toml\"]\n"
    )

    git!(identity_dir, ["add", "-A"])
    git!(identity_dir, ["commit", "-m", "fixture: duplicate receipt claim"])
    revision = git!(identity_dir, ["rev-parse", "main"])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/live", revision])
    db = start_db!()
    seed_migration_rows!(db)
    before_rows = migration_rows(db)

    assert_raise ArgumentError, ~r/rail scoping migration stopped/, fn ->
      RailScopeMigration.run!(ctx.base_dir, db)
    end

    assert git!(identity_dir, ["rev-parse", "main"]) == revision
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == revision
    assert migration_rows(db) == before_rows

    report = File.read!(Path.join(ctx.base_dir, "rail-scope-migration-report.json"))
    assert report =~ "archetypes/#{@archetype}.toml"
    assert report =~ "other-kungfu and sample-kungfu"
  end

  test "an edited legacy row reaction stops without changing fixture identity", ctx do
    init_fixture!(ctx.base_dir, edit_reaction: true)
    db = start_db!()
    identity_dir = Path.join(ctx.base_dir, "identity")
    revision = git!(identity_dir, ["rev-parse", "main"])

    assert_raise ArgumentError, ~r/rail scoping migration stopped/, fn ->
      RailScopeMigration.run!(ctx.base_dir, db)
    end

    assert git!(identity_dir, ["rev-parse", "main"]) == revision
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == revision

    assert File.read!(Path.join(ctx.base_dir, "rail-scope-migration-report.json")) =~
             "was edited"
  end

  defp init_fixture!(base_dir, opts \\ []) do
    assert :initialized = Identity.init!(base_dir)
    identity_dir = Path.join(base_dir, "identity")

    for relative <- Map.values(@seed_statutes) ++ Map.values(@seed_reactions) do
      File.rm(Path.join(identity_dir, relative))
    end

    File.mkdir_p!(Path.join(identity_dir, "archetypes"))
    File.mkdir_p!(Path.join(identity_dir, "rules"))
    File.mkdir_p!(Path.join(identity_dir, "kungfu/#{@kungfu}"))

    File.write!(
      Path.join(identity_dir, "archetypes/#{@archetype}.toml"),
      "name = \"#{@archetype}\"\nskills = []\nwhere = [\"*\"]\n"
    )

    own_condition =
      ~s({ fact = "target.archetype", op = "eq", value = "#{@archetype}" })

    condition = Keyword.get(opts, :rule_condition, own_condition)

    conditions =
      if Keyword.get(opts, :include_own_condition, false),
        do: "#{own_condition}, #{condition}",
        else: condition

    verb = Keyword.get(opts, :verb, "assign")

    rule = """
    [[rule]]
    name = "#{@rule}"
    verb = "#{verb}"
    text = "sample rule"
    deny_when = [#{conditions}]
    """

    File.write!(Path.join(identity_dir, "rules/sample.toml"), rule)

    write_legacy_reaction_copies!(identity_dir)

    if Keyword.get(opts, :edit_reaction, false) do
      File.write!(
        Path.join(identity_dir, "rules/row-reaction-handoff.toml"),
        File.read!(Path.join(identity_dir, "rules/row-reaction-handoff.toml")) <>
          "\n# fixture edit\n"
      )
    end

    File.write!(
      Path.join(identity_dir, "kungfu/#{@kungfu}/manifest.toml"),
      "name = \"#{@kungfu}\"\nroot_archetype = \"#{@archetype}\"\n"
    )

    paths = [
      "archetypes/#{@archetype}.toml",
      "rules/sample.toml",
      "rules/row-reaction-assignment-inactivity.toml",
      "rules/row-reaction-handoff.toml",
      "rules/row-reaction-terminal-action.toml",
      "kungfu/#{@kungfu}/manifest.toml"
    ]

    File.write!(
      Path.join(identity_dir, "kungfu/#{@kungfu}/installed.toml"),
      "name = \"#{@kungfu}\"\npaths = #{inspect(paths)}\n"
    )

    git!(identity_dir, ["add", "-A"])
    git!(identity_dir, ["commit", "-m", "fixture: legacy rail scope identity"])
    revision = git!(identity_dir, ["rev-parse", "main"])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/live", revision])
    :ok
  end

  defp commit_fixture!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", message])
    git!(dir, ["update-ref", "refs/heads/tightbeam/live", "main"])
  end

  defp write_legacy_reaction_copies!(identity_dir) do
    seed_dir = Path.join(identity_dir, "rules")

    for {source, destination} <- [
          {"row-reaction-assignment-inactivity.toml", "row-reaction-assignment-inactivity.toml"},
          {"row-reaction-handoff.toml", "row-reaction-handoff.toml"},
          {"row-reaction-terminal-action.toml", "row-reaction-terminal-action.toml"}
        ] do
      source_path = Path.join(@legacy_reaction_fixture_dir, source)
      destination_path = Path.join(seed_dir, destination)
      File.rm(destination_path)
      File.cp!(source_path, destination_path)
    end
  end

  defp init_seed_upgrade_fixture!(base_dir) do
    assert :initialized = Identity.init!(base_dir)
    identity_dir = Path.join(base_dir, "identity")

    for relative <- Map.values(@seed_statutes) ++ Map.values(@seed_reactions) do
      File.rm(Path.join(identity_dir, relative))
    end

    git!(identity_dir, ["add", "-A"])
    git!(identity_dir, ["commit", "-m", "fixture: pre-upgrade identity"])
    revision = git!(identity_dir, ["rev-parse", "main"])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/live", revision])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/upstream", revision])
    :ok
  end

  defp assert_single_rail_definition!(base_dir, kind, name) do
    identity_dir = Path.join(base_dir, "identity")

    definitions =
      identity_dir
      |> Path.join("**/*.toml")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        data = Toml.decode!(File.read!(path))

        data
        |> Map.get(kind, [])
        |> List.wrap()
        |> Enum.filter(&(Map.get(&1, "name") == name))
        |> Enum.map(fn rail -> {Path.relative_to(path, identity_dir), rail} end)
      end)

    assert [{relative_path, rail}] = definitions
    assert rail["archetypes"] == ["*"]
    assert Provenance.owner_for_path(base_dir, relative_path) == :substrate
  end

  defp start_db! do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    db
  end

  defp seed_migration_rows!(db) do
    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) VALUES('session-fixture','sample','sample-owner','user:sample-owner',?1,'claude','anthropic','sample-model',1,1)",
               [@archetype]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO org_settings(key,value,updatedAt) VALUES('default-archetype',?1,1)",
               [@archetype]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO subtree_guidance_entries(writerSessionKey,name,archetypes,text,createdAt,updatedAt) VALUES('session-fixture','guide',?1,'sample',1,1)",
               [JSON.encode!([@archetype])]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO rail_remedy_episodes(statute,subject,status,occurrence,rewakeCount,claimToken,openedAt) VALUES(?1,'s','live',1,0,'claim',1)",
               [@rule]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO escalation_waivers(id,raiserId,statuteName,grantedBy,grantedAt) VALUES('waiver-fixture','session-fixture',?1,'sample-owner',1)",
               [@rule]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO wakes(wakeId,sessionKey,origin,prompt,consumer,dueAt,createdAt,deliveryRule,selectedPolicyName) VALUES('wake-fixture','session-fixture',?1,'fixture prompt','prompt',1,1,?2,?2)",
               ["remedy:#{@rule}", @rule]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO decision_requests(id,kind,raiserId,ownerUserId,raisedAt,deadlineAt,statuteName,actionKey,question,context,status) VALUES('decision-fixture','statute','session-fixture','sample-owner',1,2,?1,'action','question','{}','open')",
               [@rule]
             )

    seed_recurrence_rows!(db)
  end

  defp seed_recurrence_rows!(db) do
    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO recurrence_suppression_episodes(statute,targetSession,subject,fingerprintDigest,generation,openedEvidenceSequence,openedOccurrenceSequence) VALUES(?1,'session-fixture','s','digest',1,1,1)",
               [@rule]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO recurrence_suppression_deliveries(statute,subject,receiptId,dispatchKey,state) VALUES(?1,'s','receipt','dispatch','pending')",
               [@rule]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO recurrence_suppression_fact_observations(statute,targetSession,subject,fingerprintDigest,generation,phase,signature,matched) VALUES(?1,'session-fixture','s','digest',1,'recovered','signature',1)",
               [@rule]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO recurrence_suppression_receipts(statute,targetSession,subject,fingerprintDigest,generation,receiptId,outcome) VALUES(?1,'session-fixture','s','digest',1,'receipt','stored')",
               [@rule]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO recurrence_suppression_events(ts,outcome,statute,subject,generation,suppressedCount,cause,principal) VALUES(1,'suppressed',?1,'s',1,1,'fixture','process:test')",
               [@rule]
             )
  end

  defp migration_rows(db) do
    Enum.map(
      [
        "SELECT archetype FROM sessions ORDER BY sessionKey",
        "SELECT value FROM org_settings WHERE key='default-archetype'",
        "SELECT archetypes FROM subtree_guidance_entries ORDER BY writerSessionKey,name",
        "SELECT statute,subject FROM rail_remedy_episodes ORDER BY statute,subject",
        "SELECT statuteName,id FROM escalation_waivers ORDER BY id",
        "SELECT wakeId,deliveryRule,selectedPolicyName,origin FROM wakes ORDER BY wakeId",
        "SELECT id,statuteName FROM decision_requests ORDER BY id"
      ] ++
        Enum.map(
          ~w(
            recurrence_suppression_episodes
            recurrence_suppression_deliveries
            recurrence_suppression_fact_observations
            recurrence_suppression_receipts
            recurrence_suppression_events
          ),
          &"SELECT statute FROM #{&1} ORDER BY rowid"
        ),
      fn sql ->
        {:ok, rows} = DB.query(db, sql)
        rows
      end
    )
  end

  defp add_second_kungfu_rule!(base_dir) do
    identity_dir = Path.join(base_dir, "identity")
    owner = "other-kungfu"
    File.mkdir_p!(Path.join(identity_dir, "kungfu/#{owner}/rules"))

    File.write!(
      Path.join(identity_dir, "kungfu/#{owner}/rules/sample.toml"),
      "[[rule]]\nname = \"#{@rule}\"\nverb = \"assign\"\ntext = \"sample\"\ndeny_when = [{ fact = \"caller.origin_class\", op = \"eq\", value = \"user\" }]\n"
    )

    receipt_dir = Path.join(identity_dir, "kungfu/#{owner}")

    File.write!(
      Path.join(receipt_dir, "installed.toml"),
      "name = \"#{owner}\"\npaths = [\"kungfu/#{owner}/rules/sample.toml\"]\n"
    )

    git!(identity_dir, ["add", "-A"])
    git!(identity_dir, ["commit", "-m", "fixture: add another rail source"])
    revision = git!(identity_dir, ["rev-parse", "main"])
    git!(identity_dir, ["update-ref", "refs/heads/tightbeam/live", revision])
  end

  defp git!(dir, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Tightbeam Fixture"},
      {"GIT_AUTHOR_EMAIL", "fixture@tightbeam.local"},
      {"GIT_COMMITTER_NAME", "Tightbeam Fixture"},
      {"GIT_COMMITTER_EMAIL", "fixture@tightbeam.local"}
    ]

    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
