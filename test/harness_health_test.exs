defmodule Tightbeam.HarnessHealthTest do
  use ExUnit.Case, async: true

  alias Tightbeam.HarnessHealth

  defmodule CatalogStub do
    use GenServer

    def start_link(answer), do: GenServer.start_link(__MODULE__, answer)
    def init(answer), do: {:ok, answer}
    def handle_call({:get, _key}, _from, answer), do: {:reply, answer, answer}
  end

  test "fresh capability data distinguishes populated and healthy empty inventories" do
    {:ok, populated} = CatalogStub.start_link({[%{family: "one"}], :fresh})
    {:ok, empty} = CatalogStub.start_link({[], :fresh})

    assert %{
             credentialHealth: "healthy",
             catalogHealth: "healthy",
             modelCount: 1,
             failureReason: nil,
             remediation: nil
           } = HarnessHealth.report("gibson", "codex", populated)

    assert %{
             credentialHealth: "healthy",
             catalogHealth: "healthyEmpty",
             modelCount: 0,
             failureReason: nil,
             remediation: nil
           } = HarnessHealth.report("gibson", "codex", empty)
  end

  test "an unonboarded credential names its host, reason, and bounded remedy" do
    {:ok, catalog} =
      CatalogStub.start_link({[], {:unavailable, {:needs_onboarding, :missing}}})

    assert %{
             host: "eezo",
             harness: "claude",
             provider: "anthropic",
             credentialHealth: "needsOnboarding",
             catalogHealth: "unavailable",
             failureReason: "missing",
             remediation: remedy
           } = HarnessHealth.report("eezo", "claude", catalog)

    assert remedy == "Run on eezo: tightbeam onboard anthropic --as-user <userId>."
  end

  test "catalog failures do not expose provider response bodies or prescribe onboarding" do
    {:ok, catalog} =
      CatalogStub.start_link({[], {:unavailable, {:http_status, 500, "secret response"}}})

    report = HarnessHealth.report("gibson", "codex", catalog)
    assert report.credentialHealth == "unknown"
    assert report.failureReason == "http_status_500"
    assert report.remediation =~ "Retry the catalog refresh"
    refute inspect(report) =~ "secret response"
    refute report.remediation =~ "onboard"
  end

  test "a completed ceremony reports the credential as healthy while refresh is pending" do
    {:ok, catalog} = CatalogStub.start_link({[], {:unavailable, :not_derived}})

    assert %{
             credentialHealth: "healthy",
             catalogHealth: "pending",
             failureReason: "not_derived",
             remediation: remediation
           } =
             HarnessHealth.report("gibson", "codex", catalog, credential_status: :onboarded)

    assert remediation =~ "Wait for the catalog refresh"
  end
end
