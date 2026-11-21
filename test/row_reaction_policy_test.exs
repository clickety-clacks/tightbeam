defmodule Tightbeam.RowReactionPolicyTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Rules

  test "learned engineering composition elects unaltered organization work-item rails" do
    base =
      Path.join(System.tmp_dir!(), "work-item-election-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base) end)
    assert {:ok, _} = Tightbeam.Identity.learn!(base, "agentic-engineering", "test")
    path = "kungfu/agentic-engineering/rules/row-reaction-work-items.toml"

    assert File.read!(Path.join([base, "identity", path])) ==
             File.read!(Path.join(:code.priv_dir(:tightbeam), path))

    Rules.load!(base, Map.keys(Tightbeam.Gateway.handlers(%{db: :unused_election_database})))

    item = %{
      "id" => "wi_fixture",
      "state" => "open",
      "title" => "Election",
      "ownerUserId" => "owner",
      "deliveryOwnerSessionKey" => "delivery",
      "routingWakeId" => nil,
      "slateWakeId" => nil
    }

    event = %{
      "id" => "fixture-close",
      "org" => "owner",
      "kind" => "work_item_observation",
      "workItemId" => item["id"],
      "operation" => "assignment_closed",
      "at" => 10,
      "before" => %{"deliveredWakeId" => nil},
      "after" => item
    }

    facts = %{
      "work_item" => item,
      "open_assignment_count" => 0,
      "personal_session_key" => "personal",
      "sessions" => [
        %{"sessionKey" => "personal", "archetype" => "default", "state" => "active"},
        %{
          "sessionKey" => "delivery",
          "archetype" => "agentic-engineering.pdo",
          "state" => "active"
        }
      ]
    }

    plans = Rules.reaction_plans(event, facts)
    assert length(plans) == 4
    selected = Enum.filter(plans, & &1.selected)

    assert [
             %{
               family: "r05-work-item",
               provenance: %{"bundle" => "agentic-engineering"},
               value: %{"session_key" => "delivery"}
             }
           ] = selected

    item = Map.put(item, "slateWakeId", "legacy-slate")

    withdrawal =
      event
      |> Map.put("id", "fixture-assign")
      |> Map.put("operation", "transition")
      |> Map.put("after", item)

    assert [%{family: "r05-work-item-withdraw", selected: true}] =
             Rules.reaction_plans(withdrawal, Map.put(facts, "work_item", item))
             |> Enum.filter(& &1.selected)
  end

  test "a settings-only reaction rail does not create a row action" do
    assert [] = Rules.reaction_plans(%{"kind" => "assignment"}, %{})
  end

  test "harness recovery defaults are seed-elected and limited to rate-limit-dead" do
    assert %{settings: settings, english: english, provenance: provenance} =
             Rules.reaction_policy("harness-health-recovery")

    assert settings["eligible_failure_classes"] == ["rate-limit-dead"]
    assert settings["interval_ms"] == 120_000
    assert settings["timeout_ms"] == 120_000
    assert settings["start"] == "schedule_one_cycle_for_eligible_open_hold"
    assert settings["withdraw"] == "withdraw_resolved_or_ineligible_cycle_at_delivery"
    assert settings["reschedule"] == "move_the_single_pending_cycle_in_place"
    assert settings["release"] == "resolve_only_after_all_constituent_routes_succeed"
    assert english =~ "Owning bundle: substrate base seed."
    assert english =~ "first cycle is due after two minutes"
    assert provenance["source"] == "rules/harness-health-recovery.toml"
  end

  test "the removed inactivity behavior has no compiled policy fallback" do
    empty =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-no-assignment-inactivity-#{System.unique_integer([:positive])}"
      )

    assert [] = Rules.load!(empty, [])
    assert is_nil(Rules.reaction_policy("assignment-inactivity"))
  end
end
