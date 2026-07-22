defmodule Tightbeam.ArchetypesTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Archetypes, DB, EventLog}

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-archetypes-#{System.unique_integer([:positive])}")
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Archetypes)
    end)

    %{base_dir: base_dir, manifests: manifests}
  end

  test "identity init seeds one clean commit and is idempotent", ctx do
    assert Archetypes.init_identity!(ctx.base_dir) == :initialized

    identity_dir = Path.join(ctx.base_dir, "identity")

    assert File.regular?(Path.join([identity_dir, "archetypes", "default.toml"]))

    for name <- Map.keys(Archetypes.builtin_fragments()) do
      assert File.regular?(Path.join([identity_dir, "guidance", name]))
    end

    for name <- Archetypes.builtin_skill_names() do
      assert File.regular?(Path.join([identity_dir, "skills", name, "SKILL.md"]))
    end

    assert File.regular?(Path.join([identity_dir, "rails", ".gitkeep"]))
    assert File.regular?(Path.join([identity_dir, "rules", ".gitkeep"]))
    assert {"1\n", 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: identity_dir)

    assert {"seed: tightbeam defaults\n", 0} =
             System.cmd("git", ["log", "-1", "--format=%s"], cd: identity_dir)

    assert {"", 0} = System.cmd("git", ["status", "--short"], cd: identity_dir)

    seeded_default = Archetypes.load!(ctx.base_dir)["default"]
    assert Map.put(seeded_default, :source, nil) == Archetypes.builtin_default()

    assert Archetypes.init_identity!(ctx.base_dir) == :noop
    assert {"1\n", 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: identity_dir)
    assert {"", 0} = System.cmd("git", ["status", "--short"], cd: identity_dir)
  end

  test "skill mutations auto-init and commit with the caller identity", ctx do
    path = Archetypes.put_skill!(ctx.base_dir, "review", "# Review", "agent:coder")
    identity_dir = Path.join(ctx.base_dir, "identity")

    assert File.read!(path) == "# Review"

    assert {"skill-put: review|agent:coder|agent-coder@tightbeam.local\n", 0} =
             System.cmd("git", ["log", "-1", "--format=%s|%an|%ae"], cd: identity_dir)

    Archetypes.load!(ctx.base_dir)
    assert {:ok, _removal} = Archetypes.rm_skill(ctx.base_dir, "review", "agent:coder", [])
    refute File.exists?(path)

    assert {"skill-rm: review|agent:coder|agent-coder@tightbeam.local\n", 0} =
             System.cmd("git", ["log", "-1", "--format=%s|%an|%ae"], cd: identity_dir)

    assert {"3\n", 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: identity_dir)
    assert {"", 0} = System.cmd("git", ["status", "--short"], cd: identity_dir)
  end

  test "loads all fields, merges the built-in default, and permits default override", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    where = ["work-1", "work-2"]
    model_preferences = ["claude-opus-4-8"]

    [defaults]
    harness = "codex"
    model = "gpt-5.6-sol[medium]"

    [references]
    repo = { location = "work-1:~/src/example-repo", access = "git; gate: run the tests" }
    brief = { location = "work-1:~/brief.md" }

    [guidance]
    text = "Ship the requested change."
    """)

    loaded = Archetypes.load!(ctx.base_dir)

    assert loaded["default"] == Archetypes.builtin_default()

    source_path = Path.join(ctx.manifests, "coder.toml")

    assert loaded["coder"] == %{
             name: "coder",
             skills: [],
             where: ["work-1", "work-2"],
             model_preferences: ["claude-opus-4-8"],
             containment: %{fs: :off, network: :open},
             defaults: %{harness: :codex, model: "gpt-5.6-sol[medium]"},
             references: [
               %{name: "brief", location: "work-1:~/brief.md", access: nil},
               %{
                 name: "repo",
                 location: "work-1:~/src/example-repo",
                 access: "git; gate: run the tests"
               }
             ],
             mcp: [],
             guidance: "Ship the requested change.",
             source: %{
               file: "identity/archetypes/coder.toml",
               sha256:
                 source_path
                 |> File.read!()
                 |> then(&:crypto.hash(:sha256, &1))
                 |> Base.encode16(case: :lower)
             }
           }

    assert Archetypes.get("coder") == loaded["coder"]
    assert Archetypes.names() == ["coder", "default"]

    File.write!(Path.join(ctx.manifests, "default.toml"), """
    name = "default"
    where = ["work-1"]
    """)

    assert Archetypes.load!(ctx.base_dir)["default"].where == ["work-1"]
  end

  test "source fingerprint changes when manifest file bytes change and builtin source is nil",
       ctx do
    path = Path.join(ctx.manifests, "coder.toml")
    File.write!(path, "name = \"coder\"\n")
    first = Archetypes.load!(ctx.base_dir)

    assert first["default"].source == nil
    assert first["coder"].source.file == "identity/archetypes/coder.toml"

    File.write!(path, "name = \"coder\"\n# byte change\n")
    second = Archetypes.load!(ctx.base_dir)

    refute second["coder"].source.sha256 == first["coder"].source.sha256
  end

  test "containment posture is deny-only, defaulted, and boot-validated", ctx do
    assert Archetypes.builtin_default().containment == %{fs: :off, network: :open}

    File.write!(Path.join(ctx.manifests, "contained.toml"), """
    name = "contained"

    [containment]
    fs = "workdir"
    network = "open"
    """)

    loaded = Archetypes.load!(ctx.base_dir)
    assert loaded["contained"].containment == %{fs: :workdir, network: :open}

    File.write!(Path.join(ctx.manifests, "contained.toml"), "name = \"contained\"\n")
    assert Archetypes.load!(ctx.base_dir)["contained"].containment == %{fs: :off, network: :open}

    invalid = [
      "[containment]\nunknown = true\n",
      "[containment]\nfs = \"offf\"\n",
      "[containment]\nnetwork = \"loopback\"\n"
    ]

    for body <- invalid do
      File.write!(Path.join(ctx.manifests, "contained.toml"), "name = \"contained\"\n" <> body)
      assert_raise ArgumentError, fn -> Archetypes.load!(ctx.base_dir) end
    end
  end

  test "session overrides validate in order and normalize to one canonical shape", ctx do
    for name <- ["alpha", "zeta"] do
      Archetypes.put_skill!(ctx.base_dir, name, "# #{name}")
    end

    archetype = Archetypes.load!(ctx.base_dir)["default"]

    invalid = [
      {nil, "must be an object"},
      {%{"other" => true}, "unknown override keys"},
      {%{"skills_add" => "alpha"}, "must be a list of strings"},
      {%{"skills_add" => ["alpha", 1]}, "must be a list of strings"},
      {%{"skills_add" => ["missing"]}, "unknown override skill names: missing"},
      {%{"guidance_extra" => 42}, "must be a string"},
      {%{"guidance_extra" => ~s(#include "missing.md")},
       "unknown guidance fragment \"missing.md\""}
    ]

    for {raw, message} <- invalid do
      assert {:error, %{code: "invalid_overrides", message: detail}} =
               Archetypes.normalize_overrides(ctx.base_dir, archetype, raw)

      assert detail =~ message
    end

    assert {:ok,
            %{
              "skills_add" => ["alpha", "zeta"],
              "guidance_extra" => "Additional guidance."
            }} =
             Archetypes.normalize_overrides(ctx.base_dir, archetype, %{
               "skills_add" => ["zeta", "tightbeam-skills", "alpha", "zeta"],
               "guidance_extra" => "  Additional guidance.  "
             })

    for empty <- [
          %{},
          %{"skills_add" => []},
          %{"skills_add" => ["tightbeam-skills", "tightbeam-skills"]},
          %{"guidance_extra" => "   \n"}
        ] do
      assert {:ok, nil} = Archetypes.normalize_overrides(ctx.base_dir, archetype, empty)
    end

    guidance_dir = Path.join([ctx.base_dir, "identity", "guidance"])
    File.mkdir_p!(guidance_dir)
    File.write!(Path.join(guidance_dir, "a.md"), ~s(#include "b.md"))
    File.write!(Path.join(guidance_dir, "b.md"), ~s(#include "a.md"))
    archetype = Archetypes.load!(ctx.base_dir)["default"]

    assert {:error, %{code: "invalid_overrides", message: cycle}} =
             Archetypes.normalize_overrides(ctx.base_dir, archetype, %{
               "guidance_extra" => ~s(#include "a.md")
             })

    assert cycle =~ "guidance include cycle"
  end

  test "effective identity retains the base header and logs post-spawn missing dependencies",
       ctx do
    Archetypes.put_skill!(ctx.base_dir, "review", "# Review")
    guidance_dir = Path.join([ctx.base_dir, "identity", "guidance"])
    File.mkdir_p!(guidance_dir)
    File.write!(Path.join(guidance_dir, "extra.md"), "Resolve carefully.")
    base = Archetypes.load!(ctx.base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(ctx.base_dir, base, %{
        "skills_add" => ["review"],
        "guidance_extra" => "Before.\n#include \"extra.md\"\nAfter."
      })

    composed = Archetypes.effective(base, overrides)
    assert "review" in composed.skills
    assert Archetypes.guidance(composed) =~ "# Tightbeam · default"
    assert Archetypes.guidance(composed) =~ "Before.\nResolve carefully.\nAfter."

    File.rm_rf!(Path.join(Archetypes.skills_dir(ctx.base_dir), "review"))
    File.rm!(Path.join(guidance_dir, "extra.md"))
    base = Archetypes.load!(ctx.base_dir)["default"]

    db = :"override_events_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)

    drifted =
      Archetypes.effective(base, overrides,
        base_dir: ctx.base_dir,
        db: db,
        identity_name: "default--0123456789abcdef"
      )

    refute "review" in drifted.skills
    assert Archetypes.guidance(drifted) =~ "Before.\n\nAfter."

    assert Enum.map(EventLog.lifecycle_events(db), &{&1.kind, &1.subject, &1.detail}) == [
             {"override_discrepancy", "default--0123456789abcdef",
              "missing override skill review"},
             {"override_discrepancy", "default--0123456789abcdef",
              "unknown guidance fragment \"extra.md\""}
           ]
  end

  test "archetype names may not contain the effective-identity separator", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), "name = \"bad--name\"\n")

    assert_raise ArgumentError, ~r/may not contain --/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "org skills are electable and unknown elections fail",
       ctx do
    Archetypes.load!(ctx.base_dir)

    for name <- Tightbeam.Homes.baseline_skill_names() do
      refute File.exists?(Path.join([Archetypes.skills_dir(ctx.base_dir), name, "SKILL.md"]))
    end

    # Explicit election is exact; unknown names stop the boot.
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["no-such-skill"]
    """)

    assert_raise ArgumentError, ~r/coder elects unknown skills: no-such-skill/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    # An operator-authored library skill is electable.
    File.mkdir_p!(Path.join(Archetypes.skills_dir(ctx.base_dir), "deploy"))

    File.write!(
      Path.join([Archetypes.skills_dir(ctx.base_dir), "deploy", "SKILL.md"]),
      "# deploy"
    )

    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["deploy"]
    """)

    assert Archetypes.load!(ctx.base_dir)["coder"].skills == ["deploy"]
  end

  test "load refuses an org copy of a reserved substrate skill and names its path", ctx do
    path =
      Path.join([
        Archetypes.skills_dir(ctx.base_dir),
        "tightbeam-onboarding",
        "SKILL.md"
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# org shadow")

    assert_raise ArgumentError,
                 "#{path}: rename or remove the org copy; substrate names are reserved",
                 fn -> Archetypes.load!(ctx.base_dir) end
  end

  test "skill CRUD: trees nest, roots are electable units, elected roots transform on removal",
       ctx do
    Archetypes.load!(ctx.base_dir)

    # A subject tree: parent manifest + nested technique.
    Archetypes.put_skill!(ctx.base_dir, "swift", "# Swift\nIndex: see concurrency/SKILL.md")
    Archetypes.put_skill!(ctx.base_dir, "swift/concurrency", "# Concurrency")

    names = ctx.base_dir |> Archetypes.list_skills() |> Enum.map(&{&1.name, &1.root})
    assert {"swift", true} in names
    assert {"swift/concurrency", false} in names

    # Nested nodes are not electable: election is atomic at the root.
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["swift/concurrency"]
    """)

    assert_raise ArgumentError, ~r/elects unknown skills: swift\/concurrency/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["swift"]
    """)

    Archetypes.load!(ctx.base_dir)

    assert {:ok,
            %{
              archetype_electors: ["coder"],
              manifest_warnings: [warning]
            }} = Archetypes.rm_skill(ctx.base_dir, "swift")

    assert warning ==
             "archetype coder still elects swift in identity/archetypes/coder.toml — " <>
               "edit it before the next restart (boot validation is fail-closed)"

    refute File.exists?(Path.join(Archetypes.skills_dir(ctx.base_dir), "swift"))

    assert_raise ArgumentError, ~r/coder elects unknown skills: swift/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    Archetypes.put_skill!(ctx.base_dir, "swift", "# Swift")
    Archetypes.put_skill!(ctx.base_dir, "swift/concurrency", "# Concurrency")
    Archetypes.load!(ctx.base_dir)

    assert {:ok, %{archetype_electors: [], manifest_warnings: []}} =
             Archetypes.rm_skill(ctx.base_dir, "swift/concurrency")

    refute File.exists?(Path.join(Archetypes.skills_dir(ctx.base_dir), "swift/concurrency"))

    assert {:error, %{code: "unknown_skill", message: "unknown skill: missing"}} =
             Archetypes.rm_skill(ctx.base_dir, "missing")

    # Traversal never escapes the library.
    assert_raise ArgumentError, ~r/invalid skill name/, fn ->
      Archetypes.put_skill!(ctx.base_dir, "../escape", "nope")
    end
  end

  test "unknown top-level keys raise", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), "name = \"bad\"\nware = [\"local\"]\n")

    assert_raise ArgumentError, ~r/unknown top-level archetype keys.*ware/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "bad defaults harness raises", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), """
    name = "bad"
    [defaults]
    harness = "other"
    """)

    assert_raise ArgumentError, ~r/defaults.harness must be claude or codex/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "reference without location raises", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), """
    name = "bad"
    [references]
    repo = { access = "read" }
    """)

    assert_raise ArgumentError, ~r/reference repo is missing location/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "mcp declarations load and compile to the byte-pinned ACP shape", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"

    [mcp.xcodebuild]
    command = "xcodebuildmcp"
    args = ["--daemon"]
    env = { Z_LAST = "last", XCODEBUILD_MCP_MODE = "cli" }
    """)

    archetype = Archetypes.load!(ctx.base_dir)["coder"]

    assert archetype.mcp == [
             %{
               name: "xcodebuild",
               command: "xcodebuildmcp",
               args: ["--daemon"],
               env: %{"XCODEBUILD_MCP_MODE" => "cli", "Z_LAST" => "last"}
             }
           ]

    assert Archetypes.acp_mcp_servers(archetype) == [
             %{
               "name" => "xcodebuild",
               "command" => "xcodebuildmcp",
               "args" => ["--daemon"],
               "env" => [
                 %{"name" => "XCODEBUILD_MCP_MODE", "value" => "cli"},
                 %{"name" => "Z_LAST", "value" => "last"}
               ]
             }
           ]

    assert Archetypes.acp_mcp_servers(Archetypes.builtin_default()) == []
  end

  test "mcp declarations sort by name and default args and env", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    [mcp.zeta]
    command = "z"

    [mcp.alpha]
    command = "a"
    """)

    assert Enum.map(Archetypes.load!(ctx.base_dir)["coder"].mcp, & &1.name) == [
             "alpha",
             "zeta"
           ]

    assert Enum.map(Archetypes.load!(ctx.base_dir)["coder"].mcp, &{&1.args, &1.env}) == [
             {[], %{}},
             {[], %{}}
           ]
  end

  test "invalid mcp declarations fail load with the validation fragments", ctx do
    cases = [
      {"[mcp.bad_name]\ncommand = \"ok\"\n", ~r/invalid mcp server name/},
      {"[mcp.missing]\nargs = []\n", ~r/mcp server missing is missing \"command\"/},
      {"[mcp.empty]\ncommand = \"\"\n", ~r/mcp server empty is missing \"command\"/},
      {"[mcp.badargs]\ncommand = \"ok\"\nargs = [1]\n",
       ~r/mcp server badargs: args must be a list of strings/},
      {"[mcp.badenv]\ncommand = \"ok\"\nenv = { MODE = 1 }\n",
       ~r/mcp server badenv: env must be string keys and values/},
      {"[mcp.remote]\ncommand = \"ok\"\nurl = \"https:\/\/example.test\"\n",
       ~r/unknown mcp server keys.*url/}
    ]

    Enum.each(cases, fn {manifest, message} ->
      File.write!(Path.join(ctx.manifests, "bad.toml"), manifest)
      assert_raise ArgumentError, message, fn -> Archetypes.load!(ctx.base_dir) end
    end)
  end

  test "guidance replaces the legacy sections with the operating manual and is pure" do
    archetype = %{
      name: "coder",
      where: ["testhost"],
      defaults: %{},
      references: [
        %{name: "repo", location: "work-1:~/src/example-repo", access: "git"},
        %{name: "brief", location: "work-1:~/brief.md", access: nil}
      ],
      guidance: "## Assignment\nImplement E4a."
    }

    first = Archetypes.guidance(archetype)

    manual = File.read!("test/fixtures/operating_manual.md")

    assert first ==
             "# Tightbeam · coder\n\n" <>
               String.trim_trailing(manual) <>
               "\n\n## Your materials\n" <>
               "- repo: work-1:~/src/example-repo\n" <>
               "  access: git\n" <>
               "- brief: work-1:~/brief.md\n\n" <>
               "## Assignment\nImplement E4a."

    assert Archetypes.guidance(archetype) == first

    without_references = %{archetype | references: [], guidance: "Additional law."}
    compiled = Archetypes.guidance(without_references)
    refute compiled =~ "## Your materials"

    assert String.ends_with?(
             compiled,
             "memory of your own.\n\nAdditional law."
           )
  end

  test "the exact operating manual is the sole built-in fragment" do
    assert Archetypes.builtin_fragments() == %{
             "operating-manual.md" => File.read!("test/fixtures/operating_manual.md")
           }
  end

  test "every loaded archetype receives the operating manual", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), "name = \"coder\"\n")
    loaded = Archetypes.load!(ctx.base_dir)
    manual = File.read!("test/fixtures/operating_manual.md") |> String.trim_trailing()

    for name <- ["default", "coder"] do
      assert Archetypes.guidance(loaded[name]) =~ manual
    end
  end

  test "fragments: operator files override built-ins and #include composes", ctx do
    gdir = Path.join([ctx.base_dir, "identity", "guidance"])
    File.mkdir_p!(gdir)
    File.write!(Path.join(gdir, "operating-manual.md"), "Custom operating manual.")
    File.write!(Path.join(gdir, "topology.md"), "Coders live on work hosts.")
    File.write!(Path.join(gdir, "outer.md"), ~s(before\n#include "topology.md"\nafter))

    adir = Path.join([ctx.base_dir, "identity", "archetypes"])
    File.mkdir_p!(adir)

    File.write!(Path.join(adir, "coder.toml"), """
    name = "coder"
    [guidance]
    text = \"\"\"
    #include "outer.md"
    \"\"\"
    """)

    Archetypes.load!(ctx.base_dir)
    text = Archetypes.guidance(Archetypes.get("coder"))

    assert text =~ "Custom operating manual."
    refute text =~ "# Operating tightbeam"
    assert text =~ "before\nCoders live on work hosts.\nafter"
    refute text =~ "#include"
  end

  test "missing fragment and include cycles fail the boot", ctx do
    adir = Path.join([ctx.base_dir, "identity", "archetypes"])
    File.mkdir_p!(adir)

    File.write!(Path.join(adir, "broken.toml"), """
    name = "broken"
    [guidance]
    text = \"\"\"
    #include "nope.md"
    \"\"\"
    """)

    assert_raise ArgumentError, ~r/unknown guidance fragment "nope.md"/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    gdir = Path.join([ctx.base_dir, "identity", "guidance"])
    File.mkdir_p!(gdir)
    File.write!(Path.join(gdir, "a.md"), ~s(#include "b.md"))
    File.write!(Path.join(gdir, "b.md"), ~s(#include "a.md"))

    File.write!(Path.join(adir, "broken.toml"), """
    name = "broken"
    [guidance]
    text = \"\"\"
    #include "a.md"
    \"\"\"
    """)

    assert_raise ArgumentError, ~r/include cycle: a.md -> b.md -> a.md/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "where wildcard must stand alone; empty where rejected", ctx do
    adir = Path.join([ctx.base_dir, "identity", "archetypes"])
    File.mkdir_p!(adir)

    File.write!(Path.join(adir, "bad.toml"), """
    name = "bad"
    where = ["*", "work-1"]
    """)

    assert_raise ArgumentError, ~r/must be the only element/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    File.write!(Path.join(adir, "bad.toml"), """
    name = "bad"
    where = []
    """)

    assert_raise ArgumentError, ~r/non-empty list/, fn -> Archetypes.load!(ctx.base_dir) end

    File.write!(Path.join(adir, "bad.toml"), """
    name = "roamer"
    where = ["*"]
    """)

    assert Archetypes.load!(ctx.base_dir)["roamer"].where == ["*"]
  end
end
