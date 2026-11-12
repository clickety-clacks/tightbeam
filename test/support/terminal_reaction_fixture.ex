defmodule Tightbeam.TerminalReactionFixture do
  @moduledoc false

  def load!(root, verbs) do
    law = Path.join(root, "terminal-law")
    rules = Path.join(law, "identity/rules")
    File.mkdir_p!(rules)

    seed = Path.expand("../../priv/seed/rules/substrate.toml", __DIR__)
    File.cp!(seed, Path.join(rules, "substrate.toml"))

    for name <- ~w(row-reaction-handoff.toml row-reaction-terminal-action.toml assignment-labels.toml row-reaction-assignment-inactivity.toml) do
      source = Path.join([:code.priv_dir(:tightbeam), "kungfu/agentic-engineering/rules", name])
      File.cp!(source, Path.join(rules, name))
    end

    Tightbeam.Rules.load!(law, verbs)
    law
  end

  def attest_placement do
    [_, section] =
      String.split(verification_source(), "# Attest placement and citation checks\n", parts: 2)

    [placement, _] = String.split(section, "# Ruling receipt checks\n", parts: 2)
    placement
  end

  def ruling_receipts do
    [_, receipts] = String.split(verification_source(), "# Ruling receipt checks\n", parts: 2)
    receipts
  end

  defp verification_source do
    File.read!(
      Path.join([:code.priv_dir(:tightbeam), "kungfu/agentic-engineering/rules", "verification.toml"])
    )
  end
end
