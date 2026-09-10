defmodule Tightbeam.FeatureSmokeRevocationContractTest do
  use ExUnit.Case, async: true

  test "all provider-smoke revocations supply the reason contract without running the smoke" do
    source = File.read!(Path.expand("../scripts/feature_smoke.exs", __DIR__))
    ast = Code.string_to_quoted!(source)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:ok!, _, [_state, "revoke-assignment", {:%{}, _, fields}]} = node, calls ->
          {node, [fields | calls]}

        node, calls ->
          {node, calls}
      end)

    assert length(calls) == 3

    reasons =
      Enum.map(calls, fn fields ->
        assert List.keyfind(fields, "assignmentId", 0)
        assert {"reason", reason} = List.keyfind(fields, "reason", 0)
        assert is_binary(reason)
        assert String.trim(reason) != ""
        assert length(String.to_charlist(reason)) in 1..2000
        reason
      end)

    assert Enum.sort(reasons) ==
             Enum.sort([
               "Effort smoke replaces the first assignment to verify request supersession",
               "Effort smoke completed the replacement assignment checks",
               "Smoke setup clears an open assignment left by a previous run"
             ])
  end
end
