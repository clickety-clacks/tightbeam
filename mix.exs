defmodule Tightbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :tightbeam,
      version: cli_version(),
      elixir: "~> 1.19",
      compilers: [:live_base_lock, :topline_unicode] ++ Mix.compilers(),
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

defmodule Mix.Tasks.Compile.ToplineUnicode do
  @moduledoc false
  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(_args) do
    root = File.cwd!()
    manifest = Path.join(root, "native/topline_unicode/Cargo.toml")
    target = Path.join(root, "priv/#{target_name()}")

    if current?(root, target) do
      {:noop, []}
    else
      build(root, manifest, target)
    end
  end

  defp build(root, manifest, target) do
    cargo = System.find_executable("cargo") || Mix.raise("cargo is required to build Toplines")

    {output, status} =
      System.cmd(
        cargo,
        ["build", "--locked", "--release", "--manifest-path", manifest],
        cd: root,
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("Toplines Unicode extension build failed:\n#{output}")

    source = Path.join(root, "native/topline_unicode/target/release/#{source_name()}")
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
    {:ok, []}
  end

  defp current?(root, target) do
    with {:ok, target_stat} <- File.stat(target, time: :posix) do
      sources =
        [
          Path.join(root, "native/topline_unicode/Cargo.toml"),
          Path.join(root, "native/topline_unicode/Cargo.lock")
          | Path.wildcard(Path.join(root, "native/topline_unicode/src/**/*.rs"))
        ]

      Enum.all?(sources, fn source ->
        {:ok, source_stat} = File.stat(source, time: :posix)
        source_stat.mtime <= target_stat.mtime
      end)
    else
      _ -> false
    end
  end

  defp source_name do
    case :os.type() do
      {:unix, :darwin} -> "libtopline_unicode.dylib"
      {:unix, _} -> "libtopline_unicode.so"
      other -> Mix.raise("Toplines Unicode extension does not support #{inspect(other)}")
    end
  end

  defp target_name do
    case :os.type() do
      {:unix, :darwin} -> "topline_unicode.dylib"
      {:unix, _} -> "topline_unicode.so"
      other -> Mix.raise("Toplines Unicode extension does not support #{inspect(other)}")
    end
  end
end

defmodule Mix.Tasks.Compile.LiveBaseLock do
  use Mix.Task.Compiler
  @impl true
  def run(_args) do
    unless :os.type() in [{:unix, :linux}, {:unix, :darwin}],
      do: Mix.raise("live base lock requires Linux or macOS")

    source = Path.expand("native/live_base_lock.c")
    target = Path.expand("priv/live_base_lock.so")
    include = Path.join([List.to_string(:code.root_dir()), "usr", "include"])
    cc = System.find_executable("cc") || Mix.raise("C compiler required for live base lock")
    flags = if :os.type() == {:unix, :darwin}, do: ["-undefined", "dynamic_lookup"], else: []
    File.mkdir_p!(Path.dirname(target))
    # Never truncate a library mapped by another VM. Publish a complete inode.
    temporary = target <> ".build-" <> Integer.to_string(System.unique_integer([:positive]))

    {output, status} =
      System.cmd(
        cc,
        [
          "-std=c11",
          "-D_GNU_SOURCE",
          "-Wall",
          "-Wextra",
          "-Werror",
          "-fPIC",
          "-shared",
          "-I",
          include,
          "-I",
          Path.expand("deps/exqlite/c_src"),
          source,
          "-o",
          temporary
        ] ++ flags,
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("live base lock build failed: #{output}")
    File.rename!(temporary, target)
    {:ok, []}
  end
end
