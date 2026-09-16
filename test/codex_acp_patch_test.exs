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

  test "claude preserves native adapter source without injecting legacy settlement events" do
    source = "nativeSubagents.taskStarted(message); nativeSubagents.finishTask(message);"
    assert Claude.patch_adapter_source(source) == source
    assert Claude.patch_adapter_source(Claude.patch_adapter_source(source)) == source
  end
end
