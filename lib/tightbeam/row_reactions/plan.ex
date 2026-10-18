defmodule Tightbeam.RowReactions.Plan do
  @moduledoc false

  alias Tightbeam.RowReactions.Expression

  @kinds ~w(notice)

  # This is a pure admission plan. Execution and durable action reconciliation
  # consume its output; evaluating a rail itself never performs an effect.
  def decode!(bytes, provenance) do
    manifest = Toml.decode!(bytes)
    rails = Map.get(manifest, "reaction", [])
    unless is_list(rails), do: invalid!("reaction must be an array of tables")
    compiled = Enum.map(rails, &compile!(&1, provenance))
    unique!(compiled, & &1.name, "reaction name")
    compiled
  end

  def compile!(rail, provenance) when is_map(rail) do
    fields!(rail, ~w(name family events when effects), ~w(bind))
    name = text!(rail["name"], "name")
    family = text!(rail["family"], "family")
    events = rail["events"]
    unless is_list(events) and events != [], do: invalid!("events must be a nonempty array")
    Enum.each(events, &text!(&1, "event kind"))
    bindings = Map.get(rail, "bind", [])
    unless is_list(bindings), do: invalid!("bind must be an array")

    Enum.each(bindings, fn binding ->
      fields!(binding, ~w(name value), [])
      name = text!(binding["name"], "binding name")
      Expression.validate!(%{"ref" => name})

      if String.contains?(name, ".") or name in ~w(event facts),
        do: invalid!("binding must be a local name other than event or facts")

      Expression.validate!(binding["value"])
    end)

    unique!(bindings, & &1["name"], "binding name")
    Expression.validate!(rail["when"])
    effects = rail["effects"]
    unless is_list(effects) and effects != [], do: invalid!("effects must be a nonempty array")

    Enum.each(effects, fn effect ->
      fields!(effect, ~w(slot kind when value), ~w(withdraw))
      text!(effect["slot"], "effect slot")

      unless effect["kind"] in @kinds,
        do: invalid!("unknown effect kind #{inspect(effect["kind"])}")

      Expression.validate!(effect["when"])
      Expression.validate!(effect["value"])
      if Map.has_key?(effect, "withdraw"), do: Expression.validate!(effect["withdraw"])
    end)

    unique!(effects, & &1["slot"], "effect slot")

    %{
      name: name,
      family: family,
      events: events,
      bindings: bindings,
      condition: rail["when"],
      effects: effects,
      provenance: provenance
    }
  end

  def compile!(_rail, _provenance), do: invalid!("reaction must be a table")

  def evaluate(rails, %{"id" => id, "org" => org, "kind" => kind} = event, facts) do
    text!(id, "event id")
    text!(org, "event org")
    text!(kind, "event kind")

    plans =
      Enum.flat_map(rails, fn rail ->
        if kind in rail.events do
          snapshot =
            Enum.reduce(rail.bindings, %{"event" => event, "facts" => facts}, fn binding,
                                                                                 snapshot ->
              Map.put(snapshot, binding["name"], Expression.evaluate(binding["value"], snapshot))
            end)

          if matches?(rail.condition, snapshot) do
            for effect <- rail.effects, matches?(effect["when"], snapshot) do
              %{
                identity: {org, rail.family, id, effect["slot"]},
                rule: rail.name,
                family: rail.family,
                source_event_id: id,
                slot: effect["slot"],
                kind: effect["kind"],
                value: Expression.evaluate(effect["value"], snapshot),
                provenance: rail.provenance
              }
            end
          else
            []
          end
        else
          []
        end
      end)

    # Competing rules must not silently claim the same durable action.
    unique!(plans, & &1.identity, "action identity")
    plans
  end

  # Withdrawal arguments are evaluated against current facts even when the
  # admission condition no longer matches. They affect existing pending work
  # only; they never create an action or revive an accepted/canceled output.
  def withdrawals(rails, %{"id" => id, "org" => org, "kind" => kind} = event, facts) do
    entries =
      Enum.flat_map(rails, fn rail ->
        if kind in rail.events do
          snapshot =
            Enum.reduce(rail.bindings, %{"event" => event, "facts" => facts}, fn binding, acc ->
              Map.put(acc, binding["name"], Expression.evaluate(binding["value"], acc))
            end)

          for effect <- rail.effects, Map.has_key?(effect, "withdraw") do
            {{org, rail.family, id, effect["slot"]},
             Expression.evaluate(effect["withdraw"], snapshot)}
          end
        else
          []
        end
      end)

    unique!(entries, &elem(&1, 0), "withdrawal identity")
    Map.new(entries)
  end

  defp matches?(expression, snapshot) do
    case Expression.evaluate(expression, snapshot) do
      value when is_boolean(value) -> value
      other -> invalid!("condition must evaluate to a boolean, got #{inspect(other)}")
    end
  end

  defp text!(value, _label) when is_binary(value) and byte_size(value) > 0, do: value
  defp text!(_value, label), do: invalid!("#{label} must be nonempty text")

  defp unique!(values, key, label) do
    keys = Enum.map(values, key)
    if length(Enum.uniq(keys)) != length(keys), do: invalid!("duplicate #{label}")
  end

  defp fields!(record, required, optional) when is_map(record) do
    keys = Map.keys(record)

    unless required -- keys == [] and keys -- (required ++ optional) == [],
      do:
        invalid!(
          "expected fields #{inspect(required)} with optional #{inspect(optional)}, got #{inspect(keys)}"
        )
  end

  defp fields!(_record, _required, _optional), do: invalid!("expected a table")
  defp invalid!(message), do: raise(ArgumentError, "reaction plan: " <> message)
end
