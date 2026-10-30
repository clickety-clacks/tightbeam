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

  test "claude patch emits at both liveBackgroundTasks settlement bookends idempotently" do
    source =
      [
        "                            case \"task_notification\":\n                                // The task settled — no further tool calls can originate\n                                // from it, so its registry entry can be dropped.\n                                session.liveBackgroundTasks.delete(message.task_id);\n                                break;",
        "                                if (message.patch.status === \"completed\" ||\n                                    message.patch.status === \"failed\" ||\n                                    message.patch.status === \"killed\") {\n                                    session.liveBackgroundTasks.delete(message.task_id);\n                                }"
      ]
      |> Enum.join("\n")

    patched = Claude.patch_adapter_source(source)
    assert patched =~ "const record = session.liveBackgroundTasks.get(message.task_id)"
    assert patched =~ "subagentTerminated"
    assert patched =~ "toolCallId: record.parentToolUseId"
    assert Claude.patch_adapter_source(patched) == patched
  end

  test "claude provenance hashes the exact installed adapter bundle" do
    base = Path.join(System.tmp_dir!(), "claude-provenance-#{System.unique_integer([:positive])}")
    node_modules = Path.join([base, "adapters", "node_modules"])
    package = Path.join([node_modules, "@agentclientprotocol", "claude-agent-acp"])
    sdk_package = Path.join([node_modules, "@anthropic-ai", "claude-agent-sdk"])
    binary = Path.join([node_modules, ".bin", "claude-agent-acp"])
    bundle = Path.join([package, "dist", "acp-agent.js"])
    source = "deployed adapter bytes"

    on_exit(fn -> File.rm_rf!(base) end)
    File.mkdir_p!(Path.dirname(binary))
    File.mkdir_p!(Path.dirname(bundle))
    File.mkdir_p!(sdk_package)
    File.write!(binary, "#!/bin/sh\n")
    File.write!(Path.join(package, "package.json"), JSON.encode!(%{"version" => "0.73.0"}))
    File.write!(Path.join(sdk_package, "package.json"), JSON.encode!(%{"version" => "0.3.257"}))
    File.write!(bundle, source)

    assert %{
             package: "@agentclientprotocol/claude-agent-acp",
             version: "0.73.0",
             source_sha256: digest,
             sdk: %{package: "@anthropic-ai/claude-agent-sdk", version: "0.3.257"}
           } =
             Claude.adapter_provenance(%{
               base_dir: base,
               host_config: %{base_dir: base, ssh: nil},
               host_name: "testhost",
               sh: fn _ -> flunk("local provenance must not execute a command") end
             })

    assert digest ==
             :crypto.hash(:sha256, source)
             |> Base.encode16(case: :lower)
  end
end
