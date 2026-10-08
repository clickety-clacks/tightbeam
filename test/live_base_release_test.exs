defmodule Tightbeam.LiveBaseReleaseTest do
  use Tightbeam.TestCase, async: false

  alias Exqlite.Sqlite3
  alias Tightbeam.{DB, LiveBaseAdmission, LiveBaseGuard, LiveBaseRelease, Schema}
  import ExUnit.CaptureLog

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(File.cwd!(), ".tmp-live-base-release-#{suffix}")
    base = Path.join(File.cwd!(), ".tmp-live-base-release-base-#{suffix}")
    app = Path.join(root, "release/lib/tightbeam-0.1.9")
    File.mkdir_p!(Path.join(app, "ebin"))
    File.mkdir_p!(Path.join(app, "priv"))
    File.write!(Path.join(app, "ebin/fixture.beam"), "fixture beam")
    File.write!(Path.join(app, "priv/fixture.rule"), "fixture rule")
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "package.json"), ~s({"name":"tightbeam"}))
    File.write!(Path.join(root, "bin/tightbeam"), "fixture")
    File.write!(Path.join(root, "bin/tightbeam-gateway"), "fixture")
    File.write!(Path.join(root, "release/README"), "fixture")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(base)
    end)

    %{root: root, app: app, base: base}
  end

  test "a released package derives the exact unmarked transition without operator input", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))

    File.mkdir_p!(base)
    {:ok, conn} = Sqlite3.open(Path.join(base, "state.db"))

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{Schema.live_base_upgrade_predecessor()}');"
      )

    :ok = Sqlite3.close(conn)

    admission = LiveBaseAdmission.prepare!(base, payload_root: app)
    assert admission.marker == :absent
    assert admission.decision.source == "unmarked"
    assert admission.decision.expected_schema == Schema.live_base_upgrade_predecessor()

    {:ok, db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    predecessor = Schema.live_base_upgrade_predecessor()

    assert {:ok, [[^predecessor]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    :ok = GenServer.stop(db)
  end

  test "a released package upgrades a real predecessor, marks it, and restarts marked", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_real_predecessor!(base, app)
    identity = manifest["buildIdentity"]

    refute File.exists?(Path.join(base, "build-owner.json"))

    {:ok, db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    :ok = Schema.ensure_all(db)
    target = hd(Schema.guard_compatible_stamps())
    assert {:ok, [[^target]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    assert %{
             "format" => "tightbeam-build-owner/v1",
             "buildIdentity" => ^identity
           } = JSON.decode!(File.read!(Path.join(base, "build-owner.json")))

    :ok = GenServer.stop(db)

    {:ok, restarted} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    assert :ok = Schema.ensure_all(restarted)
    assert {:ok, [[^target]]} = DB.query(restarted, "SELECT shape FROM schema_stamp")
    assert File.exists?(Path.join(base, "build-owner.json"))
    :ok = GenServer.stop(restarted)
  end

  test "a released package automatically upgrades an earlier marked build", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_real_predecessor!(base, app)

    {:ok, previous_db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    :ok = Schema.ensure_all(previous_db)
    :ok = GenServer.stop(previous_db)

    previous_identity = String.duplicate("b", 64)
    previous_marker = owner_marker(previous_identity)
    marker_path = Path.join(base, "build-owner.json")
    File.write!(marker_path, JSON.encode!(previous_marker))

    admission = LiveBaseAdmission.prepare!(base, payload_root: app)
    assert admission.marker == previous_marker
    assert admission.decision.source == previous_identity
    assert admission.decision.target == manifest["buildIdentity"]
    assert admission.decision.expected_schema == nil
    assert File.read!(marker_path) == JSON.encode!(previous_marker)

    {:ok, db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    :ok = Schema.ensure_all(db)
    target = hd(Schema.guard_compatible_stamps())
    assert {:ok, [[^target]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    assert JSON.decode!(File.read!(marker_path)) == owner_marker(manifest["buildIdentity"])
    :ok = GenServer.stop(db)
  end

  test "a released package refuses a marked build with an unknown schema without rewriting it", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_schema!(base, "unknown-schema-shape")

    previous_marker = owner_marker(String.duplicate("b", 64))
    marker_path = Path.join(base, "build-owner.json")
    File.write!(marker_path, JSON.encode!(previous_marker))
    before = File.read!(Path.join(base, "state.db"))

    assert_raise LiveBaseAdmission.Refusal, ~r/build_transition_required/, fn ->
      LiveBaseAdmission.prepare!(base, payload_root: app)
    end

    assert File.read!(Path.join(base, "state.db")) == before
    assert File.read!(marker_path) == JSON.encode!(previous_marker)
  end

  test "a failed released migration leaves the predecessor and no marker", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_real_predecessor!(base, app)
    install_migration_failure_trigger!(base)

    {:ok, db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    assert_raise Schema.ShapeError, ~r/migration .* failed: .*synthetic migration failure/, fn ->
      Schema.ensure_all(db)
    end

    predecessor = Schema.live_base_upgrade_predecessor()
    assert {:ok, [[^predecessor]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")
    assert :ok = DB.execute(db, "CREATE TEMP TABLE check_probe(n INTEGER CHECK(n > 0))")
    assert {:error, reason} = DB.execute(db, "INSERT INTO check_probe VALUES(-1)")
    assert reason =~ "CHECK constraint failed"
    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(decision_requests)")
    refute Enum.any?(columns, fn [_, name | _] -> name == "ruledViaPrincipal" end)
    refute File.exists?(Path.join(base, "build-owner.json"))
    :ok = GenServer.stop(db)
  end

  test "a failed automatic marked-build migration preserves the previous marker", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_real_predecessor!(base, app)

    previous_marker = owner_marker(String.duplicate("b", 64))
    marker_path = Path.join(base, "build-owner.json")
    previous_bytes = JSON.encode!(previous_marker)
    File.write!(marker_path, previous_bytes)
    install_migration_failure_trigger!(base)

    {:ok, db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    assert_raise Schema.ShapeError, ~r/migration .* failed: .*synthetic migration failure/, fn ->
      Schema.ensure_all(db)
    end

    predecessor = Schema.live_base_upgrade_predecessor()
    assert {:ok, [[^predecessor]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert File.read!(marker_path) == previous_bytes
    :ok = GenServer.stop(db)
  end

  test "a failed lifecycle index build rolls back its indexes and cannot stamp a successful boot",
       %{
         root: root,
         app: app,
         base: base
       } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_real_predecessor!(base, app)
    {:ok, conn} = Sqlite3.open(Path.join(base, "state.db"))

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE lifecycle_events_idle_cleanup_kind_id(x);
      INSERT INTO lifecycle_events(ts,kind,subject,detail) VALUES(0,'synthetic','preserved','raw history');
      """)

    :ok = Sqlite3.close(conn)

    {:ok, db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    capture_log(fn ->
      assert_raise Schema.ShapeError, ~r/lifecycle runtime index migration failed/, fn ->
        Schema.ensure_all(db)
      end
    end)

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='lifecycle_events'"
             )

    assert {:ok, [["raw history"]]} =
             DB.query(db, "SELECT detail FROM lifecycle_events WHERE subject='preserved'")

    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    refute File.exists?(Path.join(base, "build-owner.json"))
    :ok = GenServer.stop(db)
  end

  @tag timeout: 600_000
  test "a large guarded predecessor migration preserves rows and restarts marked",
       %{
         root: root,
         app: app,
         base: base
       } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_real_predecessor!(base, app)
    seed_migration_population!(base)
    # The captured predecessor has no lifecycle indexes. Prove upgrade builds
    # them over populated history, rather than seeding already-indexed rows.
    {:ok, before_upgrade} = Sqlite3.open(Path.join(base, "state.db"))
    {:ok, index_query} = Sqlite3.prepare(before_upgrade, "PRAGMA index_list(lifecycle_events)")
    {:ok, []} = Sqlite3.fetch_all(before_upgrade, index_query)
    :ok = Sqlite3.release(before_upgrade, index_query)
    :ok = Sqlite3.close(before_upgrade)
    refute File.exists?(Path.join(base, "build-owner.json"))

    {:ok, db} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    log =
      capture_log(fn ->
        {elapsed, :ok} = :timer.tc(fn -> Schema.ensure_all(db) end)

        IO.puts(
          "M6 guarded migration: elapsed_us=#{elapsed} decisions=20000 lifecycle_events=150000"
        )
      end)

    # The census must be allowed to become faster. Unbounded migration waits
    # are proved independently in DBCallTimeoutTest; this populated fixture
    # retains the guarded upgrade, integrity and restart assertions.
    assert log =~ "migration call migration_transaction: finished elapsed_ms="
    assert log =~ "terminal census begin"
    assert log =~ "stamp begin"
    assert log =~ "runtime checks restored"
    assert log =~ "database migration lifecycle_runtime_indexes: committed"
    assert log =~ "lifecycle index lifecycle_events_subject_kind: finished elapsed_ms="
    assert log =~ "lifecycle index lifecycle_events_idle_cleanup_kind_id: finished elapsed_ms="
    IO.puts(log)

    target = hd(Schema.guard_compatible_stamps())
    assert {:ok, [[^target]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, [[20_000, 200_010_000]]} =
             DB.query(
               db,
               "SELECT COUNT(*), SUM(raisedAt) FROM decision_requests WHERE id LIKE 'm6-%'"
             )

    assert {:ok, [[150_000]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind = 'synthetic_m6_history'"
             )

    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    assert {:ok, [[5000]]} = DB.query(db, "PRAGMA busy_timeout")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")

    assert {:error, _} =
             DB.execute(db, "UPDATE decision_requests SET status = 'invalid' WHERE id = 'm6-1'")

    :ok = Tightbeam.LifecycleRuntimeFixture.seed!(db)
    :ok = Tightbeam.LifecycleRuntimeFixture.assert_plans_and_results!(db)

    {:ok, indexes_before_restart} =
      DB.query(
        db,
        "SELECT name,rootpage FROM sqlite_master WHERE type='index' AND tbl_name='lifecycle_events' ORDER BY name"
      )

    marker = File.read!(Path.join(base, "build-owner.json"))
    assert JSON.decode!(marker)["buildIdentity"] == manifest["buildIdentity"]
    :ok = GenServer.stop(db)

    {:ok, restarted} =
      DB.start_link(
        path: Path.join(base, "state.db"),
        name: nil,
        guard_inputs: [],
        payload_root: app
      )

    assert :ok = Schema.ensure_all(restarted)
    assert {:ok, [[^target]]} = DB.query(restarted, "SELECT shape FROM schema_stamp")
    assert File.read!(Path.join(base, "build-owner.json")) == marker

    assert DB.query(
             restarted,
             "SELECT name,rootpage FROM sqlite_master WHERE type='index' AND tbl_name='lifecycle_events' ORDER BY name"
           ) ==
             {:ok, indexes_before_restart}

    :ok = GenServer.stop(restarted)
  end

  test "a valid explicit transition remains authoritative for a released package", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_predecessor!(base)

    transition =
      JSON.encode!(%{
        "base" => LiveBaseAdmission.canonical!(base),
        "expectedSchema" => Schema.live_base_upgrade_predecessor(),
        "source" => "unmarked",
        "target" => manifest["buildIdentity"]
      })

    admission = LiveBaseAdmission.prepare!(base, payload_root: app, transition: transition)

    assert admission.marker == :absent
    assert admission.decision.source == "unmarked"
    assert admission.decision.target == manifest["buildIdentity"]
    assert admission.decision.expected_schema == Schema.live_base_upgrade_predecessor()
  end

  test "invalid explicit input never falls back to automatic release admission", %{
    root: root,
    app: app,
    base: base
  } do
    write_provenance!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))
    seed_predecessor!(base)
    before = File.read!(Path.join(base, "state.db"))

    assert_raise LiveBaseAdmission.Refusal, ~r/invalid_build_transition/, fn ->
      LiveBaseAdmission.prepare!(base, payload_root: app, transition: "{")
    end

    mismatched =
      JSON.encode!(%{
        "base" => LiveBaseAdmission.canonical!(base),
        "expectedSchema" => Schema.live_base_upgrade_predecessor(),
        "source" => "unmarked",
        "target" => String.duplicate("f", 64)
      })

    assert_raise LiveBaseAdmission.Refusal, ~r/build_transition_mismatch/, fn ->
      LiveBaseAdmission.prepare!(base, payload_root: app, transition: mismatched)
    end

    assert File.read!(Path.join(base, "state.db")) == before
    refute File.exists?(Path.join(base, "build-owner.json"))
  end

  test "tagged provenance authorizes only the exact supported predecessor", %{
    root: root,
    app: app
  } do
    write_provenance!(root)

    assert {:ok, transition} =
             LiveBaseRelease.automatic_transition(
               app,
               "/tmp/live-base-release-test",
               String.duplicate("b", 64),
               [[Schema.live_base_upgrade_predecessor()]]
             )

    assert transition == %{
             "base" => "/tmp/live-base-release-test",
             "expectedSchema" => Schema.live_base_upgrade_predecessor(),
             "source" => "unmarked",
             "target" => String.duplicate("b", 64)
           }
  end

  test "missing provenance leaves ordinary explicit-transition refusal intact", %{app: app} do
    assert :none ==
             LiveBaseRelease.automatic_transition(
               app,
               "/tmp/live-base-release-test",
               String.duplicate("b", 64),
               [[Schema.live_base_upgrade_predecessor()]]
             )
  end

  test "a work-branch package refuses an unmarked base without changing it", %{
    root: root,
    app: app,
    base: base
  } do
    {:ok, manifest} = LiveBaseGuard.generate_manifest(LiveBaseAdmission.payload_files!(app))
    File.write!(Path.join(app, "build-manifest.json"), JSON.encode!(manifest))

    File.mkdir_p!(base)
    path = Path.join(base, "state.db")
    {:ok, conn} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{Schema.live_base_upgrade_predecessor()}');"
      )

    :ok = Sqlite3.close(conn)
    before = File.read!(path)

    assert_raise LiveBaseAdmission.Refusal, ~r/build_transition_required/, fn ->
      LiveBaseAdmission.prepare!(base, payload_root: app)
    end

    assert File.read!(path) == before
    refute File.exists?(Path.join(base, "build-owner.json"))
  end

  test "malformed provenance refuses rather than guessing", %{root: root, app: app} do
    File.write!(Path.join(root, "release-provenance.json"), "{}")

    assert_raise LiveBaseRelease.Refusal, ~r/release provenance refused/, fn ->
      LiveBaseRelease.automatic_transition(
        app,
        "/tmp/live-base-release-test",
        String.duplicate("b", 64),
        [[Schema.live_base_upgrade_predecessor()]]
      )
    end
  end

  test "automatic transition leaves a non-supported stamp to ordinary refusal", %{
    root: root,
    app: app
  } do
    write_provenance!(root)

    assert :none ==
             LiveBaseRelease.automatic_transition(
               app,
               "/tmp/live-base-release-test",
               String.duplicate("b", 64),
               [[hd(Schema.guard_compatible_stamps())]]
             )
  end

  defp write_provenance!(root) do
    File.write!(
      Path.join(root, "release-provenance.json"),
      JSON.encode!(%{
        "commit" => String.duplicate("a", 40),
        "format" => "tightbeam-release-provenance/v1",
        "repository" => "clickety-clacks/tightbeam",
        "tag" => "v0.1.9+1337"
      })
    )
  end

  defp seed_real_predecessor!(base, app) do
    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(
      Path.join(base, "state.db"),
      app
    )
  end

  defp seed_schema!(base, stamp) do
    File.mkdir_p!(base)
    {:ok, conn} = Sqlite3.open(Path.join(base, "state.db"))
    :ok = Sqlite3.execute(conn, "CREATE TABLE schema_stamp(shape TEXT);")
    :ok = Sqlite3.execute(conn, "INSERT INTO schema_stamp VALUES ('#{stamp}')")
    :ok = Sqlite3.close(conn)
  end

  defp owner_marker(identity) do
    %{"format" => "tightbeam-build-owner/v1", "buildIdentity" => identity}
  end

  defp seed_migration_population!(base) do
    {:ok, conn} = Sqlite3.open(Path.join(base, "state.db"))

    :ok =
      Sqlite3.execute(conn, """
      BEGIN;
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20000)
      INSERT INTO decision_requests
        (id, kind, raiserId, raiserSessionKey, ownerUserId, raisedAt, deadlineAt,
         actionKey, question, options, context, status, decision, ruledBy, ruledAt, rulingFactId)
      SELECT 'm6-'||x, 'operator', 'session:synthetic', 'synthetic', 'synthetic', x, x+1,
        'synthetic-m6', 'synthetic migration fixture', '["accept","reject"]', '{}',
        'ruled', 'accept', 'user:synthetic', x, 1 FROM n;
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<150000)
      INSERT INTO lifecycle_events(ts, kind, subject, detail)
        SELECT x, 'synthetic_m6_history', 'synthetic-'||x, 'synthetic historical event' FROM n;
      COMMIT;
      """)

    :ok = Sqlite3.close(conn)
  end

  defp install_migration_failure_trigger!(base) do
    path = Path.join(base, "state.db")
    {:ok, conn} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TRIGGER synthetic_live_base_migration_failure
      BEFORE UPDATE OF shape ON schema_stamp
      BEGIN
        SELECT RAISE(ABORT, 'synthetic migration failure');
      END;
      """)

    :ok = Sqlite3.close(conn)
  end

  defp seed_predecessor!(base) do
    File.mkdir_p!(base)
    {:ok, conn} = Sqlite3.open(Path.join(base, "state.db"))

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{Schema.live_base_upgrade_predecessor()}');"
      )

    :ok = Sqlite3.close(conn)
  end
end
