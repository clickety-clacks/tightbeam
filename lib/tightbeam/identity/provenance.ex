defmodule Tightbeam.Identity.Provenance do
  @moduledoc """
  Resolves the source of an identity item from the learned kungfu receipts.

  Item paths are relative to the identity directory in a receipt. Callers may
  pass the same path relative to the gateway base, prefixed by `identity/`.
  """

  @type owner :: :substrate | {:kungfu, String.t()}

  @doc "Return the receipt owner of an identity item, or `:substrate`."
  @spec owner_for_path(String.t(), String.t()) :: owner()
  def owner_for_path(base_dir, relative_path)
      when is_binary(base_dir) and is_binary(relative_path) do
    path = identity_relative_path!(relative_path)

    case owners_by_path(base_dir) |> Map.get(path, []) do
      [] ->
        :substrate

      [name] ->
        {:kungfu, name}

      names ->
        raise ArgumentError,
              "identity path #{path} is claimed by multiple kungfu receipts: #{Enum.join(names, ", ")}"
    end
  end

  def owner_for_path(_base_dir, _relative_path),
    do: raise(ArgumentError, "identity base directory and relative path must be strings")

  @doc false
  @spec owner_for_path_at_revision(String.t(), String.t(), String.t()) :: owner()
  def owner_for_path_at_revision(base_dir, relative_path, revision)
      when is_binary(base_dir) and is_binary(relative_path) and is_binary(revision) do
    identity_dir = identity_dir(base_dir)
    path = identity_relative_path!(relative_path)

    receipt_paths_at_revision(identity_dir, revision)
    |> Enum.reduce(%{}, fn {_receipt_path, receipt}, owners ->
      if Enum.any?(receipt.paths, &(identity_relative_path!(&1) == path)) do
        Map.update(owners, path, [receipt.name], &[receipt.name | &1])
      else
        owners
      end
    end)
    |> Map.get(path, [])
    |> Enum.uniq()
    |> Enum.sort()
    |> owner_result(path)
  end

  @doc false
  @spec receipts(String.t()) :: [%{name: String.t(), path: String.t(), paths: [String.t()]}]
  def receipts(base_dir) when is_binary(base_dir) do
    base_dir
    |> identity_dir()
    |> Path.join("kungfu/*/installed.toml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      bytes = File.read!(path)
      parse_receipt!(bytes, Path.relative_to(path, identity_dir(base_dir)))
    end)
  end

  @doc false
  @spec archetype_names(String.t(), String.t()) :: [String.t()]
  def archetype_names(base_dir, kungfu_name)
      when is_binary(base_dir) and is_binary(kungfu_name) do
    base_dir
    |> receipts()
    |> Enum.find_value([], fn receipt ->
      if receipt.name == kungfu_name do
        receipt.paths
        |> Enum.flat_map(&archetype_name_from_path(&1, kungfu_name))
        |> Enum.uniq()
        |> Enum.sort()
      end
    end)
  end

  @doc false
  def qualify(:substrate, short_name) when is_binary(short_name), do: short_name

  def qualify({:kungfu, name}, short_name) when is_binary(name) and is_binary(short_name),
    do: name <> "." <> short_name

  def qualify(_owner, short_name) when is_binary(short_name), do: short_name

  defp owners_by_path(base_dir) do
    base_dir
    |> receipts()
    |> Enum.reduce(%{}, fn receipt, owners ->
      Enum.reduce(receipt.paths, owners, fn path, owners ->
        normalized = identity_relative_path!(path)
        Map.update(owners, normalized, [receipt.name], &[receipt.name | &1])
      end)
    end)
    |> Map.new(fn {path, names} -> {path, names |> Enum.uniq() |> Enum.sort()} end)
  end

  defp receipt_paths_at_revision(identity_dir, revision) do
    case System.cmd(
           "git",
           ["ls-tree", "-r", "--name-only", revision, "--", "kungfu"],
           cd: identity_dir,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.ends_with?(&1, "/installed.toml"))
        |> Enum.sort()
        |> Enum.map(fn path ->
          case System.cmd("git", ["show", "#{revision}:#{path}"],
                 cd: identity_dir,
                 stderr_to_stdout: true
               ) do
            {bytes, 0} -> {path, parse_receipt!(bytes, path)}
            {error, status} -> raise "could not read #{path} at #{revision} (#{status}): #{error}"
          end
        end)

      {output, status} ->
        raise "could not read identity receipts at #{revision} (#{status}): #{output}"
    end
  end

  defp identity_dir(base_dir) do
    if Path.basename(Path.expand(base_dir)) == "identity" do
      Path.expand(base_dir)
    else
      Path.join(base_dir, "identity")
    end
  end

  defp identity_relative_path!(path) do
    path = String.replace(path, "\\", "/")
    parts = Path.split(path)

    parts =
      case parts do
        ["identity" | rest] -> rest
        _ -> parts
      end

    Path.join(parts)
  end

  @doc false
  def parse_receipt!(bytes, path) do
    receipt = Toml.decode!(bytes)
    name = Map.fetch!(receipt, "name")
    paths = Map.fetch!(receipt, "paths")

    unless is_binary(name) and name != "" and is_list(paths) and Enum.all?(paths, &is_binary/1) do
      raise ArgumentError, "#{path}: invalid kungfu receipt"
    end

    %{name: name, paths: paths, path: path}
  rescue
    error -> raise ArgumentError, "#{path}: invalid kungfu receipt: #{Exception.message(error)}"
  end

  defp archetype_name_from_path(path, kungfu_name) do
    name =
      case identity_relative_path!(path) |> Path.split() do
        ["archetypes", file] -> file
        ["kungfu", ^kungfu_name, "archetypes", file] -> file
        _ -> nil
      end

    if is_binary(name) and String.ends_with?(name, ".toml"),
      do: [Path.rootname(name)],
      else: []
  end

  defp owner_result([], _path), do: :substrate
  defp owner_result([name], _path), do: {:kungfu, name}

  defp owner_result(names, path) do
    raise ArgumentError,
          "identity path #{path} is claimed by multiple kungfu receipts: #{Enum.join(names, ", ")}"
  end
end
