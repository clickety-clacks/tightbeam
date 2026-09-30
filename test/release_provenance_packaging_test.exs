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

  test "only a validated tag push writes release provenance" do
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

  defp fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-release-provenance-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {root, Path.join(root, "release-provenance.json")}
  end

  defp run_script(destination, overrides) do
    keys = [
      "TIGHTBEAM_RELEASE_TAG_VALIDATED",
      "GITHUB_EVENT_NAME",
      "GITHUB_REF_TYPE",
      "GITHUB_REF",
      "GITHUB_REF_NAME",
      "CI_SOURCE_SHA",
      "GITHUB_SHA",
      "GITHUB_REPOSITORY"
    ]

    env = Enum.map(keys, fn key -> {key, Map.get(overrides, key)} end)
    System.cmd("sh", [@script, destination], env: env, stderr_to_stdout: true)
  end
end
