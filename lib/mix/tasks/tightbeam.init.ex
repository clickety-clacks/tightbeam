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

  defp default_base_dir do
    System.get_env("TIGHTBEAM_HOME") || Path.join(System.user_home!(), ".tightbeam")
  end
end
