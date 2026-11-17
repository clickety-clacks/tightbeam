defmodule Tightbeam.RulePreflightTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Gateway, RulePreflight, Rules}

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
      Rules.load!(base, ["wake"])
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

  test "preflight retains receipt-owned scope validation and namespaced diagnostics", %{base: base} do
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
