defmodule Tightbeam.WakesTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{DB, EventLog, Wakes}
  alias Tightbeam.DB.Txn

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    scheduler = :"wake_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ensure_all_schemas(name)
    %{db: name, scheduler: scheduler}
  end

  test "schedule persists a pending wake and typed public cancel requires its origin", %{db: db} do
    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "agent:a",
        prompt: "check the build",
        due_at: System.system_time(:millisecond)
      })

    assert wake.wake_id =~ ~r/^w_[0-9a-f-]{36}$/
    assert [^wake] = Wakes.list_pending(db)

    caller_supplied_event = %{
      wake_id: wake.wake_id,
      expected_origin: "agent:a",
      requester: %{kind: "session", id: "test-session"},
      reason_kind: "requester_withdrew",
      causal_source: %{
        kind: "verb_call",
        id: "1",
        accepted_event: %{
          origin: "agent:a",
          session_key: "test-session",
          principal: {:session, "test-session"},
          payload: %{cancel_wake_id: wake.wake_id, canceled: true},
          ts: 1
        }
      },
      outcome: %{kind: "no_replacement"}
    }

    assert {:ok, false} =
             DB.transaction(db, fn txn -> Wakes.cancel_in_txn(txn, caller_supplied_event) end)

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM events")
    assert Wakes.get(db, wake.wake_id).state == "pending"

    refute public_cancel(db, wake.wake_id, "agent:b")

    assert {:accepted_in_txn, event_id, %{canceled: true}} =
             public_cancel(db, wake.wake_id, "agent:a")

    assert {:ok, [[^event_id, causal_source_id]]} =
             DB.query(
               db,
               """
               SELECT e.id, c.causalSourceId
               FROM events e
               JOIN wake_cancellations c ON c.causalSourceId=CAST(e.id AS TEXT)
               WHERE c.wakeId=?1
               """,
               [wake.wake_id]
             )

    assert causal_source_id == Integer.to_string(event_id)
    assert Wakes.get(db, wake.wake_id).state == "canceled"
    refute public_cancel(db, wake.wake_id, "agent:a")
  end

  test "typed cancellation validates the closed process matrix and preserves first provenance", %{
    db: db
  } do
    wake =
      Wakes.schedule(db, %{
        session_key: "internal",
        origin: "process:tightbeam",
        consumer: "missing-consumer",
        due_at: 0
      })

    invalid = %{
      wake_id: wake.wake_id,
      requester: %{kind: "process", id: "tightbeam:supervision"},
      reason_kind: "consumer_unavailable",
      causal_source: %{kind: "scheduler_delivery", id: wake.wake_id},
      outcome: %{kind: "no_replacement"}
    }

    assert {:ok, false} =
             DB.transaction(db, fn txn -> apply(Wakes, :cancel_in_txn, [txn, invalid]) end)

    assert Wakes.get(db, wake.wake_id).state == "pending"

    valid = put_in(invalid, [:requester, :id], "tightbeam:wake-scheduler")

    assert {:ok, true} =
             DB.transaction(db, fn txn -> apply(Wakes, :cancel_in_txn, [txn, valid]) end)

    assert {:ok, [first]} =
             DB.query(
               db,
               "SELECT requesterKind, requesterId, reasonKind, causalSourceKind, causalSourceId, outcomeKind, workImpactKind, actionNeeded FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert first == [
             "process",
             "tightbeam:wake-scheduler",
             "consumer_unavailable",
             "scheduler_delivery",
             wake.wake_id,
             "no_replacement",
             "no_linked_work",
             0
           ]

    duplicate = put_in(valid, [:reason_kind], "target_unresolvable")

    assert {:ok, false} =
             DB.transaction(db, fn txn -> apply(Wakes, :cancel_in_txn, [txn, duplicate]) end)

    assert {:ok, [^first]} =
             DB.query(
               db,
               "SELECT requesterKind, requesterId, reasonKind, causalSourceKind, causalSourceId, outcomeKind, workImpactKind, actionNeeded FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )
  end

  test "a canceled wake and its one provenance carrier must agree at commit", %{db: db} do
    wake =
      Wakes.schedule(db, %{
        session_key: "internal",
        origin: "process:tightbeam",
        consumer: "missing-consumer",
        due_at: 0
      })

    assert {:error, _} =
             DB.transaction(db, fn txn ->
               Txn.q(
                 txn,
                 "UPDATE wakes SET state='canceled', canceledAt=10 WHERE wakeId=?1",
                 [wake.wake_id]
               )

               :ok
             end)

    assert Wakes.get(db, wake.wake_id).state == "pending"

    command = %{
      wake_id: wake.wake_id,
      requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
      reason_kind: "consumer_unavailable",
      causal_source: %{kind: "scheduler_delivery", id: wake.wake_id},
      outcome: %{kind: "no_replacement"}
    }

    cancellation_clock = 12_345

    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, command, fn -> cancellation_clock end)
             end)

    assert %{state: "canceled", canceled_at: canceled_at} = Wakes.get(db, wake.wake_id)

    assert {:ok, [[wake_id, "canceled", carrier_canceled_at]]} =
             DB.query(db, "SELECT wakeId, wakeState, canceledAt FROM wake_cancellations")

    assert wake_id == wake.wake_id
    assert canceled_at == cancellation_clock
    assert carrier_canceled_at == canceled_at
  end

  test "retarget preserves the wake and typed cancellation atomically carries the controller", %{
    db: db
  } do
    :ok =
      DB.execute(
        db,
        """
        INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1);
        INSERT INTO sessions
          (sessionKey, displayName, ownerUserId, origin, archetype, harness,
           provider, model, host, state, createdAt, updatedAt)
        VALUES
          ('retiring', 'retiring', 'flynn', 'user:flynn', 'default', 'claude',
           'anthropic', 'fable', 'eezo', 'active', 1, 1),
          ('replacement', 'replacement', 'flynn', 'user:flynn', 'default',
           'claude', 'anthropic', 'fable', 'eezo', 'active', 1, 1);
        INSERT INTO work_items
          (id, title, ownerUserId, state, createdByUser, createdAt)
        VALUES ('wi_retarget', 'Retarget work', 'flynn', 'open', 'flynn', 1);
        INSERT INTO assignments
          (id, subject, holderKey, openedByUser, openedAt, workItemId)
        VALUES
          ('asg_retarget', 'retarget me', 'retiring', 'flynn', 1,
           'wi_retarget');
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration,
           claimClock, basisKind, basisId, terminusAt, cause, principal,
           supervisionIntervalMs)
        VALUES
          ('asg_retarget', 2, 5000, 'armed', NULL, NULL, 'prod_scheduled',
           'pending-seed', NULL, 'prod_scheduled', 'process:tightbeam', 1000);
        """
      )

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        prompt: "continue",
        consumer: "prompt",
        due_at: 4_000,
        condition_kind: "retirement",
        condition_scope: "retiring",
        creator_session_key: "retiring",
        rumination: true,
        work_item_id: "wi_retarget",
        assignment_id: "asg_retarget",
        target_gate: 0,
        reresolve: "lineage",
        reresolve_seed: "retiring",
        reresolve_rung: 1
      })

    {:ok, _} = DB.query(db, "UPDATE wakes SET createdAt=100 WHERE wakeId=?1", [original.wake_id])
    original = Wakes.get(db, original.wake_id)

    {:ok, _} =
      DB.query(
        db,
        "UPDATE supervision_entitlements SET basisId=?2 WHERE assignmentId=?1",
        ["asg_retarget", original.wake_id]
      )

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_liveness_sidecar
          (wakeId, assignmentId, controllerOrigin, wakeKind, controllerState,
           chargedGeneration)
        VALUES (?1, 'asg_retarget', 'scheduled', 'escalation', 'pending', 2)
        """,
        [original.wake_id]
      )

    assert {:ok, replacement} =
             DB.transaction(db, fn txn ->
               replacement = Wakes.retarget_in_txn(txn, original.wake_id, "replacement")

               assert Wakes.cancel_in_txn(
                        txn,
                        %{
                          wake_id: original.wake_id,
                          requester: %{kind: "process", id: "tightbeam:retirement"},
                          reason_kind: "target_retired",
                          causal_source: %{kind: "session_transition", id: "retiring"},
                          outcome: %{
                            kind: "replacement",
                            replacement_wake_id: replacement.wake_id
                          }
                        },
                        fn -> 6_000 end
                      )

               replacement
             end)

    assert %{state: "canceled", canceled_at: 6_000} = Wakes.get(db, original.wake_id)

    assert %{
             state: "pending",
             session_key: "replacement",
             target_role: "reviewer",
             origin: "process:tightbeam",
             prompt: "continue",
             consumer: "prompt",
             due_at: 4_000,
             fired_at: nil,
             canceled_at: nil,
             condition_kind: "retirement",
             condition_scope: "retiring",
             condition_after_id: 0,
             fired_by: nil,
             creator_session_key: "retiring",
             rumination: true,
             work_item_id: "wi_retarget",
             assignment_id: "asg_retarget",
             target_gate: 0,
             reresolve: "lineage",
             reresolve_seed: "retiring",
             reresolve_rung: 1
           } = Wakes.get(db, replacement.wake_id)

    assert replacement.wake_id != original.wake_id
    assert replacement.created_at > original.created_at

    assert {:ok, sidecars} =
             DB.query(
               db,
               "SELECT wakeId, controllerState, chargedGeneration FROM supervision_liveness_sidecar"
             )

    states =
      Map.new(sidecars, fn [wake_id, state, generation] -> {wake_id, {state, generation}} end)

    assert states[original.wake_id] == {"settled", 2}
    assert states[replacement.wake_id] == {"pending", 2}
  end

  test "O1: retarget carries the sender's class election AND the original ceiling verbatim — never restarts it",
       %{db: db} do
    active_sessions!(db, ["a", "b"])

    original =
      Wakes.schedule(db, %{
        session_key: "a",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "fyi note",
        due_at: 0,
        class: "fyi"
      })

    assert original.class == "fyi"
    assert original.class_election == "sender"
    assert original.delivery_rule == Wakes.digest_rule()
    refute original.digest
    refute original.summon

    # Backdate the original's filing time deep into its own ceiling window —
    # 3h59m into a 4h `fyi` ceiling — so a restarted ceiling (retarget-moment
    # + ceiling_ms) is provably DIFFERENT from the preserved one, not a
    # coincidental match (Sol xhigh review round 2, finding 1: Invariant 3 —
    # the ceiling anchors on the wake's own creation, never on when it
    # happened to get retargeted; recomputing it here would let this `fyi`
    # land at 7h59m, a straight §7 violation).
    ceiling = Wakes.delivery_policy("fyi").ceiling_ms
    original_created_at = 1000
    original_due_at = original_created_at + ceiling - 60_000

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET createdAt=?2, dueAt=?3 WHERE wakeId=?1", [
        original.wake_id,
        original_created_at,
        original_due_at
      ])

    original = Wakes.get(db, original.wake_id)

    assert {:ok, replacement} =
             DB.transaction(db, fn txn ->
               Wakes.retarget_in_txn(txn, original.wake_id, "b")
             end)

    # THE SENDER'S ELECTION SURVIVES RETARGET (O1, Law 2) — never destroyed,
    # never re-elected.
    assert replacement.class == "fyi"
    assert replacement.class_election == "sender"
    refute replacement.digest
    refute replacement.summon
    assert replacement.session_key == "b"

    # THE CEILING IS PRESERVED, NOT RESTARTED: the replacement's `dueAt` is
    # the ORIGINAL's, byte-identical — never `replacement.created_at +
    # ceiling`, which would extend it. B's own turn-boundary eligibility is
    # handled dynamically, by grouping on the row's new `sessionKey` at the
    # next materialization pass — nothing here needs to move `dueAt` for
    # that to be true.
    assert replacement.delivery_rule == Wakes.digest_rule()
    assert replacement.due_at == original_due_at
    assert replacement.due_at == original.due_at
    refute replacement.due_at == replacement.created_at + ceiling
  end

  test "O1: a retargeted summon keeps summon, and a sender-scheduled moment stays unmoved",
       %{db: db} do
    active_sessions!(db, ["a", "b"])

    original =
      Wakes.schedule(db, %{
        session_key: "a",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "come look at this",
        due_at: System.system_time(:millisecond) + 60_000,
        class: "input-needed",
        sender_scheduled: true,
        summon: true
      })

    assert original.summon
    assert original.delivery_rule == Wakes.inhibited_rule()

    assert {:ok, replacement} =
             DB.transaction(db, fn txn ->
               Wakes.retarget_in_txn(txn, original.wake_id, "b")
             end)

    assert replacement.summon
    assert replacement.class == "input-needed"
    assert replacement.class_election == "sender"
    assert replacement.session_key == "b"

    # The sender already named this moment (batcher-inhibited); retarget
    # must not start batching it now.
    assert replacement.delivery_rule == Wakes.inhibited_rule()
    assert replacement.due_at == original.due_at
  end

  test "O1: an immediate class's own election is unmoved by retarget", %{db: db} do
    active_sessions!(db, ["a", "b"])
    at = System.system_time(:millisecond)

    original =
      Wakes.schedule(db, %{
        session_key: "a",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "stopped",
        due_at: at,
        class: "blocker"
      })

    assert {:ok, replacement} =
             DB.transaction(db, fn txn ->
               Wakes.retarget_in_txn(txn, original.wake_id, "b")
             end)

    assert replacement.class == "blocker"
    assert replacement.class_election == "sender"
    assert replacement.due_at == at
    assert replacement.delivery_rule == original.delivery_rule
  end

  defp active_sessions!(db, keys) do
    values =
      keys
      |> Enum.map(fn key ->
        "('#{key}', '#{key}', 'flynn', 'user:flynn', 'default', 'claude', 'anthropic', 'fable', 'eezo', 'active', 1, 1)"
      end)
      |> Enum.join(",\n")

    :ok =
      DB.execute(
        db,
        """
        INSERT OR IGNORE INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1);
        INSERT INTO sessions
          (sessionKey, displayName, ownerUserId, origin, archetype, harness,
           provider, model, host, state, createdAt, updatedAt)
        VALUES
          #{values};
        """
      )

    :ok
  end

  test "fire_due claims each due wake once across synchronous passes", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake}) end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "system",
        prompt: "now",
        due_at: System.system_time(:millisecond)
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, %{wake_id: wake_id, prompt: "now"}}
    assert wake_id == wake.wake_id
    assert Wakes.get(db, wake.wake_id).state == "fired"

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, _}
  end

  test "failed delivery leaves the wake pending; it retries and then fires", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()
    fail_first = :counters.new(1, [])

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake ->
         if :counters.get(fail_first, 1) == 0 do
           :counters.add(fail_first, 1, 1)
           raise "delivery blew up"
         end

         send(test_pid, {:delivered, wake})
       end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "system",
        prompt: "flaky",
        due_at: System.system_time(:millisecond)
      })

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, _}
    assert Wakes.get(db, wake.wake_id).state == "pending"

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, %{wake_id: wake_id}}
    assert wake_id == wake.wake_id
    assert %{state: "fired", fired_at: fired_at} = Wakes.get(db, wake.wake_id)
    assert is_integer(fired_at)
  end

  test "unknown internal consumer is consumed as canceled, never claimed as fired", %{
    db: db,
    scheduler: scheduler
  } do
    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn _wake -> :ok end,
       internal_consumers: %{}}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        consumer: "missing_consumer",
        due_at: System.system_time(:millisecond)
      })

    log =
      capture_log(fn ->
        assert :ok = Wakes.fire_due(scheduler)
        assert :ok = Wakes.fire_due(scheduler)
      end)

    assert log =~ "undeliverable"
    assert log =~ "missing_consumer"
    assert length(Regex.scan(~r/missing_consumer/, log)) == 1

    # CONSUMED, so the sweep does not spin on a code bug — but never claimed as
    # delivered. `fired` is this substrate's word for delivered, and a wake nobody
    # could deliver must not wear it: this path carries owner decision
    # notifications, so a consumer-name typo would otherwise eat a decision
    # request while the row said it was delivered.
    assert %{state: "canceled", canceled_at: canceled_at, fired_at: nil} =
             Wakes.get(db, wake.wake_id)

    assert is_integer(canceled_at)

    # The durable record carries WHY, since `canceled` alone cannot distinguish a
    # deliberate cancel from an undeliverable wake.
    assert [%{kind: "wake_undeliverable", subject: subject, detail: detail}] =
             Enum.filter(EventLog.lifecycle_events(db), &(&1.kind == "wake_undeliverable"))

    assert subject == wake.wake_id
    assert detail =~ "missing_consumer"
  end

  test "exiting internal consumer leaves its wake pending and does not crash the scheduler", %{
    db: db,
    scheduler: scheduler
  } do
    scheduler_pid =
      start_supervised!(
        {Wakes,
         db: db,
         name: scheduler,
         tick_ms: 60_000,
         deliver: fn _wake -> :ok end,
         internal_consumers: %{"exiting" => fn _wake -> exit(:consumer_boom) end}}
      )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        consumer: "exiting",
        due_at: System.system_time(:millisecond)
      })

    log = capture_log(fn -> assert :ok = Wakes.fire_due(scheduler) end)

    assert Process.alive?(scheduler_pid)
    assert Wakes.get(db, wake.wake_id).state == "pending"

    # Retrying is correct — a consumer can fail transiently and succeed later.
    # Retrying SILENTLY was not: a consumer raising every tick was
    # indistinguishable from an idle scheduler, so each attempt is now recorded.
    assert log =~ "consumer_boom"

    assert [%{subject: subject, detail: detail}] =
             Enum.filter(EventLog.lifecycle_events(db), &(&1.kind == "wake_delivery_failed"))

    assert subject == wake.wake_id
    assert detail =~ "consumer_boom"

    # One row per attempt, so the repetition is itself visible.
    assert :ok = Wakes.fire_due(scheduler)

    assert length(
             Enum.filter(EventLog.lifecycle_events(db), &(&1.kind == "wake_delivery_failed"))
           ) ==
             2
  end

  test "fire_due called inside the scheduler queues another pass without self-calling", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:nested_fired, wake.wake_id}) end,
       internal_consumers: %{
         "self_fire" => fn wake ->
           nested =
             Wakes.schedule(db, %{
               session_key: "k2",
               origin: "system",
               prompt: "nested",
               due_at: System.system_time(:millisecond)
             })

           :ok = Wakes.fire_due(self())
           send(test_pid, {:self_fire_returned, wake.wake_id, nested.wake_id})
           public_cancel(db, wake.wake_id, wake.origin, %{kind: "process", id: "tightbeam"})
         end
       }}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        consumer: "self_fire",
        due_at: System.system_time(:millisecond)
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert_received {:self_fire_returned, wake_id, nested_wake_id}
    assert wake_id == wake.wake_id
    assert_receive {:nested_fired, ^nested_wake_id}
    assert Wakes.get(db, wake.wake_id).state == "canceled"
    assert Wakes.get(db, nested_wake_id).state == "fired"
  end

  test "future wakes are not claimed", %{db: db, scheduler: scheduler} do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake}) end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "system",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, _}
    assert Wakes.get(db, wake.wake_id).state == "pending"
  end

  test "rumination markers count only after firing and are scoped by work-item and caller", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake}) end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "caller",
        origin: "agent:caller",
        creator_session_key: "caller",
        prompt: "digest: think first",
        due_at: System.system_time(:millisecond),
        rumination: true,
        work_item_id: "wi_one"
      })

    assert wake.rumination
    assert wake.work_item_id == "wi_one"
    refute Wakes.rumination_exists?(db, "wi_one", "caller")
    refute Wakes.rumination_exists?(db, "wi_other", "caller")
    refute Wakes.rumination_exists?(db, "wi_one", "other-caller")

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, %{wake_id: wake_id}}
    assert wake_id == wake.wake_id
    assert Wakes.rumination_exists?(db, "wi_one", "caller")
    refute Wakes.rumination_exists?(db, "wi_other", "caller")
    refute Wakes.rumination_exists?(db, "wi_one", "other-caller")
  end

  defp public_cancel(
         db,
         wake_id,
         expected_origin,
         requester \\ %{kind: "session", id: "test-session"}
       ) do
    principal = requester_principal(requester)
    session_key = if requester.kind == "session", do: requester.id

    case DB.transaction(db, fn txn ->
           Wakes.cancel_in_txn(txn, %{
             wake_id: wake_id,
             expected_origin: expected_origin,
             requester: requester,
             reason_kind: "requester_withdrew",
             causal_source: %{
               kind: "verb_call",
               accepted_event: %{
                 origin: expected_origin,
                 session_key: session_key,
                 principal: principal
               }
             },
             outcome: %{kind: "no_replacement"}
           })
         end) do
      {:ok, result} -> result
      {:error, _} -> false
    end
  end

  defp requester_principal(%{kind: "user", id: id}), do: {:user, id}
  defp requester_principal(%{kind: "session", id: id}), do: {:session, id}
  defp requester_principal(%{kind: "process", id: id}), do: {:process, id}
end
