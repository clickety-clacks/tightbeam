defmodule Tightbeam.RowReactions.Plan do
  @moduledoc false
  alias Tightbeam.RowReactions.Expression

  def compile!(rail, provenance) do
    fields!(rail, ~w(name family events when effects), ~w(bind))
    Enum.each(~w(name family), &text!(rail[&1]))

    unless is_list(rail["events"]) and rail["events"] != [],
      do: raise(ArgumentError, "reaction requires events")

    Enum.each(rail["events"], &text!/1)
    bindings = Map.get(rail, "bind", [])

    Enum.each(bindings, fn binding ->
      fields!(binding, ~w(name value), [])
      name = binding["name"]

      unless is_binary(name) and Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name) and
               name not in ~w(event facts),
             do: raise(ArgumentError, "invalid reaction binding")

      Expression.validate!(binding["value"])
    end)

    unique!(Enum.map(bindings, & &1["name"]))
    Expression.validate!(rail["when"])
    effects = rail["effects"]

    unless is_list(effects) and effects != [],
      do: raise(ArgumentError, "reaction requires effects")

    Enum.each(effects, fn effect ->
      fields!(effect, ~w(slot kind when value), ~w(withdraw))
      text!(effect["slot"])
      unless effect["kind"] == "notice", do: raise(ArgumentError, "unsupported reaction effect")
      Enum.each(~w(when value withdraw), &Expression.validate!(effect[&1]))
    end)

    unique!(Enum.map(effects, & &1["slot"]))

    %{
      name: rail["name"],
      family: rail["family"],
      events: rail["events"],
      bindings: bindings,
      condition: rail["when"],
      effects: effects,
      provenance: provenance
    }
  end

  # A nonmatching rail still supplies its typed withdrawal parameters. They
  # cannot admit work; they describe how an already pending output is canceled.
  def evaluate(rails, event, facts) do
    plans =
      for rail <- rails,
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
          selected:
            Expression.boolean!(Expression.evaluate(rail.condition, context)) and
              Expression.boolean!(Expression.evaluate(effect["when"], context)),
          value: effect["value"],
          context: context,
          withdraw: Expression.evaluate(effect["withdraw"], context)
        }
      end

    unique!(Enum.map(plans, & &1.identity))

    Enum.map(plans, fn plan ->
      value = if plan.selected, do: Expression.evaluate(plan.value, plan.context)
      plan |> Map.put(:value, value) |> Map.delete(:context)
    end)
  end

  defp context(rail, event, facts),
    do:
      Enum.reduce(rail.bindings, %{"event" => event, "facts" => facts}, fn binding, context ->
        Map.put(context, binding["name"], Expression.evaluate(binding["value"], context))
      end)

  defp text!(value) when is_binary(value) and value != "", do: value
  defp text!(_), do: raise(ArgumentError, "reaction name must be nonempty text")

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
