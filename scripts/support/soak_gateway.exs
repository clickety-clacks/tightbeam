defmodule Tightbeam.Soak.GatewayProcess do
  @moduledoc false

  # Shared by the soak driver and its isolated process-boundary acceptance test.
  # This only launches a marked arena; credential preparation is NOT part of it.
  def open(base_dir, port_number, env, args \\ [~c"run", ~c"--no-halt"]) do
    base_dir = Path.expand(base_dir)

    unless File.regular?(Path.join(base_dir, ".soak-arena")) do
      raise "refusing gateway launch: #{base_dir} is not a marked soak arena"
    end

    mix = System.find_executable("mix") || raise "mix executable not found in PATH"

    arena_env = [
      {~c"TIGHTBEAM_BASE_DIR", String.to_charlist(base_dir)},
      {~c"TIGHTBEAM_PORT", Integer.to_charlist(port_number)},
      {~c"TIGHTBEAM_CWD", String.to_charlist(Path.join(base_dir, "work"))}
    ]

    # Arena bindings win over any caller defaults, including a live inherited base.
    env = Enum.reject(env, fn {key, _} -> List.keymember?(arena_env, key, 0) end)

    Port.open({:spawn_executable, String.to_charlist(mix)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args,
      cd: String.to_charlist(File.cwd!()),
      env: arena_env ++ env
    ])
  end
end
