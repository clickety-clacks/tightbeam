defmodule Tightbeam.Harness.BinaryDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.BinaryDiagnostics

  @target %{
    host_config: %{base_dir: "/srv/tightbeam", ssh: nil},
    host_name: "example-host",
    adapter_path: "/opt/homebrew/bin:/usr/bin:/bin"
  }

  test "a synthetic effective system observation is projected as system" do
    assert %{
             "status" => "observed",
             "source" => "system",
             "path" => "/usr/local/bin/codex",
             "version" => "codex 1.2"
           } =
             BinaryDiagnostics.selection("system", "/usr/local/bin/codex", "codex 1.2")
  end

  test "an explicit pin stays selected even when PATH contains a system copy" do
    probe = fn module, target, mode, pin ->
      assert module == Tightbeam.Harness.Codex
      assert mode == "pinned"
      assert pin == "/custom path/codex "
      assert target.adapter_path =~ "/opt/homebrew/bin"
      {:ok, pin, "codex 9.1"}
    end

    assert %{
             "status" => "observed",
             "source" => "pinned_override",
             "path" => "/custom path/codex "
           } =
             BinaryDiagnostics.observe(Tightbeam.Harness.Codex, @target, "/custom path/codex ",
               probe: probe
             )
  end

  test "Claude's bundled probe matches adapter libc selection when both packages coexist" do
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-claude-libc-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    adapters = Path.join(root, "adapters")
    node_modules = Path.join(adapters, "node_modules")
    adapter = Path.join(node_modules, "@agentclientprotocol/claude-agent-acp")
    sdk = Path.join(adapter, "node_modules/@anthropic-ai/claude-agent-sdk")

    File.mkdir_p!(sdk)
    File.mkdir_p!(Path.join(node_modules, "@anthropic-ai"))
    File.write!(Path.join(adapters, "package.json"), "{}")
    File.write!(Path.join(adapter, "package.json"), ~s({"main":"index.js"}))
    File.write!(Path.join(adapter, "index.js"), "module.exports = {};")
    File.write!(Path.join(sdk, "package.json"), ~s({"main":"index.js"}))
    File.write!(Path.join(sdk, "index.js"), "module.exports = {};")

    glibc_package = Path.join(node_modules, "@anthropic-ai/claude-agent-sdk-linux-x64")
    musl_package = Path.join(node_modules, "@anthropic-ai/claude-agent-sdk-linux-x64-musl")

    for {package, version} <- [
          {glibc_package, "claude glibc fixture"},
          {musl_package, "claude musl fixture"}
        ] do
      cli = Path.join(package, "claude")
      File.mkdir_p!(package)
      File.write!(Path.join(package, "package.json"), "{}")
      File.write!(cli, "#!/bin/sh\nprintf '%s\\n' '#{version}'\n")
      File.chmod!(cli, 0o755)
    end

    node = System.find_executable("node") || flunk("Node is required for the adapter probe test")
    script = Tightbeam.Harness.Claude.binary_cli_probe_script()

    for {libc, package, version} <- [
          {:glibc, glibc_package, "claude glibc fixture"},
          {:musl, musl_package, "claude musl fixture"}
        ] do
      report =
        if libc == :glibc,
          do: "({header:{glibcVersionRuntime:'2.38'}})",
          else: "({header:{}})"

      wrapper =
        "const vm=require('node:vm'),real=process,report=#{report};" <>
          "const processProxy=new Proxy(real,{get(target,key){if(key==='platform')return 'linux';" <>
          "if(key==='arch')return 'x64';if(key==='report')return {getReport:()=>report};" <>
          "return Reflect.get(target,key,target)}});" <>
          "vm.runInNewContext(#{JSON.encode!(script)},{process:processProxy,require});"

      {output, status} =
        System.cmd(node, ["-e", wrapper, adapters, "bundled", ""], stderr_to_stdout: true)

      assert status == 0, output

      {canonical_cli, 0} =
        System.cmd(
          node,
          [
            "-e",
            "process.stdout.write(require('node:fs').realpathSync(process.argv[1]))",
            Path.join(package, "claude")
          ],
          stderr_to_stdout: true
        )

      canonical_cli = String.trim(canonical_cli)

      assert %{
               "status" => "observed",
               "source" => "bundled_fallback",
               "path" => ^canonical_cli,
               "version" => ^version
             } = JSON.decode!(output)
    end
  end

  test "remote inherited pins reach the probe and beat a different bundled CLI" do
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-remote-pin-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    adapters = Path.join(root, "adapters")
    entry = Path.join(adapters, "node_modules/@agentclientprotocol/codex-acp/index.js")
    bundled = Path.join(adapters, "node_modules/@openai/codex/bin/codex.js")
    inherited_pin = Path.join(root, "system-codex.js")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(Path.dirname(bundled))
    File.write!(Path.join(adapters, "package.json"), "{}")
    File.write!(entry, "module.exports = {};")
    File.write!(bundled, "console.log('bundled-version');")
    File.write!(inherited_pin, "console.log('remote-pin-version');")

    node = System.find_executable("node") || flunk("Node is required for the adapter probe test")
    script = Tightbeam.Harness.Codex.binary_cli_probe_script()

    {canonical_bundled, 0} =
      System.cmd(
        node,
        [
          "-e",
          "process.stdout.write(require('node:fs').realpathSync(process.argv[1]))",
          bundled
        ],
        stderr_to_stdout: true
      )

    canonical_bundled = String.trim(canonical_bundled)

    {pinned_output, 0} =
      System.cmd(node, ["-e", script, adapters, "remote", ""],
        env: [{"TIGHTBEAM_DIAGNOSTIC_PIN", inherited_pin}],
        stderr_to_stdout: true
      )

    assert %{
             "status" => "observed",
             "source" => "pinned_override",
             "path" => ^inherited_pin,
             "version" => "remote-pin-version"
           } = JSON.decode!(pinned_output)

    {bundled_output, 0} =
      System.cmd(node, ["-e", script, adapters, "remote", ""],
        env: [{"TIGHTBEAM_DIAGNOSTIC_PIN", ""}],
        stderr_to_stdout: true
      )

    assert %{
             "status" => "observed",
             "source" => "bundled_fallback",
             "path" => ^canonical_bundled,
             "version" => "bundled-version"
           } = JSON.decode!(bundled_output)

    system_bin_dir = Path.join(root, "system-bin")
    system_bin = Path.join(system_bin_dir, "codex")
    File.mkdir_p!(system_bin_dir)
    File.write!(system_bin, "#!/bin/sh\necho path-system-version\n")
    File.chmod!(system_bin, 0o755)
    path_with_system_copy = system_bin_dir <> ":" <> System.get_env("PATH", "")

    {path_mismatch_output, 0} =
      System.cmd(node, ["-e", script, adapters, "bundled", ""],
        env: [{"PATH", path_with_system_copy}],
        stderr_to_stdout: true
      )

    assert %{
             "status" => "observed",
             "source" => "bundled_fallback",
             "path" => ^canonical_bundled,
             "version" => "bundled-version"
           } = JSON.decode!(path_mismatch_output)

    remote_target =
      Map.merge(@target, %{
        host_config: %{base_dir: root, ssh: "worker@example-host"},
        adapter_path: path_with_system_copy,
        sh: fn command ->
          System.cmd("sh", ["-c", command |> Enum.take(-3) |> Enum.join(" ")],
            env: [{"CODEX_PATH", inherited_pin}],
            stderr_to_stdout: true
          )
        end
      })

    command =
      BinaryDiagnostics.probe_command(
        remote_target,
        ["node", "-e", script, adapters, "remote", ""],
        "CODEX_PATH"
      )

    # SSH joins these arguments for the remote shell, which removes the outer quoting.
    remote_script = command |> Enum.take(-3) |> Enum.join(" ")
    assert remote_script =~ "TIGHTBEAM_DIAGNOSTIC_PIN=\"${CODEX_PATH-}\""
    assert remote_script =~ "TIGHTBEAM_DIAGNOSTIC_PIN=\"$TIGHTBEAM_DIAGNOSTIC_PIN\""

    {remote_pinned_output, 0} =
      System.cmd("sh", ["-c", remote_script],
        env: [{"CODEX_PATH", inherited_pin}],
        stderr_to_stdout: true
      )

    assert %{
             "status" => "observed",
             "source" => "pinned_override",
             "path" => ^inherited_pin,
             "version" => "remote-pin-version"
           } = JSON.decode!(remote_pinned_output)

    {remote_bundled_output, 0} =
      System.cmd("sh", ["-c", remote_script],
        env: [{"CODEX_PATH", ""}],
        stderr_to_stdout: true
      )

    assert %{
             "status" => "observed",
             "source" => "bundled_fallback",
             "path" => ^canonical_bundled,
             "version" => "bundled-version"
           } = JSON.decode!(remote_bundled_output)

    capture_fun = BinaryDiagnostics.launch_capture(Tightbeam.Harness.Codex, remote_target, [])
    assert is_function(capture_fun, 0)
    capture = capture_fun.()

    assert capture["selection"]["source"] == "pinned_override"
    assert capture["selection"]["path"] == inherited_pin
    assert capture["evidence_boundary"] =~ "separate bounded selection/version probe"

    next_launch =
      BinaryDiagnostics.observe(
        Tightbeam.Harness.Codex,
        remote_target,
        {:remote_environment, "CODEX_PATH"},
        run: remote_target.sh
      )

    assert next_launch["source"] == "pinned_override"
    assert next_launch["path"] == inherited_pin
  end

  test "unconfigured current adapters report bundled fallback with a warning" do
    probe = fn _module, _target, mode, pin ->
      assert mode == "bundled"
      assert is_nil(pin)
      {:ok, "/srv/tightbeam/adapters/node_modules/vendor/claude", "Claude 2.4"}
    end

    selection = BinaryDiagnostics.observe(Tightbeam.Harness.Claude, @target, nil, probe: probe)

    assert selection["source"] == "bundled_fallback"
    assert selection["path"] == "/srv/tightbeam/adapters/node_modules/vendor/claude"
    assert [warning] = BinaryDiagnostics.warnings_for(selection)
    assert warning =~ "no automatic host-first resolver"
  end

  test "same-harness version differences warn and equality stays quiet" do
    equal = [
      %{
        "host" => "a",
        "harness" => "codex",
        "next_launch" => %{"status" => "observed", "version" => "1"}
      },
      %{
        "host" => "b",
        "harness" => "codex",
        "next_launch" => %{"status" => "observed", "version" => "1"}
      }
    ]

    different = put_in(equal, [Access.at(1), "next_launch", "version"], "2")

    assert BinaryDiagnostics.version_warnings(equal) == []
    assert [warning] = BinaryDiagnostics.version_warnings(different)
    assert warning =~ "a=1, b=2"

    running =
      Enum.map(equal, fn row ->
        Map.put(row, "running", [
          %{
            "selection_observation" => %{
              "status" => "observed",
              "version" => row["next_launch"]["version"]
            }
          }
        ])
      end)

    assert BinaryDiagnostics.version_warnings(running, "running_selection_probe") == []

    running_different =
      put_in(
        running,
        [Access.at(1), "running", Access.at(0), "selection_observation", "version"],
        "2"
      )

    assert [running_warning] =
             BinaryDiagnostics.version_warnings(running_different, "running_selection_probe")

    assert running_warning =~ "a=1, b=2"

    same_host_generations = [
      %{
        "host" => "a",
        "harness" => "codex",
        "running" => [
          %{"selection_observation" => %{"status" => "observed", "version" => "1"}},
          %{"selection_observation" => %{"status" => "observed", "version" => "2"}}
        ]
      }
    ]

    assert BinaryDiagnostics.version_warnings(same_host_generations, "running_selection_probe") ==
             []
  end

  test "an enabled harness without selection capture is present as unsupported" do
    assert "fixture" in Enum.map(BinaryDiagnostics.diagnostic_harnesses(), & &1.wire_name())

    assert %{
             "status" => "unsupported",
             "source" => "unknown",
             "reason" => reason
           } = BinaryDiagnostics.observe(Tightbeam.Harness.Fixture, @target, nil)

    assert reason =~ "does not expose vendor CLI selection diagnostics"
  end

  test "running bundled observations warn even when next launch is explicitly pinned" do
    running = [
      %{
        "generation" => 7,
        "vendor_cli_child" => %{
          "status" => "unknown",
          "source" => "unknown",
          "reason" => "the independent selection probe does not inspect the vendor child"
        },
        "selection_observation" => %{
          "status" => "observed",
          "source" => "bundled_fallback",
          "path" => "/srv/tightbeam/adapters/codex",
          "version" => "codex 1"
        }
      }
    ]

    next_launch = %{
      "status" => "observed",
      "source" => "pinned_override",
      "path" => "/opt/codex",
      "version" => "codex 2"
    }

    assert [warning] = BinaryDiagnostics.warnings_for_row(running, next_launch)
    assert warning =~ "running generation 7 launch selection probe"
    assert warning =~ "bundled CLI"
  end

  test "missing, unprobeable, unreachable, and unknown remain distinct" do
    for status <- ["missing", "unprobeable", "unreachable", "unknown"] do
      probe = fn _module, _target, _mode, _pin -> {:error, status, "synthetic #{status}"} end
      row = BinaryDiagnostics.observe(Tightbeam.Harness.Codex, @target, nil, probe: probe)
      assert row["status"] == status
      assert row["reason"] == "synthetic #{status}"
    end
  end

  test "slow multi-host probes return a bounded unknown for each host" do
    targets =
      Enum.map(["slow-a", "slow-b"], fn host ->
        {host, Tightbeam.Harness.Codex, @target, nil}
      end)

    probe = fn _module, _target, _mode, _pin ->
      Process.sleep(100)
      {:ok, "/tmp/codex", "codex 1"}
    end

    rows =
      BinaryDiagnostics.collect_targets(targets,
        probe: probe,
        target_timeout_ms: 10,
        report_timeout_ms: 500,
        max_concurrency: 2
      )

    for host <- ["slow-a", "slow-b"] do
      assert %{"status" => "unknown", "reason" => reason} = rows[{host, "codex"}]
      assert reason =~ "per-host 10ms bound"
    end
  end

  test "a ready launch without a captured selection is stale, not guessed" do
    assert %{"status" => "stale", "source" => "unknown", "reason" => reason} =
             BinaryDiagnostics.running_selection(%{"capture" => nil, "capture_pending" => false})

    assert reason =~ "predates selection capture"
  end

  test "a launch selection probe does not establish the running vendor child" do
    projected =
      BinaryDiagnostics.running_projection(%{
        "generation" => 12,
        "adapter_generation_started_at_ms" => 90,
        "capture" => %{
          "adapter" => %{"package" => "codex-acp", "version" => "1.12.0"},
          "selection" => %{
            "status" => "observed",
            "source" => "pinned_override",
            "path" => "/opt/codex",
            "version" => "codex 9"
          },
          "observation_started_at_ms" => 100,
          "observation_completed_at_ms" => 110,
          "evidence_boundary" => "separate bounded launch selection probe"
        }
      })

    assert projected["vendor_cli_child"]["status"] == "unknown"
    assert projected["vendor_cli_child"]["reason"] =~ "does not inspect the vendor child"
    assert projected["vendor_cli_child"]["started_at_ms"] == nil
    assert projected["selection_observation"]["path"] == "/opt/codex"
    assert projected["adapter_generation_started_at_ms"] == 90
    assert projected["selection_observation_started_at_ms"] == 100
    assert projected["selection_observation_completed_at_ms"] == 110
  end

  test "Mix doctor human and JSON outputs carry the same source, path, and version" do
    diagnostics = %{
      "status" => "observed",
      "rows" => [
        %{
          "host" => "example-host",
          "harness" => "codex",
          "adapter" => %{"package" => "codex-acp", "version" => "1.12.0"},
          "running_observation" => %{
            "status" => "observed",
            "boundary" => "coordinator ready-generation list"
          },
          "running" => [
            %{
              "generation" => 3,
              "adapter_generation_started_at_ms" => 1_789_999_999_000,
              "adapter" => %{"package" => "codex-acp", "version" => "1.12.0"},
              "selection_observation_started_at_ms" => 1_790_000_000_000,
              "selection_observation_completed_at_ms" => 1_790_000_001_000,
              "evidence_boundary" =>
                "separate probe; does not inspect or fingerprint the vendor child",
              "vendor_cli_child" => %{
                "status" => "unknown",
                "source" => "unknown",
                "started_at_ms" => nil,
                "reason" => "independent probe does not inspect child"
              },
              "selection_observation" => %{
                "status" => "observed",
                "source" => "pinned_override",
                "path" => "/usr/local/bin/codex",
                "version" => "codex 9.1"
              }
            }
          ],
          "next_launch" => %{
            "status" => "observed",
            "source" => "bundled_fallback",
            "path" => "/srv/tb/codex",
            "version" => "codex 8.0"
          },
          "warnings" => ["observed versions differ across hosts"]
        }
      ]
    }

    report = %{
      checks: [],
      github: nil,
      ready: true,
      terminal_credentials: [],
      harness_binary_diagnostics: diagnostics
    }

    json = Mix.Tasks.Tightbeam.Doctor.format(report, :json) |> JSON.decode!()
    human = Mix.Tasks.Tightbeam.Doctor.format(report, :human)

    assert get_in(json, [
             "harness_binary_diagnostics",
             "rows",
             Access.at(0),
             "next_launch",
             "version"
           ]) == "codex 8.0"

    assert get_in(json, [
             "harness_binary_diagnostics",
             "rows",
             Access.at(0),
             "running",
             Access.at(0),
             "selection_observation_completed_at_ms"
           ]) == 1_790_000_001_000

    assert human =~ "vendor CLI child unknown (unknown; independent probe does not inspect child)"
    assert human =~ "(start time unknown time)"
    assert human =~ "adapter generation started at 1789999999000ms since Unix epoch"

    assert human =~
             "launch selection probe observed pinned_override /usr/local/bin/codex version codex 9.1"

    assert human =~ "1790000000000ms since Unix epoch"
    assert human =~ "does not inspect or fingerprint the vendor child"
    refute human =~ "vendor CLI child pinned_override /usr/local/bin/codex version codex 9.1"
    assert human =~ "next launch bundled_fallback /srv/tb/codex version codex 8.0"
    assert human =~ "observed versions differ across hosts"
  end

  test "Mix doctor preserves gateway-fetch failure and the running-state boundary" do
    missing_base =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-doctor-no-gateway-#{System.unique_integer([:positive])}"
      )

    diagnostics = BinaryDiagnostics.fetch_gateway(missing_base)

    assert diagnostics["status"] == "unavailable"
    assert diagnostics["reason"]
    assert diagnostics["boundary"] =~ "cannot establish"
    assert Enum.join(BinaryDiagnostics.human(diagnostics), "\n") =~ diagnostics["boundary"]
  end

  test "coordinator read failure stays unavailable instead of becoming empty running evidence" do
    unavailable =
      BinaryDiagnostics.running_snapshot(:unresponsive,
        fetch: fn _ -> raise "coordinator timed out" end
      )

    observed_empty = BinaryDiagnostics.running_snapshot(:empty, fetch: fn _ -> [] end)

    assert unavailable["status"] == "unavailable"
    assert unavailable["reason"] =~ "coordinator timed out"
    assert unavailable["boundary"] =~ "ready-generation list"
    assert observed_empty["status"] == "observed"
    assert observed_empty["launches"] == []

    report = %{
      "status" => "observed",
      "rows" => [
        %{
          "host" => "example-host",
          "harness" => "codex",
          "adapter" => %{"package" => "codex-acp", "version" => "1.12.0"},
          "running_observation" => Map.drop(unavailable, ["launches"]),
          "running" => [],
          "next_launch" => %{
            "status" => "observed",
            "source" => "pinned_override",
            "path" => "/opt/codex",
            "version" => "codex 9"
          },
          "warnings" => []
        }
      ]
    }

    human = Enum.join(BinaryDiagnostics.human(report), "\n")
    assert human =~ "running generation query unavailable"
    assert human =~ "next launch pinned_override /opt/codex version codex 9"
    refute human =~ "running adapter not observed"
  end
end
