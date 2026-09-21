defmodule Tightbeam.FirehoseSmokeTest do
  use Tightbeam.TestCase, async: false
  @tag :tmp_dir
  @tag timeout: 120_000
  test "authoritative production rebuild closes the current Registry both ways", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_inventory_runtime.exs",
      "guarded-firehose-inventory: ok"
    )
  end
end
