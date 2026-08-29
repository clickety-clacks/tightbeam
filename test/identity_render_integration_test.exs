defmodule Tightbeam.IdentityRenderIntegrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Identity

  @fixture_root Path.expand("fixtures/identity-universal-root", __DIR__)

  test "snapshots for every harness deliver rendered real universal-root fixtures and stamps" do
    base =
      Path.join(
        System.tmp_dir!(),
        "identity-render-integration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    :initialized = Identity.init!(base)
    dir = Path.join(base, "identity")
    guidance = Path.join(dir, "guidance")
    expected = git!(dir, ["rev-parse", "tightbeam/live"])

    specs = File.read!(Path.join(@fixture_root, "specs-home.md"))
    dev = File.read!(Path.join(@fixture_root, "dev-on-gibson.md"))
    File.write!(Path.join(guidance, "specs-home.md"), specs)
    File.write!(Path.join(guidance, "dev-on-gibson.md"), dev)

    File.write!(
      Path.join(guidance, "operating-model.md"),
      "model-before\n#include \"dev-on-gibson.md\"\nmodel-after\n"
    )

    File.write!(
      Path.join(guidance, "operating-manual.md"),
      "manual-before\n#include \"specs-home.md\"\nmanual-after\n"
    )

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", "test: real universal-root fixtures"])
    candidate = git!(dir, ["rev-parse", "main"])

    assert {:ok, ^candidate} =
             Identity.publish_live!(base, %{
               expected_prior: expected,
               candidate_revision: candidate,
               tree_fingerprint: String.duplicate("0", 64)
             })

    for harness <- [:codex, :claude] do
      snapshot = Identity.snapshot_at!(base, candidate, "default", harness)
      assert snapshot.render_contract == "universal-root-render-v1"
      assert snapshot.guidance_digest == sha256(snapshot.guidance)
      assert String.contains?(snapshot.guidance, String.trim_trailing(specs, "\n"))
      assert String.contains?(snapshot.guidance, String.trim_trailing(dev, "\n"))
      refute Regex.match?(~r/^#include/m, snapshot.guidance)
    end
  end

  test "invalid staged initialization leaves no canonical identity path" do
    base =
      Path.join(System.tmp_dir!(), "identity-invalid-init-#{System.unique_integer([:positive])}")

    seed = Path.join(base, "invalid-seed")
    File.mkdir_p!(base)
    File.cp_r!(Application.app_dir(:tightbeam, "priv/seed"), seed)
    File.write!(Path.join(seed, "guidance/operating-model.md"), "#include \"missing.md\"\n")

    previous = Application.get_env(:tightbeam, :identity_seed_dir)
    Application.put_env(:tightbeam, :identity_seed_dir, seed)

    try do
      assert_raise Tightbeam.Identity.IncludeError, fn -> Identity.init!(base) end
      refute File.exists?(Path.join(base, "identity"))
      assert Path.wildcard(Path.join(base, "identity.candidate-*")) == []
    after
      if previous,
        do: Application.put_env(:tightbeam, :identity_seed_dir, previous),
        else: Application.delete_env(:tightbeam, :identity_seed_dir)
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp git!(dir, args) do
    env = [
      {"GIT_AUTHOR_NAME", "test"},
      {"GIT_AUTHOR_EMAIL", "test@tightbeam.invalid"},
      {"GIT_COMMITTER_NAME", "test"},
      {"GIT_COMMITTER_EMAIL", "test@tightbeam.invalid"}
    ]

    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> raise "git failed #{status}: #{output}"
    end
  end
end
