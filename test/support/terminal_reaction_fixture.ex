defmodule Tightbeam.TerminalReactionFixture do
  @moduledoc false

  def load_work_items!(root, verbs) do
    rules = Path.join(root, "identity/rules")
    File.mkdir_p!(rules)

    contents =
      File.read!(
        Path.join(
          :code.priv_dir(:tightbeam),
          "kungfu/agentic-engineering/rules/row-reaction-work-items.toml"
        )
      )

    contents = String.replace(contents, ~r/^archetypes = .*$/m, "archetypes = [\"*\"]")
    File.write!(Path.join(rules, "row-reaction-work-items.toml"), contents)
    Tightbeam.Rules.load!(root, verbs)
    root
  end

  def load!(root, verbs) do
    law = Path.join(root, "terminal-law")
    rules = Path.join(law, "identity/rules")
    File.mkdir_p!(rules)

    rule_sources = [
      {"row-reaction-work-items.toml", "kungfu/agentic-engineering/rules"},
      {"row-reaction-attest-notice.toml", "kungfu/agentic-engineering/rules"},
      {"row-reaction-handoff.toml", "seed/rules"},
      {"row-reaction-terminal-action.toml", "seed/rules"}
    ]

    for {name, directory} <- rule_sources do
      source = Path.join([:code.priv_dir(:tightbeam), directory, name])
      contents = File.read!(source)

      contents =
        if name in ["row-reaction-attest-notice.toml", "row-reaction-work-items.toml"] do
          # Synthetic sessions use the default archetype; production lists its bundle roles.
          contents
          |> String.replace(~r/^archetypes = .*\n/m, "")
          |> String.replace(
            "[[reaction]]\n",
            "[[reaction]]\narchetypes = [\"*\"]\n",
            global: true
          )
        else
          contents
        end

      File.write!(Path.join(rules, name), contents)
    end

    Tightbeam.Rules.load!(law, verbs)
    law
  end
end
