defmodule Tightbeam.TerminalDecisionResponseFixtureTest do
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "fixtures/terminal_decision_parity")
  @classes ~w(open ruled withdrawn superseded legacy hidden impossibleConsumed)
  @nonterminal ~w(open withdrawn superseded)

  test "checked-in terminal decision fixtures are canonical real gateway captures" do
    baseline = fixture("baseline-3125dfb6.json")
    candidate = fixture("candidate-3246e167.json")

    assert baseline["sourceCommit"] == "3125dfb6df4f1ab62c82e77fb93694eb1ad5015b"
    assert candidate["sourceCommit"] == "3246e167781957c4d39e4fb9eea1c71f9bd94fca"

    assert baseline["captureTransport"] ==
             "real Tightbeam.Wire.Router /agent/dispatch with real Gateway handlers"

    assert candidate["captureTransport"] == baseline["captureTransport"]
    assert Enum.sort(Map.keys(baseline["responses"])) == Enum.sort(@classes)
    assert Enum.sort(Map.keys(candidate["responses"])) == Enum.sort(@classes)

    for capture <- [baseline, candidate], class <- @classes do
      %{"status" => status, "body" => body} = capture["responses"][class]
      assert is_integer(status)
      assert JSON.encode!(JSON.decode!(body)) == body
    end
  end

  test "candidate nonterminal detail bytes retain the complete predecessor key set" do
    baseline = fixture("baseline-3125dfb6.json")
    candidate = fixture("candidate-3246e167.json")

    for class <- @nonterminal do
      baseline_row = response_row(baseline, class)
      candidate_row = response_row(candidate, class)

      assert Enum.sort(Map.keys(candidate_row)) == Enum.sort(Map.keys(baseline_row))
      assert candidate_row["status"] == class
      refute Map.has_key?(candidate_row, "ruledViaPrincipal")
      refute Map.has_key?(candidate_row, "ruledViaSessionState")
      refute Map.has_key?(candidate_row, "rulingAttribution")
    end
  end

  test "candidate fixture records the reviewed terminal visibility and integrity deltas" do
    baseline = fixture("baseline-3125dfb6.json")
    candidate = fixture("candidate-3246e167.json")

    assert baseline["responses"]["hidden"]["status"] == 200
    assert candidate["responses"]["hidden"]["status"] == 404

    assert JSON.decode!(candidate["responses"]["hidden"]["body"]) == %{
             "error" => %{
               "code" => "not_found",
               "message" => "decision request not found"
             }
           }

    assert baseline["responses"]["impossibleConsumed"]["status"] == 200
    assert candidate["responses"]["impossibleConsumed"]["status"] == 500

    assert %{
             "error" => %{
               "code" => "decision_request_integrity_invalid",
               "message" => "decision request integrity check failed",
               "requestId" => "dr_" <> _
             }
           } = JSON.decode!(candidate["responses"]["impossibleConsumed"]["body"])

    ruled = response_row(candidate, "ruled")
    assert ruled["status"] == "ruled"
    assert ruled["consumedAt"] == nil
    assert ruled["rulingAttribution"]["performer"]["principal"]["state"] == "known"
    assert ruled["rulingAttribution"]["performer"]["session"] == %{"state" => "none"}

    legacy = response_row(candidate, "legacy")

    assert legacy["rulingAttribution"]["performer"] == %{
             "principal" => %{"state" => "legacy-unknown"},
             "session" => %{"state" => "legacy-unknown"}
           }
  end

  defp fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> JSON.decode!()
  end

  defp response_row(capture, class) do
    capture["responses"][class]["body"]
    |> JSON.decode!()
    |> get_in(["result", "decisionRequest"])
  end
end
