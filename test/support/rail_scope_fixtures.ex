defmodule Tightbeam.TestRailScopeFixtures do
  @moduledoc false

  @rail_tables ~w(rule policy reaction)

  def wildcard_substrate(content, kinds \\ @rail_tables)
      when is_binary(content) and is_list(kinds) do
    kinds = Enum.uniq(kinds)

    unless kinds != [] and Enum.all?(kinds, &(&1 in @rail_tables)) do
      raise ArgumentError, "unsupported rail fixture tables: #{inspect(kinds)}"
    end

    lines = String.split(content, "\n", trim: false)

    {lines, state} =
      Enum.reduce(lines, {[], :outside}, fn line, {acc, state} ->
        cond do
          line in Enum.map(kinds, &("[[" <> &1 <> "]]")) ->
            acc = finish_table(acc, state)
            {[line | acc], :unscoped}

          String.starts_with?(line, "[") ->
            acc = finish_table(acc, state)
            {[line | acc], :outside}

          state in [:unscoped, :scoped] and
              String.starts_with?(String.trim_leading(line), "archetypes =") ->
            {["archetypes = [\"*\"]" | acc], :scoped}

          true ->
            {[line | acc], state}
        end
      end)

    lines = finish_table(lines, state)
    lines |> Enum.reverse() |> Enum.join("\n")
  end

  defp finish_table(lines, :unscoped), do: ["archetypes = [\"*\"]" | lines]
  defp finish_table(lines, _state), do: lines
end
