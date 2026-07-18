defmodule Tightbeam.HomesTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Homes

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tb-homes-#{System.unique_integer([:positive])}")

    auth_dir = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), ~S({"secret":"real"}))
    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir}
  end

  test "projects instructions file per harness and symlinks auth in", %{base_dir: base_dir} do
    home =
      Homes.project(base_dir, %{
        harness: :codex,
        archetype: "coder",
        guidance: "# Coder rules"
      })

    assert home.home_path == Path.join([base_dir, "homes", "coder", "codex"])
    assert File.read!(Path.join(home.home_path, "AGENTS.md")) == "# Coder rules"
    assert home.linked_auth_files == ["auth.json"]
    link = Path.join(home.home_path, "auth.json")
    assert File.lstat!(link).type == :symlink
    assert File.read_link!(link) == Path.join([base_dir, "auth", "codex", "auth.json"])
  end

  test "claude homes get CLAUDE.md and tolerate a missing auth dir", %{base_dir: base_dir} do
    home =
      Homes.project(base_dir, %{
        harness: :claude,
        archetype: "default",
        guidance: "# Hi"
      })

    assert File.exists?(Path.join(home.home_path, "CLAUDE.md"))
    assert home.linked_auth_files == []
  end

  test "regeneration is delete + reassemble and never touches the auth source", %{
    base_dir: base_dir
  } do
    first =
      Homes.project(base_dir, %{harness: :codex, archetype: "coder", guidance: "v1"})

    File.write!(Path.join(first.home_path, "stray-state.db"), "harness scribbles")

    second =
      Homes.project(base_dir, %{
        harness: :codex,
        archetype: "coder",
        guidance: "v2",
        extra_files: %{"skills/review/SKILL.md" => "# Review"}
      })

    assert File.read!(Path.join(second.home_path, "AGENTS.md")) == "v2"
    refute File.exists?(Path.join(second.home_path, "stray-state.db"))
    assert File.read!(Path.join(second.home_path, "skills/review/SKILL.md")) == "# Review"

    assert File.read!(Path.join([base_dir, "auth", "codex", "auth.json"])) ==
             ~S({"secret":"real"})
  end

  test "unchanged manifest preserves nested harness state and tops up new auth", %{
    base_dir: base_dir
  } do
    spec = %{harness: :codex, archetype: "coder", guidance: "v1"}
    first = Homes.project(base_dir, spec)

    # Harness session state nests inside the home; a restart must not kill it.
    sessions_dir = Path.join(first.home_path, "sessions")
    File.mkdir_p!(sessions_dir)
    File.write!(Path.join(sessions_dir, "rollout-1.jsonl"), "conversation memory")

    # A credential added after first projection gets linked on the next pass.
    File.write!(Path.join([base_dir, "auth", "codex", "extra.pem"]), "later cred")

    second = Homes.project(base_dir, spec)

    assert File.read!(Path.join(sessions_dir, "rollout-1.jsonl")) == "conversation memory"
    assert "extra.pem" in second.linked_auth_files
    assert File.lstat!(Path.join(second.home_path, "extra.pem")).type == :symlink

    # An identity CHANGE still deletes and reassembles (forfeiting nested state).
    third = Homes.project(base_dir, %{spec | guidance: "v2"})
    refute File.exists?(Path.join(third.home_path, "sessions/rollout-1.jsonl"))
    assert File.read!(Path.join(third.home_path, "AGENTS.md")) == "v2"
  end

  test "different archetypes get sibling homes sharing one auth source", %{base_dir: base_dir} do
    a = Homes.project(base_dir, %{harness: :codex, archetype: "coder", guidance: "c"})

    b =
      Homes.project(base_dir, %{harness: :codex, archetype: "reviewer", guidance: "r"})

    refute a.home_path == b.home_path

    assert File.read_link!(Path.join(a.home_path, "auth.json")) ==
             File.read_link!(Path.join(b.home_path, "auth.json"))
  end
  test "skills project as symlinks to the replica; content edits live-update; election keys the hash",
       %{base_dir: base_dir} do
    library = Path.join(base_dir, "identity/skills/deploy")
    File.mkdir_p!(library)
    File.write!(Path.join(library, "SKILL.md"), "v1")

    spec = %{
      harness: :codex,
      archetype: "default",
      guidance: "# G",
      skills: [%{name: "deploy", link_to: library}]
    }

    home = Homes.project(base_dir, spec).home_path
    link = Path.join(home, "skills/deploy")
    assert File.read_link!(link) == library

    # Content edit flows through the link with NO regeneration (stamp intact).
    stamp = File.read!(Path.join(home, ".tightbeam-manifest"))
    File.write!(Path.join(library, "SKILL.md"), "v2")
    assert File.read!(Path.join(link, "SKILL.md")) == "v2"
    Homes.project(base_dir, spec)
    assert File.read!(Path.join(home, ".tightbeam-manifest")) == stamp

    # A stale target is re-pointed (a home follows a moved replica).
    moved = Path.join(base_dir, "identity/skills-moved/deploy")
    Homes.project(base_dir, %{spec | skills: [%{name: "deploy", link_to: moved}]})
    assert File.read_link!(link) == moved

    # Election change (not content) regenerates: the hash covers the names.
    marker = Path.join(home, "nested-state")
    File.write!(marker, "keep?")
    Homes.project(base_dir, %{spec | skills: []})
    refute File.exists?(marker)
  end

end
