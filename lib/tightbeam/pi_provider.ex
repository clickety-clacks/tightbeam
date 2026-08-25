defmodule Tightbeam.PiProvider do
  @moduledoc false

  @type credential_liveness :: :live | {:dead, term()} | {:unknown, term()}

  @callback id() :: atom()
  @callback wire_name() :: String.t()
  @callback model_prefix() :: String.t()
  @callback fetch_catalog(state :: map()) :: {:ok, [map()]} | {:error, term()}
  @callback credential_live?(target :: map(), home :: String.t(), opts :: keyword()) ::
              credential_liveness()
  @callback hollow_check(bytes :: binary()) :: nil | String.t()

  @providers [
    Tightbeam.PiProvider.OpenCodeGo
  ]

  @doc false
  def all, do: @providers

  @doc false
  def for_wire(wire_name) when is_binary(wire_name) do
    Enum.find(@providers, fn mod -> mod.wire_name() == wire_name end) ||
      Tightbeam.PiProvider.OpenCodeGo
  end

  @doc false
  def for_id(id) when is_atom(id) do
    Enum.find(@providers, fn mod -> mod.id() == id end)
  end
end
