defmodule Tightbeam.AssignmentOpenerAcceptanceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Model, Org, Schema, Wakes}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")

    for {key, parent} <- [
          {"lead", nil},
          {"opener", "lead"},
          {"delivery", nil},
          {"holder", nil},
          {"stranger", nil},
          {"named", nil}
        ] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: if(parent, do: "agent:" <> parent, else: "user:owner"),
        spawned_by: parent,
        archetype: "default",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture"),
        host: "synthetic-host"
      })
    end

    {:ok, _} =
      DB.query(db, """
      INSERT INTO work_items
        (id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt,deliveryOwnerSessionKey)
      VALUES ('wi_succession','succession','owner','open','owner',0,1,'delivery')
      """)

    {:ok, _} =
      DB.query(db, """
      INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state,workItemId)
      VALUES ('asg_one','one','holder','opener',1,'open','wi_succession'),
             ('asg_two','two','holder','opener',2,'open','wi_succession')
      """)

    %{db: db}
  end

  defp accept(db, principal, params) do
    Gateway.handlers(%{db: db})["assignment-opener-accept"].(%{
      principal: principal,
      params: params
    })
  end

  defp opener_row(db, id) do
    {:ok, [row]} =
      DB.query(
        db,
        "SELECT state,holderKey,openedBySession,currentOpenerSessionKey FROM assignments WHERE id=?1",
        [id]
      )

    row
  end

  defp standing_cannot_proceed(db, assignment_id, disposer) do
    {:ok, %{wake_id: wake_id}} =
      DB.transaction(db, fn txn ->
        Wakes.schedule_in_txn(txn, %{
          session_key: disposer,
          origin: "agent:holder",
          prompt: "holder cannot proceed",
          due_at: System.system_time(:millisecond) + 60_000,
          target_gate: 0,
          assignment_id: assignment_id,
          work_item_id: "wi_succession"
        })
      end)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,
           expecterSessionKey,expecterUserId,raisedAt,question,context,status)
        VALUES ('dr_blocked','agent','session:holder','holder','owner',?1,
                ?2,'owner',3,'blocked','{}','open')
        """,
        [assignment_id, disposer]
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO attests(id,assignmentId,kind,bySession,ts) VALUES ('att_blocked',?1,'cannot-proceed','holder',3)",
        [assignment_id]
      )

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO assignment_cannot_proceed
          (id,assignmentId,attestId,decisionRequestId,decisionWakeId,openerRef,
           disposerRef,reason,state,createdAt)
        VALUES ('cp_blocked',?1,'att_blocked','dr_blocked',?2,?3,?3,'blocked','standing',3)
        """,
        [assignment_id, wake_id, "session:" <> disposer]
      )

    wake_id
  end

  test "the delivery owner accepts opener duty for one assignment after the opener retires",
       ctx do
    assert %{state: "retired"} = Org.retire(ctx.db, "opener", "user:owner")
    # The holder reports a block that still names the retired opener.
    blocked_wake = standing_cannot_proceed(ctx.db, "asg_one", "opener")

    result = accept(ctx.db, {:session, "delivery"}, %{assignment_id: "asg_one"})

    assert result["changed"] == true
    assert result["state"] == "open"
    assert result["previousOpenerSessionKey"] == "opener"
    assert result["currentOpenerSessionKey"] == "delivery"
    assert result["principal"] == "session:delivery"
    assert is_binary(result["eventId"])

    # The assignment stays open with its holder; only the current opener moves,
    # and the original opener stays on record.
    assert opener_row(ctx.db, "asg_one") == ["open", "holder", "opener", "delivery"]
    assert opener_row(ctx.db, "asg_two") == ["open", "holder", "opener", nil]

    # The holder's standing block, its open question and its undelivered notice
    # now wait on the successor; the original expecter stays on record.
    assert {:ok, [["session:delivery", "standing"]]} =
             DB.query(ctx.db, "SELECT disposerRef,state FROM assignment_cannot_proceed")

    assert {:ok, [["opener", "delivery", "open"]]} =
             DB.query(
               ctx.db,
               "SELECT expecterSessionKey,currentExpecterSessionKey,status FROM decision_requests WHERE id='dr_blocked'"
             )

    assert {:ok, [["delivery", "pending"]]} =
             DB.query(ctx.db, "SELECT sessionKey,state FROM wakes WHERE wakeId=?1", [blocked_wake])

    assert {:ok, [[detail]]} =
             DB.query(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='assignment_opener_accepted' AND subject='asg_one'"
             )

    assert %{"fromSessionKey" => "opener", "toSessionKey" => "delivery"} = JSON.decode!(detail)

    # Repeating the acceptance is a readback, not a second move.
    again = accept(ctx.db, {:session, "delivery"}, %{assignment_id: "asg_one"})
    assert again["changed"] == false
    assert again["currentOpenerSessionKey"] == "delivery"
  end

  test "a session with no accountability for the assignment is refused", ctx do
    assert %{state: "retired"} = Org.retire(ctx.db, "opener", "user:owner")

    assert %{ok: false, code: "not_authorized"} =
             accept(ctx.db, {:session, "stranger"}, %{assignment_id: "asg_one"})

    assert %{ok: false, code: "not_authorized"} =
             accept(ctx.db, {:session, "stranger"}, %{
               assignment_id: "asg_one",
               to_session_key: "stranger"
             })

    assert opener_row(ctx.db, "asg_one") == ["open", "holder", "opener", nil]
  end

  test "the retired opener's parent or the owner may name a successor", ctx do
    assert %{state: "retired"} = Org.retire(ctx.db, "opener", "user:owner")

    by_parent =
      accept(ctx.db, {:session, "lead"}, %{assignment_id: "asg_one", to_session_key: "named"})

    assert by_parent["currentOpenerSessionKey"] == "named"
    assert by_parent["changed"] == true

    # The parent's retry reads back, although the new opener is not its child.
    parent_repeat =
      accept(ctx.db, {:session, "lead"}, %{assignment_id: "asg_one", to_session_key: "named"})

    assert parent_repeat["changed"] == false
    assert parent_repeat["currentOpenerSessionKey"] == "named"

    by_owner =
      accept(ctx.db, {:user, "owner"}, %{assignment_id: "asg_two", to_session_key: "named"})

    assert by_owner["currentOpenerSessionKey"] == "named"
    assert by_owner["principal"] == "user:owner"

    assert %{ok: false, code: "invalid_message"} =
             accept(ctx.db, {:user, "owner"}, %{assignment_id: "asg_two"})
  end

  test "the retired opener's parent may take the duty itself and repeat the acceptance", ctx do
    assert %{state: "retired"} = Org.retire(ctx.db, "opener", "user:owner")

    first = accept(ctx.db, {:session, "lead"}, %{assignment_id: "asg_one"})
    assert first["changed"] == true
    assert first["currentOpenerSessionKey"] == "lead"

    again = accept(ctx.db, {:session, "lead"}, %{assignment_id: "asg_one"})
    assert again["changed"] == false
    assert again["currentOpenerSessionKey"] == "lead"
    assert opener_row(ctx.db, "asg_one") == ["open", "holder", "opener", "lead"]
  end

  test "an active opener keeps its duty and a closed assignment is not reopened", ctx do
    assert %{ok: false, code: "opener_active"} =
             accept(ctx.db, {:session, "delivery"}, %{assignment_id: "asg_one"})

    assert opener_row(ctx.db, "asg_one") == ["open", "holder", "opener", nil]

    assert %{state: "retired"} = Org.retire(ctx.db, "opener", "user:owner")
    assert %{state: "retired"} = Org.retire(ctx.db, "named", "user:owner")

    assert %{ok: false, code: "session_retired"} =
             accept(ctx.db, {:session, "delivery"}, %{
               assignment_id: "asg_one",
               to_session_key: "named"
             })

    Gateway.handlers(%{db: ctx.db})["revoke-assignment"].(%{
      principal: {:user, "owner"},
      params: %{assignment_id: "asg_two", reason: "superseded"}
    })

    assert opener_row(ctx.db, "asg_two") |> hd() == "closed"

    assert %{ok: false, code: "assignment_closed"} =
             accept(ctx.db, {:session, "delivery"}, %{assignment_id: "asg_two"})
  end
end
