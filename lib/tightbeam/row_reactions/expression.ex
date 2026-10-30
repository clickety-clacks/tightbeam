defmodule Tightbeam.RowReactions.Expression do
  @moduledoc false

  # Pure expressions over recorded rows. Policy cannot call a runtime handler.
  @binary ~w(eq ne gt gte lt lte in add)
  @unary ~w(not is_null count first unique json sha256)
  @variadic ~w(and or coalesce concat)

  def validate!(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def validate!(values) when is_list(values), do: Enum.each(values, &validate!/1)

  def validate!(%{"ref" => path} = value) do
    unless map_size(value) == 1 and is_binary(path) and
             Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$/, path),
           do: raise(ArgumentError, "invalid reaction reference")
  end

  def validate!(%{"op" => op, "items" => items, "as" => name} = value)
      when op in ["filter", "map"] do
    field = if op == "filter", do: "where", else: "value"

    unless Enum.sort(Map.keys(value)) == Enum.sort(["op", "items", "as", field]) and
             is_binary(name) and Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name),
           do: raise(ArgumentError, "invalid reaction collection")

    validate!(items)
    validate!(Map.fetch!(value, field))
  end

  def validate!(%{"op" => op, "args" => args} = value) do
    unless map_size(value) == 2 and is_list(args) and
             ((op in @binary and length(args) == 2) or
                (op in @unary and length(args) == 1) or
                (op in @variadic and args != []) or (op == "if" and length(args) == 3)),
           do: raise(ArgumentError, "unsupported reaction operation or arity: #{inspect(op)}")

    Enum.each(args, &validate!/1)
  end

  def validate!(value) when is_map(value) do
    if Map.has_key?(value, "op"), do: raise(ArgumentError, "invalid reaction operation")

    Enum.each(value, fn {key, expression} ->
      unless is_binary(key), do: raise(ArgumentError, "reaction record keys must be strings")
      validate!(expression)
    end)
  end

  def evaluate(%{"ref" => path}, facts), do: get_in(facts, String.split(path, "."))

  def evaluate(%{"op" => "if", "args" => [condition, yes, no]}, facts),
    do: evaluate(if(boolean!(evaluate(condition, facts)), do: yes, else: no), facts)

  def evaluate(%{"op" => "and", "args" => args}, facts),
    do: Enum.all?(args, &boolean!(evaluate(&1, facts)))

  def evaluate(%{"op" => "or", "args" => args}, facts),
    do: Enum.any?(args, &boolean!(evaluate(&1, facts)))

  def evaluate(%{"op" => "coalesce", "args" => args}, facts),
    do:
      Enum.reduce_while(args, nil, fn arg, _ ->
        case evaluate(arg, facts) do
          nil -> {:cont, nil}
          value -> {:halt, value}
        end
      end)

  def evaluate(%{"op" => "filter", "items" => items, "as" => name, "where" => condition}, facts),
    do:
      Enum.filter(
        evaluate(items, facts),
        &boolean!(evaluate(condition, Map.put(facts, name, &1)))
      )

  def evaluate(%{"op" => "map", "items" => items, "as" => name, "value" => value}, facts),
    do: Enum.map(evaluate(items, facts), &evaluate(value, Map.put(facts, name, &1)))

  def evaluate(%{"op" => op, "args" => args}, facts),
    do: apply_operation(op, Enum.map(args, &evaluate(&1, facts)))

  def evaluate(value, facts) when is_map(value),
    do: Map.new(value, fn {key, expression} -> {key, evaluate(expression, facts)} end)

  def evaluate(value, facts) when is_list(value), do: Enum.map(value, &evaluate(&1, facts))
  def evaluate(value, _facts), do: value

  def boolean!(value) when is_boolean(value), do: value
  def boolean!(_), do: raise(ArgumentError, "reaction condition must be boolean")

  defp apply_operation("eq", [a, b]), do: a == b
  defp apply_operation("ne", [a, b]), do: a != b
  defp apply_operation("gt", [a, b]) when is_number(a) and is_number(b), do: a > b
  defp apply_operation("gte", [a, b]) when is_number(a) and is_number(b), do: a >= b
  defp apply_operation("lt", [a, b]) when is_number(a) and is_number(b), do: a < b
  defp apply_operation("lte", [a, b]) when is_number(a) and is_number(b), do: a <= b
  defp apply_operation("add", [a, b]) when is_number(a) and is_number(b), do: a + b
  defp apply_operation("in", [a, b]) when is_list(b), do: a in b
  defp apply_operation("not", [a]) when is_boolean(a), do: not a
  defp apply_operation("is_null", [a]), do: is_nil(a)
  defp apply_operation("count", [a]) when is_list(a), do: length(a)
  defp apply_operation("first", [a]) when is_list(a), do: List.first(a)
  defp apply_operation("unique", [a]) when is_list(a), do: Enum.uniq(a)
  defp apply_operation("json", [a]), do: JSON.encode!(a)

  defp apply_operation("sha256", [a]) when is_binary(a),
    do: :crypto.hash(:sha256, a) |> Base.encode16(case: :lower)

  defp apply_operation("concat", args) do
    unless Enum.all?(args, &is_binary/1), do: raise(ArgumentError, "concat requires strings")
    Enum.join(args)
  end
end
