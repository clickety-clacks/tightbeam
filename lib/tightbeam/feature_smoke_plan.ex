defmodule Tightbeam.FeatureSmokePlan do
  @moduledoc false

  # e2e-tier-map-v1 GAP-3: T2a could not run one leg. `legs/2` mapped the compile-time
  # registry and raised without a model for EVERY harness, so a targeted question — "does
  # the codex recorder land tool-call-observed?" — cost a full both-leg run and a claude
  # model it had no use for. The map names this filter as the fix.
  #
  # Narrowing is legitimate and never a lie, which is the whole reason the selection is
  # reported rather than merely applied: a filtered run is INCOMPLETE(parity) BY DESIGN,
  # and it must never be readable as full coverage. `selection/2` exists so the caller can
  # say which legs ran AND which were held back.
  @legs_env "TIGHTBEAM_SMOKE_LEGS"

  @spec legs([module()], (String.t() -> String.t() | nil)) :: [map()]
  def legs(harnesses, getenv \\ &System.get_env/1) do
    harnesses
    |> select(getenv)
    |> Enum.map(fn harness ->
      wire_name = harness.wire_name()
      model_env = "TIGHTBEAM_SMOKE_MODEL_" <> String.upcase(wire_name)

      model =
        getenv.(model_env) ||
          raise ArgumentError,
                "missing #{model_env}; feature_smoke requires one compatible model per selected leg"

      %{harness: harness, wire_name: wire_name, model: model, model_env: model_env}
    end)
  end

  @doc """
  Which legs this run drives and which the filter held back.

  Resolved WITHOUT reading any model, so a caller can report the shape of its run before
  `legs/2` refuses over a missing one.
  """
  @spec selection([module()], (String.t() -> String.t() | nil)) ::
          %{run: [String.t()], filtered: [String.t()]}
  def selection(harnesses, getenv \\ &System.get_env/1) do
    run = harnesses |> select(getenv) |> Enum.map(& &1.wire_name())
    %{run: run, filtered: Enum.map(harnesses, & &1.wire_name()) -- run}
  end

  # Registry order is preserved rather than the env's order, so the run sequence is a
  # property of the registry and cannot be permuted from outside.
  defp select(harnesses, getenv) do
    case getenv.(@legs_env) do
      nil ->
        harnesses

      value ->
        wanted =
          value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        registered = Enum.map(harnesses, & &1.wire_name())

        # An env var that is SET but names nothing selects nothing, and a run of zero legs
        # that exits 0 is the masquerade this filter exists to prevent. Unset it to mean
        # "everything"; setting it must always be a choice.
        if wanted == [] do
          raise ArgumentError,
                "#{@legs_env} names no legs; unset it to run every registered leg " <>
                  "(registered: #{Enum.join(registered, ", ")})"
        end

        case wanted -- registered do
          [] ->
            Enum.filter(harnesses, &(&1.wire_name() in wanted))

          unknown ->
            raise ArgumentError,
                  "#{@legs_env} names unregistered leg(s): #{Enum.join(unknown, ", ")} " <>
                    "(registered: #{Enum.join(registered, ", ")})"
        end
    end
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
