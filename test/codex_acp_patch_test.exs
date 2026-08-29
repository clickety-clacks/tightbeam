defmodule Tightbeam.HarnessAdapterPatchTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, Codex}

  test "codex patch carries identity, account, and child-thread settlement idempotently" do
    source =
      [
        "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd\n",
        "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n",
        "      case \"account/updated\":\n      case \"fs/changed\":",
        "      case \"account/rateLimits/updated\":\n        this.handleRateLimitsUpdated(notification.params);\n        return null;",
        "var GOAL_CONTROL_METHOD = \"_codex/session/goal_control\";\nfunction isExtMethodRequest(request) {\n  return request.method === \"authentication/status\" || request.method === \"authentication/logout\" || request.method === LEGACY_SET_SESSION_MODEL_METHOD || request.method === GOAL_CONTROL_METHOD;\n}",
        "  async accountRead(params) {\n    return await this.sendRequest({ method: \"account/read\", params });\n  }",
        "      case GOAL_CONTROL_METHOD: {",
        ".onRequest(GOAL_CONTROL_METHOD, goalControlParamsParser, (ctx) => getAgent().extMethod(GOAL_CONTROL_METHOD, ctx.params)).connect(acpJsonStream);",
        "  activeSubAgentActivities = /* @__PURE__ */ new Set();\n",
        "      case \"thread/status/changed\":\n        return this.createCodexSessionInfoUpdate({\n          threadStatus: notification.params.status\n        });",
        "      case \"subAgentActivity\":\n        this.activeSubAgentActivities.add(event.item.id);\n        return createSubAgentActivityUpdate(event.item, \"in_progress\", \"tool_call\");"
      ]
      |> Enum.join("\n")

    patched = Codex.patch_adapter_source(source)
    assert patched =~ "developerInstructions: request._meta?.developerInstructions"
    assert patched =~ "accountUpdated: notification.params"
    assert patched =~ "rateLimitsUpdated: notification.params"
    assert patched =~ "_codex/account/rate_limits/read"
    assert patched =~ "account/rateLimits/read"
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
end
