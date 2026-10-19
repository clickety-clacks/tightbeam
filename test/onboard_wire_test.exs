defmodule Tightbeam.OnboardWireTest do
  use Tightbeam.TestCase, async: false
  @moduletag :tmp_dir

  test "onboarding wire preserves cold refusals and reports a successful finish", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "onboard_wire_runtime.exs",
      "onboard-wire-supported-unsupported-actor: ok"
    )
  end
end
