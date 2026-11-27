defmodule Tightbeam.RailScope do
  @moduledoc """
  Shared matching semantics for the agents named by a rail.

  Rail loading decides which declarations are valid for their source. This
  module only answers whether all participants fit one declaration, by agent
  type or, where the declaration names roles, by a role they hold.
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

  @doc """
  Return whether every participant passes a declaration that also names roles.

  Each participant is `%{archetype: archetype | nil, roles: [held_role]}`. It
  passes when its agent type fits `declared_archetypes` or it holds a role
  that `declared_roles` admits (`Tightbeam.SubtreeScope.role_admits?/2`).
  With no declared roles this is exactly `matches_agents?/2`.
  """
  @spec matches_participants?(term(), [String.t()], [map()]) :: boolean()
  def matches_participants?(declared_archetypes, [], participants) when is_list(participants),
    do: matches_agents?(declared_archetypes, Enum.map(participants, & &1.archetype))

  def matches_participants?(declared_archetypes, declared_roles, participants)
      when is_list(declared_roles) and is_list(participants) do
    Enum.all?(participants, fn participant ->
      matches_agents?(declared_archetypes, [participant.archetype]) or
        Tightbeam.SubtreeScope.role_admits?(declared_roles, participant.roles)
    end)
  end
end
