defmodule Tightbeam.FeatureSmokePlanTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{FeatureSmokePlan, Harness}

  # Every model is present unless overridden; every OTHER key — the leg filter included —
  # is unset unless a case sets it. A double that answered every key was fine while models
  # were the only thing read, and became a lie the moment a second key existed.
  defp env(overrides \\ %{}) do
    fn key ->
      case Map.fetch(overrides, key) do
        {:ok, value} ->
          value

        :error ->
          cond do
            String.starts_with?(key, "TIGHTBEAM_SMOKE_MODEL_") ->
              "model-for-" <> String.downcase(key)

            String.starts_with?(key, "TIGHTBEAM_SMOKE_EFFORT_") ->
              "medium"

            true ->
              nil
          end
      end
    end
  end

  defp names(legs), do: Enum.map(legs, & &1.wire_name)

  test "one explicitly modeled leg is driven for every registered harness" do
    legs = FeatureSmokePlan.legs(Harness.all(), env())

    assert Enum.map(legs, & &1.harness) == Harness.all()
    assert Enum.all?(legs, &is_binary(&1.model))

    Enum.each(legs, fn leg ->
      params = FeatureSmokePlan.explicit_spawn(leg, %{"displayName" => "Smoke"})

      assert params["harness"] == leg.wire_name
      assert params["model"] == leg.model
      # Fields, not one packed string: the effort rides its own key.
      assert params["effort"] == "medium"
      refute Map.has_key?(params, "context")
      assert params["displayName"] == "Smoke"
    end)
  end

  test "a missing per-harness model refuses the smoke before any leg runs" do
    assert_raise ArgumentError, ~r/missing TIGHTBEAM_SMOKE_MODEL_/, fn ->
      FeatureSmokePlan.legs(Harness.all(), fn _key -> nil end)
    end
  end

  test "the documented Cursor model input makes the registered leg plannable" do
    refute Tightbeam.Harness.Cursor in Harness.all()
    cursor = Tightbeam.Harness.Cursor

    [leg] =
      FeatureSmokePlan.legs([cursor], fn
        "TIGHTBEAM_SMOKE_MODEL_CURSOR" -> "catalog-listed-cursor-model"
        _ -> nil
      end)

    assert leg.wire_name == "cursor"
    assert leg.model == "catalog-listed-cursor-model"

    smoke = File.read!(Path.expand("../docs/SMOKE.md", __DIR__))
    assert smoke =~ "TIGHTBEAM_SMOKE_MODEL_CURSOR='<catalog-listed-cursor-model>'"
    assert smoke =~ "not a default"
    assert smoke =~ "claim of"
    assert smoke =~ "live support"
  end

  # e2e-tier-map-v1 GAP-3. Written against the REGISTRY rather than against literal harness
  # names, so the seam guard stays satisfied and a third registered harness does not
  # silently invalidate the cases.
  describe "leg filter" do
    test "unset runs every registered leg, which is the unchanged default" do
      assert names(FeatureSmokePlan.legs(Harness.all(), env(%{}))) ==
               Enum.map(Harness.all(), & &1.wire_name())

      assert FeatureSmokePlan.selection(Harness.all(), env(%{})) ==
               %{run: Enum.map(Harness.all(), & &1.wire_name()), filtered: []}
    end

    test "naming one leg runs exactly that leg and holds the rest back" do
      [first | rest] = Enum.map(Harness.all(), & &1.wire_name())
      getenv = env(%{"TIGHTBEAM_SMOKE_LEGS" => first})

      assert names(FeatureSmokePlan.legs(Harness.all(), getenv)) == [first]
      assert FeatureSmokePlan.selection(Harness.all(), getenv) == %{run: [first], filtered: rest}
    end

    test "a selected leg needs no model for the legs it filtered out" do
      [first | rest] = Enum.map(Harness.all(), & &1.wire_name())

      only_first =
        Map.new(rest, &{"TIGHTBEAM_SMOKE_MODEL_" <> String.upcase(&1), nil})
        |> Map.put("TIGHTBEAM_SMOKE_LEGS", first)

      assert names(FeatureSmokePlan.legs(Harness.all(), env(only_first))) == [first]
    end

    test "selection order follows the registry, never the env" do
      reversed = Harness.all() |> Enum.map(& &1.wire_name()) |> Enum.reverse() |> Enum.join(",")

      assert names(
               FeatureSmokePlan.legs(Harness.all(), env(%{"TIGHTBEAM_SMOKE_LEGS" => reversed}))
             ) ==
               Enum.map(Harness.all(), & &1.wire_name())
    end

    test "an unregistered leg name is a named refusal, not a silent empty run" do
      assert_raise ArgumentError, ~r/names unregistered leg\(s\): frobnicate/, fn ->
        FeatureSmokePlan.legs(Harness.all(), env(%{"TIGHTBEAM_SMOKE_LEGS" => "frobnicate"}))
      end
    end

    test "set-but-empty refuses rather than running zero legs and exiting green" do
      for blank <- ["", "   ", ",", " , "] do
        assert_raise ArgumentError, ~r/names no legs/, fn ->
          FeatureSmokePlan.legs(Harness.all(), env(%{"TIGHTBEAM_SMOKE_LEGS" => blank}))
        end
      end
    end
  end
end
