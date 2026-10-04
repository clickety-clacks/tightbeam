defmodule Tightbeam.OnboardWireTest do
  use Tightbeam.TestCase, async: false
  @moduletag :tmp_dir

  test "cold payload handles onboarding wire spellings without credential access", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "onboard_wire_runtime.exs",
      "onboard-wire-supported-unsupported-actor: ok"
    )
  end
end
