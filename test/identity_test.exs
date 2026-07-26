defmodule Tightbeam.IdentityTest do
  use ExUnit.Case, async: false

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

  test "learn creates the exact three refs and live snapshots compose both channels", ctx do
    assert :initialized = Identity.init!(ctx.base)
    refs = git!(Path.join(ctx.base, "identity"), ["branch", "--format=%(refname:short)"])

    assert MapSet.new(String.split(refs, "\n", trim: true)) ==
             MapSet.new(["main", "tightbeam/live", "tightbeam/upstream"])

    codex = Identity.snapshot!(ctx.base, "coder", :codex)
    claude = Identity.snapshot!(ctx.base, "coder", :claude)
    assert codex.revision == claude.revision
    assert codex.skills == %{"role-skill" => "skill-v1"}
    assert codex.guidance =~ "Codex developer message"
    assert claude.guidance =~ "Claude system prompt"
    assert codex.guidance =~ "tightbeam identity edit"
  end

  test "init refuses an identity repository missing the live ref with repair guidance", ctx do
    assert :initialized = Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    git!(dir, ["update-ref", "-d", "refs/heads/tightbeam/live"])

    assert_raise ArgumentError,
                 "identity repository is missing required refs: tightbeam/live. Repair with: git -C #{dir} branch tightbeam/live main",
                 fn ->
                   Identity.init!(ctx.base)
                 end
  end

  test "reserved skills reconcile at exact cwd without product collisions", ctx do
    Identity.init!(ctx.base)
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

    Identity.edit!(ctx.base, "coder", :manifest, manifest, "test")
    Identity.provision!(ctx.base, "coder", :codex, cwd)
    refute File.exists?(Path.join(cwd, ".codex/skills/tightbeam__role-skill"))
    assert File.read!(Path.join(cwd, ".codex/skills/role-skill/SKILL.md")) == "product"
  end

  test "real repo exclusion hides only reserved materialized skills", ctx do
    Identity.init!(ctx.base)
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
    Identity.init!(ctx.base)
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
    Identity.init!(ctx.base)

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
    Identity.init!(ctx.base)
    personal = Path.join(ctx.root, "personal/.codex/skills/personal/SKILL.md")
    File.mkdir_p!(Path.dirname(personal))
    File.write!(personal, "personal")

    snapshot = Identity.snapshot!(ctx.base, "coder", :codex)
    assert snapshot.skills == %{"role-skill" => "skill-v1"}
    refute Map.has_key?(snapshot.skills, "personal")
  end

  test "invalid manifest is refused without a commit or dirty tree", ctx do
    Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    before = git!(dir, ["rev-parse", "main"])
    original = File.read!(Path.join(dir, "archetypes/coder.toml"))

    assert_raise ArgumentError, fn ->
      Identity.edit!(
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
    Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    prior_upstream = git!(dir, ["rev-parse", "tightbeam/upstream"])
    source_before = tree_digest(ctx.source)
    Identity.edit!(ctx.base, "coder", :guidance, "local-role", "test")
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

    assert {:ok, revision} = Identity.relearn!(ctx.base)
    assert revision == Identity.live_revision!(ctx.base)
    next_upstream = git!(dir, ["rev-parse", "tightbeam/upstream"])
    assert git!(dir, ["rev-parse", "#{next_upstream}^"]) == prior_upstream
    assert File.read!(Path.join(ctx.base, "identity/guidance/coder.md")) == "local-role"
    refute File.exists?(Path.join(ctx.base, "identity/skills/role-skill"))
  end

  test "dirty and conflicted relearns never move live", ctx do
    Identity.init!(ctx.base)
    dir = Path.join(ctx.base, "identity")
    live = Identity.live_revision!(ctx.base)
    File.write!(Path.join(dir, "guidance/dirty.md"), "dirty")
    assert_raise ArgumentError, ~r/dirty/, fn -> Identity.relearn!(ctx.base) end
    File.rm!(Path.join(dir, "guidance/dirty.md"))

    Identity.edit!(ctx.base, "coder", :guidance, "local-change", "test")
    stable = Identity.live_revision!(ctx.base)
    File.write!(Path.join(ctx.source, "guidance/coder.md"), "source-change")
    assert {:conflict, ["guidance/coder.md"]} = Identity.relearn!(ctx.base)
    assert Identity.live_revision!(ctx.base) == stable
    assert stable != live
    assert Identity.status(ctx.base).state == :relearn_conflicted
    assert :ok = Identity.abort_relearn!(ctx.base)
    assert Identity.live_revision!(ctx.base) == stable
  end

  test "live is the only publication and one stamped OID cannot mix revisions", ctx do
    Identity.init!(ctx.base)
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
    File.write!(Path.join(source, "guidance/operating-model.md"), "tightbeam identity edit")
    File.write!(Path.join(source, "skills/role-skill/SKILL.md"), skill)
  end

  defp tree_digest(path) do
    path
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{Path.relative_to(&1, path), File.read!(&1)})
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
