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
    source = File.read!(Path.join(__DIR__, "fixtures/claude_acp_0_73_completion.js"))

    patched = Claude.patch_adapter_source(source)
    assert patched =~ "const record = session.liveBackgroundTasks.get(message.task_id)"
    assert patched =~ "subagentTerminated"

    assert patched =~
             "await subagents.finishTask(message.task_id, message.status, sendUpdate, message.tool_use_id)"

    assert patched =~
             "await subagents.finishTask(message.task_id, message.patch.status, sendUpdate)"

    assert patched =~ "await asyncTasks.taskNotification"
    assert patched =~ "subagents.discardPending(message.tool_use_id)"
    assert patched =~ "toolCallId: record.parentToolUseId"
    assert Claude.patch_adapter_source(patched) == patched
  end

  test "recorded Claude fork implementation resumes the fork before returning config metadata" do
    source = File.read!(Path.join(__DIR__, "fixtures/claude_acp_0_73_completion.js"))
    patched = Claude.patch_adapter_source(source)
    [method] = Regex.run(~r/    async unstable_forkSession\(params\) \{.*?\n    }/s, patched)

    script = """
    const assert = require('node:assert/strict');
    const calls = [];
    const messageIdForGrouping = () => {};
    const forkSession = async (params) => { calls.push(['fork', params]); return {sessionId: 'forked'}; };
    class Agent { #{method} }
    const agent = new Agent();
    agent.sessions = {};
    const options = [{id: 'model', currentValue: 'sonnet'}];
    agent.resumeSession = async (params) => { calls.push(['resume', params]); return {configOptions: options}; };
    (async () => {
      const params = {sessionId: 'parent', cwd: '/work', mcpServers: [], _meta: {probe: true}};
      assert.deepEqual(await agent.unstable_forkSession(params), {sessionId: 'forked', configOptions: options});
      assert.deepEqual(calls, [['fork', params], ['resume', {...params, sessionId: 'forked'}]]);
      agent.resumeSession = async () => { throw new Error('resume refused'); };
      await assert.rejects(agent.unstable_forkSession(params), /resume refused/);
      console.log('PASS');
    })().catch(e => {console.error(e); process.exitCode = 1;});
    """

    assert {"PASS\n", 0} = System.cmd("node", ["-e", script], stderr_to_stdout: true)
  end
end
