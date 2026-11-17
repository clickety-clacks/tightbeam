defmodule Tightbeam.Identity.TomlEdit do
  @moduledoc false

  # Migration edits values, not documents. Keep the original token spans so
  # comments, whitespace, ordering and unrelated values survive the rewrite.
  def update!(bytes, desired) do
    original = Toml.decode!(bytes)

    if original == desired do
      bytes
    else
      edit!(bytes, original, desired)
    end
  end

  defp edit!(bytes, original, desired) do
    tokens = tokenize(bytes, 0, [])
    index = document(tokens, [], %{nodes: %{}, tables: %{[] => 0}}, bytes)
    edits = changes(original, desired, [], index, bytes)

    result =
      edits
      |> Enum.group_by(fn {start, stop, _} -> {start, stop} end)
      |> Enum.map(fn {{start, stop}, parts} ->
        {start, stop, Enum.map_join(parts, fn {_, _, text} -> text end)}
      end)
      |> Enum.sort_by(fn {start, stop, _} -> {start, stop} end, :desc)
      |> Enum.reduce(bytes, fn {start, stop, replacement}, acc ->
        binary_part(acc, 0, start) <>
          replacement <>
          binary_part(acc, stop, byte_size(acc) - stop)
      end)

    unless Toml.decode!(result) == desired do
      raise ArgumentError, "TOML migration edit did not preserve the requested document"
    end

    result
  end

  defp changes(value, value, _path, _index, _bytes), do: []

  defp changes(old, new, path, index, bytes) when is_map(old) and is_map(new) do
    Enum.flat_map(new, fn {key, value} ->
      if Map.has_key?(old, key) do
        changes(Map.fetch!(old, key), value, path ++ [key], index, bytes)
      else
        insert_field(path, key, value, index, bytes)
      end
    end) ++
      Enum.flat_map(Map.keys(old) -- Map.keys(new), fn key ->
        remove_node(path ++ [key], index, bytes)
      end)
  end

  defp changes(old, new, path, index, bytes) when is_list(old) and is_list(new) do
    if length(old) == length(new) do
      Enum.with_index(Enum.zip(old, new))
      |> Enum.flat_map(fn {{before, after_value}, n} ->
        changes(before, after_value, path ++ [n], index, bytes)
      end)
    else
      list_changes(old, new, path, 0, index, bytes, :empty)
    end
  end

  defp changes(_old, new, path, index, bytes) do
    node = Map.fetch!(index.nodes, path)
    old_text = binary_part(bytes, node.start, node.stop - node.start)
    [{node.start, node.stop, scalar(new, old_text)}]
  end

  # Migration only removes comparisons or qualifies their values. Match retained
  # comparisons by their fact/op pair rather than shifting the following rule.
  defp list_changes([], [], _path, _n, _index, _bytes, _separator), do: []

  defp list_changes([], remaining, path, _n, index, _bytes, separator) do
    node = Map.fetch!(index.nodes, path)
    prefix = if separator == :value, do: ", ", else: ""
    [{node.stop - 1, node.stop - 1, prefix <> Enum.map_join(remaining, ", ", &encode/1)}]
  end

  defp list_changes(
         [old | rest] = original,
         [new | tail] = desired,
         path,
         n,
         index,
         bytes,
         separator
       ) do
    node = Map.fetch!(index.nodes, path ++ [n])

    cond do
      corresponding?(old, new) ->
        next_separator = if Map.has_key?(node, :entry_stop), do: :comma, else: :value

        changes(old, new, path ++ [n], index, bytes) ++
          list_changes(rest, tail, path, n + 1, index, bytes, next_separator)

      Enum.any?(rest, &corresponding?(&1, new)) or
          not Enum.any?(tail, &corresponding?(old, &1)) ->
        remove_node(path ++ [n], index, bytes) ++
          list_changes(rest, desired, path, n + 1, index, bytes, separator)

      true ->
        [
          {node.start, node.start, encode(new) <> ", "}
          | list_changes(original, tail, path, n, index, bytes, :comma)
        ]
    end
  end

  defp list_changes(old, [], path, n, index, bytes, _separator) do
    Enum.with_index(old, n)
    |> Enum.flat_map(fn {_value, i} -> remove_node(path ++ [i], index, bytes) end)
  end

  defp corresponding?(
         %{"fact" => fact, "op" => op, "value" => old},
         %{"fact" => fact, "op" => op, "value" => new}
       ),
       do: corresponding?(old, new)

  defp corresponding?(value, value), do: true

  defp corresponding?(old, new) when is_binary(old) and is_binary(new),
    do: String.ends_with?(new, "." <> old) or String.ends_with?(new, "/" <> old)

  defp corresponding?(old, new) when is_list(old) and is_list(new),
    do: Enum.all?(new, fn item -> Enum.any?(old, &corresponding?(&1, item)) end)

  defp corresponding?(_, _), do: false

  defp insert_field(path, key, value, index, bytes) do
    case Map.fetch(index.tables, path) do
      {:ok, offset} ->
        newline = if String.contains?(bytes, "\r\n"), do: "\r\n", else: "\n"

        prefix =
          if offset > 0 and binary_part(bytes, offset - 1, 1) != "\n", do: newline, else: ""

        [{offset, offset, prefix <> key <> " = " <> encode(value) <> newline}]

      :error ->
        case Map.fetch(index.nodes, path) do
          {:ok, node} ->
            prefix = if node.children == [], do: "", else: ", "
            [{node.stop - 1, node.stop - 1, prefix <> key <> " = " <> encode(value)}]

          :error ->
            # A document may spell a rail with dotted assignments instead of
            # an explicit [rule] header. Add its new field in the same root.
            dotted = Enum.map_join(path ++ [key], ".", &encode/1)
            newline = if String.contains?(bytes, "\r\n"), do: "\r\n", else: "\n"
            [{0, 0, dotted <> " = " <> encode(value) <> newline}]
        end
    end
  end

  defp remove_node(path, index, bytes) do
    node = Map.fetch!(index.nodes, path)
    start = Map.get(node, :entry_start, node.start)
    stop = Map.get(node, :entry_stop, node.stop)

    # Deleting a comparison never deletes its comments, including comments
    # between elements of a multiline array or inside a removed table.
    bytes
    |> binary_part(start, stop - start)
    |> tokenize(start, [])
    |> Enum.reject(&(&1.kind == :newline))
    |> Enum.map(&{&1.start, &1.stop, ""})
  end

  defp scalar(value, "'" <> _ = old) when is_binary(value) do
    if not String.starts_with?(old, "'''") and not String.contains?(value, ["'", "\n", "\r"]),
      do: "'" <> value <> "'",
      else: encode(value)
  end

  defp scalar(value, _), do: encode(value)

  defp encode(value) when is_binary(value), do: JSON.encode!(value)
  defp encode(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &encode/1) <> "]"

  defp encode(value) when is_map(value),
    do:
      "{" <>
        Enum.map_join(Enum.sort(value), ", ", fn {k, v} ->
          JSON.encode!(k) <> " = " <> encode(v)
        end) <> "}"

  defp encode(value), do: to_string(value)

  defp document([], _context, index, _bytes), do: index

  defp document([%{kind: :newline} | rest], context, index, bytes),
    do: document(rest, context, index, bytes)

  defp document([%{text: "["} = first | rest], _context, index, bytes) do
    {array?, rest} =
      case rest do
        [%{text: "["} | tail] -> {true, tail}
        _ -> {false, rest}
      end

    {keys, [%{text: "]"} = last | rest]} = key(rest, [], [])
    {last, rest} = if array?, do: {hd(rest), tl(rest)}, else: {last, rest}
    {path, index} = table_path(keys, array?, index)
    offset = line_end(bytes, last.stop)
    index = put_in(index.tables[path], offset)
    index = put_in(index.nodes[path], %{kind: :table, start: first.start, stop: byte_size(bytes)})
    index = close_tables(index, path, first.start)
    document(rest, path, index, bytes)
  end

  defp document(tokens, context, index, bytes) do
    first = hd(tokens)
    {keys, [%{text: "="} | rest]} = key(tokens, [], [])
    path = context ++ keys
    {node, rest, index} = value(rest, path, index)
    node = Map.put(node, :entry_start, first.start)
    index = put_in(index.nodes[path], node)
    document(rest, context, index, bytes)
  end

  defp table_path(keys, array?, index) do
    {path, index} =
      Enum.reduce(Enum.with_index(keys), {[], index}, fn {key, n}, {path, acc} ->
        path = path ++ [key]
        last? = n == length(keys) - 1

        case Map.get(acc.nodes, path) do
          %{kind: :tables, count: count} when not last? or not array? ->
            {path ++ [count - 1], acc}

          %{kind: :tables, count: count} when array? and last? ->
            {path ++ [count], put_in(acc.nodes[path].count, count + 1)}

          _ when array? and last? ->
            {path ++ [0], put_in(acc.nodes[path], %{kind: :tables, count: 1})}

          _ ->
            {path, acc}
        end
      end)

    {path, index}
  end

  defp close_tables(index, current, offset) do
    nodes =
      Map.new(index.nodes, fn {path, node} ->
        if node.kind == :table and not List.starts_with?(current, path) do
          {path, Map.update!(node, :stop, &min(&1, offset))}
        else
          {path, node}
        end
      end)

    %{index | nodes: nodes}
  end

  defp line_end(bytes, offset) do
    case :binary.match(bytes, "\n", scope: {offset, byte_size(bytes) - offset}) do
      {at, 1} -> at + 1
      :nomatch -> byte_size(bytes)
    end
  end

  defp key([%{text: t} | _] = rest, part, keys) when t in ["=", "]"] do
    {Enum.reverse([key_part(part) | keys]), rest}
  end

  defp key([%{text: "."} | rest], part, keys), do: key(rest, [], [key_part(part) | keys])
  defp key([token | rest], part, keys), do: key(rest, [token | part], keys)

  defp key_part(tokens) do
    text = tokens |> Enum.reverse() |> Enum.map_join(& &1.text)
    if String.starts_with?(text, ["\"", "'"]), do: Toml.decode!("v = " <> text)["v"], else: text
  end

  defp value([%{kind: :newline} | rest], path, index), do: value(rest, path, index)
  defp value([%{text: "["} = open | rest], path, index), do: array(rest, path, index, open, [], 0)
  defp value([%{text: "{"} = open | rest], path, index), do: inline(rest, path, index, open, [])

  defp value([%{kind: :string} = token | rest], _path, index),
    do: {Map.put(token, :kind, :scalar), rest, index}

  defp value(tokens, _path, index) do
    {parts, rest} =
      Enum.split_while(tokens, &(&1.kind != :newline and &1.text not in [",", "]", "}"]))

    {%{kind: :scalar, start: hd(parts).start, stop: List.last(parts).stop}, rest, index}
  end

  defp array([%{kind: :newline} | rest], path, index, open, children, n),
    do: array(rest, path, index, open, children, n)

  defp array([%{text: "]"} = close | rest], _path, index, open, children, _n),
    do:
      {%{kind: :array, start: open.start, stop: close.stop, children: Enum.reverse(children)},
       rest, index}

  defp array(tokens, path, index, open, children, n) do
    {node, rest, index} = value(tokens, path ++ [n], index)
    rest = Enum.drop_while(rest, &(&1.kind == :newline))

    {node, rest} =
      case rest do
        [%{text: ","} = comma | tail] -> {Map.put(node, :entry_stop, comma.stop), tail}
        _ -> {node, rest}
      end

    index = put_in(index.nodes[path ++ [n]], node)
    array(rest, path, index, open, [node | children], n + 1)
  end

  defp inline([%{text: "}"} = close | rest], _path, index, open, children),
    do: {%{kind: :inline, start: open.start, stop: close.stop, children: children}, rest, index}

  defp inline(tokens, path, index, open, children) do
    first = hd(tokens)
    {keys, [%{text: "="} | rest]} = key(tokens, [], [])
    {node, rest, index} = value(rest, path ++ keys, index)
    node = Map.put(node, :entry_start, first.start)

    {node, rest} =
      case rest do
        [%{text: ","} = comma | tail] -> {Map.put(node, :entry_stop, comma.stop), tail}
        _ -> {node, rest}
      end

    index = put_in(index.nodes[path ++ keys], node)
    inline(rest, path, index, open, [node | children])
  end

  defp tokenize(<<239, 187, 191, rest::binary>>, 0, tokens), do: tokenize(rest, 3, tokens)
  defp tokenize("", _offset, tokens), do: Enum.reverse(tokens)

  defp tokenize(<<c, rest::binary>>, offset, tokens) when c in [32, 9, 13],
    do: tokenize(rest, offset + 1, tokens)

  defp tokenize("#" <> rest, offset, tokens) do
    [comment | _] = String.split(rest, "\n", parts: 2)
    size = byte_size(comment) + 1
    tokenize(binary_part("#" <> rest, size, byte_size(rest) + 1 - size), offset + size, tokens)
  end

  defp tokenize(bytes, offset, tokens) do
    {size, kind} =
      cond do
        String.starts_with?(bytes, "\"\"\"") ->
          {string_end(bytes, "\"\"\"", 3), :string}

        String.starts_with?(bytes, "'''") ->
          {string_end(bytes, "'''", 3), :string}

        String.starts_with?(bytes, "\"") ->
          {string_end(bytes, "\"", 1), :string}

        String.starts_with?(bytes, "'") ->
          {string_end(bytes, "'", 1), :string}

        String.starts_with?(bytes, "\n") ->
          {1, :newline}

        binary_part(bytes, 0, 1) in ["[", "]", "{", "}", "=", ",", "."] ->
          {1, :symbol}

        true ->
          [atom] = Regex.run(~r/^[^\s\[\]{}=,.#"']+/, bytes)
          {byte_size(atom), :atom}
      end

    token = %{text: binary_part(bytes, 0, size), start: offset, stop: offset + size, kind: kind}
    tokenize(binary_part(bytes, size, byte_size(bytes) - size), offset + size, [token | tokens])
  end

  defp string_end(bytes, delimiter, offset) do
    tail = binary_part(bytes, offset, byte_size(bytes) - offset)

    cond do
      String.starts_with?(tail, delimiter) ->
        size = byte_size(delimiter)

        extra =
          if size == 3,
            do:
              min(
                byte_size(tail) -
                  byte_size(String.trim_leading(tail, binary_part(delimiter, 0, 1))),
                5
              ),
            else: size

        offset + extra

      String.starts_with?(delimiter, "\"") and String.starts_with?(tail, "\\") ->
        string_end(bytes, delimiter, offset + 2)

      true ->
        string_end(bytes, delimiter, offset + 1)
    end
  end
end
