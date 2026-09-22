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

  test "claude patch refuses obsolete 0.73 settlement anchors" do
    source =
      [
        "                            case \"task_notification\":\n                                // The task settled — no further tool calls can originate\n                                // from it, so its registry entry can be dropped.\n                                session.liveBackgroundTasks.delete(message.task_id);\n                                break;",
        "                                if (message.patch.status === \"completed\" ||\n                                    message.patch.status === \"failed\" ||\n                                    message.patch.status === \"killed\") {\n                                    session.liveBackgroundTasks.delete(message.task_id);\n                                }"
      ]
      |> Enum.join("\n")

    assert_raise RuntimeError,
                 "unsupported claude adapter 0.73.0 bundle; patch did not apply",
                 fn ->
                   Claude.patch_adapter_source(source)
                 end
  end

  test "claude 0.73 patch preserves native settlement before emitting the legacy marker" do
    source =
      [
        "                            case \"task_notification\":\n                                // The task settled — no further tool calls can originate\n                                // from it, so its registry entry can be dropped.\n                                await subagents.finishTask(message.task_id, message.status, sendUpdate, message.tool_use_id);\n                                await asyncTasks.taskNotification({\n                                    task_id: message.task_id,\n                                    status: message.status,\n                                    summary: message.summary,\n                                    output_file: message.output_file,\n                                });\n                                if (message.tool_use_id)\n                                    subagents.discardPending(message.tool_use_id);\n                                session.liveBackgroundTasks.delete(message.task_id);\n                                break;",
        "                                if (message.patch.status === \"completed\" ||\n                                    message.patch.status === \"failed\" ||\n                                    message.patch.status === \"killed\") {\n                                    await subagents.finishTask(message.task_id, message.patch.status, sendUpdate);\n                                    session.liveBackgroundTasks.delete(message.task_id);\n                                }"
      ]
      |> Enum.join("\n")

    patched = Claude.patch_adapter_source(source)

    assert patched =~
             "await subagents.finishTask(message.task_id, message.status, sendUpdate, message.tool_use_id);"

    assert patched =~
             "await subagents.finishTask(message.task_id, message.patch.status, sendUpdate);"

    assert patched =~ "toolCallId: record.parentToolUseId"
    assert length(String.split(patched, "subagentTerminated")) - 1 == 2
    assert Claude.patch_adapter_source(patched) == patched
  end
end
