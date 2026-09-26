defmodule Tightbeam.CodexGuardianDefaultTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.Codex

  test "managed Codex homes default Guardian only when absent across reconciliation routes" do
    cases = [
      {"fresh", nil, false},
      {"root operator config", "model = \"gpt-6-luna\"\n# keep me\n", false},
      {"features table", "[features]\nweb_search = true\n", false},
      {"root dotted features", "features.web_search = true\n[other]\nvalue = 1\n", false},
      {"explicit true", "[features]\nguardian_approval = true # operator\n", true},
      {"explicit false", "[features]\nguardian_approval = false # operator\n", true},
      {"quoted explicit", "[\"features\"]\n\"guardian_approval\" = true\n", true},
      {"dotted explicit", "features.\"guardian_approval\" = false\n", true},
      {"malformed", "[features\nguardian_approval = true\n", true},
      {"incompatible", "features = \"operator-owned\"\n", true}
    ]

    for route <- [:local, :remote, :remote_macos],
        {label, initial, unchanged?} <- cases do
      root =
        Path.join(
          System.tmp_dir!(),
          "tb-codex-guardian-#{route}-#{label}-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(root) end)
      home = Path.join(root, "homes/worker/codex")
      config = Path.join(home, "config.toml")
      File.mkdir_p!(home)
      if initial, do: File.write!(config, initial)

      expected_mode =
        if route == :remote_macos do
          if initial do
            File.chmod!(config, 0o640)
            0o640
          else
            0o600
          end
        end

      target = target(route, root)
      desired = %{harness: :codex, machine: "worker", rails: nil, default_model: nil}

      assert %{home_path: ^home} = Codex.reconcile_home(target, home, desired)
      first = File.read!(config)
      assert %{home_path: ^home} = Codex.reconcile_home(target, home, desired)
      assert File.read!(config) == first

      if expected_mode do
        assert Bitwise.band(File.stat!(config).mode, 0o777) == expected_mode
      end

      if unchanged? do
        assert first == initial
      else
        assert String.contains?(first, "guardian_approval")
        assert get_in(Toml.decode!(first), ["features", "guardian_approval"]) == false

        for line <- String.split(initial || "", "\n", trim: true) do
          assert String.contains?(first, line)
        end
      end

      launch =
        Codex.prepare_launch(target, home,
          common_env: [],
          remote_env: [],
          lineage: "fixture",
          sh_out: nil,
          ensure_workdir: fn _host, _cwd, _owner, _opts -> :ok end
        )

      if route == :local do
        assert {"CODEX_HOME", home} in launch[:env]
      else
        assert "CODEX_HOME=#{home}" in launch[:cmd]
      end
    end
  end

  defp target(:local, root) do
    %{
      base_dir: root,
      host_name: "worker",
      host_config: %{ssh: nil, base_dir: root},
      sh: fn _command -> flunk("local reconciliation must not invoke a command") end
    }
  end

  defp target(:remote, root) do
    %{
      base_dir: root,
      host_name: "worker",
      host_config: %{ssh: "worker", base_dir: root},
      sh: &run_remote_fixture/1
    }
  end

  defp target(:remote_macos, root) do
    shim_dir = install_macos_remote_shims!(root)

    %{
      base_dir: root,
      host_name: "worker",
      host_config: %{ssh: "worker", base_dir: root},
      sh: &run_macos_remote_fixture(&1, shim_dir)
    }
  end

  defp run_remote_fixture(["ssh" | _] = command) do
    command
    |> Enum.drop(6)
    |> Enum.join(" ")
    |> then(&System.cmd("sh", ["-c", &1], stderr_to_stdout: true))
  end

  defp run_remote_fixture(["rsync" | _] = command) do
    source = Enum.at(command, -2) |> String.trim_trailing("/")
    destination = command |> List.last() |> String.replace_prefix("worker:", "")

    if String.ends_with?(List.last(command), "/") do
      File.mkdir_p!(destination)
      System.cmd("cp", ["-a", source <> "/.", destination], stderr_to_stdout: true)
    else
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
      {"", 0}
    end
  end

  defp run_macos_remote_fixture(["ssh" | _] = command, shim_dir) do
    script = command |> Enum.drop(6) |> Enum.join(" ")
    path = shim_dir <> ":" <> System.fetch_env!("PATH")

    System.cmd("sh", ["-c", script],
      stderr_to_stdout: true,
      env: [{"PATH", path}]
    )
  end

  defp run_macos_remote_fixture(["rsync" | _] = command, _shim_dir) do
    run_remote_fixture(command)
  end

  defp install_macos_remote_shims!(root) do
    shim_dir = Path.join(root, "macos-command-shims")
    stat = System.find_executable("stat") || raise "stat is required by the macOS fixture"
    chmod = System.find_executable("chmod") || raise "chmod is required by the macOS fixture"
    File.mkdir_p!(shim_dir)

    write_executable!(
      Path.join(shim_dir, "stat"),
      """
      #!/bin/sh
      if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
        if mode=$("#{stat}" -f %Lp "$3" 2>/dev/null); then
          case "$mode" in
            [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7])
              printf '%s\n' "$mode"
              exit 0
              ;;
          esac
        fi
        exec "#{stat}" -c %a "$3"
      fi
      exit 64
      """
    )

    write_executable!(
      Path.join(shim_dir, "chmod"),
      """
      #!/bin/sh
      case "$1" in
        --reference=*) exit 64 ;;
      esac
      exec "#{chmod}" "$@"
      """
    )

    shim_dir
  end

  defp write_executable!(path, bytes) do
    File.write!(path, bytes)
    File.chmod!(path, 0o755)
  end
end
