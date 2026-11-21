defmodule Tightbeam.RulesBuiltinDefaultTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{Gateway, Identity, Rules}

  @notice "assignment-terminal-handoff"
  @notice_path "rules/row-reaction-handoff.toml"
  @shapes Path.expand("fixtures/identity-seed-shapes", __DIR__)
  @seed Path.expand("../priv/seed", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "builtin-default-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    db = start_supervised!({Tightbeam.DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    %{base: base, dir: Path.join(base, "identity"), db: db}
  end

  test "the notice rule belongs to no kungfu bundle, so retiring one cannot remove it" do
    assert File.regular?(Path.join(@seed, @notice_path))

    holders =
      [__DIR__, "..", "priv", "kungfu", "*", "**", "*.toml"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ @notice))

    assert holders == []
  end

  for shape <- ["0.1.15", "0.1.16"] do
    test "an identity shaped like #{shape} gets the built-in notice rule with no step and no write",
         ctx do
      init_shape!(ctx.base, unquote(shape))
      before = repo_state(ctx.dir)
      refute @notice in reaction_names(ctx.base, false)

      log = capture_log(fn -> assert @notice in reaction_names(ctx.base, true) end)

      assert log =~ "built-in default rule #{@notice} is in use"
      assert log =~ "tightbeam identity relearn"
      # Nothing was written to the identity: refs, tree and status are as they were.
      assert repo_state(ctx.dir) == before
      refute File.exists?(Path.join(ctx.dir, @notice_path))
    end
  end

  test "a fresh install already has the rule, so no built-in is used", ctx do
    assert :initialized = Identity.init!(ctx.base)

    log = capture_log(fn -> assert @notice in reaction_names(ctx.base, true) end)

    refute log =~ "built-in default"
  end

  test "an edited live copy wins and is not overridden", ctx do
    assert :initialized = Identity.init!(ctx.base)
    path = Path.join(ctx.dir, @notice_path)

    File.write!(
      path,
      String.replace(
        File.read!(path),
        ~s(family = "terminal-handoff"),
        ~s(family = "operator-family")
      )
    )

    before = File.read!(path)

    log =
      capture_log(fn ->
        assert [reaction] = reactions(ctx.base, true) |> Enum.filter(&(&1.name == @notice))
        assert reaction.family == "operator-family"
      end)

    refute log =~ "built-in default"
    assert File.read!(path) == before
  end

  test "an unreceipted alternate-path copy remains an organization-wide override", ctx do
    init_shape!(ctx.base, "0.1.16")
    destination = Path.join(ctx.dir, "kungfu/engineering/#{@notice_path}")
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Path.join(@seed, @notice_path), destination)

    capture_log(fn ->
      assert [_one] = reactions(ctx.base, true) |> Enum.filter(&(&1.name == @notice))
    end)
  end

  for {kind, body} <- [
        {"rule",
         """
         [[rule]]
         archetypes = ["*"]
         name = "assignment-terminal-handoff"
         verb = "assign"
         text = "a rule that happens to share the notice's name"
         deny_when = [{ fact = "target.archetype", op = "eq", value = "never-matches" }]
         """},
        {"policy",
         """
         [[policy]]
         archetypes = ["*"]
         name = "assignment-terminal-handoff"
         purpose = "attest-operational-evidence"
         when = [{ fact = "assignment.effect_kind", op = "eq", value = "live_mutation" }]
         """}
      ] do
    test "a valid live #{kind} with the notice's name keeps working and no built-in is added",
         ctx do
      init_shape!(ctx.base, "0.1.15")
      File.mkdir_p!(Path.join(ctx.dir, "rules"))
      File.write!(Path.join(ctx.dir, "rules/same-name.toml"), unquote(body))

      log =
        capture_log(fn ->
          Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, ["assign", "attest"])
        end)

      assert log =~ "built-in default rule #{@notice} is not used"
      refute log =~ "duplicate name"
      refute log =~ "unavailable"
      snapshot = Rules.effective_snapshot()
      assert [] == Enum.filter(snapshot.reactions, &(&1.name == @notice))

      kept = if unquote(kind) == "rule", do: snapshot.rules, else: snapshot.policies
      assert [%{name: @notice}] = kept
      assert Rules.status().unavailable_verbs == []
    end
  end

  test "without the option the loader adds nothing", ctx do
    init_shape!(ctx.base, "0.1.15")
    assert reactions(ctx.base, false) == []
  end

  describe "Rules.rule_file_path?/1" do
    test "matches the files the loader reads and never a dot-prefixed segment" do
      assert Rules.rule_file_path?("rules/a.toml")
      assert Rules.rule_file_path?("kungfu/bundle/rules/a.toml")
      refute Rules.rule_file_path?("rules/.parked.toml")
      refute Rules.rule_file_path?("kungfu/.hidden/rules/a.toml")
      refute Rules.rule_file_path?("rules/nested/a.toml")
      refute Rules.rule_file_path?("rails/a.toml")
      refute Rules.rule_file_path?("rules/a.md")
    end

    test "the loader ignores a parked, dot-prefixed copy", ctx do
      init_shape!(ctx.base, "0.1.15")
      File.mkdir_p!(Path.join(ctx.dir, "rules"))
      File.mkdir_p!(Path.join(ctx.dir, "kungfu/.hidden/rules"))
      File.cp!(Path.join(@seed, @notice_path), Path.join(ctx.dir, "rules/.parked.toml"))

      File.cp!(
        Path.join(@seed, @notice_path),
        Path.join(ctx.dir, "kungfu/.hidden/rules/parked.toml")
      )

      assert reactions(ctx.base, false) == []
    end
  end

  defp reaction_names(base, builtin?), do: Enum.map(reactions(base, builtin?), & &1.name)

  defp reactions(base, builtin?) do
    Identity.with_recovery_law!(base, fn law_base, revision ->
      Rules.load!(base, [],
        law_base: law_base,
        revision: revision,
        builtin_defaults: builtin?
      )

      Rules.effective_snapshot().reactions
    end)
  end

  defp repo_state(dir) do
    for args <- [
          ["rev-parse", "main", "tightbeam/live", "tightbeam/upstream"],
          ["status", "--porcelain"],
          ["reflog", "--all"]
        ] do
      {out, 0} = System.cmd("git", args, cd: dir)
      out
    end
  end

  defp init_shape!(base, shape) do
    previous = Application.get_env(:tightbeam, :identity_seed_dir)
    Application.put_env(:tightbeam, :identity_seed_dir, Path.join(@shapes, shape))

    try do
      assert :initialized = Identity.init!(base)
    after
      if previous,
        do: Application.put_env(:tightbeam, :identity_seed_dir, previous),
        else: Application.delete_env(:tightbeam, :identity_seed_dir)
    end
  end
end
