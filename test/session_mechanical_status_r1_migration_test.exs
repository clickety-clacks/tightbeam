defmodule Tightbeam.SessionMechanicalStatusR1MigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}

  setup do
    db = start_supervised!({DB, name: :mechanical_status_r1_db, path: ":memory:"})
    sql = File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql"))

    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) ==
             "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"

    :ok = DB.execute(db, sql)

    :ok =
      DB.execute(db, """
      ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL;
      ALTER TABLE condition_facts ADD COLUMN payload TEXT NULL;
      UPDATE schema_stamp SET shape='row-driven-r1-v1-019';
      """)

    %{db: db}
  end

  test "backfill uses pending turns and exact MAX timestamps without touching other state", %{
    db: db
  } do
    seed(db)
    assert {:ok, :ok} = carrier(db)
    before = snapshot(db)
    old_columns = columns(db)
    sessions = rows(db, "SELECT sessionKey,updatedAt FROM sessions ORDER BY sessionKey")

    pending =
      rows(db, "SELECT DISTINCT sessionKey FROM turns WHERE status IN ('queued','running')")
      |> List.flatten()

    assert {:ok, :ok} = mechanical(db, 1_000)

    assert other_tables(db) == before.other
    assert objects(db) == before.objects
    kept = Enum.reject(old_columns, &(&1 == "updatedAt"))
    positions = Enum.map(kept, &Enum.find_index(old_columns, fn column -> column == &1 end))
    expected = Enum.map(before.sessions, fn row -> Enum.map(positions, &Enum.at(row, &1)) end)

    assert rows(db, "SELECT " <> Enum.join(kept, ",") <> " FROM sessions ORDER BY sessionKey") ==
             expected

    assert rows(
             db,
             "SELECT sessionKey,mechanicalStatus,updatedAt FROM sessions ORDER BY sessionKey"
           ) ==
             Enum.map(sessions, fn [key, old] ->
               [key, if(key in pending, do: "running", else: "idle"), max(old + 1, 1_000)]
             end)

    assert rows(db, "PRAGMA foreign_key_check") == []

    assert rows(db, "SELECT assignmentId FROM turns WHERE sessionKey='owner'") == [
             ["child-assignment"]
           ]

    assert rows(db, "SELECT sessionKey,assignmentId,incidentId FROM harness_health_observations") ==
             [["owner", nil, nil]]
  end

  test "empty target retains default NOT NULL and selected status CHECK", %{db: db} do
    assert rows(db, "SELECT * FROM sessions") == []
    assert {:ok, :ok} = carrier(db)
    assert {:ok, :ok} = mechanical(db, 1_000)

    assert Enum.filter(
             rows(db, "PRAGMA table_info(sessions)"),
             &(Enum.at(&1, 1) == "mechanicalStatus")
           ) ==
             [[length(columns(db)) - 1, "mechanicalStatus", "TEXT", 1, "'idle'", 0]]

    session(db, "fresh", "active", 20)
    assert rows(db, "SELECT mechanicalStatus,updatedAt FROM sessions") == [["idle", 20]]
    assert {:error, _} = DB.query(db, "UPDATE sessions SET mechanicalStatus=NULL")
    assert {:error, _} = DB.query(db, "UPDATE sessions SET mechanicalStatus='failed'")
    assert {:ok, []} = DB.query(db, "UPDATE sessions SET mechanicalStatus='running'")
  end

  test "wrong or missing R1 stamp refuses before writes", %{db: db} do
    assert {:ok, :ok} = carrier(db)

    for sql <- ["UPDATE schema_stamp SET shape='unallocated'", "DELETE FROM schema_stamp"] do
      :ok = DB.execute(db, sql)
      before = snapshot(db)
      assert {:error, %Schema.ShapeError{}} = mechanical(db, 1_000)
      assert snapshot(db) == before
    end
  end

  test "absent and mismatched carrier postconditions refuse before ALTER", %{db: db} do
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = mechanical(db, 1_000)
    assert snapshot(db) == before
    assert {:ok, :ok} = carrier(db)
    :ok = DB.execute(db, "DROP INDEX decision_requests_asked")
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = mechanical(db, 1_000)
    assert snapshot(db) == before
    :ok = DB.execute(db, "CREATE INDEX decision_requests_asked ON decision_requests(ownerUserId)")
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = mechanical(db, 1_000)
    assert snapshot(db) == before
  end

  test "second application and noninteger time refuse without timestamp reset", %{db: db} do
    session(db, "repeat", "active", 1)
    assert {:ok, :ok} = carrier(db)
    assert {:ok, :ok} = mechanical(db, 1_000)
    before = snapshot(db)
    assert {:error, _} = mechanical(db, 9_000)
    assert snapshot(db) == before
    assert {:error, %FunctionClauseError{}} = mechanical(db, "invalid")
    assert snapshot(db) == before
  end

  test "outer rollback restores both helpers and every retained row and object", %{db: db} do
    seed(db)
    before = snapshot(db)

    assert {:error, %RuntimeError{message: "synthetic whole-sequence rollback"}} =
             carrier(db, fn txn ->
               :ok = Schema.add_r1_session_mechanical_status_in_txn(txn, 1_000)
               raise "synthetic whole-sequence rollback"
             end)

    assert snapshot(db) == before
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA legacy_alter_table") == [[0]]
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  defp mechanical(db, time),
    do: DB.transaction(db, &Schema.add_r1_session_mechanical_status_in_txn(&1, time))

  defp carrier(db, next \\ fn _ -> :ok end) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")
    :ok = DB.execute(db, "PRAGMA legacy_alter_table=ON")

    try do
      DB.transaction(db, fn txn ->
        :ok = Schema.rebuild_r1_decision_carrier_in_txn(txn)
        next.(txn)
      end)
    after
      :ok = DB.execute(db, "PRAGMA legacy_alter_table=OFF")
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
  end

  defp seed(db) do
    for {key, state, time} <- [
          {"none", "active", 10},
          {"queued", "active", 1_000},
          {"running", "active", 2_000},
          {"mixed", "retired", 10},
          {"terminal", "retired", 2_000},
          {"owner", "active", 10},
          {"child", "active", 1_000}
        ],
        do: session(db, key, state, time)

    for {key, statuses} <- [
          {"queued", ~w(queued)},
          {"running", ~w(running)},
          {"mixed", ~w(queued running delivered)},
          {"terminal", ~w(delivered canceled failed failed_unknown)}
        ],
        status <- statuses,
        do: turn(db, key, status)

    :ok =
      DB.execute(db, """
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('child-assignment','synthetic','child','fixture',1,NULL),
               ('pending-assignment','synthetic','owner','fixture',1,'{"phase":"pending"}');
      INSERT INTO assignment_effects(assignmentId,effectKind) VALUES ('child-assignment','evidence');
      INSERT INTO condition_facts(ts,kind,scope,origin,ownerUserId,payload)
        VALUES (1,'synthetic-legacy','mechanical','user:fixture','fixture',NULL),
               (2,'synthetic-typed','mechanical','user:fixture','fixture','{"v":1}');
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,assignmentId,error)
        VALUES ('owner','owner-message','process:tightbeam','child notification','failed_unknown',1,
          'child-assignment','interrupted: outcome unknown');
      INSERT INTO messages(id,sessionKey,role,content,timestamp,llmVisibleMessageId)
        VALUES ('owner-message','owner','assistant','committed evidence',1,'visible');
      INSERT INTO harness_health_observations(id,correlationId,harness,host,failureClass,
        evidenceKind,sessionKey,assignmentId,observedAt,cause,principal,incidentId)
        VALUES ('observation','correlation','fixture','synthetic-host','interrupted-outcome-unknown',
          'terminal-failure','owner',NULL,1,'synthetic retained outcome','process:tightbeam',NULL);
      """)
  end

  defp session(db, key, state, time) do
    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,state,createdAt,updatedAt)
        VALUES ('#{key}','#{key}','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',
          '#{state}',1,#{time});
      """)
  end

  defp turn(db, key, status) do
    :ok =
      DB.execute(db, """
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt)
        VALUES ('#{key}','#{key}-#{status}','user:fixture','synthetic','#{status}',1);
      """)
  end

  defp columns(db), do: Enum.map(rows(db, "PRAGMA table_info(sessions)"), &Enum.at(&1, 1))

  defp objects(db),
    do:
      rows(
        db,
        "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('index','trigger') ORDER BY type,name"
      )

  defp other_tables(db) do
    for [table] <-
          rows(
            db,
            "SELECT name FROM sqlite_master WHERE type='table' AND name!='sessions' ORDER BY name"
          ) do
      {table,
       rows(db, "SELECT * FROM \"" <> String.replace(table, "\"", "\"\"") <> "\"") |> Enum.sort()}
    end
  end

  defp snapshot(db),
    do: %{
      sessions: rows(db, "SELECT * FROM sessions ORDER BY sessionKey"),
      other: other_tables(db),
      objects: objects(db),
      ddl: rows(db, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
    }

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
