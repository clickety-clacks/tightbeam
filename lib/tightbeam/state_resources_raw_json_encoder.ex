defmodule Tightbeam.StateResources.RawJSON do
  @moduledoc false
  defstruct [:bytes]

  defimpl JSON.Encoder do
    def encode(%{bytes: bytes}, _encoder), do: bytes
  end
end
