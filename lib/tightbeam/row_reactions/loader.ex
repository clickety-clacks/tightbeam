defmodule Tightbeam.RowReactions.Loader do
  @moduledoc false
  alias Tightbeam.RowReactions.{Plan, Reminder}

  def compile!(manifest, path, law_base, revision, bytes, owner \\ nil) do
    case rails!(manifest, path) do
      [] ->
        []

      rails ->
        relative = Path.relative_to(path, Path.join(law_base, "identity"))
        owner = owner || Tightbeam.Identity.Provenance.owner_for_path(law_base, relative)

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
    end
  end

  # `[[reminder]]` tables are read only while subtree rules are switched on.
  # Each becomes an ordinary reaction table before compilation. With the
  # switch off the key is left alone, so the caller treats it as it treats any
  # other unknown root key.
  defp rails!(manifest, path) do
    reactions =
      case Map.fetch(manifest, "reaction") do
        :error -> []
        {:ok, rails} when is_list(rails) and rails != [] -> rails
        _ -> raise ArgumentError, "#{path}: reaction must be a nonempty array of tables"
      end

    reminders =
      case {Tightbeam.SubtreeRules.enabled?(), Map.fetch(manifest, "reminder")} do
        {false, _} ->
          []

        {true, :error} ->
          []

        {true, {:ok, reminders}} when is_list(reminders) and reminders != [] ->
          Enum.map(reminders, fn reminder ->
            try do
              Reminder.to_reaction!(reminder)
            rescue
              error in ArgumentError ->
                reraise ArgumentError, "#{path}: #{Exception.message(error)}", __STACKTRACE__
            end
          end)

        {true, _} ->
          raise ArgumentError, "#{path}: reminder must be a nonempty array of tables"
      end

    reactions ++ reminders
  end
end
