defmodule Tightbeam.PackagingActivationTest do
  use ExUnit.Case, async: true

  @selector Path.expand("../packaging/tightbeam-select", __DIR__)
  @assemble Path.expand("../packaging/assemble.sh", __DIR__)

  test "release assembly ships the selector used by the upgrade runbook" do
    assert File.read!(@assemble) =~ ~s(cp packaging/tightbeam-select "$OUT/bin/tightbeam-select")
    assert Bitwise.band(File.stat!(@selector).mode, 0o111) != 0
  end

  test "staging leaves the selected build alone; selection verifies, switches, and keeps switch-back bytes" do
    root = fixture_root()
    install_root = Path.join(root, "installation")
    previous = package_fixture(root, "0.1.9", String.duplicate("a", 40))
    previous_stage = stage!(previous, install_root)

    assert previous_stage["state"] == "staged"
    assert previous_stage["sourceCommit"] == String.duplicate("a", 40)
    assert previous_stage["packageSha256"] == previous.sha256
    assert selected_link(install_root) == nil

    select!(install_root, previous_stage["buildId"])
    previous_cli = candidate_cli(install_root, previous_stage["buildId"])
    previous_bytes = File.read!(previous_cli)
    assert selected_link(install_root) == "builds/#{previous_stage["buildId"]}"

    next_release = package_fixture(root, "0.1.10", String.duplicate("b", 40))
    next_stage = stage!(next_release, install_root)
    next_cli = candidate_cli(install_root, next_stage["buildId"])

    assert selected_link(install_root) == "builds/#{previous_stage["buildId"]}"
    assert next_stage["state"] == "staged"
    assert next_stage["sourceCommit"] == String.duplicate("b", 40)
    staged_bytes = File.read!(next_cli)

    File.write!(next_cli, staged_bytes <> "# changed after stage\n")
    File.chmod!(next_cli, 0o755)
    {changed_output, changed_status} = select(install_root, next_stage["buildId"])

    assert changed_status == 1
    assert changed_output =~ "changed after verification"
    assert selected_link(install_root) == "builds/#{previous_stage["buildId"]}"
    assert File.read!(previous_cli) == previous_bytes

    File.write!(next_cli, staged_bytes)
    File.chmod!(next_cli, 0o755)
    selected = select!(install_root, next_stage["buildId"])

    assert selected["state"] == "selected"
    assert selected["previousBuildId"] == previous_stage["buildId"]
    assert selected_link(install_root) == "builds/#{next_stage["buildId"]}"
    assert File.read!(previous_cli) == previous_bytes
    assert File.exists?(candidate_cli(install_root, previous_stage["buildId"]))

    rollback = select!(install_root, previous_stage["buildId"])
    assert rollback["state"] == "selected"
    assert rollback["previousBuildId"] == next_stage["buildId"]
    assert selected_link(install_root) == "builds/#{previous_stage["buildId"]}"
    assert File.read!(previous_cli) == previous_bytes
  end

  test "a checksum failure and an interrupted extraction leave the old selected build intact" do
    root = fixture_root()
    install_root = Path.join(root, "installation")
    previous = package_fixture(root, "0.1.9", String.duplicate("c", 40))
    previous_stage = stage!(previous, install_root)
    select!(install_root, previous_stage["buildId"])
    previous_cli = candidate_cli(install_root, previous_stage["buildId"])
    previous_bytes = File.read!(previous_cli)
    previous_link = selected_link(install_root)

    bad_release = package_fixture(root, "0.1.10", String.duplicate("d", 40))
    File.write!(bad_release.package, File.read!(bad_release.package) <> "changed archive bytes")
    {checksum_output, checksum_status} = stage(bad_release, install_root)

    assert checksum_status == 1
    assert checksum_output =~ "does not match SHA256SUMS"
    assert selected_link(install_root) == previous_link
    assert File.read!(previous_cli) == previous_bytes

    interrupted = package_fixture(root, "0.1.11", String.duplicate("e", 40))
    real_tar = System.find_executable("tar") || flunk("tar is required for package staging")

    node =
      System.find_executable("node") ||
        flunk("Node.js 20 or later is required for package staging")

    kill =
      System.find_executable("kill") ||
        flunk("kill is required for the interrupted-stage fixture")

    shim_dir = Path.join(root, "tar-shim")
    File.mkdir_p!(shim_dir)
    ready_file = Path.join(root, "tar-ready")
    tar_pid_file = Path.join(root, "tar-pid")
    shim = Path.join(shim_dir, "tar")

    File.write!(
      shim,
      "#!/bin/sh\n" <>
        "if [ \"$1\" = \"-xzf\" ]; then\n" <>
        "  printf '%s\\n' \"$$\" > \"$TB_TAR_PID_FILE\"\n" <>
        "  : > \"$TB_TAR_READY_FILE\"\n" <>
        "  exec sleep 30\n" <>
        "fi\n" <>
        "exec \"$TB_REAL_TAR\" \"$@\"\n"
    )

    File.chmod!(shim, 0o755)

    env = [
      {"PATH", shim_dir <> ":" <> System.get_env("PATH", "")},
      {"TB_REAL_TAR", real_tar},
      {"TB_TAR_PID_FILE", tar_pid_file},
      {"TB_TAR_READY_FILE", ready_file}
    ]

    port =
      Port.open(
        {:spawn_executable, node},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [
            @selector,
            "stage",
            "--root",
            install_root,
            "--package",
            interrupted.package,
            "--checksums",
            interrupted.checksums,
            "--provenance",
            interrupted.provenance
          ],
          env:
            Enum.map(env, fn {name, value} ->
              {String.to_charlist(name), String.to_charlist(value)}
            end)
        ]
      )

    {:os_pid, node_pid} = Port.info(port, :os_pid)

    try do
      await_file!(ready_file)
      tar_pid = File.read!(tar_pid_file) |> String.trim()
      kill_pid(kill, node_pid)
      kill_pid(kill, tar_pid)
    after
      kill_pid(kill, node_pid)
      if File.exists?(tar_pid_file), do: kill_pid(kill, File.read!(tar_pid_file) |> String.trim())

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    interrupted_sha = "sha256-#{interrupted.sha256}"
    assert selected_link(install_root) == previous_link
    assert File.read!(previous_cli) == previous_bytes
    refute File.exists?(Path.join([install_root, "builds", interrupted_sha]))
    assert File.ls!(Path.join(install_root, ".staging")) != []
  end

  test "selection warns about skipped policies and continues when the rule check fails" do
    root = fixture_root()
    install_root = Path.join(root, "installation")
    previous = package_fixture(root, "0.1.9", String.duplicate("f", 40))
    previous_stage = stage!(previous, install_root)
    select!(install_root, previous_stage["buildId"])

    candidate = package_fixture(root, "0.1.10", String.duplicate("1", 40))
    candidate_stage = stage!(candidate, install_root)
    rule_file = Path.join([install_root, "installed-base", "identity", "rules", "preflight.toml"])
    original_rules = File.read!(rule_file)
    original_sha = :crypto.hash(:sha256, original_rules)

    {output, status} = select(install_root, candidate_stage["buildId"], "ok")

    assert status == 0
    assert output =~ ~s(rules/preflight.toml: policy "legacy": purpose "retired" is retired)
    assert selected_link(install_root) == "builds/#{candidate_stage["buildId"]}"
    assert :crypto.hash(:sha256, File.read!(rule_file)) == original_sha

    fallback = package_fixture(root, "0.1.11", String.duplicate("2", 40))
    fallback_stage = stage!(fallback, install_root)

    {incomplete_output, incomplete_status} = select(install_root, fallback_stage["buildId"], "fail")

    assert incomplete_status == 0
    assert incomplete_output =~ "rule check could not complete"
    assert selected_link(install_root) == "builds/#{fallback_stage["buildId"]}"
  end

  defp fixture_root do
    name = "tightbeam-package-activation-#{System.unique_integer([:positive, :monotonic])}"
    root = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp package_fixture(parent, version, commit) do
    platform = node_platform!()
    filename = "tightbeam-#{version}-#{platform}-#{String.slice(commit, 0, 7)}.tgz"
    fixture_dir = Path.join(parent, "fixture-#{String.slice(commit, 0, 7)}")
    package_root = Path.join(fixture_dir, "tightbeam")
    File.mkdir_p!(Path.join(package_root, "bin"))
    File.mkdir_p!(Path.join(package_root, "release/bin"))
    File.mkdir_p!(Path.join(package_root, "release/releases"))
    File.mkdir_p!(Path.join(package_root, "release/lib/tightbeam-#{version}/ebin"))

    File.write!(
      Path.join(package_root, "package.json"),
      JSON.encode!(%{name: "tightbeam", version: version})
    )

    File.write!(
      Path.join(package_root, "bin/tightbeam"),
      "#!/bin/sh\nprintf '%s\\n' '#{version}'\n"
    )

    File.write!(
      Path.join(package_root, "bin/tightbeam-gateway"),
      "#!/bin/sh\n" <>
        "if [ \"$1\" = eval ]; then\n" <>
        "  case \"${TB_RULE_PREFLIGHT_MODE:-ok}\" in\n" <>
        "    fail) printf '%s\\n' 'checker failed' >&2; exit 42 ;;\n" <>
        "    silent) exit 0 ;;\n" <>
        "    *)\n" <>
        "      case \"$2\" in *Tightbeam.RulePreflight.run*) ;; *) exit 43 ;; esac\n" <>
        "      [ -r \"$TIGHTBEAM_BASE_DIR/identity/rules/preflight.toml\" ] || exit 44\n" <>
        "      [ ! -w \"$TIGHTBEAM_BASE_DIR/identity/rules\" ] || exit 45\n" <>
        "      printf '%s\\n' 'TIGHTBEAM_RULE_PREFLIGHT_JSON:{\"complete\":true,\"recording_available\":true,\"warnings\":[\"rules/preflight.toml: policy \\\"legacy\\\": purpose \\\"retired\\\" is retired; policy has no effect\"],\"unavailable_verbs\":[],\"skipped_policies\":[]}'\n" <>
        "      exit 0 ;;\n" <>
        "  esac\n" <>
        "fi\n" <>
        "exit 0\n"
    )
    File.write!(Path.join(package_root, "release/bin/tightbeam_gateway"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(package_root, "release/releases/start_erl.data"), "28.5 #{version}\n")

    File.write!(
      Path.join(package_root, "release/lib/tightbeam-#{version}/ebin/tightbeam.app"),
      "{application,tightbeam,[]}\n"
    )

    for executable <- [
          Path.join(package_root, "bin/tightbeam"),
          Path.join(package_root, "bin/tightbeam-gateway"),
          Path.join(package_root, "release/bin/tightbeam_gateway")
        ] do
      File.chmod!(executable, 0o755)
    end

    archive = Path.join(parent, filename)

    {output, 0} =
      System.cmd("tar", ["-czf", archive, "tightbeam"], cd: fixture_dir, stderr_to_stdout: true)

    assert output == ""
    sha256 = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    checksums = Path.join(parent, "SHA256SUMS-#{String.slice(commit, 0, 7)}")
    provenance = Path.join(parent, "release-provenance-#{String.slice(commit, 0, 7)}.json")
    File.write!(checksums, "#{sha256}  #{filename}\n")

    File.write!(
      provenance,
      JSON.encode!(%{
        repository: "clickety-clacks/tightbeam",
        tag: "v#{version}",
        commit: commit,
        workflow: "https://github.com/clickety-clacks/tightbeam/actions/runs/1",
        assets: [filename],
        checksums: "SHA256SUMS"
      })
    )

    %{package: archive, checksums: checksums, provenance: provenance, sha256: sha256}
  end

  defp node_platform! do
    node =
      System.find_executable("node") ||
        flunk("Node.js 20 or later is required for package staging")

    {platform, 0} = System.cmd(node, ["-p", "process.platform + '-' + process.arch"])

    case String.trim(platform) do
      "darwin-arm64" -> "darwin-aarch64"
      "linux-x64" -> "linux-x86_64"
      other -> flunk("unsupported package fixture host #{other}")
    end
  end

  defp stage(release, install_root) do
    System.cmd(
      System.find_executable("node") ||
        flunk("Node.js 20 or later is required for package staging"),
      [
        @selector,
        "stage",
        "--root",
        install_root,
        "--package",
        release.package,
        "--checksums",
        release.checksums,
        "--provenance",
        release.provenance
      ],
      stderr_to_stdout: true
    )
  end

  defp stage!(release, install_root) do
    {output, 0} = stage(release, install_root)
    JSON.decode!(output)
  end

  defp select(install_root, build_id, mode \\ "ok") do
    base_dir = Path.join(install_root, "installed-base")
    rule_file = Path.join([base_dir, "identity", "rules", "preflight.toml"])
    File.mkdir_p!(Path.dirname(rule_file))
    File.write!(rule_file, "[[rule]]\nname = \"preflight-sample\"\n")

    System.cmd(
      System.find_executable("node") ||
        flunk("Node.js 20 or later is required for package staging"),
      [
        @selector,
        "select",
        "--root",
        install_root,
        "--build",
        build_id,
        "--base-dir",
        base_dir
      ],
      env: [{"TB_RULE_PREFLIGHT_MODE", mode}],
      stderr_to_stdout: true
    )
  end

  defp select!(install_root, build_id) do
    {output, 0} = select(install_root, build_id)
    output
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.find(&String.starts_with?(&1, "{"))
    |> JSON.decode!()
  end

  defp selected_link(install_root) do
    current = Path.join(install_root, "current")

    case File.lstat(current) do
      {:ok, %File.Stat{type: :symlink}} -> File.read_link!(current)
      {:ok, _other} -> nil
      {:error, :enoent} -> nil
      {:error, reason} -> raise "could not inspect current selector: #{inspect(reason)}"
    end
  end

  defp candidate_cli(install_root, build_id) do
    Path.join([install_root, "builds", build_id, "tightbeam", "bin", "tightbeam"])
  end

  defp await_file!(file, attempts \\ 500)
  defp await_file!(_file, 0), do: flunk("interrupted-stage fixture did not reach extraction")

  defp await_file!(file, attempts) do
    if File.exists?(file) do
      :ok
    else
      Process.sleep(10)
      await_file!(file, attempts - 1)
    end
  end

  defp kill_pid(kill, pid) do
    {_output, _status} = System.cmd(kill, ["-KILL", to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
