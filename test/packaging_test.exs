defmodule Tightbeam.PackagingTest do
  use ExUnit.Case, async: true

  @smoke Path.expand("../packaging/version-smoke.sh", __DIR__)
  @finalize Path.expand("../packaging/finalize-artifact.sh", __DIR__)
  @manifest_tool Path.expand("../scripts/package_manifest.py", __DIR__)

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
    manifest = temporary <> ".payload-manifest.json"
    evidence = final <> ".verification-evidence.json"
    create_manifest!(temporary, manifest)

    {output, status} =
      System.cmd(
        "sh",
        [
          @finalize,
          temporary,
          final,
          "0.1.6",
          manifest,
          final <> ".payload-manifest.json",
          evidence
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "gateway version 0.1.5 does not match package version 0.1.6"
    refute File.exists?(final)
    refute File.exists?(evidence)
  end

  test "finalization publishes the package manifest and verification evidence" do
    temporary = artifact_fixture("0.1.6", "0.1.6")
    final = temporary <> ".final.tgz"
    manifest = temporary <> ".payload-manifest.json"
    final_manifest = final <> ".payload-manifest.json"
    evidence = final <> ".verification-evidence.json"
    create_manifest!(temporary, manifest)

    {output, status} =
      System.cmd(
        "sh",
        [@finalize, temporary, final, "0.1.6", manifest, final_manifest, evidence],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "version smoke: manifest=0.1.6 cli=0.1.6 gateway=0.1.6"
    assert File.exists?(final)
    assert File.exists?(final_manifest)
    assert File.exists?(evidence)
  end

  test "a manifest publication failure cannot publish the package" do
    temporary = artifact_fixture("0.1.6", "0.1.6")
    final = temporary <> ".final.tgz"
    manifest = temporary <> ".payload-manifest.json"
    final_manifest = Path.join(Path.dirname(final), "missing/manifest.json")
    evidence = final <> ".verification-evidence.json"
    create_manifest!(temporary, manifest)

    {output, status} =
      System.cmd(
        "sh",
        [@finalize, temporary, final, "0.1.6", manifest, final_manifest, evidence],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "No such file or directory"
    refute File.exists?(final)
    refute File.exists?(final_manifest)
    refute File.exists?(evidence)
  end

  test "finalization refuses a payload manifest that does not match the archive" do
    temporary = artifact_fixture("0.1.6", "0.1.6")
    final = temporary <> ".final.tgz"
    manifest = temporary <> ".payload-manifest.json"
    final_manifest = final <> ".payload-manifest.json"
    evidence = final <> ".verification-evidence.json"
    create_manifest!(temporary, manifest)

    File.write!(
      manifest,
      String.replace(File.read!(manifest), "\"root\":\"tightbeam\"", "\"root\":\"changed\"")
    )

    {output, status} =
      System.cmd(
        "sh",
        [@finalize, temporary, final, "0.1.6", manifest, final_manifest, evidence],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "wrong payload manifest schema"
    refute File.exists?(final)
    refute File.exists?(final_manifest)
    refute File.exists?(evidence)
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

  defp create_manifest!(artifact, manifest) do
    {output, status} =
      System.cmd(
        "python3",
        [@manifest_tool, "create", "--artifact", artifact, "--output", manifest],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
