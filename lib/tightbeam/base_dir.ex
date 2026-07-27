defmodule Tightbeam.BaseDir do
  @moduledoc """
  The single resolver for `base_dir` — where the org lives.

  There were four of these, and they did not agree:

    * `mix tightbeam.init` read `TIGHTBEAM_HOME` only
    * the gateway (`config/runtime.exs`) read `TIGHTBEAM_BASE_DIR` only
    * `mix tightbeam.catalog_diff` read both, in the right order
    * `Tightbeam.Application` read neither, defaulting bare

  So install-time and runtime resolved `base_dir` DIFFERENTLY FROM THE SAME
  ENVIRONMENT. With `TIGHTBEAM_BASE_DIR` set, `mix tightbeam.init` wrote the
  identity repo into `~/.tightbeam` and reported success, while the service
  booted against the requested directory with no identity repo in it — and if
  `~/.tightbeam` already held an unrelated org, init no-op'd against it and
  printed "already initialized", which reads as confirmation that the new
  install is ready when nothing was done. Found on shrdlu, 2026-07-27, by the
  production-install smoke, where it silently targeted a live unrelated org.

  Precedence, matching what the README documents and what `catalog_diff`
  already did:

    1. `TIGHTBEAM_BASE_DIR` — selects the org for a single run
    2. `TIGHTBEAM_HOME`
    3. `<user home>/.tightbeam`

  Every caller uses this. A second resolver is a bug, not a shortcut: the two
  halves of one install must never be able to disagree about where the org is.
  """

  @doc "Resolve `base_dir` from the environment, honouring both variables."
  @spec resolve() :: String.t()
  def resolve do
    System.get_env("TIGHTBEAM_BASE_DIR") ||
      System.get_env("TIGHTBEAM_HOME") ||
      default()
  end

  @doc "The default when neither variable is set."
  @spec default() :: String.t()
  def default, do: Path.join(System.user_home!(), ".tightbeam")
end
