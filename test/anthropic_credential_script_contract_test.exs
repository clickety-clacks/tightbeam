defmodule Tightbeam.AnthropicCredentialScriptContractTest do
  use ExUnit.Case, async: true

  test "local provision smoke projects Claude Code's credential filename" do
    source = File.read!(Path.expand("../scripts/local_provision_smoke.exs", __DIR__))

    assert source =~ ".credentials.json"
    refute source =~ "oauth-token"
  end

  test "the harness seam checker tracks Claude Code's credential filename" do
    source = File.read!(Path.expand("../scripts/check_harness_seam.sh", __DIR__))

    assert source =~ ~S(\.credentials\.json)
    refute source =~ "oauth-token"
  end
end
