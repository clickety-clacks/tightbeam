defmodule Tightbeam.RulePreflight do
  @moduledoc false

  alias Tightbeam.{Gateway, Rules}

  @doc false
  def run, do: run(System.fetch_env!("TIGHTBEAM_BASE_DIR"))

  @doc false
  def run(base_dir) when is_binary(base_dir) do
    config = %{base_dir: base_dir}
    verbs = config |> Gateway.handlers() |> Map.keys()

    Gateway.load_law!(config, verbs)

    diagnostics = Rules.status()

    %{
      complete: true,
      recording_available: diagnostics.recording_available,
      warnings:
        Enum.map(diagnostics.skipped_policies, & &1.message) ++
          Enum.map(diagnostics.unavailable_verbs, &unavailable_warning/1),
      unavailable_verbs: diagnostics.unavailable_verbs,
      skipped_policies: diagnostics.skipped_policies
    }
  end

  defp unavailable_warning(%{file: file, name: name, reason: reason, verb: verb}) do
    ~s(#{file}: rule "#{name}" makes verb "#{verb}" unavailable: #{reason})
  end
end
