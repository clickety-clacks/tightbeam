defmodule Tightbeam.HarnessAdapterPatchTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, Codex}

  test "codex patch carries identity, account, and child-thread settlement idempotently" do
    source = codex_source()

    patched = Codex.patch_adapter_source(source)
    assert patched =~ "developerInstructions: request._meta?.developerInstructions"
    assert patched =~ "accountUpdated: notification.params"
    assert patched =~ "subAgentActivityCallIds"
    assert patched =~ "subagentTerminated"
    assert patched =~ ~s(["idle", "systemError", "notLoaded"])
    assert Codex.patch_adapter_source(patched) == patched
  end

  defp codex_source do
    [
      "  async fetchAvailableModels() {\n    const models = [];\n    let cursor = null;\n    do {\n      const response = await this.codexClient.listModels({ cursor, limit: null });\n      models.push(...response.data);\n      cursor = response.nextCursor;\n    } while (cursor);\n    return models;\n  }",
      "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd\n",
      "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n",
      "      case \"account/updated\":\n      case \"fs/changed\":",
      "  activeSubAgentActivities = /* @__PURE__ */ new Set();\n",
      "      case \"thread/status/changed\":\n        return this.createCodexSessionInfoUpdate({\n          threadStatus: notification.params.status\n        });",
      "      case \"subAgentActivity\":\n        this.activeSubAgentActivities.add(event.item.id);\n        return createSubAgentActivityUpdate(event.item, \"in_progress\", \"tool_call\");"
    ]
    |> Enum.join("\n")
  end

  test "model discovery opts in Astra without exposing unrelated hidden models" do
    patched = Codex.patch_adapter_source(codex_source())
    [method] = Regex.run(~r/  async fetchAvailableModels\(\).*?    return models;\n  }/s, patched)
    fixture = Path.join(__DIR__, "fixtures/model_catalog/codex_0_153_2_api_models.json")

    script = """
    const assert = require('node:assert/strict');
    const fixture = JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8'));
    class Client { #{method} }
    const client = new Client();
    const calls = [];
    client.codexClient = {listModels: async (params) => {
      calls.push(params);
      return params.cursor === null
        ? {data: fixture.data.slice(0, 1), nextCursor: 'page-2'}
        : {data: fixture.data.slice(1), nextCursor: null};
    }};
    (async () => {
      const models = await client.fetchAvailableModels();
      assert.deepEqual(models.map(m => m.id), ['gpt-6-astra', 'gpt-5.6-sol']);
      assert.deepEqual(calls.map(c => c.cursor), [null, 'page-2']);
      assert(calls.every(c => c.includeHidden === true));
      assert.deepEqual(models[0], fixture.data[0]);
      client.codexClient.listModels = async () => ({data: fixture.data.slice(1), nextCursor: null});
      assert.deepEqual((await client.fetchAvailableModels()).map(m => m.id), ['gpt-5.6-sol']);
      console.log('PASS');
    })().catch(e => {console.error(e); process.exitCode = 1;});
    """

    assert {"PASS\n", 0} = System.cmd("node", ["-e", script, fixture], stderr_to_stdout: true)
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
