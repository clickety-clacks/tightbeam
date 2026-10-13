defmodule Tightbeam.Keyset do
  @moduledoc false

  @type boundary :: :latest | :earliest | {:before, [term()]} | {:after, [term()]}

  @doc "Fetch one bounded keyset page and bounded probes for accurate page flags."
  def page(
        query,
        select_from,
        probe_from,
        base_where,
        base_params,
        order,
        boundary,
        limit,
        tuple,
        sort \\ :asc
      )
      when sort in [:asc, :desc] do
    {operator, direction, reverse?} = query_shape(boundary, sort)
    {cursor_where, cursor_params} = cursor_predicate(order, operator, boundary)
    where = join_where(base_where, cursor_where)

    rows =
      query.(
        select_from <>
          where_clause(where) <>
          " ORDER BY " <> order_clause(order, direction) <> " LIMIT ?",
        base_params ++ cursor_params ++ [limit + 1]
      )

    extra? = length(rows) > limit
    selected = rows |> Enum.take(limit) |> maybe_reverse(reverse?)

    {has_more_before, has_more_after} =
      page_flags(
        query,
        probe_from,
        base_where,
        base_params,
        order,
        boundary,
        selected,
        extra?,
        tuple,
        sort
      )

    %{
      rows: selected,
      has_more_before: has_more_before,
      has_more_after: has_more_after,
      candidate_count: length(rows)
    }
  end

  defp query_shape(:latest, :asc), do: {nil, "DESC", true}
  defp query_shape(:earliest, :asc), do: {nil, "ASC", false}
  defp query_shape({:before, _tuple}, :asc), do: {"<", "DESC", true}
  defp query_shape({:after, _tuple}, :asc), do: {">", "ASC", false}
  defp query_shape(:latest, :desc), do: {nil, "DESC", false}
  defp query_shape(:earliest, :desc), do: {nil, "ASC", true}
  defp query_shape({:before, _tuple}, :desc), do: {"<", "DESC", false}
  defp query_shape({:after, _tuple}, :desc), do: {">", "ASC", true}

  defp page_flags(_query, _from, _where, _params, _order, :latest, _rows, extra?, _tuple, :asc),
    do: {extra?, false}

  defp page_flags(_query, _from, _where, _params, _order, :latest, _rows, extra?, _tuple, :desc),
    do: {extra?, false}

  defp page_flags(_query, _from, _where, _params, _order, :earliest, _rows, extra?, _tuple, :asc),
    do: {false, extra?}

  defp page_flags(
         _query,
         _from,
         _where,
         _params,
         _order,
         :earliest,
         _rows,
         extra?,
         _tuple,
         :desc
       ),
       do: {false, extra?}

  defp page_flags(query, from, where, params, order, {:before, cursor}, rows, extra?, tuple, sort) do
    after? =
      case rows do
        [] -> exists?(query, from, where, params, order, ">", cursor)
        _ -> exists?(query, from, where, params, order, ">", newest_tuple(rows, sort, tuple))
      end

    {extra?, after?}
  end

  defp page_flags(query, from, where, params, order, {:after, cursor}, rows, extra?, tuple, sort) do
    before? =
      case rows do
        [] -> exists?(query, from, where, params, order, "<", cursor)
        _ -> exists?(query, from, where, params, order, "<", oldest_tuple(rows, sort, tuple))
      end

    {before?, extra?}
  end

  defp newest_tuple(rows, :asc, tuple), do: tuple.(List.last(rows))
  defp newest_tuple(rows, :desc, tuple), do: tuple.(hd(rows))
  defp oldest_tuple(rows, :asc, tuple), do: tuple.(hd(rows))
  defp oldest_tuple(rows, :desc, tuple), do: tuple.(List.last(rows))

  defp exists?(query, from, base_where, base_params, order, operator, values) do
    {cursor_where, cursor_params} = tuple_predicate(order, operator, values)
    where = join_where(base_where, cursor_where)

    query.(
      "SELECT 1 FROM " <> from <> where_clause(where) <> " LIMIT 1",
      base_params ++ cursor_params
    ) != []
  end

  defp cursor_predicate(_order, nil, _boundary), do: {nil, []}

  defp cursor_predicate(order, operator, {_, values}),
    do: tuple_predicate(order, operator, values)

  defp tuple_predicate(order, operator, values)
       when operator in ["<", "<=", ">", ">="] and length(order) == length(values) do
    strict_operator = if operator in ["<", "<="], do: "<", else: ">"

    strict =
      Enum.with_index(order)
      |> Enum.map(fn {column, index} ->
        prefix =
          Enum.take(order, index)
          |> Enum.zip(Enum.take(values, index))
          |> Enum.map(fn {prior_column, _prior_value} ->
            prior_column <> " = ?"
          end)

        clause = Enum.join(prefix ++ [column <> " " <> strict_operator <> " ?"], " AND ")
        params = Enum.take(values, index) ++ [Enum.at(values, index)]
        {"(" <> clause <> ")", params}
      end)

    strict_sql = strict |> Enum.map(&elem(&1, 0)) |> Enum.join(" OR ")
    strict_params = Enum.flat_map(strict, &elem(&1, 1))

    if operator in ["<=", ">="] do
      equal_sql = Enum.map_join(order, " AND ", &(&1 <> " = ?"))
      {"(" <> strict_sql <> " OR (" <> equal_sql <> "))", strict_params ++ values}
    else
      {"(" <> strict_sql <> ")", strict_params}
    end
  end

  defp join_where(nil, nil), do: nil
  defp join_where(where, nil), do: where
  defp join_where(nil, predicate), do: predicate
  defp join_where(where, predicate), do: "(" <> where <> ") AND " <> predicate

  defp where_clause(nil), do: ""
  defp where_clause(where), do: " WHERE " <> where

  defp order_clause(columns, direction),
    do: Enum.map_join(columns, ", ", &(&1 <> " " <> direction))

  defp maybe_reverse(rows, true), do: Enum.reverse(rows)
  defp maybe_reverse(rows, false), do: rows
end
