defmodule Tightbeam.StateResourcesDecisionTurnR7Test do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Escalation, Schema, StateResources}
  alias Tightbeam.Firehose.Publisher

  @turn_fields ~w(seq sessionKey messageId wakeId origin prompt roleRef roleFallback assignmentId jobRef model thinkingLevel modelContext harness replyAttention status owner adapterGen requestRef error createdAt startedAt endedAt publishedAt rowVersion)
  @decision_fields ~w(id kind raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId lineageRung effortGeneration deadlineWakeId raisedAt deadlineAt statuteName question options context status decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt rowVersion)

  setup do
    db = :"decision_turn_r7_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

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
      assert MapSet.new(Map.keys(projection)) == MapSet.new(@decision_fields)
      bytes = StateResources.encode_item("decision requests", projection)
      assert JSON.decode!(bytes) == projection
      assert_field_order(bytes, @decision_fields)
    end

    notice =
      Publisher.committed_notice("decision_request.opened", effort, %{
        "decisionRequestId" => effort["id"]
      })

    assert notice["payload"] == effort
    assert JSON.decode!(Publisher.encode_wire_notice(notice))["payload"] == effort

    assert {:ok, [[nil, nil], [nil, nil], [4, 7]]} =
             DB.query(
               db,
               "SELECT lineageRung,effortGeneration FROM decision_requests ORDER BY rowid"
             )
  end

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

  test "v16 migration assigns existing decision rows version one and activates increments", %{
    db: db
  } do
    insert_decision_rows(db)

    assert :ok = DB.execute(db, "DROP TRIGGER decision_requests_r7_row_version")
    assert :ok = DB.execute(db, "ALTER TABLE decision_requests DROP COLUMN rowVersion")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE schema_stamp SET shape='coordination-fabric-v1-phase1-v16'"
             )

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[1], [1], [1]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests ORDER BY rowid")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE decision_requests SET question='Versioned?' WHERE id='dr_agent_r7'"
             )

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id='dr_agent_r7'")
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

    notice = Publisher.committed_notice("turn.started", exact, %{"turnSeq" => seq})
    assert notice["payload"] == item
    assert notice["payload"]["prompt"] == prompt
    assert JSON.decode!(Publisher.encode_wire_notice(notice))["payload"] == item
  end

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

  defp assert_field_order(bytes, fields) do
    positions =
      Enum.map(fields, fn field ->
        {position, _length} = :binary.match(bytes, JSON.encode!(field) <> ":")
        position
      end)

    assert positions == Enum.sort(positions)
  end
end
