defmodule Tightbeam.RowReactionPlanTest do
  use ExUnit.Case, async: true
  alias Tightbeam.RowReactions.Plan

  @rail """
  [[reaction]]
  name = "work-started"
  family = "work-status"
  events = ["turn"]
  when = {op = "and", args = [{op = "eq", args = [{ref = "event.before.status"}, "queued"]}, {op = "eq", args = [{ref = "event.after.status"}, "running"]}]}
  bind = [{name = "recipient", value = {ref = "facts.assignment.openedBySession"}}]
  effects = [{slot = "started", kind = "notice", when = {op = "not", args = [{op = "is_null", args = [{ref = "recipient"}]}]}, value = {target = {ref = "recipient"}, prompt = "Work started", due_at = {ref = "event.at"}}}]
  """

  defp event do
    %{
      "id" => "transition-1",
      "org" => "example",
      "kind" => "turn",
      "at" => 100,
      "before" => %{"status" => "queued"},
      "after" => %{"status" => "running"}
    }
  end

  defp facts, do: %{"assignment" => %{"openedBySession" => "parent"}}

  test "election, removal and changed TOML determine the planned status reaction" do
    rails = Plan.decode!(@rail, %{revision: "one", bundle: "engineering"})
    assert [plan] = Plan.evaluate(rails, event(), facts())
    assert plan.value == %{"target" => "parent", "prompt" => "Work started", "due_at" => 100}
    assert plan.identity == {"example", "work-status", "transition-1", "started"}
    assert [] == Plan.evaluate([], event(), facts())
    assert [] == Plan.evaluate(rails, put_in(event(), ["before", "status"], "running"), facts())
    assert [] == Plan.evaluate(rails, %{event() | "kind" => "attest"}, facts())

    assert [] ==
             Plan.evaluate(
               rails,
               event(),
               put_in(facts(), ["assignment", "openedBySession"], nil)
             )

    changed =
      @rail
      |> String.replace("Work started", "Started work")
      |> String.replace("facts.assignment.openedBySession", "facts.owner")

    assert [updated] =
             Plan.evaluate(Plan.decode!(changed, %{revision: "two"}), event(), %{
               "owner" => "new-parent"
             })

    assert updated.identity == plan.identity
    assert updated.value["target"] == "new-parent"
    assert updated.value["prompt"] == "Started work"
    assert updated.provenance == %{revision: "two"}
  end

  test "ordered bindings permit data-selected recipients without a named handler" do
    rail = Toml.decode!(@rail)["reaction"] |> hd()

    rail =
      Map.put(rail, "bind", [
        %{"name" => "candidates", "value" => %{"ref" => "facts.sessions"}},
        %{
          "name" => "recipient",
          "value" => %{"op" => "first", "args" => [%{"ref" => "candidates"}]}
        }
      ])

    compiled = Plan.compile!(rail, %{})
    assert [plan] = Plan.evaluate([compiled], event(), %{"sessions" => ["first", "second"]})
    assert plan.value["target"] == "first"
  end

  test "action slots cannot collide across matching rules" do
    [rail] = Plan.decode!(@rail, %{})

    assert_raise ArgumentError, ~r/duplicate action identity/, fn ->
      Plan.evaluate([rail, %{rail | name: "another-name"}], event(), facts())
    end

    assert_raise ArgumentError, ~r/duplicate reaction name/, fn ->
      Plan.decode!(@rail <> @rail, %{})
    end
  end

  test "invalid policy is refused instead of becoming a silent non-match" do
    rail = Toml.decode!(@rail)["reaction"] |> hd()

    assert_raise ArgumentError, ~r/condition must evaluate to a boolean/, fn ->
      Plan.evaluate([Plan.compile!(%{rail | "when" => "yes"}, %{})], event(), facts())
    end

    assert_raise ArgumentError, ~r/unknown effect kind/, fn ->
      Plan.decode!(
        String.replace(@rail, "kind = \"notice\"", "kind = \"notify-assignment\""),
        %{}
      )
    end
  end
end
