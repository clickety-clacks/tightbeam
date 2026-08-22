defmodule Tightbeam.JobForensicsTest do
  @moduledoc """
  Proofs for spec job-forensics-v2 — attribution columns, the causal_events
  append, and the trace extension.

  Law 0 holds throughout: every row asserted here is a substrate side effect of
  a domain write, never something a caller authored.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    CausalEvents,
    ConditionFacts,
    DB,
    EffortCheckin,
    Gateway,
    Ledger,
    Org,
    Roles,
    SubagentMarkers,
    Supervision,
    Wakes,
    WorkItems
  }

  alias Tightbeam.DB.Txn

  @cancellation_projection_keys ~w(
    provenanceStatus schedulingOrigin requesterKind requesterId reasonKind
    causalSourceKind causalSourceId outcomeKind replacementWakeId dispositionKind
    dispositionId primaryWorkKind primaryWorkId workImpactKind livenessTriggerKind
    livenessTriggerId actionNeeded
  )a

  defmodule LaneDoorbell do
    @moduledoc false
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    db = :"forensics_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    registry =
      start_supervised!(
        {Tightbeam.ConnRegistry, name: :"forensics_reg_#{System.unique_integer([:positive])}"}
      )

    lane =
      start_supervised!({LaneDoorbell, :"forensics_lane_#{System.unique_integer([:positive])}"})

    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',1,1)"
      )

    %{db: db, registry: registry, lane: lane}
  end

  ## Proof 9 — final schema

  test "proof 9: every final column and causal-event index is present", %{
    db: db
  } do
    for {table, column} <- [
          {"wakes", "assignmentId"},
          {"wakes", "canceledAt"},
          {"subagent_markers", "assignmentId"}
        ] do
      assert column in columns(db, table), "#{table}.#{column} must exist after ensure_schema"
    end

    :ok = Wakes.ensure_schema(db)
    :ok = SubagentMarkers.ensure_schema(db)
    :ok = CausalEvents.ensure_schema(db)

    assert "causal_events" in tables(db)

    indexes = indexes(db, "causal_events")
    assert "causal_events_job" in indexes
    assert "causal_events_assignment" in indexes
  end

  test "cancellation activation creates one typed carrier and the shared epoch", %{db: db} do
    assert "wake_cancellations" in tables(db)
    assert "supervision_liveness_epoch" in tables(db)
    refute "wake_cancellation_legacy" in tables(db)
    refute "wake_cancellation_epoch" in tables(db)

    assert columns(db, "wake_cancellations") ==
             ~w(
               wakeId wakeState canceledAt requesterKind requesterId reasonKind
               causalSourceKind causalSourceId outcomeKind replacementWakeId
               dispositionKind dispositionId primaryWorkKind primaryWorkId
               workImpactKind livenessTriggerKind livenessTriggerId actionNeeded
             )

    assert columns(db, "supervision_liveness_epoch") ==
             ~w(id activatedAt cause principal)

    assert {:ok, [[0, activated_at, "schema_activation", "process:tightbeam"]]} =
             DB.query(
               db,
               "SELECT id, activatedAt, cause, principal FROM supervision_liveness_epoch"
             )

    assert is_integer(activated_at) and activated_at >= 0
  end

  test "the typed cancellation command is the only exported cancellation mutation surface" do
    Code.ensure_loaded!(Wakes)

    assert function_exported?(Wakes, :cancel_in_txn, 2)
    assert function_exported?(Wakes, :cancel_in_txn, 3)
    refute function_exported?(Wakes, :cancel, 3)
    refute function_exported?(Wakes, :cancel_pending_in_txn, 2)
  end

  ## Proof 1 — atomicity

  test "proof 1: an append and its domain write commit or roll back together", %{db: db} do
    work_item(db, "wi_atomic")

    # Rollback: the domain write and the append are in one transaction, and a
    # failure after both leaves NEITHER.
    assert {:error, _} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "UPDATE work_items SET state = 'closed' WHERE id = 'wi_atomic'")

               CausalEvents.append_in_txn(txn, %{
                 kind: "disposition_transition",
                 job_ref: "wi_atomic",
                 detail: %{workItemId: "wi_atomic", fromState: "open", toState: "closed"}
               })

               raise "simulated failure after both writes"
             end)

    assert state(db, "wi_atomic") == "open", "the domain write must have rolled back"
    assert CausalEvents.for_job(db, "wi_atomic", []) == []

    # Commit: the same pair, allowed to finish.
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(txn, "UPDATE work_items SET state = 'closed' WHERE id = 'wi_atomic'")

        CausalEvents.append_in_txn(txn, %{
          kind: "disposition_transition",
          job_ref: "wi_atomic",
          detail: %{workItemId: "wi_atomic", fromState: "open", toState: "closed"}
        })
      end)

    assert state(db, "wi_atomic") == "closed"
    assert [%{kind: "disposition_transition"}] = CausalEvents.for_job(db, "wi_atomic", [])
  end

  ## Proof 7 — disposition history

  test "proof 7: icebox -> reopen -> close yields three transitions with correct from/to", %{
    db: db
  } do
    work_item(db, "wi_disp")

    assert %{workItem: %{state: "iceboxed"}} = dispose(db, "work-item-icebox", "wi_disp")
    assert %{workItem: %{state: "open"}} = dispose(db, "work-item-reopen", "wi_disp")
    assert %{workItem: %{state: "closed"}} = dispose(db, "work-item-close", "wi_disp")

    events = CausalEvents.for_job(db, "wi_disp", [])

    assert Enum.map(events, & &1.detail["fromState"]) == ["open", "iceboxed", "open"]
    assert Enum.map(events, & &1.detail["toState"]) == ["iceboxed", "open", "closed"]
    assert Enum.all?(events, &(&1.kind == "disposition_transition"))
    assert Enum.all?(events, &(&1.detail["workItemId"] == "wi_disp"))
    assert Enum.all?(events, &(&1.job_ref == "wi_disp"))
    assert Enum.all?(events, &is_nil(&1.assignment_id))

    # A same-state disposition changes nothing, so it records nothing.
    assert %{workItem: %{state: "closed"}} = dispose(db, "work-item-close", "wi_disp")
    assert length(CausalEvents.for_job(db, "wi_disp", [])) == 3

    # The work-item row keeps its shape — this table ADDS history, it does not
    # migrate the item.
    assert_keys(
      fetch_item(db, "wi_disp").workItem,
      ~w(createdAt createdBySession createdByUser failReason id isBug ownerUserId
         rowVersion specRefName specRefSha256 state title)a
    )
  end

  test "proof 7: a failed disposition records its failReason", %{db: db} do
    work_item(db, "wi_fail")

    assert %{workItem: %{state: "failed"}} =
             dispose(db, "work-item-fail", "wi_fail", %{reason: "wontfix"})

    assert [%{detail: %{"toState" => "failed", "failReason" => "wontfix"}}] =
             CausalEvents.for_job(db, "wi_fail", [])
  end

  ## Proof 4 — episode attribution + adjudication events

  ## Proof 5 — marker attribution

  test "proof 5: a marker is stamped from the parent's RUNNING turn, never guessed", %{db: db} do
    work_item(db, "wi_mark")
    session(db, "parent")
    assignment(db, "asg_mark", "wi_mark", "parent")
    assignment(db, "asg_other", "wi_mark", "parent")

    # A session can hold SEVERAL open assignments; only the running turn decides.
    turn(db, "parent", assignment_id: "asg_other", status: "delivered")
    turn(db, "parent", assignment_id: "asg_mark", status: "running")

    marker =
      SubagentMarkers.append(db, Tightbeam.WakeScheduler, %{
        kind: "subagent_start",
        principal: "parent",
        subagent_ref: "subagent:one",
        source_event_ref: "event:one",
        harness: "claude",
        at: 10
      })

    assert marker.assignment_id == "asg_mark"

    # No running turn -> NULL. Never the session's other open assignment.
    :ok = DB.execute(db, "UPDATE turns SET status = 'delivered' WHERE status = 'running'")

    unattributed =
      SubagentMarkers.append(db, Tightbeam.WakeScheduler, %{
        kind: "subagent_start",
        principal: "parent",
        subagent_ref: "subagent:two",
        source_event_ref: "event:two",
        harness: "claude",
        at: 20
      })

    assert is_nil(unattributed.assignment_id)
  end

  ## Proof 6 — wake.canceledAt on every cancel path

  test "proof 6: every cancel path stamps canceledAt", %{db: db} do
    session(db, "k1")

    # Path 1: an origin-guarded authenticated requester.
    a = Wakes.schedule(db, %{session_key: "k1", origin: "user:flynn", prompt: "a", due_at: 1})
    assert public_cancel(db, a.wake_id, "user:flynn", %{kind: "user", id: "flynn"})
    assert is_integer(Wakes.get(db, a.wake_id).canceled_at)

    # Path 2: a closed-set substrate process cancellation.
    b =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        consumer: "missing-consumer",
        due_at: 1
      })

    {:ok, true} =
      DB.transaction(db, fn txn ->
        Wakes.cancel_in_txn(txn, %{
          wake_id: b.wake_id,
          requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
          reason_kind: "consumer_unavailable",
          causal_source: %{kind: "scheduler_delivery", id: b.wake_id},
          outcome: %{kind: "no_replacement"}
        })
      end)

    assert is_integer(Wakes.get(db, b.wake_id).canceled_at)

    # A refused cancel stamps nothing.
    c = Wakes.schedule(db, %{session_key: "k1", origin: "user:flynn", prompt: "c", due_at: 1})
    refute public_cancel(db, c.wake_id, "user:someone-else", %{kind: "user", id: "flynn"})
    assert is_nil(Wakes.get(db, c.wake_id).canceled_at)
    assert Wakes.get(db, c.wake_id).state == "pending"

    # No cancel path anywhere may write state without the timestamp.
    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE state='canceled' AND canceledAt IS NULL"
             )
  end

  test "proof 6: the trace carries a wake_canceled entry", %{db: db} do
    work_item(db, "wi_cancel")
    session(db, "k1")
    assignment(db, "asg_cancel", "wi_cancel", "k1")

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        prompt: "p",
        due_at: 1,
        assignment_id: "asg_cancel"
      })

    replacement =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        prompt: "replacement",
        due_at: 2,
        assignment_id: "asg_cancel"
      })

    {:ok, true} =
      DB.transaction(db, fn txn ->
        Wakes.cancel_in_txn(txn, %{
          wake_id: wake.wake_id,
          requester: %{kind: "process", id: "tightbeam:effort-checkin"},
          reason_kind: "superseded",
          causal_source: %{kind: "wake", id: replacement.wake_id},
          outcome: %{kind: "replacement", replacement_wake_id: replacement.wake_id}
        })
      end)

    entry =
      db
      |> trace("wi_cancel")
      |> Map.fetch!(:timeline)
      |> Enum.find(&(&1.type == "wake_canceled"))

    assert entry.id == wake.wake_id
    assert entry.assignmentId == "asg_cancel"
    assert is_integer(entry.at)
    assert is_integer(entry.seqTiebreak)
    assert is_nil(entry.reason)
  end

  test "cancellation trace separates scheduling origin from requester and preserves first provenance",
       %{db: db} do
    work_item(db, "wi_requester")
    :ok = DB.execute(db, "UPDATE work_items SET state='closed' WHERE id='wi_requester'")
    session(db, "requester-session")

    wake =
      Wakes.schedule(db, %{
        session_key: "requester-session",
        origin: "agent:reviewer",
        creator_session_key: "requester-session",
        prompt: "cancel me",
        due_at: 1,
        work_item_id: "wi_requester"
      })

    assert %{canceled: false} =
             cancel_via_gateway(
               db,
               wake.wake_id,
               "agent:another-role",
               {:session, "requester-session"}
             )

    refute Enum.any?(trace(db, "wi_requester").timeline, &(&1.type == "wake_canceled"))

    assert %{canceled: true} =
             cancel_via_gateway(
               db,
               wake.wake_id,
               "agent:reviewer",
               {:session, "requester-session"}
             )

    first = canceled_entry(db, "wi_requester", wake.wake_id)

    assert_proven_cancellation(first, %{
      schedulingOrigin: "agent:reviewer",
      requesterKind: "session",
      requesterId: "requester-session",
      reasonKind: "requester_withdrew",
      causalSourceKind: "verb_call",
      outcomeKind: "no_replacement",
      primaryWorkKind: "work_item",
      primaryWorkId: "wi_requester",
      workImpactKind: "linked_work_not_open",
      actionNeeded: false
    })

    assert is_binary(first.causalSourceId) and first.causalSourceId != ""

    assert {:ok, [["verb", "wake", payload]]} =
             DB.query(
               db,
               "SELECT kind, verb, payload FROM events WHERE CAST(id AS TEXT)=?1",
               [first.causalSourceId]
             )

    assert JSON.decode!(payload) == %{
             "cancel_wake_id" => wake.wake_id,
             "canceled" => true
           }

    refute payload =~ "prompt"

    assert {:ok, [[shared_ts, shared_ts, shared_ts]]} =
             DB.query(
               db,
               """
               SELECT e.ts, c.canceledAt, w.canceledAt
               FROM events e
               JOIN wake_cancellations c ON CAST(e.id AS TEXT)=c.causalSourceId
               JOIN wakes w ON w.wakeId=c.wakeId
               WHERE c.wakeId=?1
               """,
               [wake.wake_id]
             )

    assert %{canceled: false} =
             cancel_via_gateway(
               db,
               wake.wake_id,
               "agent:reviewer",
               {:session, "requester-session"}
             )

    assert canceled_entry(db, "wi_requester", wake.wake_id) == first
  end

  test "internal consumer cancellation records process provenance without firing", %{db: db} do
    work_item(db, "wi_consumer")
    :ok = DB.execute(db, "UPDATE work_items SET state='closed' WHERE id='wi_consumer'")

    scheduler = :consumer_cancellation_scheduler

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn _wake -> flunk("an internal wake must not reach prompt delivery") end,
       internal_consumers: %{}}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "internal-target",
        origin: "process:tightbeam",
        consumer: "missing-consumer",
        due_at: 0,
        work_item_id: "wi_consumer"
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert %{state: "canceled", fired_at: nil} = Wakes.get(db, wake.wake_id)

    entry = canceled_entry(db, "wi_consumer", wake.wake_id)

    assert_proven_cancellation(entry, %{
      schedulingOrigin: "process:tightbeam",
      requesterKind: "process",
      requesterId: "tightbeam:wake-scheduler",
      reasonKind: "consumer_unavailable",
      causalSourceKind: "scheduler_delivery",
      outcomeKind: "no_replacement",
      primaryWorkKind: "work_item",
      primaryWorkId: "wi_consumer",
      workImpactKind: "linked_work_not_open",
      actionNeeded: false
    })
  end

  test "cancel and fire ordering has one winner and never writes losing provenance", %{db: db} do
    work_item(db, "wi_cancel_first")
    work_item(db, "wi_fire_first")

    :ok =
      DB.execute(
        db,
        "UPDATE work_items SET state='closed' WHERE id IN ('wi_cancel_first','wi_fire_first')"
      )

    test_pid = self()
    scheduler = :cancellation_order_scheduler

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake.wake_id}) end}
    )

    cancel_first =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "user:flynn",
        prompt: "cancel first",
        due_at: 0,
        work_item_id: "wi_cancel_first"
      })

    assert %{canceled: true} =
             cancel_via_gateway(db, cancel_first.wake_id, "user:flynn", {:user, "flynn"})

    assert :ok = Wakes.fire_due(scheduler)
    cancel_first_id = cancel_first.wake_id
    refute_received {:delivered, ^cancel_first_id}

    cancel_entry = canceled_entry(db, "wi_cancel_first", cancel_first.wake_id)
    assert Map.get(cancel_entry, :provenanceStatus) == "proven"
    refute Enum.any?(trace(db, "wi_cancel_first").timeline, &(&1.type == "wake_fired"))

    fire_first =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "user:flynn",
        prompt: "fire first",
        due_at: 0,
        work_item_id: "wi_fire_first"
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert_received {:delivered, fire_id}
    assert fire_id == fire_first.wake_id

    assert %{canceled: false} =
             cancel_via_gateway(db, fire_first.wake_id, "user:flynn", {:user, "flynn"})

    fire_timeline = trace(db, "wi_fire_first").timeline
    assert Enum.count(fire_timeline, &(&1.type == "wake_fired")) == 1
    refute Enum.any?(fire_timeline, &(&1.type == "wake_canceled"))
  end

  test "replacement and cancellation commit or roll back as one fact", %{db: db} do
    work_item(db, "wi_replace")

    original =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "process:tightbeam",
        prompt: "original",
        due_at: 10,
        work_item_id: "wi_replace"
      })

    {:ok, replacement} =
      DB.transaction(db, fn txn ->
        replacement =
          Wakes.schedule_in_txn(txn, %{
            session_key: "target",
            origin: "process:tightbeam",
            prompt: "replacement",
            due_at: 20,
            work_item_id: "wi_replace"
          })

        assert typed_cancel_in_txn(txn, original.wake_id, %{
                 requester: %{kind: "process", id: "tightbeam:effort-checkin"},
                 reason_kind: "superseded",
                 causal_source: %{kind: "wake", id: replacement.wake_id},
                 outcome: %{kind: "replacement", replacement_wake_id: replacement.wake_id}
               })

        replacement
      end)

    entry = canceled_entry(db, "wi_replace", original.wake_id)

    assert_proven_cancellation(entry, %{
      requesterKind: "process",
      requesterId: "tightbeam:effort-checkin",
      reasonKind: "superseded",
      causalSourceKind: "wake",
      causalSourceId: replacement.wake_id,
      outcomeKind: "replacement",
      replacementWakeId: replacement.wake_id,
      primaryWorkKind: "work_item",
      primaryWorkId: "wi_replace",
      workImpactKind: "linked_work_open",
      actionNeeded: false
    })

    rollback_original =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "process:tightbeam",
        prompt: "rollback original",
        due_at: 30,
        work_item_id: "wi_replace"
      })

    rollback_replacement_id = "w_rollback_replacement"

    assert {:error, _} =
             DB.transaction(db, fn txn ->
               Wakes.schedule_in_txn(txn, %{
                 wake_id: rollback_replacement_id,
                 session_key: "target",
                 origin: "process:tightbeam",
                 prompt: "must roll back",
                 due_at: 40,
                 work_item_id: "wi_replace"
               })

               assert typed_cancel_in_txn(txn, rollback_original.wake_id, %{
                        requester: %{kind: "process", id: "tightbeam:effort-checkin"},
                        reason_kind: "superseded",
                        causal_source: %{kind: "wake", id: rollback_replacement_id},
                        outcome: %{
                          kind: "replacement",
                          replacement_wake_id: rollback_replacement_id
                        }
                      })

               raise "crash before commit"
             end)

    assert Wakes.get(db, rollback_original.wake_id).state == "pending"
    assert Wakes.get(db, rollback_replacement_id) == nil
  end

  test "work-item disposition cancellation names the durable disposition", %{db: db} do
    work_item(db, "wi_dispose_wake")

    wake =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "process:tightbeam",
        prompt: "routing bracket",
        due_at: 10,
        work_item_id: "wi_dispose_wake"
      })

    {:ok, _} =
      DB.query(
        db,
        "UPDATE work_items SET routingWakeId=?2 WHERE id=?1",
        ["wi_dispose_wake", wake.wake_id]
      )

    assert %{workItem: %{state: "closed"}} =
             dispose(db, "work-item-close", "wi_dispose_wake")

    entry = canceled_entry(db, "wi_dispose_wake", wake.wake_id)

    assert_proven_cancellation(entry, %{
      requesterKind: "process",
      requesterId: "tightbeam:work-items",
      reasonKind: "routing_bracket_satisfied",
      causalSourceKind: "work_item_transition",
      outcomeKind: "disposition",
      dispositionKind: "work_item_transition",
      primaryWorkKind: "work_item",
      primaryWorkId: "wi_dispose_wake",
      workImpactKind: "linked_work_not_open",
      actionNeeded: false
    })

    assert is_binary(entry.causalSourceId) and entry.causalSourceId != ""
    assert is_binary(entry.dispositionId) and entry.dispositionId != ""
  end

  test "linked open work cannot be canceled without liveness and action-needed evidence", %{
    db: db
  } do
    work_item(db, "wi_open_cancel")
    session(db, "open-holder")
    assignment(db, "asg_open_cancel", "wi_open_cancel", "open-holder")

    wake =
      Wakes.schedule(db, %{
        session_key: "open-holder",
        origin: "process:tightbeam",
        prompt: "only future trigger",
        due_at: 10,
        assignment_id: "asg_open_cancel"
      })

    {:ok, %{fact_id: fact_id}} =
      DB.transaction(db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "work-blocked",
          scope: "open-holder",
          origin: "session:open-holder"
        })
      end)

    command = %{
      requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
      reason_kind: "production_unmatched",
      causal_source: %{kind: "condition_fact", id: Integer.to_string(fact_id)},
      outcome: %{kind: "no_replacement"}
    }

    {:ok, canceled} =
      DB.transaction(db, fn txn -> typed_cancel_in_txn(txn, wake.wake_id, command) end)

    refute canceled,
           "no-replacement cancellation must refuse linked open work without a trigger"

    assert Wakes.get(db, wake.wake_id).state == "pending"
    refute Enum.any?(trace(db, "wi_open_cancel").timeline, &(&1.type == "wake_canceled"))

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
           basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
        VALUES ('asg_open_cancel', 1, 1000, 'armed', NULL, NULL,
                'assignment_open', 'asg_open_cancel', NULL, 'assignment_open',
                'process:tightbeam', 1000)
        """
      )

    valid_command =
      put_in(command, [:outcome, :liveness_trigger], %{
        kind: "supervision_entitlement",
        id: "asg_open_cancel#1"
      })

    {:ok, true} =
      DB.transaction(db, fn txn -> typed_cancel_in_txn(txn, wake.wake_id, valid_command) end)

    assert_proven_cancellation(canceled_entry(db, "wi_open_cancel", wake.wake_id), %{
      requesterKind: "process",
      requesterId: "tightbeam:wake-scheduler",
      reasonKind: "production_unmatched",
      causalSourceKind: "condition_fact",
      causalSourceId: Integer.to_string(fact_id),
      outcomeKind: "no_replacement",
      primaryWorkKind: "assignment",
      primaryWorkId: "asg_open_cancel",
      workImpactKind: "linked_work_open",
      livenessTriggerKind: "supervision_entitlement",
      livenessTriggerId: "asg_open_cancel#1",
      actionNeeded: true
    })
  end

  test "session retirement cancels direct and role-targeted wakes with typed outcomes", %{db: db} do
    work_item(db, "wi_retire_wakes")
    :ok = DB.execute(db, "UPDATE work_items SET state='closed' WHERE id='wi_retire_wakes'")
    retiring = session(db, "retiring-target")
    Roles.create!(db, "retiring-role", "flynn", retiring.session_key)

    direct =
      Wakes.schedule(db, %{
        session_key: retiring.session_key,
        origin: "process:tightbeam",
        prompt: "direct",
        due_at: 10,
        work_item_id: "wi_retire_wakes"
      })

    role =
      Wakes.schedule(db, %{
        session_key: retiring.session_key,
        target_role: "retiring-role",
        origin: "process:tightbeam",
        prompt: "role",
        due_at: 10,
        work_item_id: "wi_retire_wakes"
      })

    Org.retire(db, retiring.session_key, "user:flynn", 1_000)

    for wake <- [direct, role] do
      assert Wakes.get(db, wake.wake_id).state == "canceled"

      entry = canceled_entry(db, "wi_retire_wakes", wake.wake_id)

      assert_proven_cancellation(entry, %{
        requesterKind: "process",
        requesterId: "tightbeam:retirement",
        reasonKind: "target_retired",
        causalSourceKind: "session_transition",
        outcomeKind: "no_replacement",
        primaryWorkKind: "work_item",
        primaryWorkId: "wi_retire_wakes",
        workImpactKind: "linked_work_not_open",
        actionNeeded: false
      })
    end
  end

  test "committed cancellation survives restart and legacy cancellation remains not proven", %{
    db: db
  } do
    work_item(db, "wi_restart_cancel")
    :ok = DB.execute(db, "UPDATE work_items SET state='closed' WHERE id='wi_restart_cancel'")

    proven =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "user:flynn",
        prompt: "proven",
        due_at: 10,
        work_item_id: "wi_restart_cancel"
      })

    assert %{canceled: true} =
             cancel_via_gateway(db, proven.wake_id, "user:flynn", {:user, "flynn"})

    before_restart = canceled_entry(db, "wi_restart_cancel", proven.wake_id)

    scheduler = :cancellation_restart_scheduler

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    stop_supervised(Wakes)

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    assert canceled_entry(db, "wi_restart_cancel", proven.wake_id) == before_restart
    assert_proven_cancellation(before_restart, %{provenanceStatus: "proven"})

    # Capture the real current wake-table blueprint and seed the preserved
    # production specimen before activation. Historical absence remains absence;
    # the shared epoch proves chronology without a per-wake marker.
    assert {:ok, [[wakes_ddl]]} =
             DB.query(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name='wakes'")

    legacy_db = :"legacy_cancellation_db_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: legacy_db,
      start: {DB, :start_link, [[path: ":memory:", name: legacy_db]]}
    })

    :ok = DB.execute(legacy_db, wakes_ddl <> ";")

    :ok =
      DB.execute(
        legacy_db,
        """
        INSERT INTO wakes
          (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt,
           canceledAt, work_item_id, targetGate)
        VALUES
          ('w_eca7e8a2-646b-4ada-8760-685db9df622c', 'legacy-target',
           'process:legacy', 'preserved production specimen', 'prompt',
           1786352503252, 'canceled', 1786266103252, 1786266112203,
           'wi_legacy_cancel', 1)
        """
      )

    :ok = Tightbeam.Schema.ensure_all(legacy_db)

    :ok =
      DB.execute(legacy_db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',1,1)")

    work_item(legacy_db, "wi_legacy_cancel")

    :ok =
      DB.execute(legacy_db, "UPDATE work_items SET state='closed' WHERE id='wi_legacy_cancel'")

    assert {:ok, [[0]]} =
             DB.query(
               legacy_db,
               "SELECT count(*) FROM wake_cancellations WHERE wakeId='w_eca7e8a2-646b-4ada-8760-685db9df622c'"
             )

    assert {:ok, [[activated_at]]} =
             DB.query(
               legacy_db,
               "SELECT activatedAt FROM supervision_liveness_epoch WHERE id=0"
             )

    assert activated_at >= 1_786_266_112_203

    assert_legacy_cancellation(
      canceled_entry(
        legacy_db,
        "wi_legacy_cancel",
        "w_eca7e8a2-646b-4ada-8760-685db9df622c"
      ),
      scheduling_origin: "process:legacy"
    )
  end

  ## Proofs 2 + 3 — supervision prods, and prod-turn attribution end to end

  test "proofs 2 and 3: a prod carries its tier, its wake carries the assignment, and the delivered turn is attributed",
       ctx do
    db = ctx.db
    work_item(db, "wi_prod")
    session(db, "supervisor")
    session(db, "holder", "supervisor")
    assignment(db, "asg_prod", "wi_prod", "holder")
    insert_entitlement!(db, "asg_prod")
    handlers = Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), default_harness: :claude})

    seq = turn(db, "holder", status: "delivered")
    assert {:prodded, 1} = Supervision.evaluate(db, handlers, 3, "holder", seq)

    assert [%{kind: "prod_fired"} = fired] = CausalEvents.for_job(db, "wi_prod", [])
    assert fired.detail["tier"] == 1
    assert fired.assignment_id == "asg_prod"
    assert fired.job_ref == "wi_prod"
    assert fired.session_key == "holder"

    # The wake now CARRIES the assignment — v1's missing durable carrier.
    [prod] = Wakes.list_pending(db)
    assert prod.assignment_id == "asg_prod"

    assert :appended =
             Gateway.deliver_prompt(prod.session_key, prod.origin, prod.prompt,
               db: db,
               wake_id: prod.wake_id,
               sender: prod.origin,
               target_gate: prod,
               fire_wake_in_txn: true,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane
             )

    # ...so the delivered turn is stamped with BOTH carriers.
    assert {:ok, [["asg_prod", "wi_prod"]]} =
             DB.query(db, "SELECT assignmentId, jobRef FROM turns WHERE wakeId = ?1", [
               prod.wake_id
             ])

    # ...and therefore appears in the trace, closing the v1 exclusion.
    timeline = trace(db, "wi_prod").timeline

    assert Enum.any?(timeline, fn
             %{type: "turn_start", assignmentId: "asg_prod", jobRef: "wi_prod"} -> true
             _ -> false
           end)

    assert Enum.any?(timeline, &(&1.type == "causal_event" and &1.kind == "prod_fired"))
  end

  test "proof 2: vague attests do not mint legacy prod_answered events", ctx do
    db = ctx.db
    work_item(db, "wi_answer")
    session(db, "supervisor")
    session(db, "holder", "supervisor")
    assignment(db, "asg_answer", "wi_answer", "holder")
    insert_entitlement!(db, "asg_answer")
    handlers = Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), default_harness: :claude})

    assert {:prodded, 1} = evaluate(db, handlers, "holder")
    assert answered(db) == []

    # TWO untyped completion claims land between evaluations. Neither is a
    # liveness receipt and the retired causal kind stays empty.
    attest(db, "att_b", "asg_answer")
    attest(db, "att_a", "asg_answer")

    evaluate(db, handlers, "holder")
    assert answered(db) == []

    # Re-evaluating sees nothing new: this table is its own watermark.
    evaluate(db, handlers, "holder")
    assert answered(db) == []

    # A later vague claim also remains inert.
    attest(db, "att_c", "asg_answer")
    evaluate(db, handlers, "holder")
    assert answered(db) == []
  end

  test "proof 2: an effort rung advance records the rung and expecter it left", ctx do
    db = ctx.db
    work_item(db, "wi_effort")
    session(db, "parent")
    session(db, "holder", "parent")
    assignment(db, "asg_effort", "wi_effort", "holder")

    wake =
      Wakes.schedule(db, %{
        session_key: "holder",
        origin: "process:tightbeam",
        consumer: "effort_deadline",
        due_at: 1,
        assignment_id: "asg_effort"
      })

    :ok =
      DB.execute(db, """
      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, assignmentId, expecterSessionKey,
         lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt,
         question, options, context, status)
      VALUES ('dr_effort', 'effort', 'process:tightbeam', 'flynn', 'asg_effort',
              'holder', 1, 1, '#{wake.wake_id}', 1, 1, 'q', '[]', '{}', 'open')
      """)

    assert :ok = EffortCheckin.deadline(db, %{}, wake)

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT lineageRung FROM decision_requests WHERE id = 'dr_effort'")

    assert [%{kind: "effort_rung_advance"} = event] = CausalEvents.for_job(db, "wi_effort", [])
    assert event.assignment_id == "asg_effort"
    assert event.job_ref == "wi_effort"
    assert event.detail["requestId"] == "dr_effort"
    assert event.detail["fromRung"] == 1
    assert event.detail["toRung"] == 2
    assert event.detail["fromExpecter"] == "session:holder"
    assert is_binary(event.detail["toExpecter"])
    assert event.detail["toExpecter"] != event.detail["fromExpecter"]
  end

  ## Proof 8 — the trace's additive types leave v1 consumers alone

  test "proof 8: causal events join the timeline at their own rank without disturbing v1 entries",
       %{db: db} do
    work_item(db, "wi_rank")
    session(db, "holder")
    assignment(db, "asg_rank", "wi_rank")
    turn(db, "holder", assignment_id: "asg_rank", job_ref: "wi_rank", status: "delivered")

    for kind <- ["prod_fired", "disposition_transition"] do
      {:ok, :ok} =
        DB.transaction(db, fn txn ->
          CausalEvents.append_in_txn(txn, %{
            kind: kind,
            at: 50,
            job_ref: "wi_rank",
            assignment_id: if(kind == "prod_fired", do: "asg_rank"),
            detail: %{tier: 1, workItemId: "wi_rank", fromState: "open", toState: "closed"}
          })
        end)
    end

    timeline = trace(db, "wi_rank").timeline

    # v1 types keep their relative order and their exact key sets; the sorter
    # requires an explicit rank per type, and the new ones have theirs.
    v1_types = Enum.filter(timeline, &(&1.type in ["turn_start", "turn_end"]))
    assert Enum.map(v1_types, & &1.type) == ["turn_start", "turn_end"]

    causal = Enum.filter(timeline, &(&1.type == "causal_event"))
    assert length(causal) == 2
    assert Enum.map(causal, & &1.seqTiebreak) == Enum.sort(Enum.map(causal, & &1.seqTiebreak))
    assert Enum.all?(causal, &String.starts_with?(&1.id, "ce:"))

    # Equal `at` -> rank decides: causal_event (5) sorts after decision_request
    # (4) and before effort_generation (6), and turn_end (8) stays last.
    assert List.last(timeline).type == "turn_end"
  end

  ## Cross-review regressions (Sol CHANGES-REQUIRED, 2026-07-26)

  test "F5: the retired prod_answered writer does not reinterpret attest history", ctx do
    db = ctx.db
    work_item(db, "wi_pre")
    session(db, "supervisor")
    session(db, "holder", "supervisor")
    assignment(db, "asg_pre", "wi_pre", "holder")
    insert_entitlement!(db, "asg_pre")
    handlers = Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), default_harness: :claude})

    # The v2-epoch cutoff is when causal_events was created; PRE-v2 attests are the
    # ones filed before it. `attestCount` is deliberately left stale here (0) so
    # the bound cannot be coming from the counter — only the timestamp floor can
    # keep these three out.
    cutoff = CausalEvents.epoch(db)

    for id <- ["att_old_a", "att_old_b", "att_old_c"],
        do: attest(db, id, "asg_pre", cutoff - 5_000)

    assert answered(db) == []

    # ONE attest arrives AFTER the cutoff.
    attest(db, "att_new", "asg_pre", cutoff + 1_000)
    evaluate(db, handlers, "holder")

    assert answered(db) == [], "attest history is not a liveness receipt"

    # A later evaluation still never reaches back across the cutoff.
    attest(db, "att_newer", "asg_pre", cutoff + 2_000)
    evaluate(db, handlers, "holder")
    assert answered(db) == []
  end

  test "F5: a stale pre-v2 aggregate cannot revive the retired writer", ctx do
    db = ctx.db
    work_item(db, "wi_stale")
    session(db, "supervisor")
    session(db, "holder", "supervisor")
    assignment(db, "asg_stale", "wi_stale", "holder")
    insert_entitlement!(db, "asg_stale")
    handlers = Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), default_harness: :claude})

    cutoff = CausalEvents.epoch(db)
    for id <- ["att_p1", "att_p2", "att_p3"], do: attest(db, id, "asg_stale", cutoff - 9_000)

    # An UNDERSTATED aggregate — the shape a pre-v2 row takes after a prod reset,
    # and the one that breaks a count-delta bound: delta would be 4-0=4, sweeping
    # all three historical attests along with the new one. attestCount is a
    # MUTABLE aggregate, which is exactly why the bound cannot be built on it.
    :ok =
      DB.execute(db, """
      INSERT INTO assignment_prods
        (assignmentId, attemptCount, prodCount, deniedStreak, attestCount)
      VALUES ('asg_stale', 0, 1, 0, 0)
      """)

    attest(db, "att_after", "asg_stale", cutoff + 500)
    evaluate(db, handlers, "holder")

    assert answered(db) == [],
           "a mutable aggregate cannot turn attest history into receipts"
  end

  test "F6: an agent cannot forge wake or turn attribution", ctx do
    db = ctx.db
    work_item(db, "wi_forge")
    session(db, "agent-session")
    assignment(db, "asg_victim", "wi_forge", "agent-session")
    handlers = Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), default_harness: :claude})

    forge = fn principal ->
      handlers["wake"].(%{
        verb: "wake",
        origin: "user:flynn",
        principal: principal,
        session_key: "agent-session",
        params: %{
          prompt: "an ordinary conversational wake",
          after_ms: 0,
          nudge: false,
          assignment_id: "asg_victim"
        }
      })
    end

    # An AGENT supplying assignment_id gets it dropped: a conversational wake is
    # NULL, and no forged carrier can reach the turn or the trace (Law 0).
    %{wake_id: agent_wake} = forge.({:session, "agent-session"})
    assert is_nil(Wakes.get(db, agent_wake).assignment_id)

    # And the spec's pinned defence is at the BOUNDARY: the field never survives
    # an agent/dispatch param map, so no handler has to remember to distrust it.
    refute Map.has_key?(
             Tightbeam.Wire.Router.atomize_params_for_test("wake", %{
               "prompt" => "p",
               "assignmentId" => "asg_victim"
             }),
             :assignment_id
           )

    # ...and ONLY for that carrier: assignmentId is an ordinary caller param on the
    # verbs that name the assignment they act on, so the strip must not reach them.
    assert %{assignment_id: "asg_victim"} =
             Tightbeam.Wire.Router.atomize_params_for_test("attest", %{
               "assignmentId" => "asg_victim",
               "kind" => "completion"
             })

    # The SUBSTRATE's own principal — which the router reserves and refuses to
    # mint for a wire caller — is the only one that may stamp it.
    %{wake_id: substrate_wake} = forge.({:process, "tightbeam"})
    assert Wakes.get(db, substrate_wake).assignment_id == "asg_victim"
  end

  ## Helpers

  defp insert_entitlement!(db, assignment_id) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_entitlements
          (assignmentId,generation,dueAt,state,lastAttemptGeneration,claimClock,
           basisKind,basisId,terminusAt,cause,principal,supervisionIntervalMs)
        VALUES (?1,1,0,'armed',NULL,NULL,'assignment_open',?1,NULL,
                'assignment_open','process:tightbeam',60000)
        """,
        [assignment_id]
      )

    :ok
  end

  # One turn-end shift. A prod leaves a PENDING wake, and the turn-end schedule's
  # pending-wake gate halts before the ladder while one exists — delivery is what
  # clears it in production, so fire it here.
  defp evaluate(db, handlers, session_key) do
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state = 'fired', firedAt = 1 WHERE state = 'pending'")

    seq = turn(db, session_key, status: "delivered")
    Supervision.evaluate(db, handlers, 3, session_key, seq)
  end

  defp answered(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT json_extract(detail, '$.byAttestId') FROM causal_events WHERE kind = 'prod_answered' ORDER BY seq"
      )

    Enum.map(rows, &hd/1)
  end

  defp trace(db, work_item_id) do
    WorkItems.__handle__(db, "work-item-trace", %{
      verb: "work-item-trace",
      principal: {:user, "flynn"},
      origin: "user:flynn",
      session_key: nil,
      params: %{work_item_id: work_item_id}
    })
  end

  defp dispose(db, verb, id, params \\ %{}) do
    WorkItems.__handle__(db, verb, %{
      verb: verb,
      principal: {:user, "flynn"},
      origin: "user:flynn",
      session_key: nil,
      params: Map.merge(%{work_item_id: id}, params)
    })
  end

  defp work_item(db, id) do
    :ok =
      DB.execute(db, """
      INSERT INTO work_items (id, title, ownerUserId, state, createdByUser, createdAt)
      VALUES ('#{id}', 'Item #{id}', 'flynn', 'open', 'flynn', 1)
      """)
  end

  defp assignment(db, id, work_item_id, holder \\ "holder") do
    :ok =
      DB.execute(db, """
      INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, state, workItemId)
      VALUES ('#{id}', 'subject #{id}', '#{holder}', 'flynn', 1, 'open', '#{work_item_id}')
      """)
  end

  defp attest(db, id, assignment_id, ts \\ nil) do
    ts = ts || System.system_time(:millisecond)

    :ok =
      DB.execute(db, """
      INSERT INTO attests (id, assignmentId, kind, bySession, ts)
      VALUES ('#{id}', '#{assignment_id}', 'completion', 'holder', #{ts})
      """)
  end

  defp session(db, key, spawned_by \\ nil) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })
  end

  defp turn(db, session_key, opts \\ []) do
    {:ok, {:ok, seq}} =
      DB.transaction(db, fn txn ->
        Ledger.enqueue_in_txn(txn, %{
          session_key: session_key,
          message_id: "m_#{System.unique_integer([:positive])}",
          origin: "user:flynn",
          prompt: "p",
          assignment_id: Keyword.get(opts, :assignment_id),
          job_ref: Keyword.get(opts, :job_ref)
        })
      end)

    status = Keyword.get(opts, :status, "queued")

    {:ok, _} =
      DB.query(db, "UPDATE turns SET status = ?2, createdAt = ?3, endedAt = ?4 WHERE seq = ?1", [
        seq,
        status,
        Keyword.get(opts, :created_at, 10),
        if(status in ~w(queued running), do: nil, else: Keyword.get(opts, :ended_at, 100))
      ])

    seq
  end

  defp fetch_item(db, id) do
    WorkItems.__handle__(db, "work-item-get", %{
      verb: "work-item-get",
      principal: {:user, "flynn"},
      origin: "user:flynn",
      session_key: nil,
      params: %{work_item_id: id}
    })
  end

  defp state(db, id) do
    {:ok, [[state]]} = DB.query(db, "SELECT state FROM work_items WHERE id = ?1", [id])
    state
  end

  defp columns(db, table) do
    {:ok, rows} = DB.query(db, "PRAGMA table_info(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp tables(db) do
    {:ok, rows} = DB.query(db, "SELECT name FROM sqlite_master WHERE type = 'table'")
    Enum.map(rows, &hd/1)
  end

  defp indexes(db, table) do
    {:ok, rows} =
      DB.query(db, "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?1", [
        table
      ])

    Enum.map(rows, &hd/1)
  end

  defp cancel_via_gateway(db, wake_id, origin, principal) do
    {requester_kind, requester_id} = principal

    %{
      canceled:
        public_cancel(db, wake_id, origin, %{
          kind: Atom.to_string(requester_kind),
          id: requester_id
        })
    }
  end

  defp public_cancel(db, wake_id, expected_origin, requester) do
    principal = requester_principal(requester)
    session_key = if requester.kind == "session", do: requester.id

    case DB.transaction(db, fn txn ->
           if Wakes.cancel_in_txn(txn, %{
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
              }) do
             true
           else
             raise "typed cancellation refused"
           end
         end) do
      {:ok, true} -> true
      {:error, _} -> false
    end
  end

  defp requester_principal(%{kind: "user", id: id}), do: {:user, id}
  defp requester_principal(%{kind: "session", id: id}), do: {:session, id}
  defp requester_principal(%{kind: "process", id: id}), do: {:process, id}

  defp typed_cancel_in_txn(%Txn{} = txn, wake_id, command) do
    apply(Wakes, :cancel_in_txn, [txn, Map.put(command, :wake_id, wake_id)])
  end

  defp canceled_entry(db, work_item_id, wake_id) do
    db
    |> trace(work_item_id)
    |> Map.fetch!(:timeline)
    |> Enum.find(&(&1.type == "wake_canceled" and &1.id == wake_id))
  end

  defp assert_proven_cancellation(entry, expected) do
    missing = Enum.reject(@cancellation_projection_keys, &Map.has_key?(entry, &1))
    assert missing == [], "missing cancellation projection keys: #{inspect(missing)}"
    assert entry.reason == nil
    assert entry.provenanceStatus == "proven"
    assert Map.take(entry, Map.keys(expected)) == expected
  end

  defp assert_legacy_cancellation(entry, scheduling_origin: scheduling_origin) do
    expected =
      @cancellation_projection_keys
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        provenanceStatus: "not_proven",
        schedulingOrigin: scheduling_origin
      })

    assert Map.take(entry, @cancellation_projection_keys) == expected
    assert entry.reason == nil
  end

  defp assert_keys(map, keys), do: assert(Map.keys(map) |> Enum.sort() == Enum.sort(keys))
end
