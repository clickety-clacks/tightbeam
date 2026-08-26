defmodule Tightbeam.DeployReadinessDocsTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "the deployed readiness procedure requires the existing fresh-agent smoke" do
    upgrade = File.read!(Path.join(@root, "docs/UPGRADE.md"))

    assert upgrade =~ "TIGHTBEAM_SMOKE_LEGS=codex"
    assert upgrade =~ "mix run --no-start scripts/feature_smoke.exs"
    assert upgrade =~ "spawn a new agent"
    assert upgrade =~ "observe one real turn and reply"
    assert upgrade =~ "retire it"
    assert upgrade =~ "already open proves only existing-session health"
    assert upgrade =~ "does not prove fresh-agent readiness"
  end

  test "the release train points to the canonical deployed readiness procedure" do
    release_train = File.read!(Path.join(@root, "docs/RELEASE_TRAIN.md"))

    assert release_train =~ "UPGRADE.md#verify-after-starting"
    assert release_train =~ "all five checks"
    assert release_train =~ "spawns a new agent"
    assert release_train =~ ~r/obtains one real turn and\s+reply/
    assert release_train =~ "retires it"
    assert release_train =~ "already open proves only"
    assert release_train =~ "does not satisfy fresh-agent readiness"
  end

  test "the referenced local deployment smoke owns the full fresh-agent lifecycle" do
    smoke = File.read!(Path.join(@root, "scripts/feature_smoke.exs"))
    [local_deployment | _] = String.split(smoke, "defp local_workdir_path", parts: 2)

    local_deployment =
      local_deployment
      |> String.split("defp check_local_deployment", parts: 2)
      |> List.last()

    assert_in_order(local_deployment, [
      ~s(ok!(state, "spawn"),
      ~s(ok!(state, "wake"),
      "await_turn_boundary!(state, session_key)",
      "retire(state, session)"
    ])
  end

  defp assert_in_order(text, needles) do
    Enum.reduce(needles, -1, fn needle, previous_offset ->
      {offset, _length} = :binary.match(text, needle)
      assert offset > previous_offset
      offset
    end)
  end
end
