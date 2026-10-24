defmodule Tightbeam.BaseDir do
  @moduledoc """
  The single resolver for `base_dir` — where the org lives.

  There were four of these, and they did not agree:

    * `mix tightbeam.init` read `TIGHTBEAM_HOME` only
    * the gateway (`config/runtime.exs`) read `TIGHTBEAM_BASE_DIR` only
    * `mix tightbeam.catalog_diff` read both, in the right order
    * `Tightbeam.Application` read neither, defaulting bare

  So install-time and runtime resolved `base_dir` differently from the same
  environment. With `TIGHTBEAM_BASE_DIR` set, initialization and the running
  service could select different directories, making a successful initialization
  message misleading or causing later commands to contact the wrong gateway.

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
