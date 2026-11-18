defmodule Tightbeam.RailScopeTest do
  use ExUnit.Case, async: true

  alias Tightbeam.RailScope

  test "every nonempty participant must be named" do
    assert RailScope.matches_agents?(["engineering.coder", "engineering.reviewer"], [
             "engineering.coder",
             "engineering.reviewer"
           ])

    refute RailScope.matches_agents?(["engineering.coder"], [
             "engineering.coder",
             "engineering.reviewer"
           ])
  end

  test "wildcard matches any participant and an empty declaration matches none" do
    assert RailScope.matches_agents?(["*"], ["org-example-analyst", "engineering.coder"])
    refute RailScope.matches_agents?([], ["engineering.coder"])
  end

  test "wildcard is valid only as the complete declaration" do
    refute RailScope.matches_agents?(["*", "engineering.coder"], ["engineering.coder"])
  end

  test "zero-agent interactions have no nonmatching participants" do
    assert RailScope.matches_agents?([], [])
    assert RailScope.matches_agents?(["engineering.coder"], [])
  end

  test "invalid inputs fail closed" do
    refute RailScope.matches_agents?(["*"], [nil])
    refute RailScope.matches_agents?("*", ["engineering.coder"])
  end
end
