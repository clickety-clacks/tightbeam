defmodule Tightbeam.FeatureSmokeHome do
  @moduledoc """
  Required projection checks for the feature smoke's active, shared harness HOME.

  Other HOME entries may be written independently by the harness. A whole-HOME
  before/after difference cannot attribute those writes to deployment. The strict
  projection write-set and durable-state checks live in the isolated projection
  fixture tests, where reconciliation is the only writer.
  """

  def verify_owned!(home, harness) do
    for relative <- Tightbeam.Homes.owned_entries(harness) do
      path = Path.join(home, relative)

      # Like the smoke's leaf inventory, do not follow baseline skill symlinks.
      # A directory at a required leaf is not a delivered projection file.
      unless owned_leaf?(home, Path.split(relative)),
        do: raise("local deployment HOME missing owned path: #{path}")
    end

    :ok
  end

  defp owned_leaf?(parent, [leaf]) do
    case File.lstat(Path.join(parent, leaf)) do
      {:ok, %{type: type}} when type in [:regular, :symlink] -> true
      _ -> false
    end
  end

  defp owned_leaf?(parent, [directory | rest]) do
    path = Path.join(parent, directory)

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> owned_leaf?(path, rest)
      _ -> false
    end
  end
end
