defmodule Tightbeam.FeatureSmokeRevocationContractTest do
  use ExUnit.Case, async: true

  test "fixture revocations are reasoned and no cross-run sweep is invoked" do
    source = File.read!(Path.expand("../scripts/feature_smoke.exs", __DIR__))
    ast = Code.string_to_quoted!(source)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:ok!, _, [_state, "revoke-assignment", {:%{}, _, fields}]} = node, calls ->
          {node, [fields | calls]}

        node, calls ->
          {node, calls}
      end)

    # The cannot-proceed duplicate moved to its decisions-runbook owner.
    assert length(calls) == 2

    reasons =
      Enum.map(calls, fn fields ->
        assert List.keyfind(fields, "assignmentId", 0)
        assert {"reason", reason} = List.keyfind(fields, "reason", 0)
        assert is_binary(reason)
        assert String.trim(reason) != ""
        assert length(String.to_charlist(reason)) in 1..2000
        reason
      end)

    expected_reasons = [
      "Effort smoke replaces the first assignment to verify request supersession",
      "Effort smoke completed the replacement assignment checks"
    ]

    assert Enum.sort(reasons) == Enum.sort(expected_reasons)

    {_, revocation_scopes} =
      Macro.prewalk(ast, [], fn
        {:defp, _, [{name, _, _args}, body]} = node, scopes ->
          {_, scoped_calls} =
            Macro.prewalk(body, [], fn
              {:ok!, _, [_state, "revoke-assignment", _payload]} = call, scoped_calls ->
                {call, [call | scoped_calls]}

              node, scoped_calls ->
                {node, scoped_calls}
            end)

          scopes = if scoped_calls == [], do: scopes, else: [name | scopes]
          {node, scopes}

        node, scopes ->
          {node, scopes}
      end)

    assert Enum.sort(revocation_scopes) == [:check_effort_without_effect]

    refute String.contains?(source, "sweep_open_work_items")
    refute String.contains?(source, "clear_previous_leg_work_items")
    refute String.contains?(source, "work-item-list")
  end
end
