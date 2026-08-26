defmodule Tightbeam.PackagingTest do
  use ExUnit.Case, async: true

  @smoke Path.expand("../packaging/version-smoke.sh", __DIR__)
  @finalize Path.expand("../packaging/finalize-artifact.sh", __DIR__)
  @gateway Path.expand("../packaging/tightbeam-gateway", __DIR__)

  test "the extracted artifact refuses a stale gateway version" do
    artifact = artifact_fixture("0.1.6", "0.1.5")

    {output, status} = System.cmd("sh", [@smoke, artifact, "0.1.6"], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "gateway version 0.1.5 does not match package version 0.1.6"
  end

  test "the extracted artifact proves matching CLI and gateway versions" do
    artifact = artifact_fixture("0.1.6", "0.1.6")

    {output, status} = System.cmd("sh", [@smoke, artifact, "0.1.6"], stderr_to_stdout: true)

    assert status == 0
    assert output =~ "version smoke: manifest=0.1.6 cli=0.1.6 gateway=0.1.6"
  end

  test "a rejected temporary artifact never receives the final installable name" do
    temporary = artifact_fixture("0.1.6", "0.1.5")
    final = temporary <> ".final.tgz"

    {output, status} =
      System.cmd("sh", [@finalize, temporary, final, "0.1.6"], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "gateway version 0.1.5 does not match package version 0.1.6"
    refute File.exists?(final)
  end

  test "the extracted artifact refuses a wrong manifest version" do
    artifact = artifact_fixture("0.1.6", "0.1.6", "0.1.5")

    {output, status} = System.cmd("sh", [@smoke, artifact, "0.1.6"], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "manifest version 0.1.5 does not match package version 0.1.6"
  end

  test "the extracted artifact refuses a missing manifest" do
    artifact = artifact_fixture("0.1.6", "0.1.6", nil)

    {output, status} = System.cmd("sh", [@smoke, artifact, "0.1.6"], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "extracted artifact has no package.json"
  end

  test "release commands keep the first cookie across an on-disk package upgrade" do
    fixture = gateway_fixture("FIRST_COOKIE")

    assert {_, 0} = run_gateway(fixture, ["pid"])
    assert File.read!(fixture.seen_cookie) == "FIRST_COOKIE\n"
    assert File.read!(fixture.seen_args) == "pid\n"
    assert File.stat!(fixture.persisted_cookie).mode |> Bitwise.band(0o777) == 0o600

    File.write!(fixture.packaged_cookie, "REPLACEMENT_COOKIE\n")

    assert {_, 0} = run_gateway(fixture, ["stop"])
    assert File.read!(fixture.seen_cookie) == "FIRST_COOKIE\n"
    assert File.read!(fixture.seen_args) == "stop\n"
  end

  test "an explicit release cookie remains authoritative and is not persisted" do
    fixture = gateway_fixture("PACKAGED_COOKIE")

    assert {_, 0} = run_gateway(fixture, ["pid"], [{"RELEASE_COOKIE", "EXPLICIT_COOKIE"}])
    assert File.read!(fixture.seen_cookie) == "EXPLICIT_COOKIE\n"
    refute File.exists?(fixture.persisted_cookie)
  end

  test "a persisted cookie symlink is refused without touching its target" do
    fixture = gateway_fixture("PACKAGED_COOKIE")
    target = Path.join(Path.dirname(fixture.base_dir), "unrelated")
    File.mkdir_p!(fixture.base_dir)
    File.write!(target, "DO_NOT_TOUCH\n")
    File.ln_s!(target, fixture.persisted_cookie)

    assert {output, 1} = run_gateway(fixture, ["pid"])
    assert output =~ "release cookie must not be a symlink"
    assert File.read!(target) == "DO_NOT_TOUCH\n"
  end

  test "an invalid persisted cookie is refused before the release runs" do
    fixture = gateway_fixture("PACKAGED_COOKIE")
    File.mkdir_p!(fixture.base_dir)
    File.write!(fixture.persisted_cookie, "not valid\n")

    assert {output, 1} = run_gateway(fixture, ["pid"])
    assert output =~ "invalid release cookie"
    refute File.exists?(fixture.seen_args)
  end

  test "the launcher maps TERM and INT to graceful TERM for the release" do
    for signal <- ["-TERM", "-INT"] do
      fixture = gateway_fixture("SIGNAL_COOKIE")

      task = Task.async(fn -> run_gateway(fixture, []) end)
      assert eventually(fn -> File.exists?(fixture.pid) end)

      pid = fixture.pid |> File.read!() |> String.trim()
      assert {_, 0} = System.cmd("kill", [signal, pid], stderr_to_stdout: true)
      assert {_, 0} = Task.await(task, 5_000)
      assert File.read!(fixture.seen_signal) == "TERM\n"
      File.rm!(fixture.pid)
    end
  end

  defp artifact_fixture(cli_version, gateway_version, manifest_version \\ "0.1.6") do
    root = Path.join(System.tmp_dir!(), "tightbeam-package-#{System.unique_integer([:positive])}")
    package = Path.join(root, "tightbeam")
    File.mkdir_p!(Path.join(package, "bin"))
    File.mkdir_p!(Path.join(package, "release/releases"))

    cli = Path.join(package, "bin/tightbeam")
    File.write!(cli, "#!/bin/sh\necho #{cli_version}\n")
    File.chmod!(cli, 0o755)

    File.write!(
      Path.join(package, "release/releases/start_erl.data"),
      "16.4 #{gateway_version}\n"
    )

    if manifest_version do
      File.write!(Path.join(package, "package.json"), ~s({"version":"#{manifest_version}"}))
    end

    artifact = Path.join(root, "artifact.tgz")
    {_, 0} = System.cmd("tar", ["czf", artifact, "tightbeam"], cd: root)
    on_exit(fn -> File.rm_rf!(root) end)
    artifact
  end

  defp gateway_fixture(cookie) do
    root = Path.join(System.tmp_dir!(), "tightbeam-gateway-#{System.unique_integer([:positive])}")
    package = Path.join(root, "package")
    release_bin = Path.join(package, "release/bin")
    release_meta = Path.join(package, "release/releases")
    base_dir = Path.join(root, "base")

    File.mkdir_p!(Path.join(package, "bin"))
    File.mkdir_p!(release_bin)
    File.mkdir_p!(release_meta)
    File.cp!(@gateway, Path.join(package, "bin/tightbeam-gateway"))

    fake_release = Path.join(release_bin, "tightbeam_gateway")

    File.write!(
      fake_release,
      """
      #!/bin/sh
      printf '%s\\n' "$RELEASE_COOKIE" > "$SEEN_COOKIE"
      printf '%s\\n' "$@" > "$SEEN_ARGS"
      if [ "${1:-}" = stop ]; then
        kill -TERM "$(cat "$SEEN_RELEASE_PID")"
        exit 0
      fi
      if [ "${1:-}" = start ]; then
        trap 'printf "TERM\\n" > "$SEEN_SIGNAL"; exit 0' TERM
        trap 'printf "INT\\n" > "$SEEN_SIGNAL"; exit 2' INT
        printf '%s\\n' "$$" > "$SEEN_RELEASE_PID"
        printf '%s\\n' "$PPID" > "$SEEN_PID"
        while :; do sleep 1 & wait $!; done
      fi
      """
    )

    launcher = Path.join(package, "bin/tightbeam-gateway")
    File.chmod!(launcher, 0o755)
    File.chmod!(fake_release, 0o755)
    packaged_cookie = Path.join(release_meta, "COOKIE")
    File.write!(packaged_cookie, cookie <> "\n")

    on_exit(fn ->
      if File.exists?(Path.join(root, "pid")) do
        pid = root |> Path.join("pid") |> File.read!() |> String.trim()
        System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
      end

      if File.exists?(Path.join(root, "release-pid")) do
        pid = root |> Path.join("release-pid") |> File.read!() |> String.trim()
        System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
      end

      File.rm_rf!(root)
    end)

    %{
      launcher: launcher,
      base_dir: base_dir,
      packaged_cookie: packaged_cookie,
      persisted_cookie: Path.join(base_dir, "release.cookie"),
      seen_cookie: Path.join(root, "seen-cookie"),
      seen_args: Path.join(root, "seen-args"),
      seen_signal: Path.join(root, "seen-signal"),
      release_pid: Path.join(root, "release-pid"),
      pid: Path.join(root, "pid")
    }
  end

  defp run_gateway(fixture, args, extra_env \\ []) do
    env =
      ([
         {"TIGHTBEAM_BASE_DIR", fixture.base_dir},
         {"SEEN_COOKIE", fixture.seen_cookie},
         {"SEEN_ARGS", fixture.seen_args},
         {"SEEN_SIGNAL", fixture.seen_signal},
         {"SEEN_RELEASE_PID", fixture.release_pid},
         {"SEEN_PID", fixture.pid},
         {"RELEASE_COOKIE", nil}
       ] ++ extra_env)
      |> Map.new()
      |> Map.to_list()

    System.cmd(fixture.launcher, args, env: env, stderr_to_stdout: true)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
