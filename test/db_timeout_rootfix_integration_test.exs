defmodule Tightbeam.DBTimeoutRootfixIntegrationTest do
  use Tightbeam.TestCase, async: false

  @tag :tmp_dir
  test "boot and runtime components progress while publication is open", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "db_timeout_rootfix_integration_runtime.exs",
      "db-timeout-rootfix-integration: ok"
    )
  end
end
