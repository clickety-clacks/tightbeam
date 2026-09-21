defmodule Tightbeam.EvalsTest do
  use ExUnit.Case, async: true

  test "the matching stated-goal scenario asserts the offer before any plan" do
    evals = File.read!("docs/EVALS.md")

    [_, scenario] = String.split(evals, "5. **matching-goal kungfu offer**", parts: 2)
    scenario = scenario |> String.split("\n\nRunner:", parts: 2) |> hd()

    assert scenario =~ ~s("I want to write software.")
    assert scenario =~ "first sentence names `agentic-engineering`"
    assert scenario =~ "offers to learn it before"
    assert scenario =~ "any other plan"
    assert scenario =~ "runs a tool before making the offer"
  end
end
