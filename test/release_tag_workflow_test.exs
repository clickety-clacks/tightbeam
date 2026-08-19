defmodule Tightbeam.ReleaseTagWorkflowTest do
  use Tightbeam.TestCase, async: false

  @root Path.expand("..", __DIR__)
  @script Path.join(@root, "scripts/validate_release_tag.sh")
  @workflow Path.join(@root, ".github/workflows/ci.yml")

  test "a 0.1 release tag binds its version, build count, and canonical branch" do
    fixture = git_fixture!("0.1.8", "0.1.8")

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

  test "a later release uses main and rejects a superseded main tip" do
    fixture = git_fixture!("0.2.0", "main")
    git!(fixture.repo, ["push", "origin", "#{fixture.parent}:refs/heads/0.2.0"])

    assert {_, 0} =
             command("sh", [@script, "v0.2.0+#{fixture.build}", fixture.head], cd: fixture.repo)

    advance_canonical!(fixture)
    {_output, status} =
      command("sh", [@script, "v0.2.0+#{fixture.build}", fixture.head], cd: fixture.repo)

    assert status != 0
  end

  test "the publish job uses the base version for package filenames" do
    workflow = File.read!(@workflow)

    assert workflow =~ "identity=${GITHUB_REF_NAME#v}"
    assert workflow =~ "version=${identity%%+*}"
    assert workflow =~ ~s(sh scripts/validate_release_tag.sh "$GITHUB_REF_NAME" "$GITHUB_SHA")
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
