defmodule Tightbeam.ArtifactOriginsTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{ArtifactOrigins, Artifacts, DB, Org, Placement, Schema}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: :artifact_origins_test})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,createdAt,updatedAt)
      VALUES ('origin-owner','origin','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model','host-a',1,1);
      INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt)
      VALUES ('origin-work','Origin','fixture','fixture',1);
      """)

    for host <- ["host-a", "host-b"] do
      {:ok, _} =
        Placement.register_host(db, host, %{ssh: host <> ".invalid", base_dir: "/same/base"})
    end

    %{db: db}
  end

  test "identical named paths retain their registration host across an A to B move", %{db: db} do
    original = record(db, "/same/base/report.md")
    relative = record(db, "reports/result.md")
    workspace = Placement.host_workdir_path(%{base_dir: "/same/base"}, "origin-owner")
    Org.set_host(db, "origin-owner", "host-b")
    moved = record(db, "/same/base/report.md")
    assert original.origin_path == moved.origin_path

    assert ArtifactOrigins.resolve(Artifacts.get(db, original.artifact_id)) ==
             {:ok, "host-a", "/same/base/report.md"}

    assert ArtifactOrigins.resolve(moved) == {:ok, "host-b", "/same/base/report.md"}
    assert relative.origin_workspace == workspace

    assert ArtifactOrigins.resolve(Artifacts.get(db, relative.artifact_id)) ==
             {:ok, "host-a", Path.join(workspace, "reports/result.md")}

    assert original.origin_workspace == nil
  end

  test "base directory changes do not rebind prior relative registrations", %{db: db} do
    original = record(db, "report.md")

    {:ok, _} =
      Placement.register_host(db, "host-a", %{ssh: "host-a.invalid", base_dir: "/new/base"})

    newer = record(db, "report.md")
    refute original.origin_workspace == newer.origin_workspace
    assert Artifacts.get(db, original.artifact_id).origin_workspace == original.origin_workspace

    assert ArtifactOrigins.resolve(original) ==
             {:ok, "host-a", Path.join(original.origin_workspace, "report.md")}

    assert ArtifactOrigins.resolve(newer) ==
             {:ok, "host-a", Path.join(newer.origin_workspace, "report.md")}
  end

  test "qualified cross-session references use their named host and preserve the literal path", %{
    db: db
  } do
    origin = "host-b:/same/base/work/other-session/_build"
    row = record(db, origin)
    assert row.origin_path == origin
    assert row.origin_host == "host-b"
    assert row.origin_workspace == nil
    assert ArtifactOrigins.resolve(row) == {:ok, "host-b", "/same/base/work/other-session/_build"}
    assert record(db, "/another/session/report.md").origin_workspace == nil
  end

  test "registration without an authoritative resolution workspace retains unknown context", %{
    db: db
  } do
    Org.set_host(db, "origin-owner", "unconfigured")
    row = record(db, "report.md")
    assert row.origin_workspace == nil
    assert ArtifactOrigins.resolve(row) == {:error, :unknown_origin}
    assert ArtifactOrigins.resolve(record(db, "service:ambiguous")) == {:error, :unknown_origin}
  end

  test "recognized references stay distinct from colon-bearing filesystem and unknown origins", %{
    db: db
  } do
    for origin <- [
          "https://example.invalid/reports/1",
          "http://example.invalid/a",
          "tightbeam-transcript:session:fixture"
        ] do
      row = record(db, origin)
      assert row.origin_path == origin
      assert row.origin_host == nil
      assert ArtifactOrigins.possible_location(row) == :non_filesystem
    end

    assert ArtifactOrigins.parse("host-a:/reports/result") ==
             {:qualified, "host-a", "/reports/result"}

    assert ArtifactOrigins.parse("tightbeam-transcript:/a-file") ==
             {:qualified, "tightbeam-transcript", "/a-file"}

    assert ArtifactOrigins.possible_location(record(db, "arbitrary:unknown")) ==
             {:error, :unknown_origin}
  end

  test "registered context is immutable and is not caller-selected params", %{db: db} do
    row = record(db, "report.md", %{origin_host: "spoof", origin_workspace: "/spoof"})
    assert row.origin_host == "host-a"

    assert {:error, _} =
             DB.query(db, "UPDATE artifacts SET originHost='host-b' WHERE artifactId=?1", [
               row.artifact_id
             ])

    assert {:error, _} =
             DB.query(db, "UPDATE artifacts SET originWorkspace='/other' WHERE artifactId=?1", [
               row.artifact_id
             ])

    assert Artifacts.get(db, row.artifact_id) == row
  end

  test "concurrent placement writes and records never mix host and workspace context", %{db: db} do
    {:ok, _} =
      Placement.register_host(db, "host-b", %{ssh: "host-b.invalid", base_dir: "/host-b-base"})

    tasks =
      for _ <- 1..12 do
        Task.async(fn ->
          mover = Task.async(fn -> Org.set_host(db, "origin-owner", "host-b") end)
          row = record(db, "report.md")
          Task.await(mover)
          Org.set_host(db, "origin-owner", "host-a")
          row
        end)
      end

    for row <- Enum.map(tasks, &Task.await/1) do
      base = if row.origin_host == "host-a", do: "/same/base", else: "/host-b-base"
      assert row.origin_host in ["host-a", "host-b"]

      assert row.origin_workspace ==
               Placement.host_workdir_path(%{base_dir: base}, "origin-owner")
    end
  end

  test "exact predecessor upgrade leaves legacy origins unknown and preserves every named byte of the row",
       %{db: db} do
    row = record(db, "/same/base/report.md")
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_assignment_source_replacement_cancellation!(db)

    :ok =
      DB.execute(db, """
      DROP TRIGGER artifacts_origin_immutable;
      ALTER TABLE artifacts DROP COLUMN originHost;
      ALTER TABLE artifacts DROP COLUMN originWorkspace;
      ALTER TABLE work_items DROP COLUMN deliveryOwnerSessionKey;
      ALTER TABLE identity_publication_markers DROP COLUMN denialDiagnostic;
      UPDATE schema_stamp SET shape='delivery-owner-reparent-v1-019';
      """)

    assert :ok = Schema.ensure_all(db)
    migrated = Artifacts.get(db, row.artifact_id)
    assert migrated.origin_host == nil
    assert migrated.origin_workspace == nil

    assert Map.drop(migrated, [:origin_host, :origin_workspace]) ==
             Map.drop(row, [:origin_host, :origin_workspace])

    assert ArtifactOrigins.resolve(migrated) == {:error, :unknown_origin}
    assert :ok = Schema.ensure_all(db)
    assert Artifacts.get(db, row.artifact_id) == migrated

    assert {:ok, [["assignment-source-replacement-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")
  end

  test "migration stamp failure rolls the provenance columns back", %{db: db} do
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_assignment_source_replacement_cancellation!(db)

    :ok =
      DB.execute(db, """
      DROP TRIGGER artifacts_origin_immutable;
      ALTER TABLE artifacts DROP COLUMN originHost;
      ALTER TABLE artifacts DROP COLUMN originWorkspace;
      ALTER TABLE work_items DROP COLUMN deliveryOwnerSessionKey;
      UPDATE schema_stamp SET shape='delivery-owner-reparent-v1-019';
      CREATE TRIGGER reject_origin_stamp BEFORE UPDATE ON schema_stamp
      WHEN NEW.shape='artifact-origin-v1-019'
      BEGIN SELECT RAISE(ABORT,'synthetic stamp failure'); END;
      """)

    assert_raise Tightbeam.DB.Error, fn -> Schema.ensure_all(db) end

    assert {:ok, [["delivery-owner-reparent-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(artifacts)")
    refute Enum.any?(columns, &(Enum.at(&1, 1) in ["originHost", "originWorkspace"]))
  end

  defp record(db, path, extra \\ %{}) do
    Artifacts.record(db, %{
      principal: {:session, "origin-owner"},
      session_key: "origin-owner",
      artifact_base_dir: "/synthetic/gateway",
      params:
        Map.merge(extra, %{
          kind: "data",
          title: "Origin",
          origin_path: path,
          work_item_id: "origin-work"
        })
    })
  end
end
