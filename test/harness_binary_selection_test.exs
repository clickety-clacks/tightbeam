defmodule Tightbeam.Harness.BinarySelectionTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{BinarySelection, Claude, Codex, Support}

  setup do
    root = Path.join(System.tmp_dir!(), "tb-selection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {root, 0} =
      System.cmd("node", [
        "-e",
        "process.stdout.write(require('node:fs').realpathSync(process.argv[1]))",
        root
      ])

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "both launch plans consume the installed invocation, preserve wrappers and never retry",
       ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bundle_fixture(module, root)
      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      marker = Path.join(root, "invocations")
      vendor = Path.join(bin, module.cli_binary())
      child = Path.join(root, "child")

      executable(child, """
      #!/bin/sh
      printf 'wrapper-argument:%s\\n' "$*" >> "$SELECTION_MARKER"
      exit 23
      """)

      executable(vendor, """
      #!/bin/sh
      if [ "$1" = --version ]; then echo 'vendor 1.0.0'; exit 0; fi
      exec "$SELECTION_CHILD" --injected "$@"
      """)

      # This fixture consumes the same vendor variable as the inspected adapter.
      adapter =
        Path.join(root, "adapters/node_modules/.bin/#{Path.basename(module.install_package())}")

      executable(adapter, """
      #!/bin/sh
      selected="$#{module.binary_cli_env_name()}"
      [ -n "$selected" ] || { echo bundle >> "$SELECTION_MARKER"; exit 31; }
      exec "$selected" app-server
      """)

      plan =
        launch_plan(module, root, [
          {"PATH", test_path(bin)},
          {"SELECTION_MARKER", marker},
          {"SELECTION_CHILD", Path.join(root, "child")},
          {module.binary_cli_env_name(), ""}
        ])

      assert Keyword.get(plan, :harness_binary_selection)
      {output, 23} = execute(plan)
      assert File.read!(marker) == "wrapper-argument:--injected app-server\n"
      assert output =~ ~s("source":"system")
      assert output =~ "Selection captured before adapter exec"
      refute output =~ ~s("source":"pinned_override")
    end
  end

  test "broken explicit pins do not run the available installed copy", ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bundle_fixture(module, root)
      bin = Path.join(root, "bin")
      marker = Path.join(root, "invocations")

      executable(
        Path.join(bin, module.cli_binary()),
        "#!/bin/sh\necho unexpected >> \"$SELECTION_MARKER\"\n"
      )

      adapter =
        Path.join(root, "adapters/node_modules/.bin/#{Path.basename(module.install_package())}")

      executable(adapter, "#!/bin/sh\nexec \"$#{module.binary_cli_env_name()}\" app-server\n")
      pin = Path.join(root, "missing-pin")

      plan =
        launch_plan(module, root, [
          {"PATH", test_path(bin)},
          {"SELECTION_MARKER", marker},
          {module.binary_cli_env_name(), pin}
        ])

      {output, status} = execute(plan)
      assert status != 0
      assert output =~ ~s("source":"pinned_override")
      refute File.exists?(marker)
    end
  end

  test "empty successful version output still selects the host wrapper", ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bin = Path.join(root, "bin")
      vendor = Path.join(bin, module.cli_binary())
      executable(vendor, "#!/bin/sh\nexit 0\n")

      {output, 0} =
        System.cmd("node", ["-e", BinarySelection.script(module), root, "automatic", ""],
          env: [{"PATH", test_path(bin)}]
        )

      result = JSON.decode!(output)
      assert result["source"] == "system"
      assert result["path"] == vendor
      assert result["version"] == nil
      assert result["version_status"] == "unknown"
    end
  end

  test "unrunnable first candidates fall back without searching later PATH entries", ctx do
    for module <- [Claude, Codex], failure <- [:absent, :interpreter, :exit, :timeout] do
      root = Path.join(ctx.root, "#{module.wire_name()}-#{failure}")
      bin = Path.join(root, "bin")
      bundle = bundle_fixture(module, root)
      vendor = Path.join(bin, module.cli_binary())

      case failure do
        :absent -> :ok
        :interpreter -> executable(vendor, "#!/missing/interpreter\n")
        :exit -> executable(vendor, "#!/bin/sh\nexit 1\n")
        :timeout -> executable(vendor, "#!#{System.find_executable("node")}\nwhile(true){}\n")
      end

      later = Path.join(root, "later")
      # Absent means absent throughout PATH; failures must not try a later copy.
      if failure != :absent do
        executable(Path.join(later, module.cli_binary()), "#!/bin/sh\necho vendor 1.0.0\n")
      end

      result = observe(module, root, test_path(bin) <> ":" <> later)
      assert result["source"] == "bundled_fallback"
      assert result["path"] == bundle
      assert result["version"] == "vendor 9.0.0"
      assert is_binary(result["fallback_reason"])
      assert [_] = Tightbeam.Harness.BinaryDiagnostics.warnings_for(result)
    end
  end

  test "PATH order, symlink invocation and direct bundle provenance are preserved", ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bin = Path.join(root, "bin")
      bundle = bundle_fixture(module, root)
      host = Path.join(root, "installed")
      executable(host, "#!/bin/sh\necho vendor 1.0.0\n")
      path = test_path(bin)
      link = Path.join(bin, module.cli_binary())
      File.ln_s!(host, link)
      result = observe(module, root, path)
      assert result["source"] == "system"
      assert result["path"] == link
      assert result["resolved_path"] != link
      assert result["version"] == "vendor 1.0.0"
      File.rm!(link)
      File.ln_s!(bundle, link)
      result = observe(module, root, path)
      assert result["source"] == "bundled_fallback"
      assert result["path"] == link
      pinned = observe(module, root, path, "pinned", link)
      assert pinned["source"] == "pinned_override"
      assert pinned["path"] == link
    end
  end

  test "non-executable PATH entries are skipped and unrecognized successful versions stay unknown",
       ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bin = Path.join(root, "bin")
      later = Path.join(root, "later")
      path = test_path(bin)
      File.write!(Path.join(bin, module.cli_binary()), "not executable")
      vendor = Path.join(later, module.cli_binary())
      executable(vendor, "#!/bin/sh\necho unrecognized\n")
      result = observe(module, root, path <> ":" <> later)
      assert result["source"] == "system"
      assert result["path"] == vendor
      assert result["version"] == nil
    end
  end

  test "failed pin observations retain selection, and unknown versions are not mismatches", ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      pin = Path.join(root, "missing")
      result = observe(module, root, test_path(Path.join(root, "bin")), "pinned", pin)
      assert result["status"] == "observed"
      assert result["source"] == "pinned_override"
      assert result["path"] == pin
      assert result["version"] == nil
      assert result["reason"] =~ "failed"

      rows =
        for {host, version} <- [{"one", "vendor 1.0.0"}, {"two", nil}] do
          %{
            "host" => host,
            "harness" => module.wire_name(),
            "next_launch" => Map.put(result, "version", version)
          }
        end

      assert Tightbeam.Harness.BinaryDiagnostics.version_warnings(rows) == []
      fallback = Map.put(result, "source", "bundled_fallback")
      assert [_] = Tightbeam.Harness.BinaryDiagnostics.warnings_for(fallback)
    end
  end

  test "launch capture survives a later changed prospective selection", ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bin = Path.join(root, "bin")
      bundle = bundle_fixture(module, root)

      adapter =
        Path.join(root, "adapters/node_modules/.bin/#{Path.basename(module.install_package())}")

      executable(adapter, "#!/bin/sh\nexit 0\n")
      path = test_path(bin)

      {output, 0} =
        execute(launch_plan(module, root, [{"PATH", path}, {module.binary_cli_env_name(), ""}]))

      log = Path.join(root, "stderr.log")
      File.write!(log, "previous attempt\n" <> output)
      capture = BinarySelection.read_capture(log, byte_size("previous attempt\n"), module)
      assert capture["selection"]["source"] == "bundled_fallback"
      assert capture["selection"]["path"] == bundle
      assert capture["selection"]["version"] == nil
      executable(Path.join(bin, module.cli_binary()), "#!/bin/sh\necho vendor 1.0.0\n")
      fresh = observe(module, root, path)
      assert fresh["source"] == "system"

      projected =
        Tightbeam.Harness.BinaryDiagnostics.running_projection(%{
          "capture" => capture,
          "generation" => 1,
          "started_at_ms" => 1,
          "capture_pending" => false
        })

      assert projected["selection_observation"]["source"] == "bundled_fallback"
      assert projected["vendor_cli_child"]["status"] == "unknown"
    end
  end

  test "a broken default bundle fails without selecting another executable", ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bundle = bundle_fixture(module, root)

      if module == Codex do
        File.write!(bundle, "process.exit(31);\n")
      else
        executable(bundle, "#!/bin/sh\nexit 31\n")
      end

      adapter =
        Path.join(root, "adapters/node_modules/.bin/#{Path.basename(module.install_package())}")

      invocation = if module == Codex, do: "node ", else: ""

      executable(
        adapter,
        "#!/bin/sh\nexec #{invocation}#{Support.shell_quote(bundle)} app-server\n"
      )

      plan =
        launch_plan(module, root, [
          {"PATH", test_path(Path.join(root, "bin"))},
          {module.binary_cli_env_name(), ""}
        ])

      {output, 31} = execute(plan)
      assert output =~ ~s("source":"bundled_fallback")
      result = observe(module, root, test_path(Path.join(root, "bin")))
      assert result["path"] == bundle
      assert result["source"] == "bundled_fallback"
      assert result["version"] == nil
      assert result["reason"] =~ "unsuccessfully"
    end
  end

  test "remote launch and prospective probe use the same host overlays, home and cwd", ctx do
    for module <- [Claude, Codex] do
      root = Path.join(ctx.root, module.wire_name())
      bin = Path.join(root, "remote-bin")
      path = test_path(bin)
      vendor = Path.join(bin, module.cli_binary())
      home = Path.join(root, "home")
      File.mkdir_p!(home)

      executable(vendor, """
      #!/bin/sh
      [ "$HOME" = "$EXPECTED_HOME" ] || exit 41
      [ "$PWD" = "$EXPECTED_CWD" ] || exit 42
      if [ "$1" = --version ]; then echo 'vendor 1.0.0'; exit 0; fi
      echo remote-invocation
      """)

      adapter =
        Path.join(root, "adapters/node_modules/.bin/#{Path.basename(module.install_package())}")

      executable(adapter, "#!/bin/sh\nexec \"$#{module.binary_cli_env_name()}\" app-server\n")

      env = [
        {"PATH", path},
        {"HOME", home},
        {"EXPECTED_HOME", home},
        {"EXPECTED_CWD", ctx.root},
        {module.binary_cli_env_name(), ""}
      ]

      target = %{
        base_dir: root,
        host_config: %{base_dir: root, ssh: "worker"},
        host_name: "worker",
        sh: &Support.system_cmd_out/1
      }

      opts = [
        common_env: [],
        remote_env: Enum.map(env, fn {k, v} -> "#{k}=#{Support.shell_quote(v)}" end),
        lineage: "fixture",
        rails: nil,
        statutes: false,
        credential_kind: :subscription
      ]

      plan = module.prepare_launch(target, home, opts)
      # Model SSH's argument joining on an isolated local shell, with a different
      # gateway PATH and inherited broken pin. The host overlay clears that pin.
      execute_remote = fn plan ->
        command = plan |> Keyword.fetch!(:cmd) |> Enum.drop(6) |> Enum.join(" ")

        System.cmd("/bin/sh", ["-c", command],
          cd: ctx.root,
          env: [{"PATH", "/usr/bin:/bin"}, {module.binary_cli_env_name(), "/missing/gateway-pin"}],
          stderr_to_stdout: true
        )
      end

      {output, 0} = execute_remote.(plan)
      assert output =~ "remote-invocation"
      assert output =~ ~s("source":"system")
      raw_plan = module.launch_plan(target, home, opts)

      probe =
        BinarySelection.probe_plan(
          raw_plan,
          [
            "node",
            "-e",
            BinarySelection.script(module),
            Path.join(root, "adapters"),
            "prospective",
            ""
          ],
          target
        )

      {output, 0} = execute_remote.(probe)
      result = JSON.decode!(output)
      assert result["source"] == "system"
      assert result["path"] == vendor
      assert result["version"] == "vendor 1.0.0"
    end
  end

  defp test_path(bin) do
    File.mkdir_p!(bin)
    node = Path.join(bin, "node")
    unless File.exists?(node), do: File.ln_s!(System.find_executable("node"), node)
    bin
  end

  defp observe(module, root, path, mode \\ "automatic", pin \\ "") do
    {output, 0} =
      System.cmd(
        System.find_executable("node"),
        ["-e", BinarySelection.script(module), Path.join(root, "adapters"), mode, pin],
        env: [{"PATH", path}]
      )

    JSON.decode!(output)
  end

  defp bundle_fixture(module, root) do
    adapters = Path.join(root, "adapters")
    entry = Path.join(adapters, "node_modules/#{module.install_package()}/index.js")
    File.mkdir_p!(Path.dirname(entry))
    File.write!(Path.join(adapters, "package.json"), "{}")
    File.write!(entry, "module.exports={};")

    if module == Codex do
      bundle = Path.join(adapters, "node_modules/@openai/codex/bin/codex.js")
      executable(bundle, "#!/usr/bin/env node\nconsole.log('vendor 9.0.0');\n")
      bundle
    else
      sdk = Path.join(adapters, "node_modules/@anthropic-ai/claude-agent-sdk/index.js")
      File.mkdir_p!(Path.dirname(sdk))
      File.write!(sdk, "module.exports={};")
      {platform, 0} = System.cmd("node", ["-p", "process.platform+'-'+process.arch"])

      bundle =
        Path.join(
          adapters,
          "node_modules/@anthropic-ai/claude-agent-sdk-#{String.trim(platform)}/claude"
        )

      executable(bundle, "#!/bin/sh\necho vendor 9.0.0\n")
      bundle
    end
  end

  defp launch_plan(module, root, env) do
    target = %{
      base_dir: root,
      host_config: %{base_dir: root, ssh: nil},
      host_name: "fixture",
      sh: &Support.system_cmd_out/1
    }

    module.prepare_launch(target, root,
      common_env: env,
      remote_env: [],
      lineage: "fixture",
      rails: nil,
      statutes: false,
      credential_kind: :subscription
    )
  end

  defp execute(plan) do
    [command | args] = Keyword.fetch!(plan, :cmd)
    System.cmd(command, args, env: Keyword.fetch!(plan, :env), stderr_to_stdout: true)
  end

  defp executable(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    File.chmod!(path, 0o755)
  end
end
