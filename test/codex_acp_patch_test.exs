defmodule Tightbeam.HarnessAdapterPatchTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, Codex, CodexIdentity}

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

  test "Codex and Claude readiness leave present adapter bundles and modes unchanged" do
    for module <- [Codex, Claude] do
      base = scratch_dir()
      package = if module == Codex, do: "codex-acp", else: "claude-agent-acp"
      bundle_name = if module == Codex, do: "index.js", else: "acp-agent.js"
      binary = Path.join([base, "adapters", "node_modules", ".bin", package])

      bundle =
        Path.join([
          base,
          "adapters",
          "node_modules",
          "@agentclientprotocol",
          package,
          "dist",
          bundle_name
        ])

      File.mkdir_p!(Path.dirname(binary))
      File.mkdir_p!(Path.dirname(bundle))
      File.write!(bundle, "stock vendor bytes")
      File.chmod!(bundle, 0o751)
      File.ln_s!(bundle, binary)
      before = {File.read!(bundle), File.stat!(bundle).mode, File.stat!(bundle).mtime}

      target = %{
        base_dir: base,
        host_name: "local",
        host_config: %{base_dir: base, ssh: nil},
        adapter_binary: binary
      }

      assert {:ok, "adapters present"} = module.ensure_adapter(target)
      assert {:ok, "adapters present"} = module.ensure_adapter(target)
      assert {File.read!(bundle), File.stat!(bundle).mode, File.stat!(bundle).mtime} == before
    end
  end

  test "Codex and Claude remote readiness perform only executable checks" do
    for module <- [Codex, Claude] do
      base = scratch_dir()
      package = if module == Codex, do: "codex-acp", else: "claude-agent-acp"
      parent = self()

      sh = fn argv ->
        send(parent, {:remote_command, argv})
        {"", 0}
      end

      target = %{
        base_dir: base,
        host_name: "remote",
        host_config: %{base_dir: base, ssh: "fixture@remote"},
        adapter_binary: "/srv/tb/adapters/node_modules/.bin/#{package}",
        sh: sh
      }

      assert {:ok, "adapters present"} = module.ensure_adapter(target)
      assert {:ok, "adapters present"} = module.ensure_adapter(target)
      assert_receive {:remote_command, first}
      assert_receive {:remote_command, second}
      assert Enum.join(first, " ") =~ "test -x"
      assert Enum.join(second, " ") =~ "test -x"
      refute_receive {:remote_command, _}
    end
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
