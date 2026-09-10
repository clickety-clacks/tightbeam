defmodule Tightbeam.ReminderTransactionTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Ledger, ReminderDelivery, Schema}
  alias Tightbeam.DB.Txn

  setup do
    db = start_supervised!({DB, name: :r1_transaction_db, path: ":memory:"})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) VALUES ('r1-holder','r1','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt) VALUES ('r1-assignment','r1','r1-holder','fixture',1)"
      )

    %{db: db}
  end

  for recovery <- [:wake, :turn] do
    @tag recovery: recovery
    test "supported #{recovery} successor keeps immutable intent and fences terminal replay", %{
      db: db,
      recovery: recovery
    } do
      assert {:ok, wake} =
               DB.transaction(db, fn txn ->
                 ReminderDelivery.schedule_in_txn(txn, "r1-assignment", "prod", "r1-holder", fn ->
                   Tightbeam.Wakes.schedule_in_txn(txn, %{
                     session_key: "r1-holder",
                     origin: "process:tightbeam",
                     prompt: "Preserve this reminder intent",
                     assignment_id: "r1-assignment",
                     due_at: 0
                   })
                 end)
               end)

      assert {:ok, source_seq} =
               Ledger.enqueue(db, %{
                 session_key: "r1-holder",
                 message_id: "source-message",
                 origin: "process:tightbeam",
                 prompt: wake.prompt,
                 assignment_id: "r1-assignment",
                 wake_id: wake.wake_id
               })

      assert {:ok, source} = Ledger.claim_next(db, "r1-holder", "source-consumer")
      initial = state(db)
      failed_status = if recovery == :wake, do: "failed", else: "failed_unknown"
      assert :ok = Ledger.finish(db, source_seq, failed_status, "fixture terminal failure")

      assert {:ok, [[ended_at]]} =
               DB.query(db, "SELECT endedAt FROM turns WHERE seq=?1", [source_seq])

      successor_seq =
        if recovery == :wake do
          assert {:ok, [[request_ref]]} =
                   DB.query(db, "SELECT requestRef FROM turns WHERE seq=?1", [source_seq])

          failed =
            Map.merge(source, %{status: "failed", ended_at: ended_at, request_ref: request_ref})

          assert {:ok, {:retry, successor_wake}} =
                   DB.transaction(
                     db,
                     &Tightbeam.Wakes.preserve_failed_intent_in_txn(&1, failed, "rate-limit-dead")
                   )

          rebound = state(db)

          assert {:ok, {:retry, ^successor_wake}} =
                   DB.transaction(
                     db,
                     &Tightbeam.Wakes.preserve_failed_intent_in_txn(&1, failed, "rate-limit-dead")
                   )

          assert state(db) == rebound
          assert rebound["pending"]["consumer"] == %{"wake" => successor_wake}
          assert Tightbeam.Wakes.get(db, successor_wake).assignment_id == "r1-assignment"

          assert {:ok, seq} =
                   Ledger.enqueue(db, %{
                     session_key: "r1-holder",
                     message_id: "successor-message",
                     origin: "process:tightbeam",
                     prompt: wake.prompt,
                     assignment_id: "r1-assignment",
                     wake_id: successor_wake
                   })

          seq
        else
          assert {:ok, {:appended, seq, attempt}} =
                   Ledger.repair_terminal(
                     db,
                     source_seq,
                     "r1-assignment",
                     "owner-repair",
                     "user:fixture"
                   )

          assert {:ok, {:duplicate, ^seq, ^attempt}} =
                   Ledger.repair_terminal(
                     db,
                     source_seq,
                     "r1-assignment",
                     "owner-repair",
                     "user:fixture"
                   )

          assert state(db)["pending"]["consumer"] == %{"turn" => seq}
          seq
        end

      rebound = state(db)
      assert rebound["claimEpoch"] == initial["claimEpoch"] + 1
      assert rebound["pending"]["intent"] == initial["pending"]["intent"]
      assert rebound["pending"]["snapshot"] == initial["pending"]["snapshot"]

      assert {:ok, false} =
               DB.transaction(db, &Ledger.finish_in_txn(&1, source_seq, "delivered", nil))

      assert {:ok, :no_claim} =
               DB.transaction(db, &ReminderDelivery.delivered_in_txn(&1, source_seq))

      assert state(db) == rebound

      assert {:ok, %{seq: ^successor_seq}} =
               Ledger.claim_next(db, "r1-holder", "successor-consumer")

      assert {:ok, :recorded} =
               DB.transaction(db, fn txn ->
                 assert Ledger.finish_in_txn(txn, successor_seq, "delivered", nil)
                 ReminderDelivery.delivered_in_txn(txn, successor_seq)
               end)

      delivered = state(db)
      assert delivered["pending"] == nil
      assert delivered["lastIntent"] == wake.wake_id
      assert delivered["lastSnapshot"] == initial["pending"]["snapshot"]

      assert {:ok, false} =
               DB.transaction(db, &Ledger.finish_in_txn(&1, successor_seq, "delivered", nil))

      assert {:ok, :no_claim} =
               DB.transaction(db, &ReminderDelivery.delivered_in_txn(&1, successor_seq))

      assert state(db) == delivered

      assert {:ok, [[^failed_status]]} =
               DB.query(db, "SELECT status FROM turns WHERE seq=?1", [source_seq])
    end
  end

  test "claim, winning terminal success, and duplicate callback share persisted state", %{db: db} do
    assert {:ok, %{wake_id: "r1-notice"}} =
             DB.transaction(db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, "r1-assignment", "prod", "r1-holder", fn ->
                 %{wake_id: "r1-notice"}
               end)
             end)

    assert {:ok, %{code: "reminder_pending"}} =
             DB.transaction(db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, "r1-assignment", "prod", "r1-holder", fn ->
                 flunk("duplicate notice")
               end)
             end)

    :ok =
      DB.execute(
        db,
        "INSERT INTO turns(seq,sessionKey,messageId,wakeId,origin,prompt,assignmentId,status,createdAt) VALUES (1,'r1-holder','m1','r1-notice','process:tightbeam','notice','r1-assignment','running',1)"
      )

    assert {:ok, :recorded} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, 1, "delivered", nil)
               ReminderDelivery.delivered_in_txn(txn, 1)
             end)

    before = state(db)
    assert before["nextEligibleAt"] - before["lastDeliveredAt"] == 300_000
    assert is_nil(before["pending"])
    assert {:ok, :no_claim} = DB.transaction(db, &ReminderDelivery.delivered_in_txn(&1, 1))
    assert state(db) == before

    assert {:ok, %{code: "reminder_not_eligible"}} =
             DB.transaction(db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, "r1-assignment", "prod", "r1-holder", fn ->
                 flunk("early notice")
               end)
             end)
  end

  test "authorized successor turn preserves unknown outcome and fences old consumer", %{db: db} do
    {:ok, _} =
      DB.transaction(db, fn txn ->
        ReminderDelivery.schedule_in_txn(txn, "r1-assignment", "prod", "r1-holder", fn ->
          %{wake_id: "r1-failed"}
        end)
      end)

    :ok =
      DB.execute(
        db,
        "INSERT INTO turns(seq,sessionKey,messageId,wakeId,origin,prompt,assignmentId,status,createdAt,endedAt) VALUES (1,'r1-holder','m1','r1-failed','process:tightbeam','notice','r1-assignment','failed_unknown',1,2)"
      )

    assert {:ok, :no_claim} = DB.transaction(db, &ReminderDelivery.delivered_in_txn(&1, 1))

    assert {:ok, {:appended, successor, _}} =
             Ledger.repair_terminal(db, 1, "r1-assignment", "repair-1", "user:fixture")

    assert state(db)["pending"]["consumer"] == %{"turn" => successor}
    assert state(db)["claimEpoch"] == 2
    assert is_nil(state(db)["lastDeliveredAt"])

    assert {:ok, :recorded} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "UPDATE turns SET status='running' WHERE seq=?1", [successor])
               assert Ledger.finish_in_txn(txn, successor, "delivered", nil)
               ReminderDelivery.delivered_in_txn(txn, successor)
             end)

    assert state(db)["lastIntent"] == "r1-failed"
    assert {:ok, [["failed_unknown"]]} = DB.query(db, "SELECT status FROM turns WHERE seq=1")
  end

  test "persisted JSON round trips typed consequence and malformed JSON refuses atomically", %{
    db: db
  } do
    consequence = %{
      "assignmentId" => "r1-assignment",
      "consequenceKey" => "résumé",
      "revision" => "r1",
      "attentionRequestId" => "attention-1",
      "evidenceAttestId" => "att-evidence",
      "explicitAttention" => true
    }

    initial = %{"version" => 1, "claimEpoch" => 0, "currentConsequence" => consequence}

    {:ok, _} =
      DB.query(db, "UPDATE assignments SET reminderState=?1 WHERE id='r1-assignment'", [
        JSON.encode!(initial)
      ])

    assert {:ok, _} =
             DB.transaction(db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, "r1-assignment", "prod", "r1-holder", fn ->
                 %{wake_id: "round-trip"}
               end)
             end)

    assert state(db)["currentConsequence"] == consequence
    assert state(db)["pending"]["snapshot"]["consequence"] == consequence

    {:ok, _} =
      DB.query(db, "UPDATE assignments SET reminderState=?1 WHERE id='r1-assignment'", [
        "{malformed"
      ])

    assert {:error, %JSON.DecodeError{}} =
             DB.transaction(db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, "r1-assignment", "prod", "r1-holder", fn ->
                 flunk("must not create wake for corrupt state")
               end)
             end)

    assert {:ok, [["{malformed"]]} =
             DB.query(db, "SELECT reminderState FROM assignments WHERE id='r1-assignment'")
  end

  test "legacy null consequence remains intact through authorized typed admission and replay", %{
    db: db
  } do
    :ok =
      DB.execute(
        db,
        "INSERT INTO attests(id,assignmentId,kind,bySession,ts) VALUES ('att-evidence','r1-assignment','progress','r1-holder',1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO condition_facts(ts,kind,scope,origin,ownerUserId,payload) VALUES (1,'obligation-consequence-changed','r1-assignment','session:r1-holder','fixture',NULL)"
      )

    {:ok, [legacy]} = DB.query(db, "SELECT * FROM condition_facts WHERE payload IS NULL")

    payload = %{
      "assignmentId" => "r1-assignment",
      "consequenceKey" => "legacy-upgrade",
      "revision" => "r1",
      "attentionRequestId" => "attention-legacy",
      "evidenceAttestId" => "att-evidence",
      "explicitAttention" => true
    }

    input = %{
      kind: "obligation-consequence-changed",
      scope: "r1-assignment",
      origin: "session:r1-holder",
      principal: {:session, "r1-holder"},
      payload: payload
    }

    file = fn input -> DB.transaction(db, &Tightbeam.ConditionFacts.file_in_txn(&1, input)) end

    assert {:ok, {:error, %{code: "not_authorized"}}} =
             file.(%{input | principal: {:session, "other"}})

    assert {:ok, fact} = file.(input)
    assert fact.payload == payload
    assert {:ok, ^fact} = file.(input)

    assert {:ok, {:error, %{code: "conflict"}}} =
             file.(%{input | payload: Map.put(payload, "revision", "changed")})

    assert {:ok, ^fact} =
             file.(%{
               input
               | payload: %{
                   payload
                   | "attentionRequestId" => "attention-repeat",
                     "explicitAttention" => false
                 }
             })

    assert {:ok, [^legacy]} = DB.query(db, "SELECT * FROM condition_facts WHERE payload IS NULL")
    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM condition_facts")
    assert state(db)["currentConsequence"] == payload
  end

  defp state(db) do
    {:ok, [[encoded]]} =
      DB.query(db, "SELECT reminderState FROM assignments WHERE id='r1-assignment'")

    JSON.decode!(encoded)
  end
end
