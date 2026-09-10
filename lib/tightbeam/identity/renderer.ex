defmodule Tightbeam.Identity.Renderer do
  @moduledoc """
  The one exact-line recursive renderer for served identity guidance.

  Catalog names are flat basenames. Catalog construction refuses ambiguity,
  and rendering returns explicit universal-root reachability and include
  provenance instead of asking rendered prose to stand in for graph state.
  """

  alias Tightbeam.Identity.IncludeError

  @universal_roots ["operating-model.md", "operating-manual.md"]
  @directive ~r/^#include "([^"\/\\]+\.md)"[ \t]*$/

  @type catalog_entry :: %{bytes: binary(), path: String.t()}
  @type catalog :: %{optional(String.t()) => catalog_entry()}
  @type provenance :: %{
          root_origin: String.t(),
          fragment_name: String.t(),
          source_path: String.t(),
          line: pos_integer(),
          chain: [String.t()]
        }

  @doc "Build the strict flat fragment catalog from path/byte entries."
  @spec catalog!([{String.t(), binary()}]) :: catalog()
  def catalog!(entries) when is_list(entries) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {path, bytes}, catalog ->
      name = Path.basename(path)

      case Map.fetch(catalog, name) do
        :error ->
          Map.put(catalog, name, %{bytes: bytes, path: path})

        {:ok, %{path: first_path}} ->
          invalid!(:duplicate_basename, "fragment-catalog", path, nil, [], [first_path, path])
      end
    end)
  end

  @doc "Normalize legacy name-to-bytes maps through the same catalog shape."
  @spec normalize_catalog!(map()) :: catalog()
  def normalize_catalog!(catalog) when is_map(catalog) do
    entries =
      Enum.map(catalog, fn
        {_name, %{bytes: bytes, path: path}} -> {path, bytes}
        {name, bytes} when is_binary(bytes) -> {"guidance/#{name}", bytes}
      end)

    catalog!(entries)
  end

  @doc "Render one root and return bytes plus graph metadata."
  @spec render!(binary(), String.t(), map(), keyword()) :: map()
  def render!(bytes, origin, catalog, opts \\ []) when is_binary(bytes) and is_binary(origin) do
    catalog = normalize_catalog!(catalog)

    state = %{
      origin: origin,
      catalog: catalog,
      provenance: [],
      root_occurrences: %{},
      universal_root: Keyword.get(opts, :universal_root)
    }

    {rendered, state} = render_lines(bytes, origin, [], state)

    %{
      bytes: rendered,
      provenance: Enum.reverse(state.provenance),
      reachable_roots: state.root_occurrences |> Map.keys() |> MapSet.new(),
      root_occurrences: state.root_occurrences
    }
  end

  @doc "Parse one include-like line through the sole directive grammar."
  @spec directive(binary()) :: :none | {:include, String.t()} | :invalid
  def directive("#include" <> _rest = line) do
    case Regex.run(@directive, line, capture: :all_but_first) do
      [name] -> {:include, name}
      nil -> :invalid
    end
  end

  def directive(_line), do: :none

  defp render_lines(bytes, source_path, stack, state) do
    bytes
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_reduce(state, fn {line, line_number}, state ->
      case directive(line) do
        :none ->
          {line, state}

        :invalid ->
          invalid!(:invalid_directive, state.origin, source_path, line_number, chain(stack))

        {:include, name} ->
          render_include(name, source_path, line_number, stack, state)
      end
    end)
    |> then(fn {lines, state} -> {Enum.join(lines, "\n"), state} end)
  end

  defp render_include(name, source_path, line, stack, state) do
    include_chain = chain([name | stack])
    entry = Map.get(state.catalog, name)

    cond do
      is_nil(entry) ->
        invalid!(:missing_fragment, state.origin, source_path, line, include_chain, [name])

      name in stack ->
        invalid!(:cycle, state.origin, source_path, line, include_chain)

      length(stack) >= 10 ->
        invalid!(:depth_exceeded, state.origin, source_path, line, include_chain)

      state.universal_root in @universal_roots and name in @universal_roots ->
        invalid!(:universal_root_reentry, state.origin, source_path, line, include_chain)

      true ->
        provenance = %{
          root_origin: state.origin,
          fragment_name: name,
          source_path: source_path,
          line: line,
          chain: include_chain
        }

        state = %{state | provenance: [provenance | state.provenance]}
        state = record_root_occurrence!(state, name, provenance)

        entry.bytes
        |> String.trim_trailing("\n")
        |> render_lines(entry.path, [name | stack], state)
    end
  end

  defp record_root_occurrence!(state, name, provenance) when name in @universal_roots do
    occurrences = Map.get(state.root_occurrences, name, [])

    if occurrences != [] do
      [first | _] = Enum.reverse(occurrences)

      invalid!(
        :duplicate_universal_root,
        state.origin,
        provenance.source_path,
        provenance.line,
        provenance.chain,
        [format_provenance(first), format_provenance(provenance)]
      )
    end

    %{state | root_occurrences: Map.put(state.root_occurrences, name, [provenance])}
  end

  defp record_root_occurrence!(state, _name, _provenance), do: state

  defp chain(stack), do: Enum.reverse(stack)

  defp format_provenance(provenance) do
    "#{provenance.source_path}:#{provenance.line} (#{Enum.join(provenance.chain, " -> ")})"
  end

  defp invalid!(cause, origin, path, line, chain, paths \\ []) do
    raise IncludeError,
      cause: cause,
      origin: origin,
      path: path,
      line: line,
      chain: chain,
      paths: paths
  end
end
