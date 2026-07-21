defmodule Tightbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :tightbeam,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Tightbeam",
      docs: [main: "Tightbeam", extras: ["docs/ARCHITECTURE.md", "docs/HANDOFF.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Tightbeam.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.27"},
      # Wire front: Bandit serves Plug (HTTP control plane) + WebSock (Clawline WS).
      {:bandit, "~> 1.5"},
      {:websock_adapter, "~> 0.5"},
      # Archetype manifests are TOML (spec §Agent identity; rails will share the format).
      {:toml, "~> 0.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
