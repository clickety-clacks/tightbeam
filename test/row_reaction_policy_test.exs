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

  test "the seeded substrate file supplies one values-only family per mechanism" do
    base =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-substrate-settings-#{System.unique_integer([:positive])}"
      )

    path = Path.join(base, "identity/rules/substrate.toml")
    File.mkdir_p!(Path.dirname(path))
    File.cp!(
      Path.expand("../priv/seed/rules/substrate.toml", __DIR__),
      path
    )

    on_exit(fn -> File.rm_rf!(base) end)

    assert [] = Rules.load!(base, [])

    assert %{settings: %{"recipients" => ["owner"]}} =
             Rules.reaction_policy("notice-audience")

    assert is_nil(Rules.reaction_policy("wait-transitions"))

    assert %{settings: %{"queued_turns" => 20, "oldest_age_ms" => 3_600_000}} =
             Rules.reaction_policy("queue-thresholds")

    assert %{settings: %{"batching_enabled" => true, "class_order" => class_order}} =
             Rules.reaction_policy("notice-delivery")

    assert class_order == ["algedonic", "blocker", "input-needed", "status-query", "fyi"]

    assert %{
             settings: %{
               "automatic_retirement" => true,
               "result_recipients" => ["caller", "parent"]
             }
           } = Rules.reaction_policy("single-turn-session")

    assert %{settings: %{"link_current_turn" => true}} =
             Rules.reaction_policy("work-item-context")

    assert %{
             settings: %{
               "escalate_script_failures" => true,
               "recover_on_success" => true
             }
           } = Rules.reaction_policy("rule-failure")

    assert %{
             settings: %{
               "protected_descendant_kinds" => ["open_assignments", "bound_roles"],
               "refuse_by_default" => true,
               "kept_parent_order" => ["active_ancestor", "owner_personal_session"]
             }
           } = Rules.reaction_policy("session-retirement")
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
