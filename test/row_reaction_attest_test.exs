defmodule Tightbeam.RowReactionAttestTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    DB,
    Escalation,
    Gateway,
    Identity,
    Model,
    Org,
    RowReactions,
    Schema,
    Wakes
  }

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "attest-reaction-#{System.unique_integer([:positive])}")
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

  defp file(ctx, kind, extra \\ %{}) do
    params = Map.merge(%{assignment_id: "assignment", kind: kind}, extra)
    Assignments.__handle__(ctx.db, "attest", call("holder", "attest", params))
  end

  defp attest_events(ctx) do
    {:ok, rows} =
      DB.query(
        ctx.db,
        "SELECT event,facts FROM row_reaction_events WHERE json_extract(event,'$.kind')='attest' ORDER BY admittedAt,eventId"
      )

    Enum.map(rows, fn [event, facts] -> {JSON.decode!(event), JSON.decode!(facts)} end)
  end

  defp legacy_wake(ctx, attest, suffix \\ "") do
    {:ok, wake} =
      DB.transaction(ctx.db, fn txn ->
        Wakes.schedule_in_txn(txn, %{
          session_key: "opener",
          owner_user_id: "owner",
          origin:
            if(attest.bySession, do: "agent:" <> attest.bySession, else: "user:" <> attest.byUser),
          creator_session_key: attest.bySession,
          assignment_id: "assignment",
          due_at: attest.ts,
          prompt:
            "Attest #{attest.id} (#{attest.kind}) was filed on assignment assignment." <> suffix
        })
      end)

    wake
  end

  defp reopen_cutover(ctx) do
    # Simulate upgrading an existing database before the new cutover watermark.
    DB.execute(ctx.db, "DELETE FROM row_reaction_cutovers WHERE source='attest-notice/v1'")
  end

  defp entitlement(ctx) do
    DB.execute(ctx.db, """
    INSERT INTO supervision_entitlements
      (assignmentId,generation,dueAt,state,lastAttemptGeneration,claimClock,
       basisKind,basisId,terminusAt,cause,principal,supervisionIntervalMs)
    VALUES('assignment',1,9999999999999,'armed',NULL,NULL,
           'assignment_open','assignment',NULL,'assignment_open','process:tightbeam',60000)
    """)
  end

  test "shipped engineering composition elects status and handoff declarations", ctx do
    assert {:ok, candidate} = Identity.learn!(ctx.base, "agentic-engineering", "test")
    assert {:ok, _revision} = Identity.publish_live!(ctx.base, candidate)
    Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, [])
    names = Enum.map(Tightbeam.Rules.reactions(), & &1.name)
    assert "assignment-first-start-notice" in names
    assert "assignment-terminal-handoff" in names
    assert "assignment-blocker-raised-notice" in names
    progress = file(ctx, "progress")
    assert progress.attest.kind == "progress"
    assert Wakes.list_pending(ctx.db) == []
    assert [{event, _facts}] = attest_events(ctx)
    assert event["after"]["id"] == progress.attest.id
  end

  test "current notice schema never fabricates missing decision activation evidence", ctx do
    assert :ok = DB.execute(ctx.db, "DELETE FROM decision_request_terminal_epoch")
    assert {:ok, :ok} = DB.transaction(ctx.db, fn txn ->
      Escalation.ensure_terminal_parity_in_txn(txn, 99, true)
    end)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_request_terminal_epoch")
  end

  test "elected engineering keeps routine progress and ordinary verdicts durable and quiet",
       ctx do
    elect(ctx)
    progress = file(ctx, "progress")
    verdict = file(ctx, "verdict", %{verdict_kind: "observed"})
    assert progress.attest.kind == "progress"
    assert verdict.attest.verdictKind == "observed"
    assert Wakes.list_pending(ctx.db) == []
    assert length(attest_events(ctx)) == 2

    for {event, facts} <- attest_events(ctx) do
      assert event["before"] == nil
      assert event["principal"] == %{"kind" => "session", "id" => "holder"}
      assert event["after"]["assignmentId"] == "assignment"
      assert facts["decision_request"] == nil
      assert Enum.any?(facts["attests"], &(&1["id"] == event["after"]["id"]))
    end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")
  end

  test "legacy pending progress is canceled once through liveness while accepted history is retained",
       ctx do
    elect(ctx)
    entitlement(ctx)
    pending_attest = file(ctx, "progress").attest
    accepted_attest = file(ctx, "verdict", %{verdict_kind: "observed"}).attest
    pending = legacy_wake(ctx, pending_attest)
    accepted = legacy_wake(ctx, accepted_attest)
    # Seed the pre-upgrade delivered state; this case does not claim delivery.
    DB.query(ctx.db, "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1", [
      accepted.wake_id,
      accepted.due_at
    ])

    reopen_cutover(ctx)
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, pending.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, accepted.wake_id).state == "fired"

    assert {:ok, [["canceled"], ["accepted"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM row_reaction_actions WHERE eventId IN (?1,?2) ORDER BY CASE eventId WHEN ?1 THEN 0 ELSE 1 END",
               ["legacy_notice:" <> pending.wake_id, "legacy_notice:" <> accepted.wake_id]
             )

    assert {:ok, [["supervision_entitlement"]]} =
             DB.query(
               ctx.db,
               "SELECT livenessTriggerKind FROM wake_cancellations WHERE wakeId=?1",
               [pending.wake_id]
             )

    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.list_pending(ctx.db) == []
  end

  test "unmatched messages are not attributed to the legacy producer", ctx do
    elect(ctx)
    attest = file(ctx, "progress").attest
    unknown = legacy_wake(ctx, %{attest | id: "missing"})
    unrelated = legacy_wake(ctx, attest, " authored follow-up")
    reopen_cutover(ctx)
    assert :ok = RowReactions.recover(ctx.db)

    assert {:ok, true} =
             DB.transaction(ctx.db, &RowReactions.delivery_ready_in_txn?(&1, unknown.wake_id))

    assert {:ok, true} =
             DB.transaction(ctx.db, &RowReactions.delivery_ready_in_txn?(&1, unrelated.wake_id))

    assert Wakes.get(ctx.db, unknown.wake_id).state == "pending"
    assert Wakes.get(ctx.db, unrelated.wake_id).state == "pending"
  end

  defp late_request(ctx, opener_active?) do
    request =
      Escalation.operator_ask(
        ctx.db,
        call("holder", "operator-ask", %{question: "Continue?", assignment_id: "assignment"})
      )

    assert %{state: "closed"} =
             Assignments.__handle__(
               ctx.db,
               "revoke-assignment",
               call("opener", "revoke-assignment", %{
                 assignment_id: "assignment",
                 reason: "Exercise late ruling"
               })
             )

    DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='holder'")

    unless opener_active?,
      do: DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='opener'")

    ruling = %{
      verb: "operator-rule",
      origin: "user:owner",
      principal: {:user, "owner"},
      transport_session_key: nil,
      params: %{request: request.id, decision: "accept"}
    }

    assert %{status: "ruled"} = Escalation.operator_rule(ctx.db, ruling)
    # Existing operator notices already carry a request relation even when no
    # new reaction-event record exists, as on an upgrade from older source.
    DB.query(
      ctx.db,
      "DELETE FROM row_reaction_events WHERE json_extract(event,'$.kind')='decision_request'"
    )

    DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey='opener'")
    request
  end

  defp receipt(ctx, request) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "user:owner",
      principal: {:user, "owner"},
      session_key: nil,
      params: %{
        assignment_id: "assignment",
        kind: "verdict",
        verdict_kind: "ruling-consumed:" <> request.id,
        note: "operational-action: follow the recorded decision"
      }
    })
  end

  test "late receipt captures one real insertion on a closed card and replay sends nothing",
       ctx do
    request = late_request(ctx, false)
    elect(ctx)
    before = Wakes.list_pending(ctx.db)
    result = receipt(ctx, request)
    assert result.attest.verdictKind == "ruling-consumed:" <> request.id
    assert result.assignment.state == "closed"
    assert [{event, facts}] = attest_events(ctx)
    assert event["before"] == nil
    assert event["after"]["id"] == result.attest.id
    assert facts["assignment"]["state"] == "closed"
    assert facts["decision_request"]["id"] == request.id

    assert [%{"operation" => "operator-rule", "sessionKey" => personal}] =
             facts["explicit_notices"]

    assert personal == Org.personal_session_key("owner")
    added = Wakes.list_pending(ctx.db) -- before
    assert [notice] = added
    assert notice.session_key == "opener"
    assert notice.prompt =~ "has a consumed ruling"
    assert %{replayed: true} = receipt(ctx, request)
    assert length(attest_events(ctx)) == 1
    assert Wakes.list_pending(ctx.db) -- before == [notice]

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state,outcome FROM assignments WHERE id='assignment'")
  end

  test "legacy explicit ruling output to the opener suppresses a late receipt status", ctx do
    request = late_request(ctx, true)
    elect(ctx)
    before = Wakes.list_pending(ctx.db)
    assert %{attest: %{kind: "verdict"}} = receipt(ctx, request)
    assert [{_, facts}] = attest_events(ctx)

    assert [%{"operation" => "operator-rule", "sessionKey" => "opener"}] =
             facts["explicit_notices"]

    assert Wakes.list_pending(ctx.db) == before
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM row_reaction_actions")
  end

  test "a proven pending legacy receipt keeps its output identity under the elected rail", ctx do
    request = late_request(ctx, false)
    before = Wakes.list_pending(ctx.db)
    result = receipt(ctx, request)
    assert result.attest.kind == "verdict"
    assert Wakes.list_pending(ctx.db) == before
    legacy = legacy_wake(ctx, result.attest)
    reopen_cutover(ctx)
    elect(ctx)
    revised = Wakes.get(ctx.db, legacy.wake_id)
    assert revised.state == "pending"
    assert revised.session_key == "opener"
    assert revised.prompt =~ "has a consumed ruling"

    assert {:ok, [["pending", id]]} =
             DB.query(
               ctx.db,
               "SELECT status,json_extract(result,'$.wake_id') FROM row_reaction_actions WHERE eventId=?1",
               ["legacy_notice:" <> legacy.wake_id]
             )

    assert id == legacy.wake_id
    assert %{replayed: true} = receipt(ctx, request)
    assert :ok = RowReactions.recover(ctx.db)
    assert Enum.map(Wakes.list_pending(ctx.db) -- before, & &1.wake_id) == [legacy.wake_id]

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM attests WHERE id=?1", [result.attest.id])
  end

  test "event admission failure rolls back the attest source transaction", ctx do
    elect(ctx)

    DB.execute(ctx.db, """
    CREATE TRIGGER reject_attest_observation BEFORE INSERT ON row_reaction_events
    WHEN json_extract(NEW.event,'$.kind')='attest'
    BEGIN SELECT RAISE(ABORT,'injected observation failure'); END;
    """)

    assert_raise DB.Error, fn -> file(ctx, "progress") end
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM attests")
    assert Wakes.list_pending(ctx.db) == []
    assert attest_events(ctx) == []
  end
end
