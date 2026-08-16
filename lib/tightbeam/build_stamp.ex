defmodule Tightbeam.BuildStamp do
  @moduledoc """
  The compile-time build identity a running gateway reports at `/version`.

  A running gateway must state which bytes it is (builds-identify-bytes). The
  release version alone cannot: many builds carry the same version. The build
  number is `git rev-list --count HEAD` and the sha is `git rev-parse --short
  HEAD`, both captured HERE, at compile time — the shipped gateway carries no
  toolchain and no `.git`, so neither can be read at runtime. This matches the
  version stamp's own compile-time home in `Tightbeam.CliCompatibility`.

  Every real release is assembled with full git history: `packaging/assemble.sh`
  runs under an `actions/checkout` with `fetch-depth: 0` (release-candidate.yml,
  ci.yml), and its `mix clean` before `mix release` forces this module to
  recompile, so the stamp is fresh and accurate in the shipped bytes. A build
  with no reachable git history — a source tree divorced from `.git`, e.g. the
  `git archive` isolation `release_candidate_workflow_test` runs `assemble.sh`
  in — genuinely cannot know its count; it reports `nil` rather than fabricating
  a number or crashing the compile. A missing stamp is surfaced as unknown,
  never inferred.
  """

  @build (case System.cmd("git", ["rev-list", "--count", "HEAD"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.trim() |> String.to_integer()
            {_out, _nonzero} -> nil
          end)

  @sha (case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          {_out, _nonzero} -> nil
        end)

  @doc "The build number (`git rev-list --count HEAD`) stamped at compile time, or nil if built without reachable git history."
  @spec build() :: non_neg_integer() | nil
  def build, do: @build

  @doc "The short commit sha stamped at compile time, or nil if built without reachable git history."
  @spec sha() :: String.t() | nil
  def sha, do: @sha
end
