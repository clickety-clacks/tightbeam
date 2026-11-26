defmodule Tightbeam.FeatureFlags do
  @moduledoc """
  Default-off feature flags, read at each use so a test or an operator can
  change them without a restart. The register is `docs/feature-flags.md`.
  """

  @doc """
  Whether subtree rules are enabled: role-anchored rule scope, the `roles`
  filter, and the facts, operator and reminder form built on them.

  Configured as `config :tightbeam, :subtree_rules, true`, or with
  `TIGHTBEAM_SUBTREE_RULES=true` for a packaged gateway. Off by default; while
  it is off, rule loading, evaluation and stored data are exactly as before.
  """
  @spec subtree_rules?() :: boolean()
  def subtree_rules?, do: Application.get_env(:tightbeam, :subtree_rules, false) == true
end
