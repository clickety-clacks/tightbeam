defmodule Tightbeam.ReleaseProvenancePackagingTest do
  use ExUnit.Case, async: true

  @script Path.expand("../packaging/write-release-provenance.sh", __DIR__)

  test "workflow dispatch on a tag-shaped ref emits no release provenance" do
    {root, destination} = fixture()

    try do
      {output, status} =
        run_script(destination, %{
          "GITHUB_EVENT_NAME" => "workflow_dispatch",
          "GITHUB_REF_TYPE" => "tag",
          "GITHUB_REF" => "refs/tags/v0.1.9+1337",
          "GITHUB_REF_NAME" => "v0.1.9+1337",
          "CI_SOURCE_SHA" => String.duplicate("a", 40),
          "GITHUB_SHA" => String.duplicate("a", 40),
          "GITHUB_REPOSITORY" => "clickety-clacks/tightbeam"
        })

      assert status == 0, output
      refute File.exists?(destination)
    after
      File.rm_rf!(root)
    end
  end

  test "a validated tag push retains its release provenance" do
    {root, destination} = fixture()
    commit = String.duplicate("a", 40)

    try do
      {output, status} =
        run_script(destination, %{
          "TIGHTBEAM_RELEASE_TAG_VALIDATED" => "1",
          "GITHUB_EVENT_NAME" => "push",
          "GITHUB_REF_TYPE" => "tag",
          "GITHUB_REF" => "refs/tags/v0.1.9+1337",
          "GITHUB_REF_NAME" => "v0.1.9+1337",
          "CI_SOURCE_SHA" => commit,
          "GITHUB_SHA" => commit,
          "GITHUB_REPOSITORY" => "clickety-clacks/tightbeam"
        })

      assert status == 0, output

      assert JSON.decode!(File.read!(destination)) == %{
               "commit" => commit,
               "format" => "tightbeam-release-provenance/v1",
               "repository" => "clickety-clacks/tightbeam",
               "tag" => "v0.1.9+1337"
             }
    after
      File.rm_rf!(root)
    end
  end

  test "validated provenance refuses a source SHA different from GITHUB_SHA" do
    {root, destination} = fixture()

    try do
      {output, status} =
        run_script(destination, %{
          "TIGHTBEAM_RELEASE_TAG_VALIDATED" => "1",
          "GITHUB_EVENT_NAME" => "push",
          "GITHUB_REF_TYPE" => "tag",
          "GITHUB_REF" => "refs/tags/v0.1.9+1337",
          "GITHUB_REF_NAME" => "v0.1.9+1337",
          "CI_SOURCE_SHA" => String.duplicate("a", 40),
          "GITHUB_SHA" => String.duplicate("b", 40),
          "GITHUB_REPOSITORY" => "clickety-clacks/tightbeam"
        })

      assert status == 1
      assert output =~ "does not equal GITHUB_SHA"
      refute File.exists?(destination)
    after
      File.rm_rf!(root)
    end
  end

  test "exact canonical main dispatch derives its embedded release identity" do
    {root, destination} = fixture()
    on_exit(fn -> File.rm_rf!(root) end)
    {checkout, commit, env} = canonical_candidate!(root)

    assert {_, 0} = run_script(destination, env, checkout)

    assert JSON.decode!(File.read!(destination)) == %{
             "commit" => commit,
             "format" => "tightbeam-release-provenance/v1",
             "repository" => "clickety-clacks/tightbeam",
             "tag" => "v1.2.3+1"
           }
  end

  test "canonical main dispatch refuses inconsistent source, workflow, checkout or version" do
    {root, destination} = fixture()
    on_exit(fn -> File.rm_rf!(root) end)
    {checkout, commit, env} = canonical_candidate!(root)
    wrong = String.duplicate("a", 40)

    for update <- [
          %{"CANDIDATE_REF" => "refs/heads/other"},
          %{"CANDIDATE_SHA" => wrong},
          %{"GITHUB_WORKFLOW_SHA" => wrong},
          Map.new(~w(CANDIDATE_SHA GITHUB_SHA GITHUB_WORKFLOW_SHA), &{&1, wrong})
        ] do
      assert {output, 1} = run_script(destination, Map.merge(env, update), checkout)
      assert output =~ "canonical candidate ref, source, workflow and checkout must agree"
      refute File.exists?(destination)
    end

    File.write!(Path.join(checkout, "cli/Cargo.toml"), ~s(version = "wrong"\n))
    assert {output, 1} = run_script(destination, env, checkout)
    assert output =~ "candidate version declaration differs from its exact source"
    refute File.exists?(destination)
    assert git!(checkout, ["rev-parse", "HEAD"]) == commit
  end

  test "non-authoritative lanes leave the candidate authority absent" do
    {root, destination} = fixture()
    on_exit(fn -> File.rm_rf!(root) end)
    {checkout, _commit, env} = canonical_candidate!(root)

    for update <- [
          %{"GITHUB_EVENT_NAME" => nil},
          %{"GITHUB_EVENT_NAME" => "pull_request"},
          %{"GITHUB_REPOSITORY" => "contributor/tightbeam"},
          %{
            "CANDIDATE_BRANCH" => "release-candidate/example",
            "CANDIDATE_REF" => "refs/heads/release-candidate/example"
          },
          %{
            "GITHUB_WORKFLOW_REF" => "clickety-clacks/tightbeam/.github/workflows/ci.yml@refs/heads/main"
          },
          %{"GITHUB_REF_TYPE" => "tag", "GITHUB_REF" => "refs/tags/v1.2.3+1"}
        ] do
      assert {"", 0} = run_script(destination, Map.merge(env, update), checkout)
      refute File.exists?(destination)
    end
  end

  defp canonical_candidate!(root) do
    checkout = Path.join(root, "checkout")
    remote = Path.join(root, "remote")
    File.mkdir_p!(Path.join(checkout, "cli"))
    File.mkdir_p!(Path.join(checkout, "scripts"))
    File.mkdir_p!(remote)
    File.write!(Path.join(checkout, "cli/Cargo.toml"), ~s(version = "1.2.3"\n))

    File.cp!(
      Path.expand("../scripts/validate_release_tag.sh", __DIR__),
      Path.join(checkout, "scripts/validate_release_tag.sh")
    )

    git!(remote, ["init", "--bare"])
    git!(checkout, ["init", "-b", "main"])
    git!(checkout, ["config", "user.name", "Release Test"])
    git!(checkout, ["config", "user.email", "release@example.invalid"])
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "Source"])
    git!(checkout, ["remote", "add", "origin", remote])
    git!(checkout, ["push", "origin", "main"])
    commit = git!(checkout, ["rev-parse", "HEAD"])

    {checkout, commit,
     %{
       "GITHUB_EVENT_NAME" => "workflow_dispatch",
       "GITHUB_REF_TYPE" => "branch",
       "GITHUB_REF" => "refs/heads/main",
       "GITHUB_REF_NAME" => "main",
       "GITHUB_REPOSITORY" => "clickety-clacks/tightbeam",
       "GITHUB_WORKFLOW_REF" =>
         "clickety-clacks/tightbeam/.github/workflows/release-candidate.yml@refs/heads/main",
       "GITHUB_SHA" => commit,
       "GITHUB_WORKFLOW_SHA" => commit,
       "CANDIDATE_BRANCH" => "main",
       "CANDIDATE_REF" => "refs/heads/main",
       "CANDIDATE_SHA" => commit
     }}
  end

  defp git!(directory, arguments) do
    {output, status} = System.cmd("git", arguments, cd: directory, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-release-provenance-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {root, Path.join(root, "release-provenance.json")}
  end

  defp run_script(destination, overrides, directory \\ File.cwd!()) do
    keys = [
      "TIGHTBEAM_RELEASE_TAG_VALIDATED",
      "GITHUB_EVENT_NAME",
      "GITHUB_REF_TYPE",
      "GITHUB_REF",
      "GITHUB_REF_NAME",
      "CI_SOURCE_SHA",
      "GITHUB_SHA",
      "GITHUB_REPOSITORY",
      "GITHUB_WORKFLOW_REF",
      "GITHUB_WORKFLOW_SHA",
      "CANDIDATE_BRANCH",
      "CANDIDATE_REF",
      "CANDIDATE_SHA"
    ]

    env = Enum.map(keys, fn key -> {key, Map.get(overrides, key)} end)
    System.cmd("sh", [@script, destination], cd: directory, env: env, stderr_to_stdout: true)
  end
end
