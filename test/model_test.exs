defmodule Tightbeam.ModelTest do
  use ExUnit.Case, async: true

  doctest Tightbeam.Model

  alias Tightbeam.Model

  test "an identity round-trips through the vendor line format" do
    for ref <- ["claude-fable-5", "claude-fable-5[1m]", "gpt-5.6-sol"] do
      assert ref |> Model.parse_ref() |> Model.to_ref() == ref
    end
  end

  test "effort never enters the vendor line format and survives the round trip beside it" do
    chosen = Model.new("claude-fable-5", context: "1m", effort: "high")

    rendered = Model.to_ref(chosen)
    assert rendered == "claude-fable-5[1m]"

    assert %{Model.parse_ref(rendered) | effort: chosen.effort} == chosen
  end

  test "params carry named fields in both directions" do
    chosen = Model.new("gpt-5.6-sol", effort: "medium")

    assert Model.to_params(chosen) == %{"model" => "gpt-5.6-sol", "effort" => "medium"}
    assert Model.from_params(%{"model" => "gpt-5.6-sol", "effort" => "medium"}) == chosen
    assert Model.from_params(%{model: "gpt-5.6-sol", effort: "medium"}) == chosen
    assert Model.from_params(%{"model" => "", "effort" => "medium"}) == nil
    assert Model.from_params(%{"effort" => "medium"}) == nil
  end

  test "same_model? ignores effort and respects the context variant" do
    fable = Model.new("claude-fable-5")
    fable_wide = Model.new("claude-fable-5", context: "1m")

    assert Model.same_model?(fable, %{fable | effort: "max"})
    refute Model.same_model?(fable, fable_wide)
  end

  test "describe names every field for a reader who must pick one" do
    assert Model.describe(Model.new("gpt-5.6-sol")) == "gpt-5.6-sol"

    assert Model.describe(Model.new("gpt-5.6-sol", effort: "medium")) ==
             "gpt-5.6-sol (effort medium)"

    assert Model.describe(nil) == "unknown"
  end
end
