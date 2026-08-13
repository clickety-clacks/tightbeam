defmodule Tightbeam.ArchetypesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Archetypes, Identity, Rails, Rules}

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-archetypes-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Archetypes)
    end)

    %{base_dir: base_dir}
  end

  test "initialization seeds only the neutral served identity tree once", ctx do
    assert Archetypes.init_identity!(ctx.base_dir) == :initialized
    identity_dir = Path.join(ctx.base_dir, "identity")

    for ref <- ["tightbeam/upstream", "main", "tightbeam/live"] do
      assert {oid, 0} = System.cmd("git", ["rev-parse", ref], cd: identity_dir)
      assert String.trim(oid) != ""
    end

    assert Path.wildcard(Path.join(identity_dir, "archetypes/*.toml")) ==
             [Path.join(identity_dir, "archetypes/default.toml")]

    assert File.regular?(Path.join([identity_dir, "guidance", "operating-model.md"]))

    assert Path.wildcard(Path.join(identity_dir, "guidance/*.md")) ==
             [Path.join(identity_dir, "guidance/operating-model.md")]

    assert %{"default" => default} = Archetypes.load!(ctx.base_dir)
    assert default.skills == ["tightbeam-onboarding"]

    snapshot = Identity.snapshot!(ctx.base_dir, "default", :codex)
    assert snapshot.skills == %{}
    assert snapshot.guidance =~ "expert on Tightbeam, setting it up on this machine"
    assert snapshot.guidance =~ "tightbeam doctor"

    assert snapshot.guidance =~
             "tightbeam assimilate <ssh-dest> --as-user <adminUserId> --harness <harness>"

    assert snapshot.guidance =~
             "Kung fu (功夫, gōngfu) means skill earned through time and practice"

    flat_guidance = String.replace(snapshot.guidance, "\n", " ")

    assert flat_guidance =~
             "You are the org's general agent and the user's front door, and you WANT this user to get everything tightbeam can give them."

    assert flat_guidance =~
             "Attentiveness is the trait, offers are its expression: notice how this user actually uses tightbeam"

    assert flat_guidance =~
             "bring ONE concrete offer at a natural pause, do it for them if they say yes, and record the answer. Once per need; a decline closes it."

    assert flat_guidance =~
             "If two or more user-created default sessions are alive at once (origin `user:*`, archetype default)"

    assert flat_guidance =~ "user.md's Onboarding section is the offer record"

    assert flat_guidance =~
             "Never re-raise after a recorded decline; a deferral waits for a new, stronger signal."

    assert snapshot.guidance =~ "default-archetype"
    refute snapshot.guidance =~ "agentic-engineering"
    refute snapshot.guidance =~ "tightbeam learn __list__"

    assert Rails.load!(ctx.base_dir) == []
    assert Rules.load!(ctx.base_dir, []) == []
    refute File.exists?(Path.join(identity_dir, "skills"))
    refute File.exists?(Path.join(identity_dir, "rails"))
    refute File.exists?(Path.join(identity_dir, "rules"))

    assert Archetypes.init_identity!(ctx.base_dir) == :noop
    assert {"", 0} = System.cmd("git", ["status", "--short"], cd: identity_dir)
  end

  test "the neutral default's elected baseline skills prescribe no bundle archetype before learn" do
    # Read the SEEDED default, not builtin_default() -- the latter carries skills: [],
    # so looping over it iterates nothing and the assertion passes unconditionally. That
    # is how bundle content ("spawn a product owner") shipped in an elected skill with
    # this very test green.
    default =
      Application.app_dir(:tightbeam, "priv/seed/archetypes/default.toml")
      |> File.read!()
      |> Toml.decode!()

    assert default["skills"] != [],
           "the seeded default elects no skills, so this test would prove nothing"

    bundle_archetypes =
      Application.app_dir(:tightbeam, "priv/kungfu/*/archetypes/*.toml")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> File.read!() |> Toml.decode!() |> Map.fetch!("name") end)

    # The same empty-iteration trap one level down: with no bundle archetypes the
    # refutations below execute zero times and this passes proving nothing.
    assert bundle_archetypes != [],
           "no bundle archetypes found, so the refutations below would check nothing"

    for skill <- default["skills"] do
      body =
        Application.app_dir(:tightbeam, "priv/skills/#{skill}/SKILL.md")
        |> File.read!()

      pre_learn = body |> String.split("## AFTER LEARNING A KUNGFU", parts: 2) |> hd()

      # BOUNDED BY DESIGN (reviewer-ruled): this catches CARELESSNESS, not an adversary.
      # Paraphrases get through ("ask a delivery specialist to take ownership") and that
      # residual is acceptable. What is NOT acceptable is blocking honest text, and a
      # hand-built verb list did exactly that: "spawn a product" rejected "spawn a
      # production support session", "escalate to the product" rejected "escalate to the
      # product support team", "hand off to the" rejected "hand off to the user". Those
      # signatures are gone. Only full archetype NAMES remain, matched at word boundaries
      # so a name can never match as the prefix of an ordinary word. "hand this to the product owner agent" names no
      # archetype token, and a bundle-only VERB is just as much a pre-learn instruction.
      # Both spellings of every archetype, plus the verbs that only make sense once a
      # bundle exists.
      bundle_only_names =
        Enum.flat_map(bundle_archetypes, &[&1, String.replace(&1, "-", " ")])

      for spelling <- bundle_only_names do
        pattern = ~r/\b#{Regex.escape(String.downcase(spelling))}\b/

        refute Regex.match?(pattern, String.downcase(pre_learn)),
               "neutral elected skill #{skill} names bundle-only archetype #{inspect(spelling)} before learn"
      end
    end
  end

  test "the operating manual names the shell as the path to every substrate verb" do
    manual = Archetypes.builtin_fragments()["operating-manual.md"]
    assert manual =~ "shell tool"
    assert manual =~ "PATH"
    assert Map.keys(Archetypes.builtin_fragments()) == ["operating-manual.md"]
    refute manual =~ "--role reviewer"
    refute manual =~ "--role coder"
    refute manual =~ "worktree-session"
  end

  test "the shipped bundle loads role guidance and elected shared skills", ctx do
    Identity.init!(ctx.base_dir)

    assert {:ok, _revision} =
             Identity.learn!(ctx.base_dir, "agentic-engineering", "user:flynn")

    loaded = Archetypes.load!(ctx.base_dir)

    assert Map.keys(loaded) |> Enum.sort() ==
             ~w(coder default orchestrator product-owner recon reviewer spec-writer)

    assert loaded["product-owner"].skills == [
             "tightbeam-dispatching",
             "base-synchronization",
             "product-discovery",
             "human-communication"
           ]

    coder =
      Identity.snapshot_at!(
        ctx.base_dir,
        Identity.live_revision!(ctx.base_dir),
        "coder",
        :codex
      )

    assert coder.guidance =~ "Nontrivial bugs start with a causal verdict"

    product_owner =
      Identity.snapshot_at!(
        ctx.base_dir,
        Identity.live_revision!(ctx.base_dir),
        "product-owner",
        :codex
      )

    assert Map.keys(product_owner.skills) == [
             "base-synchronization",
             "human-communication",
             "product-discovery"
           ]

    refute File.regular?(
             Path.join([
               ctx.base_dir,
               "identity",
               "skills",
               "tightbeam-dispatching",
               "SKILL.md"
             ])
           )
  end

  # Every archetype x both harnesses, and each `snapshot_at!` is a chain of
  # SEQUENTIAL git forks (rev-parse for the required refs, ls-tree for the
  # guidance set, then a `git show` per fragment, manifest and skill). A single
  # `git rev-parse HEAD` measured 1.6-2.6s on this box under a five-lane load
  # against ~5ms idle, so the loop's cost is dominated by fork latency and
  # scales with machine load, not with anything the test does.
  #
  # ExUnit's default per-test timeout is 60s and this run exceeded it — a
  # BUDGET failure, not a defect the test found. It is the same root as
  # @cold_runner_prompt_timeout in gateway_test and the same missing contract
  # (#111): there is nothing to wait on, so there is nothing to barrier against.
  # Both tests that walk this loop are tagged, not just the one that happened to
  # blow up, because a budget fixed one site at a time leaves its twin holding
  # the number already shown to be wrong.
  @tag timeout: 180_000
  test "one composer delivers operating guidance to every archetype for both harnesses", ctx do
    Identity.init!(ctx.base_dir)

    assert {:ok, _revision} =
             Identity.learn!(ctx.base_dir, "agentic-engineering", "user:flynn")

    loaded = Archetypes.load!(ctx.base_dir)
    revision = Identity.live_revision!(ctx.base_dir)

    for name <- Map.keys(loaded), harness <- [:codex, :claude] do
      guidance = Identity.snapshot_at!(ctx.base_dir, revision, name, harness).guidance

      assert guidance =~ "tightbeam identity edit <archetype>"
      assert guidance =~ "tightbeam learn <bundle>"
      assert guidance =~ "tightbeam unlearn <bundle>"
      assert guidance =~ "tightbeam identity relearn"
      assert guidance =~ "tightbeam identity status"
      assert guidance =~ "tightbeam identity apply"

      case harness do
        :codex ->
          assert guidance =~ "Codex developer message"
          refute guidance =~ "Claude system prompt. It is authoritative"

        :claude ->
          assert guidance =~ "Claude system prompt"
          refute guidance =~ "Codex developer message. It is authoritative"
      end
    end
  end

  # Same loop, same git-fork cost, same reason — see the tag above.
  @tag timeout: 180_000
  test "every archetype's served snapshot carries the operating manual", ctx do
    Identity.init!(ctx.base_dir)

    assert {:ok, _revision} =
             Identity.learn!(ctx.base_dir, "agentic-engineering", "user:flynn")

    loaded = Archetypes.load!(ctx.base_dir)
    revision = Identity.live_revision!(ctx.base_dir)

    for name <- Map.keys(loaded), harness <- [:codex, :claude] do
      guidance = Identity.snapshot_at!(ctx.base_dir, revision, name, harness).guidance

      assert guidance =~ "# Operating tightbeam"
      assert guidance =~ "shell tool"
      assert guidance =~ "PATH"
    end
  end

  test "an org's own operating-manual fragment wins and is served exactly once", ctx do
    Identity.init!(ctx.base_dir)
    identity_dir = Path.join(ctx.base_dir, "identity")
    File.write!(Path.join(identity_dir, "guidance/operating-manual.md"), "ORG MANUAL v2")
    publish!(identity_dir, "org manual")

    revision = Identity.live_revision!(ctx.base_dir)
    guidance = Identity.snapshot_at!(ctx.base_dir, revision, "default", :codex).guidance

    assert length(String.split(guidance, "ORG MANUAL v2")) == 2
    refute guidance =~ "# Operating tightbeam"
  end

  test "an explicit operating-manual include resolves and is not double-appended", ctx do
    Identity.init!(ctx.base_dir)
    identity_dir = Path.join(ctx.base_dir, "identity")

    File.write!(Path.join([identity_dir, "archetypes", "manualist.toml"]), """
    name = "manualist"
    [guidance]
    text = '#include "operating-manual.md"'
    """)

    publish!(identity_dir, "manualist")

    revision = Identity.live_revision!(ctx.base_dir)
    guidance = Identity.snapshot_at!(ctx.base_dir, revision, "manualist", :codex).guidance

    assert length(String.split(guidance, "# Operating tightbeam")) == 2
  end

  test "manifest parsing is boot-equivalent and unknown elections fail", ctx do
    Identity.init!(ctx.base_dir)
    manifest = Path.join([ctx.base_dir, "identity", "archetypes", "default.toml"])

    File.write!(manifest, """
    name = "default"
    skills = ["does-not-exist"]
    where = ["testhost"]
    """)

    assert_raise ArgumentError, ~r/elects unknown skills/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "kungfu scaffold rejects every invalid name class before identity mutation", ctx do
    for name <- ["", "-demo", "Demo", "demo_name", "demo--name", "demo-"] do
      assert_raise ArgumentError, ~r/invalid kungfu name/, fn ->
        Archetypes.scaffold_kungfu!(ctx.base_dir, name, "A useful capability.", "user:flynn")
      end

      refute File.exists?(Path.join(ctx.base_dir, "identity/.git"))
    end
  end

  test "kungfu scaffold requires purpose before identity mutation", ctx do
    for purpose <- [nil, "", "  "] do
      assert_raise ArgumentError, "kungfu purpose is required", fn ->
        Archetypes.scaffold_kungfu!(ctx.base_dir, "demo", purpose, "user:flynn")
      end

      refute File.exists?(Path.join(ctx.base_dir, "identity/.git"))
    end
  end

  test "kungfu scaffold refuses each occupied target without writing any sibling", ctx do
    relative_templates = scaffold_templates()

    for {occupied_template, index} <- Enum.with_index(relative_templates) do
      base_dir = Path.join(ctx.base_dir, "collision-#{index}")
      assert :initialized = Identity.init!(base_dir)
      identity_dir = Path.join(base_dir, "identity")
      name = "collision-#{index}"
      occupied_relative = String.replace(occupied_template, "<name>", name)
      occupied = Path.join(identity_dir, occupied_relative)
      File.mkdir_p!(Path.dirname(occupied))
      File.write!(occupied, "operator-owned")

      assert_raise ArgumentError,
                   "kungfu scaffold target already exists: identity/#{occupied_relative}",
                   fn ->
                     Archetypes.scaffold_kungfu!(
                       base_dir,
                       name,
                       "A useful capability.",
                       "user:flynn"
                     )
                   end

      assert File.read!(occupied) == "operator-owned"

      for template <- relative_templates -- [occupied_template] do
        sibling = template |> String.replace("<name>", name) |> then(&Path.join(identity_dir, &1))
        refute File.exists?(sibling)
      end
    end
  end

  test "kungfu scaffold commits on main and publishes live through the identity seam", ctx do
    paths =
      Archetypes.scaffold_kungfu!(
        ctx.base_dir,
        "demo",
        ~s(Help teams turn "ideas" into shipped work.\nKeep it accountable.),
        "user:flynn"
      )

    identity_dir = Path.join(ctx.base_dir, "identity")

    assert Enum.map(paths, &Path.relative_to(&1, identity_dir)) == scaffold_paths("demo")

    assert git!(identity_dir, ["rev-parse", "main"]) ==
             git!(identity_dir, ["rev-parse", "tightbeam/live"])

    assert git!(identity_dir, ["log", "-1", "--format=%s|%an"]) ==
             "kungfu-scaffold: demo|user:flynn"

    assert Archetypes.load!(ctx.base_dir)["demo-role"].skills == []
  end

  test "unknown keys, bad harness defaults, and missing reference locations fail boot", ctx do
    manifests = manifests_dir!(ctx.base_dir)
    path = Path.join(manifests, "bad.toml")

    cases = [
      {"name = \"bad\"\nware = [\"local\"]\n", ~r/unknown top-level archetype keys.*ware/},
      {"name = \"bad\"\n[defaults]\nharness = \"other\"\n",
       ~r/unknown harness "other"; expected one of: claude, codex, fixture/},
      {"name = \"bad\"\n[references]\nrepo = { access = \"read\" }\n",
       ~r/reference repo is missing location/}
    ]

    for {body, message} <- cases do
      File.write!(path, body)
      assert_raise ArgumentError, message, fn -> Archetypes.load!(ctx.base_dir) end
    end
  end

  # Stored selections hold FIELDS. A preference written as `"claude-fable-5[1m]"`
  # is refused by name rather than split here — splitting is the guess that read
  # a vendor context window as one of our reasoning levels and lost the model.
  test "archetype defaults and model preferences are fields, and packed strings are refused",
       ctx do
    path = Path.join(manifests_dir!(ctx.base_dir), "prefs.toml")

    File.write!(path, """
    name = "prefs"

    [defaults]
    model = "claude-fable-5"
    effort = "high"
    context = "1m"

    [[model_preferences]]
    model = "claude-fable-5"
    effort = "high"

    [[model_preferences]]
    model = "gpt-5.6-sol"
    """)

    archetype = Archetypes.load!(ctx.base_dir)["prefs"]

    assert archetype.defaults[:model] ==
             Tightbeam.Model.new("claude-fable-5", effort: "high", context: "1m")

    assert archetype.model_preferences == [
             Tightbeam.Model.new("claude-fable-5", effort: "high"),
             Tightbeam.Model.new("gpt-5.6-sol")
           ]

    File.write!(path, """
    name = "prefs"
    model_preferences = ["claude-fable-5[1m]"]
    """)

    assert_raise ArgumentError, ~r/is a packed string; a preference is fields/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    File.write!(path, """
    name = "prefs"

    [[model_preferences]]
    effort = "high"
    """)

    assert_raise ArgumentError, ~r/model_preferences entry is missing model/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "where wildcard must stand alone and where must be non-empty", ctx do
    path = Path.join(manifests_dir!(ctx.base_dir), "bad.toml")

    File.write!(path, "name = \"bad\"\nwhere = [\"*\", \"eezo\"]\n")

    assert_raise ArgumentError, ~r/must be the only element/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    File.write!(path, "name = \"bad\"\nwhere = []\n")
    assert_raise ArgumentError, ~r/non-empty list/, fn -> Archetypes.load!(ctx.base_dir) end

    File.write!(path, "name = \"roamer\"\nwhere = [\"*\"]\n")
    assert Archetypes.load!(ctx.base_dir)["roamer"].where == ["*"]
  end

  test "containment posture is deny-only, defaulted, and boot-validated", ctx do
    path = Path.join(manifests_dir!(ctx.base_dir), "contained.toml")
    assert Archetypes.builtin_default().containment == %{fs: :off, network: :open}

    File.write!(path, """
    name = "contained"
    [containment]
    fs = "off"
    network = "open"
    """)

    assert Archetypes.load!(ctx.base_dir)["contained"].containment ==
             %{fs: :off, network: :open}

    # "workdir" was the adapter-containment posture; deleted by ruling (#36).
    for body <- [
          "[containment]\nunknown = true\n",
          "[containment]\nfs = \"offf\"\n",
          "[containment]\nfs = \"workdir\"\n",
          "[containment]\nnetwork = \"loopback\"\n"
        ] do
      File.write!(path, "name = \"contained\"\n" <> body)
      assert_raise ArgumentError, fn -> Archetypes.load!(ctx.base_dir) end
    end
  end

  test "session overrides validate in order and normalize deterministically", ctx do
    identity_dir = identity_dir!(ctx.base_dir)

    for name <- ["alpha", "zeta"] do
      path = Path.join([identity_dir, "skills", name, "SKILL.md"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# #{name}")
    end

    archetype = Archetypes.load!(ctx.base_dir)["default"]

    for {raw, message} <- [
          {nil, "must be an object"},
          {%{"other" => true}, "unknown override keys"},
          {%{"skills_add" => "alpha"}, "must be a list of strings"},
          {%{"skills_add" => ["alpha", 1]}, "must be a list of strings"},
          {%{"skills_add" => ["missing"]}, "unknown override skill names: missing"},
          {%{"guidance_extra" => 42}, "must be a string"},
          {%{"guidance_extra" => ~s(#include "missing.md")},
           "unknown guidance fragment \"missing.md\""}
        ] do
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
  end

  test "archetype names may not contain the effective-identity separator", ctx do
    path = Path.join(manifests_dir!(ctx.base_dir), "bad.toml")
    File.write!(path, "name = \"bad--name\"\n")

    assert_raise ArgumentError, ~r/may not contain --/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "load refuses an org copy of a reserved substrate skill and names its path", ctx do
    identity_dir = identity_dir!(ctx.base_dir)
    path = Path.join([identity_dir, "skills", "tightbeam-onboarding", "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# org shadow")

    assert_raise ArgumentError,
                 "#{path}: rename or remove the org copy; substrate names are reserved",
                 fn -> Archetypes.load!(ctx.base_dir) end
  end

  test "mcp declarations compile to the byte-pinned ACP shape and sort deterministically", ctx do
    path = Path.join(manifests_dir!(ctx.base_dir), "coder.toml")

    File.write!(path, """
    name = "coder"
    [mcp.zeta]
    command = "z"
    [mcp.alpha]
    command = "xcodebuildmcp"
    args = ["--daemon"]
    env = { Z_LAST = "last", XCODEBUILD_MCP_MODE = "cli" }
    """)

    archetype = Archetypes.load!(ctx.base_dir)["coder"]
    assert Enum.map(archetype.mcp, & &1.name) == ["alpha", "zeta"]

    assert Archetypes.acp_mcp_servers(archetype) == [
             %{
               "name" => "alpha",
               "command" => "xcodebuildmcp",
               "args" => ["--daemon"],
               "env" => [
                 %{"name" => "XCODEBUILD_MCP_MODE", "value" => "cli"},
                 %{"name" => "Z_LAST", "value" => "last"}
               ]
             },
             %{"name" => "zeta", "command" => "z", "args" => [], "env" => []}
           ]
  end

  test "invalid mcp declarations fail boot", ctx do
    path = Path.join(manifests_dir!(ctx.base_dir), "bad.toml")

    for {manifest, message} <- [
          {"[mcp.bad_name]\ncommand = \"ok\"\n", ~r/invalid mcp server name/},
          {"[mcp.missing]\nargs = []\n", ~r/mcp server missing is missing "command"/},
          {"[mcp.empty]\ncommand = \"\"\n", ~r/mcp server empty is missing "command"/},
          {"[mcp.badargs]\ncommand = \"ok\"\nargs = [1]\n", ~r/args must be a list of strings/},
          {"[mcp.badenv]\ncommand = \"ok\"\nenv = { MODE = 1 }\n",
           ~r/env must be string keys and values/},
          {"[mcp.remote]\ncommand = \"ok\"\nurl = \"https://example.test\"\n",
           ~r/unknown mcp server keys.*url/}
        ] do
      File.write!(path, manifest)
      assert_raise ArgumentError, message, fn -> Archetypes.load!(ctx.base_dir) end
    end
  end

  test "missing fragments and include cycles fail boot", ctx do
    identity_dir = identity_dir!(ctx.base_dir)
    manifest = Path.join([identity_dir, "archetypes", "broken.toml"])

    File.write!(manifest, """
    name = "broken"
    [guidance]
    text = '#include "nope.md"'
    """)

    assert_raise ArgumentError, ~r/unknown guidance fragment "nope.md"/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    File.write!(Path.join(identity_dir, "guidance/a.md"), ~s(#include "b.md"))
    File.write!(Path.join(identity_dir, "guidance/b.md"), ~s(#include "a.md"))

    File.write!(manifest, """
    name = "broken"
    [guidance]
    text = '#include "a.md"'
    """)

    assert_raise ArgumentError, ~r/include cycle: a.md -> b.md -> a.md/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  defp manifests_dir!(base_dir), do: Path.join(identity_dir!(base_dir), "archetypes")

  defp identity_dir!(base_dir) do
    Identity.init!(base_dir)
    Path.join(base_dir, "identity")
  end

  defp scaffold_templates do
    [
      "archetypes/<name>-role.toml",
      "guidance/<name>-role.md",
      "skills/<name>-example/SKILL.md",
      "rails/<name>-example.toml",
      "kungfu/<name>/capabilities.md",
      "kungfu/<name>/preferred-models.md",
      "kungfu/<name>/intake.md",
      "kungfu/<name>/manifest.toml",
      "kungfu/<name>/README.md"
    ]
  end

  defp scaffold_paths(name),
    do: Enum.map(scaffold_templates(), &String.replace(&1, "<name>", name))

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> raise "git failed #{status}: #{output}"
    end
  end

  defp publish!(identity_dir, message) do
    git!(identity_dir, ["add", "-A"])

    git!(identity_dir, [
      "-c",
      "user.name=test",
      "-c",
      "user.email=test@test",
      "commit",
      "-m",
      message
    ])

    git!(identity_dir, [
      "update-ref",
      "refs/heads/tightbeam/live",
      git!(identity_dir, ["rev-parse", "main"])
    ])
  end
end
