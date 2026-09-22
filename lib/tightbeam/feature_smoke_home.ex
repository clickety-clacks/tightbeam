defmodule Tightbeam.FeatureSmokeHome do
  @moduledoc false

  def new_strays(before_entries, after_entries, owned_entries, harness) do
    module = Tightbeam.Harness.module!(harness)

    after_entries
    |> MapSet.difference(before_entries)
    |> MapSet.difference(owned_entries)
    |> Enum.reject(&module.native_home_entry?/1)
  end

  # A live runtime may remove a listed lock before stat/readdir. Only ENOENT
  # represents a vanished entry; permission and other IO failures remain fatal.
  # Keep symlinks as leaves and never follow credential links.
  def leaf_entries(root, opts \\ []) do
    lstat = Keyword.get(opts, :lstat, &File.lstat/1)
    walk(root, root, File.ls!(root), lstat)
  end

  defp walk(path, root, names, lstat) do
    Enum.flat_map(names, fn name ->
      child = Path.join(path, name)
      relative = Path.relative_to(child, root)

      case lstat.(child) do
        {:error, :enoent} ->
          []

        {:error, reason} ->
          raise File.Error, reason: reason, action: "stat", path: child

        {:ok, %{type: :directory}} ->
          case File.ls(child) do
            {:ok, []} ->
              [relative <> "/"]

            {:ok, children} ->
              walk(child, root, children, lstat)

            {:error, :enoent} ->
              []

            {:error, reason} ->
              raise File.Error, reason: reason, action: "list directory", path: child
          end

        {:ok, _} ->
          [relative]
      end
    end)
  end
end
