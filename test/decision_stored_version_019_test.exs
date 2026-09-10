defmodule Tightbeam.DecisionStoredVersion019Test do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Escalation, Schema, StateResources}

  setup context do
    db = :"decision_version_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    unless context[:historical_r1], do: :ok = Schema.ensure_all(db)
    %{db: db}
  end

  @turn_fields ~w(seq sessionKey messageId wakeId origin prompt roleRef roleFallback assignmentId jobRef model thinkingLevel modelContext harness replyAttention status owner adapterGen requestRef error createdAt startedAt endedAt publishedAt rowVersion)
  @decision_fields ~w(id kind raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId lineageRung effortGeneration deadlineWakeId raisedAt deadlineAt statuteName question options context status decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt rowVersion)

  @tag rest_r7_closure: true
  test "real statute, agent, and effort rows use the ruled lineage projection", %{db: db} do
    insert_decision_rows(db)

    statute = db |> Escalation.raw_by_id("dr_statute_r7") |> StateResources.decision_request()
    agent = db |> Escalation.raw_by_id("dr_agent_r7") |> StateResources.decision_request()
    effort = db |> Escalation.raw_by_id("dr_effort_r7") |> StateResources.decision_request()

    assert {statute["lineageRung"], statute["effortGeneration"]} == {0, 0}
    assert {agent["lineageRung"], agent["effortGeneration"]} == {0, 0}
    assert {effort["lineageRung"], effort["effortGeneration"]} == {4, 7}
    assert statute["deadlineAt"] == 20
    assert agent["deadlineAt"] == nil
    assert effort["deadlineAt"] == 22
    assert Enum.map([statute, agent, effort], & &1["rowVersion"]) == [1, 1, 1]
    assert statute["options"] == []
    assert agent["options"] == []

    assert effort["options"] == [
             %{"label" => "wake"},
             %{"label" => "continue"},
             %{"label" => "dismiss"}
           ]

    for projection <- [statute, agent, effort] do
      refute Map.has_key?(projection, "cliToken")
      refute Map.has_key?(projection, "actionKey")
      assert is_integer(projection["lineageRung"])
      assert is_integer(projection["effortGeneration"])

      fields =
        if projection["kind"] == "agent",
          do:
            List.insert_at(@decision_fields, -2, "returnedBy")
            |> List.insert_at(-2, "returnReason")
            |> List.insert_at(-2, "returnedAt"),
          else: @decision_fields

      assert MapSet.new(Map.keys(projection)) == MapSet.new(fields)
      bytes = StateResources.encode_item("decision requests", projection)
      assert JSON.decode!(bytes) == projection
      assert_field_order(bytes, fields)
    end

    notice =
      Tightbeam.Firehose.Publisher.committed_notice("decision_request.opened", effort, %{
        "decisionRequestId" => effort["id"]
      })

    assert notice["payload"] == effort

    assert JSON.decode!(Tightbeam.Firehose.Publisher.encode_wire_notice(notice))["payload"] ==
             effort

    assert {:ok, [[nil, nil], [nil, nil], [4, 7]]} =
             DB.query(
               db,
               "SELECT lineageRung,effortGeneration FROM decision_requests ORDER BY rowid"
             )
  end

  @tag rest_r7_closure: true
  test "decision deadline projection enforces the ruled kind-specific storage values", %{db: db} do
    insert_decision_rows(db)
    statute = Escalation.raw_by_id(db, "dr_statute_r7")
    agent = Escalation.raw_by_id(db, "dr_agent_r7")
    effort = Escalation.raw_by_id(db, "dr_effort_r7")

    for malformed <- [
          Map.put(statute, :deadline_at, nil),
          Map.put(statute, :deadline_at, 0),
          Map.put(effort, :deadline_at, -1),
          Map.put(effort, :deadline_at, "22"),
          Map.put(agent, :deadline_at, 22)
        ] do
      assert_raise ArgumentError, ~r/deadlineAt is projection_invalid/, fn ->
        StateResources.decision_request(malformed)
      end
    end
  end

  @tag rest_r7_closure: true
  test "decision option projection preserves ruled exact objects and refuses malformed values", %{
    db: db
  } do
    insert_decision_rows(db)
    statute = Escalation.raw_by_id(db, "dr_statute_r7")

    assert StateResources.decision_request(%{
             statute
             | options: [%{"label" => "allow"}, %{"label" => "deny"}]
           })["options"] == [%{"label" => "allow"}, %{"label" => "deny"}]

    for malformed <- [
          :invalid_json,
          "allow",
          [1],
          [%{"label" => 1}],
          [%{"label" => "allow", "effect" => "allow"}]
        ] do
      assert_raise ArgumentError, ~r/projection_invalid/, fn ->
        StateResources.decision_request(%{statute | options: malformed})
      end
    end
  end

  @tag rest_r7_closure: true
  test "effort lineage projection refuses absent and non-integer stored values", %{db: db} do
    insert_decision_rows(db)
    effort = Escalation.raw_by_id(db, "dr_effort_r7")

    for malformed <- [
          Map.put(effort, :lineage_rung, nil),
          Map.put(effort, :effort_generation, nil),
          Map.put(effort, :lineage_rung, "4"),
          Map.put(effort, :effort_generation, 7.0)
        ] do
      assert_raise ArgumentError, ~r/stored integers for effort/, fn ->
        StateResources.decision_request(malformed)
      end
    end
  end

  @tag rest_r7_closure: true
  test "exact and by-seq turn queries preserve stored prompt through the shared serializer", %{
    db: db
  } do
    prompt = "preserve this exact prompt — no default or redaction"

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO turns (sessionKey,messageId,origin,prompt,replyAttention,status,createdAt) VALUES ('agent:r7','msg_r7','user:mike',?1,1,'queued',123)",
               [prompt]
             )

    assert {:ok, [[seq]]} = DB.query(db, "SELECT seq FROM turns WHERE messageId='msg_r7'")

    exact = StateResources.query_turn(db, "agent:r7", "msg_r7")

    assert {:ok, by_seq} =
             DB.transaction(db, fn txn -> StateResources.query_turn_in_txn(txn, seq) end)

    assert exact == by_seq
    assert exact.prompt == prompt

    item = StateResources.turn(exact)
    assert item["prompt"] == prompt
    assert item["roleFallback"] == nil
    assert item["replyAttention"] == 1
    assert item["rowVersion"] == 123
    assert MapSet.new(Map.keys(item)) == MapSet.new(@turn_fields)
    refute Map.has_key?(item, "turnSeq")

    bytes = StateResources.encode_item("turns", item)
    assert JSON.decode!(bytes) == item
    assert_field_order(bytes, @turn_fields)

    assert :binary.match(bytes, ~s("origin":"user:mike","prompt":#{JSON.encode!(prompt)})) !=
             :nomatch

    notice =
      Tightbeam.Firehose.Publisher.committed_notice("turn.started", exact, %{"turnSeq" => seq})

    assert notice["payload"] == item
    assert notice["payload"]["prompt"] == prompt

    assert JSON.decode!(Tightbeam.Firehose.Publisher.encode_wire_notice(notice))["payload"] ==
             item
  end

  @tag rest_r7_closure: true
  test "turn projection maps stored role fallback and refuses unknown storage values", %{db: db} do
    for {message_id, stored} <- [{"msg_direct", 0}, {"msg_owner", 1}, {"msg_invalid", 2}] do
      assert {:ok, _} =
               DB.query(
                 db,
                 "INSERT INTO turns (sessionKey,messageId,origin,prompt,roleFallback,status,createdAt) VALUES ('agent:r7',?1,'user:mike','prompt',?2,'queued',123)",
                 [message_id, stored]
               )
    end

    direct = StateResources.query_turn(db, "agent:r7", "msg_direct")
    owner = StateResources.query_turn(db, "agent:r7", "msg_owner")
    invalid = StateResources.query_turn(db, "agent:r7", "msg_invalid")

    assert StateResources.turn(direct)["roleFallback"] == nil
    assert StateResources.turn(owner)["roleFallback"] == "owner"

    assert_raise ArgumentError, ~r/roleFallback is projection_invalid/, fn ->
      StateResources.turn(invalid)
    end
  end

  @tag rest_r7_closure: true
  test "turn projection refuses missing and non-string prompt" do
    row = %{
      seq: 1,
      session_key: "agent:r7",
      message_id: "msg_r7",
      origin: "user:mike",
      prompt: "valid",
      role_ref: nil,
      role_fallback: 0,
      assignment_id: nil,
      job_ref: nil,
      model: nil,
      thinking_level: nil,
      model_context: nil,
      harness: nil,
      reply_attention: 0,
      status: "queued",
      owner: nil,
      adapter_gen: nil,
      request_ref: nil,
      error: nil,
      created_at: 1,
      started_at: nil,
      ended_at: nil,
      published_at: nil,
      wake_id: nil
    }

    for malformed <- [
          Map.delete(row, :prompt),
          Map.put(row, :prompt, nil),
          Map.put(row, :prompt, 1)
        ] do
      assert_raise ArgumentError, ~r/prompt must be a string/, fn ->
        StateResources.turn(malformed)
      end
    end
  end

  defp assert_field_order(bytes, fields) do
    positions =
      Enum.map(fields, fn field ->
        {position, _length} = :binary.match(bytes, JSON.encode!(field) <> ":")
        position
      end)

    assert positions == Enum.sort(positions)
  end

  @tag historical_r1: true
  test "exact R1 predecessor adopts version one atomically and preserves reminder bytes", %{
    db: db
  } do
    load_exact_r1(db)
    before = historical_snapshot(db)

    assert_raise RuntimeError, "forced activation interruption", fn ->
      Schema.upgrade_firehose_r1(db, fail_after_statement: :before_firehose_stamp)
    end

    assert historical_snapshot(db) == before
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA legacy_alter_table")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")
    assert :ok = Schema.upgrade_firehose_r1(db)

    assert {:ok, [[1], [1], [1]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests ORDER BY id")

    assert {:ok, [[~s({"phase":"pending"})]]} =
             DB.query(db, "SELECT reminderState FROM assignments WHERE id='retained'")

    assert {:ok, [["firehose-r1-v1-019"]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, _} =
             DB.query(db, "UPDATE decision_requests SET question='Versioned?' WHERE id='old-1'")

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='old-1'")

    for invalid <- [nil, 0, -1, "invalid", 1.5] do
      assert {:error, _} =
               DB.query(db, "UPDATE decision_requests SET rowVersion=?1 WHERE id='old-1'", [
                 invalid
               ])
    end

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='old-1'")

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  @tag historical_r1: true
  test "wrong historical predecessor refuses before changing rows or guards", %{db: db} do
    load_exact_r1(db)
    :ok = DB.execute(db, "UPDATE schema_stamp SET shape='unallocated-decision-predecessor'")
    before = historical_snapshot(db)
    assert_raise Schema.ShapeError, fn -> Schema.upgrade_firehose_r1(db) end
    assert historical_snapshot(db) == before
  end

  defp load_exact_r1(db) do
    sql = File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql"))

    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) ==
             "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"

    :ok = DB.execute(db, sql)

    :ok =
      DB.execute(db, """
      ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL;
      ALTER TABLE condition_facts ADD COLUMN payload TEXT NULL;
      UPDATE schema_stamp SET shape='row-driven-r1-v1-019';
      INSERT INTO users(userId,createdAt) VALUES ('fixture',1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('holder','holder','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('retained','synthetic','holder','fixture',1,'{"phase":"pending"}');
      """)

    for id <- ["old-1", "old-2", "old-3"] do
      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 INSERT INTO decision_requests(id,kind,raiserId,ownerUserId,assignmentId,raisedAt,deadlineAt,statuteName,actionKey,question,context,status)
                 VALUES (?1,'statute','user:fixture','fixture','retained',1,2,'synthetic',?1,'May this ship?','{}','open')
                 """,
                 [id]
               )
    end
  end

  defp historical_snapshot(db) do
    for sql <- [
          "SELECT type,name,sql FROM sqlite_master ORDER BY type,name",
          "SELECT * FROM schema_stamp",
          "SELECT * FROM decision_requests ORDER BY id",
          "SELECT * FROM assignments ORDER BY id"
        ] do
      {:ok, rows} = DB.query(db, sql)
      rows
    end
  end

  test "decision rowVersion defaults, increments on R7 changes, and ignores non-R7 changes", %{
    db: db
  } do
    insert_decision_rows(db)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_statute_r7'")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET question=question WHERE id='dr_statute_r7'"
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_statute_r7'")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET question='May this ship now?' WHERE id='dr_statute_r7'"
             )

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_statute_r7'")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET actionKey='ship-action-v2' WHERE id='dr_statute_r7'"
             )

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_statute_r7'")

    projection =
      db |> Escalation.raw_by_id("dr_statute_r7") |> StateResources.decision_request()

    assert projection["rowVersion"] == 2

    assert {:error, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET rowVersion=0 WHERE id='dr_statute_r7'"
             )
  end

  test "decision projection refuses absent and invalid stored rowVersion", %{db: db} do
    insert_decision_rows(db)
    statute = Escalation.raw_by_id(db, "dr_statute_r7")

    for malformed <- [
          Map.delete(statute, :row_version),
          Map.put(statute, :row_version, nil),
          Map.put(statute, :row_version, 0),
          Map.put(statute, :row_version, "1")
        ] do
      assert_raise ArgumentError, ~r/rowVersion is projection_invalid/, fn ->
        StateResources.decision_request(malformed)
      end
    end
  end

  test "each R7 field including return triplet increments once; rollback preserves version", %{
    db: db
  } do
    insert_decision_rows(db)

    fields =
      ~w(id kind raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId lineageRung effortGeneration deadlineWakeId raisedAt deadlineAt statuteName question options context status decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt returnedBy returnReason returnedAt)

    # Isolate the trigger's complete field inventory from class-shape constraints.
    :ok = DB.execute(db, "PRAGMA ignore_check_constraints = ON")

    for field <- fields do
      assert {:error, _} =
               DB.transaction(db, fn txn ->
                 Tightbeam.DB.Txn.q(
                   txn,
                   "UPDATE decision_requests SET #{field}=?1 WHERE id='dr_agent_r7'",
                   ["changed"]
                 )

                 assert [[2]] =
                          Tightbeam.DB.Txn.q(
                            txn,
                            "SELECT rowVersion FROM decision_requests WHERE rowid=2"
                          )

                 raise "rollback field control"
               end)

      assert {:ok, [[1]]} =
               DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_agent_r7'")
    end

    :ok = DB.execute(db, "PRAGMA ignore_check_constraints = OFF")

    assert {:ok, _} =
             DB.query(db, """
             UPDATE decision_requests SET status='returned', returnedBy='session:agent:asked',
               returnReason='clarify', returnedAt=raisedAt WHERE id='dr_agent_r7'
             """)

    assert {:ok, [[2, 11, 11]]} =
             DB.query(
               db,
               "SELECT rowVersion,raisedAt,returnedAt FROM decision_requests WHERE id='dr_agent_r7'"
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET returnedAt=returnedAt, returnReason=returnReason WHERE id='dr_agent_r7'"
             )

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_agent_r7'")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_agent_r7'")
  end

  test "existing guards reject malformed writes and counter overflow", %{db: db} do
    insert_decision_rows(db)

    for invalid <- [nil, 0, -1, "invalid", 1.5] do
      assert {:error, _} =
               DB.query(db, "UPDATE decision_requests SET rowVersion=?1 WHERE id='dr_agent_r7'", [
                 invalid
               ])

      assert {:error, _} =
               DB.query(
                 db,
                 """
                 INSERT INTO decision_requests (id,kind,raiserId,raiserSessionKey,ownerUserId,
                   expecterSessionKey,expecterUserId,raisedAt,question,context,status,rowVersion)
                 VALUES ('dr_invalid','agent','session:agent:raiser','agent:raiser','mike',
                   'agent:asked','mike',1,'q','{}','open',?1)
                 """,
                 [invalid]
               )

      assert {:ok, [[1]]} =
               DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_agent_r7'")
    end

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET rowVersion=9223372036854775807 WHERE id='dr_agent_r7'"
             )

    assert {:error, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET question='overflow' WHERE id='dr_agent_r7'"
             )

    assert {:ok, [[9_223_372_036_854_775_807, "Which path?"]]} =
             DB.query(
               db,
               "SELECT rowVersion,question FROM decision_requests WHERE id='dr_agent_r7'"
             )

    assert :ok = Schema.ensure_all(db)

    assert {:error, _} =
             DB.query(db, "UPDATE decision_requests SET rowVersion=-1 WHERE id='dr_agent_r7'")
  end

  defp insert_decision_rows(db) do
    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,
                  raisedAt,deadlineAt,statuteName,actionKey,question,options,context,status)
               VALUES
                 ('dr_statute_r7','statute','session:raiser','agent:raiser','mike','asg_r7',
                  10,20,'ship-law','ship-action','May this ship?',
                  NULL,'{"verb":"ship"}','open')
               """
             )

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,
                  expecterSessionKey,expecterUserId,raisedAt,question,context,status,askedOfRole)
               VALUES
                 ('dr_agent_r7','agent','session:agent:raiser','agent:raiser','mike','asg_r7',
                  'agent:asked','mike',11,'Which path?','{"verb":"ask"}','open','reviewer:r7')
               """
             )

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,ownerUserId,assignmentId,expecterSessionKey,
                  lineageRung,effortGeneration,deadlineWakeId,raisedAt,deadlineAt,
                  question,options,context,status)
               VALUES
                 ('dr_effort_r7','effort','process:tightbeam','mike','asg_r7','agent:expecter',
                  4,7,'w_effort_r7',12,22,'Continue or dismiss?',
                  '["wake","continue","dismiss"]','{"actions":["wake","continue","dismiss"]}','open')
               """
             )
  end
end
