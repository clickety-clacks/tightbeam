defmodule Tightbeam.Identity.SeedReconcileTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{AdminProjection, DB, Identity, Rules, Schema}
  alias Tightbeam.Identity.SeedReconcile

  @notice "assignment-terminal-handoff"
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

  test "a fresh install has the finished-child notice rule and reconcile is a no-op", ctx do
    assert :initialized = Identity.init!(ctx.base)
    live = Identity.live_revision!(ctx.base)

    assert %{added: [], attention: [], candidate: nil} = SeedReconcile.run!(ctx.base, ctx.db)
    assert Identity.live_revision!(ctx.base) == live
    assert loaded?(ctx.base)
    refute File.exists?(Path.join(ctx.dir, "kungfu"))
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
    test "an install shaped like #{shape} gets the notice rule at startup, once, with no relearn",
         ctx do
      init_shape!(ctx.base, unquote(shape))
      prior = Identity.live_revision!(ctx.base)
      refute loaded?(ctx.base)
      assert :ok = AdminProjection.bootstrap_served(ctx.db, ctx.base)

      assert %{added: [@notice], attention: [], candidate: %{candidate_revision: revision}} =
               SeedReconcile.run!(ctx.base, ctx.db)

      # Recorded as one new commit, published, and stamped as served.
      assert Identity.live_revision!(ctx.base) == revision
      refute revision == prior
      assert git(ctx.dir, ["rev-parse", "main"]) == revision
      assert git(ctx.dir, ["rev-parse", "HEAD^"]) == prior
      assert git(ctx.dir, ["status", "--porcelain"]) == ""
      assert git(ctx.dir, ["log", "-1", "--format=%s"]) =~ "add shipped seed rules"

      assert %{"liveRevision" => ^revision} =
               AdminProjection.stamped_item(ctx.db, "identity", "served")

      assert live_bytes(ctx.dir, @notice_path) == File.read!(Path.join(@seed, @notice_path))
      assert loaded?(ctx.base)

      # Only the notice is delivered: the parent reminder is not an upgrade default.
      assert {_, status} =
               System.cmd("git", ["cat-file", "-e", "tightbeam/live:#{@reminder_path}"],
                 cd: ctx.dir,
                 stderr_to_stdout: true
               )

      assert status != 0

      # The next boot finds nothing to do.
      assert %{added: [], attention: [], candidate: nil} = SeedReconcile.run!(ctx.base, ctx.db)
      assert Identity.live_revision!(ctx.base) == revision
    end
  end

  test "a rule a learned bundle already supplies is not duplicated, and returns when it is retired",
       ctx do
    init_shape!(ctx.base, "0.1.16")

    # An earlier bundle put the same named reaction in its own rule file.
    destination = Path.join(ctx.dir, "kungfu/engineering/#{@notice_path}")
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Path.join(@seed, @notice_path), destination)
    commit_and_publish!(ctx.dir, "fixture: bundle supplies the rule")

    assert %{candidate: nil, added: []} = SeedReconcile.run!(ctx.base, ctx.db)
    refute File.exists?(Path.join(ctx.dir, @notice_path))
    # A duplicated name would silently disable both, so it must still load once.
    assert loaded?(ctx.base)

    File.rm_rf!(Path.join(ctx.dir, "kungfu"))
    commit_and_publish!(ctx.dir, "fixture: bundle retired")
    refute loaded?(ctx.base)
    assert %{added: [@notice]} = SeedReconcile.run!(ctx.base, ctx.db)
    assert loaded?(ctx.base)
  end

  test "an operator-edited live rule keeps its bytes", ctx do
    assert :initialized = Identity.init!(ctx.base)
    edited = File.read!(Path.join(ctx.dir, @notice_path)) <> "\n# operator edit\n"
    File.write!(Path.join(ctx.dir, @notice_path), edited)
    commit_and_publish!(ctx.dir, "operator: edit the rule")
    live = Identity.live_revision!(ctx.base)

    assert %{added: [], attention: [], candidate: nil} = SeedReconcile.run!(ctx.base, ctx.db)
    assert Identity.live_revision!(ctx.base) == live
    assert live_bytes(ctx.dir, @notice_path) == edited
  end

  test "an occupied path that lacks the shipped entry is reported loudly and never rewritten",
       ctx do
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
  end

  test "a copy in a file the loader never reads (nested, rails, hidden) does not count, and an unrelated bad file does not stop the add",
       ctx do
    init_shape!(ctx.base, "0.1.15")
    File.mkdir_p!(Path.join(ctx.dir, "rules/nested"))
    File.mkdir_p!(Path.join(ctx.dir, "rails"))
    File.cp!(Path.join(@seed, @notice_path), Path.join(ctx.dir, "rules/nested/unread.toml"))
    File.cp!(Path.join(@seed, @notice_path), Path.join(ctx.dir, "rails/unread.toml"))
    File.write!(Path.join(ctx.dir, "rules/broken.toml"), "[[rule]\nname = broken")
    # The loader's wildcard never matches a leading dot, so parked copies are unread too.
    File.cp!(Path.join(@seed, @notice_path), Path.join(ctx.dir, "rules/.disabled.toml"))
    File.mkdir_p!(Path.join(ctx.dir, "kungfu/.hidden/rules"))
    File.cp!(Path.join(@seed, @notice_path), Path.join(ctx.dir, "kungfu/.hidden/rules/parked.toml"))
    commit_and_publish!(ctx.dir, "fixture: unread copies and a bad file")

    # The loader itself ignores every one of those copies.
    refute loaded?(ctx.base)
    assert %{added: [@notice]} = SeedReconcile.run!(ctx.base, ctx.db)
    assert File.exists?(Path.join(ctx.dir, @notice_path))
    assert loaded?(ctx.base)
  end

  test "a start that stopped after committing on main finishes the publication", ctx do
    init_shape!(ctx.base, "0.1.15")
    prior = Identity.live_revision!(ctx.base)
    assert :ok = AdminProjection.bootstrap_served(ctx.db, ctx.base)

    # The process dies after the commit and before anything is published.
    assert :crash ==
             catch_throw(Identity.reconcile_seed_law!(ctx.base, fn _ -> throw(:crash) end))

    committed = git(ctx.dir, ["rev-parse", "main"])
    refute committed == prior
    assert Identity.live_revision!(ctx.base) == prior

    assert %{added: [@notice], attention: [], candidate: %{candidate_revision: ^committed}} =
             SeedReconcile.run!(ctx.base, ctx.db)

    assert Identity.live_revision!(ctx.base) == committed
    assert git(ctx.dir, ["rev-parse", "main"]) == committed

    assert %{"liveRevision" => ^committed} =
             AdminProjection.stamped_item(ctx.db, "identity", "served")

    assert loaded?(ctx.base)
  end

  test "a start that stopped after live moved but before the stamp committed restamps", ctx do
    init_shape!(ctx.base, "0.1.15")
    assert :ok = AdminProjection.bootstrap_served(ctx.db, ctx.base)
    prior = Identity.live_revision!(ctx.base)

    # Live moves (the Git ref), the stamp does not: the later boot finds the rule present.
    assert :crash ==
             catch_throw(
               Identity.reconcile_seed_law!(ctx.base, fn candidate ->
                 {:ok, _} = Identity.publish_live!(ctx.base, candidate)
                 throw(:crash)
               end)
             )

    live = Identity.live_revision!(ctx.base)
    refute live == prior

    assert %{"liveRevision" => ^prior} =
             AdminProjection.stamped_item(ctx.db, "identity", "served")

    assert %{added: [], candidate: nil} = SeedReconcile.run!(ctx.base, ctx.db)
    assert %{"liveRevision" => ^live} = AdminProjection.stamped_item(ctx.db, "identity", "served")
  end

  test "the add does not depend on the reminder file, so removing it from the seed cannot break it",
       ctx do
    init_shape!(ctx.base, "0.1.16")
    seed = Path.join(ctx.base, "seed-without-reminder")
    File.cp_r!(@seed, seed)
    File.rm!(Path.join(seed, @reminder_path))
    previous = Application.get_env(:tightbeam, :identity_seed_dir)
    Application.put_env(:tightbeam, :identity_seed_dir, seed)

    try do
      assert %{added: [@notice], attention: [], candidate: %{}} =
               SeedReconcile.run!(ctx.base, ctx.db)
    after
      if previous,
        do: Application.put_env(:tightbeam, :identity_seed_dir, previous),
        else: Application.delete_env(:tightbeam, :identity_seed_dir)
    end

    assert loaded?(ctx.base)
    refute File.exists?(Path.join(ctx.dir, @reminder_path))
  end

  test "a start that stopped after writing the file and before committing it recovers", ctx do
    init_shape!(ctx.base, "0.1.15")
    prior = Identity.live_revision!(ctx.base)
    leftover = Path.join(ctx.dir, @notice_path)
    File.mkdir_p!(Path.dirname(leftover))
    File.cp!(Path.join(@seed, @notice_path), leftover)
    git(ctx.dir, ["add", "--", @notice_path])
    assert git(ctx.dir, ["status", "--porcelain"]) != ""

    assert %{added: [@notice], attention: [], candidate: %{candidate_revision: revision}} =
             SeedReconcile.run!(ctx.base, ctx.db)

    assert git(ctx.dir, ["rev-parse", "HEAD^"]) == prior
    assert Identity.live_revision!(ctx.base) == revision
    assert git(ctx.dir, ["status", "--porcelain"]) == ""
    assert loaded?(ctx.base)
  end

  test "uncommitted operator changes are never removed by the add", ctx do
    init_shape!(ctx.base, "0.1.15")
    File.write!(Path.join(ctx.dir, "guidance/local.md"), "operator draft\n")
    File.mkdir_p!(Path.join(ctx.dir, "rules"))
    File.cp!(Path.join(@seed, @notice_path), Path.join(ctx.dir, @notice_path))

    capture_log(fn ->
      assert %{candidate: nil, added: [], attention: [message]} =
               SeedReconcile.run!(ctx.base, ctx.db)

      send(self(), {:message, message})
    end)

    assert_received {:message, message}
    assert message =~ "uncommitted"
    assert File.read!(Path.join(ctx.dir, "guidance/local.md")) == "operator draft\n"
  end

  test "a failed stamp repair warns and leaves the published commit, it does not stop start",
       ctx do
    init_shape!(ctx.base, "0.1.15")
    assert :ok = AdminProjection.bootstrap_served(ctx.db, ctx.base)

    assert :crash ==
             catch_throw(
               Identity.reconcile_seed_law!(ctx.base, fn candidate ->
                 {:ok, _} = Identity.publish_live!(ctx.base, candidate)
                 throw(:crash)
               end)
             )

    live = Identity.live_revision!(ctx.base)
    assert {:ok, _} = DB.query(ctx.db, "DROP TABLE admin_projection_versions")

    log =
      capture_log(fn ->
        assert %{candidate: nil, added: []} = SeedReconcile.run!(ctx.base, ctx.db)
      end)

    assert log =~ "served identity stamp"
    assert Identity.live_revision!(ctx.base) == live
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

  # A duplicated name drops both copies, so "loaded" also proves it is defined once.
  defp loaded?(base) do
    Identity.with_recovery_law!(base, fn law_base, revision ->
      Rules.load!(base, [], law_base: law_base, revision: revision)
      Enum.any?(Rules.effective_snapshot().reactions, &(&1.name == @notice))
    end)
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
