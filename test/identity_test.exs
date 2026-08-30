defmodule Tightbeam.IdentityTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog

  alias Tightbeam.Identity

  setup do
    base = Path.join(System.tmp_dir!(), "tb-identity-#{System.unique_integer([:positive])}")
    source = Path.join(base, "source")
    runtime = Path.join(base, "runtime")
    write_source!(source, "role-v1", "skill-v1")
    previous = Application.get_env(:tightbeam, :identity_source_dir)
    Application.put_env(:tightbeam, :identity_source_dir, source)

    on_exit(fn ->
      if previous do
        Application.put_env(:tightbeam, :identity_source_dir, previous)
      else
        Application.delete_env(:tightbeam, :identity_source_dir)
      end

      File.rm_rf!(base)
    end)

    %{base: runtime, root: base, source: source}
  end

  test "neutral seed creates the exact three refs and only the two seed files", ctx do
    assert :initialized = Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    refs = git!(dir, ["branch", "--format=%(refname:short)"])

    assert MapSet.new(String.split(refs, "\n", trim: true)) ==
             MapSet.new(["main", "tightbeam/live", "tightbeam/upstream"])

    assert git!(dir, ["log", "--max-parents=0", "-1", "--format=%s", "main"]) ==
             "seed: neutral-identity"

    assert git!(dir, ["ls-tree", "-r", "--name-only", "main"])
           |> String.split("\n", trim: true) ==
             ["archetypes/default.toml", "guidance/operating-model.md"]

    snapshot = Identity.snapshot!(ctx.base, "default", :codex)
    assert snapshot.skills == %{}
    assert snapshot.guidance =~ "tightbeam learn <bundle>"
    refute snapshot.guidance =~ "role-v1"

    assert Identity.available_bundles() == [
             %{
               name: "agentic-engineering",
               purpose:
                 "Give your organization a disciplined way to turn product ideas and bug reports into shipped software, with tracked work, independent review, and verification.",
               phrases: [
                 "I want my code reviewed before it merges.",
                 "We keep shipping bugs that someone should have caught.",
                 "I want a spec agreed before anyone starts writing code.",
                 "My agents rewrite things I never asked them to touch.",
                 "The same bug keeps coming back and nobody finds the cause.",
                 "I want to know a change was actually tested, not just claimed."
               ],
               root_archetype: "product-owner"
             }
           ]
  end

  test "concurrent neutral-seed initialization publishes one complete repository", ctx do
    results =
      1..2
      |> Task.async_stream(fn _ -> Identity.init!(ctx.base) end, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(results) == [:initialized, :noop]

    identity_dir = Path.join(ctx.base, "identity")

    assert identity_dir
           |> git!(["branch", "--format=%(refname:short)"])
           |> String.split("\n", trim: true)
           |> MapSet.new() == MapSet.new(["main", "tightbeam/live", "tightbeam/upstream"])
  end

  # Work-custody pin: operating-model.md is composed into EVERY archetype, so
  # the custody rail reaches every session including learned-kungfu archetypes.
  # The forensic reason it exists (2026-08-18): retirement deletes a workdir
  # unless it holds registered in-workspace artifacts, so undeclared work is
  # destroyed silently and attests that cite raw workdir paths point at bytes
  # nobody owns — 7 of 10 paths cited over one day were already gone. Pin the
  # load-bearing phrases so an edit that keeps the file cannot gut the rail.
  test "the operating model carries the work-custody rail, not just the identity seam" do
    model =
      File.read!(Application.app_dir(:tightbeam, "priv/seed/guidance/operating-model.md"))

    assert model =~ "Work custody: the last step of finishing"
    assert model =~ "DELETED unless it holds\nregistered artifacts"
    assert model =~ "A path\nwritten into an attest is a pointer, not custody"
    assert model =~ "finishing has a fixed last step, not a judgment call"
    assert model =~ "tightbeam artifact-record --kind <kind> --title"
    assert model =~ "an unneeded artifact costs one row, an unrecorded one costs the work"
    assert model =~ "that\nfile must be an artifact FIRST"
    assert model =~ "the handoff is the artifact, never the\npath"
  end

  test "a shipped bundle manifest without purpose is refused when bundles are read", ctx do
    File.write!(Path.join(ctx.source, "manifest.toml"), ~s(root_archetype = "product-owner"\n))

    assert_raise KeyError, ~r/key "purpose" not found/, fn ->
      Identity.available_bundles()
    end
  end

  test "a scaffold manifest without purpose is refused before identity mutation", ctx do
    assert_raise KeyError, ~r/key "purpose" not found/, fn ->
      Identity.scaffold!(
        ctx.base,
        "demo",
        [{"kungfu/demo/manifest.toml", ~s(root_archetype = "demo-role"\n)}],
        "operator"
      )
    end

    refute File.exists?(Path.join(ctx.base, "identity/.git"))
  end

  test "a manifest may omit phrases and projects an empty list", ctx do
    File.write!(Path.join(ctx.source, "manifest.toml"), """
    root_archetype = "product-owner"
    purpose = "Help a team ship dependable work."
    """)

    assert [%{phrases: []}] = Identity.available_bundles()
  end

  test "a manifest with invalid phrases is refused before identity mutation", ctx do
    for phrases <- [
          ~s(phrases = "A useful signal."),
          "phrases = []",
          ~s(phrases = ["A useful signal.", " "])
        ] do
      assert_raise ArgumentError, ~r/phrases must be a non-empty list/, fn ->
        Identity.scaffold!(
          ctx.base,
          "demo",
          [
            {"kungfu/demo/manifest.toml",
             """
             root_archetype = "demo-role"
             purpose = "Help a team do demo work."
             #{phrases}
             """}
          ],
          "operator"
        )
      end

      refute File.exists?(Path.join(ctx.base, "identity/.git"))
    end
  end

  test "explicit learn installs the shipped bundle and committed receipt", ctx do
    assert :initialized = Identity.init!(ctx.base)
    assert {:ok, revision} = learn!(ctx.base, "agentic-engineering", "operator")
    codex = Identity.snapshot!(ctx.base, "coder", :codex)
    claude = Identity.snapshot!(ctx.base, "coder", :claude)
    assert codex.revision == claude.revision and codex.revision == revision
    assert codex.skills == %{"role-skill" => "skill-v1"}
    assert codex.guidance =~ "Codex developer message"
    assert claude.guidance =~ "Claude system prompt"
    assert codex.guidance =~ "tightbeam identity edit"

    receipt = Path.join(ctx.base, "identity/kungfu/agentic-engineering/installed.toml")
    assert File.read!(receipt) =~ ~s(name = "agentic-engineering")
    assert {:noop, ^revision} = learn!(ctx.base, "agentic-engineering", "operator")
  end

  test "shipped engineering bundle imports the test receipt rule and role guidance", ctx do
    shipped = Path.expand("priv/kungfu/agentic-engineering")
    Application.put_env(:tightbeam, :identity_source_dir, shipped)
    base = Path.join(ctx.root, "shipped-runtime")

    assert {:ok, _revision} = learn!(base, "agentic-engineering", "operator")

    engineering_rule = File.read!(Path.join(base, "identity/rules/engineering.toml"))
    assert engineering_rule =~ ~s(name = "code-review-requires-passing-tests")
    assert engineering_rule =~ ~s(on_rule_denied = "surface")

    reviewer = Identity.snapshot!(base, "reviewer", :codex)
    assert reviewer.guidance =~ "producer holder filed the `tests-passed`"

    coder = Identity.snapshot!(base, "coder", :codex)
    assert coder.guidance =~ "Before the ready-for-review progress attest"
    assert coder.guidance =~ "--verdict tests-passed"
  end

  test "init refuses an identity repository missing the live ref with repair guidance", ctx do
    assert :initialized = Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    git!(dir, ["update-ref", "-d", "refs/heads/tightbeam/live"])

    assert_raise ArgumentError,
                 "identity repository is missing required refs: tightbeam/live. Repair with: git -C #{dir} branch tightbeam/live main; then tightbeam identity relearn",
                 fn ->
                   Identity.init!(ctx.base)
                 end
  end

  test "init tells an empty repository to be removed and re-learned", ctx do
    dir = Path.join(ctx.base, "identity")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-b", "main"])

    assert_raise ArgumentError,
                 "identity repository is missing required refs: main, tightbeam/upstream, tightbeam/live. Repair with: remove #{dir} and re-boot to re-learn",
                 fn ->
                   Identity.init!(ctx.base)
                 end
  end

  test "init verifies required refs stored only in packed-refs", ctx do
    assert :initialized = Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    git!(dir, ["pack-refs", "--all", "--prune"])

    refute File.exists?(Path.join(dir, ".git/refs/heads/tightbeam/live"))
    assert :noop = Identity.init!(ctx.base)

    packed_path = Path.join(dir, ".git/packed-refs")

    packed =
      packed_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.ends_with?(&1, " refs/heads/tightbeam/live"))
      |> Enum.join("\n")

    File.write!(packed_path, packed)

    assert_raise ArgumentError,
                 "identity repository is missing required refs: tightbeam/live. Repair with: git -C #{dir} branch tightbeam/live main; then tightbeam identity relearn",
                 fn ->
                   Identity.init!(ctx.base)
                 end
  end

  test "reserved skills reconcile at exact cwd without product collisions", ctx do
    learn_test_bundle!(ctx)
    cwd = Path.join(ctx.root, "plain")
    nested = Path.join(cwd, "nested-repo")
    File.mkdir_p!(Path.join(cwd, ".codex/skills/role-skill"))
    File.write!(Path.join(cwd, ".codex/skills/role-skill/SKILL.md"), "product")
    File.mkdir_p!(nested)
    git!(nested, ["init"])
    nested_exclude = File.read!(Path.join(nested, ".git/info/exclude"))

    Identity.provision!(ctx.base, "coder", :codex, cwd)

    assert File.read!(Path.join(cwd, ".codex/skills/role-skill/SKILL.md")) == "product"

    assert File.read!(Path.join(cwd, ".codex/skills/tightbeam__role-skill/SKILL.md")) ==
             "skill-v1"

    refute File.exists?(Path.join(nested, ".codex"))
    assert File.read!(Path.join(nested, ".git/info/exclude")) == nested_exclude

    manifest = """
    name = "coder"
    skills = []

    [guidance]
    text = '#include "coder.md"'
    """

    edit!(ctx.base, "coder", :manifest, manifest, "test")
    Identity.provision!(ctx.base, "coder", :codex, cwd)
    refute File.exists?(Path.join(cwd, ".codex/skills/tightbeam__role-skill"))
    assert File.read!(Path.join(cwd, ".codex/skills/role-skill/SKILL.md")) == "product"
  end

  test "real repo exclusion hides only reserved materialized skills", ctx do
    learn_test_bundle!(ctx)
    repo = Path.join(ctx.root, "repo")
    File.mkdir_p!(Path.join(repo, ".codex/skills/product"))
    File.write!(Path.join(repo, ".codex/skills/product/SKILL.md"), "product")
    git!(repo, ["init"])
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "product"], "product")

    Identity.provision!(ctx.base, "coder", :codex, repo)

    assert git!(repo, ["status", "--porcelain"]) == ""
    assert File.read!(Path.join(repo, ".codex/skills/product/SKILL.md")) == "product"

    assert File.read!(Path.join(repo, ".git/info/exclude")) =~
             ".codex/skills/tightbeam__*"
  end

  test "linked worktrees keep product collisions visible and reserved skills hidden", ctx do
    learn_test_bundle!(ctx)
    repo = Path.join(ctx.root, "linked-source")
    linked = Path.join(ctx.root, "linked-worktree")
    File.mkdir_p!(Path.join(repo, ".codex/skills/role-skill"))
    File.write!(Path.join(repo, ".codex/skills/role-skill/SKILL.md"), "product")
    git!(repo, ["init"])
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "product"], "product")
    git!(repo, ["worktree", "add", "-b", "linked", linked])

    Identity.provision!(ctx.base, "coder", :codex, linked)
    File.write!(Path.join(linked, ".codex/skills/role-skill/SKILL.md"), "product changed")

    status = git!(linked, ["status", "--porcelain"])
    assert status =~ ".codex/skills/role-skill/SKILL.md"
    refute status =~ "tightbeam__role-skill"

    assert File.read!(Path.join(linked, ".codex/skills/tightbeam__role-skill/SKILL.md")) ==
             "skill-v1"
  end

  test "plain workdirs materialize at exact cwd for both harnesses and never touch nested repos",
       ctx do
    learn_test_bundle!(ctx)

    for harness <- [:codex, :claude] do
      cwd = Path.join(ctx.root, "plain-#{harness}")
      nested = Path.join(cwd, "product")
      File.mkdir_p!(nested)
      git!(nested, ["init"])
      exclude = File.read!(Path.join(nested, ".git/info/exclude"))

      Identity.provision!(ctx.base, "coder", harness, cwd)
      prefix = skills_prefix(harness)

      assert File.read!(Path.join([cwd, prefix, "skills", "tightbeam__role-skill", "SKILL.md"])) ==
               "skill-v1"

      refute File.exists?(Path.join(nested, prefix))
      assert File.read!(Path.join(nested, ".git/info/exclude")) == exclude
    end
  end

  defp skills_prefix(:codex), do: ".codex"
  defp skills_prefix(:claude), do: ".claude"

  test "personal skills are outside the elected served snapshot", ctx do
    learn_test_bundle!(ctx)
    personal = Path.join(ctx.root, "personal/.codex/skills/personal/SKILL.md")
    File.mkdir_p!(Path.dirname(personal))
    File.write!(personal, "personal")

    snapshot = Identity.snapshot!(ctx.base, "coder", :codex)
    assert snapshot.skills == %{"role-skill" => "skill-v1"}
    refute Map.has_key?(snapshot.skills, "personal")
  end

  test "invalid manifest is refused without a commit or dirty tree", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    before = git!(dir, ["rev-parse", "main"])
    original = File.read!(Path.join(dir, "archetypes/coder.toml"))

    assert_raise ArgumentError, fn ->
      edit!(
        ctx.base,
        "coder",
        :manifest,
        "name = \"coder\"\nskills = [\"missing\"]\n",
        "test"
      )
    end

    assert git!(dir, ["rev-parse", "main"]) == before
    assert git!(dir, ["status", "--porcelain"]) == ""
    assert File.read!(Path.join(dir, "archetypes/coder.toml")) == original
  end

  test "customization leaves source untouched and relearn preserves changes and deletions", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    prior_upstream = git!(dir, ["rev-parse", "tightbeam/upstream"])
    source_before = tree_digest(ctx.source)
    edit!(ctx.base, "coder", :guidance, "local-role", "test")
    assert tree_digest(ctx.source) == source_before

    File.write!(Path.join(ctx.source, "guidance/new.md"), "new-source")
    File.rm!(Path.join(ctx.source, "skills/role-skill/SKILL.md"))
    File.rmdir!(Path.join(ctx.source, "skills/role-skill"))

    File.write!(Path.join(ctx.source, "archetypes/coder.toml"), """
    name = "coder"
    skills = []

    [guidance]
    text = '#include "coder.md"'
    """)

    assert {:ok, revision} = relearn!(ctx.base, "relearn operator")
    assert revision == Identity.live_revision!(ctx.base)
    next_upstream = git!(dir, ["rev-parse", "tightbeam/upstream"])
    assert git!(dir, ["rev-parse", "#{next_upstream}^"]) == prior_upstream

    assert git!(dir, ["log", "-1", "--format=%an <%ae>"]) ==
             "relearn operator <relearn-operator@tightbeam.local>"

    assert File.read!(Path.join(ctx.base, "identity/guidance/coder.md")) == "local-role"
    refute File.exists?(Path.join(ctx.base, "identity/skills/role-skill"))
  end

  # A host with NO git identity anywhere: no global config, no system config, and
  # nothing in the environment. That is a fresh satellite, and it is where #58 was
  # found -- `relearn!` reported a phantom `{:conflict, []}` because git refused the
  # merge commit for want of a committer and the empty conflict list was read as one.
  # Nothing proved that fix, so CI could not have caught it coming back.
  #
  # Both write paths are covered, because both supply their own committer and both
  # are reachable on such a host: `edit!` was observed on shrdlu committing cleanly
  # as `user:flynn <user-flynn@tightbeam.local>` with no host identity present, and
  # that observation was the only evidence it worked.
  test "relearn and edit both commit on a host with no git identity at all", ctx do
    # `useConfigOnly` is what makes this a real bare host rather than a tidied one.
    # Emptying the config is not enough: git falls back to GUESSING an identity from
    # the passwd entry and the hostname, so a machine with no configured identity
    # still commits -- as "Mike Manzano <mike@eezo…>" here. That fallback is what
    # made this environment untestable by simply clearing config, and it is off on
    # a fresh satellite, where the commit genuinely has nowhere to get a committer.
    bare_config = Path.join(ctx.root, "bare-gitconfig")
    File.write!(bare_config, "[user]\n\tuseConfigOnly = true\n")

    System.put_env("GIT_CONFIG_GLOBAL", bare_config)
    System.put_env("GIT_CONFIG_SYSTEM", bare_config)

    for key <- ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL) do
      System.delete_env(key)
    end

    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")

    # The environment really is bare: git itself cannot commit here unaided, so a
    # pass below is the substrate supplying an identity rather than one leaking in
    # from the developer's machine.
    File.write!(Path.join(dir, "scratch.md"), "probe")
    {_, 0} = System.cmd("git", ["-C", dir, "add", "scratch.md"], stderr_to_stdout: true)

    {output, status} =
      System.cmd("git", ["-C", dir, "commit", "-m", "unaided"], stderr_to_stdout: true)

    # STAGED first, so this fails for want of a committer and not for want of a
    # change. An unstaged probe exits non-zero with "nothing to commit", which would
    # make this precondition pass on any machine and prove nothing at all.
    assert status != 0
    assert output =~ "user.useConfigOnly" or output =~ "tell me who you are"

    {_, 0} = System.cmd("git", ["-C", dir, "reset", "scratch.md"], stderr_to_stdout: true)
    File.rm!(Path.join(dir, "scratch.md"))

    assert edit!(ctx.base, "coder", :guidance, "no-identity-edit", "user:flynn")

    assert git!(dir, ["log", "-1", "--format=%an <%ae>", "main"]) ==
             "user:flynn <user-flynn@tightbeam.local>"

    File.write!(Path.join(ctx.source, "guidance/new.md"), "new-source")

    assert {:ok, revision} = relearn!(ctx.base, "relearn operator")
    assert revision == Identity.live_revision!(ctx.base)

    assert git!(dir, ["log", "-1", "--format=%an <%ae>"]) ==
             "relearn operator <relearn-operator@tightbeam.local>"

    assert File.read!(Path.join(dir, "guidance/coder.md")) == "no-identity-edit"
  end

  # The second gate a pre-upgrade org hits, and the one its own repair walks into.
  #
  # An org seeded before `operating-model.md` shipped has main only, so boot raises
  # the missing-refs error first. That error says to create the refs from main — and
  # doing exactly that gets you here, where the tree is still too old to serve. Both
  # halves are the same upgrade, so the first error now names relearn too.
  test "an org whose tree predates a required fragment says so, and says relearn", ctx do
    Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")

    File.rm!(Path.join(dir, "guidance/operating-model.md"))
    git!(dir, ["add", "-A"], "tightbeam")
    git!(dir, ["commit", "-m", "pre-upgrade tree"], "tightbeam")
    git!(dir, ["branch", "-f", "tightbeam/live", "main"])

    error =
      assert_raise(ArgumentError, fn -> Identity.snapshot!(ctx.base, "default", :claude) end)

    message = error.message

    assert message =~ "has no guidance/operating-model.md"
    assert message =~ "tightbeam identity relearn"
    assert message =~ "seeded before"

    # The fragment map is NOT in the message. It is every guidance file in the org,
    # and dumping it buries the one filename and one verb that matter.
    refute message =~ "wisdom"
    assert String.length(message) < 400
  end

  test "the missing-refs repair names relearn, not just the branch commands", ctx do
    Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    git!(dir, ["branch", "-D", "tightbeam/live"])

    error = assert_raise(ArgumentError, fn -> Identity.live_revision!(ctx.base) end)

    assert error.message =~ "missing required refs: tightbeam/live"
    assert error.message =~ "branch tightbeam/live main"
    assert error.message =~ "then tightbeam identity relearn"
  end

  test "dirty and conflicted relearns never move live", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    live = Identity.live_revision!(ctx.base)
    File.write!(Path.join(dir, "guidance/dirty.md"), "dirty")
    assert_raise ArgumentError, ~r/dirty/, fn -> relearn!(ctx.base, "test") end
    File.rm!(Path.join(dir, "guidance/dirty.md"))

    edit!(ctx.base, "coder", :guidance, "local-change", "test")
    stable = Identity.live_revision!(ctx.base)
    File.write!(Path.join(ctx.source, "guidance/coder.md"), "source-change")
    assert {:conflict, ["guidance/coder.md"]} = relearn!(ctx.base, "test")
    assert Identity.live_revision!(ctx.base) == stable
    assert stable != live
    assert Identity.status(ctx.base).state == :relearn_conflicted
    assert :ok = Identity.abort_relearn!(ctx.base)
    assert Identity.live_revision!(ctx.base) == stable
  end

  test "relearn surfaces a non-conflict merge failure with git's reason", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    live = Identity.live_revision!(ctx.base)
    hook = Path.join(dir, ".git/hooks/pre-merge-commit")

    File.write!(hook, """
    #!/bin/sh
    echo "pre-merge policy rejected relearn" >&2
    exit 1
    """)

    File.chmod!(hook, 0o755)

    result = relearn!(ctx.base, "test")

    assert {:error, message} = result
    assert message =~ "pre-merge policy rejected relearn"
    refute match?({:conflict, _paths}, result)
    assert Identity.live_revision!(ctx.base) == live
  end

  test "live is the only publication and one stamped OID cannot mix revisions", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    live = Identity.live_revision!(ctx.base)
    cwd = Path.join(ctx.root, "published")
    before = Identity.provision_at!(ctx.base, live, "coder", :codex, cwd)

    File.write!(Path.join(dir, "guidance/coder.md"), "main-only")
    File.write!(Path.join(dir, "skills/role-skill/SKILL.md"), "skill-main")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", "unpublished main"], "test")

    from_live = Identity.provision!(ctx.base, "coder", :codex, cwd)
    assert from_live.revision == live
    assert from_live.guidance =~ "role-v1"
    assert from_live.skills == %{"role-skill" => "skill-v1"}

    git!(dir, ["update-ref", "refs/heads/tightbeam/live", git!(dir, ["rev-parse", "main"]), live])
    advanced = Identity.live_revision!(ctx.base)
    assert advanced != live

    assert File.read!(Path.join(cwd, ".codex/skills/tightbeam__role-skill/SKILL.md")) ==
             "skill-v1"

    assert before.revision == live
    assert before.guidance =~ "role-v1"
    assert before.skills == %{"role-skill" => "skill-v1"}

    pinned = Identity.provision_at!(ctx.base, live, "coder", :codex, cwd)
    assert pinned.revision == live
    assert pinned.guidance =~ "role-v1"
    assert pinned.skills == %{"role-skill" => "skill-v1"}

    refreshed = Identity.provision!(ctx.base, "coder", :codex, cwd)
    assert refreshed.revision == advanced
    assert refreshed.guidance =~ "main-only"
    assert refreshed.skills == %{"role-skill" => "skill-main"}
  end

  test "unlearn removes exactly the receipted bundle and relearn does not resurrect it", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    receipt_path = Path.join(dir, "kungfu/agentic-engineering/installed.toml")
    receipt = receipt_path |> File.read!() |> Toml.decode!()

    assert revision = unlearn!(ctx.base, "agentic-engineering", "operator")
    assert revision == Identity.live_revision!(ctx.base)

    for relative <- receipt["paths"] do
      refute File.exists?(Path.join(dir, relative))
    end

    refute File.exists?(receipt_path)
    assert File.regular?(Path.join(dir, "archetypes/default.toml"))
    assert File.regular?(Path.join(dir, "guidance/operating-model.md"))
    assert git!(dir, ["log", "-1", "--format=%s"]) == "unlearn: agentic-engineering"

    assert {:ok, _revision} = relearn!(ctx.base, "operator")
    refute File.exists?(Path.join(dir, "archetypes/coder.toml"))
    refute File.exists?(receipt_path)
  end

  test "unlearn restores the pre-learn identity tree without empty directories", ctx do
    Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    before = identity_tree(dir)

    assert {:ok, _revision} = learn!(ctx.base, "agentic-engineering", "operator")
    assert unlearn!(ctx.base, "agentic-engineering", "operator")

    assert identity_tree(dir) == before
  end

  test "unlearn keeps a bundle-created directory populated by the org", ctx do
    guard_base = Path.join(ctx.root, "guard")
    guard_dir = Path.join(guard_base, "identity")
    org_relative = "skills/role-skill/org.md"
    org_path = Path.join(guard_dir, org_relative)

    Identity.init!(guard_base)
    assert {:ok, _revision} = learn!(guard_base, "agentic-engineering", "operator")
    File.write!(org_path, "org-authored")
    git!(guard_dir, ["add", "--", org_relative])
    git!(guard_dir, ["commit", "-m", "identity: add org file"], "operator")

    assert unlearn!(guard_base, "agentic-engineering", "operator")
    assert File.read!(org_path) == "org-authored"
    assert File.dir?(Path.dirname(org_path))
  end

  test "unlearn tolerates a receipted path that is already absent", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    missing = "skills/role-skill/SKILL.md"

    File.rm!(Path.join(dir, missing))
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", "remove receipted path outside identity edit"], "operator")

    assert unlearn!(ctx.base, "agentic-engineering", "operator")
    refute File.exists?(Path.join(dir, missing))
    refute File.exists?(Path.join(dir, "kungfu/agentic-engineering/installed.toml"))
  end

  test "a customized path kept through a relearn deletion conflict remains owned", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    owned_path = "guidance/coder.md"
    absolute = Path.join(dir, owned_path)

    edit!(ctx.base, "coder", :guidance, "operator-kept guidance", "operator")
    File.rm!(Path.join(ctx.source, owned_path))

    assert {:conflict, [^owned_path]} = relearn!(ctx.base, "operator")
    assert File.read!(absolute) == "operator-kept guidance"
    git!(dir, ["add", "--", owned_path])
    assert resolve_relearn!(ctx.base, "operator")

    receipt =
      dir
      |> Path.join("kungfu/agentic-engineering/installed.toml")
      |> File.read!()
      |> Toml.decode!()

    assert owned_path in receipt["paths"]
    assert unlearn!(ctx.base, "agentic-engineering", "operator")
    refute File.exists?(absolute)
  end

  test "an independently authored add/add winner is not receipted and survives unlearn", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")
    independent_path = "guidance/independent.md"
    absolute = Path.join(dir, independent_path)
    org_content = "org-authored guidance"

    File.write!(absolute, org_content)
    git!(dir, ["add", "--", independent_path])
    git!(dir, ["commit", "-m", "identity: add independent guidance"], "operator")
    File.write!(Path.join(ctx.source, independent_path), "newly shipped guidance")

    assert {:conflict, [^independent_path]} = relearn!(ctx.base, "operator")

    # Resolve the add/add conflict in the org's favor without using checkout:
    # the staged merge result itself is the provenance Identity must inspect.
    File.write!(absolute, org_content)
    git!(dir, ["add", "--", independent_path])
    assert resolve_relearn!(ctx.base, "operator")

    receipt =
      dir
      |> Path.join("kungfu/agentic-engineering/installed.toml")
      |> File.read!()
      |> Toml.decode!()

    refute independent_path in receipt["paths"]
    assert unlearn!(ctx.base, "agentic-engineering", "operator")
    assert File.read!(absolute) == org_content
  end

  test "removing a learned skill removes its path from the receipt", ctx do
    learn_test_bundle!(ctx)
    dir = Path.join(ctx.base, "identity")

    neutral_manifest = "name = \"coder\"\nskills = []\n"
    edit!(ctx.base, "coder", :manifest, neutral_manifest, "operator")
    edit!(ctx.base, "coder", {:skill, "role-skill", true}, nil, "operator")

    receipt =
      dir
      |> Path.join("kungfu/agentic-engineering/installed.toml")
      |> File.read!()
      |> Toml.decode!()

    refute "skills/role-skill/SKILL.md" in receipt["paths"]
    assert unlearn!(ctx.base, "agentic-engineering", "operator")
  end

  test "learn refuses seed-owned bundle paths and unknown names list shipped bundles", ctx do
    assert :initialized = Identity.init!(ctx.base)
    forbidden = Path.join(ctx.source, "archetypes/default.toml")
    File.write!(forbidden, "name = \"default\"\nskills = []\n")

    assert_raise ArgumentError, ~r/claims seed-owned path archetypes\/default.toml/, fn ->
      learn!(ctx.base, "agentic-engineering", "operator")
    end

    File.rm!(forbidden)

    error =
      assert_raise ArgumentError, fn ->
        learn!(ctx.base, "missing", "operator")
      end

    assert error.message =~ "unknown kungfu bundle missing"
    assert error.message =~ "available bundles: agentic-engineering"

    traversal =
      assert_raise ArgumentError, fn ->
        learn!(ctx.base, "../guidance", "operator")
      end

    assert traversal.message =~ "unknown kungfu bundle ../guidance"
    assert traversal.message =~ "available bundles: agentic-engineering"
  end

  test "legacy enriched roots mint one receipt without changing their seed-owned paths", ctx do
    dir = build_legacy_org!(ctx)
    enriched_default = File.read!(Path.join(dir, "archetypes/default.toml"))

    assert :noop = Identity.init!(ctx.base)
    assert File.regular?(Path.join(dir, "kungfu/agentic-engineering/installed.toml"))
    assert File.read!(Path.join(dir, "archetypes/default.toml")) == enriched_default
    assert git!(dir, ["log", "-1", "--format=%s"]) == "learn-receipt: agentic-engineering"

    assert :noop = Identity.init!(ctx.base)

    assert git!(dir, ["log", "--format=%s"])
           |> String.split("\n", trim: true)
           |> Enum.count(&(&1 == "learn-receipt: agentic-engineering")) == 1

    assert {:ok, _revision} = relearn!(ctx.base, "operator")
    assert File.read!(Path.join(dir, "archetypes/default.toml")) == enriched_default

    receipt =
      dir
      |> Path.join("kungfu/agentic-engineering/installed.toml")
      |> File.read!()
      |> Toml.decode!()

    for doc <- ~w(capabilities.md intake.md preferred-models.md manifest.toml) do
      refute doc in receipt["paths"]
      assert "kungfu/agentic-engineering/#{doc}" in receipt["paths"]
      refute File.exists?(Path.join(dir, doc))
      assert File.regular?(Path.join(dir, "kungfu/agentic-engineering/#{doc}"))
    end

    neutral_default =
      Application.app_dir(:tightbeam, "priv/seed/archetypes/default.toml") |> File.read!()

    edit!(ctx.base, "default", :manifest, neutral_default, "operator")
    assert unlearn!(ctx.base, "agentic-engineering", "operator")
  end

  test "dirty legacy roots defer grandfather mint and refuse relearn until a clean boot", ctx do
    dir = build_legacy_org!(ctx)
    dirty = Path.join(dir, "dirty.md")
    File.write!(dirty, "operator work")

    log = capture_log(fn -> assert :noop = Identity.init!(ctx.base) end)
    assert log =~ "grandfather receipt mint deferred"
    refute File.exists?(Path.join(dir, "kungfu/agentic-engineering/installed.toml"))

    assert_raise ArgumentError, ~r/grandfather receipt mint is pending/, fn ->
      relearn!(ctx.base, "operator")
    end

    File.rm!(dirty)
    assert :noop = Identity.init!(ctx.base)
    assert File.regular?(Path.join(dir, "kungfu/agentic-engineering/installed.toml"))
  end

  defp write_source!(source, role, skill) do
    File.mkdir_p!(Path.join(source, "archetypes"))
    File.mkdir_p!(Path.join(source, "guidance"))
    File.mkdir_p!(Path.join(source, "skills/role-skill"))

    File.write!(Path.join(source, "archetypes/coder.toml"), """
    name = "coder"
    skills = ["role-skill"]

    [guidance]
    text = '#include "coder.md"'
    """)

    File.write!(Path.join(source, "guidance/coder.md"), role)
    File.write!(Path.join(source, "skills/role-skill/SKILL.md"), skill)

    for doc <- ~w(capabilities.md intake.md preferred-models.md manifest.toml) do
      File.cp!(
        Application.app_dir(:tightbeam, "priv/kungfu/agentic-engineering/#{doc}"),
        Path.join(source, doc)
      )
    end
  end

  defp edit!(base, archetype, target, content, author) do
    base
    |> Identity.edit!(archetype, target, content, author)
    |> publish_candidate!(base)
  end

  defp unlearn!(base, name, author) do
    base
    |> Identity.unlearn!(name, author)
    |> publish_candidate!(base)
  end

  defp resolve_relearn!(base, author) do
    base
    |> Identity.resolve_relearn!(author)
    |> publish_candidate!(base)
  end

  defp learn!(base, name, author) do
    case Identity.learn!(base, name, author) do
      {:ok, candidate} -> {:ok, publish_candidate!(candidate, base)}
      other -> other
    end
  end

  defp relearn!(base, author) do
    case Identity.relearn!(base, author) do
      {:ok, candidate} -> {:ok, publish_candidate!(candidate, base)}
      other -> other
    end
  end

  defp publish_candidate!(candidate, base) when is_map(candidate) do
    assert {:ok, revision} = Identity.publish_live!(base, candidate)
    revision
  end

  defp learn_test_bundle!(ctx) do
    Identity.init!(ctx.base)
    assert {:ok, _revision} = learn!(ctx.base, "agentic-engineering", "test")
  end

  defp build_legacy_org!(ctx) do
    dir = Path.join(ctx.base, "identity")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-b", "main"])

    for entry <- File.ls!(ctx.source) do
      File.cp_r!(Path.join(ctx.source, entry), Path.join(dir, entry))
    end

    File.write!(Path.join(dir, "archetypes/default.toml"), """
    name = "default"
    skills = []

    [guidance]
    text = '#include "coder.md"'
    """)

    File.cp!(
      Application.app_dir(:tightbeam, "priv/seed/guidance/operating-model.md"),
      Path.join(dir, "guidance/operating-model.md")
    )

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", "learn: agentic-engineering"], "tightbeam")
    git!(dir, ["branch", "tightbeam/upstream"])
    git!(dir, ["branch", "tightbeam/live"])
    dir
  end

  defp tree_digest(path) do
    path
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{Path.relative_to(&1, path), File.read!(&1)})
  end

  defp identity_tree(root), do: identity_tree(root, "")

  defp identity_tree(root, relative) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn entry ->
      if relative == "" and entry == ".git" do
        []
      else
        child_relative = if relative == "", do: entry, else: Path.join(relative, entry)
        child = Path.join(root, child_relative)

        if File.dir?(child) do
          [{child_relative, :directory} | identity_tree(root, child_relative)]
        else
          [{child_relative, {:file, File.read!(child)}}]
        end
      end
    end)
  end

  defp git!(dir, args, author \\ nil) do
    env =
      if author,
        do: [
          {"GIT_AUTHOR_NAME", author},
          {"GIT_AUTHOR_EMAIL", "test@tightbeam.invalid"},
          {"GIT_COMMITTER_NAME", author},
          {"GIT_COMMITTER_EMAIL", "test@tightbeam.invalid"}
        ],
        else: []

    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> raise "git failed #{status}: #{output}"
    end
  end
end
