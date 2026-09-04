defmodule Tightbeam.ProductionIdentityEnv do
  @moduledoc false
  # The production-identity environment variable set — ERTS paths, release
  # identity, and instance selectors that name a specific running gateway.
  #
  # Single source of truth: scripts/production-identity-env (see that file). It
  # is parsed HERE at compile time and by scripts/verify_mix.sh at run time, so
  # the R3 spawn scrub, the R9 overlay reservation, and the source-test scrub
  # cannot drift on what "production identity" means.
  #
  # Session vars (TIGHTBEAM_HOME/MACHINE/LINEAGE/URL) are deliberately absent:
  # they are per-session and re-provided to children, never a production leak.

  @fragment Path.expand("../../scripts/production-identity-env", __DIR__)
  @external_resource @fragment

  {prefixes, exact} =
    @fragment
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == "" or String.starts_with?(String.trim_leading(&1), "#")))
    |> Enum.reduce({[], []}, fn line, {prefixes, exact} ->
      case String.split(line, ~r/\s+/, trim: true) do
        ["prefix", value] -> {[value | prefixes], exact}
        ["exact", value] -> {prefixes, [value | exact]}
        other -> raise "malformed production-identity-env entry: #{inspect(other)}"
      end
    end)

  @prefixes Enum.reverse(prefixes)
  @exact Enum.reverse(exact)

  @doc "Var-name prefixes in the production-identity set (e.g. \"RELEASE_\")."
  @spec prefixes() :: [String.t()]
  def prefixes, do: @prefixes

  @doc "Exact var names in the production-identity set."
  @spec exact() :: [String.t()]
  def exact, do: @exact

  @doc "True when `name` is a production-identity variable (exact or prefix match)."
  @spec production_identity?(String.t()) :: boolean()
  def production_identity?(name) when is_binary(name) do
    name in @exact or Enum.any?(@prefixes, &String.starts_with?(name, &1))
  end
end
