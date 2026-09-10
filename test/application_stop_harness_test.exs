defmodule Tightbeam.ApplicationStopHarnessTest do
  use Tightbeam.TestCase, async: false

  @moduletag :tmp_dir

  test "Application.stop runs the harness park and detached-descendant floor", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "application_stop_harness_runtime.exs",
      "application-stop-harness-cleanup: ok"
    )
  end
end
