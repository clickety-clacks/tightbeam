defmodule Tightbeam.AdapterPatchModeTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Tightbeam.Harness.AdapterPatch

  # Regression: ensure! once hardcoded chmod 0o644 on the patched bundle. npm marks
  # bin-target bundles executable and node_modules/.bin symlinks exec them directly,
  # so the stripped x-bit broke every codex adapter spawn with Permission denied
  # (found live on the codex smoke leg, 2026-07-25). The write must preserve the
  # bundle's own mode.
  test "ensure! preserves the executable bit on a patched bin-target bundle" do
    root = Path.join(System.tmp_dir!(), "tb-patch-mode-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    package_dir = Path.join([root, "node_modules", "@agentclientprotocol", "smoke-acp"])
    bin_dir = Path.join([root, "node_modules", ".bin"])
    dist_dir = Path.join(package_dir, "dist")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(dist_dir)

    File.write!(Path.join(package_dir, "package.json"), ~s({"version":"9.9.9"}))
    bundle = Path.join(dist_dir, "index.js")
    File.write!(bundle, "#!/usr/bin/env node\nBEFORE_ANCHOR\n")
    File.chmod!(bundle, 0o755)
    binary_path = Path.join(bin_dir, "smoke-acp")

    assert :ok =
             AdapterPatch.ensure!(
               binary_path,
               "smoke-acp",
               "index.js",
               "9.9.9",
               [{"BEFORE_ANCHOR", "AFTER_ANCHOR"}],
               "smoke"
             )

    assert File.read!(bundle) =~ "AFTER_ANCHOR"
    assert %File.Stat{mode: mode} = File.stat!(bundle)
    assert band(mode, 0o111) != 0, "patch write stripped the execute bit"
  end

  test "an unknown installed version warns and continues unpatched" do
    root = Path.join(System.tmp_dir!(), "tb-patch-version-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    {binary_path, bundle} = stage_adapter(root, "10.0.0")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 AdapterPatch.ensure!(
                   binary_path,
                   "smoke-acp",
                   "index.js",
                   "9.9.9",
                   [{"BEFORE_ANCHOR", "AFTER_ANCHOR"}],
                   "smoke"
                 )
      end)

    assert File.read!(bundle) =~ "BEFORE_ANCHOR"
    refute File.read!(bundle) =~ "AFTER_ANCHOR"
    assert log =~ "smoke adapter patch skipped: expected version 9.9.9, found 10.0.0"
    assert log =~ "continuing with the installed adapter unpatched"
  end

  test "the remote patch script exits successfully on an unknown installed version" do
    root = Path.join(System.tmp_dir!(), "tb-remote-patch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    {binary_path, bundle} = stage_adapter(root, "10.0.0")

    script =
      AdapterPatch.remote_script(
        binary_path,
        "smoke-acp",
        "index.js",
        "9.9.9",
        [{"BEFORE_ANCHOR", "AFTER_ANCHOR"}],
        "smoke"
      )

    assert {output, 0} = System.cmd("node", ["-e", script], stderr_to_stdout: true)
    assert output =~ "smoke adapter patch skipped: expected version 9.9.9, found 10.0.0"
    assert File.read!(bundle) =~ "BEFORE_ANCHOR"
    refute File.read!(bundle) =~ "AFTER_ANCHOR"
  end

  defp stage_adapter(root, version) do
    package_dir = Path.join([root, "node_modules", "@agentclientprotocol", "smoke-acp"])
    bin_dir = Path.join([root, "node_modules", ".bin"])
    dist_dir = Path.join(package_dir, "dist")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(dist_dir)

    File.write!(Path.join(package_dir, "package.json"), JSON.encode!(%{"version" => version}))
    bundle = Path.join(dist_dir, "index.js")
    File.write!(bundle, "#!/usr/bin/env node\nBEFORE_ANCHOR\n")
    File.chmod!(bundle, 0o755)

    {Path.join(bin_dir, "smoke-acp"), bundle}
  end
end
