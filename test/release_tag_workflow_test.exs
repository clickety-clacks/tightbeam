defmodule Tightbeam.ReleaseTagWorkflowTest do
  use Tightbeam.TestCase, async: false

  @root Path.expand("..", __DIR__)
  @script Path.join(@root, "scripts/validate_release_tag.sh")

  test "a 0.1 release tag binds its version, build count, and current main" do
    fixture = git_fixture!("0.1.8", "main")
    git!(fixture.repo, ["push", "origin", "#{fixture.parent}:refs/heads/0.1.8"])

    assert {_, 0} =
             command("sh", [@script, "v0.1.8+#{fixture.build}", fixture.head], cd: fixture.repo)

    for invalid <- ["v0.1.8", "v0.1.8+#{fixture.build + 1}", "v0.1.9+#{fixture.build}"] do
      {_output, status} = command("sh", [@script, invalid, fixture.head], cd: fixture.repo)
      assert status != 0
    end

    advance_canonical!(fixture)

    {_output, status} =
      command("sh", [@script, "v0.1.8+#{fixture.build}", fixture.head], cd: fixture.repo)

    assert status != 0
  end

  test "a later release rejects a superseded main tip" do
    fixture = git_fixture!("0.2.0", "main")
    git!(fixture.repo, ["push", "origin", "#{fixture.parent}:refs/heads/0.2.0"])

    assert {_, 0} =
             command("sh", [@script, "v0.2.0+#{fixture.build}", fixture.head], cd: fixture.repo)

    advance_canonical!(fixture)

    {_output, status} =
      command("sh", [@script, "v0.2.0+#{fixture.build}", fixture.head], cd: fixture.repo)

    assert status != 0
  end

  test "canonical staging and publication accept the selected SHA only while it is on main" do
    fixture = git_fixture!("0.1.17", "main")
    tag = "v0.1.17+#{fixture.build}"
    args = [@script, tag, fixture.head, "--selected-candidate"]

    assert {_, 0} = command("sh", args, cd: fixture.repo)
    advance_canonical!(fixture)
    git!(fixture.repo, ["checkout", "--detach", fixture.head])

    assert {_, 0} = command("sh", args, cd: fixture.repo)
    {output, status} = command("sh", Enum.drop(args, -1), cd: fixture.repo)
    assert status != 0
    assert output =~ "is not the canonical refs/heads/main tip"

    for invalid <- ["v0.1.17+#{fixture.build + 1}", "v0.1.18+#{fixture.build}"] do
      {_, status} =
        command("sh", [@script, invalid, fixture.head, "--selected-candidate"], cd: fixture.repo)

      assert status != 0
    end

    git!(fixture.repo, ["checkout", "--detach", fixture.parent])
    git!(fixture.repo, ["commit", "--allow-empty", "-m", "divergent canonical tip"])
    divergent = git!(fixture.repo, ["rev-parse", "HEAD"])
    git!(fixture.repo, ["push", "--force", "origin", "HEAD:refs/heads/main"])
    git!(fixture.repo, ["update-ref", "refs/remotes/origin/main", fixture.head])
    git!(fixture.repo, ["checkout", "--detach", fixture.head])

    {output, status} = command("sh", args, cd: fixture.repo)
    assert status != 0
    assert output =~ "is not in canonical refs/heads/main history at #{divergent}"
  end

  test "only canonical staging and publication opt into selected candidate validation" do
    candidate = File.read!(Path.join(@root, ".github/workflows/release-candidate.yml"))
    legacy = File.read!(Path.join(@root, ".github/workflows/ci.yml"))

    assert candidate =~
             ~s(sh scripts/validate_release_tag.sh "$release_tag" "$CANDIDATE_SHA" --selected-candidate)

    assert legacy =~ ~s(sh scripts/validate_release_tag.sh "$GITHUB_REF_NAME" "$GITHUB_SHA")
    refute legacy =~ "--selected-candidate"
  end

  test "the publish workflow validates and publishes the selected candidate" do
    workflow = File.read!(Path.join(@root, ".github/workflows/publish-release.yml"))

    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "candidate_run_id:"
    assert workflow =~ "candidate_sha:"
    assert workflow =~ "install_approved_sha:"
    assert workflow =~ "soak_outcome:"
    assert workflow =~ "soaked_sha:"

    assert workflow =~
             ~s(sh scripts/validate_release_tag.sh "$RELEASE_TAG" "$CANDIDATE_SHA" --selected-candidate)

    assert workflow =~ "release-candidate-proof-" <> <<36>> <> "{{ inputs.candidate_sha }}"
    assert workflow =~ "release-candidate-stage-" <> <<36>> <> "{{ inputs.candidate_sha }}"
    assert workflow =~ "verify_release_candidate_stage.py verify"
    assert workflow =~ "workflow: $publication_workflow"
    assert workflow =~ "workflow_sha: $candidate_workflow_sha"
    assert workflow =~ "run-id: " <> <<36>> <> "{{ inputs.candidate_run_id }}"
    assert workflow =~ "target_commitish: " <> <<36>> <> "{{ inputs.candidate_sha }}"
    assert workflow =~ "Create the GitHub Release"
    refute workflow =~ "packaging/assemble.sh"
    refute workflow =~ "cargo build"
  end

  defp git_fixture!(version, canonical_branch) do
    root = Path.join(System.tmp_dir!(), "release-tag-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(Path.join(repo, "cli"))
    on_exit(fn -> File.rm_rf!(root) end)

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Release Test"])
    git!(repo, ["config", "user.email", "release@test.invalid"])
    File.write!(Path.join(repo, "cli/Cargo.toml"), "[package]\nversion = \"#{version}\"\n")
    git!(repo, ["add", "cli/Cargo.toml"])
    git!(repo, ["commit", "-m", "base"])
    File.write!(Path.join(repo, "release"), "passing bytes\n")
    git!(repo, ["add", "release"])
    git!(repo, ["commit", "-m", "passing release"])
    head = git!(repo, ["rev-parse", "HEAD"])
    parent = git!(repo, ["rev-parse", "HEAD^"])
    build = git!(repo, ["rev-list", "--count", head]) |> String.to_integer()

    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "origin", "HEAD:refs/heads/#{canonical_branch}"])

    %{repo: repo, head: head, parent: parent, build: build, canonical_branch: canonical_branch}
  end

  defp advance_canonical!(fixture) do
    File.write!(Path.join(fixture.repo, "superseding"), "new canonical tip\n")
    git!(fixture.repo, ["add", "superseding"])
    git!(fixture.repo, ["commit", "-m", "advance canonical"])
    git!(fixture.repo, ["push", "origin", "HEAD:refs/heads/#{fixture.canonical_branch}"])
  end

  defp git!(directory, arguments) do
    {output, status} = command("git", arguments, cd: directory)
    assert status == 0, "git #{Enum.join(arguments, " ")} failed:\n#{output}"
    String.trim(output)
  end

  defp command(executable, arguments, options) do
    System.cmd(executable, arguments, Keyword.merge([stderr_to_stdout: true], options))
  end
end
