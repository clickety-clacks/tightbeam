defmodule Tightbeam.CodexAcpPatch do
  @moduledoc """
  Tight Beam's pinned vendored-adapter patches carried until they are upstream.

  Codex-acp 1.1.4 forwards served identity and account updates, and emits a
  correlated subagent termination update when a child thread settles. Claude
  agent ACP 0.59.0 emits the same explicit carrier at the
  `liveBackgroundTasks` settlement point.
  """

  @versions %{codex: "1.1.4", claude: "0.59.0"}

  @codex_replacements [
    {
      "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd\n",
      "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd,\n      developerInstructions: request._meta?.developerInstructions\n"
    },
    {
      "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n",
      "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId,\n      developerInstructions: request._meta?.developerInstructions\n"
    },
    {
      "      case \"account/updated\":\n      case \"fs/changed\":",
      "      case \"account/updated\":\n        return this.createCodexSessionInfoUpdate({ accountUpdated: notification.params });\n      case \"fs/changed\":"
    },
    {
      "  activeSubAgentActivities = /* @__PURE__ */ new Set();\n",
      "  activeSubAgentActivities = /* @__PURE__ */ new Set();\n  subAgentActivityCallIds = /* @__PURE__ */ new Map();\n"
    },
    {
      "      case \"thread/status/changed\":\n        return this.createCodexSessionInfoUpdate({\n          threadStatus: notification.params.status\n        });",
      "      case \"thread/status/changed\": {\n        const childToolCallId = this.subAgentActivityCallIds.get(notification.params.threadId);\n        if (childToolCallId && [\"idle\", \"systemError\", \"notLoaded\"].includes(notification.params.status.type)) {\n          return {\n            sessionUpdate: \"tool_call_update\",\n            toolCallId: childToolCallId,\n            status: notification.params.status.type === \"idle\" ? \"completed\" : \"failed\",\n            _meta: { codex: { subagentTerminated: { agentThreadId: notification.params.threadId, threadStatus: notification.params.status } } }\n          };\n        }\n        return this.createCodexSessionInfoUpdate({\n          threadStatus: notification.params.status\n        });\n      }"
    },
    {
      "      case \"subAgentActivity\":\n        this.activeSubAgentActivities.add(event.item.id);\n        return createSubAgentActivityUpdate(event.item, \"in_progress\", \"tool_call\");",
      "      case \"subAgentActivity\":\n        this.activeSubAgentActivities.add(event.item.id);\n        this.subAgentActivityCallIds.set(event.item.agentThreadId, event.item.id);\n        return createSubAgentActivityUpdate(event.item, \"in_progress\", \"tool_call\");"
    }
  ]

  @claude_replacements [
    {
      "                            case \"task_notification\":\n                                // The task settled — no further tool calls can originate\n                                // from it, so its registry entry can be dropped.\n                                session.liveBackgroundTasks.delete(message.task_id);\n                                break;",
      "                            case \"task_notification\": {\n                                // The task settled — emit the correlated child-termination\n                                // carrier before dropping its parent tool-use bookkeeping.\n                                const record = session.liveBackgroundTasks.get(message.task_id);\n                                if (record?.isSubagent) {\n                                    await sendUpdate({\n                                        sessionId: message.session_id,\n                                        update: {\n                                            sessionUpdate: \"tool_call_update\",\n                                            toolCallId: record.parentToolUseId,\n                                            status: \"completed\",\n                                            _meta: { claudeCode: { subagentTerminated: { taskId: message.task_id, status: \"completed\" } } },\n                                        },\n                                    });\n                                }\n                                session.liveBackgroundTasks.delete(message.task_id);\n                                break;\n                            }"
    },
    {
      "                                if (message.patch.status === \"completed\" ||\n                                    message.patch.status === \"failed\" ||\n                                    message.patch.status === \"killed\") {\n                                    session.liveBackgroundTasks.delete(message.task_id);\n                                }",
      "                                if (message.patch.status === \"completed\" ||\n                                    message.patch.status === \"failed\" ||\n                                    message.patch.status === \"killed\") {\n                                    const record = session.liveBackgroundTasks.get(message.task_id);\n                                    if (record?.isSubagent) {\n                                        await sendUpdate({\n                                            sessionId: message.session_id,\n                                            update: {\n                                                sessionUpdate: \"tool_call_update\",\n                                                toolCallId: record.parentToolUseId,\n                                                status: message.patch.status === \"completed\" ? \"completed\" : \"failed\",\n                                                _meta: { claudeCode: { subagentTerminated: { taskId: message.task_id, status: message.patch.status } } },\n                                            },\n                                        });\n                                    }\n                                    session.liveBackgroundTasks.delete(message.task_id);\n                                }"
    }
  ]

  @doc "Apply the pinned Codex patch idempotently."
  @spec ensure!(String.t()) :: :ok
  def ensure!(binary_path), do: ensure!(:codex, binary_path)

  @doc "Apply one pinned adapter patch idempotently."
  @spec ensure!(:codex | :claude, String.t()) :: :ok
  def ensure!(harness, binary_path) do
    {package, bundle} = installed_paths(harness, binary_path)
    %{"version" => version} = package |> File.read!() |> JSON.decode!()
    ^version = Map.fetch!(@versions, harness)
    source = File.read!(bundle)
    patched = patch(harness, source)

    if patched != source do
      temporary = bundle <> ".tightbeam-patch"
      File.write!(temporary, patched)
      File.chmod!(temporary, 0o644)
      File.rename!(temporary, bundle)
    end

    :ok
  end

  @doc "A shell-safe Node program used to patch a remote Codex installation."
  @spec remote_script(String.t()) :: String.t()
  def remote_script(binary_path), do: remote_script(:codex, binary_path)

  @doc "A shell-safe Node program used to patch one remote installation."
  @spec remote_script(:codex | :claude, String.t()) :: String.t()
  def remote_script(harness, binary_path) do
    {_package, bundle} = installed_paths(harness, binary_path)

    encoded =
      replacements(harness)
      |> Enum.map(fn {before, replacement} -> [before, replacement] end)
      |> JSON.encode!()
      |> Base.encode64()

    """
    const fs=require('fs');const p=#{JSON.encode!(bundle)};
    const rs=JSON.parse(Buffer.from(#{JSON.encode!(encoded)},'base64').toString());
    let s=fs.readFileSync(p,'utf8');
    for(const [a,b] of rs){if(!s.includes(a)&&!s.includes(b))throw new Error('unsupported #{harness} adapter bundle');s=s.replace(a,b)}
    fs.writeFileSync(p,s);
    """
    |> String.replace("\n", "")
  end

  @doc false
  @spec patch(binary()) :: binary()
  def patch(source), do: patch(:codex, source)

  @doc false
  @spec patch(:codex | :claude, binary()) :: binary()
  def patch(harness, source) do
    Enum.reduce(replacements(harness), source, fn {before, replacement}, bytes ->
      cond do
        String.contains?(bytes, replacement) ->
          bytes

        String.contains?(bytes, before) ->
          String.replace(bytes, before, replacement, global: false)

        true ->
          raise "unsupported #{harness} adapter #{Map.fetch!(@versions, harness)} bundle; patch did not apply"
      end
    end)
  end

  defp replacements(:codex), do: @codex_replacements
  defp replacements(:claude), do: @claude_replacements

  defp installed_paths(harness, binary_path) do
    node_modules = binary_path |> Path.dirname() |> Path.dirname()
    package_name = if harness == :codex, do: "codex-acp", else: "claude-agent-acp"
    bundle_name = if harness == :codex, do: "index.js", else: "acp-agent.js"

    {
      Path.join([node_modules, "@agentclientprotocol", package_name, "package.json"]),
      Path.join([node_modules, "@agentclientprotocol", package_name, "dist", bundle_name])
    }
  end
end
