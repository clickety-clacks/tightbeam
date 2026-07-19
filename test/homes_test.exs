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
      Homes.project(
        base_dir,
        home_spec(%{
          harness: :codex,
          archetype: "coder",
          guidance: "# Coder rules"
        })
      )

    assert home.home_path == Path.join([base_dir, "homes", "coder", "codex"])
    assert File.read!(Path.join(home.home_path, "AGENTS.md")) == "# Coder rules"
    assert home.linked_auth_files == ["auth.json"]
    link = Path.join(home.home_path, "auth.json")
    assert File.lstat!(link).type == :symlink
    assert File.read_link!(link) == Path.join([base_dir, "auth", "codex", "auth.json"])
  end

  test "claude homes get CLAUDE.md and tolerate a missing auth dir", %{base_dir: base_dir} do
    home =
      Homes.project(
        base_dir,
        home_spec(%{
          harness: :claude,
          archetype: "default",
          guidance: "# Hi"
        })
      )

    assert File.exists?(Path.join(home.home_path, "CLAUDE.md"))
    assert home.linked_auth_files == []
  end

  test "regeneration is delete + reassemble and never touches the auth source", %{
    base_dir: base_dir
  } do
    first =
      Homes.project(base_dir, home_spec(%{harness: :codex, archetype: "coder", guidance: "v1"}))

    File.write!(Path.join(first.home_path, "stray-state.db"), "harness scribbles")

    second =
      Homes.project(
        base_dir,
        home_spec(%{
          harness: :codex,
          archetype: "coder",
          guidance: "v2",
          extra_files: %{"skills/review/SKILL.md" => "# Review"}
        })
      )

    assert File.read!(Path.join(second.home_path, "AGENTS.md")) == "v2"
    refute File.exists?(Path.join(second.home_path, "stray-state.db"))
    assert File.read!(Path.join(second.home_path, "skills/review/SKILL.md")) == "# Review"

    assert File.read!(Path.join([base_dir, "auth", "codex", "auth.json"])) ==
             ~S({"secret":"real"})
  end

  test "unchanged manifest preserves nested harness state and tops up new auth", %{
    base_dir: base_dir
  } do
    spec = home_spec(%{harness: :codex, archetype: "coder", guidance: "v1"})
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
    a = Homes.project(base_dir, home_spec(%{harness: :codex, archetype: "coder", guidance: "c"}))

    b =
      Homes.project(base_dir, home_spec(%{harness: :codex, archetype: "reviewer", guidance: "r"}))

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
      base_archetype: "default",
      parent_source: nil,
      guidance: "# G",
      skills: [
        %{name: "deploy", link_to: library, provenance: "template", linkage: "linked"}
      ]
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

    Homes.project(base_dir, %{
      spec
      | skills: [
          %{name: "deploy", link_to: moved, provenance: "template", linkage: "linked"}
        ]
    })

    assert File.read_link!(link) == moved

    # Election change (not content) regenerates: the hash covers the names.
    marker = Path.join(home, "nested-state")
    File.write!(marker, "keep?")
    Homes.project(base_dir, %{spec | skills: []})
    refute File.exists?(marker)
  end

  test "manifest bytes are canonical, readable, and include parent and content fingerprints", %{
    base_dir: base_dir
  } do
    source = %{
      file: "identity/archetypes/coder.toml",
      sha256: String.duplicate("a", 64)
    }

    spec =
      home_spec(%{
        harness: :codex,
        archetype: "coder",
        base_archetype: "coder",
        parent_source: source,
        guidance: "guidance",
        extra_files: %{"settings.json" => "settings"},
        skills: [
          %{name: "swift", link_to: "/library/swift", provenance: "template", linkage: "linked"}
        ]
      })

    home = Homes.project(base_dir, spec).home_path
    stamp_path = Path.join(home, ".tightbeam-manifest")
    stamp = File.read!(stamp_path)
    marker = Path.join(home, "sessions/nested-marker")
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, "keep")

    assert stamp == Homes.manifest_bytes(spec)
    assert File.read!(stamp_path) == stamp

    assert JSON.decode!(stamp) == %{
             "base_archetype" => "coder",
             "extra_files" => %{
               "settings.json" => sha256("settings")
             },
             "guidance_sha256" => sha256("guidance"),
             "harness" => "codex",
             "parent_manifest" => %{
               "file" => "identity/archetypes/coder.toml",
               "sha256" => String.duplicate("a", 64)
             },
             "skills" => [
               %{"name" => "swift", "provenance" => "template", "linkage" => "linked"}
             ]
           }

    Homes.project(base_dir, spec)
    assert File.read!(stamp_path) == stamp
    assert File.read!(marker) == "keep"

    builtin =
      Homes.manifest_bytes(%{
        spec
        | archetype: "default",
          base_archetype: "default",
          parent_source: nil
      })

    assert JSON.decode!(builtin)["parent_manifest"] == %{"file" => nil, "sha256" => nil}
  end

  test "old opaque stamps cause one regeneration", %{base_dir: base_dir} do
    spec = home_spec(%{harness: :codex, archetype: "coder", guidance: "v1"})
    home = Homes.project(base_dir, spec).home_path
    marker = Path.join(home, "nested-state")
    File.write!(marker, "old body")
    File.write!(Path.join(home, ".tightbeam-manifest"), String.duplicate("f", 64))

    Homes.project(base_dir, spec)

    refute File.exists?(marker)
    assert JSON.decode!(File.read!(Path.join(home, ".tightbeam-manifest")))
  end

  test "same short overridden name refuses a different full identity fingerprint", %{
    base_dir: base_dir
  } do
    prefix = "0123456789abcdef"

    spec =
      home_spec(%{
        harness: :codex,
        archetype: "default--#{prefix}",
        identity_sha256: prefix <> String.duplicate("a", 48),
        guidance: "first"
      })

    Homes.project(base_dir, spec)

    assert_raise ArgumentError, ~r/identity name collision/, fn ->
      Homes.project(base_dir, %{
        spec
        | identity_sha256: prefix <> String.duplicate("b", 48),
          guidance: "second"
      })
    end
  end

  test "credential sweep recovers the newest regular-file credential from abandoned homes", %{
    base_dir: base_dir
  } do
    store = Path.join([base_dir, "auth", "codex", "auth.json"])
    older_home = Path.join([base_dir, "homes", "old-id", "codex"])
    newest_home = Path.join([base_dir, "homes", "new-id", "codex"])
    File.mkdir_p!(older_home)
    File.mkdir_p!(newest_home)
    older = Path.join(older_home, "auth.json")
    newest = Path.join(newest_home, "auth.json")
    File.write!(older, "rotated-once")
    File.write!(newest, "rotated-twice")
    File.touch!(store, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(older, {{2026, 1, 2}, {0, 0, 0}})
    File.touch!(newest, {{2026, 1, 3}, {0, 0, 0}})

    assert :ok = Homes.sweep_auth(base_dir, :codex)
    assert File.read!(store) == "rotated-twice"
  end

  test "credential sweep discovers known regular credentials absent from the store", %{
    base_dir: base_dir
  } do
    auth_dir = Path.join([base_dir, "auth", "codex"])
    File.rm_rf!(auth_dir)
    home = Path.join([base_dir, "homes", "abandoned-id", "codex"])
    File.mkdir_p!(home)
    File.write!(Path.join(home, ".credentials.json"), "rotated")
    File.write!(Path.join(home, "AGENTS.md"), "instructions")
    File.write!(Path.join(home, ".tightbeam-manifest"), "manifest")

    assert :ok = Homes.sweep_auth(base_dir, :codex)
    assert File.read!(Path.join(auth_dir, ".credentials.json")) == "rotated"
    refute File.exists?(Path.join(auth_dir, "AGENTS.md"))
    refute File.exists?(Path.join(auth_dir, ".tightbeam-manifest"))
  end

  defp home_spec(overrides) do
    Map.merge(
      %{
        harness: :codex,
        archetype: "default",
        base_archetype: Map.get(overrides, :archetype, "default"),
        parent_source: nil,
        guidance: ""
      },
      overrides
    )
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
