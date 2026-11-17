defmodule Tightbeam.RailScope do
  @moduledoc """
  Shared matching semantics for the agents named by a rail.

  Rail loading decides which declarations are valid for their source. This
  module only answers whether all participant archetypes fit one declaration.
  """

  @doc "Return whether every participant archetype is covered by the declaration."
  @spec matches_agents?(term(), term()) :: boolean()
  def matches_agents?(declared_archetypes, participant_archetypes)
      when is_list(declared_archetypes) and is_list(participant_archetypes) do
    cond do
      participant_archetypes == [] ->
        true

      not Enum.all?(participant_archetypes, &is_binary/1) ->
        false

      declared_archetypes == ["*"] ->
        true

      "*" in declared_archetypes ->
        false

      not Enum.all?(declared_archetypes, &is_binary/1) ->
        false

      true ->
        declared = MapSet.new(declared_archetypes)
        Enum.all?(participant_archetypes, &MapSet.member?(declared, &1))
    end
  end

  def matches_agents?(_declared_archetypes, _participant_archetypes), do: false
end
