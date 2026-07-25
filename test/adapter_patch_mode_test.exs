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
end
