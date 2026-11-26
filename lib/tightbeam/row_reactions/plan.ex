defmodule Tightbeam.RowReactions.Plan do
  @moduledoc false
  alias Tightbeam.{FeatureFlags, SubtreeScope}
  alias Tightbeam.RowReactions.Expression

  @subtree_facts "scope_subtree"

  @doc false
  # The facts key holding subtree-rule inputs; present only with the flag on.
  def subtree_facts_key, do: @subtree_facts

  def compile!(rail, provenance, owner \\ :substrate, owned_archetypes \\ [])

  def compile!(%{"settings" => _settings} = rail, provenance, owner, owned_archetypes) do
    fields!(rail, ~w(name family settings english), ["archetypes"])
    Enum.each(~w(name family english), &text!(rail[&1]))
    archetypes = validate_archetypes!(rail, owner, owned_archetypes)

    settings = rail["settings"]

    unless is_map(settings) and settings != %{},
      do: raise(ArgumentError, "reaction settings must be a nonempty table")

    Enum.each(settings, fn {key, value} ->
      text!(key)
      validate_setting!(value)
    end)

    %{
      mode: :settings,
      name: Tightbeam.Identity.Provenance.qualify(owner, rail["name"]),
      short_name: rail["name"],
      owner: owner,
      archetypes: archetypes,
      owned_archetypes:
        Enum.map(owned_archetypes, &Tightbeam.Identity.Provenance.qualify(owner, &1)),
      family: rail["family"],
      settings: settings,
      english: rail["english"],
      provenance: provenance
    }
  end

  def compile!(rail, provenance, owner, owned_archetypes) do
    subtree? = FeatureFlags.subtree_rules?()
    optional = ~w(bind english archetypes policy_context)
    optional = if subtree?, do: optional ++ ~w(scope roles), else: optional
    fields!(rail, ~w(name family events when effects), optional)
    Enum.each(~w(name family), &text!(rail[&1]))
    archetypes = validate_archetypes!(rail, owner, owned_archetypes)

    subtree =
      if subtree?,
        do: SubtreeScope.parse!(rail, &raise(ArgumentError, "reaction #{rail["name"]}: " <> &1)),
        else: %{}

    archetypes =
      if subtree? and owner == :substrate and archetypes == [] and
           not Map.has_key?(rail, "archetypes") and not Map.has_key?(rail, "roles"),
         do: ["*"],
         else: archetypes

    policy_context = Map.get(rail, "policy_context", "participants")

    unless policy_context in ["participants", "organization"],
      do: raise(ArgumentError, "unsupported reaction policy context")

    english = Map.get(rail, "english")
    if english, do: text!(english)

    unless is_list(rail["events"]) and rail["events"] != [],
      do: raise(ArgumentError, "reaction requires events")

    Enum.each(rail["events"], &text!/1)
    bindings = Map.get(rail, "bind", [])

    Enum.each(bindings, fn binding ->
      fields!(binding, ~w(name value), [])
      name = binding["name"]

      reserved = if subtree?, do: ~w(event facts anchor), else: ~w(event facts)

      unless is_binary(name) and Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name) and
               name not in reserved,
             do: raise(ArgumentError, "invalid reaction binding")

      Expression.validate!(binding["value"])
      validate_scope_expressions!(binding["value"], owner, owned_archetypes, rail["name"])
    end)

    unique!(Enum.map(bindings, & &1["name"]))
    Expression.validate!(rail["when"])
    validate_scope_expressions!(rail["when"], owner, owned_archetypes, rail["name"])
    effects = rail["effects"]

    unless is_list(effects) and effects != [],
      do: raise(ArgumentError, "reaction requires effects")

    Enum.each(effects, fn effect ->
      fields!(effect, ~w(slot kind when value), ~w(withdraw))
      text!(effect["slot"])

      unless effect["kind"] in ["notice", "cancel_notice"],
        do: raise(ArgumentError, "unsupported reaction effect")

      Enum.each(~w(when value withdraw), fn key ->
        Expression.validate!(effect[key])
        validate_scope_expressions!(effect[key], owner, owned_archetypes, rail["name"])
      end)
    end)

    unique!(Enum.map(effects, & &1["slot"]))

    %{
      mode: :event,
      policy_context: policy_context,
      name: Tightbeam.Identity.Provenance.qualify(owner, rail["name"]),
      short_name: rail["name"],
      owner: owner,
      archetypes: archetypes,
      owned_archetypes:
        Enum.map(owned_archetypes, &Tightbeam.Identity.Provenance.qualify(owner, &1)),
      family: rail["family"],
      events: rail["events"],
      bindings: bindings,
      condition: rail["when"],
      effects: effects,
      english: english,
      provenance: provenance
    }
    |> Map.merge(subtree)
  end

  @doc false
  def handoff_default?(%{owner: :substrate, archetypes: archetypes} = rail) do
    (archetypes == ["*"] or Map.get(rail, :policy_context) == "organization") and
      terminal_handoff?(rail)
  end

  def handoff_default?(_rail), do: false

  defp terminal_handoff?(%{
         mode: :event,
         short_name: "assignment-terminal-handoff",
         family: "terminal-handoff",
         events: events,
         effects: effects
       }) do
    "assignment" in events and
      Enum.any?(effects, &match?(%{"slot" => "handoff", "kind" => "notice"}, &1))
  end

  defp terminal_handoff?(_rail), do: false

  # A nonmatching rail still supplies its typed withdrawal parameters. They
  # cannot admit work; they describe how an already pending output is canceled.
  def evaluate(rails, event, facts) do
    plans =
      for rail <- rails,
          rail.mode == :event,
          event["kind"] in rail.events,
          context = context(rail, event, facts),
          effect <- rail.effects do
        identity = [event["org"], rail.family, event["id"], effect["slot"]]

        %{
          identity: identity,
          family: rail.family,
          source_event_id: event["id"],
          slot: effect["slot"],
          rule: rail.name,
          provenance: rail.provenance,
          kind: effect["kind"],
          rail: rail,
          selected:
            Expression.boolean!(Expression.evaluate(rail.condition, context)) and
              Expression.boolean!(Expression.evaluate(effect["when"], context)),
          value: effect["value"],
          context: context,
          withdraw: Expression.evaluate(effect["withdraw"], context)
        }
      end

    plans =
      Enum.map(plans, fn plan ->
        if plan.selected do
          value = Expression.evaluate(plan.value, plan.context)
          scoped? = scope_matches?(plan.rail, event, facts, value)

          plan
          |> Map.put(:selected, scoped?)
          |> Map.put(:value, value)
          |> then(fn scoped_plan ->
            if scoped?, do: scoped_plan, else: Map.put(scoped_plan, :withdraw, nil)
          end)
        else
          Map.put(plan, :value, nil)
        end
      end)

    plans = select_terminal_handoff(plans, event)
    unique!(Enum.map(plans, & &1.identity))

    Enum.map(plans, fn plan ->
      plan |> Map.delete(:context) |> Map.delete(:rail)
    end)
  end

  # The canonical organization-wide handoff may be the built-in, the stock
  # seed, or an operator edit. A matching bundle uses the same action identity,
  # so the election must happen after scope matching and before admission.
  defp select_terminal_handoff(plans, %{"kind" => "assignment", "org" => org, "id" => id}) do
    identity = [org, "terminal-handoff", id, "handoff"]
    handoffs = Enum.filter(plans, &(&1.identity == identity))

    with {[_global], [_ | _] = candidates} <- Enum.split_with(handoffs, &global_handoff?/1),
         true <- Enum.all?(candidates, &bundle_handoff?/1) do
      case Enum.filter(candidates, & &1.selected) do
        [] -> plans -- candidates
        [winner] -> plans -- (handoffs -- [winner])
        _ -> plans
      end
    else
      _ -> plans
    end
  end

  defp select_terminal_handoff(plans, _event), do: plans

  defp global_handoff?(%{kind: "notice", rail: rail}), do: handoff_default?(rail)
  defp global_handoff?(_plan), do: false

  defp bundle_handoff?(%{
         kind: "notice",
         rail: %{owner: {:kungfu, _}, short_name: "assignment-terminal-handoff"}
       }),
       do: true

  defp bundle_handoff?(_plan), do: false

  defp validate_archetypes!(rail, owner, owned_archetypes) do
    names = Map.get(rail, "archetypes", [])

    unless is_list(names) and Enum.all?(names, &is_binary/1),
      do: raise(ArgumentError, "archetypes must be a list of strings")

    if Enum.uniq(names) != names,
      do: raise(ArgumentError, "archetypes must not contain duplicates")

    if "*" in names and names != ["*"],
      do: raise(ArgumentError, ~s(archetypes "*" must be the only entry))

    case owner do
      :substrate ->
        names

      {:kungfu, name} ->
        allowed =
          owned_archetypes
          |> Enum.map(&Tightbeam.Identity.Provenance.qualify(owner, &1))
          |> MapSet.new()

        foreign = Enum.reject(names, &MapSet.member?(allowed, &1))

        if foreign != [] do
          raise ArgumentError,
                "reaction #{rail["name"]} archetypes contain #{inspect(foreign)}; " <>
                  "kungfu #{name} may name only its own archetypes; allowed names: " <>
                  Enum.join(MapSet.to_list(allowed) |> Enum.sort(), ", ")
        end

        names
    end
  end

  defp validate_scope_expressions!(_expression, :substrate, _owned_archetypes, _rail), do: :ok

  defp validate_scope_expressions!(expression, {:kungfu, name} = owner, owned_archetypes, rail) do
    allowed =
      owned_archetypes
      |> Enum.map(&Tightbeam.Identity.Provenance.qualify(owner, &1))
      |> MapSet.new()

    walk_scope_expression(expression, fn fact, op, value ->
      if archetype_reference?(fact) do
        values = if op in ["in", "not_in"], do: value, else: [value]
        foreign = Enum.reject(List.wrap(values), &MapSet.member?(allowed, &1))

        if foreign != [] do
          raise ArgumentError,
                "reaction #{rail} in kungfu #{name} compares #{fact} against foreign " <>
                  "archetype(s) #{inspect(foreign)}; allowed names: " <>
                  Enum.join(MapSet.to_list(allowed) |> Enum.sort(), ", ")
        end
      end
    end)
  end

  defp walk_scope_expression(%{"op" => op, "args" => [left, right | _]} = expression, visit)
       when op in ["eq", "ne", "in", "not_in"] do
    right_reference = expression_reference(right)

    cond do
      reference = expression_reference(left) -> visit.(reference, op, right)
      op in ["eq", "ne"] and is_binary(right_reference) -> visit.(right_reference, op, left)
      true -> :ok
    end

    Enum.each(Map.values(expression), &walk_scope_expression(&1, visit))
  end

  defp walk_scope_expression(value, visit) when is_map(value),
    do: Enum.each(Map.values(value), &walk_scope_expression(&1, visit))

  defp walk_scope_expression(value, visit) when is_list(value),
    do: Enum.each(value, &walk_scope_expression(&1, visit))

  defp walk_scope_expression(_value, _visit), do: :ok

  defp expression_reference(%{"ref" => name}) when is_binary(name), do: name
  defp expression_reference(_), do: nil

  defp archetype_reference?(name), do: String.ends_with?(name, ".archetype")

  # Organization-level declarations elect policy independently of their audience.
  # Session-scoped declarations retain the existing participant restrictions.
  defp scope_matches?(rail, event, facts, value) do
    who_matches?(rail, event, facts, value) and where_matches?(rail, facts)
  rescue
    _ -> false
  end

  defp who_matches?(%{policy_context: "organization"}, _event, _facts, _value), do: true

  defp who_matches?(rail, _event, facts, value) do
    base = Map.get(facts, "scope_participant_archetypes", [])

    effect_key =
      case value do
        %{"session_key" => key} when is_binary(key) -> key
        %{session_key: key} when is_binary(key) -> key
        _ -> nil
      end

    effect = if effect_key, do: [scope_session_archetype(facts, effect_key)], else: []

    participants = base ++ effect

    cond do
      participants != [] ->
        case Map.get(rail, :roles, []) do
          [] ->
            Tightbeam.RailScope.matches_agents?(rail.archetypes, participants)

          roles ->
            keys =
              get_in(facts, [@subtree_facts, "participants"]) ++ List.wrap(effect_key)

            Tightbeam.RailScope.matches_participants?(
              rail.archetypes,
              roles,
              Enum.zip_with(participants, keys, fn archetype, key ->
                %{archetype: archetype, roles: held_roles(facts, key)}
              end)
            )
        end

      rail.owner == :substrate ->
        true

      true ->
        scope_records_belong?(rail, facts)
    end
  end

  # A reaction anchored to a role covers only work owed to that role's current
  # active holder or to a session under it; an unbound role covers nobody.
  defp where_matches?(rail, facts) do
    case Map.get(rail, :scope_role) do
      nil ->
        true

      role ->
        subtree = Map.fetch!(facts, @subtree_facts)
        holder = get_in(subtree, ["anchors", role, "session_key"])
        is_binary(holder) and holder in Map.get(subtree, "owner_lineage", [])
    end
  end

  defp held_roles(facts, key) do
    facts
    |> get_in([@subtree_facts, "role_bindings"])
    |> Enum.flat_map(fn {role, holder} -> if holder == key, do: [role], else: [] end)
    |> Enum.sort()
  end

  defp scope_session_archetype(facts, key) do
    facts
    |> Map.get("sessions", [])
    |> Enum.find_value(fn
      %{"sessionKey" => ^key, "archetype" => archetype} -> archetype
      _ -> nil
    end) || get_in(facts, [@subtree_facts, "holder_archetypes", key])
  end

  defp scope_records_belong?(%{owned_archetypes: owned_archetypes} = rail, facts)
       when is_list(owned_archetypes) do
    allowed = MapSet.new(owned_archetypes)
    roles = Map.get(rail, :roles, [])
    groups = Map.get(facts, "scope_record_session_groups", [])

    groups != [] and
      Enum.all?(groups, fn keys ->
        keys != [] and
          Enum.all?(keys, fn key ->
            archetype = scope_session_archetype(facts, key)

            # A role the kungfu names reaches its holder whatever the agent type.
            (is_binary(archetype) and MapSet.member?(allowed, archetype)) or
              (roles != [] and SubtreeScope.role_admits?(roles, held_roles(facts, key)))
          end)
      end)
  end

  defp scope_records_belong?(_rail, _facts), do: false

  defp context(rail, event, facts),
    do:
      Enum.reduce(rail.bindings, base_context(rail, event, facts), fn binding, context ->
        Map.put(context, binding["name"], Expression.evaluate(binding["value"], context))
      end)

  # Bind the live anchor separately for each rule, preserving other names.
  defp base_context(%{scope_role: role}, event, facts) do
    anchor = get_in(facts, [@subtree_facts, "anchors", role]) || %{}
    names = Map.put(Map.get(facts, "names", %{}), "anchor", anchor["name"])

    %{
      "event" => event,
      "facts" => Map.put(facts, "names", names),
      "anchor" => %{"role" => role, "session_key" => anchor["session_key"]}
    }
  end

  defp base_context(_rail, event, facts), do: %{"event" => event, "facts" => facts}

  defp text!(value) when is_binary(value) and value != "", do: value
  defp text!(_), do: raise(ArgumentError, "reaction name must be nonempty text")

  defp validate_setting!(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
       do: :ok

  defp validate_setting!(values) when is_list(values), do: Enum.each(values, &validate_setting!/1)

  defp validate_setting!(values) when is_map(values) do
    Enum.each(values, fn {key, value} ->
      text!(key)
      validate_setting!(value)
    end)
  end

  defp validate_setting!(_),
    do: raise(ArgumentError, "reaction settings must contain only static TOML values")

  defp unique!(values) do
    unless length(values) == length(Enum.uniq(values)),
      do: raise(ArgumentError, "duplicate reaction identity or name")
  end

  defp fields!(record, required, optional) when is_map(record) do
    unless required -- Map.keys(record) == [] and Map.keys(record) -- (required ++ optional) == [],
      do: raise(ArgumentError, "invalid reaction fields")
  end

  defp fields!(_, _, _), do: raise(ArgumentError, "reaction must be a table")
end
