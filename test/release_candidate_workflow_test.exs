defmodule Tightbeam.ReleaseCandidateWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @script Path.join(@root, "scripts/release_candidate.sh")
  @verifier Path.join(@root, "scripts/verify_release_candidate_manifest.py")
  @workflow Path.join(@root, ".github/workflows/release-candidate.yml")

  test "preparation creates one exact candidate branch and canonical input manifest" do
    fixture = git_fixture!()

    {manifest, 0} =
      command("sh", [@script, "release-candidate/test", fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    assert git!(fixture.repo, ["branch", "--show-current"]) == "release-candidate/test"
    assert git!(fixture.repo, ["rev-parse", "HEAD"]) == fixture.f2
    assert manifest =~ ~s("protected_base_sha":"#{fixture.base}")
    assert manifest =~ ~s("reviewed_feature_shas":["#{fixture.f1}","#{fixture.f2}"])
    assert manifest =~ ~s("source_sha":"#{fixture.f2}")
    assert manifest == String.trim(manifest) <> "\n"
  end

  test "preparation refuses dirty trees before it creates a branch" do
    fixture = git_fixture!()
    File.write!(Path.join(fixture.repo, "untracked"), "dirt")

    {output, status} =
      command("sh", [@script, "release-candidate/dirty", fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    assert status != 0
    assert output =~ "worktree is dirty"
    refute git_ref?(fixture.repo, "refs/heads/release-candidate/dirty")
  end

  test "preparation refuses missing, duplicate, and reordered reviewed SHAs" do
    fixture = git_fixture!()

    cases = [
      [fixture.f2],
      [fixture.f1, fixture.f1, fixture.f2],
      [fixture.f2, fixture.f1]
    ]

    for {features, index} <- Enum.with_index(cases) do
      {output, status} =
        command(
          "sh",
          [@script, "release-candidate/refusal-#{index}", fixture.base | features],
          cd: fixture.repo
        )

      assert status != 0
      assert output =~ ~r/duplicate|missing, reordered, extra, or non-ancestral/
      refute git_ref?(fixture.repo, "refs/heads/release-candidate/refusal-#{index}")
    end
  end

  test "preparation refuses a candidate that is not descended from the protected base" do
    fixture = git_fixture!()
    git!(fixture.repo, ["switch", "--orphan", "unrelated"])
    File.write!(Path.join(fixture.repo, "unrelated"), "unrelated")
    git!(fixture.repo, ["add", "unrelated"])
    git!(fixture.repo, ["commit", "-m", "unrelated"])
    unrelated = git!(fixture.repo, ["rev-parse", "HEAD"])

    {output, status} =
      command("sh", [@script, "release-candidate/unrelated", fixture.base, unrelated],
        cd: fixture.repo
      )

    assert status != 0
    assert output =~ "is not descended from protected base"
  end

  test "workflow has closed triggers, least permission, exact checkout, and both native platforms" do
    workflow = File.read!(@workflow)

    assert workflow =~ ~s(- "release-candidate/**")
    assert workflow =~ "workflow_dispatch:"
    refute workflow =~ "tags:"
    assert workflow =~ "permissions:\n  contents: read"
    assert workflow =~ ~s(ref: ${{ needs.metadata.outputs.candidate_sha }})
    assert workflow =~ "test \"$(git rev-parse HEAD)\" = \"$CANDIDATE_SHA\""
    assert workflow =~ "platform: linux-x86_64"
    assert workflow =~ "platform: darwin-aarch64"
    assert workflow =~ "sh packaging/assemble.sh"
  end

  test "workflow publishes final proof only behind all test and package jobs" do
    workflow = File.read!(@workflow)
    [before_proof, proof_job] = String.split(workflow, "\n  proof:\n", parts: 2)

    assert workflow =~ "package:\n    needs: [metadata, test]"
    assert workflow =~ "proof:\n    needs: [metadata, package]\n    if: ${{ success() }}"
    refute before_proof =~ "release-candidate-proof-"
    assert proof_job =~ "release-candidate-proof-${{ needs.metadata.outputs.candidate_sha }}"

    assert workflow =~
             "No proof artifact exists unless metadata, both test jobs, and both package jobs passed."
  end

  test "manifest verifier accepts complete exact evidence" do
    fixture = proof_fixture!()

    assert {"", 0} = create_manifest(fixture)
    assert {"", 0} = verify_manifest(fixture)
    manifest = File.read!(fixture.manifest)
    assert manifest =~ ~s("schema":"tightbeam-release-candidate-proof/v1")
    assert manifest =~ ~s("protected_base_sha":"#{fixture.base}")
    assert manifest =~ ~s("source_sha":"#{fixture.f2}")
    assert manifest =~ ~s("workflow_sha":"#{fixture.workflow_sha}")
    assert manifest =~ ~s("packages":[)
    assert manifest =~ ~s("toolchains":[)
  end

  test "manifest verifier fails closed on wrong source and package hashes" do
    fixture = proof_fixture!()
    assert {"", 0} = create_manifest(fixture)

    {wrong_source, wrong_status} =
      verify_manifest(fixture, expected_source_sha: String.duplicate("c", 40))

    assert wrong_status != 0
    assert wrong_source =~ "source_sha mismatch"

    File.write!(fixture.package, "changed package")
    {wrong_hash, hash_status} = verify_manifest(fixture)
    assert hash_status != 0
    assert wrong_hash =~ "hash mismatch"
  end

  test "manifest verifier rejects partial and changed toolchain evidence" do
    fixture = proof_fixture!()
    File.rm!(fixture.darwin_toolchain)

    {partial, partial_status} = create_manifest(fixture)
    assert partial_status != 0
    assert partial =~ "missing darwin-aarch64 toolchain record"

    File.write!(fixture.darwin_toolchain, toolchain_record("darwin-aarch64"))
    assert {"", 0} = create_manifest(fixture)
    File.write!(fixture.darwin_toolchain, "changed")
    {changed, changed_status} = verify_manifest(fixture)
    assert changed_status != 0
    assert changed =~ "hash mismatch"
  end

  defp proof_fixture! do
    fixture = git_fixture!()

    git!(fixture.repo, [
      "remote",
      "set-url",
      "origin",
      "git@github.com:clickety-clacks/tightbeam.git"
    ])

    {candidate_input, 0} =
      command(
        "sh",
        [@script, "--check", "release-candidate/proof", fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    evidence = Path.join(fixture.root, "evidence")
    File.mkdir_p!(Path.join(evidence, "packages/darwin-aarch64"))
    File.mkdir_p!(Path.join(evidence, "packages/linux-x86_64"))
    File.mkdir_p!(Path.join(evidence, "toolchains"))
    input = Path.join(evidence, "candidate-input.json")
    File.write!(input, candidate_input)

    darwin_package =
      Path.join(evidence, "packages/darwin-aarch64/tightbeam-1.0.0-darwin-aarch64.tgz")

    linux_package = Path.join(evidence, "packages/linux-x86_64/tightbeam-1.0.0-linux-x86_64.tgz")
    File.write!(darwin_package, "darwin package")
    File.write!(linux_package, "linux package")
    darwin_toolchain = Path.join(evidence, "toolchains/darwin-aarch64.txt")
    linux_toolchain = Path.join(evidence, "toolchains/linux-x86_64.txt")
    File.write!(darwin_toolchain, toolchain_record("darwin-aarch64"))
    File.write!(linux_toolchain, toolchain_record("linux-x86_64"))

    Map.merge(fixture, %{
      candidate_input: input,
      darwin_toolchain: darwin_toolchain,
      evidence: evidence,
      manifest: Path.join(evidence, "release-candidate-manifest.json"),
      package: linux_package,
      workflow_sha: String.duplicate("a", 40)
    })
  end

  defp create_manifest(fixture) do
    command("python3", [
      @verifier,
      "create",
      "--candidate-input",
      fixture.candidate_input,
      "--evidence-root",
      fixture.evidence,
      "--workflow-sha",
      fixture.workflow_sha,
      "--run-id",
      "12345",
      "--output",
      fixture.manifest
    ])
  end

  defp verify_manifest(fixture, options \\ []) do
    source = Keyword.get(options, :expected_source_sha, fixture.f2)

    command("python3", [
      @verifier,
      "verify",
      "--manifest",
      fixture.manifest,
      "--evidence-root",
      fixture.evidence,
      "--repository-root",
      fixture.repo,
      "--expected-repository",
      "clickety-clacks/tightbeam",
      "--expected-ref",
      "refs/heads/release-candidate/proof",
      "--expected-source-sha",
      source,
      "--expected-workflow-sha",
      fixture.workflow_sha
    ])
  end

  defp git_fixture! do
    root = Path.join(System.tmp_dir!(), "release-candidate-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Release Test"])
    git!(repo, ["config", "user.email", "release@test.invalid"])
    File.write!(Path.join(repo, "content"), "base\n")
    git!(repo, ["add", "content"])
    git!(repo, ["commit", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "-u", "origin", "main"])
    File.write!(Path.join(repo, "content"), "feature one\n", [:append])
    git!(repo, ["commit", "-am", "feature one"])
    f1 = git!(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "content"), "feature two\n", [:append])
    git!(repo, ["commit", "-am", "feature two"])
    f2 = git!(repo, ["rev-parse", "HEAD"])
    %{base: base, f1: f1, f2: f2, remote: remote, repo: repo, root: root}
  end

  defp git!(directory, arguments) do
    {output, status} = command("git", arguments, cd: directory)
    assert status == 0, "git #{Enum.join(arguments, " ")} failed:\n#{output}"
    String.trim(output)
  end

  defp git_ref?(directory, ref) do
    {_output, status} = command("git", ["show-ref", "--verify", "--quiet", ref], cd: directory)
    status == 0
  end

  defp command(executable, arguments, options \\ []) do
    command_options =
      Keyword.merge([stderr_to_stdout: true, env: [{"LC_ALL", "C"}]], options)

    System.cmd(executable, arguments, command_options)
  end

  defp toolchain_record(platform) do
    "platform=#{platform}\nErlang/OTP 28\nElixir 1.19.5\nrustc 1.80.0\n"
  end
end
