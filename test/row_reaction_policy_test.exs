defmodule Tightbeam.RowReactionPolicyTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Rules

  test "assignment inactivity defaults are elected with their aligned English meaning" do
    assert %{settings: settings, english: english, provenance: provenance} =
             Rules.reaction_policy("assignment-inactivity")

    assert settings["period_ms"] == 1_800_000
    assert settings["holder_reminder_limit"] == 2

    assert settings["escalation_order"] == [
             "opener",
             "active_ancestors",
             "owner_personal_session"
           ]

    assert english =~ "30 minutes by default"
    assert english =~ "at most twice"
    assert english =~ "same resumable episode"
    assert provenance["source"] == "rules/row-reaction-assignment-inactivity.toml"
    assert provenance["content_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a settings-only reaction rail does not create a row action" do
    assert [] = Rules.reaction_plans(%{"kind" => "assignment"}, %{})
  end

  test "absence of the assignment inactivity rail has no compiled policy fallback" do
    empty =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-no-assignment-inactivity-#{System.unique_integer([:positive])}"
      )

    assert [] = Rules.load!(empty, [])
    assert is_nil(Rules.reaction_policy("assignment-inactivity"))
  end
end
