defmodule Tightbeam.MementoFacts do
  @moduledoc false
  alias Tightbeam.{Mementos, MementoJudgments}

  @selectors %{
    "latest_linked_review" => "linked_review",
    "latest_holder_verdict" => "holder"
  }

  def type("call.comparison_value"), do: :string
  def type("call.has_comparison_value"), do: :bool

  def type("call.memento_names"), do: {:list, :string}

  def type(fact) when is_binary(fact) do
    case String.split(fact, ".", parts: 3) do
      ["assignment", selector, property] when is_map_key(@selectors, selector) ->
        selector_type(selector, property)

      [prefix, operator, name] when prefix in ~w(work_item assignment call) ->
        kind = if prefix == "call", do: nil, else: prefix
        declared_type(kind, operator, name)

      _ ->
        nil
    end
  end

  def type(_), do: nil

  defp selector_type(_, property) when property in ~w(present has_judgment_kind), do: :bool
  defp selector_type(_, "judgment_kind"), do: :string
  defp selector_type("latest_linked_review", "independent"), do: :bool

  defp selector_type(_, property) do
    case String.split(property, ".", parts: 2) do
      [operator, name] -> declared_type("attest", operator, name)
      _ -> nil
    end
  end

  defp declared_type(kind, operator, name) do
    case Map.get(Mementos.declarations().names, name) do
      %{records: records} ->
        if is_nil(kind) or kind in records do
          case operator do
            "memento" ->
              {:list, :string}

            "has_memento" ->
              :bool

            operator
            when operator in ~w(memento_matches_call memento_contains_comparison_value) and
                   kind == "attest" ->
              :bool

            _ ->
              nil
          end
        end

      _ ->
        nil
    end
  end

  def call_value("call.memento_names", proposed), do: Enum.map(proposed, &elem(&1, 0))

  def call_value(fact, proposed) do
    ["call", operator, name] = String.split(fact, ".", parts: 3)
    values = Map.get(Map.new(proposed), name, [])
    value(operator, values)
  end

  def record_value(db, kind, id, operator, name),
    do: value(operator, Mementos.current(db, kind, id, name))

  def value("memento", values), do: values
  def value("has_memento", values), do: values != []

  def comparison_value(call), do: Map.get(call, :memento_comparison_value) || ""
  def has_comparison_value?(call), do: comparison_value(call) != ""

  def contains_comparison?(values, call),
    do: has_comparison_value?(call) and comparison_value(call) in values

  def matches?(values, expected),
    do: values != [] and expected != [] and MapSet.new(values) == MapSet.new(expected)

  # The caller caches this selected row once per selector, so all its facts
  # describe the same judgment even outside a mutation transaction.
  def select(db, assignment_id, selector),
    do: MementoJudgments.latest(db, assignment_id, Map.fetch!(@selectors, selector))

  def judgment_value(_db, selected, "present", _proposed), do: not is_nil(selected)
  def judgment_value(_db, nil, "has_judgment_kind", _proposed), do: false

  def judgment_value(_db, selected, "has_judgment_kind", _proposed),
    do: is_binary(selected.judgment_kind) and selected.judgment_kind != ""

  def judgment_value(_db, nil, "judgment_kind", _proposed), do: ""
  def judgment_value(_db, selected, "judgment_kind", _proposed), do: selected.judgment_kind || ""
  def judgment_value(_db, nil, "independent", _proposed), do: false
  def judgment_value(_db, selected, "independent", _proposed), do: selected.independent

  def judgment_value(db, selected, property, proposed) do
    [operator, name] = String.split(property, ".", parts: 2)
    values = if selected, do: Mementos.current(db, "attest", selected.id, name), else: []

    case operator do
      "memento_matches_call" ->
        expected = Map.get(Map.new(proposed), name, [])
        matches?(values, expected)

      _ ->
        value(operator, values)
    end
  end
end
