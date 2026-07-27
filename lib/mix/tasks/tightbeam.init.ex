defmodule Mix.Tasks.Tightbeam.Init do
  use Mix.Task

  @shortdoc "Initialize the Tightbeam identity repository"

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [base_dir: :string], aliases: [])

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix tightbeam.init [--base-dir DIR]")
    end

    base_dir = options[:base_dir] || default_base_dir()

    case Tightbeam.Archetypes.init_identity!(base_dir) do
      :initialized -> Mix.shell().info("Initialized #{Path.join(base_dir, "identity")}")
      :noop -> Mix.shell().info("Identity repository already initialized")
    end
  end

  # One resolver, shared with the gateway and every other task. This read
  # TIGHTBEAM_HOME alone, so with TIGHTBEAM_BASE_DIR set it initialized a
  # DIFFERENT org than the one the service would boot -- and said "already
  # initialized" if something happened to be at the default path.
  defp default_base_dir, do: Tightbeam.BaseDir.resolve()
end
