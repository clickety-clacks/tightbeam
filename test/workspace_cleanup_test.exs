defmodule Tightbeam.WorkspaceCleanupTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{Artifacts, DB, Gateway, Model, Org, Placement, Schema, WorkspaceCleanup}

  setup do
    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})

    db =
      start_supervised!(
        {DB, path: ":memory:", name: :"cleanup_#{System.unique_integer([:positive])}"}
      )

    :ok = Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "workspace-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES('cleanup-work','Cleanup','owner','owner',1)"
      )

    session =
      Org.create(db, %{
        session_key: "cleanup-example",
        display_name: "Example",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "claude",
        provider: "anthropic",
        model: Model.new("example")
      })

    config = %{db: db, base_dir: base, wake_tick_ms: 1_000}
    workspace = Placement.workdir_path(config, session)
    File.mkdir_p!(workspace)
    %{db: db, base: base, config: config, session: session, workspace: workspace}
  end

  test "retirement records pending cleanup without waiting for filesystem work", ctx do
    parent = self()

    config =
      ctx.config
      |> Map.put(:workspace_cleanup_timeout_ms, 60_000)
      |> Map.put(:workspace_cleanup_runner, fn _, _, _ ->
        send(parent, {:runner_started, self()})

        receive do
          :release -> {"DONE\t0\n", 0}
        end
      end)

    worker = start_supervised!({WorkspaceCleanup, config: config})

    request =
      Task.async(fn ->
        Gateway.handlers(config)["retire"].(%{
          origin: "user:owner",
          principal: {:user, "owner"},
          session_key: ctx.session.session_key,
          params: %{}
        })
      end)

    assert_receive {:runner_started, runner}, 5_000
    result = Task.yield(request, 1_000)
    if is_nil(result), do: Task.shutdown(request, :brutal_kill)
    send(runner, :release)
    assert {:ok, %{retired_session_keys: [key]}} = result
    assert key == ctx.session.session_key
    assert Org.get(ctx.db, key).state == "retired"
    :sys.get_state(worker)
  end

  test "a workspace with no artifacts disappears and completed work is not queued again", ctx do
    File.write!(Path.join(ctx.workspace, "scratch"), "discard")
    retire(ctx)

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    refute File.exists?(ctx.workspace)
    assert WorkspaceCleanup.health(ctx.db).count == 0
    assert :ok = Schema.ensure_all(ctx.db)
    assert WorkspaceCleanup.health(ctx.db).count == 0
  end

  test "cleanup ignores unrelated and unplaceable references and archives only declared files",
       ctx do
    kept = Path.join(ctx.workspace, "reports/kept.md")
    File.mkdir_p!(Path.dirname(kept))
    File.write!(kept, "preserve")
    File.write!(Path.join(ctx.workspace, "scratch"), "discard")
    artifact = artifact(ctx, kept)
    artifact(ctx, "https://example.com/report")
    artifact(ctx, "/elsewhere/report")
    legacy = artifact(ctx, "legacy-reference")
    :ok = DB.execute(ctx.db, "DROP TRIGGER artifacts_origin_immutable")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE artifacts SET originHost=NULL,originWorkspace=NULL WHERE artifactId=?1",
        [legacy.artifact_id]
      )

    retire(ctx)

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    refute File.exists?(ctx.workspace)
    archived = Artifacts.get(ctx.db, artifact.artifact_id)
    assert archived.state == "archived"
    assert File.read!(archived.home) == "preserve"
    assert File.ls!(Path.dirname(archived.home)) == ["kept.md"]
    refute File.exists?(Path.join(Path.dirname(Path.dirname(archived.home)), "scratch"))
  end

  test "configured archive crosses filesystems and resumes after the move before repointing",
       ctx do
    archive = Path.join("/dev/shm", "cleanup-archive-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(archive) end)
    Application.put_env(:tightbeam, :archive_dir, archive)
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    kept = Path.join(ctx.workspace, "kept")
    File.write!(kept, "preserve across devices")
    artifact = artifact(ctx, kept)
    retire(ctx)
    # A failed database update must leave the move recoverable on the next attempt.
    :ok =
      DB.execute(
        ctx.db,
        "CREATE TRIGGER refuse_archive BEFORE UPDATE OF state ON artifacts WHEN NEW.state='archived' BEGIN SELECT RAISE(ABORT,'archive update unavailable'); END"
      )

    assert %{status: "incomplete"} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    assert WorkspaceCleanup.health(ctx.db).count == 1
    refute File.exists?(ctx.workspace)
    :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_archive")

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    home = Artifacts.get(ctx.db, artifact.artifact_id).home
    assert String.starts_with?(home, archive <> "/")
    assert File.read!(home) == "preserve across devices"
    assert File.stat!(ctx.base).major_device != File.stat!(archive).major_device
  end

  test "the recorded backlog migration runs once and includes retirements with no attempt", ctx do
    :ok =
      DB.execute(
        ctx.db,
        "DROP TRIGGER retired_workspace_cleanup_enqueue; DROP TABLE retired_workspace_cleanup; DROP TABLE retired_archive_relocation; DELETE FROM retired_workspace_cleanup_migration"
      )

    retire(ctx)
    assert :ok = Schema.ensure_all(ctx.db)

    assert %{count: 1, unfinished: [%{reason: "cleanup pending"}]} =
             WorkspaceCleanup.health(ctx.db)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM retired_workspace_cleanup_migration")

    assert :ok = Schema.ensure_all(ctx.db)
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM retired_workspace_cleanup")
  end

  test "a 0.1.8 predecessor receives the cleanup migration once", ctx do
    prepared =
      Tightbeam.GuardRuntimeFixture.prepare!(
        Path.join(ctx.base, "predecessor"),
        "schema_shape_runtime.exs"
      )

    path = Path.join(prepared.base, "state.db")
    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(path, prepared.payload)
    manifest = File.read!(Path.join(prepared.payload, "build-manifest.json")) |> JSON.decode!()

    transition =
      JSON.encode!(%{
        "base" => Path.dirname(path),
        "source" => "unmarked",
        "target" => manifest["buildIdentity"],
        "expectedSchema" => "operator-decision-requests-v1"
      })

    name = :"cleanup_predecessor_#{System.unique_integer([:positive])}"

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           name: name,
           path: path,
           guard_inputs: [transition: transition],
           payload_root: prepared.payload}, id: name)
      )

    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM retired_workspace_cleanup_migration")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "existing archives move once to the configured directory and their records follow", ctx do
    kept = Path.join(ctx.workspace, "kept")
    File.write!(kept, "older archive")
    artifact = artifact(ctx, kept)
    retire(ctx)

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    old_home = Artifacts.get(ctx.db, artifact.artifact_id).home
    archive = Path.join(ctx.base, "configured-archive")
    Application.put_env(:tightbeam, :archive_dir, archive)
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    worker = start_supervised!({WorkspaceCleanup, config: ctx.config})
    send(worker, :drain)
    :sys.get_state(worker)
    moved = Artifacts.get(ctx.db, artifact.artifact_id)
    assert String.starts_with?(moved.home, archive <> "/")
    assert File.read!(moved.home) == "older archive"
    refute File.exists?(old_home)
    send(worker, :drain)
    :sys.get_state(worker)
    assert Artifacts.get(ctx.db, artifact.artifact_id).home == moved.home
  end

  test "one failed workspace does not prevent the next cleanup and retries when due", ctx do
    other =
      Org.create(ctx.db, %{
        session_key: "other-example",
        display_name: "Other",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "claude",
        provider: "anthropic",
        model: Model.new("example")
      })

    other_workspace = Placement.workdir_path(ctx.config, other)
    File.mkdir_p!(other_workspace)
    File.write!(Path.join(other_workspace, "scratch"), "discard")
    retire(ctx)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        other.session_key
      ])

    attempts = :atomics.new(1, [])

    config =
      Map.put(ctx.config, :workspace_cleanup_runner, fn invocation, script, input ->
        if :atomics.add_get(attempts, 1, 1) == 1,
          do: {"offline", 255},
          else: WorkspaceCleanup.system_runner(invocation, script, input)
      end)

    worker = start_supervised!({WorkspaceCleanup, config: config})
    send(worker, :drain)
    :sys.get_state(worker)
    assert WorkspaceCleanup.health(ctx.db).count == 2
    send(worker, :drain)
    :sys.get_state(worker)
    refute File.exists?(other_workspace)
    assert %{count: 1, unfinished: [%{reason: reason}]} = WorkspaceCleanup.health(ctx.db)
    assert reason =~ "cleanup_command_failed"
    assert WorkspaceCleanup.health(ctx.db, "another-owner").count == 0
    {:ok, _} = DB.query(ctx.db, "UPDATE retired_workspace_cleanup SET nextAt=0 WHERE completed=0")
    send(worker, :drain)
    :sys.get_state(worker)
    refute File.exists?(ctx.workspace)
    assert WorkspaceCleanup.health(ctx.db).count == 0
  end

  test "a missing artifact does not stop deletion of unrelated files", ctx do
    missing = Path.join(ctx.workspace, "missing")
    artifact(ctx, missing)
    scratch = Path.join(ctx.workspace, "scratch")
    File.write!(scratch, "discard")
    retire(ctx)

    assert %{status: "incomplete", blockers: blockers} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    assert Enum.any?(blockers, &(&1.reason == "artifact_missing"))
    refute File.exists?(scratch)
    File.write!(missing, "recovered")

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    assert WorkspaceCleanup.health(ctx.db).count == 0
  end

  test "notification failure after retirement cannot lose cleanup or change the result", ctx do
    config = Map.put(ctx.config, :on_retired, fn _ -> raise "notification unavailable" end)

    result =
      Gateway.handlers(config)["retire"].(%{
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: ctx.session.session_key,
        params: %{}
      })

    assert result.retired_session_keys == [ctx.session.session_key]
    assert %{count: 1} = WorkspaceCleanup.health(ctx.db)

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(config, ctx.db, ctx.session.session_key)

    refute File.exists?(ctx.workspace)
  end

  test "an audit failure cannot turn a completed cleanup into a failure", ctx do
    retire(ctx)

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TRIGGER refuse_cleanup_audit BEFORE INSERT ON lifecycle_events WHEN NEW.kind='retired_workspace_cleanup_completed' BEGIN SELECT RAISE(ABORT,'audit unavailable'); END"
      )

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    refute File.exists?(ctx.workspace)
    assert WorkspaceCleanup.health(ctx.db).count == 0
  end

  defp retire(ctx) do
    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        ctx.session.session_key
      ])
  end

  defp artifact(ctx, path) do
    Artifacts.record(ctx.db, %{
      principal: {:session, ctx.session.session_key},
      session_key: ctx.session.session_key,
      params: %{
        kind: "report",
        title: "Example report",
        origin_path: path,
        work_item_id: "cleanup-work"
      }
    })
  end
end
