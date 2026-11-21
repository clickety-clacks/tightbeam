defmodule Tightbeam.Identity.SeedReconcileTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{AdminProjection, DB, Identity, Reminders, Rules, Schema}
  alias Tightbeam.Identity.SeedReconcile

  @notice "assignment-terminal-handoff"
  @reminder "terminal-child-action-reminder"
  @notice_path "rules/row-reaction-handoff.toml"
  @reminder_path "rules/row-reaction-terminal-action.toml"
  @shapes Path.expand("fixtures/identity-seed-shapes", __DIR__)
  @seed Path.expand("../priv/seed", __DIR__)

  setup do
    base =
      Path.join(System.tmp_dir!(), "seed-reconcile-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    %{base: base, db: db, dir: Path.join(base, "identity")}
  end

  test "a fresh install has both finished-child rules and the reminder wording, and reconcile is a no-op",
       ctx do
    assert :initialized = Identity.init!(ctx.base)
    live = Identity.live_revision!(ctx.base)

    assert %{added: [], attention: [], candidate: nil} = SeedReconcile.run!(ctx.base, ctx.db)
    assert Identity.live_revision!(ctx.base) == live
    assert [@notice, @reminder] == loaded_reaction_names(ctx.base)

    # No learned kungfu: the reminder text is the shipped default.
    refute File.exists?(Path.join(ctx.dir, "kungfu"))
    assert Reminders.render(ctx.base, "terminal-action", %{child_assignment_id: "a1"}) =~ "a1"
  end

  for shape <- ["0.1.15", "0.1.16"] do
    test "an install shaped like #{shape} gets every shipped seed rule at startup, once, with no relearn",
         ctx do
      init_shape!(ctx.base, unquote(shape))
      prior = Identity.live_revision!(ctx.base)
      refute @notice in loaded_reaction_names(ctx.base)
      assert :ok = AdminProjection.bootstrap_served(ctx.db, ctx.base)

      assert %{added: added, attention: [], candidate: %{candidate_revision: revision}} =
               SeedReconcile.run!(ctx.base, ctx.db)

      assert @notice in added and @reminder in added

      # Recorded as one new commit, published, and stamped as served.
      assert Identity.live_revision!(ctx.base) == revision
      refute revision == prior
      assert git(ctx.dir, ["rev-parse", "main"]) == revision
      assert git(ctx.dir, ["rev-parse", "HEAD^"]) == prior
      assert git(ctx.dir, ["status", "--porcelain"]) == ""
      assert git(ctx.dir, ["log", "-1", "--format=%s"]) =~ "add shipped seed rules"

      assert %{"liveRevision" => ^revision} =
               AdminProjection.stamped_item(ctx.db, "identity", "served")

      for path <- seed_law_paths() do
        assert live_bytes(ctx.dir, path) == File.read!(Path.join(@seed, path))
      end

      assert [@notice, @reminder] == loaded_reaction_names(ctx.base)

      # The next boot finds nothing to do.
      assert %{added: [], attention: [], candidate: nil} = SeedReconcile.run!(ctx.base, ctx.db)
      assert Identity.live_revision!(ctx.base) == revision
      assert Identity.status(ctx.base).missing_seed_law_notice == nil
    end
  end

  test "a 0.1.16 install whose learned engineering bundle already supplies the rules gets no duplicate",
       ctx do
    init_shape!(ctx.base, "0.1.16")

    # The released bundle put the same named reactions in its own rule files.
    for path <- [@notice_path, @reminder_path] do
      destination = Path.join(ctx.dir, "kungfu/engineering/#{path}")
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(@seed, path), destination)
    end

    commit_and_publish!(ctx.dir, "fixture: bundle supplies the rules")

    assert %{candidate: %{}} = SeedReconcile.run!(ctx.base, ctx.db)
    refute File.exists?(Path.join(ctx.dir, @notice_path))
    refute File.exists?(Path.join(ctx.dir, @reminder_path))
    # A duplicated name would silently disable both, so each must still load.
    assert [@notice, @reminder] == loaded_reaction_names(ctx.base)

    # Retiring the bundle leaves the shipped default in its place at next start.
    File.rm_rf!(Path.join(ctx.dir, "kungfu"))
    commit_and_publish!(ctx.dir, "fixture: bundle retired")
    refute @notice in loaded_reaction_names(ctx.base)
    assert %{added: added} = SeedReconcile.run!(ctx.base, ctx.db)
    assert added == [@notice, @reminder]
    assert [@notice, @reminder] == loaded_reaction_names(ctx.base)
  end

  test "an operator-edited live rule keeps its bytes and an operator-deleted one comes back", ctx do
    assert :initialized = Identity.init!(ctx.base)
    edited = File.read!(Path.join(ctx.dir, @notice_path)) <> "\n# operator edit\n"
    File.write!(Path.join(ctx.dir, @notice_path), edited)
    File.rm!(Path.join(ctx.dir, @reminder_path))
    commit_and_publish!(ctx.dir, "operator: edit one rule, drop the other")

    assert %{added: [@reminder], attention: [], candidate: %{}} =
             SeedReconcile.run!(ctx.base, ctx.db)

    assert live_bytes(ctx.dir, @notice_path) == edited
    assert live_bytes(ctx.dir, @reminder_path) == File.read!(Path.join(@seed, @reminder_path))
  end

  test "an occupied path that lacks a shipped entry is reported loudly and never rewritten", ctx do
    assert :initialized = Identity.init!(ctx.base)
    renamed = String.replace(File.read!(Path.join(ctx.dir, @notice_path)), @notice, "local-name")
    File.write!(Path.join(ctx.dir, @notice_path), renamed)
    commit_and_publish!(ctx.dir, "operator: renamed the rule")
    live = Identity.live_revision!(ctx.base)

    log =
      capture_log(fn ->
        assert %{candidate: nil, added: [], attention: [message]} =
                 SeedReconcile.run!(ctx.base, ctx.db)

        send(self(), {:message, message})
      end)

    assert_received {:message, message}
    assert message =~ @notice_path
    assert log =~ "tightbeam identity relearn"
    assert Identity.live_revision!(ctx.base) == live
    assert live_bytes(ctx.dir, @notice_path) == renamed
    assert Identity.status(ctx.base).missing_seed_law_notice =~ @notice_path
  end

  test "unpublished identity changes on main stop the add and the warning names the command",
       ctx do
    init_shape!(ctx.base, "0.1.15")
    File.write!(Path.join(ctx.dir, "guidance/local.md"), "pending operator change\n")
    git(ctx.dir, ["add", "-A"])
    git(ctx.dir, ["commit", "-m", "operator: unpublished"])
    live = Identity.live_revision!(ctx.base)
    refute git(ctx.dir, ["rev-parse", "main"]) == live

    log =
      capture_log(fn ->
        assert %{candidate: nil, added: [], attention: [message]} =
                 SeedReconcile.run!(ctx.base, ctx.db)

        send(self(), {:message, message})
      end)

    assert_received {:message, message}
    assert message =~ @notice and message =~ "unpublished"
    assert log =~ "tightbeam identity relearn"
    assert Identity.live_revision!(ctx.base) == live
    assert Identity.status(ctx.base).missing_seed_law_notice =~ @notice
  end

  test "a failed publication puts main and live back", ctx do
    init_shape!(ctx.base, "0.1.15")
    prior = Identity.live_revision!(ctx.base)

    result =
      Identity.reconcile_seed_law!(ctx.base, fn _candidate -> raise "publication refused" end)

    assert %{candidate: nil, added: [], attention: attention} = result
    assert Enum.any?(attention, &(&1 =~ "publication refused"))
    assert Identity.live_revision!(ctx.base) == prior
    assert git(ctx.dir, ["rev-parse", "main"]) == prior
    assert git(ctx.dir, ["status", "--porcelain"]) == ""
    refute File.exists?(Path.join(ctx.dir, @notice_path))
  end

  defp seed_law_paths do
    ~w(rules rails)
    |> Enum.flat_map(fn kind ->
      @seed |> Path.join(kind) |> File.ls!() |> Enum.map(&Path.join(kind, &1))
    end)
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

  defp loaded_reaction_names(base) do
    Identity.with_recovery_law!(base, fn law_base, revision ->
      Rules.load!(base, [], law_base: law_base, revision: revision)

      Rules.effective_snapshot().reactions
      |> Enum.map(& &1.name)
      |> Enum.filter(&(&1 in [@notice, @reminder]))
    end)
    |> Enum.sort_by(&(&1 != @notice))
  end

  defp live_bytes(dir, path) do
    {bytes, 0} = System.cmd("git", ["show", "tightbeam/live:#{path}"], cd: dir)
    bytes
  end

  defp commit_and_publish!(dir, message) do
    git(dir, ["add", "-A"])
    git(dir, ["commit", "--allow-empty", "-m", message])
    git(dir, ["update-ref", "refs/heads/tightbeam/live", "main"])
  end

  defp git(dir, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fixture"},
      {"GIT_AUTHOR_EMAIL", "fixture@tightbeam.local"},
      {"GIT_COMMITTER_NAME", "Fixture"},
      {"GIT_COMMITTER_EMAIL", "fixture@tightbeam.local"}
    ]

    {output, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    String.trim(output)
  end
end
