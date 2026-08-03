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

  test "params carry named fields from either key shape" do
    chosen = Model.new("gpt-5.6-sol", effort: "medium")

    assert Model.from_params(%{"model" => "gpt-5.6-sol", "effort" => "medium"}) == chosen
    assert Model.from_params(%{model: "gpt-5.6-sol", effort: "medium"}) == chosen
    assert Model.from_params(%{"model" => "", "effort" => "medium"}) == nil
    assert Model.from_params(%{"effort" => "medium"}) == nil
  end

  # WHERE THE DISTINCTION IS DESTROYED. `named_fields/1` is the function that
  # claims to carry "omitted" and "explicitly nil" apart, so it is the function
  # that has to be tested for it — the gateway tests only ever saw a nil that
  # `resolve_issued/3` manufactured AFTER this ran, so they could not see this
  # collapse at all. Coverage of a distinction belongs where it can be lost,
  # not only where it is made.
  test "an explicitly nil field is named, and an omitted one is not" do
    assert Model.named_fields(%{model: "m", context: nil}) == %{family: "m", context: nil}
    assert Model.named_fields(%{model: "m"}) == %{family: "m"}

    assert Model.named_fields(%{"model" => "m", "context" => nil}) ==
             %{family: "m", context: nil}

    # An empty string is the wire's way of saying "cleared", which is explicit.
    assert Model.named_fields(%{model: "m", context: ""}) == %{family: "m", context: nil}

    # Same for effort: naming no tier is a real answer, distinct from silence.
    assert Model.named_fields(%{model: "m", effort: nil}) == %{family: "m", effort: nil}
    assert Model.named_fields(%{model: "m", effort: "high"}) == %{family: "m", effort: "high"}
  end

  # The family is the exception, and deliberately: there is no model you select
  # by declining to name one, so an explicitly nil family is absence.
  test "an explicitly nil family is absence, not a selection" do
    assert Model.named_fields(%{model: nil, effort: "high"}) == %{effort: "high"}
    assert Model.named_fields(%{model: nil}) == %{}
    refute Map.has_key?(Model.named_fields(%{model: nil}), :family)
  end

  test "describe names every field for a reader who must pick one" do
    assert Model.describe(Model.new("gpt-5.6-sol")) == "gpt-5.6-sol"

    assert Model.describe(Model.new("gpt-5.6-sol", effort: "medium")) ==
             "gpt-5.6-sol (effort medium)"

    assert Model.describe(nil) == "unknown"
  end
end
