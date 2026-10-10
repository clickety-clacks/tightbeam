defmodule Tightbeam.SubmissionSize do
  @moduledoc false

  # rust-v0.154.0 protocol::user_input::MAX_USER_INPUT_TEXT_CHARS and
  # TurnRequestProcessor::validate_v2_input_limit: sum Rust chars(), i.e.
  # Unicode scalar values, across ALL text items in this submission.
  @codex_text_limit 1_048_576

  def codex_text_limit, do: @codex_text_limit

  def text_chars(text) when is_binary(text) do
    if String.valid?(text), do: count_scalars(text, 0),
      else: raise(ArgumentError, "invalid_submission_text_utf8")
  end

  defp count_scalars(<<>>, count), do: count
  defp count_scalars(<<_scalar::utf8, rest::binary>>, count),
    do: count_scalars(rest, count + 1)

  def check_codex(parts) when is_list(parts) do
    chars = Enum.reduce(parts, 0, fn
      %{type: "text", text: text}, sum -> sum + text_chars(text)
      %{"type" => "text", "text" => text}, sum -> sum + text_chars(text)
      _, sum -> sum
    end)

    if chars <= @codex_text_limit, do: :ok,
      else: {:error, {:submission_text_limit_exceeded, chars, @codex_text_limit}}
  end

  # The caller supplies the actual member rendering and complete envelope
  # overhead (including separators and the Gateway sender stamp). Greedy
  # ordered prefixes are maximal; no message-count or UTF-8 byte cap applies.
  # Measure each member once, rather than repeatedly rendering a growing queue.
  def pack_codex(items, member_text, overhead) do
    result = Enum.reduce_while(items, {[], [], nil, 0, 0}, fn item,
        {chunks, reversed, first, count, chars} ->
      size = text_chars(member_text.(item))
      first = first || item

      if chars + size + overhead.(first, count + 1) <= @codex_text_limit do
        {:cont, {chunks, [item | reversed], first, count + 1, chars + size}}
      else
        single = size + overhead.(item, 1)
        if single > @codex_text_limit do
          {:halt, {:error, {:source_submission_too_large, item, single, @codex_text_limit}}}
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
