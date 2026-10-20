defmodule Tightbeam.Harness.SupportTest do
  use Tightbeam.TestCase, async: true

  alias Tightbeam.Harness.Support

  test "satellite catalog command failures identify command-version mismatches" do
    for {output, host} <- [
          {"unknown command: catalog-probe\n", "satellite-east"},
          {"usage: tightbeam catalog-probe <provider> <kind>\n", "satellite-west"}
        ] do
      assert {:error, {:satellite_command_version_mismatch, ^host, "catalog-probe"}} =
               Support.catalog_probe(fn _argv -> {output, 2} end, ["ssh", "satellite"], host)
    end
  end

  test "local catalog failures keep the existing probe-failure result" do
    assert {:error, {:probe_failed, 2, "unknown command: catalog-probe"}} =
             Support.catalog_probe(
               fn _argv -> {"unknown command: catalog-probe\n", 2} end,
               ["sh", "-c", "tightbeam catalog-probe"]
             )
  end
end
