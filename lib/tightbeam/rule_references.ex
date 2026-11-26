defmodule Tightbeam.RuleReferences do
  @moduledoc false

  alias Tightbeam.{Gateway, Mementos, Rules}
  alias Tightbeam.Identity.Provenance

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

  def validate!(entries) do
    case diagnostics(entries) do
      [] -> :ok
      errors -> raise ArgumentError, Enum.join(errors, "\n")
    end
  end

  def warn!(dir) do
    dir
    |> tree_entries!()
    |> diagnostics()
    |> Enum.each(&Logger.warning("Invalid rule reference: #{&1}"))
  rescue
    error ->
      Logger.warning("Rule reference check could not complete: #{Exception.message(error)}")
  end

  def diagnostics(entries) do
    rules =
      entries
      |> Enum.filter(fn {path, _} -> Rules.rule_file_path?(path) end)
      |> Enum.sort()

    if rules == [] do
      []
    else
      catalog = catalog(entries)
      declarations = Mementos.declarations_from_manifests(manifests(entries), nil)

      Mementos.with_declarations(declarations, fn ->
        Enum.flat_map(rules, fn {path, bytes} -> file_diagnostics(path, bytes, catalog) end)
      end)
    end
  end

  defp catalog(entries) do
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

    archetypes =
      for {path, bytes} <- entries,
          archetype_path?(path),
          owner <- Map.get(owners, path, [:substrate]),
          %{"name" => name} <- [Toml.decode!(bytes)],
          is_binary(name),
          into: MapSet.new(["default"]),
          do: Provenance.qualify(owner, name)

    %{
      archetype: archetypes,
      kungfu: MapSet.new(manifests(entries), fn {path, _} -> bundle(path) end),
      verb: MapSet.new(Map.keys(Gateway.handlers(%{})))
    }
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

  defp file_diagnostics(path, bytes, catalog) do
    case Toml.decode(bytes) do
      {:ok, manifest} ->
        for kind <- ["rule", "policy", "reaction"],
            {entry, index} <- Enum.with_index(List.wrap(manifest[kind]), 1),
            is_map(entry),
            not (kind == "policy" and Rules.retired_policy?(entry)),
            {type, name} <- Enum.uniq(references(entry)),
            missing?(catalog, type, name),
            do:
              "#{path}: #{kind} #{inspect(entry["name"] || index)}: unknown #{type} #{inspect(name)}"

      {:error, reason} ->
        ["#{path}: cannot check rule references in invalid TOML: #{inspect(reason)}"]
    end
  end

  defp references(entry) do
    remedy = if is_map(entry["remedy"]), do: entry["remedy"], else: %{}

    recurrence =
      if is_map(entry["recurrence_suppression"]), do: entry["recurrence_suppression"], else: %{}

    rearm = if is_map(recurrence["rearm"]), do: recurrence["rearm"], else: %{}

    conditions =
      Enum.flat_map(
        [entry["deny_when"], entry["when"], rearm["recovered_when"], rearm["recurred_when"]],
        &List.wrap/1
      )

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
      Enum.flat_map(conditions, &condition_references/1)
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

  defp missing?(_catalog, :memento, name),
    do: not Map.has_key?(Mementos.declarations().names, name)

  defp missing?(_catalog, :fact, name), do: is_nil(Rules.fact_type(name))
  defp missing?(catalog, type, name), do: not MapSet.member?(Map.fetch!(catalog, type), name)
end
