defmodule Tightbeam.RulePreflight do
  @moduledoc false

  alias Tightbeam.{Archetypes, Gateway, Identity, Rails, RuleReferences, Rules}
  alias Tightbeam.Identity.RailScopeMigration

  @doc false
  def run do
    base_dir = System.fetch_env!("TIGHTBEAM_BASE_DIR")

    mode =
      case System.get_env("TIGHTBEAM_RULE_PREFLIGHT_DB") do
        nil ->
          :installed

        "" ->
          :pending_upgrade

        path ->
          if RailScopeMigration.pending_for_database!(path),
            do: :pending_upgrade,
            else: :installed
      end

    run(base_dir, mode)
  end

  @doc false
  def run(base_dir, mode \\ :installed) when is_binary(base_dir) do
    verbs = Map.keys(Gateway.handlers(%{base_dir: base_dir}))

    load = fn law_base, revision ->
      references =
        law_base
        |> Path.join("identity")
        |> RuleReferences.tree_entries!()
        |> RuleReferences.diagnostics()

      Archetypes.load!(law_base)
      Rails.load!(law_base)
      Rules.load!(base_dir, verbs, law_base: law_base, revision: revision, builtin_defaults: true)
      status = Rules.status()
      prefix = Path.join(law_base, "identity") <> "/"

      unavailable =
        Enum.map(status.unavailable_verbs, fn item ->
          %{item | reason: String.replace(item.reason, prefix, "")}
        end)

      {references, %{status | unavailable_verbs: unavailable}}
    end

    {references, diagnostics} =
      case mode do
        :installed ->
          Identity.with_recovery_law!(base_dir, load)

        :pending_upgrade ->
          {{converted, status}, legacy} = RailScopeMigration.with_preview!(base_dir, load)
          {Enum.uniq(converted ++ legacy), status}
      end

    %{
      complete: true,
      recording_available: diagnostics.recording_available and references == [],
      warnings:
        references ++
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
