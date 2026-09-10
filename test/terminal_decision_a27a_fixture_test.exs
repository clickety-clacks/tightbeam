defmodule Tightbeam.TerminalDecisionA27aFixtureTest do
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "fixtures/terminal_decision_parity/a27a-019")
  @baseline_commit "3125dfb6df4f1ab62c82e77fb93694eb1ad5015b"
  @candidate_commit "cabce9b12917dcf0a1552f729d70d98cdd2b8ee2"
  @spec_commit "f3b15654ca8880dd147a0fbe41a770a1c8570727"
  @spec_sha256 "7a0affca1a550eb23bd6be0b331e8107bb6e85825d2496f207ba40042684187c"
  @route_command ~s(rg -n '^[[:space:]]*get "/api/decision-requests' lib/tightbeam/wire/router.ex)
  @nonterminal ~w(openDetail withdrawnDetail supersededDetail)
  @terminal_parity ~w(status decision rationale ruledAt ruledBy ruledViaSessionKey rulingFactId rulingAttribution)

  setup_all do
    manifest = fixture("manifest.json")
    baseline = fixture(manifest["baseline"]["fixture"])
    candidate = fixture(manifest["candidate"]["fixture"])
    {:ok, manifest: manifest, baseline: baseline, candidate: candidate}
  end

  test "manifest binds the reviewed REST-absent arm to real predecessor and candidate bytes",
       ctx do
    assert ctx.manifest["proofArm"] == "rest-absent"
    assert ctx.manifest["specCommit"] == @spec_commit
    assert ctx.manifest["specFileSha256"] == @spec_sha256
    assert ctx.manifest["routeInventoryCommand"] == @route_command
    assert ctx.manifest["gatewayInvocation"]["route"] == "/agent/dispatch"
    assert ctx.manifest["fixtureSetupPath"] == "test/support/terminal_decision_a27a_capture.exs"

    for {arm, capture, commit} <- [
          {"baseline", ctx.baseline, @baseline_commit},
          {"candidate", ctx.candidate, @candidate_commit}
        ] do
      entry = ctx.manifest[arm]
      assert capture["proofArm"] == "rest-absent"
      assert capture["sourceCommit"] == commit
      assert capture["specFileSha256"] == @spec_sha256
      assert capture["fixtureSetupPath"] == ctx.manifest["fixtureSetupPath"]
      assert capture["gatewayInvocation"] == ctx.manifest["gatewayInvocation"]
      assert capture["builtCli"]["sha256"] == entry["builtCliSha256"]
      assert capture["builtCli"]["version"] == "0.1.8"
      assert sha256(entry["fixture"]) == entry["fixtureSha256"]

      assert capture["routeInventory"] == %{
               "command" => @route_command,
               "exitStatus" => 1,
               "routes" => [],
               "stdout" => ""
             }
    end
  end

  test "gateway bytes preserve nonterminal compatibility and terminal list/detail parity", ctx do
    for name <- @nonterminal do
      baseline = gateway_row(ctx.baseline, name)
      candidate = gateway_row(ctx.candidate, name)

      assert Map.keys(candidate) |> Enum.sort() == Map.keys(baseline) |> Enum.sort()
      refute Map.has_key?(candidate, "ruledViaPrincipal")
      refute Map.has_key?(candidate, "ruledViaSessionState")
      refute Map.has_key?(candidate, "rulingAttribution")
    end

    detail = gateway_row(ctx.candidate, "ruledDetail")

    list_row =
      ctx.candidate
      |> gateway_body("ruledList")
      |> get_in(["result", "decisionRequests"])
      |> Enum.find(&(&1["id"] == detail["id"]))

    assert is_map(list_row)

    for key <- @terminal_parity do
      assert list_row[key] == detail[key]
    end

    assert detail["status"] == "ruled"
    assert detail["rulingAttribution"]["onBehalfOf"] == "user:capture-owner"

    assert detail["rulingAttribution"]["performer"]["principal"] == %{
             "state" => "known",
             "value" => "user:capture-owner"
           }

    assert detail["rulingAttribution"]["performer"]["session"] == %{"state" => "none"}

    for capture <- [ctx.baseline, ctx.candidate], {name, response} <- capture["gateway"] do
      assert is_integer(response["status"]), name
      assert JSON.encode!(JSON.decode!(response["body"])) == response["body"], name
    end
  end

  test "built candidate CLI uses one canonical carrier and rejects malformed shapes locally",
       ctx do
    ruled = ctx.candidate["cli"]["ruledDetail"]
    ruled_id = ctx.candidate["fixtureIds"]["ruled"]

    assert ruled["exitStatus"] == 0
    assert ruled["stderr"] == ""
    assert get_in(JSON.decode!(ruled["stdout"]), ["decisionRequest", "id"]) == ruled_id

    assert ruled["wireRequests"] == [
             %{"verb" => "decision-request", "params" => %{"request" => ruled_id}}
           ]

    for {name, result} <- ctx.candidate["cli"]["parser"] do
      assert result["exitStatus"] != 0, name
      assert result["stdout"] == "", name
      assert result["wireRequests"] == [], name
    end

    assert length(ctx.baseline["cli"]["parser"]["prefix"]["wireRequests"]) == 1
    assert length(ctx.baseline["cli"]["parser"]["duplicate"]["wireRequests"]) == 1
  end

  test "complete unknown and nonvisible IDs remain indistinguishable", ctx do
    for capture <- [ctx.baseline, ctx.candidate], name <- ~w(unknownDetail nonvisibleDetail) do
      gateway = capture["gateway"][name]
      cli = capture["cli"][name]

      assert gateway["status"] == 404

      assert JSON.decode!(gateway["body"]) == %{
               "error" => %{
                 "code" => "not_found",
                 "message" => "decision request not found"
               }
             }

      assert cli["exitStatus"] != 0
      assert cli["stdout"] == ""
      assert cli["stderr"] == "not_found: decision request not found\n"

      assert [%{"verb" => "decision-request", "params" => %{"request" => _}}] =
               cli["wireRequests"]
    end

    assert ctx.candidate["integrityEvidence"]["hidden"] == 0
  end

  test "impossible shapes fail list, detail, and CLI without partial results", ctx do
    impossible_id = ctx.candidate["fixtureIds"]["impossible"]

    for name <- ~w(impossibleList impossibleDetail) do
      response = ctx.candidate["gateway"][name]
      body = JSON.decode!(response["body"])

      assert response["status"] == 500
      refute Map.has_key?(body, "result")

      assert body == %{
               "error" => %{
                 "code" => "decision_request_integrity_invalid",
                 "message" => "decision request integrity check failed",
                 "requestId" => impossible_id
               }
             }
    end

    cli = ctx.candidate["cli"]["impossibleDetail"]
    assert cli["exitStatus"] != 0
    assert cli["stdout"] == ""

    assert cli["stderr"] ==
             "decision_request_integrity_invalid: decision request integrity check failed (#{impossible_id})\n"

    assert cli["wireRequests"] == [
             %{"verb" => "decision-request", "params" => %{"request" => impossible_id}}
           ]

    assert ctx.candidate["integrityEvidence"] == %{
             "supported" => true,
             "hidden" => 0,
             "impossible" => 1
           }

    assert ctx.baseline["gateway"]["impossibleList"]["status"] == 200
    assert ctx.baseline["gateway"]["impossibleDetail"]["status"] == 200
    assert ctx.baseline["integrityEvidence"] == %{"supported" => false}
  end

  defp fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> JSON.decode!()
  end

  defp gateway_body(capture, name), do: JSON.decode!(capture["gateway"][name]["body"])

  defp gateway_row(capture, name) do
    capture
    |> gateway_body(name)
    |> get_in(["result", "decisionRequest"])
  end

  defp sha256(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
