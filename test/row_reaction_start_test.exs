defmodule Tightbeam.RowReactionStartTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Gateway, Identity, Ledger, Model, Org, RowReactions, Schema, Wakes}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "start-reaction-#{System.unique_integer([:positive])}")
    assert :initialized = Identity.init!(base)
    Gateway.load_law!(%{base_dir: base, db: db}, [])
    on_exit(fn -> File.rm_rf!(base) end)
    DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    for key <- ["holder", "opener", "alternate"] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        kind: "custom",
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
    File.write!(path, edit.(bytes))
    receipt = Path.join(ctx.base, "identity/kungfu/agentic-engineering/installed.toml")
    File.mkdir_p!(Path.dirname(receipt))
    File.write!(receipt, "name='agentic-engineering'\npaths=['rules/row-reaction-status.toml']\n")
    Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, [])
    path
  end

  defp enqueue(ctx) do
    {:ok, seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "holder",
        message_id: "message-#{System.unique_integer([:positive])}",
        origin: "user:owner",
        prompt: "work",
        assignment_id: "assignment",
        job_ref: "work-reference"
      })

    seq
  end

  defp claims(ctx) do
    {:ok, rows} =
      DB.query(
        ctx.db,
        "SELECT event,facts FROM row_reaction_events WHERE json_extract(event,'$.after.status')='running' ORDER BY admittedAt,eventId"
      )

    Enum.map(rows, fn [event, facts] -> {JSON.decode!(event), JSON.decode!(facts)} end)
  end

  test "real claim elects the first holder start once and captures the queued row", ctx do
    elect(ctx)
    seq = enqueue(ctx)
    assert Wakes.list_pending(ctx.db) == []
    assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert turn.seq == seq
    assert [notice] = Wakes.list_pending(ctx.db)
    assert notice.session_key == "opener"
    assert notice.assignment_id == "assignment"
    assert notice.prompt =~ "began its first turn"
    assert [{event, facts}] = claims(ctx)
    assert event["before"]["status"] == "queued"
    assert event["before"]["startedAt"] == nil
    assert event["after"]["startedAt"] == event["at"]
    assert event["after"]["workItemId"] == "work-reference"
    assert event["principal"] == %{"kind" => "process", "id" => "tightbeam"}
    assert facts["assignment"]["holderKey"] == "holder"
    assert [raw_turn] = facts["turns"]
    assert raw_turn["seq"] == seq
    assert raw_turn["workItemId"] == "work-reference"
    assert :busy = Ledger.claim_next(ctx.db, "holder", "retry")
    assert length(claims(ctx)) == 1
    assert :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: turn.owner_lease)
    enqueue(ctx)
    assert {:ok, _} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert Wakes.list_pending(ctx.db) == [notice]

    assert {:ok, [["agentic-engineering"]]} =
             DB.query(
               ctx.db,
               "SELECT json_extract(plan,'$.provenance.bundle') FROM row_reaction_actions"
             )
  end

  test "absent engineering election is quiet and enabling cannot replay an earlier start", ctx do
    seq = enqueue(ctx)
    assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert Wakes.list_pending(ctx.db) == []
    elect(ctx)
    assert Wakes.list_pending(ctx.db) == []
    assert :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: turn.owner_lease)
    enqueue(ctx)
    assert {:ok, _} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert Wakes.list_pending(ctx.db) == []
    assert length(claims(ctx)) == 2
  end

  test "changed recipient and text come from election and pending withdrawal retains liveness",
       ctx do
    path =
      elect(ctx, fn bytes ->
        bytes
        |> String.replace("{ ref = \"assignment.openedBySession\" }", "\"alternate\"")
        |> String.replace("Work started on assignment ", "Selected start for ")
      end)

    enqueue(ctx)
    assert {:ok, _} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert [notice] = Wakes.list_pending(ctx.db)
    assert notice.session_key == "alternate"
    assert notice.prompt =~ "Selected start for"

    [{event, facts}] = claims(ctx)

    assert {:error, %ArgumentError{message: "reaction notice cancellation refused"}} =
             DB.transaction(ctx.db, fn txn ->
               RowReactions.reconcile_in_txn(
                 txn,
                 "owner",
                 event["id"],
                 facts,
                 [],
                 event["at"] + 1
               )
             end)

    assert Wakes.get(ctx.db, notice.wake_id).state == "pending"

    DB.execute(ctx.db, """
    INSERT INTO supervision_entitlements
      (assignmentId,generation,dueAt,state,lastAttemptGeneration,claimClock,
       basisKind,basisId,terminusAt,cause,principal,supervisionIntervalMs)
    VALUES('assignment',1,9999999999999,'armed',NULL,NULL,
           'assignment_open','assignment',NULL,'assignment_open','process:tightbeam',60000)
    """)

    File.rm!(path)
    Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, [])
    assert Wakes.get(ctx.db, notice.wake_id).state == "canceled"

    assert {:ok, [["supervision_entitlement", "assignment#1"]]} =
             DB.query(
               ctx.db,
               "SELECT livenessTriggerKind,livenessTriggerId FROM wake_cancellations WHERE wakeId=?1",
               [notice.wake_id]
             )

    elect(ctx)
    assert Wakes.get(ctx.db, notice.wake_id).state == "canceled"
  end

  test "another session's turn does not consume the holder's first start", ctx do
    elect(ctx)

    {:ok, seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "alternate",
        message_id: "unrelated-holder",
        origin: "user:owner",
        prompt: "related work",
        assignment_id: "assignment"
      })

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "alternate", "fixture")
    assert Wakes.list_pending(ctx.db) == []
    assert :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: turn.owner_lease)
    enqueue(ctx)
    assert {:ok, _} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert [_notice] = Wakes.list_pending(ctx.db)
  end

  test "failed notice admission rolls back claim and its event", ctx do
    elect(ctx)
    seq = enqueue(ctx)

    DB.execute(
      ctx.db,
      "CREATE TRIGGER refuse_action BEFORE INSERT ON row_reaction_actions BEGIN SELECT RAISE(ABORT,'fixture refusal'); END"
    )

    assert_raise MatchError, fn -> Ledger.claim_next(ctx.db, "holder", "fixture") end

    assert {:ok, [["queued", nil]]} =
             DB.query(ctx.db, "SELECT status,startedAt FROM turns WHERE seq=?1", [seq])

    assert claims(ctx) == []
    assert Wakes.list_pending(ctx.db) == []
  end
end
