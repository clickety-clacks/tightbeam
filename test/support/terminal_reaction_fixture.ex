defmodule Tightbeam.TerminalReactionFixture do
  @moduledoc false

  def load_work_items!(root, verbs, wildcard \\ true) do
    rules = Path.join(root, "identity/rules")
    File.mkdir_p!(rules)

    contents =
      File.read!(
        Path.join(
          :code.priv_dir(:tightbeam),
          "seed/rules/row-reaction-work-items.toml"
        )
      )

    contents =
      if wildcard,
        do: String.replace(contents, ~r/^archetypes = .*$/m, "archetypes = [\"*\"]"),
        else: contents

    File.write!(Path.join(rules, "row-reaction-work-items.toml"), contents)
    Tightbeam.Rules.load!(root, verbs)
    root
  end

  def load!(root, verbs) do
    law = Path.join(root, "terminal-law")
    rules = Path.join(law, "identity/rules")
    File.mkdir_p!(rules)

    # The attest notice and the 2-hour reminder are no longer shipped; orgs
    # that keep them still run them, so their fixture copies stay covered.
    rule_sources = [
      {"row-reaction-work-items.toml", Path.join(:code.priv_dir(:tightbeam), "seed/rules")},
      {"row-reaction-attest-notice.toml",
       Path.expand("fixtures/kungfu/agentic-engineering/rules", __DIR__)},
      {"row-reaction-handoff.toml", Path.join(:code.priv_dir(:tightbeam), "seed/rules")},
      {"row-reaction-terminal-action.toml", Path.expand("fixtures/rules", __DIR__)}
    ]

    for {name, directory} <- rule_sources do
      source = Path.join(directory, name)
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
