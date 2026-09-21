defmodule Tightbeam.DecisionRowVersionR1MigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Escalation,
    Model,
    Org,
    Schema,
    Wakes,
    WorkItems
  }

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    db = start_supervised!({DB, name: :decision_version_r1_db, path: ":memory:"})
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

  test "additive version preserves all predecessor fields and other durable state", %{db: db} do
    seed(db)

    :ok =
      DB.execute(db, """
      INSERT INTO harness_health_observations(id,correlationId,harness,host,failureClass,evidenceKind,
        sessionKey,observedAt,cause,principal)
      VALUES ('health','correlation','fixture','synthetic','interrupted-outcome-unknown','terminal-failure',
        'carrier-fixture',1,'retained unknown','process:tightbeam');
      INSERT INTO assignment_effects(assignmentId,effectKind) VALUES ('carrier-assignment','evidence');
      INSERT INTO messages(id,sessionKey,role,content,timestamp,llmVisibleMessageId)
        VALUES ('preserved-message','carrier-fixture','assistant','committed evidence',1,'visible');
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('causal-owner','owner','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,assignmentId,error)
        VALUES ('causal-owner','causal-message','process:tightbeam','child notice','failed_unknown',1,
          'carrier-assignment','interrupted: outcome unknown');
      INSERT INTO condition_facts(ts,kind,scope,origin,ownerUserId,payload)
        VALUES (2,'synthetic-typed','carrier','user:fixture','fixture','{"v":1}');
      """)

    assert {:ok, :ok} = prerequisites(db)
    before = snapshot(db)
    columns = rows(db, "PRAGMA table_info(decision_requests)") |> Enum.map(&Enum.at(&1, 1))
    assert {:ok, :ok} = version(db)

    assert rows(db, "SELECT " <> Enum.join(columns, ",") <> " FROM decision_requests ORDER BY id") ==
             before.decisions

    assert others(db) == before.other
    assert rows(db, "SELECT DISTINCT rowVersion FROM decision_requests") == [[1]]
    assert rows(db, "PRAGMA foreign_key_check") == []

    assert rows(
             db,
             "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='decision_requests' ORDER BY name"
           ) ==
             Enum.map(
               ~w(decision_requests_r7_row_version decision_requests_terminal_insert_guard decision_requests_terminal_update_guard),
               &[&1]
             )

    assert rows(db, "SELECT type,name,sql FROM sqlite_master WHERE type='index' ORDER BY name") ==
             before.indexes
  end

  test "selected meaningful changes increment once while noops and exclusions do not", %{db: db} do
    seed(db)
    assert {:ok, :ok} = upgrade(db)

    for {sql, expected} <- [
          {"UPDATE decision_requests SET question=question WHERE id='statute-open'", 1},
          {"UPDATE decision_requests SET rationale='changed' WHERE id='statute-open'", 2},
          {"UPDATE decision_requests SET rationale=NULL WHERE id='statute-open'", 3},
          {"UPDATE decision_requests SET question='new',context='new' WHERE id='statute-open'",
           4},
          {"UPDATE decision_requests SET actionKey='excluded' WHERE id='statute-open'", 4},
          {"UPDATE decision_requests SET rowVersion=9 WHERE id='statute-open'", 9}
        ] do
      assert {:ok, []} = DB.query(db, sql)
      assert version_of(db, "statute-open") == expected
    end

    for invalid <- ["NULL", "0", "-1", "'invalid'", "1.5"] do
      before = snapshot(db)

      assert {:error, _} =
               DB.query(
                 db,
                 "UPDATE decision_requests SET rowVersion=#{invalid} WHERE id='statute-open'"
               )

      assert snapshot(db) == before
    end
  end

  test "agent answer return shapes default to one and terminal insert guard rejects invalid versions",
       %{db: db} do
    assert {:ok, :ok} = upgrade(db)

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

      assert version_of(db, "agent-#{status}") == 1
    end

    :ok = DB.execute(db, "UPDATE decision_requests SET answer='next' WHERE id='agent-answered'")
    assert version_of(db, "agent-answered") == 2

    :ok =
      DB.execute(db, "UPDATE decision_requests SET returnReason='next' WHERE id='agent-returned'")

    assert version_of(db, "agent-returned") == 2

    for invalid <- ["0", "-1", "'bad'", "1.5", "NULL"] do
      assert {:error, _} =
               DB.query(db, """
               INSERT INTO decision_requests(id,kind,raiserId,ownerUserId,raisedAt,deadlineAt,statuteName,
                 actionKey,question,context,status,rowVersion)
               VALUES ('invalid','statute','user:fixture','fixture',1,2,'law','invalid','q','{}','open',#{invalid})
               """)
    end
  end

  test "missing or malformed prerequisites and repeated application refuse unchanged", %{db: db} do
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = version(db)
    assert snapshot(db) == before
    assert {:ok, :ok} = prerequisites(db)
    :ok = DB.execute(db, "DROP INDEX decision_requests_asked")
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = version(db)
    assert snapshot(db) == before

    :ok =
      DB.execute(
        db,
        "CREATE INDEX decision_requests_asked ON decision_requests(expecterSessionKey,status) WHERE kind='agent'"
      )

    assert {:ok, :ok} = version(db)
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = version(db)
    assert snapshot(db) == before
    :ok = DB.execute(db, "UPDATE schema_stamp SET shape='unallocated'")
    before = snapshot(db)
    assert {:error, %Schema.ShapeError{}} = version(db)
    assert snapshot(db) == before
  end

  test "whole sequence rollback restores original data schema and terminal objects", %{db: db} do
    seed(db)
    before = snapshot(db)

    assert {:error, %RuntimeError{message: "row version rollback"}} =
             upgrade(db, fn -> raise "row version rollback" end)

    assert snapshot(db) == before
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA legacy_alter_table") == [[0]]
  end

  test "actual consume wins once and emits one decision transition", %{db: db} do
    seed(db)
    :ok = DB.execute(db, "UPDATE decision_requests SET decision='allow' WHERE id='statute-ruled'")
    assert {:ok, :ok} = upgrade(db)
    pid = GenServer.whereis(db)
    :erlang.trace_pattern({Wakes, :row_commit_in_txn, 2}, true, [:local])
    :erlang.trace(pid, true, [:call, {:tracer, self()}])
    on_exit(fn -> :erlang.trace_pattern({Wakes, :row_commit_in_txn, 2}, false, [:local]) end)
    assert Escalation.consume(db, "statute-ruled")
    assert version_of(db, "statute-ruled") == 2
    before = snapshot(db)
    refute Escalation.consume(db, "statute-ruled")
    assert snapshot(db) == before
    barrier = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^barrier}

    transitions =
      for {:trace, ^pid, :call, {Wakes, :row_commit_in_txn, [_txn, items]}} <- drain([]),
          item <- List.wrap(items),
          do: item

    assert Enum.count(
             transitions,
             &(&1.domain == "decision_request" and &1.row_id == "statute-ruled")
           ) == 1
  end

  @tag firehose_version_runtime: true
  test "actual late ruling keeps owner-bound notification and replay CAS with versioning", %{
    db: db
  } do
    assert :ok = Schema.upgrade_firehose_r1(db)
    assert :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',0,1)")
    ensure_main_session(db, "flynn")
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    register_hosts(db, %{
      "fixture" => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    opener = session(db, "version-opener")
    raiser = session(db, "version-raiser")
    scheduler = :row_version_scheduler
    start_supervised!({Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _ -> :ok end})

    item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: opener.session_key,
        principal: {:session, opener.session_key},
        session_key: nil,
        supervision_interval_ms: 1_000,
        params: %{title: "version work"}
      })

    assignment =
      Assignments.__handle__(db, "assign", %{
        verb: "assign",
        origin: opener.session_key,
        principal: {:session, opener.session_key},
        session_key: raiser.session_key,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{subject: "version work", work_item_id: item.id, effect_kind: "coordination"}
      })

    request =
      Escalation.operator_ask(db, %{
        verb: "operator-ask",
        origin: raiser.session_key,
        principal: {:session, raiser.session_key},
        transport_session_key: raiser.session_key,
        params: %{question: "continue?", assignment_id: assignment.id}
      })

    assert version_of(db, request.id) == 1

    assert %{state: "closed"} =
             Assignments.__handle__(db, "revoke-assignment", %{
               verb: "revoke-assignment",
               origin: opener.session_key,
               principal: {:session, opener.session_key},
               params: %{assignment_id: assignment.id, reason: "synthetic replacement"}
             })

    Org.retire(db, raiser.session_key, "session:#{opener.session_key}", 1_000)
    assert :ok = Escalation.recover_retired(db)
    before_version = version_of(db, request.id)

    call = %{
      verb: "operator-rule",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      params: %{request: request.id, decision: "accept"}
    }

    assert %{status: "ruled"} = Escalation.operator_rule(db, call, scheduler: scheduler)
    assert version_of(db, request.id) == before_version + 1

    assert rows(
             db,
             "SELECT ownerUserId FROM condition_facts WHERE kind='operator-ruling-late-routed' AND scope='#{request.id}'"
           ) == [["flynn"]]

    assert rows(
             db,
             "SELECT sessionKey FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope='#{request.id}'"
           ) == [[opener.session_key]]

    before = snapshot(db)
    assert %{status: "ruled"} = Escalation.operator_rule(db, call, scheduler: scheduler)
    assert snapshot(db) == before
  end

  @tag rest_r7_boundary: true
  test "R7 preserves malformed legacy returns and versions same-millisecond changes", %{db: db} do
    seed(db)
    assert {:ok, :ok} = prerequisites(db)

    for {id, actor, at} <- [
          {"valid", "session:holder", 3},
          {"bad-time", "session:holder", 0},
          {"bad-actor", " ", 3}
        ] do
      assert {:ok, []} =
               DB.query(
                 db,
                 """
                 INSERT INTO decision_requests(id,kind,raiserId,raiserSessionKey,ownerUserId,
                   expecterSessionKey,expecterUserId,raisedAt,question,context,status,
                   returnedBy,returnReason,returnedAt)
                 VALUES (?1,'agent','session:raiser','raiser','fixture','holder','fixture',1,
                   'question','{}','returned',?2,'original',?3)
                 """,
                 [id, actor, at]
               )
    end

    columns = rows(db, "PRAGMA table_info(decision_requests)") |> Enum.map(&Enum.at(&1, 1))
    before = snapshot(db)
    assert {:ok, :ok} = version(db)

    assert rows(db, "SELECT " <> Enum.join(columns, ",") <> " FROM decision_requests ORDER BY id") ==
             before.decisions

    assert others(db) == before.other
    assert rows(db, "SELECT shape FROM schema_stamp") == [["row-driven-r1-v1-019"]]
    assert rows(db, "PRAGMA foreign_key_check") == []

    for id <- ["bad-time", "bad-actor"] do
      preserved = snapshot(db)

      assert_raise ArgumentError,
                   "returned agent request requires its stored return triplet",
                   fn ->
                     db
                     |> Tightbeam.StateResources.query_decision_request(id)
                     |> Tightbeam.StateResources.decision_request()
                   end

      assert snapshot(db) == preserved
      assert version_of(db, id) == 1
    end

    project = fn ->
      db
      |> Tightbeam.StateResources.query_decision_request("valid")
      |> Tightbeam.StateResources.decision_request()
    end

    original = project.()
    assert original["rowVersion"] == 1
    assert original["returnedAt"] == 3

    assert {:ok, []} =
             DB.query(db, "UPDATE decision_requests SET returnReason='changed' WHERE id='valid'")

    changed = project.()
    assert changed["returnedAt"] == original["returnedAt"]
    assert changed["rowVersion"] == 2
    assert changed["returnReason"] == "changed"

    assert Map.delete(changed, "rowVersion") |> Map.put("returnReason", "original") ==
             Map.delete(original, "rowVersion")

    assert Tightbeam.StateResources.encode_item("decision requests", changed) !=
             Tightbeam.StateResources.encode_item("decision requests", original)

    preserved = snapshot(db)

    assert {:ok, []} =
             DB.query(db, "UPDATE decision_requests SET returnReason='changed' WHERE id='valid'")

    assert snapshot(db) == preserved
    assert project.() == changed
  end

  defp session(db, key),
    do:
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "fixture",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

  defp prerequisites(db, next \\ fn _ -> :ok end) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")
    :ok = DB.execute(db, "PRAGMA legacy_alter_table=ON")

    try do
      DB.transaction(db, fn txn ->
        :ok = Schema.rebuild_r1_decision_carrier_in_txn(txn)
        :ok = Schema.add_r1_session_mechanical_status_in_txn(txn, 1_000)
        next.(txn)
      end)
    after
      :ok = DB.execute(db, "PRAGMA legacy_alter_table=OFF")
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
  end

  defp upgrade(db, after_version \\ fn -> :ok end),
    do:
      prerequisites(db, fn txn ->
        :ok = Schema.add_r1_decision_row_version_in_txn(txn)
        after_version.()
      end)

  defp version(db), do: DB.transaction(db, &Schema.add_r1_decision_row_version_in_txn/1)

  defp version_of(db, id) do
    {:ok, [[version]]} =
      DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id=?1", [id])

    version
  end

  defp drain(acc) do
    receive do
      {:trace, _, :call, _} = event -> drain([event | acc])
    after
      0 -> acc
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

  defp others(db),
    do:
      for(
        [table] <-
          rows(
            db,
            "SELECT name FROM sqlite_master WHERE type='table' AND name!='decision_requests' ORDER BY name"
          ),
        do: {table, rows(db, "SELECT * FROM \"" <> table <> "\"") |> Enum.sort()}
      )

  defp snapshot(db),
    do: %{
      decisions: rows(db, "SELECT * FROM decision_requests ORDER BY id"),
      other: others(db),
      indexes:
        rows(db, "SELECT type,name,sql FROM sqlite_master WHERE type='index' ORDER BY name"),
      objects: rows(db, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
    }

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
