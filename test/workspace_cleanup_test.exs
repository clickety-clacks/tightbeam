defmodule Tightbeam.WorkspaceCleanupTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{Artifacts, DB, Gateway, Model, Org, Placement, Schema, WorkspaceCleanup}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: :"cleanup_#{System.unique_integer([:positive])}"})
    :ok = Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "workspace-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, _} = DB.query(db, "INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES('cleanup-work','Cleanup','owner','owner',1)")
    session = Org.create(db, %{session_key: "cleanup-example", display_name: "Example", owner_user_id: "owner", origin: "user:owner", archetype: "default", host: Placement.local_host_name(), harness: "claude", provider: "anthropic", model: Model.new("example")})
    config = %{db: db, base_dir: base, wake_tick_ms: 1_000}
    workspace = Placement.workdir_path(config, session)
    File.mkdir_p!(workspace)
    %{db: db, base: base, config: config, session: session, workspace: workspace}
  end

  test "retirement records pending cleanup without waiting for filesystem work", ctx do
    parent = self()
    config = Map.put(ctx.config, :workspace_cleanup_runner, fn _, _, _ ->
      send(parent, :runner_started)
      receive do :release -> {"DONE\t0\n", 0} end
    end)
    worker = start_supervised!({WorkspaceCleanup, config: config})
    result = Gateway.handlers(config)["retire"].(%{origin: "user:owner", principal: {:user, "owner"}, session_key: ctx.session.session_key, params: %{}})
    assert result.retired_session_keys == [ctx.session.session_key]
    assert_receive :runner_started, 5_000
    assert Org.get(ctx.db, ctx.session.session_key).state == "retired"
    assert WorkspaceCleanup.health(ctx.db).count == 1
    Process.exit(worker, :kill)
  end

  test "a workspace with no artifacts disappears and completed work is not queued again", ctx do
    File.write!(Path.join(ctx.workspace, "scratch"), "discard")
    retire(ctx)
    assert %{status: "completed"} = WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)
    refute File.exists?(ctx.workspace)
    assert WorkspaceCleanup.health(ctx.db).count == 0
    assert :ok = Schema.ensure_all(ctx.db)
    assert WorkspaceCleanup.health(ctx.db).count == 0
  end

  test "cleanup ignores unrelated and unplaceable references and archives only declared files", ctx do
    kept = Path.join(ctx.workspace, "reports/kept.md")
    File.mkdir_p!(Path.dirname(kept))
    File.write!(kept, "preserve")
    File.write!(Path.join(ctx.workspace, "scratch"), "discard")
    artifact = artifact(ctx, kept)
    artifact(ctx, "https://example.com/report")
    artifact(ctx, "/elsewhere/report")
    legacy = artifact(ctx, "legacy-reference")
    :ok = DB.execute(ctx.db, "DROP TRIGGER artifacts_origin_immutable")
    {:ok, _} = DB.query(ctx.db, "UPDATE artifacts SET originHost=NULL,originWorkspace=NULL WHERE artifactId=?1", [legacy.artifact_id])
    retire(ctx)
    assert %{status: "completed"} = WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)
    refute File.exists?(ctx.workspace)
    archived = Artifacts.get(ctx.db, artifact.artifact_id)
    assert archived.state == "archived"
    assert File.read!(archived.home) == "preserve"
    assert File.ls!(Path.dirname(archived.home)) == ["kept.md"]
    refute File.exists?(Path.join(Path.dirname(Path.dirname(archived.home)), "scratch"))
  end

  test "configured archive crosses filesystems and resumes after the move before repointing", ctx do
    archive = Path.join("/dev/shm", "cleanup-archive-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(archive) end)
    Application.put_env(:tightbeam, :archive_dir, archive)
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    kept = Path.join(ctx.workspace, "kept")
    File.write!(kept, "preserve across devices")
    artifact = artifact(ctx, kept)
    retire(ctx)
    # A failed database update must leave the move recoverable on the next attempt.
    :ok = DB.execute(ctx.db, "CREATE TRIGGER refuse_archive BEFORE UPDATE OF state ON artifacts WHEN NEW.state='archived' BEGIN SELECT RAISE(ABORT,'archive update unavailable'); END")
    assert %{status: "incomplete"} = WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)
    assert WorkspaceCleanup.health(ctx.db).count == 1
    refute File.exists?(ctx.workspace)
    :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_archive")
    assert %{status: "completed"} = WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)
    home = Artifacts.get(ctx.db, artifact.artifact_id).home
    assert String.starts_with?(home, archive <> "/")
    assert File.read!(home) == "preserve across devices"
    assert File.stat!(ctx.base).major_device != File.stat!(archive).major_device
  end

  test "the recorded backlog migration runs once and includes retirements with no attempt", ctx do
    :ok = DB.execute(ctx.db, "DROP TRIGGER retired_workspace_cleanup_enqueue; DROP TABLE retired_workspace_cleanup; DROP TABLE retired_archive_relocation; DELETE FROM retired_workspace_cleanup_migration")
    retire(ctx)
    assert :ok = Schema.ensure_all(ctx.db)
    assert %{count: 1, unfinished: [%{reason: "cleanup pending"}]} = WorkspaceCleanup.health(ctx.db)
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM retired_workspace_cleanup_migration")
    assert :ok = Schema.ensure_all(ctx.db)
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM retired_workspace_cleanup")
  end

  defp retire(ctx) do
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [ctx.session.session_key])
  end

  defp artifact(ctx, path) do
    Artifacts.record(ctx.db, %{principal: {:session, ctx.session.session_key}, session_key: ctx.session.session_key,
      params: %{kind: "report", title: "Example report", origin_path: path, work_item_id: "cleanup-work"}})
  end
end
