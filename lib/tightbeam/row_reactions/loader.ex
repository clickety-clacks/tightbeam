defmodule Tightbeam.RowReactions.Loader do
  @moduledoc false
  alias Tightbeam.RowReactions.Plan

  def compile!(manifest, path, law_base, revision, bytes) do
    case Map.fetch(manifest, "reaction") do
      :error ->
        []

      {:ok, rails} when is_list(rails) and rails != [] ->
        provenance = %{
          "source" => Path.relative_to(path, Path.join(law_base, "identity")),
          "bundle" => bundle!(path, law_base),
          "revision" => revision,
          "content_sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }

        Enum.map(rails, fn rail ->
          {:reaction, Map.put(Plan.compile!(rail, provenance), :source, path)}
        end)

      _ ->
        raise ArgumentError, "#{path}: reaction must be a nonempty array of tables"
    end
  end

  defp bundle!(path, law_base) do
    relative = Path.relative_to(path, Path.join(law_base, "identity"))

    owners =
      Path.wildcard(Path.join(law_base, "identity/kungfu/*/installed.toml"))
      |> Enum.flat_map(fn receipt_path ->
        receipt = receipt_path |> File.read!() |> Toml.decode!()
        if relative in Map.fetch!(receipt, "paths"), do: [Map.fetch!(receipt, "name")], else: []
      end)

    case owners do
      [] -> "seed"
      [owner] -> owner
      _ -> raise ArgumentError, "#{path}: multiple bundle receipts claim this rule"
    end
  end
end
