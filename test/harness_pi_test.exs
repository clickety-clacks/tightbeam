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
    session_key = "agent:pi:extension"
    root = pi_session_dir!("pi-extension", session_key)
    extension = Path.join(root, "tightbeam.mjs")
    runner = Path.join(root, "runner.mjs")
    sentinel = Path.join(root, "must-not-exist")

    materialize_pi_identity!(root, session_key, "SERVED IDENTITY FIXTURE")

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
      await handlers.session_start({ type: "session_start", reason: "startup" });
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

  test "generated extension refuses invalid identity carriers before any model request" do
    session_key = "agent:pi:carrier-cases"

    for {case_name, expected_error} <- [
          {:missing, "missing carrier"},
          {:unreadable, "unreadable carrier"},
          {:malformed, "malformed"},
          {:wrong_session, "wrong-session"},
          {:correct, nil}
        ] do
      root = pi_session_dir!("pi-carrier-#{case_name}", session_key)
      identity = pi_identity_path(root)
      extension = Path.join(root, "tightbeam.mjs")
      runner = Path.join(root, "runner.mjs")
      model_request = Path.join(root, "model-requested")

      case case_name do
        :missing ->
          :ok

        :unreadable ->
          materialize_pi_identity!(root, session_key, "SERVED IDENTITY FIXTURE")
          File.rm!(identity)
          File.mkdir!(identity)

        :malformed ->
          File.mkdir_p!(Path.dirname(identity))
          File.write!(identity, "not a served identity carrier")

        :wrong_session ->
          copy_foreign_pi_identity!(root, "agent:pi:another-session", "WRONG IDENTITY")

        :correct ->
          materialize_pi_identity!(root, session_key, "SERVED IDENTITY FIXTURE")
      end

      {output, status} = run_pi_identity_startup(root, extension, runner, model_request)

      if case_name == :correct do
        assert status == 0

        assert JSON.decode!(output) == %{
                 "identity" => %{"systemPrompt" => "BASE\n\nSERVED IDENTITY FIXTURE"}
               }

        assert File.read!(model_request) == "requested"
      else
        assert status == 78
        refute File.exists?(model_request)
        assert output =~ "Tightbeam identity carrier refused startup"
        assert output =~ expected_error
      end
    end
  end

  test "generated extension lets the carrier-less gate probe reach the permission rail" do
    parent = tmp_dir!("pi-gate-probe")
    root = Path.join(parent, "gate-probe")
    extension = Path.join(root, "tightbeam.mjs")
    runner = Path.join(root, "runner.mjs")

    File.mkdir_p!(root)

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
      let modelRequests = 0;
      extension({ on(name, handler) { handlers[name] = handler; } });

      await handlers.session_start({ type: "session_start", reason: "startup" });
      const identity = await handlers.before_agent_start({ systemPrompt: "BASE" });
      modelRequests += 1;
      const gate = await handlers.tool_call({
        toolName: "bash",
        input: { command: "tightbeam-gate-probe" }
      });
      process.stdout.write(JSON.stringify({ identity: identity ?? null, gate, modelRequests }));
      """
    )

    {output, 0} = System.cmd("node", [runner], cd: root, stderr_to_stdout: true)

    assert JSON.decode!(output) == %{
             "identity" => nil,
             "gate" => %{
               "block" => true,
               "reason" => "fixture-refusal",
               "terminate" => true
             },
             "modelRequests" => 1
           }
  end

  test "generated extension refuses a present invalid carrier in a gate-probe workdir" do
    for case_name <- [:malformed, :wrong_session] do
      root = Path.join([tmp_dir!("pi-gate-probe-invalid-#{case_name}"), "gate-probe"])
      identity = pi_identity_path(root)
      extension = Path.join(root, "tightbeam.mjs")
      runner = Path.join(root, "runner.mjs")
      model_request = Path.join(root, "model-requested")

      case case_name do
        :malformed ->
          File.mkdir_p!(Path.dirname(identity))
          File.write!(identity, "not a served identity carrier")

        :wrong_session ->
          copy_foreign_pi_identity!(root, "agent:pi:another-session", "WRONG IDENTITY")
      end

      {output, status} = run_pi_identity_startup(root, extension, runner, model_request)

      assert status == 78
      refute File.exists?(model_request)
      assert output =~ "Tightbeam identity carrier refused startup"
      assert output =~ if(case_name == :malformed, do: "malformed", else: "wrong-session")
    end
  end

  test "generated extension binds the carrier to the workdir, not to the directory name" do
    session_key = "agent:pi:ephemeral-helper"

    # Placement.with_turn_directory gives an ephemeral helper a `mktemp -d
    # /tmp/tightbeam-helper.XXXXXXXXXX` workdir, so nothing in the directory
    # name derives from the session key. Mirror that layout under tmp_dir!.
    ephemeral_root =
      Path.join(tmp_dir!("pi-ephemeral"), "tightbeam-helper.#{random_mktemp_suffix()}")

    File.mkdir_p!(ephemeral_root)

    # A durable session may be reached through a symlinked configured path while
    # getcwd() reports the physical one; the binding must survive that.
    symlink_parent = tmp_dir!("pi-symlinked-workdir")
    physical_root = pi_session_dir!("pi-symlinked-physical", session_key)
    symlinked_root = Path.join(symlink_parent, "linked")
    File.ln_s!(physical_root, symlinked_root)

    for {label, root, materialize_at} <- [
          {:ephemeral, ephemeral_root, ephemeral_root},
          {:symlinked, symlinked_root, symlinked_root}
        ] do
      extension = Path.join(root, "tightbeam.mjs")
      runner = Path.join(root, "runner.mjs")
      model_request = Path.join(root, "model-requested")

      materialize_pi_identity!(materialize_at, session_key, "SERVED IDENTITY #{label}")

      {output, 0} = run_pi_identity_startup(root, extension, runner, model_request)

      assert JSON.decode!(output) == %{
               "identity" => %{"systemPrompt" => "BASE\n\nSERVED IDENTITY #{label}"}
             }

      assert File.read!(model_request) == "requested"
    end

    # The same ephemeral helper refuses a carrier that another helper's turn
    # directory materialized for the same session key: the binding is the
    # workdir the gateway wrote into, not a name the directory happens to have.
    stale_root =
      Path.join(tmp_dir!("pi-ephemeral-stale"), "tightbeam-helper.#{random_mktemp_suffix()}")

    File.mkdir_p!(stale_root)
    File.rm_rf!(Path.join(ephemeral_root, ".pi"))
    copy_foreign_pi_identity!(ephemeral_root, session_key, "STALE IDENTITY", stale_root)

    extension = Path.join(ephemeral_root, "tightbeam.mjs")
    runner = Path.join(ephemeral_root, "runner.mjs")
    model_request = Path.join(ephemeral_root, "model-requested")
    File.rm!(model_request)

    {output, 78} = run_pi_identity_startup(ephemeral_root, extension, runner, model_request)

    refute File.exists?(model_request)
    assert output =~ "Tightbeam identity carrier refused startup"
    assert output =~ "wrong-session"
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

  defp pi_session_dir!(label, session_key) do
    parent = tmp_dir!(label)

    digest =
      :crypto.hash(:sha256, session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    root = Path.join(parent, digest)
    File.mkdir_p!(root)
    root
  end

  defp materialize_pi_identity!(root, session_key, guidance) do
    Pi.materialize_skills(
      %{host_config: %{ssh: nil}, base_dir: root, session_key: session_key},
      root,
      %{
        revision: "fixture",
        archetype: "default",
        guidance: guidance,
        skills: %{}
      }
    )
  end

  # A carrier the gateway materialized into another session's workdir, then
  # found in `root`: the realistic wrong-session case (a copied or left-over
  # carrier), since the gateway itself only ever writes a carrier in place.
  defp copy_foreign_pi_identity!(root, session_key, guidance, foreign_root \\ nil) do
    foreign_root = foreign_root || pi_session_dir!("pi-foreign-workdir", session_key)
    materialize_pi_identity!(foreign_root, session_key, guidance)

    identity = pi_identity_path(root)
    File.mkdir_p!(Path.dirname(identity))
    File.cp!(pi_identity_path(foreign_root), identity)
  end

  defp run_pi_identity_startup(root, extension, runner, model_request) do
    File.write!(extension, Pi.extension_source(%{"hooks" => %{}}))

    File.write!(
      runner,
      """
      import extension from #{JSON.encode!(extension)};
      import { writeFileSync } from "node:fs";
      const handlers = {};
      extension({ on(name, handler) { handlers[name] = handler; } });

      try {
        await handlers.session_start({ type: "session_start", reason: "startup" });
        const identity = await handlers.before_agent_start({ systemPrompt: "BASE" });
        writeFileSync(#{JSON.encode!(model_request)}, "requested");
        process.stdout.write(JSON.stringify({ identity }));
      } catch (error) {
        // Pi 0.84.1 catches hook errors and continues to the model request.
        console.error(String(error?.message ?? error));
        writeFileSync(#{JSON.encode!(model_request)}, "requested-after-caught-hook-error");
      }
      """
    )

    System.cmd("node", [runner], cd: root, stderr_to_stdout: true)
  end

  defp random_mktemp_suffix do
    :crypto.strong_rand_bytes(8)
    |> Base.encode32(case: :upper, padding: false)
    |> binary_part(0, 10)
  end

  defp pi_identity_path(root) do
    Path.join([root, ".pi", "skills", "tightbeam__served-identity", "SKILL.md"])
  end
end
