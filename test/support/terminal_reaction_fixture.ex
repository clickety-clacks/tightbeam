defmodule Tightbeam.TerminalReactionFixture do
  @moduledoc false

  def load!(root, verbs) do
    law = Path.join(root, "terminal-law")
    rules = Path.join(law, "identity/rules")
    File.mkdir_p!(rules)

    rule_sources = [
      {"row-reaction-attest-notice.toml", "kungfu/agentic-engineering/rules"},
      {"row-reaction-handoff.toml", "seed/rules"},
      {"row-reaction-terminal-action.toml", "seed/rules"}
    ]

    for {name, directory} <- rule_sources do
      source = Path.join([:code.priv_dir(:tightbeam), directory, name])
      File.cp!(source, Path.join(rules, name))
    end

    Tightbeam.Rules.load!(law, verbs)
    law
  end
end
