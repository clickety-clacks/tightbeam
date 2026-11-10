defmodule Tightbeam.RowReactionPolicyTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Rules

  test "a settings-only reaction rail does not create a row action" do
    assert [] = Rules.reaction_plans(%{"kind" => "assignment"}, %{})
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
