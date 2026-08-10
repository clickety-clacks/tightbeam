defmodule Tightbeam.PackagingTest do
  use ExUnit.Case, async: true

  @smoke Path.expand("../packaging/version-smoke.sh", __DIR__)
  @finalize Path.expand("../packaging/finalize-artifact.sh", __DIR__)

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
end
