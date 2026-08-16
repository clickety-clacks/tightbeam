defmodule Tightbeam.BuildStamp do
  @moduledoc """
  The compile-time build identity a running gateway reports at `/version`.

  A running gateway must state which bytes it is (builds-identify-bytes). The
  release version alone cannot: many builds carry the same version. The build
  number is `git rev-list --count HEAD` and the sha is `git rev-parse --short
  HEAD`, both captured HERE, at compile time — the shipped gateway carries no
  toolchain and no `.git`, so neither can be read at runtime. This matches the
  version stamp's own compile-time home in `Tightbeam.CliCompatibility`.

  `packaging/assemble.sh` runs `mix clean` before `mix release`, so the release
  always recompiles this module against the checkout it is built from and the
  stamp is fresh in the shipped bytes. Git absence at compile time is a loud
  build failure here, not a runtime guess: the `{out, 0}` match refuses a stamp
  it cannot compute rather than shipping one that lies.
  """

  @build (
           {out, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"])
           out |> String.trim() |> String.to_integer()
         )

  @sha (
         {out, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"])
         String.trim(out)
       )

  @doc "The build number (`git rev-list --count HEAD`) stamped at compile time."
  @spec build() :: non_neg_integer()
  def build, do: @build

  @doc "The short commit sha stamped at compile time."
  @spec sha() :: String.t()
  def sha, do: @sha
end
