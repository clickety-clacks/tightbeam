defmodule Tightbeam.LiveBaseReleaseTest do
  use Tightbeam.TestCase, async: false

  alias Exqlite.Sqlite3
  alias Tightbeam.{DB, LiveBaseAdmission, LiveBaseGuard, LiveBaseRelease, Schema}

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
