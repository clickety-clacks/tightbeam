defmodule Tightbeam.FirehoseR1SchemaTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}
  @fixture Path.expand("fixtures/r1_o2_v1.sql", __DIR__)
  @fixture_sha "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"
  setup do
    %{db: start_supervised!({DB, path: ":memory:", name: nil})}
  end

  test "administrative backfill waits for prerequisites and preserves existing floors", %{db: db} do
    alias Tightbeam.AdminProjection
    assert :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO org_settings VALUES('synthetic-setting','literal',11);
      INSERT INTO hosts(name,baseDir) VALUES('synthetic-host','/synthetic-only');
      INSERT INTO users(userId,isAdmin,createdAt) VALUES('synthetic-user',0,12);
      INSERT INTO harness_env_overlays VALUES('synthetic-host','fixture','SYNTHETIC_KEY','synthetic-value','fixture',13);
      INSERT INTO admin_projection_versions(resource,primaryKey,rowVersion,updatedAt) VALUES('config','synthetic-setting',9,7);
      """)

    assert :ok = AdminProjection.ensure_schema(db)

    assert rows(
             db,
             "SELECT rowVersion,updatedAt FROM admin_projection_versions WHERE resource='config' AND primaryKey='synthetic-setting'"
           ) == [[9, 7]]

    assert rows(
             db,
             "SELECT rowVersion,updatedAt FROM admin_projection_versions WHERE resource='users' AND primaryKey='synthetic-user'"
           ) == [[1, 12]]

    assert rows(db, "SELECT valuePresent,updatedAt,rowVersion FROM host_environment_projection") ==
             [[1, 13, 1]]

    assert rows(
             db,
             "SELECT rowVersion FROM admin_projection_versions WHERE resource='hosts' AND primaryKey='synthetic-host'"
           ) == [[1]]

    floors = rows(db, "SELECT * FROM admin_projection_versions ORDER BY resource,primaryKey")
    overlays = rows(db, "SELECT * FROM host_environment_projection")
    assert :ok = Schema.ensure_all(db)

    assert rows(db, "SELECT * FROM admin_projection_versions ORDER BY resource,primaryKey") ==
             floors

    assert rows(db, "SELECT * FROM host_environment_projection") == overlays
    assert rows(db, "SELECT value FROM harness_env_overlays") == [["synthetic-value"]]
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "fresh bootstrap and restart use one composed shape without duplicate columns", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT shape FROM schema_stamp") == [["firehose-r1-v1-019"]]

    for {table, column} <- [
          {"assignments", "reminderState"},
          {"assignments", "closedByProcess"},
          {"condition_facts", "payload"},
          {"sessions", "mechanicalStatus"},
          {"decision_requests", "rowVersion"}
        ] do
      assert Enum.count(rows(db, "PRAGMA table_info(#{table})"), &(Enum.at(&1, 1) == column)) == 1
    end

    before = objects(db)
    assert :ok = Schema.ensure_all(db)
    assert objects(db) == before
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "exact R1 upgrade retains bytes, old close provenance and floors with atomic successor", %{
    db: db
  } do
    load_r1(db)
    before = retained(db)
    assert :ok = Schema.upgrade_firehose_r1(db)
    assert retained(db) == before
    assert rows(db, "SELECT shape FROM schema_stamp") == [["firehose-r1-v1-019"]]

    assert rows(db, "SELECT reminderState,closedByProcess FROM assignments ORDER BY id") ==
             [[nil, nil], ["{ \"version\": 1, \"unicode\": \"λ\" }", nil]]

    assert rows(db, "SELECT reason,revokedAt,revokedByUser FROM assignment_revocations") ==
             [["legacy_unknown", 2, "fixture"]]

    assert rows(db, "SELECT artifactId,rowVersion FROM artifact_version_floors") == [
             ["artifact", 2]
           ]

    assert rows(db, "SELECT mechanicalStatus FROM sessions") == [["running"]]
    assert rows(db, "SELECT updatedAt FROM sessions") |> hd() |> hd() |> Kernel.>(1)
    assert rows(db, "PRAGMA foreign_key_check") == []
    assert :ok = Schema.ensure_all(db)
    assert retained(db) == before
  end

  test "failure before final stamp rolls back whole suffix and restores connection pragmas", %{
    db: db
  } do
    load_r1(db)

    before =
      {objects(db), retained(db), rows(db, "SELECT * FROM schema_stamp"),
       rows(db, "SELECT * FROM sessions")}

    assert_raise RuntimeError, "forced activation interruption", fn ->
      Schema.upgrade_firehose_r1(db, fail_after_statement: :before_firehose_stamp)
    end

    assert {objects(db), retained(db), rows(db, "SELECT * FROM schema_stamp"),
            rows(db, "SELECT * FROM sessions")} == before

    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA legacy_alter_table") == [[0]]
    assert rows(db, "PRAGMA ignore_check_constraints") == [[0]]
    assert :ok = Schema.upgrade_firehose_r1(db)
  end

  test "unknown stamp and missing R1 column refuse without retaining partial suffix", %{db: db} do
    load_r1(db)
    :ok = DB.execute(db, "UPDATE schema_stamp SET shape='unknown-firehose-predecessor'")
    before = {objects(db), retained(db), rows(db, "SELECT * FROM schema_stamp")}
    assert_raise Schema.ShapeError, fn -> Schema.upgrade_firehose_r1(db) end
    assert {objects(db), retained(db), rows(db, "SELECT * FROM schema_stamp")} == before

    :ok = DB.execute(db, "UPDATE schema_stamp SET shape='row-driven-r1-v1-019'")
    :ok = DB.execute(db, "ALTER TABLE assignments DROP COLUMN reminderState")

    before =
      {objects(db), rows(db, "SELECT * FROM assignments"), rows(db, "SELECT * FROM sessions"),
       rows(db, "SELECT * FROM schema_stamp"), rows(db, "SELECT * FROM condition_facts")}

    assert_raise MatchError, fn -> Schema.upgrade_firehose_r1(db) end

    assert {objects(db), rows(db, "SELECT * FROM assignments"),
            rows(db, "SELECT * FROM sessions"), rows(db, "SELECT * FROM schema_stamp"),
            rows(db, "SELECT * FROM condition_facts")} == before

    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA legacy_alter_table") == [[0]]
    assert rows(db, "PRAGMA ignore_check_constraints") == [[0]]
  end

  defp load_r1(db) do
    sql = File.read!(@fixture)
    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) == @fixture_sha
    :ok = DB.execute(db, sql)
    # The exact two additive R1 statements on the preserved O2 fixture.
    # This is not a successor schema relabeled as its own predecessor.
    :ok =
      DB.execute(db, """
      ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL;
      ALTER TABLE condition_facts ADD COLUMN payload TEXT NULL;
      UPDATE schema_stamp SET shape='row-driven-r1-v1-019';
      INSERT INTO users(userId,createdAt) VALUES ('fixture',1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('fixture-session','fixture','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('a','null','fixture-session','fixture',1,NULL),
               ('b','raw','fixture-session','fixture',1,'{ "version": 1, "unicode": "λ" }');
      UPDATE assignments SET state='closed',outcome='revoked',closedAt=2,closedByUser='fixture' WHERE id='b';
      INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES ('work','work','fixture','fixture',1);
      INSERT INTO artifacts(artifactId,kind,title,createdBySession,workItemId,originPath,createdAt,updatedAt)
        VALUES ('artifact','other','synthetic','fixture-session','work','synthetic-only',1,1);
      INSERT INTO condition_facts(ts,kind,scope,origin,ownerUserId,payload)
        VALUES (1,'synthetic','a','user:fixture','fixture',NULL),
               (2,'synthetic','b','user:fixture','fixture','{"version":1}');
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt)
        VALUES ('fixture-session','message','user:fixture','synthetic','queued',1);
      """)
  end

  defp retained(db) do
    {rows(
       db,
       "SELECT id,subject,holderKey,state,outcome,closedAt,closedByUser,closedBySession,reminderState FROM assignments ORDER BY id"
     ), rows(db, "SELECT * FROM condition_facts ORDER BY id"),
     rows(db, "SELECT * FROM artifacts ORDER BY artifactId"),
     rows(db, "SELECT * FROM decision_request_terminal_epoch"),
     rows(db, "SELECT * FROM turns ORDER BY seq")}
  end

  defp objects(db),
    do:
      rows(db, "SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type,name")

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
