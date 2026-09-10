defmodule Tightbeam.DecisionCarrierR1MigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}

  setup do
    db = start_supervised!({DB, name: :decision_carrier_r1_db, path: ":memory:"})
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

  test "all predecessor kinds and states retain exact rows, evidence, R1 nulls and FK links", %{
    db: db
  } do
    seed(db)
    before = snapshot(db)
    columns = columns(db)
    assert {:ok, :ok} = rebuild(db)

    assert rows(db, "SELECT " <> Enum.join(columns, ",") <> " FROM decision_requests ORDER BY id") ==
             before.requests

    assert retained(db) == before.retained
    assert triggers(db) == before.triggers
    assert rows(db, "SELECT requestId FROM synthetic_decision_links") == [["operator-ruled"]]
    assert rows(db, "PRAGMA foreign_key_check") == []
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA legacy_alter_table") == [[0]]

    assert Enum.map(indexes(db), &hd/1) ==
             ~w(decision_requests_asked decision_requests_effort_generation decision_requests_key decision_requests_one_open decision_requests_operator_open decision_requests_owner)

    assert Enum.reject(indexes(db), &(hd(&1) == "decision_requests_asked")) == before.indexes

    assert rows(
             db,
             "SELECT askedOfRole,answer,answeredBy,answeredAt,returnedBy,returnReason,returnedAt FROM decision_requests"
           )
           |> Enum.all?(&(&1 == List.duplicate(nil, 7)))
  end

  test "empty rebuild admits only selected agent shapes and retains terminal guards", %{db: db} do
    assert {:ok, :ok} = rebuild(db)

    for status <- ~w(open answered withdrawn returned) do
      answer = if status == "answered", do: "'answer','session:holder',2", else: "NULL,NULL,NULL"

      returned =
        if status == "returned", do: "'session:holder','reason',3", else: "NULL,NULL,NULL"

      :ok =
        DB.execute(db, """
        INSERT INTO decision_requests(id,kind,raiserId,raiserSessionKey,ownerUserId,expecterSessionKey,
          expecterUserId,raisedAt,question,context,status,answer,answeredBy,answeredAt,returnedBy,returnReason,returnedAt)
        VALUES ('agent-#{status}','agent','session:raiser','raiser','fixture','holder','fixture',1,'question','{}',
          '#{status}',#{answer},#{returned});
        """)
    end

    assert {:error, _} =
             DB.query(db, "UPDATE decision_requests SET answer=NULL WHERE id='agent-answered'")

    assert {:error, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET returnReason=' ' WHERE id='agent-returned'"
             )

    assert {:error, _} =
             DB.query(db, "UPDATE decision_requests SET status='ruled' WHERE id='agent-open'")

    seed(db)

    assert {:error, _} =
             DB.query(db, """
             UPDATE decision_requests SET status='ruled',decision='allow',ruledBy='user:fixture',
               ruledAt=2,rulingFactId=1 WHERE id='operator-open'
             """)

    assert {:error, _} =
             DB.query(db, """
             INSERT INTO decision_requests SELECT * FROM decision_requests WHERE id='operator-ruled'
             """)

    assert rows(db, "SELECT shape FROM schema_stamp") == [["row-driven-r1-v1-019"]]
  end

  test "outer rollback restores rows DDL indexes triggers epoch and evidence", %{db: db} do
    seed(db)
    before = snapshot(db)

    assert {:error, %RuntimeError{message: "synthetic rollback"}} =
             rebuild(db, fn -> raise "synthetic rollback" end)

    assert snapshot(db) == before
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "wrong and missing stamp refuse without mutation", %{db: db} do
    for statement <- ["UPDATE schema_stamp SET shape='unallocated'", "DELETE FROM schema_stamp"] do
      :ok = DB.execute(db, statement)
      before = snapshot(db)
      assert {:error, %Schema.ShapeError{}} = rebuild(db)
      assert snapshot(db) == before
    end
  end

  test "missing terminal trigger refuses and altered trigger rolls back the rebuild", %{db: db} do
    seed(db)
    :ok = DB.execute(db, "DROP TRIGGER decision_requests_terminal_insert_guard")
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = rebuild(db)
    assert snapshot(db) == before

    :ok =
      DB.execute(db, """
      CREATE TRIGGER decision_requests_terminal_insert_guard BEFORE INSERT ON decision_requests
      WHEN NEW.id='forbidden' BEGIN SELECT RAISE(ABORT,'synthetic'); END;
      """)

    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = rebuild(db)
    assert snapshot(db) == before
  end

  test "unsafe transaction configuration refuses before source changes", %{db: db} do
    before = snapshot(db)

    assert {:error, %ArgumentError{}} =
             DB.transaction(db, &Schema.rebuild_r1_decision_carrier_in_txn/1)

    assert snapshot(db) == before
  end

  defp rebuild(db, after_rebuild \\ fn -> :ok end) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")
    :ok = DB.execute(db, "PRAGMA legacy_alter_table=ON")

    try do
      DB.transaction(db, fn txn ->
        :ok = Schema.rebuild_r1_decision_carrier_in_txn(txn)
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
        VALUES ('carrier-fixture','fixture','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('carrier-assignment','synthetic','carrier-fixture','fixture',1,NULL);
      INSERT INTO condition_facts(ts,kind,scope,origin,ownerUserId,payload)
        VALUES (1,'synthetic-legacy','carrier','user:fixture','fixture',NULL);
      """)

    for kind <- ~w(statute effort operator),
        status <- ~w(open ruled consumed withdrawn superseded),
        not (kind == "operator" and status == "consumed") do
      id = "#{kind}-#{status}"

      {raiser, session, assignment, expecter, rung, generation, wake, statute, key, options} =
        case kind do
          "statute" ->
            {"user:fixture", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", "'law'", "'#{id}'",
             "NULL"}

          "effort" ->
            {"process:tightbeam", "NULL", "'carrier-assignment'", "'holder'", "0", "'#{status}'",
             "'wake'", "NULL", "NULL", "NULL"}

          "operator" ->
            {"session:carrier-fixture", "'carrier-fixture'", "NULL", "NULL", "NULL", "NULL",
             "NULL", "NULL", "'#{id}'", "'[]'"}
        end

      terminal =
        if kind == "operator" and status == "ruled",
          do: "'allow','late ruling','user:fixture','user:fixture',NULL,'none',2,1",
          else: "NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL"

      :ok =
        DB.execute(db, """
        INSERT INTO decision_requests(id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,
          expecterSessionKey,lineageRung,effortGeneration,deadlineWakeId,raisedAt,deadlineAt,
          statuteName,actionKey,question,options,context,status,decision,rationale,ruledBy,
          ruledViaPrincipal,ruledViaSessionKey,ruledViaSessionState,ruledAt,rulingFactId)
        VALUES ('#{id}','#{kind}','#{raiser}',#{session},'fixture',#{assignment},#{expecter},#{rung},
          #{generation},#{wake},1,10,#{statute},#{key},'question',#{options},'{"exact":"λ"}','#{status}',#{terminal});
        """)
    end

    :ok =
      DB.execute(db, """
      CREATE TABLE synthetic_decision_links(requestId TEXT REFERENCES decision_requests(id));
      INSERT INTO synthetic_decision_links VALUES ('operator-ruled');
      INSERT INTO decision_request_integrity_evidence
        (requestId,shapeDigest,schemaVersion,causeCode,failingFields,firstSurface,firstObservedAt,observerPrincipal)
        VALUES ('legacy','digest','terminal-operator-decision-parity-v1','synthetic','[]','migration-preflight',1,'user:fixture');
      """)
  end

  defp columns(db),
    do: Enum.map(rows(db, "PRAGMA table_info(decision_requests)"), &Enum.at(&1, 1))

  defp triggers(db),
    do:
      rows(
        db,
        "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='decision_requests' ORDER BY name"
      )

  defp indexes(db),
    do:
      rows(
        db,
        "SELECT name,sql FROM sqlite_master WHERE type='index' AND tbl_name='decision_requests' AND sql IS NOT NULL ORDER BY name"
      )

  defp retained(db) do
    for table <-
          ~w(schema_stamp assignments condition_facts decision_request_terminal_epoch decision_request_integrity_evidence) do
      {table, rows(db, "SELECT * FROM " <> table)}
    end
  end

  defp snapshot(db),
    do: %{
      requests: rows(db, "SELECT * FROM decision_requests ORDER BY id"),
      retained: retained(db),
      triggers: triggers(db),
      indexes: indexes(db),
      objects: rows(db, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
    }

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
