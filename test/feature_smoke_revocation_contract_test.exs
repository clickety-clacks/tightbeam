defmodule Tightbeam.FeatureSmokeRevocationContractTest do
  use ExUnit.Case, async: true

  test "removed effort-check-in smoke is absent and no cross-run sweep is invoked" do
    source = File.read!(Path.expand("../scripts/feature_smoke.exs", __DIR__))
    ast = Code.string_to_quoted!(source)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:ok!, _, [_state, "revoke-assignment", {:%{}, _, fields}]} = node, calls ->
          {node, [fields | calls]}

        node, calls ->
          {node, calls}
      end)

    assert calls == []
    refute String.contains?(source, "check_effort_without_effect")
    refute String.contains?(source, "Effort smoke")
    refute String.contains?(source, "effort check-in")

    refute String.contains?(source, "sweep_open_work_items")
    refute String.contains?(source, "clear_previous_leg_work_items")
    refute String.contains?(source, "work-item-list")
  end
end
