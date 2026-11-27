defmodule Tightbeam.RuleReferences do
  @moduledoc false

  alias Tightbeam.{Archetypes, Gateway, Mementos, Rules}
  alias Tightbeam.Identity.Provenance
  alias Tightbeam.RowReactions.{Expression, Snapshot}

  require Logger

  @doc false
  def source_path?(path) do
    Rules.rule_file_path?(path) or
      case Path.split(path) do
        ["archetypes", file] -> Path.extname(file) == ".toml"
        ["kungfu", _, "archetypes", file] -> Path.extname(file) == ".toml"
        ["kungfu", _, file] -> file in ["manifest.toml", "installed.toml"]
        _ -> false
      end
  end

  def tree_entries!(dir) do
    for glob <- [
          "archetypes/*.toml",
          "rules/*.toml",
          "kungfu/*/*.toml",
          "kungfu/*/{archetypes,rules}/*.toml"
        ],
        path <- Path.wildcard(Path.join(dir, glob)),
        relative = Path.relative_to(path, dir),
        source_path?(relative),
        into: %{},
        do: {relative, File.read!(path)}
  end

  def validate_publication!(candidate, prior) do
    current = diagnostics(candidate)
    existing = MapSet.new(diagnostics(prior))
    {carried, introduced} = Enum.split_with(current, &MapSet.member?(existing, &1))

    Enum.each(carried, &Logger.warning("Existing invalid rule reference: #{&1}"))

    case introduced do
      [] -> :ok
      errors -> raise ArgumentError, Enum.join(errors, "\n")
    end
  end

  def warn!(dir), do: warn_diagnostics(fn -> dir |> tree_entries!() |> diagnostics() end)

  def warn_entries!(entries), do: warn_diagnostics(fn -> diagnostics(entries) end)

  def warn_legacy!(entries), do: warn_diagnostics(fn -> legacy_archetype_diagnostics(entries) end)

  defp warn_diagnostics(diagnostics) do
    Enum.each(diagnostics.(), &Logger.warning("Invalid rule reference: #{&1}"))
  rescue
    error ->
      Logger.warning("Rule reference check could not complete: #{Exception.message(error)}")
  end

  def diagnostics(entries) do
    rules = rule_files(entries)

    if rules == [] do
      []
    else
      catalog = catalog(entries)
      declarations = Mementos.declarations_from_manifests(manifests(entries), nil)

      Mementos.with_declarations(declarations, fn ->
        malformed_archetype_diagnostics(entries) ++
          Enum.flat_map(rules, fn {path, bytes} ->
            file_diagnostics(path, bytes, catalog, &references/1)
          end)
      end)
    end
  end

  # Conversion can remove a comparison against an out-of-scope archetype.
  # Distinguish real legacy names from dangling ones even when both were removed.
  def legacy_archetype_diagnostics(entries) do
    catalog = %{archetype: archetype_names(entries, true)}

    entries
    |> rule_files()
    |> Enum.flat_map(fn {path, bytes} ->
      file_diagnostics(
        path,
        bytes,
        catalog,
        fn entry ->
          entry
          |> conditions()
          |> Enum.flat_map(&condition_references/1)
          |> Enum.filter(fn {kind, _} -> kind == :archetype end)
        end,
        false
      )
    end)
  end

  defp rule_files(entries) do
    entries
    |> Enum.filter(fn {path, _} -> Rules.rule_file_path?(path) end)
    |> Enum.sort()
  end

  defp catalog(entries) do
    %{
      archetype: archetype_names(entries, false),
      kungfu: MapSet.new(manifests(entries), fn {path, _} -> bundle(path) end),
      verb: MapSet.new(Map.keys(Gateway.handlers(%{})))
    }
  end

  defp archetype_names(entries, legacy?) do
    owners =
      for {path, bytes} <- entries,
          match?(["kungfu", _, "installed.toml"], Path.split(path)),
          receipt = Provenance.parse_receipt!(bytes, path),
          claim <- receipt.paths,
          reduce: %{} do
        owners ->
          claim = String.replace_prefix(claim, "identity/", "")
          Map.update(owners, claim, [{:kungfu, receipt.name}], &[{:kungfu, receipt.name} | &1])
      end

    for {path, bytes} <- entries,
        archetype_path?(path),
        owner <- Map.get(owners, path, [:substrate]),
        {:ok, manifest} <- [Toml.decode(bytes)],
        name = Archetypes.manifest_name(manifest, path),
        is_binary(name),
        qualified = Provenance.qualify(owner, name),
        reference <- if(legacy?, do: [name, qualified], else: [qualified]),
        into: MapSet.new(["default"]),
        do: reference
  end

  defp malformed_archetype_diagnostics(entries) do
    for {path, bytes} <- Enum.sort(entries),
        archetype_path?(path),
        {:error, reason} <- [Toml.decode(bytes)],
        do: "#{path}: invalid archetype TOML: #{inspect(reason)}"
  end

  defp manifests(entries) do
    entries
    |> Enum.filter(fn {path, _} -> match?(["kungfu", _, "manifest.toml"], Path.split(path)) end)
    |> Enum.sort()
  end

  defp archetype_path?(path) do
    match?(["archetypes", _], Path.split(path)) or
      match?(["kungfu", _, "archetypes", _], Path.split(path))
  end

  defp bundle(path), do: path |> Path.dirname() |> Path.basename()

  defp file_diagnostics(path, bytes, catalog, references, reactions? \\ true) do
    case Toml.decode(bytes) do
      {:ok, manifest} ->
        for kind <- ["rule", "policy", "reaction"],
            {entry, index} <- Enum.with_index(List.wrap(manifest[kind]), 1),
            is_map(entry),
            not (kind == "policy" and Rules.retired_policy?(entry)),
            {type, name} <-
              Enum.uniq(
                references.(entry) ++
                  if(reactions?, do: reaction_references(kind, entry), else: [])
              ),
            missing?(catalog, type, name),
            do:
              "#{path}: #{kind} #{inspect(entry["name"] || index)}: unknown #{reference_label(type)} #{inspect(name)}"

      {:error, reason} ->
        ["#{path}: cannot check rule references in invalid TOML: #{inspect(reason)}"]
    end
  end

  defp reaction_references("reaction", entry) do
    expressions = [entry["when"], entry["bind"], entry["effects"]]

    archetypes =
      expressions
      |> Expression.archetype_comparisons()
      |> Enum.flat_map(fn {_fact, _op, value} -> archetype_references(List.wrap(value)) end)

    facts = Enum.map(Expression.fact_references(expressions), &{:reaction_fact, &1})
    archetypes ++ facts
  end

  defp reaction_references(_kind, _entry), do: []

  defp conditions(entry) do
    recurrence = entry["recurrence_suppression"]

    rearm =
      if is_map(recurrence) and is_map(recurrence["rearm"]), do: recurrence["rearm"], else: %{}

    Enum.flat_map(
      [entry["deny_when"], entry["when"], rearm["recovered_when"], rearm["recurred_when"]],
      &List.wrap/1
    )
  end

  defp references(entry) do
    remedy = if is_map(entry["remedy"]), do: entry["remedy"], else: %{}
    verbs = List.wrap(entry["verb"]) ++ List.wrap(entry["verbs"]) ++ List.wrap(remedy["action"])
    scope = Enum.reject(List.wrap(entry["archetypes"]), &(&1 == "*"))

    spawned =
      for name <- List.wrap(remedy["archetype"]),
          is_binary(name),
          not String.starts_with?(name, "{"),
          do: name

    named(:verb, verbs) ++
      archetype_references(scope ++ spawned) ++
      memento_references(entry["evidence_memento"]) ++
      Enum.flat_map(conditions(entry), &condition_references/1)
  end

  defp condition_references(%{"fact" => fact} = condition) when is_binary(fact) do
    archetypes =
      if Rules.archetype_fact?(fact),
        do: archetype_references(List.wrap(condition["value"])),
        else: []

    [{:fact, fact} | fact_kungfu_references(fact) ++ archetypes]
  end

  defp condition_references(_), do: []

  defp fact_kungfu_references(fact) do
    case Regex.run(
           ~r/\.(?:memento|has_memento|memento_matches_call|memento_contains_comparison_value)\.([^\/]+)\//,
           fact
         ) do
      [_, bundle] -> [{:kungfu, bundle}]
      nil -> []
    end
  end

  defp memento_references(name) when is_binary(name) do
    case String.split(name, "/", parts: 2) do
      [bundle, _] -> [{:kungfu, bundle}, {:memento, name}]
      _ -> [{:memento, name}]
    end
  end

  defp memento_references(_), do: []

  defp archetype_references(names) do
    Enum.flat_map(named(:archetype, names), fn {:archetype, name} = reference ->
      case String.split(name, ".", parts: 2) do
        [bundle, _] -> [{:kungfu, bundle}, reference]
        [_] -> [reference]
      end
    end)
  end

  defp named(type, names), do: for(name <- names, is_binary(name), do: {type, name})

  defp reference_label(:reaction_fact), do: :fact
  defp reference_label(type), do: type

  defp missing?(_catalog, :reaction_fact, name), do: not Snapshot.fact_reference?(name)

  defp missing?(_catalog, :memento, name),
    do: not Map.has_key?(Mementos.declarations().names, name)

  defp missing?(_catalog, :fact, name), do: is_nil(Rules.fact_type(name))
  defp missing?(catalog, type, name), do: not MapSet.member?(Map.fetch!(catalog, type), name)
end
