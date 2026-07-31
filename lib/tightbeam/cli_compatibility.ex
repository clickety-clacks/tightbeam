defmodule Tightbeam.CliCompatibility do
  @moduledoc """
  The gateway-owned compatibility policy for Tight Beam CLI connections.

  The CLI owns and reports its build version. While Tight Beam is pre-1.0, the
  gateway accepts only the exact CLI version it was released with.
  """

  @required_version "0.1.0"

  @doc "The exact CLI version this gateway accepts."
  @spec required_version() :: String.t()
  def required_version, do: @required_version

  @doc "Accept only the gateway-owned exact CLI version."
  @spec check(String.t() | nil) :: :ok | {:error, String.t()}
  def check(@required_version), do: :ok

  def check(nil),
    do: {:error, "your CLI offered no version; this gateway requires #{@required_version}"}

  def check(version),
    do: {:error, "your CLI offered #{version}; this gateway requires #{@required_version}"}
end
