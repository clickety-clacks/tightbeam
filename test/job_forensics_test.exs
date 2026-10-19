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
      ~w(body bodyUpdatedAt bodyUpdatedBySession bodyUpdatedByUser createdAt
         createdBySession createdByUser deliveryOwnerSessionKey failReason id isBug ownerUserId priority
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

    # Path 1: the authenticated recorded sender.
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
    refute public_cancel(db, c.wake_id, "user:flynn", %{kind: "user", id: "someone-else"})
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
    session(db, "other-session")

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
               "agent:reviewer",
               {:session, "other-session"}
             )

    refute Enum.any?(trace(db, "wi_requester").timeline, &(&1.type == "wake_canceled"))

    # A changed role label does not change the recorded sender.
    assert %{canceled: true} =
             cancel_via_gateway(
               db,
               wake.wake_id,
               "agent:another-role",
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
      primaryWorkKind: nil,
      primaryWorkId: nil,
      workImpactKind: "no_linked_work",
      actionNeeded: false
    })

    # Sender withdrawal does not evaluate linked-work liveness or dispose of it.
    # The notice still retains its association for trace discovery.
    assert Wakes.get(db, wake.wake_id).work_item_id == "wi_requester"

    assert {:ok, [["closed"]]} =
             DB.query(db, "SELECT state FROM work_items WHERE id='wi_requester'")

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

  test "cancel and fire ordering has one winner and never writes losing provenance", %{
    db: db,
    registry: registry,
    lane: lane
  } do
    work_item(db, "wi_cancel_first")
    work_item(db, "wi_fire_first")
    session(db, "target")

    :ok =
      DB.execute(
        db,
        "UPDATE work_items SET state='closed' WHERE id IN ('wi_cancel_first','wi_fire_first')"
      )

    scheduler = :cancellation_order_scheduler

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       delivery_opts: [conn_registry: registry, lane_manager: lane],
       deliver: fn _wake -> flunk("normal cancellation-order source used legacy callback") end}
    )

    cancel_first =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "user:flynn",
        prompt: "cancel first",
        due_at: 0,
        sender_scheduled: true,
        work_item_id: "wi_cancel_first"
      })

    assert %{canceled: true} =
             cancel_via_gateway(db, cancel_first.wake_id, "user:flynn", {:user, "flynn"})

    assert :ok = Wakes.fire_due(scheduler)
    assert %{state: "canceled", fired_at: nil} = Wakes.get(db, cancel_first.wake_id)
    assert Tightbeam.NoticeBatcher.source_refs(db, cancel_first.wake_id) == []
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM turns")

    cancel_entry = canceled_entry(db, "wi_cancel_first", cancel_first.wake_id)
    assert Map.get(cancel_entry, :provenanceStatus) == "proven"
    refute Enum.any?(trace(db, "wi_cancel_first").timeline, &(&1.type == "wake_fired"))

    fire_first =
      Wakes.schedule(db, %{
        session_key: "target",
        origin: "user:flynn",
        prompt: "fire first",
        due_at: 0,
        sender_scheduled: true,
        work_item_id: "wi_fire_first"
      })

    assert :ok = Wakes.fire_due(scheduler)

    [%{delivery_wake_id: fire_carrier_id, member_state: "included", batch_state: "delivered"}] =
      Tightbeam.NoticeBatcher.source_refs(db, fire_first.wake_id)

    assert %{state: "fired"} = Wakes.get(db, fire_first.wake_id)
    assert %{state: "fired", digest: true} = Wakes.get(db, fire_carrier_id)

    assert {:ok, [["target", "queued", actual_prompt]]} =
             DB.query(db, "SELECT sessionKey,status,prompt FROM turns WHERE wakeId=?1", [
               fire_carrier_id
             ])

    assert actual_prompt =~ fire_first.prompt
    assert actual_prompt =~ fire_first.wake_id

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [fire_first.wake_id])

    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM turns")

    assert %{canceled: false} =
             cancel_via_gateway(db, fire_first.wake_id, "user:flynn", {:user, "flynn"})

    fire_timeline = trace(db, "wi_fire_first").timeline
    fired_ids = fire_timeline |> Enum.filter(&(&1.type == "wake_fired")) |> Enum.map(& &1.id)
    assert Enum.count(fired_ids, &(&1 == fire_first.wake_id)) == 1
    assert Enum.count(fired_ids, &(&1 == fire_carrier_id)) == 1
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

  test "linked open work cancellation stays actionable after progress without a continuation", %{
    db: db
  } do
    work_item(db, "wi_open_cancel")
    session(db, "open-holder")
    assignment(db, "asg_open_cancel", "wi_open_cancel", "open-holder")

    opened_at = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_open_cancel",
               opened_at
             ])

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.Supervision.assignment_opened_in_txn(
                 txn,
                 "asg_open_cancel",
                 opened_at,
                 60_000
               )
             end)

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

    assert {:ok, [[trigger_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer='assignment_inactivity_deadline' AND state='pending'",
               ["asg_open_cancel"]
             )

    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               {:ok, trigger} =
                 Tightbeam.Supervision.inactivity_deadline_trigger_in_txn(
                   txn,
                   {:assignment, "asg_open_cancel"}
                 )

               typed_cancel_in_txn(
                 txn,
                 wake.wake_id,
                 put_in(command, [:outcome, :liveness_trigger], trigger)
               )
             end)

    entry = canceled_entry(db, "wi_open_cancel", wake.wake_id)

    assert_proven_cancellation(entry, %{
      requesterKind: "process",
      requesterId: "tightbeam:wake-scheduler",
      reasonKind: "production_unmatched",
      causalSourceKind: "condition_fact",
      causalSourceId: Integer.to_string(fact_id),
      outcomeKind: "no_replacement",
      replacementWakeId: nil,
      dispositionKind: nil,
      dispositionId: nil,
      primaryWorkKind: "assignment",
      primaryWorkId: "asg_open_cancel",
      workImpactKind: "linked_work_open",
      livenessTriggerKind: "pending_wake",
      livenessTriggerId: trigger_id,
      actionNeeded: true
    })

    :ok =
      DB.execute(db, """
      INSERT INTO attests (id, assignmentId, kind, bySession, ts)
      VALUES
        ('att_after_cancel_1', 'asg_open_cancel', 'progress', 'open-holder', 20),
        ('att_after_cancel_2', 'asg_open_cancel', 'progress', 'open-holder', 30)
      """)

    assert {:ok, [["open", nil]]} =
             DB.query(
               db,
               "SELECT state, reviewsAssignmentId FROM assignments WHERE id='asg_open_cancel'"
             )

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM attests WHERE assignmentId='asg_open_cancel' AND kind='progress'"
             )

    assert {:ok, [["armed", 1, 1000]]} =
             DB.query(
               db,
               "SELECT state, generation, dueAt FROM supervision_entitlements WHERE assignmentId='asg_open_cancel'"
             )

    after_progress = canceled_entry(db, "wi_open_cancel", wake.wake_id)
    assert after_progress.livenessTriggerId == "asg_open_cancel#1"
    assert after_progress.actionNeeded
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

    # Reconstruct the pre-payload wake table before seeding the preserved
    # specimen. Successor source columns cannot accompany a predecessor stamp;
    # the shared epoch still proves chronology without a per-wake marker.
    assert {:ok, [[wakes_ddl]]} =
             DB.query(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name='wakes'")

    legacy_db = :"legacy_cancellation_db_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: legacy_db,
      start: {DB, :start_link, [[path: ":memory:", name: legacy_db]]}
    })

    :ok = DB.execute(legacy_db, wakes_ddl <> ";")

    # Model an older schema that already had the retired supervision history
    # columns. The 0.1.10 source migration must preserve these when restoring
    # the newer notice columns below; it need not create them on a fresh store.
    :ok =
      DB.execute(legacy_db, """
      ALTER TABLE wakes ADD COLUMN idleCleanupObserved INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE wakes ADD COLUMN idleCleanupGroup TEXT;
      ALTER TABLE wakes ADD COLUMN idleCleanupRecorded INTEGER NOT NULL DEFAULT 0;
      """)

    # A predecessor fixture must exclude later delivery and source columns.
    :ok =
      DB.execute(legacy_db, """
      ALTER TABLE wakes DROP COLUMN sourceClientIdentity;
      ALTER TABLE wakes DROP COLUMN sourceAttachments;
      ALTER TABLE wakes DROP COLUMN sourceVisibilityScope;
      ALTER TABLE wakes DROP COLUMN sourceAddress;
      ALTER TABLE wakes DROP COLUMN deliveredTurnSeq;
      """)

    assert {:ok, []} =
             DB.query(legacy_db, """
             SELECT name FROM pragma_table_info('wakes')
             WHERE name IN ('sourceClientIdentity','sourceAttachments','sourceVisibilityScope','sourceAddress',
                            'deliveredTurnSeq')
             """)

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

    assert {:ok,
            [
              ["deliveredTurnSeq"],
              ["idleCleanupGroup"],
              ["idleCleanupObserved"],
              ["idleCleanupRecorded"],
              ["sourceAddress"],
              ["sourceAttachments"],
              ["sourceClientIdentity"],
              ["sourceVisibilityScope"]
            ]} =
             DB.query(legacy_db, """
             SELECT name FROM pragma_table_info('wakes')
             WHERE name IN ('sourceClientIdentity','sourceAttachments','sourceVisibilityScope','sourceAddress',
                            'deliveredTurnSeq','idleCleanupObserved','idleCleanupGroup','idleCleanupRecorded')
             ORDER BY name
             """)

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

    for kind <- ["disposition_transition"] do
      {:ok, :ok} =
        DB.transaction(db, fn txn ->
          CausalEvents.append_in_txn(txn, %{
            kind: kind,
            at: 50,
            job_ref: "wi_rank",
            assignment_id: "asg_rank",
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
    assert length(causal) == 1
    assert hd(causal).kind == "disposition_transition"
    assert Enum.map(causal, & &1.seqTiebreak) == Enum.sort(Enum.map(causal, & &1.seqTiebreak))
    assert Enum.all?(causal, &String.starts_with?(&1.id, "ce:"))

    # Equal `at` -> rank decides: causal_event (5) sorts after decision_request
    # (4) and before effort_generation (6), and turn_end (8) stays last.
    assert List.last(timeline).type == "turn_end"
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
