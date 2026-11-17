defmodule Tightbeam.RowReactions.Loader do
  @moduledoc false
  alias Tightbeam.RowReactions.Plan

  def compile!(manifest, path, law_base, revision, bytes) do
    case Map.fetch(manifest, "reaction") do
      :error ->
        []

      {:ok, rails} when is_list(rails) and rails != [] ->
        relative = Path.relative_to(path, Path.join(law_base, "identity"))
        owner = Tightbeam.Identity.Provenance.owner_for_path(law_base, relative)

        provenance = %{
          "source" => relative,
          "bundle" =>
            case owner do
              {:kungfu, name} -> name
              :substrate -> "substrate"
            end,
          "revision" => revision,
          "content_sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }

        owned_archetypes =
          case owner do
            {:kungfu, name} -> Tightbeam.Identity.Provenance.archetype_names(law_base, name)
            :substrate -> []
          end

        Enum.map(rails, fn rail ->
          {:reaction,
           Map.put(Plan.compile!(rail, provenance, owner, owned_archetypes), :source, path)}
        end)

      _ ->
        raise ArgumentError, "#{path}: reaction must be a nonempty array of tables"
    end
  end
end
