defmodule Tightbeam.TerminalReactionFixture do
  @moduledoc false

  def load!(root, verbs) do
    law = Path.join(root, "terminal-law")
    rules = Path.join(law, "identity/rules")
    File.mkdir_p!(rules)

    for name <- ~w(row-reaction-handoff.toml row-reaction-terminal-action.toml) do
      source = Path.join([:code.priv_dir(:tightbeam), "kungfu/agentic-engineering/rules", name])
      File.cp!(source, Path.join(rules, name))
    end

    Tightbeam.Rules.load!(law, verbs)
    law
  end
end
