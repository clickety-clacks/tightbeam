defmodule Tightbeam.HarnessAdapterPatchTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, ClaudeFoldedPrompt, Codex, CodexIdentity, Support}

  test "Codex projects separate full developer snapshots through the stock SessionStart hook" do
    base = scratch_dir()
    target = %{base_dir: base, host_config: %{base_dir: base, ssh: nil}}
    guidance_a = "developer identity A\n" <> String.duplicate("middle-of-guidance\n", 500)
    guidance_b = "developer identity B"

    assert :ok = CodexIdentity.project(target, "session-A", guidance_a)
    assert :ok = CodexIdentity.project(target, "session-B", guidance_b)
    snapshot_a = CodexIdentity.superseding_snapshot(guidance_a)
    snapshot_b = CodexIdentity.superseding_snapshot(guidance_b)

    assert snapshot_a =~ "supersedes every earlier Tightbeam identity snapshot"
    assert snapshot_a =~ "Earlier Tightbeam identity clauses absent below are no longer active"
    assert snapshot_a =~ guidance_a

    rails = JSON.encode!(%{"hooks" => %{"PreToolUse" => [%{"hooks" => []}]}})
    settings = CodexIdentity.hook_settings(rails) |> JSON.decode!()
    assert get_in(settings, ["hooks", "PreToolUse"]) == [%{"hooks" => []}]
    [handler] = get_in(settings, ["hooks", "SessionStart", Access.at(0), "hooks"])
    assert handler["additionalContextLimit"] == 0

    assert hook_result(handler, base, "session-A") == %{
             "hookSpecificOutput" => %{
               "hookEventName" => "SessionStart",
               "additionalContext" => snapshot_a
             }
           }

    assert hook_result(handler, base, "session-B") == %{
             "hookSpecificOutput" => %{
               "hookEventName" => "SessionStart",
               "additionalContext" => snapshot_b
             }
           }

    assert :ok = CodexIdentity.verify_hook(target, "session-A")
    assert :ok = CodexIdentity.verify_hook(target, "session-B")

    assert Bitwise.band(File.stat!(Path.join([base, "codex-context", "session-A"])).mode, 0o777) ==
             0o600
  end

  test "only the latest persisted Tightbeam snapshot suppresses an unchanged resume" do
    base = scratch_dir()
    target = %{base_dir: base, host_config: %{base_dir: base, ssh: nil}}

    [handler] =
      CodexIdentity.hook_settings(nil)
      |> JSON.decode!()
      |> get_in(["hooks", "SessionStart", Access.at(0), "hooks"])

    transcript = Path.join(base, "rollout.jsonl")
    assert :ok = CodexIdentity.project(target, "session-A", "rule A\nremoved rule")
    snapshot_a = CodexIdentity.superseding_snapshot("rule A\nremoved rule")

    assert get_in(hook_result(handler, base, "session-A", transcript), [
             "hookSpecificOutput",
             "additionalContext"
           ]) == snapshot_a

    File.write!(transcript, delivered_row(snapshot_a))
    assert hook_result(handler, base, "session-A", transcript) == %{}

    assert :ok = CodexIdentity.project(target, "session-A", "rule B")
    snapshot_b = CodexIdentity.superseding_snapshot("rule B")

    assert get_in(hook_result(handler, base, "session-A", transcript), [
             "hookSpecificOutput",
             "additionalContext"
           ]) == snapshot_b

    refute snapshot_b =~ "removed rule"

    File.write!(transcript, delivered_row(snapshot_b), [:append])
    assert hook_result(handler, base, "session-A", transcript) == %{}
    assert :ok = CodexIdentity.verify_hook(target, "session-A")

    File.write!(transcript, delivered_row("unrelated developer context"), [:append])
    assert :ok = CodexIdentity.project(target, "session-A", "rule A\nremoved rule")

    assert get_in(hook_result(handler, base, "session-A", transcript), [
             "hookSpecificOutput",
             "additionalContext"
           ]) == snapshot_a

    File.write!(transcript, delivered_row(snapshot_a), [:append])
    assert hook_result(handler, base, "session-A", transcript) == %{}
    assert :ok = CodexIdentity.verify_hook(target, "session-A")

    File.write!(transcript, "{unreadable rollout row\n", [:append])

    assert get_in(hook_result(handler, base, "session-A", transcript), [
             "hookSpecificOutput",
             "additionalContext"
           ]) == snapshot_a

    File.rm!(transcript)

    assert get_in(hook_result(handler, base, "session-A", transcript), [
             "hookSpecificOutput",
             "additionalContext"
           ]) == snapshot_a
  end

  test "compaction requires redelivery before an unchanged snapshot can be suppressed" do
    base = scratch_dir()
    target = %{base_dir: base, host_config: %{base_dir: base, ssh: nil}}

    [handler] =
      CodexIdentity.hook_settings(nil)
      |> JSON.decode!()
      |> get_in(["hooks", "SessionStart", Access.at(0), "hooks"])

    transcript = Path.join(base, "rollout.jsonl")
    assert :ok = CodexIdentity.project(target, "session-A", "rule A")
    snapshot_a = CodexIdentity.superseding_snapshot("rule A")

    File.write!(transcript, delivered_row(snapshot_a))
    assert hook_result(handler, base, "session-A", transcript) == %{}

    File.write!(transcript, JSON.encode!(%{type: "compacted"}) <> "\n", [:append])

    assert get_in(hook_result(handler, base, "session-A", transcript), [
             "hookSpecificOutput",
             "additionalContext"
           ]) == snapshot_a

    assert :ok = CodexIdentity.verify_hook(target, "session-A")

    File.write!(transcript, delivered_row(snapshot_a), [:append])
    assert hook_result(handler, base, "session-A", transcript) == %{}
  end

  test "missing or oversized Codex developer carrier stops before a model turn" do
    base = scratch_dir()
    settings = CodexIdentity.hook_settings(nil) |> JSON.decode!()
    [handler] = get_in(settings, ["hooks", "SessionStart", Access.at(0), "hooks"])

    assert %{"continue" => false, "stopReason" => reason} =
             hook_result(handler, base, "missing-session")

    assert reason =~ "developer instructions unavailable"

    assert {:error, :codex_identity_hook_not_observed} =
             CodexIdentity.verify_hook(
               %{host_config: %{base_dir: base, ssh: nil}},
               "missing-session"
             )

    target = %{base_dir: base, host_config: %{base_dir: base, ssh: nil}}

    assert {:error, {:codex_identity_projection_failed, reason}} =
             CodexIdentity.project(target, "oversize", String.duplicate("x", 1_048_577))

    assert reason =~ "exceeds"
  end

  test "Codex load patch passes served instructions into threadResume and leaves new unchanged" do
    base = scratch_dir()
    {binary, bundle, source} = codex_adapter_fixture!(base)

    target = %{
      base_dir: base,
      host_name: "local",
      host_config: %{base_dir: base, ssh: nil},
      adapter_binary: binary
    }

    patched = Codex.patch_adapter_source(source)
    assert patched =~ "developerInstructions: request._meta?.developerInstructions"

    instruction = "developerInstructions: request._meta?.developerInstructions"
    assert Enum.count(String.split(patched, instruction)) - 1 == 2

    [_, after_resume_session] =
      String.split(patched, "async resumeSession(request) {", parts: 2)

    [resume_session, _] =
      String.split(after_resume_session, "async loadSession(request) {", parts: 2)

    [_, load_session] = String.split(patched, "async loadSession(request) {", parts: 2)

    assert resume_session =~ instruction
    assert load_session =~ instruction

    refute patched =~
             "threadStart({\n      modelProvider: this.getModelProvider(),\n      cwd: request.cwd,\n      developerInstructions"

    assert Codex.patch_adapter_source(patched) == patched
    assert Codex.session_config(%{}, "served guidance").meta == %{}

    mode = File.stat!(bundle).mode
    assert {:ok, "adapters present"} = Codex.ensure_adapter(target)
    assert File.read!(bundle) == patched
    assert File.stat!(bundle).mode == mode
    assert File.read_link!(binary) == bundle
    before = {File.read!(bundle), File.stat!(bundle).mode, File.stat!(bundle).mtime}

    assert {:ok, "adapters present"} = Codex.ensure_adapter(target)
    assert {File.read!(bundle), File.stat!(bundle).mode, File.stat!(bundle).mtime} == before

    base = scratch_dir()
    {binary, bundle, source} = claude_adapter_fixture!(base)

    target = %{
      target
      | base_dir: base,
        host_config: %{base_dir: base, ssh: nil},
        adapter_binary: binary
    }

    local_mode = File.stat!(bundle).mode

    assert {:ok, "adapters present"} = Claude.ensure_adapter(target)
    assert File.read!(bundle) == ClaudeFoldedPrompt.patch(source)
    assert File.stat!(bundle).mode == local_mode
    assert File.read_link!(binary) == bundle
    before = {File.read!(bundle), File.stat!(bundle).mode, File.stat!(bundle).mtime}

    assert {:ok, "adapters present"} = Claude.ensure_adapter(target)
    assert {File.read!(bundle), File.stat!(bundle).mode, File.stat!(bundle).mtime} == before
  end

  test "remote readiness checks and patches Codex and Claude adapters" do
    base = scratch_dir()
    parent = self()
    {binary, bundle, source} = codex_adapter_fixture!(base)

    codex_check =
      Support.catalog_probe_argv(
        "fixture@remote",
        "test -x #{Support.shell_quote(binary)}"
      )

    codex_target = %{
      base_dir: base,
      host_name: "remote",
      host_config: %{base_dir: base, ssh: "fixture@remote"},
      adapter_binary: binary,
      sh: fn argv ->
        send(parent, {:remote_command, argv})

        if argv == codex_check do
          {"", 0}
        else
          script = argv |> Enum.drop(6) |> Enum.join(" ")
          System.cmd("sh", ["-c", script], stderr_to_stdout: true)
        end
      end
    }

    assert {:ok, "adapters present; codex adapter patched"} = Codex.ensure_adapter(codex_target)
    assert_receive {:remote_command, ^codex_check}
    assert_receive {:remote_command, patch_command}
    assert patch_command != codex_check
    refute_receive {:remote_command, _}
    assert File.read!(bundle) == Codex.patch_adapter_source(source)
    assert File.read_link!(binary) == bundle

    {binary, bundle, source} = claude_adapter_fixture!(base)

    claude_target = %{
      base_dir: base,
      host_name: "remote",
      host_config: %{base_dir: base, ssh: "fixture@remote"},
      adapter_binary: binary,
      sh: fn argv -> throw(argv) end
    }

    check =
      Support.catalog_probe_argv(
        claude_target.host_config.ssh,
        "test -x #{Support.shell_quote(binary)}"
      )

    patch =
      catch_throw(ClaudeFoldedPrompt.remote(claude_target, binary, "adapters present"))

    claude_target = %{
      claude_target
      | sh: fn argv ->
          assert argv in [check, patch]
          send(parent, {:remote_command, argv})
          script = argv |> Enum.drop(6) |> Enum.join(" ")
          System.cmd("sh", ["-c", script], stderr_to_stdout: true)
        end
    }

    mode = File.stat!(bundle).mode

    for _ <- 1..2 do
      assert {:ok, "adapters present; claude adapter patched"} =
               Claude.ensure_adapter(claude_target)

      assert_receive {:remote_command, first}
      assert first == check
      assert_receive {:remote_command, second}
      assert second == patch
      refute_receive {:remote_command, _}
      assert File.read!(bundle) == ClaudeFoldedPrompt.patch(source)
      assert File.stat!(bundle).mode == mode
      assert File.read_link!(binary) == bundle
    end
  end

  defp codex_adapter_fixture!(base) do
    package =
      Path.join([base, "adapters", "node_modules", "@agentclientprotocol", "codex-acp"])

    binary = Path.join([base, "adapters", "node_modules", ".bin", "codex-acp"])
    bundle = Path.join([package, "dist", "index.js"])

    source =
      "async newSession(request) {\n" <>
        "    await this.codexClient.threadStart({\n" <>
        "      modelProvider: this.getModelProvider(),\n" <>
        "      cwd: request.cwd\n" <>
        "    });\n" <>
        "  }\n" <>
        "  async resumeSession(request) {\n" <>
        "    await this.codexClient.threadResume({\n" <>
        "      excludeTurns: true,\n" <>
        "      modelProvider: await this.getResumeModelProvider(),\n" <>
        "      threadId: request.sessionId\n" <>
        "    });\n" <>
        "  }\n" <>
        "  async loadSession(request) {\n" <>
        "    await this.codexClient.threadResume({\n" <>
        "      excludeTurns: true,\n" <>
        "      modelProvider: await this.getResumeModelProvider(),\n" <>
        "      threadId: request.sessionId\n" <>
        "    });\n" <>
        "  }\n"

    File.mkdir_p!(Path.dirname(binary))
    File.mkdir_p!(Path.dirname(bundle))
    File.write!(Path.join(package, "package.json"), JSON.encode!(%{"version" => "1.12.0"}))
    File.write!(bundle, source)
    File.chmod!(bundle, 0o751)
    File.ln_s!(bundle, binary)
    {binary, bundle, source}
  end

  defp claude_adapter_fixture!(base) do
    package =
      Path.join([base, "adapters", "node_modules", "@agentclientprotocol", "claude-agent-acp"])

    binary = Path.join([base, "adapters", "node_modules", ".bin", "claude-agent-acp"])
    bundle = Path.join([package, "dist", "acp-agent.js"])
    source = ClaudeFoldedPrompt.fixture()
    File.mkdir_p!(Path.dirname(binary))
    File.mkdir_p!(Path.dirname(bundle))
    File.write!(Path.join(package, "package.json"), JSON.encode!(%{"version" => "0.81.0"}))
    File.write!(bundle, source)
    File.chmod!(bundle, 0o751)
    File.ln_s!(bundle, binary)
    {binary, bundle, source}
  end

  defp delivered_row(snapshot) do
    JSON.encode!(%{
      type: "response_item",
      payload: %{
        type: "message",
        role: "developer",
        content: [%{type: "input_text", text: snapshot}],
        internal_chat_message_metadata_passthrough: %{
          content_item_kinds: ["hooks.additional_context"]
        }
      }
    }) <> "\n"
  end

  defp hook_result(handler, base, session_id, transcript_path \\ nil) do
    input =
      JSON.encode!(%{
        session_id: session_id,
        hook_event_name: "SessionStart",
        transcript_path: transcript_path
      })

    command =
      "printf '%s' #{Tightbeam.Harness.Support.shell_quote(input)} | #{handler["command"]}"

    {output, 0} =
      System.cmd("/bin/sh", ["-c", command], env: [{"TIGHTBEAM_HOME", base}])

    JSON.decode!(output)
  end

  defp scratch_dir do
    path = Path.join(System.tmp_dir!(), "tb-stock-acp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
