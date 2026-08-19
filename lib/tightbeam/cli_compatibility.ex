defmodule Tightbeam.CliCompatibility do
  @moduledoc """
  The gateway-owned compatibility policy for Tightbeam CLI connections.

  The CLI package version is the release version. Before 1.0, the gateway
  accepts only that exact version. Starting at 1.0, it accepts every CLI with
  the same MAJOR version.
  """

  @required_version Mix.Project.config() |> Keyword.fetch!(:version)
  @stable_version Version.parse!("1.0.0")

  @doc "The gateway release version used for CLI compatibility decisions."
  @spec required_version() :: String.t()
  def required_version, do: @required_version

  @doc "Apply the gateway release's CLI compatibility policy."
  @spec check(String.t() | nil) :: :ok | {:error, String.t()}
  def check(version), do: check(version, @required_version)

  @doc false
  @spec check(String.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def check(nil, required_version),
    do: {:error, "your CLI offered no version; this gateway requires #{required_version}"}

  def check(version, required_version) do
    if compatible?(version, required_version) do
      :ok
    else
      {:error, "your CLI offered #{version}; this gateway requires #{required_version}"}
    end
  end

  defp compatible?(offered_version, required_version) do
    with {:ok, offered} <- Version.parse(offered_version),
         {:ok, required} <- Version.parse(required_version) do
      if Version.compare(offered, @stable_version) != :lt and
           Version.compare(required, @stable_version) != :lt do
        offered.major == required.major
      else
        offered == required
      end
    else
      :error -> false
    end
  end
end
