defmodule Tightbeam.Id do
  @moduledoc "ID generation shared by stores (one boring implementation)."

  import Bitwise

  @doc """
  Random UUIDv4 string in canonical lowercase-hex form
  (`"xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"`), from `:crypto` randomness.
  """
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  @doc "Deterministic RFC 4122 UUIDv5 for a canonical UUID namespace and binary name."
  @spec uuid5(String.t(), binary()) :: String.t()
  def uuid5(namespace, name) when is_binary(namespace) and is_binary(name) do
    namespace_bytes = canonical_uuid_bytes!(namespace)

    <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
      :crypto.hash(:sha, namespace_bytes <> name)

    format_uuid(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc """
  ULID string (26 chars, Crockford base32): 48-bit millisecond timestamp then
  80 random bits. Unique, and sortable by mint time to MILLISECOND granularity.

  NOT strictly ordered: two ULIDs minted in the same millisecond order by their
  random suffixes, so one may sort before another minted earlier. Use it as a
  stable handle, never where a strictly-increasing value is required — that
  needs a durable counter, which cannot tie.

      iex> id = Tightbeam.Id.ulid()
      iex> String.length(id)
      26
  """
  @spec ulid() :: String.t()
  def ulid do
    <<random::80>> = :crypto.strong_rand_bytes(10)
    encode32(<<System.system_time(:millisecond)::48, random::80>>)
  end

  defp encode32(<<bits::128>>) do
    for shift <- 125..0//-5, into: "" do
      <<Enum.at(@crockford, bits >>> shift &&& 0x1F)>>
    end
  end

  defp canonical_uuid_bytes!(uuid) do
    case uuid do
      <<a::binary-size(8), "-", b::binary-size(4), "-", c::binary-size(4), "-", d::binary-size(4),
        "-", e::binary-size(12)>> ->
        hex = a <> b <> c <> d <> e

        if uuid == String.downcase(uuid) and hex =~ ~r/\A[0-9a-f]{32}\z/ do
          Base.decode16!(hex, case: :lower)
        else
          raise ArgumentError, "UUID namespace must be canonical lowercase hexadecimal"
        end

      _ ->
        raise ArgumentError, "UUID namespace must be canonical lowercase hexadecimal"
    end
  end

  defp format_uuid(bytes) do
    hex = Base.encode16(bytes, case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end
end
