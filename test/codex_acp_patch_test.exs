defmodule Tightbeam.HarnessAdapterPatchTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, Codex}

  test "codex 1.9 patch carries only developer instructions idempotently" do
    source =
      [
        "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd\n",
        "  async resumeSession(request, onSubscribed) {\n    const additionalDirectories = readAdditionalDirectories(request.cwd, request.additionalDirectories, request._meta);\n    await this.refreshSkills(request.cwd, additionalDirectories);\n    const response = await this.codexClient.threadResume({\n      config: await this.createSessionConfig(request.cwd, additionalDirectories, request.mcpServers ?? []),\n      cwd: request.cwd,\n      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n",
        "  async loadSession(request, onSubscribed) {\n    const additionalDirectories = readAdditionalDirectories(request.cwd, request.additionalDirectories, request._meta);\n    await this.refreshSkills(request.cwd, additionalDirectories);\n    const response = await this.codexClient.threadResume({\n      config: await this.createSessionConfig(request.cwd, additionalDirectories, request.mcpServers ?? []),\n      cwd: request.cwd,\n      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n"
      ]
      |> Enum.join("\n")

    patched = Codex.patch_adapter_source(source)

    assert length(
             Regex.scan(
               ~r/developerInstructions: request\._meta\?\.developerInstructions/,
               patched
             )
           ) == 3

    refute patched =~ "accountUpdated: notification.params"
    refute patched =~ "subagentTerminated"
    refute patched =~ "subAgentActivityCallIds"
    assert Codex.patch_adapter_source(patched) == patched
  end

  test "current adapters use the native subagent lifecycle" do
    assert Codex.adapter_version() == "1.9.0"
    assert Claude.adapter_version() == "0.74.0"
    refute function_exported?(Claude, :patch_adapter_source, 1)

    for harness <- [Codex, Claude] do
      assert {:subagent_start, %{source_event_ref: "child-1", subagent_ref: "child-1"}} =
               harness.classify_subagent_event(%{
                 "sessionUpdate" => "subagent_spawned",
                 "subagentSessionId" => "child-1"
               })

      for state <- ["completed", "failed", "cancelled", "disconnected"] do
        assert {:subagent_stop, %{source_event_ref: "child-1", subagent_ref: "child-1"}} =
                 harness.classify_subagent_event(%{
                   "sessionUpdate" => "subagent_state_update",
                   "subagentSessionId" => "child-1",
                   "state" => state
                 })
      end

      assert :skip =
               harness.classify_subagent_event(%{
                 "sessionUpdate" => "subagent_state_update",
                 "subagentSessionId" => "child-1",
                 "state" => "running"
               })
    end
  end
end
