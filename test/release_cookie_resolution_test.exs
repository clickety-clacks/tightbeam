defmodule Tightbeam.ReleaseCookieResolutionTest do
  # F2 (R4) proven against the REAL mix-generated release launcher — not a model.
  #
  # The generated launcher resolves the Erlang distribution cookie
  # (`RELEASE_COOKIE="${RELEASE_COOKIE:-"$(cat releases/COOKIE)"}"`) and EXPORTS
  # it, so `<launcher> eval` reading the exported RELEASE_COOKIE observes the
  # EFFECTIVE cookie the debug verbs (rpc/remote) would use — without a peer
  # node. Together with the committed shim stripping RELEASE_COOKIE on the
  # rpc/remote path (isolated_lifecycle_isolation_test.exs), this proves the end
  # state R4 requires: rpc/remote use this install's BAKED cookie, and an
  # inherited/ambient RELEASE_COOKIE cannot override it.
  #
  # Builds the real release ONCE in setup_all (~10s). Kept in the default gate on
  # purpose: a proof against reality has to actually run to count.
  use Tightbeam.TestCase, async: false

  @moduletag :release_build

  setup_all do
    mix = System.find_executable("mix") || "mix"

    release_dir =
      Path.join(System.tmp_dir!(), "tb-real-release-#{System.unique_integer([:positive])}")

    {out, status} =
      System.cmd(mix, ["release", "--overwrite", "--path", release_dir],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix release failed:\n#{out}"

    launcher = Path.join(release_dir, "bin/tightbeam_gateway")
    baked = release_dir |> Path.join("releases/COOKIE") |> File.read!() |> String.trim()
    assert baked != "", "the built release has no baked releases/COOKIE"

    on_exit(fn -> File.rm_rf!(release_dir) end)

    %{launcher: launcher, baked: baked}
  end

  # The cookie the REAL launcher resolves and exports, for the given child env.
  defp resolved_cookie(launcher, env) do
    expr = ~s{IO.puts("TBCOOKIE=" <> (System.get_env("RELEASE_COOKIE") || "nil"))}

    {out, status} =
      System.cmd(launcher, ["eval", expr], env: env, stderr_to_stdout: true)

    assert status == 0, out
    [cookie] = Regex.run(~r/^TBCOOKIE=(.*)$/m, out, capture: :all_but_first)
    cookie
  end

  test "the real launcher uses the baked releases/COOKIE when RELEASE_COOKIE is unset (the shim-scrubbed state)",
       %{launcher: launcher, baked: baked} do
    assert resolved_cookie(launcher, [{"RELEASE_COOKIE", nil}]) == baked
  end

  test "the real launcher prefers an inherited RELEASE_COOKIE — which is exactly why the shim must strip it",
       %{launcher: launcher, baked: baked} do
    resolved = resolved_cookie(launcher, [{"RELEASE_COOKIE", "synthetic-foreign-cookie"}])
    assert resolved == "synthetic-foreign-cookie"
    refute resolved == baked
  end
end
