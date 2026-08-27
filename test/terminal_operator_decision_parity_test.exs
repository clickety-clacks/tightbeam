defmodule Tightbeam.TerminalOperatorDecisionParityTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConnRegistry,
    DB,
    Dispatch,
    Escalation,
    EventLog,
    Gateway,
    Model,
    Org,
    StateResources,
    Wakes
  }

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:lane_nudged, session_key})
      {:reply, :ok, parent}
    end
  end

  setup do
    db = :"terminal_operator_db_#{System.unique_integer([:positive])}"
    scheduler = :"terminal_operator_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    ensure_main_session(db, "flynn")
    raiser = session(db, "raiser", "flynn")
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    %{db: db, scheduler: scheduler, raiser: raiser}
  end

  test "ruled operator list and exact reads share the complete terminal projection", ctx do
    request =
      Escalation.operator_ask(
        ctx.db,
        ask_call(ctx.raiser, %{
          question: " choose one ",
          options: [%{label: "alpha"}, %{label: "beta"}]
        })
      )

    rule = rule_call(request.id, %{decision: "alpha"})

    assert %{status: "ruled", decision: "alpha"} =
             ruled =
             Escalation.operator_rule(ctx.db, rule, scheduler: ctx.scheduler)

    refute Map.has_key?(ruled, :ruled_via_principal)
    refute Map.has_key?(ruled, :ruled_via_session_state)

    firehose_item =
      ctx.db
      |> Escalation.raw_by_id(request.id)
      |> StateResources.decision_request()

    assert firehose_item["rulingAttribution"]["performer"]["principal"]["state"] == "known"
    refute Map.has_key?(firehose_item, "ruledViaPrincipal")
    refute Map.has_key?(firehose_item, "ruledViaSessionState")

    [listed] = Escalation.list(ctx.db, rule, "ruled", owner_user_id: "flynn")
    detailed = Escalation.get(ctx.db, rule, request.id, owner_user_id: "flynn")

    assert listed == detailed

    assert %{
             id: id,
             kind: "operator",
             status: "ruled",
             question: "choose one",
             options: [%{"label" => "alpha"}, %{"label" => "beta"}],
             raiser_id: "agent:raiser",
             raiser_session_key: raiser_key,
             owner_user_id: "flynn",
             assignment_id: nil,
             decision: "alpha",
             rationale: nil,
             ruled_by: "user:flynn",
             ruled_via_session_key: nil,
             consumed_at: nil,
             ruling_attribution: %{
               on_behalf_of: "user:flynn",
               performer: %{
                 principal: %{state: "known", value: "user:flynn"},
                 session: %{state: "none"}
               }
             }
           } = detailed

    assert id == request.id
    assert raiser_key == ctx.raiser.session_key
    assert is_integer(detailed.raised_at)
    assert is_integer(detailed.deadline_at)
    assert is_integer(detailed.ruled_at)
    assert is_integer(detailed.ruling_fact_id)
  end

  test "one automatic condition wake is committed and exact replay creates nothing", ctx do
    request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "ship?"}))
    call = rule_call(request.id, %{response: "yes", rationale: "ordered"})

    first = Escalation.operator_rule(ctx.db, call, scheduler: ctx.scheduler)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
               [request.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='escalation-ruled' AND scope=?1",
               [request.id]
             )

    assert Enum.count(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "decision_request_ruled" and event.subject == request.id
           end) == 1

    replay = Escalation.operator_rule(ctx.db, call, scheduler: ctx.scheduler)
    assert replay.id == first.id
    assert replay.ruling_fact_id == first.ruling_fact_id

    assert {:ok, [[1, 1, 1]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT COUNT(*) FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1), (SELECT COUNT(*) FROM condition_facts WHERE kind='escalation-ruled' AND scope=?1), (SELECT COUNT(*) FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject=?1)",
               [request.id]
             )

    assert {:ok, [["fired", fired_at, "condition", prompt]]} =
             DB.query(
               ctx.db,
               "SELECT state,firedAt,firedBy,prompt FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
               [request.id]
             )

    assert is_integer(fired_at)

    assert prompt ==
             "Decision request #{request.id} was ruled. Read it with tightbeam decision-request --request #{request.id}."
  end

  test "presenting session is preserved beside the performing principal", ctx do
    request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "relay?"}))

    call =
      rule_call(request.id, %{response: "after 013"})
      |> Map.put(:transport_session_key, ctx.raiser.session_key)

    assert %{ruled_via_session_key: session_key} =
             Escalation.operator_rule(ctx.db, call, scheduler: ctx.scheduler)

    assert session_key == ctx.raiser.session_key

    assert %{
             ruling_attribution: %{
               performer: %{
                 principal: %{state: "known", value: "user:flynn"},
                 session: %{state: "known", key: ^session_key}
               }
             }
           } = Escalation.get(ctx.db, call, request.id, owner_user_id: "flynn")
  end

  test "visible impossible terminal shape refuses and records privacy-safe evidence", ctx do
    request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "tamper?"}))
    call = rule_call(request.id, %{decision: "accept"})
    Escalation.operator_rule(ctx.db, call, scheduler: ctx.scheduler)

    :ok =
      DB.execute(
        ctx.db,
        "DELETE FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject='#{request.id}'"
      )

    assert %{
             code: "decision_request_integrity_invalid",
             request_id: request_id
           } = Escalation.get(ctx.db, call, request.id, owner_user_id: "flynn")

    assert request_id == request.id

    assert {:ok,
            [
              [
                evidence_request_id,
                "terminal-operator-decision-parity-v1",
                "terminal-shape-invalid",
                failing_fields,
                "detail",
                "user:flynn"
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT requestId,schemaVersion,causeCode,failingFields,firstSurface,observerPrincipal FROM decision_request_integrity_evidence"
             )

    assert evidence_request_id == request.id
    assert JSON.decode!(failing_fields) == ["rulingLifecycleEvent"]
    refute failing_fields =~ "flynn"
    refute failing_fields =~ "tamper"
  end

  test "future incomplete terminal transition is refused by the database trigger", ctx do
    request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "trigger?"}))

    for attribution <- [
          "",
          ",ruledViaPrincipal='user:flynn'",
          ",ruledViaPrincipal='user:flynn',ruledViaSessionState='known'",
          ",ruledViaPrincipal='user:flynn',ruledViaSessionState='none',ruledViaSessionKey='agent:presenter'",
          ",ruledViaSessionState='none'"
        ] do
      assert {:error, %DB.Error{message: message}} =
               DB.query(
                 ctx.db,
                 "UPDATE decision_requests SET status='ruled',decision='accept',ruledBy='user:flynn',ruledAt=1,rulingFactId=1#{attribution} WHERE id=?1",
                 [request.id]
               )

      assert message =~ "decision_request_integrity_invalid"
    end

    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT status FROM decision_requests WHERE id=?1", [request.id])

    assert {:error, %DB.Error{message: insert_message}} =
             DB.query(
               ctx.db,
               "INSERT INTO decision_requests (id,kind,raiserId,raiserSessionKey,ownerUserId,raisedAt,deadlineAt,actionKey,question,options,context,status,decision,ruledBy,ruledAt,rulingFactId) VALUES ('dr_incomplete_insert','operator','agent:raiser','agent:raiser:app','flynn',1,2,'insert','insert?','[{\"label\":\"accept\"}]','{}','ruled','accept','user:flynn',1,1)"
             )

    assert insert_message =~ "decision_request_integrity_invalid"
  end

  test "ruling wake preserves the request's stored decision duration", ctx do
    request =
      Escalation.operator_ask(
        ctx.db,
        ask_call(ctx.raiser, %{question: "custom deadline?", deadline: 12_345})
      )

    ruled =
      Escalation.operator_rule(
        ctx.db,
        rule_call(request.id, %{decision: "accept"}),
        scheduler: ctx.scheduler
      )

    assert {:ok, [[due_at]]} =
             DB.query(
               ctx.db,
               "SELECT dueAt FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
               [request.id]
             )

    assert due_at == ruled.ruled_at + 12_345
  end

  test "list validates every admitted invalid row and refuses the lexical first id", ctx do
    requests =
      for question <- ["batch one?", "batch two?", "batch three?"] do
        request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: question}))

        Escalation.operator_rule(
          ctx.db,
          rule_call(request.id, %{decision: "accept"}),
          scheduler: ctx.scheduler
        )

        request
      end

    [missing_event, missing_fact, _valid] = requests

    :ok =
      DB.execute(
        ctx.db,
        "DELETE FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject='#{missing_event.id}'"
      )

    :ok =
      DB.execute(
        ctx.db,
        "DELETE FROM condition_facts WHERE id=#{missing_fact.ruling_fact_id || ruled_fact_id(ctx.db, missing_fact.id)}"
      )

    expected = Enum.min([missing_event.id, missing_fact.id])

    assert %{code: "decision_request_integrity_invalid", request_id: ^expected} =
             Escalation.list(
               ctx.db,
               rule_call(expected, %{decision: "accept"}),
               "ruled",
               owner_user_id: "flynn"
             )

    assert {:ok, evidence_rows} =
             DB.query(
               ctx.db,
               "SELECT DISTINCT requestId FROM decision_request_integrity_evidence ORDER BY requestId"
             )

    assert Enum.map(evidence_rows, &hd/1) == Enum.sort([missing_event.id, missing_fact.id])
  end

  test "visibility precedes validation and hidden dirt writes no evidence", ctx do
    ensure_main_session(ctx.db, "alice")
    alice_raiser = session(ctx.db, "alice-raiser", "alice")
    request = Escalation.operator_ask(ctx.db, ask_call(alice_raiser, %{question: "private?"}))
    alice_call = rule_call(request.id, %{decision: "accept"}, "alice")
    Escalation.operator_rule(ctx.db, alice_call, scheduler: ctx.scheduler)

    :ok =
      DB.execute(
        ctx.db,
        "DELETE FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject='#{request.id}'"
      )

    flynn_call = rule_call(request.id, %{decision: "accept"})
    assert Escalation.get(ctx.db, flynn_call, request.id, owner_user_id: "flynn") == nil

    refute Enum.any?(
             Escalation.list(ctx.db, flynn_call, "ruled", owner_user_id: "flynn"),
             &(&1.id == request.id)
           )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [request.id]
             )
  end

  test "an unrelated sibling session cannot borrow owner visibility", ctx do
    reviewer = session(ctx.db, "reviewer", "flynn")
    request = invalid_without_event(ctx, "sibling private?")
    reviewer_call = ask_call(reviewer, %{})

    assert Escalation.get(ctx.db, reviewer_call, request.id, owner_user_id: "flynn") == nil

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [request.id]
             )

    assert %{code: "decision_request_integrity_invalid", request_id: request_id} =
             Escalation.get(
               ctx.db,
               ask_call(ctx.raiser, %{}),
               request.id,
               owner_user_id: "flynn"
             )

    assert request_id == request.id
  end

  test "legacy attribution remains unknown without inferred owner provenance", ctx do
    direct = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "legacy direct?"}))
    via = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "legacy via?"}))

    direct_call = rule_call(direct.id, %{decision: "accept"})

    via_call =
      Map.put(
        rule_call(via.id, %{decision: "accept"}),
        :transport_session_key,
        ctx.raiser.session_key
      )

    direct_ruled = Escalation.operator_rule(ctx.db, direct_call, scheduler: ctx.scheduler)
    via_ruled = Escalation.operator_rule(ctx.db, via_call, scheduler: ctx.scheduler)
    cutoff = max(direct_ruled.ruling_fact_id, via_ruled.ruling_fact_id)

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE decision_requests SET ruledViaPrincipal=NULL,ruledViaSessionState=NULL WHERE id IN ('#{direct.id}','#{via.id}')"
      )

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE decision_request_terminal_epoch SET legacyRulingFactMaxId=#{cutoff} WHERE id=0"
      )

    assert %{
             ruling_attribution: %{
               performer: %{
                 principal: %{state: "legacy-unknown"},
                 session: %{state: "legacy-unknown"}
               }
             }
           } = Escalation.get(ctx.db, direct_call, direct.id, owner_user_id: "flynn")

    assert %{
             ruled_via_session_key: session_key,
             ruling_attribution: %{
               performer: %{
                 principal: %{state: "legacy-unknown"},
                 session: %{state: "known", key: session_key}
               }
             }
           } = Escalation.get(ctx.db, via_call, via.id, owner_user_id: "flynn")

    assert session_key == ctx.raiser.session_key
  end

  test "impossible consumed operator refuses before generic consumption", ctx do
    request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "consume?"}))

    Escalation.operator_rule(ctx.db, rule_call(request.id, %{decision: "accept"}),
      scheduler: ctx.scheduler
    )

    :ok = DB.execute(ctx.db, "PRAGMA ignore_check_constraints=ON")

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE decision_requests SET status='consumed',consumedAt=1 WHERE id='#{request.id}'"
      )

    :ok = DB.execute(ctx.db, "PRAGMA ignore_check_constraints=OFF")

    assert %{code: "decision_request_integrity_invalid", request_id: request_id} =
             Escalation.consume(ctx.db, request.id)

    assert request_id == request.id

    assert {:ok, [["consumed", 1]]} =
             DB.query(ctx.db, "SELECT status,consumedAt FROM decision_requests WHERE id=?1", [
               request.id
             ])
  end

  test "evidence conflicts and write failures are typed and prohibit serialization", ctx do
    conflict_request = invalid_without_event(ctx, "evidence conflict?")
    call = rule_call(conflict_request.id, %{decision: "accept"})

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(ctx.db, call, conflict_request.id, owner_user_id: "flynn")

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE decision_request_integrity_evidence SET causeCode='fixture-conflict' WHERE requestId='#{conflict_request.id}'"
      )

    assert %{code: "decision_request_integrity_evidence_conflict"} =
             Escalation.get(ctx.db, call, conflict_request.id, owner_user_id: "flynn")

    unavailable_request = invalid_without_event(ctx, "evidence unavailable?")

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TRIGGER refuse_integrity_evidence BEFORE INSERT ON decision_request_integrity_evidence BEGIN SELECT RAISE(ABORT, 'fixture unavailable'); END;"
      )

    assert %{code: "decision_request_integrity_evidence_unavailable"} =
             Escalation.get(
               ctx.db,
               call,
               unavailable_request.id,
               owner_user_id: "flynn"
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [unavailable_request.id]
             )
  end

  test "real gateway dispatch preserves ruled list and exact response equality", ctx do
    handlers = Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler, wake_tick_ms: 1_000})

    assert {:ok, %{decision_request: request}} =
             Dispatch.dispatch(
               ctx.db,
               handlers,
               ask_call(ctx.raiser, %{question: "gateway parity?"})
             )

    assert {:ok, %{decision_request: %{status: "ruled"}}} =
             Dispatch.dispatch(
               ctx.db,
               handlers,
               rule_call(request.id, %{response: "yes", rationale: "complete"})
             )

    read_call = rule_call(request.id, %{decision: "accept"})

    assert {:ok, %{decision_requests: [listed]}} =
             Dispatch.dispatch(
               ctx.db,
               handlers,
               %{read_call | verb: "decision-requests", params: %{status: "ruled"}}
             )

    assert {:ok, %{decision_request: detailed}} =
             Dispatch.dispatch(
               ctx.db,
               handlers,
               %{read_call | verb: "decision-request", params: %{request: request.id}}
             )

    assert listed == detailed
  end

  test "a failure after wake and fact creation rolls the full ruling back", ctx do
    request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: "rollback?"}))

    assert {:ok, [[wake_count, fact_count, event_count]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT COUNT(*) FROM wakes), (SELECT COUNT(*) FROM condition_facts), (SELECT COUNT(*) FROM lifecycle_events)"
             )

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TRIGGER refuse_operator_ruling_fixture BEFORE UPDATE OF status ON decision_requests WHEN NEW.kind='operator' AND NEW.status='ruled' BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END;"
      )

    assert_raise DB.Error, ~r/fixture rollback/, fn ->
      Escalation.operator_rule(
        ctx.db,
        rule_call(request.id, %{decision: "accept"}),
        scheduler: ctx.scheduler
      )
    end

    assert {:ok, [["open", nil, nil, nil, ^wake_count, ^fact_count, ^event_count]]} =
             DB.query(
               ctx.db,
               "SELECT status,decision,ruledAt,rulingFactId, (SELECT COUNT(*) FROM wakes), (SELECT COUNT(*) FROM condition_facts), (SELECT COUNT(*) FROM lifecycle_events) FROM decision_requests WHERE id=?1",
               [request.id]
             )
  end

  defp session(db, name, owner) do
    Org.create(db, %{
      session_key: "agent:#{name}:app",
      display_name: name,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp ask_call(session, params) do
    %{
      verb: "operator-ask",
      origin: "agent:raiser",
      principal: {:session, session.session_key},
      transport_session_key: session.session_key,
      params: params
    }
  end

  defp rule_call(id, params, owner \\ "flynn") do
    %{
      verb: "operator-rule",
      origin: "user:#{owner}",
      principal: {:user, owner},
      transport_session_key: nil,
      params: Map.put(params, :request, id)
    }
  end

  defp invalid_without_event(ctx, question) do
    request = Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, %{question: question}))

    Escalation.operator_rule(ctx.db, rule_call(request.id, %{decision: "accept"}),
      scheduler: ctx.scheduler
    )

    :ok =
      DB.execute(
        ctx.db,
        "DELETE FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject='#{request.id}'"
      )

    request
  end

  defp ruled_fact_id(db, request_id) do
    {:ok, [[fact_id]]} =
      DB.query(db, "SELECT rulingFactId FROM decision_requests WHERE id=?1", [request_id])

    fact_id
  end
end
