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

  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc """
  ULID string (26 chars, Crockford base32): 48-bit millisecond timestamp then
  80 random bits. Unique, and sortable by mint time to MILLISECOND granularity.

  NOT strictly ordered: two ULIDs minted in the same millisecond order by their
  random suffixes, so one may sort before another minted earlier. Use it as a
  stable handle (an episodeId), never where a strictly-increasing value is
  required — a coordinator epoch needs `AdapterCoordinator.mint_epoch/1`, whose
  durable counter cannot tie.

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
end
