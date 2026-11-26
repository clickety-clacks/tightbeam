defmodule Tightbeam.SubtreeRules do
  @moduledoc """
  The default-off switch for subtree rules: role-anchored scope, the `roles`
  filter, the new timed-engine facts and `contains`, and the `[[reminder]]`
  rule form. With it off, rule loading and evaluation are exactly as before.
  """

  @doc "True when subtree rules are switched on (`config :tightbeam, :subtree_rules`)."
  def enabled?, do: Application.get_env(:tightbeam, :subtree_rules, false) == true
end
