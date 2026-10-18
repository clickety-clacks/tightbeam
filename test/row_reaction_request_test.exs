defmodule Tightbeam.RowReactionRequestTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Escalation, Gateway, Identity, Model, Org, RowReactions, Schema, Wakes}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "request-reaction-#{System.unique_integer([:positive])}")
    assert :initialized = Identity.init!(base)
    Gateway.load_law!(%{base_dir: base, db: db}, [])
    on_exit(fn -> File.rm_rf!(base) end)
    DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    for key <- ["holder", "opener", "alternate", Org.personal_session_key("owner")] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        kind: if(key == Org.personal_session_key("owner"), do: "main", else: "custom"),
        archetype: "default",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture"),
        host: "synthetic-host"
      })
    end

    DB.execute(db, """
    INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state)
    VALUES('assignment','fixture','holder','opener',1,'open')
    """)

    %{db: db, base: base}
  end

  defp elect(ctx, edit \\ &Function.identity/1) do
    path = Path.join(ctx.base, "identity/rules/row-reaction-status.toml")
    bytes = File.read!("priv/kungfu/agentic-engineering/rules/row-reaction-status.toml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, edit.(bytes))
    receipt = Path.join(ctx.base, "identity/kungfu/agentic-engineering/installed.toml")
    File.mkdir_p!(Path.dirname(receipt))
    File.write!(receipt, "name='agentic-engineering'\npaths=['rules/row-reaction-status.toml']\n")
    Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, [])
    path
  end

  defp call(key, verb, params, target \\ nil) do
    %{
      verb: verb,
      origin: "session:" <> key,
      principal: {:session, key},
      transport_session_key: key,
      session_key: target,
      params: params
    }
  end

  defp ask(ctx, target \\ "alternate") do
    Escalation.ask(
      ctx.db,
      call(
        "holder",
        "ask",
        %{question: "What should change?", assignment_id: "assignment"},
        target
      )
    )
  end

  defp observations(ctx) do
    {:ok, rows} =
      DB.query(
        ctx.db,
        "SELECT event,facts FROM row_reaction_events WHERE json_extract(event,'$.kind')='decision_request' ORDER BY admittedAt,eventId"
      )

    Enum.map(rows, fn [event, facts] -> {JSON.decode!(event), JSON.decode!(facts)} end)
  end

  test "real ask and answer record explicit outputs and elect separate opener status once", ctx do
    elect(ctx)
    request = ask(ctx)
    assert request.status == "open"
    assert length(Wakes.list_pending(ctx.db)) == 2
    assert [{event, facts}] = observations(ctx)
    assert event["before"] == nil
    assert event["after"]["id"] == request.id
    assert event["principal"] == %{"kind" => "session", "id" => "holder"}
    assert [%{"operation" => "ask", "wakeId" => wake_id}] = event["outputs"]

    assert [%{"wakeId" => ^wake_id, "sessionKey" => "alternate", "requestId" => id}] =
             facts["explicit_notices"]

    assert id == request.id

    answer_call =
      call("alternate", "answer", %{request: request.id, answer: "Use the existing path"})

    assert %{status: "answered"} = Escalation.answer(ctx.db, answer_call)
    assert length(Wakes.list_pending(ctx.db)) == 4
    records = observations(ctx)
    assert length(records) == 2

    {event, facts} =
      Enum.find(records, fn {event, _} -> event["after"]["status"] == "answered" end)

    assert event["before"]["status"] == "open"
    assert event["before"]["answeredAt"] == nil
    assert event["after"]["answeredAt"] == event["at"]
    assert Enum.sort(Enum.map(facts["explicit_notices"], & &1["operation"])) == ["answer", "ask"]
    assert Enum.any?(facts["related_actions"], &(&1["slot"] == "blocker-raised"))
    pending = Wakes.list_pending(ctx.db)
    assert %{status: "answered"} = Escalation.answer(ctx.db, answer_call)
    assert :ok = RowReactions.recover(ctx.db)
    assert observations(ctx) == records
    assert Wakes.list_pending(ctx.db) == pending
  end

  test "explicit request output to the opener suppresses duplicate status", ctx do
    elect(ctx)
    request = ask(ctx, "opener")
    assert request.status == "open"
    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == "opener"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")
    assert length(observations(ctx)) == 1
  end

  test "explicit answer to an opener who is the asker suppresses resolution status", ctx do
    DB.execute(ctx.db, "UPDATE assignments SET openedBySession='holder' WHERE id='assignment'")
    elect(ctx)
    request = ask(ctx)

    assert %{status: "answered"} =
             Escalation.answer(
               ctx.db,
               call("alternate", "answer", %{request: request.id, answer: "Resolved"})
             )

    assert length(Wakes.list_pending(ctx.db)) == 2
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")
  end

  test "absent election preserves explicit communications without replay after enabling", ctx do
    request = ask(ctx)
    assert request.status == "open"
    assert [_explicit] = Wakes.list_pending(ctx.db)
    elect(ctx)
    assert [_explicit] = Wakes.list_pending(ctx.db)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")
    assert length(observations(ctx)) == 1
  end

  test "elected recipient changes and removal revises only automatic pending output", ctx do
    path =
      elect(ctx, &String.replace(&1, "{ ref = \"assignment.openedBySession\" }", "\"alternate\""))

    request = ask(ctx, "opener")
    assert request.status == "open"
    notices = Wakes.list_pending(ctx.db)
    assert Enum.sort(Enum.map(notices, & &1.session_key)) == ["alternate", "opener"]
    automatic = Enum.find(notices, &(&1.session_key == "alternate"))
    explicit = Enum.find(notices, &(&1.session_key == "opener"))

    DB.execute(ctx.db, """
    INSERT INTO supervision_entitlements
      (assignmentId,generation,dueAt,state,lastAttemptGeneration,claimClock,
       basisKind,basisId,terminusAt,cause,principal,supervisionIntervalMs)
    VALUES('assignment',1,9999999999999,'armed',NULL,NULL,
           'assignment_open','assignment',NULL,'assignment_open','process:tightbeam',60000)
    """)

    File.rm!(path)
    Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, [])
    assert Wakes.get(ctx.db, automatic.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, explicit.wake_id).state == "pending"
  end

  test "source rollback rolls back explicit and elected outputs with the request", ctx do
    elect(ctx)

    assert {:error, %RuntimeError{message: "abort"}} =
             DB.transaction(ctx.db, fn txn ->
               Escalation.file_agent_request_in_txn(txn, %{
                 assignment_id: "assignment",
                 asker_session_key: "holder",
                 owner_user_id: "owner",
                 asked: %{session_key: "alternate", owner_user_id: "owner"},
                 asked_of_role: nil,
                 role_fallback: false,
                 question: "Rolled back"
               })

               raise "abort"
             end)

    assert observations(ctx) == []
    assert Wakes.list_pending(ctx.db) == []
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
  end

  test "operator ask and ruling preserve explicit outputs and actual user attribution", ctx do
    elect(ctx)

    request_call =
      call("holder", "operator-ask", %{question: "Proceed?", assignment_id: "assignment"})

    request = Escalation.operator_ask(ctx.db, request_call)
    assert request.status == "open"
    assert length(Wakes.list_pending(ctx.db)) == 2
    assert %{id: id} = Escalation.operator_ask(ctx.db, request_call)
    assert id == request.id
    assert length(observations(ctx)) == 1

    ruling = %{
      verb: "operator-rule",
      origin: "user:owner",
      principal: {:user, "owner"},
      transport_session_key: nil,
      params: %{request: request.id, decision: "accept"}
    }

    assert %{status: "ruled"} = Escalation.operator_rule(ctx.db, ruling)
    records = observations(ctx)
    assert length(records) == 2
    {event, facts} = Enum.find(records, fn {event, _} -> event["after"]["status"] == "ruled" end)
    assert event["principal"] == %{"kind" => "user", "id" => "owner"}
    assert event["before"]["status"] == "open"
    assert event["after"]["ruledAt"] == event["at"]

    assert Enum.sort(Enum.map(facts["explicit_notices"], & &1["operation"])) == [
             "operator-ask",
             "operator-rule"
           ]

    pending = Wakes.list_pending(ctx.db)
    assert %{status: "ruled"} = Escalation.operator_rule(ctx.db, ruling)
    assert observations(ctx) == records
    assert Wakes.list_pending(ctx.db) == pending
  end

  test "standing-condition release captures settlement facts but ordinary withdrawal does not resolve a blocker",
       ctx do
    elect(ctx)

    DB.execute(ctx.db, """
    INSERT INTO supervision_entitlements
      (assignmentId,generation,dueAt,state,lastAttemptGeneration,claimClock,
       basisKind,basisId,terminusAt,cause,principal,supervisionIntervalMs)
    VALUES('assignment',1,9999999999999,'armed',NULL,NULL,
           'assignment_open','assignment',NULL,'assignment_open','process:tightbeam',60000)
    """)

    filing =
      call("holder", "attest", %{
        assignment_id: "assignment",
        kind: "cannot-proceed",
        note: "Dependency unavailable",
        release_fact_kind: "dependency-ready",
        release_fact_scope: "assignment",
        release_fact_principal_ref: "session:alternate"
      })

    result = Tightbeam.Assignments.__handle__(ctx.db, "attest", filing)
    assert result.cannotProceed.state == "standing"
    assert [notice] = Wakes.list_pending(ctx.db)
    assert notice.wake_id == result.decisionWake.wake_id

    assert {:ok, fact} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.ConditionFacts.file_in_txn(txn, %{
                 kind: "dependency-ready",
                 scope: "assignment",
                 origin: "session:alternate"
               })
             end)

    {event, facts} =
      Enum.find(observations(ctx), fn {event, _} -> event["after"]["status"] == "withdrawn" end)

    assert event["before"]["status"] == "open"
    assert event["before"]["withdrawnAt"] == nil
    assert event["after"]["withdrawnAt"] == event["at"]
    assert event["outputs"] == []
    assert facts["cannot_proceed"]["state"] == "settled"
    assert facts["cannot_proceed"]["settlementKind"] == "release-fact"
    assert facts["settlement_fact"]["id"] == fact.fact_id
    assert facts["settlement_fact"]["origin"] == "session:alternate"

    assert [resolution] =
             Enum.filter(
               Wakes.list_pending(ctx.db),
               &String.contains?(&1.prompt, "no longer has a standing")
             )

    assert resolution.session_key == "opener"
    records = observations(ctx)
    assert %{replayed: true} = Tightbeam.Assignments.__handle__(ctx.db, "attest", filing)
    assert observations(ctx) == records

    request = ask(ctx)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Escalation.settle_agent_request_in_txn(
                 txn,
                 request.id,
                 "process:tightbeam",
                 "ordinary withdrawal"
               )
             end)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions WHERE eventId=?1", [
               "decision_request:#{request.id}:status:withdrawn"
             ])
  end

  defp statute_request(ctx) do
    Escalation.escalate(
      ctx.db,
      call("holder", "attest", %{assignment_id: "assignment", kind: "completion"}),
      %{name: "review", text: "Review required"},
      %{question: "Allow completion?", options: nil}
    )
  end

  defp statute_ruling(id, verb) do
    %{
      verb: verb,
      origin: "user:owner",
      principal: {:user, "owner"},
      params: %{request: id, decision: "allow", reason: "Accepted exception"}
    }
  end

  test "statute opening captures actual owner output and original attempted command", ctx do
    elect(ctx)
    assert {:decision_pending, id} = statute_request(ctx)
    assert [{event, facts}] = observations(ctx)
    assert event["verb"] == "escalate"
    assert event["before"] == nil
    assert event["after"]["context"]["verb"] == "attest"
    assert event["principal"] == %{"kind" => "session", "id" => "holder"}
    assert [%{"operation" => "escalate", "wakeId" => wake_id}] = event["outputs"]
    assert [%{"wakeId" => ^wake_id, "requestId" => ^id}] = facts["explicit_notices"]

    assert Enum.sort(Enum.map(Wakes.list_pending(ctx.db), & &1.session_key)) ==
             Enum.sort(["opener", Org.personal_session_key("owner")])

    records = observations(ctx)
    pending = Wakes.list_pending(ctx.db)
    assert {:decision_pending, ^id} = statute_request(ctx)
    assert observations(ctx) == records
    assert Wakes.list_pending(ctx.db) == pending
  end

  test "statute owner communication suppresses same-recipient raised status only", ctx do
    DB.query(ctx.db, "UPDATE assignments SET openedBySession=?1 WHERE id='assignment'", [
      Org.personal_session_key("owner")
    ])

    elect(ctx)
    assert {:decision_pending, id} = statute_request(ctx)
    assert [_explicit] = Wakes.list_pending(ctx.db)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")

    assert %{status: "ruled"} =
             Escalation.rule(ctx.db, statute_ruling(id, "rule"), authorized: true)

    assert length(Wakes.list_pending(ctx.db)) == 2
  end

  test "statute rule and waiver observe actual first resolution without fabricated outputs",
       ctx do
    elect(ctx)

    for operation <- ["rule", "waive"] do
      assert {:decision_pending, id} = statute_request(ctx)
      ruling = statute_ruling(id, operation)

      result =
        apply(Escalation, String.to_existing_atom(operation), [ctx.db, ruling, [authorized: true]])

      refute Map.has_key?(result, :error)
      records = observations(ctx)

      {event, _facts} =
        Enum.find(records, fn {event, _} ->
          event["after"]["id"] == id and event["after"]["status"] == "ruled"
        end)

      assert event["verb"] == operation
      assert event["principal"] == %{"kind" => "user", "id" => "owner"}
      assert event["before"]["status"] == "open"
      assert event["before"]["ruledAt"] == nil
      assert event["after"]["ruledAt"] == event["at"]
      assert is_integer(Escalation.raw_by_id(ctx.db, id).ruling_fact_id)
      assert event["outputs"] == []

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM row_reaction_actions WHERE eventId=?1 AND slot='blocker-resolved'",
                 [event["id"]]
               )

      pending = Wakes.list_pending(ctx.db)
      apply(Escalation, String.to_existing_atom(operation), [ctx.db, ruling, [authorized: true]])
      assert observations(ctx) == records
      assert Wakes.list_pending(ctx.db) == pending
    end
  end

  test "absent statute election preserves source and explicit owner communication", ctx do
    assert {:decision_pending, id} = statute_request(ctx)

    assert %{status: "ruled"} =
             Escalation.rule(ctx.db, statute_ruling(id, "rule"), authorized: true)

    assert [_explicit] = Wakes.list_pending(ctx.db)
    assert length(observations(ctx)) == 2
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")
    elect(ctx)
    assert [_explicit] = Wakes.list_pending(ctx.db)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")
  end

  test "statute observation failure rolls back the ruling and its fact", ctx do
    elect(ctx)
    assert {:decision_pending, id} = statute_request(ctx)
    records = observations(ctx)
    pending = Wakes.list_pending(ctx.db)
    assert {:ok, [[fact_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM condition_facts")

    DB.execute(ctx.db, """
    CREATE TRIGGER reject_statute_resolution BEFORE INSERT ON row_reaction_events
    WHEN json_extract(NEW.event,'$.kind')='decision_request'
      AND json_extract(NEW.event,'$.after.status')='ruled'
    BEGIN SELECT RAISE(ABORT,'injected observation failure'); END;
    """)

    for operation <- ["rule", "waive"] do
      assert_raise MatchError, fn ->
        apply(Escalation, String.to_existing_atom(operation), [
          ctx.db,
          statute_ruling(id, operation),
          [authorized: true]
        ])
      end

      assert %{status: "open", ruling_fact_id: nil} = Escalation.raw_by_id(ctx.db, id)
      assert {:ok, [[^fact_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM condition_facts")
      assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM escalation_waivers")
      assert observations(ctx) == records
      assert Wakes.list_pending(ctx.db) == pending
    end
  end
  test "successive public interventions retain addressed provenance without nested histories", ctx do
    elect(ctx)
    sizes = for n <- 1..32 do
      request = ask(ctx)
      [{raised, facts} | _] = Enum.filter(observations(ctx), fn {event, _} -> event["after"]["id"] == request.id end)
      assert facts["related_actions"] == []
      assert length(facts["sessions"]) <= 4
      assert %{status: "answered"} = Escalation.answer(ctx.db, call("alternate", "answer", %{request: request.id, answer: "Resolved"}))
      {_, resolved} = Enum.find(observations(ctx), fn {event, _} -> event["after"]["id"] == request.id and event["after"]["status"] == "answered" end)
      assert [prior] = resolved["related_actions"]
      assert prior["event"]["id"] == raised["id"]
      assert prior["facts"] == %{"decision_request" => %{"id" => request.id}}
      assert prior["source_ref"] == %{"org" => "owner", "event_id" => raised["id"]}
      assert {:ok, [[saved]]} = DB.query(ctx.db, "SELECT facts FROM row_reaction_events WHERE org=?1 AND eventId=?2", [prior["source_ref"]["org"], prior["source_ref"]["event_id"]])
      assert JSON.decode!(saved) == facts
      # Settle this actual source's automatic outputs; growing settled history
      # must not become recovery's current work set.
      assert :ok = DB.execute(ctx.db, "UPDATE row_reaction_actions SET status='accepted'")
      if n == 32 do
        assert {:ok, plans} = DB.transaction(ctx.db, fn txn ->
          Process.put(:request_queries, [])
          traced = Tightbeam.DB.Txn.observe_queries(txn, fn {:sql_query,sql,params} -> Process.put(:request_queries, [{sql,params}|Process.get(:request_queries)]) end)
          Tightbeam.RowReactions.Snapshot.current(traced, raised, %{})
          for {sql,params} <- Process.delete(:request_queries) do
            {sql,Tightbeam.DB.Txn.q(txn,"EXPLAIN QUERY PLAN " <> sql,params)}
          end
        end)
        assert Enum.any?(plans, fn {_,plan} -> Enum.any?(plan, &(List.last(&1) =~ "row_reaction_request")) end)
        for {_,plan} <- plans do
          refute Regex.match?(~r/SCAN (?:attests|sessions|e|a)(?:$|\s)/m, Enum.map_join(plan,"\n",&List.last/1))
        end
        IO.puts("request_address_plans=#{inspect(plans)}")
      end
      size = byte_size(JSON.encode!(facts)) + byte_size(JSON.encode!(resolved))
      if n in [8,16,32], do: IO.puts("intervention count=#{n} current_snapshot_bytes=#{size}")
      size
    end
    assert Enum.max(sizes) < 2 * Enum.min(sizes)
    assert Enum.sum(sizes) < 32 * 20_000
    assert {:ok, [[64]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_events WHERE json_extract(event,'$.kind')='decision_request'")
  end

end
