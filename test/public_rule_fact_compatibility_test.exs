defmodule Tightbeam.PublicRuleFactCompatibilityTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @verifier Path.join(@root, "scripts/verify_public_rule_facts.py")
  @baseline "6c13efcbe9e1ae247b8aa7e91a374015c74dc947"
  @source "lib/tightbeam/rules.ex"

  test "a merge cannot drop a public fact introduced on a side branch" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "public-rule-facts-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(repo) end)

    git!(Path.dirname(repo), ["clone", "--shared", @root, repo])
    git!(repo, ["config", "user.name", "tightbeam test"])
    git!(repo, ["config", "user.email", "test@tightbeam.invalid"])
    git!(repo, ["switch", "-c", "specimen-main", @baseline])

    source_path = Path.join(repo, @source)
    baseline_source = File.read!(source_path)

    git!(repo, ["switch", "-c", "specimen-side"])

    side_source =
      String.replace(
        baseline_source,
        "@facts %{\n",
        "@facts %{\n    \"specimen.side_fact\" => %{},\n",
        global: false
      )

    refute side_source == baseline_source
    File.write!(source_path, side_source)
    git!(repo, ["add", @source])
    git!(repo, ["commit", "-m", "add side-branch public fact"])

    git!(repo, ["switch", "specimen-main"])
    git!(repo, ["merge", "--no-commit", "--no-ff", "specimen-side"])
    File.write!(source_path, baseline_source)
    git!(repo, ["add", @source])
    git!(repo, ["commit", "-m", "drop side-branch public fact at merge"])

    {output, status} =
      System.cmd("python3", [@verifier], cd: repo, stderr_to_stdout: true)

    assert status == 1
    assert output =~ "public rule facts cannot be removed"
    assert output =~ "specimen.side_fact"
  end

  defp git!(repo, args) do
    {output, status} =
      System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

    assert status == 0, "git #{Enum.join(args, " ")} failed:\n#{output}"
    String.trim(output)
  end
end
