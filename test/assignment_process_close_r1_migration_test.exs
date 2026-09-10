defmodule Tightbeam.AssignmentProcessCloseR1MigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{Assignments, DB, Schema}

  setup do
    db = start_supervised!({DB, name: :process_close_r1_db, path: ":memory:"})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "upgrade preserves raw reminder bytes, references and attached objects", %{db: db} do
    seed(db)
    before = snapshot(db)
    assert {:ok, :ok} = rebuild(db)
    assert retained(db) == elem(before, 0)
    assert objects(db) == elem(before, 2)

    assert rows(db, "SELECT closedByProcess FROM assignments ORDER BY id") == [
             [nil],
             [nil],
             [nil]
           ]

    assert rows(db, "PRAGMA foreign_key_check") == []
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA legacy_alter_table") == [[0]]
    assert rows(db, "SELECT path FROM assignment_files") == [["synthetic"]]
    assert rows(db, "SELECT assignmentId FROM attests") == [["a"]]
    assert {:error, _} = DB.query(db, "UPDATE assignments SET subject='forbidden' WHERE id='a'")
  end

  test "empty R1 target retains nullable column and process actor checks", %{db: db} do
    assert {:ok, :ok} = rebuild(db)

    assert [[_, "reminderState", "TEXT", 0, nil, 0]] =
             Enum.filter(
               rows(db, "PRAGMA table_info(assignments)"),
               &(Enum.at(&1, 1) == "reminderState")
             )

    seed(db)

    assert {:error, _} =
             DB.query(db, "UPDATE assignments SET closedByProcess='other' WHERE id='a'")

    assert {:error, _} =
             DB.query(
               db,
               "UPDATE assignments SET closedByProcess='process:tightbeam' WHERE id='a'"
             )

    # Current Firehose requires the process close to name its exact generation
    # and durable retirement provenance; keep the actor CHECKs above and below.
    assert :ok =
             DB.execute(db, """
             INSERT INTO assignment_revocations
               (id,assignmentId,revokedAt,revokedByProcess,reason)
             VALUES ('rev_process_fixture','a',2,'process:tightbeam','holder session retired');
             INSERT INTO assignment_revocation_generations
               (revocationId,assignmentId,reopeningId)
             VALUES ('rev_process_fixture','a',NULL);
             """)

    assert {:ok, []} =
             DB.query(db, """
             UPDATE assignments SET state='closed',outcome='revoked',closedAt=2,
               closedByProcess='process:tightbeam' WHERE id='a'
             """)

    assert {:error, _} =
             DB.query(db, "UPDATE assignments SET closedByUser='fixture' WHERE id='a'")
  end

  test "outer transaction rollback restores rows schema objects and references", %{db: db} do
    seed(db)
    before = snapshot(db)

    assert {:error, %RuntimeError{message: "synthetic rollback"}} =
             rebuild(db, fn -> raise "synthetic rollback" end)

    assert snapshot(db) == before
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "missing R1 prerequisite refuses without changing predecessor", %{db: db} do
    :ok = DB.execute(db, "ALTER TABLE assignments DROP COLUMN reminderState")
    before = snapshot(db)
    assert {:error, %MatchError{term: {:error, "no such column: reminderState"}}} = rebuild(db)
    assert snapshot(db) == before
  end

  test "unsafe transaction settings refuse before writes", %{db: db} do
    before = snapshot(db)

    assert {:error, %ArgumentError{}} =
             DB.transaction(db, &Assignments.rebuild_r1_process_close_in_txn/1)

    assert snapshot(db) == before
  end

  defp rebuild(db, after_rebuild \\ fn -> :ok end) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")
    :ok = DB.execute(db, "PRAGMA legacy_alter_table=ON")

    try do
      DB.transaction(db, fn txn ->
        :ok = Assignments.rebuild_r1_process_close_in_txn(txn)
        after_rebuild.()
      end)
    after
      :ok = DB.execute(db, "PRAGMA legacy_alter_table=OFF")
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
  end

  defp seed(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('r1-fixture','r1','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('a','synthetic','r1-fixture','fixture',1,NULL),
               ('b','synthetic','r1-fixture','fixture',1,''),
               ('c','synthetic','r1-fixture','fixture',1,'{ "v": 1, "unicode": "λ" }');
      UPDATE assignments SET reviewsAssignmentId='a' WHERE id='a';
      INSERT INTO assignment_files(assignmentId,path) VALUES ('a','synthetic');
      INSERT INTO attests(id,assignmentId,kind,bySession,ts)
        VALUES ('att','a','progress','r1-fixture',1);
      CREATE INDEX synthetic_reminder_index ON assignments(reminderState);
      CREATE TRIGGER synthetic_subject_guard BEFORE UPDATE OF subject ON assignments
        WHEN NEW.subject='forbidden' BEGIN SELECT RAISE(ABORT,'synthetic refusal'); END;
      """)
  end

  defp retained(db) do
    columns =
      rows(db, "PRAGMA table_info(assignments)")
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.reject(&(&1 == "closedByProcess"))

    rows(db, "SELECT " <> Enum.join(columns, ",") <> " FROM assignments ORDER BY id")
  end

  defp objects(db),
    do:
      rows(
        db,
        "SELECT type,name,sql FROM sqlite_schema WHERE type IN ('index','trigger') AND sql IS NOT NULL ORDER BY name"
      )

  defp snapshot(db),
    do:
      {retained(db), rows(db, "PRAGMA table_info(assignments)"), objects(db),
       rows(db, "SELECT * FROM schema_stamp")}

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
