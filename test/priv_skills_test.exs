defmodule Tightbeam.PrivSkillsTest do
  use ExUnit.Case, async: true

  @baseline_skill_names [
    "tightbeam-dispatching",
    "tightbeam-assimilate",
    "tightbeam-harnesses",
    "tightbeam-skills",
    "tightbeam-onboarding",
    "tightbeam-guidance-authoring",
    "tightbeam-law-minting",
    "tightbeam-archetype-cultivation",
    "tightbeam-kungfu-crafting"
  ]

  test "all substrate baseline skills ship in priv and are non-empty" do
    assert Tightbeam.Homes.baseline_skill_names() == @baseline_skill_names

    for name <- @baseline_skill_names do
      path = Application.app_dir(:tightbeam, "priv/skills/#{name}/SKILL.md")
      assert File.regular?(path), "missing shipped baseline skill: #{path}"
      assert File.read!(path) != "", "empty shipped baseline skill: #{path}"
    end
  end

  test "neutral guidance skills use domain-neutral role examples" do
    authoring =
      Application.app_dir(:tightbeam, "priv/skills/tightbeam-guidance-authoring/SKILL.md")
      |> File.read!()

    cultivation =
      Application.app_dir(:tightbeam, "priv/skills/tightbeam-archetype-cultivation/SKILL.md")
      |> File.read!()

    refute authoring =~ ~r/\b(spec|spec-writer|coder|reviewer)\b/i
    refute cultivation =~ ~r/\b(spec|product[- ]owner)\b/i
  end
end
