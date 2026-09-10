defmodule Tightbeam.Soak.GatewayProcess do
  @moduledoc false

  # Planning reads metadata only and happens before an old arena is removed.
  # The caller must supply an explicit, authorized same-machine template base.
  def home_plan!(arena, source_base, machine) do
    unless is_binary(machine) and machine not in ["", ".", ".."] and
             Path.basename(machine) == machine do
      raise "refusing invalid soak machine name"
    end

    arena = Path.expand(arena)
    source_base = Path.expand(source_base)

    if arena == source_base or String.starts_with?(arena, source_base <> "/") or
         String.starts_with?(source_base, arena <> "/") do
      raise "refusing overlapping soak source and arena"
    end

    home = Tightbeam.Homes.home_path(source_base, machine, :claude)
    regular_ancestors!(home)
    regular_tree!(home)

    for leaf <- [".credentials.json", ".tightbeam/credential.json"] do
      unless match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(home, leaf))) do
        raise "refusing soak home without regular #{leaf}: #{home}"
      end
    end

    %{source_base: source_base, machine: machine, home: home, arena: arena}
  end

  def seed_home!(arena, plan) do
    plan = home_plan!(arena, plan.source_base, plan.machine)

    unless match?(
             {:ok, %File.Stat{type: :regular}},
             File.lstat(Path.join(plan.arena, ".soak-arena"))
           ) do
      raise "refusing unmarked soak arena"
    end

    target = Tightbeam.Homes.home_path(plan.arena, plan.machine, :claude)
    unless File.lstat(target) == {:error, :enoent}, do: raise("soak target home exists")
    regular_ancestors!(plan.arena)
    File.mkdir_p!(Path.dirname(target))
    File.cp_r!(plan.home, target)

    adapters = Path.join(plan.source_base, "adapters")

    case File.lstat(adapters) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        File.cp_r!(adapters, Path.join(plan.arena, "adapters"))

      _ ->
        raise "refusing non-directory adapter template"
    end

    :ok
  end

  defp regular_ancestors!(path) do
    path
    |> Path.split()
    |> Enum.reduce(nil, fn part, parent ->
      current = if is_nil(parent), do: part, else: Path.join(parent, part)

      unless match?({:ok, %File.Stat{type: :directory}}, File.lstat(current)) do
        raise "refusing missing or linked soak directory: #{current}"
      end

      current
    end)
  end

  defp regular_tree!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        for child <- File.ls!(path), do: regular_tree!(Path.join(path, child))

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      _ ->
        raise "refusing linked or special soak home entry: #{path}"
    end
  end

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
