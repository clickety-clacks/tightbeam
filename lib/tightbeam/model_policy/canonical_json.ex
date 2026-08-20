defmodule Tightbeam.ModelPolicy.CanonicalJSON do
  @moduledoc """
  RFC 8785 canonical JSON for policy projections.

  Object keys must be strings and strings must contain valid Unicode. Maps, lists,
  strings, finite numbers, booleans, and nil are the complete admitted value set.
  """

  @spec encode!(term()) :: binary()
  def encode!(value), do: value |> encode_value() |> IO.iodata_to_binary()

  @spec sha256(term()) :: binary()
  def sha256(value) do
    value
    |> encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_value(value) when is_map(value) do
    members =
      value
      |> Enum.map(fn
        {key, item} when is_binary(key) ->
          valid_unicode!(key)
          {utf16_sort_key(key), key, item}

        {key, _item} ->
          raise ArgumentError, "canonical JSON object key is not a string: #{inspect(key)}"
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_sort_key, key, item} -> [encode_string(key), ?:, encode_value(item)] end)
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp encode_value(value) when is_list(value) do
    [?[, value |> Enum.map(&encode_value/1) |> Enum.intersperse(?,), ?]]
  end

  defp encode_value(value) when is_binary(value), do: encode_string(value)
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: encode_float(value)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(nil), do: "null"

  defp encode_value(value) do
    raise ArgumentError, "value is outside the canonical JSON data model: #{inspect(value)}"
  end

  defp encode_string(value) do
    valid_unicode!(value)

    escaped =
      value
      |> String.to_charlist()
      |> Enum.map(fn
        ?\b ->
          "\\b"

        ?\t ->
          "\\t"

        ?\n ->
          "\\n"

        ?\f ->
          "\\f"

        ?\r ->
          "\\r"

        ?" ->
          "\\\""

        ?\\ ->
          "\\\\"

        codepoint when codepoint in 0x00..0x1F ->
          "\\u" <>
            (codepoint
             |> Integer.to_string(16)
             |> String.downcase()
             |> String.pad_leading(4, "0"))

        codepoint ->
          <<codepoint::utf8>>
      end)

    [?", escaped, ?"]
  end

  # :short gives the shortest round-tripping decimal. RFC 8785 then requires
  # ECMAScript's fixed/scientific placement around those digits.
  defp encode_float(value) do
    raw = :erlang.float_to_binary(value, [:short])

    cond do
      raw in ["-0.0", "0.0"] -> "0"
      String.ends_with?(raw, ["nan", "inf"]) -> raise ArgumentError, "non-finite JSON number"
      true -> ecmascript_number(raw)
    end
  end

  defp ecmascript_number(raw) do
    {sign, unsigned} =
      if String.starts_with?(raw, "-"),
        do: {"-", binary_part(raw, 1, byte_size(raw) - 1)},
        else: {"", raw}

    [coefficient | exponent_parts] = String.split(unsigned, "e", parts: 2)
    exponent = if exponent_parts == [], do: 0, else: exponent_parts |> hd() |> String.to_integer()
    [integer | fractional_parts] = String.split(coefficient, ".", parts: 2)
    fraction = if fractional_parts == [], do: "", else: hd(fractional_parts)
    fraction = if fraction == "0", do: "", else: fraction
    digits = integer <> fraction
    k = byte_size(integer) + exponent
    n = byte_size(digits)

    encoded =
      cond do
        k <= 0 and k > -6 ->
          "0." <> String.duplicate("0", -k) <> digits

        k > 0 and k < n ->
          String.slice(digits, 0, k) <> "." <> String.slice(digits, k, n - k)

        k >= n and k <= 21 ->
          digits <> String.duplicate("0", k - n)

        true ->
          mantissa =
            if n == 1,
              do: digits,
              else: String.first(digits) <> "." <> String.slice(digits, 1, n - 1)

          scientific_exponent = k - 1
          exponent_sign = if scientific_exponent >= 0, do: "+", else: ""
          mantissa <> "e" <> exponent_sign <> Integer.to_string(scientific_exponent)
      end

    sign <> encoded
  end

  defp utf16_sort_key(value), do: :unicode.characters_to_binary(value, :utf8, {:utf16, :big})

  defp valid_unicode!(value) do
    unless String.valid?(value) do
      raise ArgumentError, "canonical JSON string is not valid Unicode"
    end
  end
end
