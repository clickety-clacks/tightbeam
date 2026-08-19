defmodule Tightbeam.ReleaseTagWorkflowTest do
  use Tightbeam.TestCase, async: false

  @root Path.expand("..", __DIR__)
  @script Path.join(@root, "scripts/validate_release_tag.sh")
  @workflow Path.join(@root, ".github/workflows/ci.yml")

  test "a 0.1 release tag binds its version, build count, and canonical branch" do
    fixture = git_fixture!()

    assert {_, 0} =
             command("sh", [@script, "v0.1.8+#{fixture.build}", fixture.head], cd: fixture.repo)

    for invalid <- ["v0.1.8", "v0.1.8+#{fixture.build + 1}", "v0.1.9+#{fixture.build}"] do
      {_output, status} = command("sh", [@script, invalid, fixture.head], cd: fixture.repo)
      assert status != 0
    end
  end

  test "the publish job uses the base version for package filenames" do
    workflow = File.read!(@workflow)

    assert workflow =~ "identity=${GITHUB_REF_NAME#v}"
    assert workflow =~ "version=${identity%%+*}"
    assert workflow =~ ~s(sh scripts/validate_release_tag.sh "$GITHUB_REF_NAME" "$GITHUB_SHA")
  end

  defp git_fixture! do
    root = Path.join(System.tmp_dir!(), "release-tag-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(Path.join(repo, "cli"))
    on_exit(fn -> File.rm_rf!(root) end)

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Release Test"])
    git!(repo, ["config", "user.email", "release@test.invalid"])
    File.write!(Path.join(repo, "cli/Cargo.toml"), "[package]\nversion = \"0.1.8\"\n")
    git!(repo, ["add", "cli/Cargo.toml"])
    git!(repo, ["commit", "-m", "base"])
    File.write!(Path.join(repo, "release"), "passing bytes\n")
    git!(repo, ["add", "release"])
    git!(repo, ["commit", "-m", "passing release"])
    head = git!(repo, ["rev-parse", "HEAD"])
    build = git!(repo, ["rev-list", "--count", head]) |> String.to_integer()

    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "origin", "HEAD:refs/heads/0.1.8"])

    %{repo: repo, head: head, build: build}
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
