defmodule Tightbeam.PackageSoakTest do
  use ExUnit.Case, async: true

  @checks Path.expand("../scripts/support/package_soak_checks.py", __DIR__)

  test "package identity, workload evidence boundaries and sustained drift detectors" do
    python =
      System.find_executable("python3") || flunk("python3 is required for package-soak checks")
    {output, status} = System.cmd(python, ["-I", @checks], stderr_to_stdout: true)
    assert status == 0, output
  end
end
