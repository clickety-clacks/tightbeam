defmodule Tightbeam.GithubRuleTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Rails, Rules}

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tb-github-rule-#{System.unique_integer([:positive])}")

    rules_dir = Path.join([base_dir, "identity", "rules"])
    File.mkdir_p!(rules_dir)

    source =
      Application.app_dir(
        :tightbeam,
        "priv/kungfu/agentic-engineering/rules/github.toml"
      )

    destination = Path.join(rules_dir, "github.toml")
    File.cp!(source, destination)

    System.cmd("git", ["init", "-q"], cd: Path.join(base_dir, "identity"))
    System.cmd("git", ["config", "user.name", "fixture"], cd: Path.join(base_dir, "identity"))

    System.cmd("git", ["config", "user.email", "fixture@example.invalid"],
      cd: Path.join(base_dir, "identity")
    )

    System.cmd("git", ["add", "rules/github.toml"], cd: Path.join(base_dir, "identity"))

    System.cmd("git", ["commit", "-q", "-m", "fixture"], cd: Path.join(base_dir, "identity"))

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Rules)
      :persistent_term.erase(Tightbeam.Rails)
    end)

    %{base_dir: base_dir, path: destination}
  end

  test "the reviewed GitHub law loads and compiles the exact internal command", ctx do
    assert [rule] = Rules.load!(ctx.base_dir, [])
    assert rule.name == "github-network-auth-required"
    assert rule.verb == "tool-call"
    assert rule.edges == ["pre-execution"]
    assert rule.actors == %{capability: "Bash"}
    assert rule.check.handler == "github-network-auth-v1"
    assert rule.check.abi == 1
    assert rule.check.timeout_ms == 60_000

    Rails.load!(ctx.base_dir)

    assert %{
             "hooks" => %{
               "PreToolUse" => [
                 %{
                   "matcher" => "Bash",
                   "hooks" => [
                     %{
                       "type" => "command",
                       "command" => command,
                       "timeout" => 60
                     }
                   ]
                 },
                 observation
               ]
             }
           } = Rails.hook_settings()

    assert command ==
             "tightbeam dispatch-rule-check --rule github-network-auth-required " <>
               "--handler github-network-auth-v1 --abi 1 --identity-sha #{rule.identity_manifest_sha}"

    assert observation == Rails.observation_entry()
  end

  test "invalid tool-call law shapes refuse by the named compiler boundary", ctx do
    original = File.read!(ctx.path)

    cases = [
      {"actors = { capability = \"Bash\" }", "actors = { capability = \"WebFetch\" }"},
      {"edges = [\"pre-execution\"]", "edges = [\"verb\"]"},
      {"handler = \"github-network-auth-v1\"", "handler = \"unknown-handler\""},
      {"abi = 1", "abi = 2"},
      {"timeout_ms = 60000", "timeout_ms = 60001"},
      {"malformed_tool_call = \"deny\"", "malformed_tool_call = \"allow\""},
      {"rule_runtime_failure = \"deny\"", "rule_runtime_failure = \"allow\""}
    ]

    for {from, to} <- cases do
      File.write!(ctx.path, String.replace(original, from, to))

      assert_raise ArgumentError, ~r/tool-call-rule-invalid/, fn ->
        Rules.load!(ctx.base_dir, [])
      end
    end
  end

  test "gateway rules still reject actors instead of silently changing shape", ctx do
    gateway = """
    [[rule]]
    name = "ordinary"
    verb = "wake"
    actors = { capability = "Bash" }
    text = "ordinary"
    deny_when = [{ fact = "caller.is_admin", op = "eq", value = false }]
    """

    File.write!(ctx.path, gateway)

    assert_raise ArgumentError, ~r/actors is valid only on verb tool-call/, fn ->
      Rules.load!(ctx.base_dir, ["wake"])
    end
  end
end
