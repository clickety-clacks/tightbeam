defmodule Tightbeam.CliCompatibility do
  @moduledoc """
  The gateway-owned compatibility policy for Tight Beam CLI connections.

  The CLI owns and reports its build version. The gateway owns the oldest CLI
  version it still accepts; there is no matching constant on the CLI side.
  """

  @minimum_supported_version "0.1.0"

  @doc "The oldest CLI version this gateway accepts."
  @spec minimum_supported_version() :: String.t()
  def minimum_supported_version, do: @minimum_supported_version

  @doc "Accept a semantic CLI version at or above the gateway-owned minimum."
  @spec check(String.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def check(version, minimum \\ @minimum_supported_version)

  def check(version, minimum) when is_binary(version) and version != "" do
    case Version.compare(version, minimum) do
      ordering when ordering in [:eq, :gt] -> :ok
      :lt -> {:error, refusal(version, minimum)}
    end
  rescue
    Version.InvalidVersionError -> {:error, refusal(version, minimum)}
  end

  def check(_version, minimum) do
    {:error, "your CLI did not state its version; this gateway needs #{minimum} or newer"}
  end

  defp refusal(version, minimum) do
    "your CLI is too old, it says #{version}; this gateway needs #{minimum} or newer"
  end
end
