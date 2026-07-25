defmodule Tightbeam.FeatureSmokePlan do
  @moduledoc false

  @spec legs([module()], (String.t() -> String.t() | nil)) :: [map()]
  def legs(harnesses, getenv \\ &System.get_env/1) do
    Enum.map(harnesses, fn harness ->
      wire_name = harness.wire_name()
      model_env = "TIGHTBEAM_SMOKE_MODEL_" <> String.upcase(wire_name)

      model =
        getenv.(model_env) ||
          raise ArgumentError,
                "missing #{model_env}; feature_smoke requires one compatible model per registered harness"

      %{harness: harness, wire_name: wire_name, model: model, model_env: model_env}
    end)
  end

  @spec provider_names([module()]) :: [String.t()]
  def provider_names(harnesses) do
    harnesses
    |> Enum.map(& &1.credential_provider())
    |> Enum.uniq()
    |> Enum.map(&(Atom.to_string(&1) |> String.replace("_", "-")))
  end

  @spec explicit_spawn(map(), map()) :: map()
  def explicit_spawn(leg, params) do
    params
    |> Map.put("harness", leg.wire_name)
    |> Map.put("model", leg.model)
  end
end
