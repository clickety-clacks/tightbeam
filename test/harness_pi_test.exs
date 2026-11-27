defmodule Tightbeam.HarnessPiTest do
  # Not async: Tightbeam.TestCase registers Tightbeam.RailEpisodes and
  # Tightbeam.TurnObservations under their module names in every test's setup,
  # so two concurrent tests under this template race for one global name.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ErrorDiagnostic
  alias Tightbeam.Harness.Pi

  test "local stock adapter readiness is version-pinned and idempotent" do
    root = tmp_dir!("pi-stock-local-readiness")
    {target, bundle, package_json} = adapter_fixture(root)
    stock_bytes = File.read!(bundle)
    stock_hash = :crypto.hash(:sha256, stock_bytes)

    assert {:ok, "adapters present"} = Pi.ensure_adapter(target)
    assert {:ok, "adapters present"} = Pi.ensure_adapter(target)
    assert JSON.decode!(File.read!(package_json))["version"] == "0.0.34"
    assert File.read!(bundle) == stock_bytes
    assert :crypto.hash(:sha256, File.read!(bundle)) == stock_hash
  end

  test "local readiness replaces a Pi package outside the stock version pin" do
    root = tmp_dir!("pi-stock-version-repair")
    {target, _bundle, package_json} = adapter_fixture(root, "0.0.33")
    owner = self()

    target =
      Map.put(target, :sh, fn command ->
        send(owner, {:pi_install_command, command})
        File.write!(package_json, JSON.encode!(%{"version" => "0.0.34"}))
        {"", 0}
      end)

    assert {:ok, "deployed adapters"} = Pi.ensure_adapter(target)
    assert_receive {:pi_install_command, ["/bin/sh", "-c", script]}
    assert script =~ "pi-acp@0.0.34"
    assert JSON.decode!(File.read!(package_json))["version"] == "0.0.34"
  end

  test "remote stock adapter readiness checks the package pin without rewriting its bundle" do
    owner = self()
    adapter = "/remote/base/adapters/node_modules/.bin/pi-acp"
    expected_package = "/remote/base/adapters/node_modules/pi-acp/package.json"

    target = %{
      adapter_binary: adapter,
      base_dir: "/local/base",
      host_name: "vector",
      host_config: %{base_dir: "/remote/base", ssh: "vector@remote"},
      sh: fn command ->
        send(owner, {:remote_readiness_command, command})
        joined = Enum.join(command, " ")

        if String.contains?(joined, "cat "),
          do: {~s({"version":"0.0.34"}), 0},
          else: {"", 0}
      end
    }

    assert {:ok, "adapters present"} = Pi.ensure_adapter(target)
    assert {:ok, "adapters present"} = Pi.ensure_adapter(target)

    commands =
      for _ <- 1..4 do
        assert_receive {:remote_readiness_command, command}
        Enum.join(command, " ")
      end

    assert Enum.count(commands, &String.contains?(&1, "test -x")) == 2

    assert Enum.count(commands, fn command ->
             String.contains?(command, "cat ") and String.contains?(command, expected_package)
           end) == 2

    refute Enum.any?(commands, &String.contains?(&1, "node -e"))
    refute Enum.any?(commands, &String.contains?(&1, "npm install"))
  end

  test "isolated engine launcher inventories workspace inputs without personal discovery" do
    # Resolve version-manager shims before running with the fixture PATH.
    {node, 0} = System.cmd("node", ["-p", "process.execPath"])
    node = String.trim(node)

    # The launcher reports realpaths; macOS resolves the temp dir's /var through
    # /private, so expectations are built from the resolved root.
    {root, 0} =
      System.cmd(node, [
        "-e",
        "process.stdout.write(require('fs').realpathSync(process.argv[1]))",
        tmp_dir!("pi-isolation")
      ])

    cwd = Path.join(root, "workspace")
    home = Path.join(root, "owned")
    private_home = Path.join(root, "private-home")
    real_home = Path.join(root, "real-home")
    bin = Path.join(root, "bin")
    for dir <- [cwd, home, private_home, real_home, bin], do: File.mkdir_p!(dir)
    File.ln_s!(node, Path.join(bin, "node"))

    write = fn file ->
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "fixture")
      file
    end

    write.(Path.join(root, "AGENTS.md"))
    outside = write.(Path.join(root, "personal/SKILL.md"))
    extension = write.(Path.join(home, "extensions/tightbeam.ts"))
    convention = write.(Path.join(cwd, "AGENTS.md"))
    nested = write.(Path.join(cwd, "nested/CLAUDE.md"))
    write.(Path.join(cwd, "CLAUDE.md"))
    skill = write.(Path.join(cwd, ".pi/skills/work/SKILL.md"))
    other = write.(Path.join(cwd, "nested/.agents/skills/local/SKILL.md"))
    File.ln_s!(Path.dirname(outside), Path.join(cwd, ".pi/skills/external"))
    baseline = write.(Path.join(root, "packaged/SKILL.md"))
    name = hd(Tightbeam.Homes.baseline_skill_names())
    File.mkdir_p!(Path.join(home, "skills"))
    File.ln_s!(Path.dirname(baseline), Path.join(home, "skills/" <> name))
    write.(Path.join(home, "skills/unowned/SKILL.md"))
    launcher = Path.join(home, "tightbeam-launch-pi")
    File.write!(launcher, Pi.launcher_source())
    # This records argv only. No Pi engine or adapter is executed.
    fake = Path.join(bin, "pi")

    File.write!(
      fake,
      "#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify({args:process.argv.slice(2),home:process.env.HOME,piHome:process.env.PI_CODING_AGENT_DIR,hasPrivateHomeMarker:Object.hasOwn(process.env,'PI_REAL_HOME')}));\n"
    )

    File.chmod!(fake, 0o755)

    env = [
      {"PI_CODING_AGENT_DIR", home},
      {"PI_REAL_HOME", real_home},
      {"HOME", private_home},
      {"PATH", bin <> ":" <> System.fetch_env!("PATH")}
    ]

    run = fn ->
      System.cmd(node, [launcher, "--mode", "rpc", "--no-themes"],
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )
    end

    {output, 0} = run.()
    child = JSON.decode!(output)
    args = child["args"]

    assert child["home"] == real_home
    assert child["piHome"] == home
    refute child["hasPrivateHomeMarker"]
    assert Enum.take(args, 5) == ["-nc", "-ns", "-ne", "-e", extension]
    assert Enum.take(args, -3) == ["--mode", "rpc", "--no-themes"]
    assert convention in args and nested in args
    assert skill in args and other in args and baseline in args
    refute outside in args
    refute Path.join(root, "AGENTS.md") in args
    refute Path.join(cwd, "CLAUDE.md") in args
    refute Path.join(home, "skills/unowned/SKILL.md") in args
    later = write.(Path.join(cwd, ".pi/skills/later/SKILL.md"))
    {output, 0} = run.()
    assert later in JSON.decode!(output)["args"]
    File.write!(fake, "#!/bin/sh\nexit 2\n")
    assert {_, 2} = run.()
    File.rm!(extension)
    assert {error, 1} = run.()
    assert error =~ "Pi isolated launch refused"
  end

  test "launch refuses overrides of its isolated engine command and home" do
    target = %{host_config: %{base_dir: "/fixture", ssh: nil}}

    for name <- ["HOME", "PI_REAL_HOME", "PI_ACP_PI_COMMAND", "PI_CODING_AGENT_DIR"] do
      assert_raise ArgumentError, "Pi isolation environment cannot be overridden", fn ->
        Pi.prepare_launch(target, "/owned", common_env: [{name, "/outside"}], remote_env: [])
      end

      assert_raise ArgumentError, "Pi isolation environment cannot be overridden", fn ->
        Pi.prepare_launch(target, "/owned", common_env: [], remote_env: [name <> "=/outside"])
      end
    end
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

  test "Pi rail hooks capture session cwd at session start and ignore tool cwd" do
    source = Pi.extension_source(%{"hooks" => %{}})

    assert source =~ "pi.on(\"session_start\", async (_event, ctx) =>"

    assert source =~
             "sessionWorkdir = typeof ctx?.cwd === \"string\" && ctx.cwd ? resolve(ctx.cwd) : \"\""

    assert source =~ "cwd: sessionWorkdir || process.cwd()"
    assert source =~ "TIGHTBEAM_SESSION_WORKDIR: sessionWorkdir"
    refute source =~ "event?.cwd"
  end

  describe "typed Pi turn failures in the pi-acp 0.0.34 patch" do
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

      root = tmp_dir!("pi-acp-patched-bundle")
      bundle = Path.join(root, "index.mjs")
      File.write!(bundle, patched)
      assert {_output, 0} = System.cmd("node", ["--check", bundle], stderr_to_stdout: true)
    end

    test "enabled readiness patches only the expected npm version" do
      Application.put_env(:tightbeam, :pi_typed_turn_failures_enabled, true)
      root = tmp_dir!("pi-acp-pin")
      {target, bundle, package_json} = adapter_fixture(root, "0.0.35")
      source = release_bundle()
      File.write!(bundle, source)

      assert {:error, _} =
               Pi.ensure_adapter(
                 Map.put(target, :sh, fn _command ->
                   assert File.read!(bundle) == source
                   {"install refused in fixture", 1}
                 end)
               )

      assert File.read!(bundle) == source

      File.write!(package_json, JSON.encode!(%{"version" => "0.0.34"}))
      opts = [credential_kind: :api_key]
      assert {:ok, ^opts} = Pi.preflight_launch(target, root, opts)
      assert File.read!(bundle) == Pi.patch_adapter_source(source)
      assert {:ok, ^opts} = Pi.preflight_launch(target, root, opts)
      assert File.read!(bundle) == Pi.patch_adapter_source(source)
    end

    test "enabled remote readiness applies the same patch through the remote shell" do
      Application.put_env(:tightbeam, :pi_typed_turn_failures_enabled, true)
      root = tmp_dir!("pi-acp-remote")
      {target, bundle, _package_json} = adapter_fixture(root)
      source = release_bundle()
      File.write!(bundle, source)
      destination = "fixture@remote"

      target =
        Map.merge(target, %{
          host_config: %{base_dir: root, ssh: destination},
          sh: fn command ->
            [^destination | remote_args] = Enum.drop_while(command, &(&1 != destination))
            System.cmd("sh", ["-c", Enum.join(remote_args, " ")], stderr_to_stdout: true)
          end
        })

      assert {:ok, "adapters present; pi adapter patched"} = Pi.ensure_adapter(target)
      assert File.read!(bundle) == Pi.patch_adapter_source(source)
    end

    for version <- ["0.84.1", "1.4.0"] do
      @tag pi_version: version
      test "exhausted retries, assistant errors and RPC refusals reject typed on Pi #{version}",
           ctx do
        results = turn_contract(Pi.patch_adapter_source(release_bundle()), ctx.pi_version)

        # One logical prompt, four Pi request attempts, and context usage before completion.
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

        assert results["exhausted"]["usage"] == %{
                 "sessionUpdate" => "usage_update",
                 "used" => 42,
                 "size" => 128_000
               }

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
      assert data["piAttempts"] == 4
      assert String.length(final_error) == 303
      assert String.ends_with?(final_error, "...")
      refute final_error =~ "\n"

      for redacted <- [
            "401 echoed [REDACTED:token] Authorization: Bearer [REDACTED:secret_field]",
            "api_key=[REDACTED:secret_field]",
            "Authorization: Basic [REDACTED:secret_field]",
            "Cookie: [REDACTED:secret_field]",
            "https://[REDACTED:userinfo]@example.test/fail",
            ~s(password="[REDACTED:secret_field]")
          ] do
        assert final_error =~ redacted
      end

      for secret <- [
            "sk-live-abcdefghijklmnop",
            "SECRETVALUE",
            "dXNlcjpwYXNzd29yZA",
            "topsecret",
            "alice",
            "hunter2",
            "ghp_ABCDEFGH",
            "phrase with spaces",
            "sk-proj-"
          ] do
        refute message =~ secret
        refute final_error =~ secret
        refute Enum.any?(results["unsafeError"]["text"], &(&1 =~ secret))
      end
    end

    test "the adapter's redaction matches ErrorDiagnostic.redact_text" do
      texts = [
        "Authorization: Basic dXNlcjpwYXNzd29yZA==",
        "Cookie: session=topsecret",
        "upstream https://alice:hunter2@example.test/fail",
        "provider token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456",
        ~s(password="secret phrase with spaces"),
        "password='single quoted' and passwd: plain",
        ~s({"api_key":"abc def","client_secret": "x\\"y"}),
        "Proxy-Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
        "header bearer abcdefghijklmnopqrstuvwxyz== trailing",
        "x-api-key => k-123 access_token=a refresh-token:b id_token=c private_key=d",
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEabc\n-----END RSA PRIVATE KEY----- after",
        "-----BEGIN PRIVATE KEY-----\nunterminated",
        "github_pat_ABCDEFGHIJKL sk_ABCDEFGHIJ xoxb-ABCDEFGHIJ tbc_ABCDEFGHIJ tbt_ABCDEFGHIJ",
        "ftp://user@host.example/path and https://u:p@h/x",
        "token: [REDACTED:secret_field] secret=\"unterminated",
        "Request timed out.",
        "429 rate limit exceeded; retry after 30s"
      ]

      root = tmp_dir!("pi-acp-redaction")
      runner = Path.join(root, "runner.mjs")
      bundle = Path.join(root, "bundle.js")
      fixture = Path.expand("fixtures/pi_acp/0.0.34-turn-failure-contract.mjs", __DIR__)
      File.write!(bundle, Pi.patch_adapter_source(release_bundle()))

      File.write!(
        runner,
        """
        import { readFileSync } from "node:fs";
        import { runRedaction } from #{JSON.encode!(fixture)};
        const source = readFileSync(#{JSON.encode!(bundle)}, "utf8");
        const texts = JSON.parse(readFileSync(0, "utf8"));
        process.stdout.write(JSON.stringify(await runRedaction(source, texts)));
        """
      )

      input = Path.join(root, "texts.json")
      File.write!(input, JSON.encode!(texts))

      {output, 0} =
        System.cmd("sh", ["-c", "node runner.mjs < texts.json"],
          cd: root,
          env: [{"TMPDIR", root}]
        )

      assert JSON.decode!(output) == Enum.map(texts, &ErrorDiagnostic.redact_text/1)
    end

    test "the unpatched release misreports retry exhaustion and the disabled patch matches stock" do
      # Negative control: the same scripts against pristine 0.0.34 reproduce the
      # defect. PiAcpAgent.prompt maps a session result of "error" to end_turn.
      source = release_bundle()
      results = turn_contract(source, "1.4.0", "0")
      assert turn_contract(Pi.patch_adapter_source(source), "1.4.0", "0") == results

      assert results["exhausted"]["stopReason"] == "end_turn"
      assert List.last(results["exhausted"]["text"]) == "Retry finished, resuming."
      assert results["assistantError"]["stopReason"] == "end_turn"
      assert results["rpcRejected"]["stopReason"] == "error"
      assert results["isolated"]["failed"]["stopReason"] == "end_turn"
    end
  end

  # pi-acp@0.0.34 dist/index.js exactly as published (npm integrity sha512-MrCp37Ub...,
  # MIT, github.com/svkozak/pi-acp), gzip -9n and base64 encoded.
  defp release_bundle do
    bundle =
      Path.expand("fixtures/pi_acp/pi-acp-0.0.34-dist-index.js.gz.b64", __DIR__)
      |> File.read!()
      |> String.replace(~r/\s+/u, "")
      |> Base.decode64!()
      |> :zlib.gunzip()

    assert Base.encode16(:crypto.hash(:sha256, bundle), case: :lower) ==
             "324aeb8bba1228937e16b1326fb3e014e2a625b2dea549dbcd49b006cd5df6a2"

    bundle
  end

  defp turn_contract(source, pi_version, flag \\ "1") do
    root = tmp_dir!("pi-turn-contract")
    runner = Path.join(root, "runner.mjs")
    bundle = Path.join(root, "bundle.js")
    fixture = Path.expand("fixtures/pi_acp/0.0.34-turn-failure-contract.mjs", __DIR__)
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

    {output, 0} =
      System.cmd("node", [runner],
        cd: root,
        env: [{"TMPDIR", root}, {"PI_ACP_TIGHTBEAM_TURN_FAILURES", flag}]
      )

    JSON.decode!(output)
  end

  defp adapter_fixture(base, version \\ "0.0.34") do
    adapter = Path.join([base, "adapters", "node_modules", ".bin", "pi-acp"])
    package_dir = Path.join([base, "adapters", "node_modules", "pi-acp"])
    package_json = Path.join(package_dir, "package.json")
    bundle = Path.join([package_dir, "dist", "index.js"])
    File.mkdir_p!(Path.dirname(adapter))
    File.mkdir_p!(Path.dirname(bundle))
    File.write!(adapter, "#!/bin/sh\n")
    File.chmod!(adapter, 0o755)
    File.write!(package_json, JSON.encode!(%{"version" => version}))
    File.write!(bundle, "stock package fixture bytes\n")

    target = %{
      adapter_binary: adapter,
      base_dir: base,
      host_name: "vector",
      host_config: %{base_dir: base, ssh: nil},
      sh: fn command -> raise "unexpected Pi adapter install command: #{inspect(command)}" end
    }

    {target, bundle, package_json}
  end

  defp tmp_dir!(label) do
    root =
      Path.join(System.tmp_dir!(), "tightbeam-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
