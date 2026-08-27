defmodule Tightbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :tightbeam,
      version: cli_version(),
      elixir: "~> 1.19",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Tightbeam",
      docs: [main: "Tightbeam", extras: ["docs/ARCHITECTURE.md", "docs/HANDOFF.md"]],
      releases: releases()
    ]
  end

  # The npm-installable gateway (Flynn rulings 2026-08-03: one package carrying CLI and
  # gateway so the version handshake holds by construction; mix release bundled
  # per-platform; no registry until a real release).
  #
  # INSTALLS ARE FROM A BUILT TARBALL, NOT FROM THE GIT URL. `packaging/package.json` is
  # a template that `packaging/assemble.sh` stamps with the version and platform; there
  # is deliberately no manifest at the repository root, so `npm install <git-url>` has
  # nothing to install and would fail. The package cannot come from a checkout anyway:
  # it carries a compiled ERTS and a compiled CLI, so it is built per platform and
  # shipped as the one file. README documents that path and only that path.
  # `include_executables_for: [:unix]` and bundled ERTS: `npm install` must yield a
  # working install with NO Elixir toolchain on the host — that is the entire point.
  defp releases do
    [
      tightbeam_gateway: [
        include_erts: true,
        include_executables_for: [:unix],
        strip_beams: true
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :inets],
      mod: {Tightbeam.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp cli_version do
    manifest = File.read!(Path.join(__DIR__, "cli/Cargo.toml"))
    [version] = Regex.run(~r/^version\s*=\s*"([^"]+)"$/m, manifest, capture: :all_but_first)
    version
  end

  defp deps do
    [
      {:exqlite, "~> 0.27"},
      {:elixir_make, "~> 0.10", runtime: false},
      # Wire front: Bandit serves Plug (HTTP control plane) + WebSock (Clawline WS).
      # The floor is the advisory boundary, stated as the advisory states it:
      # EEF-CVE-2026-65623 / GHSA-vg8x-66vg-5pxh affects >= 1.11.0 and < 1.12.1.
      {:bandit, ">= 1.12.1 and < 2.0.0"},
      {:websock_adapter, "~> 0.5"},
      # Archetype manifests are TOML (spec §Agent identity; rails will share the format).
      {:toml, "~> 0.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
