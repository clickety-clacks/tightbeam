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

    config = %{
      db: db,
      base_dir: base,
      wake_tick_ms: 1_000,
      workspace_cleanup_runner: &WorkspaceCleanup.system_runner/3
    }

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
    archive_parent = if File.dir?("/dev/shm"), do: "/dev/shm", else: ctx.base
    archive = Path.join(archive_parent, "cleanup-archive-#{System.unique_integer([:positive])}")
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

    if archive_parent == "/dev/shm" do
      assert File.stat!(ctx.base).major_device != File.stat!(archive).major_device
    end
  end

  test "the recorded backlog migration runs once and includes retirements with no attempt", ctx do
    :ok =
      DB.execute(
        ctx.db,
        "DROP TRIGGER retired_workspace_cleanup_enqueue; DROP TABLE retired_workspace_cleanup; DELETE FROM retired_workspace_cleanup_migration"
      )

    retire(ctx)
    assert :ok = Schema.ensure_all(ctx.db)

    assert %{count: 1, reasons: [%{reason: "cleanup pending"}]} =
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
           payload_root: prepared.payload},
          id: name
        )
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

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TRIGGER refuse_archive_repoint BEFORE UPDATE OF home ON artifacts BEGIN SELECT RAISE(ABORT,'archive repoint unavailable'); END"
      )

    worker = start_supervised!({WorkspaceCleanup, config: ctx.config})
    send(worker, :drain)
    :sys.get_state(worker)
    # The moved entry remains discoverable through its old database prefix.
    assert Artifacts.get(ctx.db, artifact.artifact_id).home == old_home
    :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_archive_repoint")

    :sys.replace_state(worker, fn state ->
      %{
        state
        | relocation_failures:
            Map.new(state.relocation_failures, fn {entry, _} ->
              {entry, System.monotonic_time(:millisecond) - 1}
            end)
      }
    end)

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
    assert %{count: 1, reasons: [%{reason: reason}]} = WorkspaceCleanup.health(ctx.db)
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
    present = Path.join(ctx.workspace, "present")
    File.write!(present, "keep")
    kept = artifact(ctx, present)
    scratch = Path.join(ctx.workspace, "scratch")
    File.write!(scratch, "discard")
    retire(ctx)

    assert %{status: "completed", blockers: blockers} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    assert Enum.any?(blockers, &(&1.reason == "artifact_missing"))
    refute File.exists?(scratch)
    refute File.exists?(ctx.workspace)
    assert File.read!(Artifacts.get(ctx.db, kept.artifact_id).home) == "keep"

    assert %{count: 0, reasons: [%{completed: true, reason: "artifact_missing", count: 1}]} =
             WorkspaceCleanup.health(ctx.db)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT completed FROM retired_workspace_cleanup WHERE sessionKey=?1",
               [ctx.session.session_key]
             )
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

  test "an interrupted archive copy preserves originals and retries the copy", ctx do
    kept = Path.join(ctx.workspace, "kept")
    File.write!(kept, "preserve through a failed copy")
    artifact = artifact(ctx, kept)
    retire(ctx)
    attempts = :atomics.new(1, [])
    parent = self()

    runner = fn _invocation, script, input ->
      copy_script =
        String.replace(
          script,
          ~S|if [ ! -e "$target" ] && [ "$(device_id "$source")" = "$(device_id "$(dirname "$target")")" ]; then|,
          "if false; then"
        )

      prefix =
        if :atomics.add_get(attempts, 1, 1) == 1 do
          """
          cp() {
            # macOS sh can exec `command cp` here and skip the rest of this function.
            /bin/cp "$@" || return $?
            printf 'interrupting archive copy\\n'
            # Replace the background function with a process that really dies by signal.
            exec sh -c 'kill -TERM "$$"'
          }
          """
        else
          ""
        end

      result =
        WorkspaceCleanup.system_runner(["sh", "-c", prefix <> copy_script], copy_script, input)

      send(parent, {:copy_result, result})
      result
    end

    config = Map.put(ctx.config, :workspace_cleanup_runner, runner)

    assert %{status: "incomplete", blockers: blockers} =
             WorkspaceCleanup.process_session(config, ctx.db, ctx.session.session_key)

    assert Enum.any?(blockers, &(&1.reason == "archive_move_failed"))
    assert_receive {:copy_result, {output, status}}
    assert output =~ "interrupting archive copy"
    assert status != 0
    assert File.read!(kept) == "preserve through a failed copy"
    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "in-workspace"

    assert {:ok, [[destination]]} =
             DB.query(
               ctx.db,
               "SELECT archivePath FROM retired_workspace_cleanup WHERE sessionKey=?1",
               [ctx.session.session_key]
             )

    assert File.read!(Path.join(destination, "kept")) ==
             "preserve through a failed copy"

    assert %{status: "completed"} =
             WorkspaceCleanup.process_session(config, ctx.db, ctx.session.session_key)

    refute File.exists?(ctx.workspace)
    refute File.exists?(destination <> ".partial")

    assert File.read!(Artifacts.get(ctx.db, artifact.artifact_id).home) ==
             "preserve through a failed copy"
  end

  test "a timed out archive copy stops before another attempt can start", ctx do
    kept = Path.join(ctx.workspace, "kept")
    File.write!(kept, "preserve")
    artifact(ctx, kept)
    retire(ctx)
    pid_file = Path.join(ctx.base, "copy-pid")

    runner = fn _, script, input ->
      script =
        String.replace(
          script,
          ~S|if [ ! -e "$target" ] && [ "$(device_id "$source")" = "$(device_id "$(dirname "$target")")" ]; then|,
          "if false; then"
        )

      script =
        "cp() { sleep 30 & child=$!; echo $child > " <>
          pid_file <> "; trap 'kill $child; wait $child; exit 1' TERM; wait $child; }\n" <> script

      WorkspaceCleanup.system_runner(["sh", "-c", script], script, input)
    end

    config =
      ctx.config
      |> Map.put(:workspace_cleanup_runner, runner)
      |> Map.put(:workspace_cleanup_timeout_ms, 4_000)

    assert %{status: "incomplete", blockers: blockers} =
             WorkspaceCleanup.process_session(config, ctx.db, ctx.session.session_key)

    assert Enum.any?(blockers, &(&1.reason == "archive_move_failed"))
    pid = File.read!(pid_file) |> String.trim()
    assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
    assert File.read!(kept) == "preserve"
  end

  test "satellites keep their archive on their own host", ctx do
    Application.put_env(:tightbeam, :archive_dir, "/configured/archive")
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    assert WorkspaceCleanup.archive_root(%{ssh: nil, base_dir: ctx.base}) == "/configured/archive"

    assert WorkspaceCleanup.archive_root(%{ssh: "remote", base_dir: "/remote/base"}) ==
             "/remote/base/archive"
  end

  test "each drain relocates only one existing archive entry", ctx do
    source = Path.join(ctx.base, "archive")
    destination = Path.join(ctx.base, "destination")

    for entry <- ["first", "second"] do
      File.mkdir_p!(Path.join(source, entry))
      File.write!(Path.join([source, entry, "kept"]), entry)
    end

    Application.put_env(:tightbeam, :archive_dir, destination)
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    worker = start_supervised!({WorkspaceCleanup, config: ctx.config})
    send(worker, :drain)
    :sys.get_state(worker)
    assert File.ls!(source) == ["second"]
    assert File.read!(Path.join([destination, "first", "kept"])) == "first"
    send(worker, :drain)
    :sys.get_state(worker)
    assert File.ls!(source) == []
    assert File.read!(Path.join([destination, "second", "kept"])) == "second"
  end

  test "failed archive entries wait while later entries relocate, then retry when due", ctx do
    source = Path.join(ctx.base, "archive")
    destination = Path.join(ctx.base, "destination")
    File.mkdir_p!(source)
    # A file cannot be relocated as an archive directory.
    File.write!(Path.join(source, "first"), "blocked")
    File.mkdir_p!(Path.join(source, "second"))
    File.write!(Path.join([source, "second", "kept"]), "preserve")
    Application.put_env(:tightbeam, :archive_dir, destination)
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    worker = start_supervised!({WorkspaceCleanup, config: ctx.config})

    send(worker, :drain)
    state = :sys.get_state(worker)
    retry_at = Map.fetch!(state.relocation_failures, "first")
    assert retry_at > System.monotonic_time(:millisecond) + 290_000

    send(worker, :drain)
    :sys.get_state(worker)
    assert File.read!(Path.join([destination, "second", "kept"])) == "preserve"
    File.rm!(Path.join(source, "first"))
    File.mkdir_p!(Path.join(source, "first"))
    send(worker, :drain)
    state = :sys.get_state(worker)
    assert state.relocation_failures == %{"first" => retry_at}
    assert Process.read_timer(state.timer) > 290_000
    assert File.dir?(Path.join(source, "first"))

    :sys.replace_state(worker, fn state ->
      %{state | relocation_failures: %{"first" => System.monotonic_time(:millisecond) - 1}}
    end)

    send(worker, :drain)
    assert :sys.get_state(worker).relocation_failures == %{}
    refute File.exists?(Path.join(source, "first"))
    assert File.dir?(Path.join(destination, "first"))
  end

  test "a database exit during relocation leaves the worker alive", ctx do
    Application.put_env(:tightbeam, :archive_dir, Path.join(ctx.base, "destination"))
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    worker = start_supervised!({WorkspaceCleanup, config: ctx.config})
    :sys.replace_state(worker, &%{&1 | db: dead})
    send(worker, :drain)
    state = :sys.get_state(worker)
    assert Process.alive?(worker)
    assert Process.read_timer(state.timer) > 0
  end

  test "all missing artifacts leave no workspace or empty archive", ctx do
    artifact = artifact(ctx, Path.join(ctx.workspace, "nested/lost"))
    File.mkdir_p!(Path.join(ctx.workspace, "nested"))
    File.write!(Path.join(ctx.workspace, "scratch"), "discard")
    retire(ctx)

    assert %{status: "completed", blockers: [%{reason: "artifact_missing"}]} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    refute File.exists?(ctx.workspace)
    refute File.exists?(Path.join(ctx.base, "archive"))
    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "in-workspace"
  end

  test "an absent workspace finishes with missing artifact reasons", ctx do
    artifact(ctx, Path.join(ctx.workspace, "lost"))
    File.rm_rf!(ctx.workspace)
    retire(ctx)

    assert %{status: "completed", blockers: [%{reason: "artifact_missing"}]} =
             WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)

    assert %{count: 0, reasons: [%{completed: true, reason: "artifact_missing"}]} =
             WorkspaceCleanup.health(ctx.db)
  end

  test "removal reports store counts without paths", ctx do
    for n <- 1..1000, do: File.write!(Path.join(ctx.workspace, "scratch-#{n}"), "discard")
    retire(ctx)
    report = WorkspaceCleanup.process_session(ctx.config, ctx.db, ctx.session.session_key)
    assert report.status == "completed"
    assert report.removed_count == 1001

    {:ok, [[stored]]} =
      DB.query(ctx.db, "SELECT report FROM retired_workspace_cleanup WHERE sessionKey=?1", [
        ctx.session.session_key
      ])

    assert JSON.decode!(stored) == %{"removed_count" => 1001, "blockers" => []}

    {:ok, [[event]]} =
      DB.query(
        ctx.db,
        "SELECT detail FROM lifecycle_events WHERE kind='retired_workspace_cleanup_completed' AND subject=?1",
        [ctx.session.session_key]
      )

    assert JSON.decode!(event) == JSON.decode!(stored)
  end

  test "repeated failures grow the retry interval and doctor groups reasons", ctx do
    retire(ctx)
    config = Map.put(ctx.config, :workspace_cleanup_runner, fn _, _, _ -> {"offline", 255} end)
    WorkspaceCleanup.process_session(config, ctx.db, ctx.session.session_key)

    {:ok, [[first]]} =
      DB.query(ctx.db, "SELECT nextAt FROM retired_workspace_cleanup WHERE sessionKey=?1", [
        ctx.session.session_key
      ])

    WorkspaceCleanup.process_session(config, ctx.db, ctx.session.session_key)

    {:ok, [[second, attempts]]} =
      DB.query(
        ctx.db,
        "SELECT nextAt,attempts FROM retired_workspace_cleanup WHERE sessionKey=?1",
        [ctx.session.session_key]
      )

    assert attempts == 2
    assert second - first >= 300_000

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO retired_workspace_cleanup(sessionKey,reason) SELECT 'other',reason FROM retired_workspace_cleanup WHERE sessionKey=?1",
        [ctx.session.session_key]
      )

    assert %{count: 2, reasons: [%{count: 2, reason: reason}]} = WorkspaceCleanup.health(ctx.db)
    assert reason =~ "cleanup_command_failed"
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
