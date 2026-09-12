defmodule Tightbeam.RevocationMigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}

  @tag :tmp_dir
  test "guarded legacy revocation upgrade survives actual restart", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_revocation_restart.exs",
      "guarded-revocation-restart: ok"
    )
  end

  test "exact R1 legacy revocations preserve actors audit and reminder bytes atomically" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    sql = File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql"))

    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) ==
             "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"

    :ok = DB.execute(db, sql)

    :ok =
      DB.execute(db, """
      ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL;
      ALTER TABLE condition_facts ADD COLUMN payload TEXT NULL;
      UPDATE schema_stamp SET shape='row-driven-r1-v1-019';
      CREATE TABLE IF NOT EXISTS assignment_reopenings (
      id                   INTEGER PRIMARY KEY AUTOINCREMENT,
      assignmentId         TEXT    NOT NULL REFERENCES assignments(id),
      ts                   INTEGER NOT NULL,
      reopenedByUser       TEXT    NULL REFERENCES users(userId),
      reopenedBySession    TEXT    NULL REFERENCES sessions(sessionKey),
      reason               TEXT    NOT NULL
      CHECK(length(trim(reason)) BETWEEN 1 AND 2000),
      priorOutcome         TEXT    NOT NULL
      CHECK(priorOutcome IN ('completed', 'surrendered', 'revoked')),
      priorClosedAt        INTEGER NOT NULL,
      priorClosedByUser    TEXT    NULL,
      priorClosedBySession TEXT    NULL,
      priorClosingAttestId TEXT    NULL REFERENCES attests(id),
      CHECK((reopenedByUser IS NOT NULL) != (reopenedBySession IS NOT NULL))
      );
      CREATE INDEX IF NOT EXISTS assignment_reopenings_assignment
      ON assignment_reopenings (assignmentId, id);
      INSERT INTO users(userId,createdAt) VALUES ('owner',1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('holder','holder','owner','user:owner','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,outcome,closedAt,closedByUser,closedBySession,reminderState)
        VALUES ('initial','initial','holder','owner',1,'closed','revoked',700,'owner',NULL,NULL),
               ('reopened','reopened','holder','owner',1,'closed','revoked',700,NULL,'holder','{ "phase": "pending" }'),
               ('open','open','holder','owner',1,'open',NULL,NULL,NULL,NULL,'');
      INSERT INTO assignment_reopenings(assignmentId,ts,reopenedByUser,reason,priorOutcome,priorClosedAt,priorClosedByUser)
        VALUES ('reopened',700,'owner','again','revoked',700,'owner');
      """)

    columns =
      rows(db, "PRAGMA table_info(assignments)") |> Enum.map(&Enum.at(&1, 1)) |> Enum.join(",")

    audit_columns =
      rows(db, "PRAGMA table_info(assignment_reopenings)")
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.join(",")

    before = rows(db, "SELECT * FROM assignments ORDER BY id")
    audit = rows(db, "SELECT * FROM assignment_reopenings ORDER BY id")
    objects = rows(db, "SELECT type,name,sql FROM sqlite_schema ORDER BY type,name")

    assert_raise RuntimeError, ~r/forced activation interruption/, fn ->
      Schema.upgrade_firehose_r1(db, fail_after_statement: :before_firehose_stamp)
    end

    assert rows(db, "SELECT * FROM assignments ORDER BY id") == before
    assert rows(db, "SELECT * FROM assignment_reopenings ORDER BY id") == audit
    assert rows(db, "SELECT type,name,sql FROM sqlite_schema ORDER BY type,name") == objects
    assert :ok = Schema.upgrade_firehose_r1(db)
    assert rows(db, "SELECT #{columns} FROM assignments ORDER BY id") == before
    assert rows(db, "SELECT #{audit_columns} FROM assignment_reopenings ORDER BY id") == audit

    assert rows(db, "SELECT closedByProcess FROM assignments ORDER BY id") == [
             [nil],
             [nil],
             [nil]
           ]

    assert rows(db, "SELECT priorClosedByProcess FROM assignment_reopenings") == [[nil]]

    assert {:error, %DB.Error{}} =
             DB.query(db, "UPDATE assignment_reopenings SET priorClosedByProcess='other'")

    assert rows(db, "SELECT priorClosedByProcess FROM assignment_reopenings") == [[nil]]

    assert {:ok, []} =
             DB.query(db, "UPDATE assignment_reopenings SET priorClosedByProcess=NULL")

    assert rows(db, "SELECT #{audit_columns} FROM assignment_reopenings ORDER BY id") == audit

    assert rows(db, """
           SELECT r.assignmentId,r.revokedAt,r.revokedByUser,r.revokedBySession,r.reason,g.reopeningId
           FROM assignment_revocations r JOIN assignment_revocation_generations g ON g.revocationId=r.id
           ORDER BY r.assignmentId
           """) == [
             ["initial", 700, "owner", nil, "legacy_unknown", nil],
             ["reopened", 700, nil, "holder", "legacy_unknown", 1]
           ]

    assert {:error, %DB.Error{}} =
             DB.query(db, "UPDATE assignments SET closedAt=701 WHERE id='initial'")

    assert {:error, %DB.Error{}} =
             DB.query(db, "UPDATE assignment_revocations SET reason='invented'")

    assert :ok = Schema.upgrade_firehose_r1(db)
    assert rows(db, "SELECT count(*) FROM assignment_revocations") == [[2]]
    assert rows(db, "SELECT shape FROM schema_stamp") == [["session-reparent-v1-019"]]
    assert rows(db, "PRAGMA foreign_key_check") == []
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
  end

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
