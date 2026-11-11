defmodule Tightbeam.HarnessAdapterPatchTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, Codex}

  test "codex patch carries identity, account, and child-thread settlement idempotently" do
    source =
      [
        "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd\n",
        "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n",
        "      case \"account/updated\":\n      case \"fs/changed\":",
        "  activeSubAgentActivities = /* @__PURE__ */ new Set();\n",
        "      case \"thread/status/changed\":\n        return this.createCodexSessionInfoUpdate({\n          threadStatus: notification.params.status\n        });",
        "      case \"subAgentActivity\":\n        this.activeSubAgentActivities.add(event.item.id);\n        return createSubAgentActivityUpdate(event.item, \"in_progress\", \"tool_call\");"
      ]
      |> Enum.join("\n")

    patched = Codex.patch_adapter_source(source)
    assert patched =~ "developerInstructions: request._meta?.developerInstructions"
    assert patched =~ "accountUpdated: notification.params"
    assert patched =~ "subAgentActivityCallIds"
    assert patched =~ "subagentTerminated"
    assert patched =~ ~s(["idle", "systemError", "notLoaded"])
    assert Codex.patch_adapter_source(patched) == patched
  end

  test "claude probe patch preserves status and emits redacted process provenance idempotently" do
    source = adapter_probe_body()

    patched = Claude.patch_adapter_source(source)
    assert patched =~ "incomplete-positive-login"
    assert patched =~ "return this.currentAuthStatus"
    assert patched =~ "apiKeySourcePresent: false"
    assert patched =~ "subscriptionTypePresent: false"

    assert patched =~
             ~s(executableSource: process.env.CLAUDE_CODE_EXECUTABLE ? "override" : "bundled")

    assert patched =~ ~s(binding: "process-observed")
    assert patched =~ "tightbeam: { probeBinding: binding }"
    refute patched =~ "CLAUDE_CODE_EXECUTABLE:"
    assert Claude.patch_adapter_source(patched) == patched
  end

  test "T23 positive-login-missing-plan stays indeterminate" do
    patched = Claude.patch_auth_status_source(auth_status_source())
    assert run_mapper(patched, %{loggedIn: true, apiProvider: "firstParty"}) == :undefined

    assert run_mapper(patched, %{
             loggedIn: true,
             apiProvider: "firstParty",
             subscriptionType: ""
           }) == :undefined

    assert Claude.patch_auth_status_source(patched) == patched

    input = %{loggedIn: true, apiProvider: "firstParty"}
    no_prior = run_probe(input, nil)
    assert no_prior["current"] == nil
    assert no_prior["result"] == nil
    assert no_prior["notifications"] == []
    assert [diagnostic] = no_prior["logs"]
    assert diagnostic =~ "incomplete-positive-login"
    assert diagnostic =~ ~s("subscriptionTypePresent":false)
    refute diagnostic =~ JSON.encode!(input)

    prior = %{"kind" => "account", "label" => "Claude Max", "account" => %{"plan" => "max"}}
    with_prior = run_probe(input, prior)
    assert with_prior["current"] == prior
    assert with_prior["result"] == prior
    assert with_prior["notifications"] == []
  end

  test "T24 positive-login-max preserves the exact account payload" do
    patched = Claude.patch_auth_status_source(auth_status_source())

    assert run_mapper(patched, %{
             loggedIn: true,
             apiProvider: "firstParty",
             subscriptionType: "max"
           }) == %{
             "kind" => "account",
             "label" => "Claude Max",
             "account" => %{"plan" => "max"}
           }
  end

  test "T25 executable-binding provenance is process observed or unknown" do
    assert Claude.probe_binding_provenance(process_observed: true, override_present: false) == %{
             acp_version: "0.81.0",
             sdk_wrapper_version: "0.3.280",
             native_package_version: "0.3.280",
             bundled_claude_version: "2.1.280",
             executable_source: "bundled",
             binding: "process-observed"
           }

    sentinel = "/secret/override/claude"

    override =
      Claude.probe_binding_provenance(process_observed: true, override_present: true)

    assert override.executable_source == "override"
    refute inspect(override) =~ sentinel

    event = %{
      "authStatus" => %{
        "_meta" => %{
          "tightbeam" => %{
            "probeBinding" => %{
              "binding" => "process-observed",
              "executableSource" => "override",
              "overrideValue" => sentinel,
              "acpVersion" => "untrusted"
            }
          }
        }
      }
    }

    diagnostic = Claude.probe_binding_diagnostic(event)
    assert diagnostic =~ "source=override"
    assert diagnostic =~ "acp=0.81.0"
    refute diagnostic =~ sentinel
    refute diagnostic =~ "untrusted"

    assert Claude.probe_binding_provenance(historical: true) == %{
             acp_version: nil,
             sdk_wrapper_version: nil,
             native_package_version: nil,
             bundled_claude_version: nil,
             executable_source: "unknown",
             binding: "unobserved"
           }

    assert Claude.probe_binding_diagnostic(%{"authStatus" => %{}}) ==
             "probe-binding unobserved source=unknown"
  end

  defp auth_status_source do
    """
    function notLoggedInAuthStatus() { return {kind: "none", label: "Not logged in"}; }
    function mapAuthFields(fields) {
      if (fields.subscriptionType) {
        return {kind: "account", label: "Claude " + fields.subscriptionType[0].toUpperCase() + fields.subscriptionType.slice(1), account: {plan: fields.subscriptionType}};
      }
      return notLoggedInAuthStatus();
    }
    export function fromCliStatus(stdout) {
        let parsed;
        try { parsed = JSON.parse(stdout); } catch { return undefined; }
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
        const status = parsed;
        if (typeof status.loggedIn !== "boolean") return undefined;
        const externalBackend = Boolean(status.apiProvider && status.apiProvider !== "firstParty");
        if (!externalBackend && !status.loggedIn && !status.apiKeySource) return notLoggedInAuthStatus();
        return mapAuthFields({
            apiProvider: status.apiProvider,
            subscriptionType: status.subscriptionType,
            apiKeySource: status.apiKeySource,
            email: status.email,
            organization: status.orgName,
        });
    }
    console.log(JSON.stringify(fromCliStatus(process.argv[2])));
    """
  end

  defp run_mapper(source, input) do
    path = Path.join(System.tmp_dir!(), "claude-auth-mapper-#{System.unique_integer()}.mjs")
    File.write!(path, source)

    try do
      {output, 0} = System.cmd("node", [path, JSON.encode!(input)])

      case String.trim(output) do
        "undefined" -> :undefined
        json -> JSON.decode!(json)
      end
    after
      File.rm(path)
    end
  end

  defp run_probe(input, prior) do
    source =
      auth_status_source()
      |> String.replace(
        "console.log(JSON.stringify(fromCliStatus(process.argv[2])));",
        """
        function mergeAuthStatus(_current, status) { return status; }
        class Probe {
          constructor(currentAuthStatus) {
            this.currentAuthStatus = currentAuthStatus;
            this.notifications = [];
            this.logs = [];
            this.logger = {error: (message) => this.logs.push(message)};
          }
          setAuthStatus(status) {
            this.currentAuthStatus = status;
            this.notifications.push(status);
          }
          probe(stdout) {
        """ <>
          adapter_probe_body() <>
          """
            }
          }
          const probe = new Probe(JSON.parse(process.argv[3]));
          const result = probe.probe(process.argv[2]);
          console.log(JSON.stringify({current: probe.currentAuthStatus ?? null, result: result ?? null, notifications: probe.notifications, logs: probe.logs}));
          """
      )
      |> Claude.patch_auth_status_source()
      |> Claude.patch_adapter_source()

    path = Path.join(System.tmp_dir!(), "claude-auth-probe-#{System.unique_integer()}.mjs")
    File.write!(path, source)

    try do
      {output, 0} = System.cmd("node", [path, JSON.encode!(input), JSON.encode!(prior)])
      JSON.decode!(output)
    after
      File.rm(path)
    end
  end

  defp adapter_probe_body do
    """
            const status = fromCliStatus(stdout);
            if (!status) {
                this.logger.error("claude auth status returned unparseable output");
                return undefined;
            }
            const merged = mergeAuthStatus(this.currentAuthStatus, status);
            this.setAuthStatus(merged);
    """
  end
end
