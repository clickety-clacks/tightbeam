defmodule Tightbeam.SubmissionSize do
  @moduledoc false

  def codex_text_limit, do: Tightbeam.Harness.Codex.submission_text_limit()

  def text_chars(text) when is_binary(text) do
    if String.valid?(text),
      do: count_scalars(text, 0),
      else: raise(ArgumentError, "invalid_submission_text_utf8")
  end

  defp count_scalars(<<>>, count), do: count

  defp count_scalars(<<_scalar::utf8, rest::binary>>, count),
    do: count_scalars(rest, count + 1)

  def check_codex(parts), do: check_text(parts, codex_text_limit())

  def check_text(_parts, nil), do: :ok

  def check_text(parts, limit) when is_list(parts) and is_integer(limit) and limit > 0 do
    chars =
      Enum.reduce(parts, 0, fn
        %{type: "text", text: text}, sum -> sum + text_chars(text)
        %{"type" => "text", "text" => text}, sum -> sum + text_chars(text)
        _, sum -> sum
      end)

    if chars <= limit,
      do: :ok,
      else: {:error, {:submission_text_limit_exceeded, chars, limit}}
  end

  # The caller supplies the actual member rendering and complete envelope
  # overhead (including separators and the Gateway sender stamp). Greedy
  # ordered prefixes are maximal; no message-count or UTF-8 byte cap applies.
  # Measure each member once, rather than repeatedly rendering a growing queue.
  def pack_codex(items, member_text, overhead),
    do: pack_text(items, member_text, overhead, codex_text_limit())

  def pack_text(items, _member_text, _overhead, nil), do: {:ok, [items]}

  def pack_text(items, member_text, overhead, limit) when is_integer(limit) and limit > 0 do
    result =
      Enum.reduce_while(items, {[], [], nil, 0, 0}, fn item,
                                                       {chunks, reversed, first, count, chars} ->
        size = text_chars(member_text.(item))
        first = first || item

        if chars + size + overhead.(first, count + 1) <= limit do
          {:cont, {chunks, [item | reversed], first, count + 1, chars + size}}
        else
          single = size + overhead.(item, 1)

          if single > limit do
            {:halt, {:error, {:source_submission_too_large, item, single, limit}}}
          else
            {:cont, {[Enum.reverse(reversed) | chunks], [item], item, 1, size}}
          end
        end
      end)

    case result do
      {:error, _} = error -> error
      {chunks, [], _, _, _} -> {:ok, Enum.reverse(chunks)}
      {chunks, reversed, _, _, _} -> {:ok, Enum.reverse([Enum.reverse(reversed) | chunks])}
    end
  end
end
