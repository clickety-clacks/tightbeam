defmodule Tightbeam.SessionCustodyTransferTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Gateway,
    Ledger,
    Model,
    NoticeBatcher,
    Org,
    Schema,
    SessionCustodyTransfer,
    Wakes
  }

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")

    for key <- ["old", "successor", "holder"] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture"),
        host: "synthetic-host"
      })
    end

    {:ok, _} =
      DB.query(db, """
      INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt)
      VALUES ('wi_transfer','transfer','owner','open','owner',0,1)
      """)

    {:ok, _} =
      DB.query(db, """
      INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state,workItemId)
      VALUES ('asg_held','held','old','holder',1,'open','wi_transfer'),
             ('asg_opened','opened','holder','old',2,'open','wi_transfer')
      """)

    {:ok, wake} =
      DB.transaction(db, fn txn ->
        Wakes.schedule_in_txn(txn, %{
          session_key: "old",
          origin: "agent:holder",
          prompt: "pending accountable notice",
          due_at: System.system_time(:millisecond) + 60_000,
          target_gate: 0,
          assignment_id: "asg_opened",
          work_item_id: "wi_transfer"
        })
      end)

    {:ok, _} =
      DB.query(db, """
      INSERT INTO decision_requests
        (id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,
         expecterSessionKey,expecterUserId,raisedAt,question,context,status)
      VALUES
        ('dr_raised','agent','session:old','old','owner','asg_held',
         'holder','owner',1,'question one','{}','open'),
        ('dr_asked','agent','session:holder','holder','owner','asg_opened',
         'old','owner',2,'question two','{}','open')
      """)

    %{db: db, wake_id: wake.wake_id}
  end

  test "operator transfer moves current custody and pending notice with replayable readback",
       ctx do
    {:ok, _} =
      DB.query(ctx.db, """
      INSERT INTO harklight_wake_handles
        (handle,sessionKey,host,state,createdAt,updatedAt)
      VALUES ('synthetic-handle','old','synthetic-host','active',1,1)
      """)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO harklight_wake_entries
          (handle,eventId,feedCursor,senderId,messageId,entryKind,entryAuthor,rawLine,wakeId,capturedAt)
        VALUES ('synthetic-handle','one',1,'sender','message','discussion','person','{}',?1,1)
        """,
        [ctx.wake_id]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId)
        VALUES ('synthetic-handle','one','old',?1)
        """,
        [ctx.wake_id]
      )

    {:ok, _} =
      DB.query(ctx.db, """
      INSERT INTO attests(id,assignmentId,kind,bySession,ts)
      VALUES ('att_held','asg_opened','cannot-proceed','holder',3)
      """)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO assignment_cannot_proceed
          (id,assignmentId,attestId,decisionRequestId,decisionWakeId,openerRef,
           disposerRef,reason,state,createdAt)
        VALUES ('cp_held','asg_opened','att_held','dr_asked',?1,
                'session:old','session:old','blocked','standing',3)
        """,
        [ctx.wake_id]
      )

    params = %{from_session_key: "old", to_session_key: "successor", idempotency_key: "move-one"}
    call = %{principal: {:user, "owner"}, params: params}

    result = Gateway.handlers(%{db: ctx.db})["session-custody-transfer"].(call)
    assert is_binary(result["eventId"])
    assert result["before"] != result["after"]
    assert result["principal"] == "user:owner"

    assert Enum.find(result["before"]["assignments"], &(&1["id"] == "asg_held"))[
             "holderKey"
           ] == "old"

    assert Enum.find(result["after"]["assignments"], &(&1["id"] == "asg_held"))[
             "holderKey"
           ] == "successor"

    assert rows(
             ctx.db,
             "SELECT id,holderKey,openedBySession,currentOpenerSessionKey FROM assignments ORDER BY id"
           ) ==
             [
               ["asg_held", "successor", "holder", nil],
               ["asg_opened", "holder", "old", "successor"]
             ]

    assert rows(
             ctx.db,
             "SELECT id,raiserSessionKey,currentRaiserSessionKey,expecterSessionKey,currentExpecterSessionKey FROM decision_requests ORDER BY id"
           ) ==
             [
               ["dr_asked", "holder", nil, "old", "successor"],
               ["dr_raised", "old", "successor", "holder", nil]
             ]

    assert rows(
             ctx.db,
             "SELECT sessionKey,creatorSessionKey FROM wakes WHERE wakeId='#{ctx.wake_id}'"
           ) ==
             [["successor", nil]]

    assert rows(
             ctx.db,
             "SELECT sessionKey,currentRecipientSessionKey,wakeId FROM harklight_wake_deliveries"
           ) == [["old", "successor", ctx.wake_id]]

    assert rows(
             ctx.db,
             "SELECT sessionKey,currentReceiverSessionKey FROM harklight_wake_handles"
           ) == [["old", "successor"]]

    assert rows(ctx.db, "SELECT openerRef,disposerRef FROM assignment_cannot_proceed") ==
             [["session:old", "session:successor"]]

    assert SessionCustodyTransfer.handle(ctx.db, call) == result

    assert rows(
             ctx.db,
             "SELECT COUNT(*) FROM lifecycle_events WHERE kind='session_custody_transferred'"
           ) ==
             [[1]]

    assert %{code: "idempotency_conflict"} =
             SessionCustodyTransfer.handle(ctx.db, %{
               call
               | params: %{params | to_session_key: "holder"}
             })

    assert :ok = Schema.ensure_all(ctx.db)
  end

  test "optional parent correction commits with custody and replays one exact readback", ctx do
    call = %{
      principal: {:user, "owner"},
      params: %{
        from_session_key: "old",
        to_session_key: "successor",
        parent_session_key: "holder",
        idempotency_key: "move-with-parent"
      }
    }

    result = SessionCustodyTransfer.handle(ctx.db, call)
    assert is_binary(result["eventId"])
    assert result["before"]["currentParent"] == nil
    assert result["after"]["currentParent"] == "holder"
    assert result["after"]["coordinationParents"]["asg_held"] == "holder"

    assert rows(ctx.db, "SELECT holderKey FROM assignments WHERE id='asg_held'") ==
             [["successor"]]

    assert SessionCustodyTransfer.handle(ctx.db, call) == result
    assert rows(ctx.db, "SELECT COUNT(*) FROM session_reparent_events") == [[1]]

    assert %{code: "idempotency_conflict"} =
             SessionCustodyTransfer.handle(ctx.db, %{
               call
               | params: %{call.params | parent_session_key: "successor"}
             })

    assert rows(ctx.db, "SELECT COUNT(*) FROM session_reparent_events") == [[1]]
  end

  test "item ownership follows explicit open links, not transferred assignment membership", ctx do
    {:ok, _} =
      DB.query(ctx.db, """
      INSERT INTO work_items
        (id,title,ownerUserId,state,deliveryOwnerSessionKey,createdBySession,createdAt)
      VALUES ('wi_bare','bare','owner','open','old','old',1),
             ('wi_closed','closed','owner','closed','old','old',1),
             ('wi_iceboxed','iceboxed','owner','iceboxed','old','old',1),
             ('wi_failed','failed','owner','failed','old','old',1),
             ('wi_other','other','owner','open','holder','holder',1)
      """)

    {:ok, _} =
      DB.query(ctx.db, """
      INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state,workItemId)
      VALUES ('asg_other_item','another owner','old','holder',3,'open','wi_other')
      """)

    before = rows(ctx.db, "SELECT * FROM work_items WHERE id<>'wi_bare' ORDER BY id")

    call = %{
      principal: {:user, "owner"},
      params: %{from_session_key: "old", to_session_key: "successor", idempotency_key: "items"}
    }

    result = SessionCustodyTransfer.handle(ctx.db, call)

    assert [%{"id" => "wi_bare", "deliveryOwnerSessionKey" => "old", "rowVersion" => 1}] =
             result["before"]["workItems"]

    assert [
             %{
               "id" => "wi_bare",
               "deliveryOwnerSessionKey" => "successor",
               "rowVersion" => version,
               "createdBySession" => "old"
             }
           ] = result["after"]["workItems"]

    assert version > 1
    assert rows(ctx.db, "SELECT * FROM work_items WHERE id<>'wi_bare' ORDER BY id") == before
    assert rows(ctx.db, "SELECT workItemId FROM work_item_versions") == [["wi_bare"]]

    assert rows(ctx.db, "SELECT holderKey FROM assignments WHERE id='asg_held'") == [
             ["successor"]
           ]

    assert SessionCustodyTransfer.handle(ctx.db, call) == result

    assert rows(ctx.db, "SELECT rowVersion FROM work_item_versions WHERE workItemId='wi_bare'") ==
             [[version]]

    assert [[encoded]] =
             rows(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='session_custody_transferred'"
             )

    assert JSON.decode!(encoded)["after"]["workItems"] == result["after"]["workItems"]
  end

  test "captured pending wake is delivered and its turn settles for the successor", ctx do
    {:ok, _} =
      DB.query(ctx.db, """
      INSERT INTO harklight_wake_handles
        (handle,sessionKey,host,state,createdAt,updatedAt)
      VALUES ('captured-handle','old','synthetic-host','active',1,1)
      """)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO harklight_wake_entries
          (handle,eventId,feedCursor,senderId,messageId,entryKind,entryAuthor,rawLine,wakeId,capturedAt)
        VALUES ('captured-handle','one',1,'sender','message','discussion','person','{}',?1,1)
        """,
        [ctx.wake_id]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId)
        VALUES ('captured-handle','one','old',?1)
        """,
        [ctx.wake_id]
      )

    assert %{"eventId" => _} =
             SessionCustodyTransfer.handle(ctx.db, %{
               principal: {:user, "owner"},
               params: %{
                 from_session_key: "old",
                 to_session_key: "successor",
                 idempotency_key: "deliver-captured"
               }
             })

    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    scheduler = :"custody_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Wakes,
         db: ctx.db,
         name: scheduler,
         tick_ms: 60_000,
         deliver: fn wake ->
           Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
             db: ctx.db,
             wake_id: wake.wake_id,
             sender: wake.origin,
             target_gate: if(wake.target_gate == 0, do: nil, else: wake),
             fire_wake_in_txn: wake.origin == "process:tightbeam",
             wake_scheduler: scheduler
           )
         end},
        id: scheduler
      )
    )

    {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [ctx.wake_id])
    assert :ok = Wakes.fire_due(scheduler)

    assert [%{delivery_wake_id: carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, ctx.wake_id)

    assert Wakes.get(ctx.db, ctx.wake_id).state == "fired"

    assert rows(ctx.db, "SELECT currentRecipientSessionKey FROM harklight_wake_deliveries") ==
             [["successor"]]

    assert {:ok, [[seq, "successor", "queued"]]} =
             DB.query(ctx.db, "SELECT seq,sessionKey,status FROM turns WHERE wakeId=?1", [
               carrier_id
             ])

    assert {:ok, %{seq: ^seq} = turn} =
             Ledger.claim_next(ctx.db, "successor", "custody-test")

    assert :ok =
             Ledger.finish(ctx.db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

    assert rows(ctx.db, "SELECT status FROM turns WHERE seq=#{seq}") == [["delivered"]]
  end

  test "parent cycle refuses the entire transfer", ctx do
    assert %{code: "cycle_detected"} =
             SessionCustodyTransfer.handle(ctx.db, %{
               principal: {:user, "owner"},
               params: %{
                 from_session_key: "old",
                 to_session_key: "successor",
                 parent_session_key: "old",
                 idempotency_key: "cycle"
               }
             })

    assert rows(ctx.db, "SELECT holderKey FROM assignments WHERE id='asg_held'") == [["old"]]
    assert rows(ctx.db, "SELECT COUNT(*) FROM session_reparent_events") == [[0]]
  end

  test "non-operator and cross-owner calls cannot transfer custody", ctx do
    params = %{from_session_key: "old", to_session_key: "successor", idempotency_key: "refuse"}

    assert %{code: "user_principal_required"} =
             SessionCustodyTransfer.handle(ctx.db, %{
               principal: {:session, "holder"},
               params: params
             })

    assert %{code: "not_authorized"} =
             SessionCustodyTransfer.handle(ctx.db, %{principal: {:user, "other"}, params: params})

    assert rows(ctx.db, "SELECT holderKey FROM assignments WHERE id='asg_held'") == [["old"]]
  end

  defp rows(db, sql) do
    assert {:ok, rows} = DB.query(db, sql)
    rows
  end
end
