defmodule Tightbeam.HarnessPiTest do
  use Tightbeam.TestCase, async: true

  alias Tightbeam.Harness.Pi

  @close_only_close_session """
    async closeSession(params) {
      this.sessions.close(params.sessionId);
      return {};
    }
  """

  # Negative control for blocker 1: the pre-fix sequential await-then-close body.
  # When cancellation rejects, the await throws before close runs, so the session
  # is retained and close is never called. Reverting the pi.ex fix reproduces this
  # body and turns the positive rejection test below red.
  @sequential_close_session """
    async closeSession(params) {
      const session = this.sessions.maybeGet(params.sessionId);
      if (session) await session.cancel();
      this.sessions.close(params.sessionId);
      return {};
    }
  """

  test "adapter patch adds abort-on-close lifecycle and preserves concurrent sessions idempotently" do
    patched = Pi.patch_adapter_source(pristine_adapter_fixture())

    assert patched =~ "          close: {}"
    assert patched =~ "  async closeSession(params) {"
    assert patched =~ "    if (session) await session.cancel();"
    assert patched =~ "    this.sessions.close(params.sessionId);"
    refute patched =~ "closeAllExcept"
    assert Pi.patch_adapter_source(patched) == patched
  end

  test "adapter patch upgrades the prior close-only handler to abort-on-close idempotently" do
    source =
      pristine_adapter_fixture()
      |> Pi.patch_adapter_source()
      |> String.replace(
        "    const session = this.sessions.maybeGet(params.sessionId);\n    try {\n      if (session) await session.cancel();\n    } finally {\n      this.sessions.close(params.sessionId);\n    }",
        "    this.sessions.close(params.sessionId);",
        global: false
      )

    upgraded = Pi.patch_adapter_source(source)

    assert upgraded =~ "    if (session) await session.cancel();"
    assert Pi.patch_adapter_source(upgraded) == upgraded
  end

  test "patched closeSession sends abort and settles an interrupted turn as cancelled" do
    patched_close_session =
      pristine_adapter_fixture()
      |> Pi.patch_adapter_source()
      |> close_session_source()

    assert close_contract(patched_close_session) == %{
             "abortRequests" => [%{"type" => "abort"}],
             "release" => %{
               "bundleSha256" =>
                 "24ff73fda6e3c76ddce2d359a79f5c4b8f292eb290e4d2ab85aac94676b2c2dc",
               "package" => "pi-acp",
               "version" => "0.0.33"
             },
             "settlements" => ["cancelled"],
             "sessionClosed" => true,
             "stopReason" => "cancelled",
             "trace" => ["request:abort", "dispose"]
           }
  end

  test "close-only handler leaves an interrupted turn to complete as end_turn without abort" do
    assert close_contract(@close_only_close_session) == %{
             "abortRequests" => [],
             "release" => %{
               "bundleSha256" =>
                 "24ff73fda6e3c76ddce2d359a79f5c4b8f292eb290e4d2ab85aac94676b2c2dc",
               "package" => "pi-acp",
               "version" => "0.0.33"
             },
             "settlements" => ["end_turn"],
             "sessionClosed" => true,
             "stopReason" => "end_turn",
             "trace" => ["dispose"]
           }
  end

  test "patched closeSession closes the session in finally even when cancellation rejects" do
    patched_close_session =
      pristine_adapter_fixture()
      |> Pi.patch_adapter_source()
      |> close_session_source()

    result = cancel_rejection_contract(patched_close_session)

    # Close runs exactly once in the finally path, so the session is gone...
    assert result["closeCalls"] == 1
    assert result["sessionClosed"] == true
    # ...and the cancellation failure is still observable, not a false success.
    assert result["cancelRejected"] == true
    assert result["cancelError"] =~ "injected abort failure"
  end

  test "sequential await-then-close body strands the session when cancellation rejects" do
    result = cancel_rejection_contract(@sequential_close_session)

    # Negative control: the await throws before close, so close never runs and the
    # session is retained. This is the failure the finally-based fix eliminates.
    assert result["closeCalls"] == 0
    assert result["sessionClosed"] == false
    assert result["cancelRejected"] == true
  end

  test "projected extension injects served identity and blocks compiled rails before execution" do
    root = tmp_dir!("pi-extension")
    identity = Path.join([root, ".pi", "skills", "tightbeam__served-identity", "SKILL.md"])
    extension = Path.join(root, "tightbeam.mjs")
    runner = Path.join(root, "runner.mjs")
    sentinel = Path.join(root, "must-not-exist")

    File.mkdir_p!(Path.dirname(identity))

    File.write!(
      identity,
      """
      ---
      name: tightbeam-served-identity
      description: fixture
      ---
      SERVED IDENTITY FIXTURE
      """
    )

    settings = %{
      "hooks" => %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{
                "type" => "command",
                "command" =>
                  "sh -c 'grep -q tightbeam-gate-probe - || exit 0; echo fixture-refusal >&2; exit 2'"
              }
            ]
          }
        ]
      }
    }

    File.write!(extension, Pi.extension_source(settings))

    File.write!(
      runner,
      """
      import extension from #{JSON.encode!(extension)};
      const handlers = {};
      extension({ on(name, handler) { handlers[name] = handler; } });
      const identity = await handlers.before_agent_start({ systemPrompt: "BASE" });
      const gate = await handlers.tool_call({
        toolName: "bash",
        input: { command: #{JSON.encode!("touch #{sentinel}; echo tightbeam-gate-probe")} }
      });
      process.stdout.write(JSON.stringify({ identity, gate }));
      """
    )

    {output, 0} = System.cmd("node", [runner], cd: root, stderr_to_stdout: true)
    decoded = JSON.decode!(output)

    assert decoded["identity"]["systemPrompt"] == "BASE\n\nSERVED IDENTITY FIXTURE"

    assert decoded["gate"] == %{
             "block" => true,
             "reason" => "fixture-refusal",
             "terminate" => true
           }

    refute File.exists?(sentinel)
  end

  test "catalog refuses a provider mismatch instead of relabeling it" do
    base = tmp_dir!("pi-catalog-mismatch")

    state = %{
      base_dir: base,
      credential_status: fn :opencode_go, _ -> :onboarded end,
      options: %{
        sh: fn _command ->
          {~s({"wrong":{"id":"wrong","name":"Wrong","provider":"other","contextWindow":1,"maxTokens":1}}) <>
             "\n200", 0}
        end
      },
      host_config: %{ssh: nil}
    }

    assert {:error, :malformed_catalog} = Pi.fetch_catalog(state)
  end

  test "liveness uses the live-proven Pi request without putting the key in argv" do
    owner = self()

    transport = fn _target, %{command: command} ->
      send(owner, {:command, command})
      {:ok, %{status: 200, headers: %{}, body: "{}"}}
    end

    assert :live =
             Pi.credential_live?(
               %{host_config: %{ssh: nil}, sh: fn _ -> {"", 0} end},
               "/vector/home",
               transport: transport,
               timeout_ms: 5_000
             )

    assert_receive {:command, [node, "--no-warnings", "-e", script, auth_path]}
    assert Path.type(node) == :absolute
    assert Path.basename(node) == "node"
    assert auth_path == "/vector/home/auth.json"
    assert script =~ ~s("x-opencode-client": "pi")
    assert script =~ ~s("x-opencode-session": requestId)
    assert script =~ ~s("x-client-request-id": requestId)
    assert script =~ ~s(model: "gpt-5.6-luna")
    assert script =~ ~s(type: "input_text")
    assert script =~ ~s(max_output_tokens: 16)
    refute script =~ "session_id"
    assert script =~ ~s(auth["opencode-go"]?.key)
    refute auth_path =~ "api-key"
  end

  test "catalog and generated gate launch only absolute executables" do
    owner = self()
    base = tmp_dir!("pi-catalog-abs")

    state = %{
      base_dir: base,
      credential_status: fn :opencode_go, _ -> :onboarded end,
      options: %{
        find_executable: fn
          "sh" -> "/absolute/sh"
          "curl" -> "/absolute/curl"
        end,
        sh: fn command ->
          send(owner, {:catalog_command, command})

          {~s({"gpt-5.6-luna":{"id":"gpt-5.6-luna","name":"Luna","provider":"opencode-go","contextWindow":1050000,"maxTokens":128000,"reasoningLevels":["medium"]}}) <>
             "\n200", 0}
        end
      },
      host_config: %{ssh: nil}
    }

    assert {:ok, [_model]} = Pi.fetch_catalog(state)
    assert_receive {:catalog_command, ["/absolute/sh", "-c", script]}
    assert script =~ "'/absolute/curl'"
    assert Pi.extension_source(%{"hooks" => %{}}) =~ ~s(spawnSync("/bin/sh")
  end

  test "remote adapter rejects relative node candidates before probing them" do
    owner = self()
    adapter = "/remote/base/adapters/node_modules/.bin/pi-acp"

    target = fn toolchain_dirs, label ->
      %{
        adapter_binary: adapter,
        base_dir: "/local/base",
        find_executable: fn "ssh" -> "/usr/bin/ssh" end,
        host_name: "worker",
        host_config: %{
          base_dir: "/remote/base",
          ssh: "fixture@worker",
          toolchain_dirs: toolchain_dirs
        },
        sh: fn command ->
          send(owner, {label, command})
          {"", 0}
        end
      }
    end

    assert {:error, %{code: "host_unready", message: "remote node executable not found"}} =
             target.(["relative-bin"], :relative) |> Pi.ensure_adapter()

    assert_receive {:relative, _adapter_presence_check}
    refute_receive {:relative, _node_command}

    assert {:ok, "adapters present; pi adapter patched"} =
             target.(["/opt/toolchain"], :absolute) |> Pi.ensure_adapter()

    assert_receive {:absolute, _adapter_presence_check}

    assert_receive {:absolute,
                    ["/usr/bin/ssh" | [_, _, _, _, "fixture@worker", "/bin/test", "-x", node]]}

    assert node == "/opt/toolchain/node"

    assert_receive {:absolute,
                    ["/usr/bin/ssh" | [_, _, _, _, "fixture@worker", ^node, "-e", script]]}

    assert script =~ "/remote/base/adapters/node_modules/pi-acp/package.json"
    assert script =~ "unsupported pi adapter version"
    assert script =~ "0.0.33"
    assert script =~ "const rs=JSON.parse"
  end

  defp pristine_adapter_fixture do
    [
      "          list: {},\n          delete: {}",
      "    this.sessions.closeAllExcept?.(session.sessionId);\n    const response = {",
      "    const fileCommands = loadSlashCommands(params.cwd);\n    this.sessions.closeAllExcept?.(session.sessionId);\n    this.store.upsert({",
      "  async cancel(params) {\n    const session = this.sessions.maybeGet(params.sessionId);\n    if (!session) return;\n    await session.cancel();\n  }\n  async listSessions(params) {"
    ]
    |> Enum.join("\n")
  end

  defp close_contract(close_session_source) do
    root = tmp_dir!("pi-close-contract")
    runner = Path.join(root, "runner.mjs")
    fixture = Path.expand("fixtures/pi_acp/0.0.33-close-contract.mjs", __DIR__)

    File.write!(
      runner,
      """
      import { runCloseContract } from #{JSON.encode!(fixture)};
      const result = await runCloseContract(#{JSON.encode!(close_session_source)});
      process.stdout.write(JSON.stringify(result));
      """
    )

    {output, 0} = System.cmd("node", [runner], cd: root, stderr_to_stdout: true)
    JSON.decode!(output)
  end

  defp cancel_rejection_contract(close_session_source) do
    root = tmp_dir!("pi-cancel-rejection")
    runner = Path.join(root, "runner.mjs")
    fixture = Path.expand("fixtures/pi_acp/0.0.33-close-contract.mjs", __DIR__)

    File.write!(
      runner,
      """
      import { runCancelRejectionContract } from #{JSON.encode!(fixture)};
      const result = await runCancelRejectionContract(#{JSON.encode!(close_session_source)});
      process.stdout.write(JSON.stringify(result));
      """
    )

    {output, 0} = System.cmd("node", [runner], cd: root, stderr_to_stdout: true)
    JSON.decode!(output)
  end

  defp close_session_source(source) do
    [_, close_session] =
      Regex.run(
        ~r/(  async closeSession\(params\) \{.*?\n  \})\n  async listSessions\(params\)/s,
        source
      )

    close_session
  end

  defp tmp_dir!(label) do
    root =
      Path.join(System.tmp_dir!(), "tightbeam-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
