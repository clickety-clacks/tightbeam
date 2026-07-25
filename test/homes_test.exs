defmodule Tightbeam.HomesTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Homes

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-homes-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir}
  end

  test "projects one generic home per machine and harness", %{base_dir: base_dir} do
    auth = Path.join([base_dir, "auth", "codex", "auth.json"])
    File.mkdir_p!(Path.dirname(auth))
    File.write!(auth, ~S({"token":"machine-a"}))

    coder = Homes.project(base_dir, %{machine: "machine-a", harness: :codex, rails: "v1"})
    reviewer = Homes.project(base_dir, %{machine: "machine-a", harness: :codex, rails: "v1"})

    assert coder.home_path == Path.join([base_dir, "homes", "machine-a", "codex"])
    assert reviewer.home_path == coder.home_path
    assert File.read!(Path.join(coder.home_path, "hooks.json")) == "v1"
    assert File.lstat!(Path.join(coder.home_path, "auth.json")).type == :symlink
    refute File.exists?(Path.join(coder.home_path, "AGENTS.md"))
    refute File.dir?(Path.join(coder.home_path, "skills"))
  end

  test "regeneration replaces only owned paths and preserves durable Codex state", %{
    base_dir: base_dir
  } do
    auth = Path.join([base_dir, "auth", "codex", "auth.json"])
    File.mkdir_p!(Path.dirname(auth))
    File.write!(auth, "old")

    projected = Homes.project(base_dir, %{machine: "eezo", harness: :codex, rails: "v1"})
    File.mkdir_p!(Path.join(projected.home_path, "sessions"))
    File.write!(Path.join(projected.home_path, "sessions/rollout.jsonl"), "rollout")
    File.write!(Path.join(projected.home_path, "history.jsonl"), "history")

    File.rm!(Path.join(projected.home_path, "auth.json"))
    File.write!(Path.join(projected.home_path, "auth.json"), "runtime-rotated")

    regenerated =
      Homes.project(base_dir, %{machine: "eezo", harness: :codex, rails: "v2"})

    assert File.read!(Path.join(regenerated.home_path, "sessions/rollout.jsonl")) == "rollout"
    assert File.read!(Path.join(regenerated.home_path, "history.jsonl")) == "history"
    assert File.read!(Path.join(regenerated.home_path, "hooks.json")) == "v2"
    assert File.read!(auth) == "runtime-rotated"
    assert File.lstat!(Path.join(regenerated.home_path, "auth.json")).type == :symlink
  end

  test "regeneration preserves Claude projects and memory", %{base_dir: base_dir} do
    token = Path.join([base_dir, "auth", "claude", "oauth-token"])
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, "token")

    projected = Homes.project(base_dir, %{machine: "eezo", harness: :claude, rails: "v1"})
    File.mkdir_p!(Path.join(projected.home_path, "projects/repo/memory"))
    File.write!(Path.join(projected.home_path, "projects/repo/transcript.jsonl"), "chat")
    File.write!(Path.join(projected.home_path, "projects/repo/memory/notes.md"), "memory")

    Homes.project(base_dir, %{machine: "eezo", harness: :claude, rails: "v2"})

    assert File.read!(Path.join(projected.home_path, "projects/repo/transcript.jsonl")) == "chat"
    assert File.read!(Path.join(projected.home_path, "projects/repo/memory/notes.md")) == "memory"
    assert File.read!(Path.join(projected.home_path, "settings.json")) == "v2"
  end
end
