defmodule Tightbeam.HarnessPiTest do
  # Not async: Tightbeam.TestCase registers Tightbeam.RailEpisodes and
  # Tightbeam.TurnObservations under their module names in every test's setup,
  # so two concurrent tests under this template race for one global name.
  use Tightbeam.TestCase, async: false

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

    assert {:error, {:pi_catalog_provider_failed, :opencode_go, :malformed_catalog}} =
             Pi.fetch_catalog(state)
  end

  test "a malformed OpenCode Go model does not discard healthy catalog entries" do
    state = %{
      base_dir: "/vector/base",
      find_executable: fn
        "sh" -> "/bin/sh"
        "curl" -> "/usr/bin/curl"
      end,
      options: %{
        sh: fn _command ->
          body =
            JSON.encode!(%{
              "good" => %{
                "id" => "good",
                "name" => "Good model",
                "provider" => "opencode-go",
                "contextWindow" => 1000,
                "maxTokens" => 100,
                "thinkingLevelMap" => %{"medium" => "medium"}
              },
              "broken" => %{"id" => "broken", "name" => "Broken model"}
            })

          {body <> "\n200", 0}
        end
      },
      host_config: %{ssh: nil}
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, [model]} =
                 Tightbeam.PiProvider.OpenCodeGo.fetch_catalog(state)

        assert model.family == "opencode-go/good"
      end)

    assert log =~ "Skipping malformed OpenCode Go catalog model"
    assert log =~ "broken"
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

  describe "typed Pi turn failures in the pi-acp 0.0.33 patch" do
    test "the release bundle takes the full patch set once and stays valid JavaScript" do
      source = release_bundle()
      patched = Pi.patch_adapter_source(source)

      assert Pi.patch_adapter_source(patched) == patched

      for marker <- [
            "function tightbeamPiSafeError(raw) {",
            "function tightbeamPiTurnError(errorKind, piAttempts, raw) {",
            "    this.piRunError = null;\n    this.piRetryFailure = null;",
            ~s|tightbeamPiTurnError("pi_turn_failed", 0, err?.message ?? err)|,
            ~s|: `Retry exhausted${attempts}: ${tightbeamPiSafeError(ev.finalError)}`;|,
            ~s|messages.findLast((message) => message?.role === "assistant")|,
            ~s|tightbeamPiTurnError("pi_retry_exhausted", retryFailure.piAttempts|
          ] do
        assert patched =~ marker
      end

      refute patched =~ ~s|const reason = this.cancelRequested ? "cancelled" : "error";|
      refute patched =~ ~s|const reason = this.cancelRequested ? "cancelled" : "end_turn";|

      root = tmp_dir!("pi-acp-patched-bundle")
      bundle = Path.join(root, "index.mjs")
      File.write!(bundle, patched)
      assert {_output, 0} = System.cmd("node", ["--check", bundle], stderr_to_stdout: true)
    end

    test "the adapter patch is pinned to 0.0.33 and leaves another release untouched" do
      for {version, expect_patched?} <- [{"0.0.34", false}, {"0.0.33", true}] do
        root = tmp_dir!("pi-acp-pin-#{version}")
        package = Path.join([root, "node_modules", "pi-acp"])
        bundle = Path.join([package, "dist", "index.js"])
        binary = Path.join([root, "node_modules", ".bin", "pi-acp"])
        File.mkdir_p!(Path.dirname(bundle))
        File.mkdir_p!(Path.dirname(binary))
        File.write!(Path.join(package, "package.json"), JSON.encode!(%{"version" => version}))
        File.write!(bundle, release_bundle())
        File.write!(binary, "")

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, "adapters present"} =
                     Pi.ensure_adapter(%{
                       adapter_binary: binary,
                       host_name: "local",
                       host_config: %{ssh: nil}
                     })
          end)

        if expect_patched? do
          assert File.read!(bundle) == Pi.patch_adapter_source(release_bundle())
        else
          assert File.read!(bundle) == release_bundle()
          assert log =~ "unsupported installed version 0.0.34; expected 0.0.33"
        end
      end
    end

    for version <- ["0.84.1", "1.4.0"] do
      @tag pi_version: version
      test "exhausted retries, assistant errors and RPC refusals reject typed on Pi #{version}",
           ctx do
        results = turn_contract(Pi.patch_adapter_source(release_bundle()), ctx.pi_version)

        # A1: turn 38756's shape, one logical prompt and four Pi request attempts.
        assert results["exhausted"]["error"] == %{
                 "code" => -32_603,
                 "message" =>
                   "Internal error: pi retry exhausted after 4 attempts: Request timed out.",
                 "data" => %{
                   "errorKind" => "pi_retry_exhausted",
                   "piAttempts" => 4,
                   "transportAttempts" => "unobserved",
                   "finalError" => "Request timed out."
                 }
               }

        assert List.last(results["exhausted"]["text"]) ==
                 "Retry exhausted after 4 attempts: Request timed out."

        refute "Retry finished, resuming." in results["exhausted"]["text"]
        assert results["exhausted"]["requests"] == ["prompt"]

        # A4: a non-retryable final assistant error.
        assert results["assistantError"]["error"]["data"] == %{
                 "errorKind" => "pi_turn_failed",
                 "piAttempts" => 1,
                 "transportAttempts" => "unobserved",
                 "finalError" => "400 invalid_request_error: bad schema"
               }

        # A5: Pi refused the RPC prompt before running it.
        assert results["rpcRejected"]["error"]["code"] == -32_603

        assert results["rpcRejected"]["error"]["data"] == %{
                 "errorKind" => "pi_turn_failed",
                 "piAttempts" => 0,
                 "transportAttempts" => "unobserved",
                 "finalError" => "pi prompt failed: No model selected"
               }

        refute Map.has_key?(results["rpcRejected"], "stopReason")

        # An authentication refusal keeps pi-acp's own authRequired error.
        assert results["rpcAuthRejected"]["error"]["code"] == -32_000
        assert results["rpcAuthRejected"]["error"]["data"]["authMethods"] != []
      end

      @tag pi_version: version
      test "success, recovery, cancellation and later runs keep their outcome on Pi #{version}",
           ctx do
        results = turn_contract(Pi.patch_adapter_source(release_bundle()), ctx.pi_version)

        assert results["success"]["stopReason"] == "end_turn"
        assert results["success"]["text"] == ["hello"]

        # A2: a retry that recovers is a normal turn.
        assert results["recovered"]["stopReason"] == "end_turn"
        assert "Retry finished, resuming." in results["recovered"]["text"]

        # A failed retry chain superseded by a later successful run (compaction).
        assert results["supersededByLaterRun"]["stopReason"] == "end_turn"

        # A3: cancellation during a retry wait stays cancelled, with no error.
        assert results["cancelled"]["stopReason"] == "cancelled"
        assert results["cancelled"]["requests"] == ["prompt", "abort"]
        assert List.last(results["cancelled"]["text"]) == "Retry cancelled."
        assert results["cancelledRejection"] == %{"stopReason" => "cancelled"}
      end

      @tag pi_version: version
      test "consecutive prompts and separate sessions do not share a failure on Pi #{version}",
           ctx do
        results = turn_contract(Pi.patch_adapter_source(release_bundle()), ctx.pi_version)

        assert [
                 %{"error" => %{"data" => %{"errorKind" => "pi_retry_exhausted"}}},
                 %{"stopReason" => "end_turn"},
                 %{"error" => %{"data" => %{"errorKind" => "pi_turn_failed", "piAttempts" => 1}}}
               ] = results["consecutive"]

        assert %{
                 "failed" => %{"error" => %{"data" => %{"errorKind" => "pi_retry_exhausted"}}},
                 "delivered" => %{"stopReason" => "end_turn"}
               } = results["isolated"]
      end
    end

    test "failure text is bounded and carries no credential material" do
      results = turn_contract(Pi.patch_adapter_source(release_bundle()), "1.4.0")
      %{"message" => message, "data" => data} = results["unsafeError"]["error"]
      final_error = data["finalError"]

      assert data["errorKind"] == "pi_retry_exhausted"
      assert String.length(final_error) == 303
      assert String.ends_with?(final_error, "...")
      assert final_error =~ "401 from provider Authorization: [REDACTED]"
      assert final_error =~ "api_key=[REDACTED]"
      assert final_error =~ "token: [REDACTED]"
      assert final_error =~ "echoed [REDACTED]"
      refute final_error =~ "\n"

      for secret <- ["sk-live-abcdefghijklmnop", "SECRETVALUE", "tok_abcdef", "sk-proj-"] do
        refute message =~ secret
        refute Enum.any?(results["unsafeError"]["text"], &(&1 =~ secret))
      end
    end

    test "the unpatched release reports every failed turn as a normal end_turn" do
      # Negative control: the same scripts against pristine 0.0.33 reproduce the
      # defect. PiAcpAgent.prompt maps a session result of "error" to end_turn.
      results = turn_contract(release_bundle(), "1.4.0")

      assert results["exhausted"]["stopReason"] == "end_turn"
      assert List.last(results["exhausted"]["text"]) == "Retry finished, resuming."
      assert results["assistantError"]["stopReason"] == "end_turn"
      assert results["rpcRejected"]["stopReason"] == "error"
      assert results["isolated"]["failed"]["stopReason"] == "end_turn"
    end
  end

  # pi-acp@0.0.33 dist/index.js exactly as published (npm integrity sha512-vX9kY1tK...,
  # MIT, github.com/svkozak/pi-acp), gzip -9n and base64 encoded.
  defp release_bundle do
    bundle =
      Path.expand("fixtures/pi_acp/pi-acp-0.0.33-dist-index.js.gz.b64", __DIR__)
      |> File.read!()
      |> String.replace(~r/\s+/u, "")
      |> Base.decode64!()
      |> :zlib.gunzip()

    assert Base.encode16(:crypto.hash(:sha256, bundle), case: :lower) ==
             "24ff73fda6e3c76ddce2d359a79f5c4b8f292eb290e4d2ab85aac94676b2c2dc"

    bundle
  end

  defp turn_contract(source, pi_version) do
    root = tmp_dir!("pi-turn-contract")
    runner = Path.join(root, "runner.mjs")
    bundle = Path.join(root, "bundle.js")
    fixture = Path.expand("fixtures/pi_acp/0.0.33-turn-failure-contract.mjs", __DIR__)
    File.write!(bundle, source)

    File.write!(
      runner,
      """
      import { readFileSync } from "node:fs";
      import { runTurnContract } from #{JSON.encode!(fixture)};
      const source = readFileSync(#{JSON.encode!(bundle)}, "utf8");
      const result = await runTurnContract(source, #{JSON.encode!(pi_version)});
      process.stdout.write(JSON.stringify(result));
      """
    )

    {output, 0} = System.cmd("node", [runner], cd: root, env: [{"TMPDIR", root}])
    JSON.decode!(output)
  end

  defp pristine_adapter_fixture do
    [
      "          list: {},\n          delete: {}",
      "    this.sessions.closeAllExcept?.(session.sessionId);\n    const response = {",
      "    const fileCommands = loadSlashCommands(params.cwd);\n    this.sessions.closeAllExcept?.(session.sessionId);\n    this.store.upsert({",
      "  async cancel(params) {\n    const session = this.sessions.maybeGet(params.sessionId);\n    if (!session) return;\n    await session.cancel();\n  }\n  async listSessions(params) {",
      "  startTurn(t) {\n    this.cancelRequested = false;\n    this.inAgentLoop = false;\n",
      "        if (authErr) {\n          this.pendingTurn?.reject(authErr);\n        } else {\n          const reason = this.cancelRequested ? \"cancelled\" : \"error\";\n          this.pendingTurn?.resolve(reason);\n        }\n",
      "      case \"auto_retry_end\": {\n        this.emit({\n          sessionUpdate: \"agent_message_chunk\",\n          content: { type: \"text\", text: \"Retry finished, resuming.\" }\n        });\n        break;\n      }\n",
      "      case \"agent_end\": {\n        this.inAgentLoop = false;\n        break;\n      }\n",
      "        void this.flushEmits().finally(() => {\n          const reason = this.cancelRequested ? \"cancelled\" : \"end_turn\";\n          this.pendingTurn?.resolve(reason);\n          this.pendingTurn = null;\n",
      "function formatAutoRetryMessage(ev) {\n"
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
