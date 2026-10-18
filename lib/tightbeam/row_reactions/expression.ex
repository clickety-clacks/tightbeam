defmodule Tightbeam.RowReactions.Expression do
  @moduledoc false

  # Expressions operate on a captured row snapshot. They cannot execute commands
  # or read process state, so the same event and election can be retried unchanged.
  @binary ~w(eq ne gt gte lt lte in add subtract multiply divide floor_divide)
  @unary ~w(not is_null count first text json sha256 unique)
  @variadic ~w(and or coalesce concat min max)
  @collection ~w(filter map sort)

  def validate!(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def validate!(nil), do: nil

  def validate!(values) when is_list(values) do
    Enum.each(values, &validate!/1)
    values
  end

  def validate!(%{"ref" => path} = expression) do
    keys!(expression, ["ref"])

    unless is_binary(path) and
             Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$/, path),
           do: invalid!("invalid reference #{inspect(path)}")

    expression
  end

  def validate!(%{"op" => op} = expression) when op in @collection do
    keys!(expression, ["op", "items", "as", if(op == "filter", do: "where", else: "value")])
    binding = Map.fetch!(expression, "as")

    unless is_binary(binding) and Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, binding),
      do: invalid!("invalid collection binding")

    validate!(Map.fetch!(expression, "items"))
    validate!(Map.fetch!(expression, if(op == "filter", do: "where", else: "value")))
    expression
  end

  def validate!(%{"op" => op, "args" => args} = expression) do
    keys!(expression, ["op", "args"])
    unless is_list(args), do: invalid!("#{op} args must be an array")

    valid_arity =
      cond do
        op in @binary -> length(args) == 2
        op in @unary -> length(args) == 1
        op in @variadic -> args != []
        op == "if" -> length(args) == 3
        true -> false
      end

    unless valid_arity, do: invalid!("unsupported operation or arity: #{inspect(op)}")
    Enum.each(args, &validate!/1)
    expression
  end

  def validate!(%{} = expression) do
    if Map.has_key?(expression, "op"),
      do: invalid!("operation requires args or collection fields")

    Enum.each(expression, fn {key, value} ->
      unless is_binary(key), do: invalid!("record keys must be strings")
      validate!(value)
    end)

    expression
  end

  def validate!(other), do: invalid!("unsupported value #{inspect(other)}")

  def evaluate(value, _snapshot)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def evaluate(values, snapshot) when is_list(values),
    do: Enum.map(values, &evaluate(&1, snapshot))

  def evaluate(%{"ref" => path}, snapshot) do
    Enum.reduce(String.split(path, "."), snapshot, fn
      key, %{} = record -> Map.get(record, key)
      _key, _missing -> nil
    end)
  end

  def evaluate(%{"op" => "if", "args" => [condition, yes, no]}, snapshot),
    do: evaluate(if(evaluate(condition, snapshot) == true, do: yes, else: no), snapshot)

  def evaluate(%{"op" => "and", "args" => args}, snapshot),
    do: Enum.all?(args, &(evaluate(&1, snapshot) == true))

  def evaluate(%{"op" => "or", "args" => args}, snapshot),
    do: Enum.any?(args, &(evaluate(&1, snapshot) == true))

  def evaluate(%{"op" => "coalesce", "args" => args}, snapshot) do
    Enum.reduce_while(args, nil, fn expression, _ ->
      case evaluate(expression, snapshot) do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end

  def evaluate(%{"op" => op, "items" => source, "as" => binding} = expression, snapshot)
      when op in @collection do
    items = evaluate(source, snapshot)
    unless is_list(items), do: invalid!("#{op} requires an array, got #{inspect(items)}")
    inner = Map.fetch!(expression, if(op == "filter", do: "where", else: "value"))
    eval = fn item -> evaluate(inner, Map.put(snapshot, binding, item)) end

    case op do
      "filter" -> Enum.filter(items, &(eval.(&1) == true))
      "map" -> Enum.map(items, eval)
      "sort" -> Enum.sort_by(items, eval)
    end
  end

  def evaluate(%{"op" => op, "args" => args}, snapshot),
    do: apply_operation(op, Enum.map(args, &evaluate(&1, snapshot)))

  def evaluate(%{} = record, snapshot),
    do: Map.new(record, fn {key, expression} -> {key, evaluate(expression, snapshot)} end)

  # Missing facts do not accidentally match inequality. Null selection is an
  # explicit predicate, just as with the existing statute evaluator.
  defp apply_operation(op, [left, right])
       when op in ~w(eq ne gt gte lt lte in) and (is_nil(left) or is_nil(right)),
       do: false

  defp apply_operation("eq", [left, right]), do: left == right
  defp apply_operation("ne", [left, right]), do: left != right

  defp apply_operation("gt", [left, right]) when is_number(left) and is_number(right),
    do: left > right

  defp apply_operation("gte", [left, right]) when is_number(left) and is_number(right),
    do: left >= right

  defp apply_operation("lt", [left, right]) when is_number(left) and is_number(right),
    do: left < right

  defp apply_operation("lte", [left, right]) when is_number(left) and is_number(right),
    do: left <= right

  defp apply_operation("in", [value, values]) when is_list(values), do: value in values
  defp apply_operation("not", [value]) when is_boolean(value), do: not value
  defp apply_operation("is_null", [value]), do: is_nil(value)
  defp apply_operation("count", [values]) when is_list(values), do: length(values)
  defp apply_operation("first", [values]) when is_list(values), do: List.first(values)
  defp apply_operation("unique", [values]) when is_list(values), do: Enum.uniq(values)

  defp apply_operation("text", [value])
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: to_string(value)

  defp apply_operation("concat", values) do
    unless Enum.all?(values, &is_binary/1), do: invalid!("concat requires strings")
    Enum.join(values)
  end

  defp apply_operation("json", [value]), do: JSON.encode!(value)

  defp apply_operation("sha256", [value]) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp apply_operation("add", [left, right]) when is_number(left) and is_number(right),
    do: left + right

  defp apply_operation("subtract", [left, right]) when is_number(left) and is_number(right),
    do: left - right

  defp apply_operation("multiply", [left, right]) when is_number(left) and is_number(right),
    do: left * right

  defp apply_operation("divide", [left, right])
       when is_number(left) and is_number(right) and right != 0,
       do: left / right

  defp apply_operation("floor_divide", [left, right])
       when is_integer(left) and is_integer(right) and right != 0,
       do: Integer.floor_div(left, right)

  defp apply_operation("min", values), do: numeric_extreme(values, &Enum.min/1)
  defp apply_operation("max", values), do: numeric_extreme(values, &Enum.max/1)
  defp apply_operation(op, args), do: invalid!("invalid operands for #{op}: #{inspect(args)}")

  defp numeric_extreme(values, operation) do
    unless Enum.all?(values, &is_number/1), do: invalid!("numeric operands required")
    operation.(values)
  end

  defp keys!(record, expected) do
    unless Enum.sort(Map.keys(record)) == Enum.sort(expected),
      do: invalid!("expected fields #{inspect(expected)}, got #{inspect(Map.keys(record))}")
  end

  defp invalid!(message), do: raise(ArgumentError, "reaction expression: " <> message)
end
