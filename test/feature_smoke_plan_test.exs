defmodule Tightbeam.FeatureSmokePlanTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{FeatureSmokePlan, Harness}

  test "one explicitly modeled leg is driven for every registered harness" do
    getenv = fn key -> "model-for-" <> String.downcase(key) end
    legs = FeatureSmokePlan.legs(Harness.all(), getenv)

    assert Enum.map(legs, & &1.harness) == Harness.all()
    assert Enum.all?(legs, &is_binary(&1.model))

    Enum.each(legs, fn leg ->
      params = FeatureSmokePlan.explicit_spawn(leg, %{"displayName" => "Smoke"})

      assert params["harness"] == leg.wire_name
      assert params["model"] == leg.model
      assert params["displayName"] == "Smoke"
    end)
  end

  test "a missing per-harness model refuses the smoke before any leg runs" do
    assert_raise ArgumentError, ~r/missing TIGHTBEAM_SMOKE_MODEL_/, fn ->
      FeatureSmokePlan.legs(Harness.all(), fn _key -> nil end)
    end
  end
end
