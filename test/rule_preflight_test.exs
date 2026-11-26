defmodule Tightbeam.RulePreflightTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Gateway, Identity, RulePreflight, RuleReferences, Rules}

  setup do
    base = Path.join(System.tmp_dir!(), "rule-preflight-#{System.unique_integer([:positive])}")
    assert :initialized = Tightbeam.Identity.init!(base)

    on_exit(fn ->
      Rules.load!(Path.join(base, "absent"), [])
      File.rm_rf!(base)
    end)

    %{base: base}
  end

  test "reports unavailable verbs and skipped policies from candidate rules", %{base: base} do
    path = Path.join([base, "identity", "rules", "preflight.toml"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    [[rule]]
    name = "unsupported-check"
    archetypes = ["*"]
    verb = "wake"
    deny_when = [{ fact = "not.a.supported.fact", op = "eq", value = true }]
    text = "unsupported"

    [[policy]]
    name = "retired-policy"
    purpose = "wait-effort-relief"
    """)

    ExUnit.CaptureLog.capture_log(fn ->
      Rules.load!(base, Map.keys(Gateway.handlers(%{base_dir: base})))
    end)

    status = Rules.status()
    refute status.recording_available
    assert Enum.any?(status.unavailable_verbs, &(&1.verb == "wake"))
    assert Enum.any?(status.skipped_policies, &(&1.name == "retired-policy"))
    assert Enum.all?(status.unavailable_verbs, &(&1.file == "rules/preflight.toml"))
  end

  test "preflight returns a warning report without modifying the installed identity", %{
    base: base
  } do
    path = Path.join([base, "identity", "rules", "preflight.toml"])
    File.mkdir_p!(Path.dirname(path))

    bytes = """
    [[policy]]
    name = "retired-policy"
    purpose = "wait-effort-relief"
    """

    File.write!(path, bytes)

    ExUnit.CaptureLog.capture_log(fn ->
      report = RulePreflight.run(base)
      assert report.complete
      assert Enum.any?(report.warnings, &String.contains?(&1, "retired-policy"))
      assert File.read!(path) == bytes
    end)
  end

  test "preflight retains receipt-owned scope validation and namespaced diagnostics", %{
    base: base
  } do
    root = Path.join([base, "identity", "kungfu", "preflight-scope"])
    archetype_path = Path.join(root, "archetypes/analyst.toml")
    rule_path = Path.join(root, "rules/owned.toml")
    File.mkdir_p!(Path.dirname(archetype_path))
    File.mkdir_p!(Path.dirname(rule_path))
    File.write!(archetype_path, ~s(name = "analyst"\nskills = []\nwhere = ["*"]\n))

    File.write!(Path.join(root, "installed.toml"), """
    name = "preflight-scope"
    paths = ["kungfu/preflight-scope/archetypes/analyst.toml", "kungfu/preflight-scope/rules/owned.toml"]
    """)

    bytes = """
    [[rule]]
    name = "valid-owned"
    verb = "wake"
    archetypes = ["preflight-scope.analyst"]
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    text = "owned scope"

    [[rule]]
    name = "foreign-scope"
    verb = "condition"
    archetypes = ["another-kungfu.analyst"]
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    text = "foreign scope"
    """

    File.write!(rule_path, bytes)

    ExUnit.CaptureLog.capture_log(fn ->
      report = RulePreflight.run(base)
      assert report.complete
      refute report.recording_available

      assert Enum.any?(report.unavailable_verbs, fn item ->
               item.file == "kungfu/preflight-scope/rules/owned.toml" and
                 item.verb == "condition" and item.name == "foreign-scope"
             end)

      refute Enum.any?(report.unavailable_verbs, &(&1.name == "valid-owned"))
      assert File.read!(rule_path) == bytes
    end)
  end

  test "a pending upgrade checks the converted engineering rule and preserves its source", %{
    base: base
  } do
    dir = Path.join(base, "identity")
    default = File.read!(Path.join(dir, "archetypes/default.toml"))

    write!(
      dir,
      "archetypes/coder.toml",
      String.replace(default, ~s(name = "default"), ~s(name = "coder"))
    )

    write!(
      dir,
      "archetypes/exec.toml",
      String.replace(default, ~s(name = "default"), ~s(name = "exec"))
    )

    write!(dir, "kungfu/agentic-engineering/manifest.toml", ~s(name = "agentic-engineering"
))

    write!(dir, "kungfu/agentic-engineering/installed.toml", """
    name = "agentic-engineering"
    paths = ["archetypes/coder.toml", "rules/legacy.toml"]
    """)

    rule = """
    [[rule]]
    name = "legacy-staffing"
    verb = "spawn"
    deny_when = [
      { fact = "spawn.archetype", op = "not_in", value = ["coder", "exec"] },
      { fact = "work_item.reference_state", op = "ne", value = "known" },
    ]
    text = "Worker staffing needs a work item"
    """

    path = write!(dir, "rules/legacy.toml", rule)
    revision = commit_live!(dir)
    report = RulePreflight.run(base, :pending_upgrade)
    assert report.recording_available, inspect(report.warnings)
    assert report.unavailable_verbs == []
    assert File.read!(path) == rule
    assert git!(dir, ["rev-parse", "main"]) == revision
    assert Identity.live_revision!(base) == revision

    File.write!(path, String.replace(rule, ~s("exec"), ~s("missing-exec")))
    commit_live!(dir)

    assert_raise ArgumentError, ~r/legacy-staffing.*unknown archetype.*missing-exec/, fn ->
      RulePreflight.run(base, :pending_upgrade)
    end
  end

  test "the selector uses the database marker to choose the preview", %{base: base} do
    path = Path.join(base, "state.db")
    assert {:ok, conn} = Exqlite.Sqlite3.open(path)

    try do
      assert Tightbeam.Identity.RailScopeMigration.pending_for_database!(path)

      assert :ok =
               Exqlite.Sqlite3.execute(conn, """
               CREATE TABLE rail_scope_migrations (migrationId TEXT, reportJson TEXT)
               """)

      assert Tightbeam.Identity.RailScopeMigration.pending_for_database!(path)

      assert :ok =
               Exqlite.Sqlite3.execute(conn, """
               INSERT INTO rail_scope_migrations VALUES ('rail-scope-v1',
                 '{"schema":"tightbeam-rail-scope-migration/v1","status":"complete","source_revision":"before","result_revision":"after"}')
               """)

      refute Tightbeam.Identity.RailScopeMigration.pending_for_database!(path)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  test "publishing a candidate checks its committed rule references", %{base: base} do
    dir = Path.join(base, "identity")
    live = Identity.live_revision!(base)
    path = write!(dir, "rules/orphan.toml", orphan_rule())
    git!(dir, ["add", "-A"])

    git!(dir, [
      "-c",
      "user.name=test",
      "-c",
      "user.email=test@localhost",
      "commit",
      "-m",
      "orphan"
    ])

    revision = git!(dir, ["rev-parse", "HEAD"])
    File.rm!(path)

    assert_raise ArgumentError, ~r/orphaned-topology.*unknown kungfu.*removed/, fn ->
      Identity.publish_live!(base, %{candidate_revision: revision, expected_prior: live})
    end

    assert Identity.live_revision!(base) == live
  end

  test "startup law loading warns when an orphan is already installed", %{base: base} do
    write!(Path.join(base, "identity"), "rules/orphan.toml", orphan_rule())
    db = start_supervised!({Tightbeam.DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Gateway.load_law!(%{base_dir: base, db: db})
      end)

    assert log =~
             ~s(Invalid rule reference: rules/orphan.toml: rule "orphaned-topology": unknown kungfu "removed")

    assert log =~ ~s(unknown archetype "removed.worker")
  end

  test "reference diagnostics name the missing condition fact, secondary verb and remedy archetype" do
    diagnostics =
      RuleReferences.diagnostics(%{
        "rules/references.toml" => """
        [[rule]]
        name = "missing-references"
        verb = "assign"
        verbs = ["assign", "invented-verb"]
        deny_when = [{ fact = "missing.fact", op = "eq", value = true }]
        [rule.remedy]
        action = "spawn"
        archetype = "missing-worker"
        """
      })

    assert Enum.any?(diagnostics, &(&1 =~ ~s(unknown fact "missing.fact")))
    assert Enum.any?(diagnostics, &(&1 =~ ~s(unknown verb "invented-verb")))
    assert Enum.any?(diagnostics, &(&1 =~ ~s(unknown archetype "missing-worker")))
  end

  defp orphan_rule do
    """
    [[rule]]
    name = "orphaned-topology"
    archetypes = ["removed.worker"]
    verb = "spawn"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    text = "Fixture rule"
    """
  end

  defp write!(dir, relative, bytes) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp commit_live!(dir) do
    git!(dir, ["add", "-A"])

    git!(dir, [
      "-c",
      "user.name=test",
      "-c",
      "user.email=test@localhost",
      "commit",
      "-m",
      "legacy"
    ])

    revision = git!(dir, ["rev-parse", "HEAD"])
    git!(dir, ["update-ref", "refs/heads/tightbeam/live", revision])
    revision
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(output)
  end

  test "a later load clears stale unavailability diagnostics", %{base: base} do
    ExUnit.CaptureLog.capture_log(fn ->
      Rules.load!(base, Map.keys(Gateway.handlers(%{base_dir: base})))
    end)

    Rules.load!(Path.join(base, "empty"), [])

    assert Rules.status() == %{
             recording_available: true,
             unavailable_verbs: [],
             skipped_policies: []
           }
  end
end
