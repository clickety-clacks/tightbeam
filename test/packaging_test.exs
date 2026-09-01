defmodule Tightbeam.PackagingTest do
  use ExUnit.Case, async: true

  @smoke Path.expand("../packaging/version-smoke.sh", __DIR__)
  @purity Path.expand("../packaging/purity-check.sh", __DIR__)
  @finalize Path.expand("../packaging/finalize-artifact.sh", __DIR__)

  @repo_root Path.expand("..", __DIR__)
  @importer Path.join(@repo_root, "lib/tightbeam/credentials.ex")
  @runtime Path.join(@repo_root, "config/runtime.exs")
  @credential_docs [
    Path.join(@repo_root, "README.md"),
    Path.join(@repo_root, "docs/ONBOARDING.md")
  ]

  test "the systemd daemon-credential docs stay bound to both halves of the importer seam" do
    # systemd LoadCredential delivers the seeded key as $CREDENTIALS_DIRECTORY/<id>.
    # BOTH halves of that path are code the docs must not drift from, or a
    # daemon-onboarded key lands where the gateway never looks and onboarding fails
    # at read time. Both are derived from source here, so a doc-only or code-only
    # rename turns this test red:
    #
    #   1. FILENAME (<id>): systemd delivers the key under the LoadCredential id, so
    #      the documented id must equal the fixed name the importer reads
    #      (read_daemon_credential/2 in credentials.ex).
    #   2. DIRECTORY ($env): the env the docs join that name onto must be an env var
    #      config/runtime.exs actually reads into :credentials_directory — the
    #      standard CREDENTIALS_DIRECTORY systemd sets, not a lookalike.
    credential_name =
      case Regex.run(~r/Path\.join\(directory, "([^"]+)"\)/, File.read!(@importer)) do
        [_, name] -> name
        _ -> flunk("could not find the daemon credential filename in credentials.ex; the anti-drift anchor moved")
      end

    runtime_credential_env_vars =
      ~r/System\.get_env\("([A-Za-z0-9_]*CREDENTIALS_DIRECTORY)"\)/
      |> Regex.scan(File.read!(@runtime))
      |> Enum.map(fn [_, var] -> var end)

    assert "CREDENTIALS_DIRECTORY" in runtime_credential_env_vars,
           "config/runtime.exs must read the standard systemd CREDENTIALS_DIRECTORY " <>
             "into :credentials_directory, or LoadCredential never reaches the importer"

    for doc <- @credential_docs do
      body = File.read!(doc)

      assert body =~ "LoadCredential=#{credential_name}",
             "#{Path.relative_to(doc, @repo_root)} must document LoadCredential=#{credential_name} " <>
               "to match the importer's fixed credential file"

      documented_dir_env =
        case Regex.run(~r/\$([A-Za-z0-9_]+)\/#{Regex.escape(credential_name)}/, body) do
          [_, env] -> env
          _ -> flunk("#{Path.relative_to(doc, @repo_root)} must document the $<dir>/#{credential_name} delivery path")
        end

      assert documented_dir_env in runtime_credential_env_vars,
             "#{Path.relative_to(doc, @repo_root)} joins #{credential_name} onto $#{documented_dir_env}, " <>
               "which config/runtime.exs does not read into :credentials_directory"
    end
  end

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

  test "package purity accepts an archive with only product entries" do
    artifact = artifact_fixture("0.1.6", "0.1.6")

    {output, status} = System.cmd("sh", [@purity, artifact], stderr_to_stdout: true)

    assert status == 0
    assert output =~ "package purity: clean"
  end

  test "package purity refuses an AppleDouble sidecar" do
    artifact = artifact_fixture("0.1.6", "0.1.6", "0.1.6", apple_double: true)

    {output, status} = System.cmd("sh", [@purity, artifact], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "forbidden AppleDouble entry: tightbeam/._package.json"
  end

  for {label, header} <- [
        {"extended attributes", "LIBARCHIVE.xattr.com.apple.provenance"},
        {"SCHILY extended attributes", "SCHILY.xattr.com.apple.provenance"},
        {"access control lists", "SCHILY.acl.access"},
        {"file flags", "SCHILY.fflags"}
      ] do
    test "package purity refuses #{label}" do
      artifact = artifact_fixture("0.1.6", "0.1.6")
      header = unquote(header)
      poison_pax_header!(artifact, header)

      {output, status} = System.cmd("sh", [@purity, artifact], stderr_to_stdout: true)

      assert status == 1
      assert output =~ "forbidden archive metadata header #{header}"
    end
  end

  test "a metadata-poisoned temporary artifact never receives the final installable name" do
    temporary = artifact_fixture("0.1.6", "0.1.6")
    poison_pax_header!(temporary, "SCHILY.fflags")
    final = temporary <> ".final.tgz"

    {output, status} =
      System.cmd("sh", [@finalize, temporary, final, "0.1.6"], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "forbidden archive metadata header SCHILY.fflags"
    refute File.exists?(final)
  end

  defp artifact_fixture(cli_version, gateway_version, manifest_version \\ "0.1.6", opts \\ []) do
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

    if opts[:apple_double] do
      File.write!(Path.join(package, "._package.json"), "host metadata")
    end

    artifact = Path.join(root, "artifact.tgz")

    script = """
    import sys
    import tarfile

    artifact, package = sys.argv[1:]
    with tarfile.open(artifact, "w:gz") as archive:
        archive.add(package, arcname="tightbeam")
    """

    {_, 0} =
      System.cmd("python3", ["-c", script, artifact, package], stderr_to_stdout: true)

    on_exit(fn -> File.rm_rf!(root) end)
    artifact
  end

  defp poison_pax_header!(artifact, header) do
    script = """
    import os
    import sys
    import tarfile

    source, header = sys.argv[1:]
    poisoned = source + ".poisoned"
    found = False

    with tarfile.open(source, "r:gz") as original:
        with tarfile.open(poisoned, "w:gz", format=tarfile.PAX_FORMAT) as output:
            for member in original.getmembers():
                fileobj = original.extractfile(member) if member.isfile() else None
                if member.name == "tightbeam/package.json":
                    member.pax_headers = dict(member.pax_headers)
                    member.pax_headers[header] = "poison"
                    found = True
                output.addfile(member, fileobj)

    if not found:
        raise RuntimeError("package fixture has no manifest to poison")

    os.replace(poisoned, source)
    """

    {_, 0} =
      System.cmd("python3", ["-c", script, artifact, header], stderr_to_stdout: true)

    :ok
  end
end
