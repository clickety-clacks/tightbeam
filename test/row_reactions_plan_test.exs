defmodule Tightbeam.RowReactions.PlanTest do
  use ExUnit.Case, async: true

  alias Tightbeam.RowReactions.Plan

  @event %{"kind" => "assignment", "org" => "fixture", "id" => "event"}
  @facts %{"scope_participant_archetypes" => ["sample.worker"]}

  test "the canonical organization handoff accepts a compiled policy context or wildcard" do
    assert Plan.handoff_default?(handoff(:substrate, ["*"]))
    refute Plan.handoff_default?(handoff(:substrate, []))

    assert Plan.handoff_default?(
             handoff(:substrate, [])
             |> Map.put(:policy_context, "organization")
           )
  end

  test "two eligible scoped plans still fail duplicate validation" do
    global = handoff(:substrate, ["*"])
    scoped = handoff({:kungfu, "sample"}, ["sample.worker"], ["worker"])

    assert_raise ArgumentError, "duplicate reaction identity or name", fn ->
      Plan.evaluate([global, scoped, scoped], @event, @facts)
    end
  end

  test "a non-notice effect at the canonical identity still fails duplicate validation" do
    global = handoff(:substrate, ["*"])
    scoped = handoff({:kungfu, "sample"}, ["sample.worker"], ["worker"])
    # A newer compiler can supply other effects. The evaluator's precedence
    # applies only to notices, even when they share a slot with such an effect.
    other =
      update_in(
        scoped.effects,
        &Enum.map(&1, fn effect -> %{effect | "kind" => "cancel_notice"} end)
      )

    assert_raise ArgumentError, "duplicate reaction identity or name", fn ->
      Plan.evaluate([global, other], @event, @facts)
    end
  end

  defp handoff(owner, archetypes, owned_archetypes \\ []) do
    Plan.compile!(
      %{
        "name" => "assignment-terminal-handoff",
        "archetypes" => archetypes,
        "family" => "terminal-handoff",
        "events" => ["assignment"],
        "when" => true,
        "effects" => [%{"slot" => "handoff", "kind" => "notice", "when" => true, "value" => %{}}]
      },
      %{},
      owner,
      owned_archetypes
    )
  end
end
