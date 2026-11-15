defmodule Tightbeam.HarnessPiTest do
  # Not async: Tightbeam.TestCase registers Tightbeam.RailEpisodes and
  # Tightbeam.TurnObservations under their module names in every test's setup,
  # so two concurrent tests under this template race for one global name.
  use Tightbeam.TestCase, async: false

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
    # The launcher reports realpaths; macOS resolves the temp dir's /var through
    # /private, so expectations are built from the resolved root.
    {root, 0} =
      System.cmd("node", [
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
      System.cmd("node", [launcher, "--mode", "rpc", "--no-themes"],
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
