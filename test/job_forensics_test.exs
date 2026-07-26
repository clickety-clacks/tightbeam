defmodule Tightbeam.JobForensicsTest do
  @moduledoc """
  Proofs for spec job-forensics-v2 — attribution columns, the causal_events
  append, and the trace extension.

  Law 0 holds throughout: every row asserted here is a substrate side effect of
  a domain write, never something a caller authored.
  """
  use ExUnit.Case, async: false

  alias Tightbeam.{
    Adjudication,
    Assignments,
    CausalEvents,
    ConditionFacts,
    CriticalLeases,
    DB,
    Devices,
    EffortCheckin,
    Escalation,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Projection,
    Roles,
    SubagentMarkers,
    Supervision,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.DB.Txn

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
    registry = start_supervised!({Tightbeam.ConnRegistry, name: :"forensics_reg_#{System.unique_integer([:positive])}"})
    lane = start_supervised!({LaneDoorbell, :"forensics_lane_#{System.unique_integer([:positive])}"})

    for module <- [
          CausalEvents,
          Devices,
          ConditionFacts,
          Idempotency,
          Ledger,
          EventLog,
          Escalation,
          Wakes,
          Projection,
          Org,
          CriticalLeases,
          Roles,
          WorkItems,
          Assignments,
          WorkState,
          EffortCheckin,
          Adjudication,
          Supervision,
          SubagentMarkers
        ],
        do: :ok = module.ensure_schema(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',1,1)"
      )

    %{db: db, registry: registry, lane: lane}
  end

  ## Proof 9 — migration

  test "proof 9: every column is an additive ALTER, causal_events is fresh, rows survive", %{
    db: db
  } do
    # A pre-v2 database: the tables exist, with rows, and none of the new
    # columns. ensure_schema must widen them without touching the rows.
    :ok = DB.execute(db, "DROP TABLE causal_events")

    for {table, column} <- [
          {"wakes", "assignmentId"},
          {"wakes", "canceledAt"},
          {"adjudication_episodes", "assignmentId"},
          {"adjudication_episodes", "jobRef"},
          {"subagent_markers", "assignmentId"}
        ] do
      assert column in columns(db, table), "#{table}.#{column} must exist after ensure_schema"
    end

    wake = Wakes.schedule(db, %{session_key: "k1", origin: "user:flynn", prompt: "p", due_at: 1})

    # Re-running the migration is a no-op that preserves the row (duplicate
    # column errors are swallowed; anything else raises).
    :ok = Wakes.ensure_schema(db)
    :ok = Adjudication.ensure_schema(db)
    :ok = SubagentMarkers.ensure_schema(db)
    :ok = CausalEvents.ensure_schema(db)

    assert Wakes.get(db, wake.wake_id).wake_id == wake.wake_id
    assert "causal_events" in tables(db)

    indexes = indexes(db, "causal_events")
    assert "causal_events_job" in indexes
    assert "causal_events_assignment" in indexes
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
         specRefName specRefSha256 state title)a
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

  test "proof 4: an episode carries its FAILING TURN's attribution, and reopen appends", %{db: db} do
    work_item(db, "wi_epi")
    session(db, "holder")
    assignment(db, "asg_epi", "wi_epi")

    # The failing turn is the durable carrier; the resolver reads THAT row.
    seq = turn(db, "holder", assignment_id: "asg_epi", job_ref: "wi_epi", status: "failed")

    {:ok, episode} =
      DB.transaction(db, fn txn ->
        Adjudication.claim_in_txn(txn, "holder", "other",
          claim_window_ms: 300_000,
          cause: "adapter_fault:claude:shared@testhost",
          failing_seq: seq
        )
      end)

    assert episode.assignment_id == "asg_epi"
    assert episode.job_ref == "wi_epi"

    # v1 reads still see the same CURRENT row.
    assert Adjudication.get(db, "holder", "other").status == "claimed"
    assert Adjudication.get_by_correlation(db, episode.correlation_key).condition == "other"

    {:ok, _} =
      DB.transaction(db, fn txn ->
        Adjudication.resolve_in_txn(
          txn,
          %{episode | status: "notified"} |> notified_in_txn(txn)
        )
      end)

    {:ok, reopened} =
      DB.transaction(db, fn txn ->
        Adjudication.reopen_in_txn(txn, "holder", "other",
          claim_window_ms: 300_000,
          cause: "adapter_fault:claude:shared@testhost",
          failing_seq: seq,
          reresolve_rung: 2
        )
      end)

    assert [%{kind: "adjudication_reopen"} = event] = CausalEvents.for_job(db, "wi_epi", [])
    assert event.assignment_id == "asg_epi"
    assert event.job_ref == "wi_epi"
    assert event.session_key == "holder"
    assert event.detail["episodeId"] == reopened.episode_id
    assert event.detail["fromState"] == "resolved"
    assert event.detail["toState"] == "claimed"
    assert event.detail["toRung"] == 2
  end

  test "proof 4: an episode whose failing turn has NULL attribution stamps NULL", %{db: db} do
    session(db, "holder")
    seq = turn(db, "holder", status: "failed")

    {:ok, episode} =
      DB.transaction(db, fn txn ->
        Adjudication.claim_in_txn(txn, "holder", "other",
          claim_window_ms: 300_000,
          failing_seq: seq
        )
      end)

    assert is_nil(episode.assignment_id)
    assert is_nil(episode.job_ref)
  end

  test "proof 4: an overdue escalation appends its rung and target", %{db: db} do
    work_item(db, "wi_esc")
    session(db, "parent")
    session(db, "holder", "parent")
    assignment(db, "asg_esc", "wi_esc")
    seq = turn(db, "holder", assignment_id: "asg_esc", job_ref: "wi_esc", status: "failed")

    {:ok, episode} =
      DB.transaction(db, fn txn ->
        claimed =
          Adjudication.claim_in_txn(txn, "holder", "other",
            claim_window_ms: 0,
            failing_seq: seq
          )

        {:ok, _wake, _target} = Adjudication.notify_in_txn(txn, claimed, "adjudicate", 0)
        claimed
      end)

    :ok = Adjudication.escalate_due(db, 86_400_000)

    assert [%{kind: "adjudication_escalate"} = event] = CausalEvents.for_job(db, "wi_esc", [])
    assert event.assignment_id == "asg_esc"
    assert event.detail["episodeId"] == episode.episode_id
    assert event.detail["toState"] == "notified"
    assert event.detail["toRung"] == 2
    assert is_binary(event.detail["toTarget"])
  end

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

    # Path 1: the origin-guarded helper (the one most callers use).
    a = Wakes.schedule(db, %{session_key: "k1", origin: "user:flynn", prompt: "a", due_at: 1})
    assert Wakes.cancel(db, a.wake_id, "user:flynn")
    assert is_integer(Wakes.get(db, a.wake_id).canceled_at)

    # Path 2: the substrate-internal cancel (escalation retarget, park supersede).
    b = Wakes.schedule(db, %{session_key: "k1", origin: "process:tightbeam", prompt: "b", due_at: 1})

    {:ok, true} = DB.transaction(db, fn txn -> Wakes.cancel_pending_in_txn(txn, b.wake_id) end)
    assert is_integer(Wakes.get(db, b.wake_id).canceled_at)

    # A refused cancel stamps nothing.
    c = Wakes.schedule(db, %{session_key: "k1", origin: "user:flynn", prompt: "c", due_at: 1})
    refute Wakes.cancel(db, c.wake_id, "user:someone-else")
    assert is_nil(Wakes.get(db, c.wake_id).canceled_at)
    assert Wakes.get(db, c.wake_id).state == "pending"

    # No cancel path anywhere may write state without the timestamp.
    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE state='canceled' AND canceledAt IS NULL")
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

    {:ok, true} = DB.transaction(db, fn txn -> Wakes.cancel_pending_in_txn(txn, wake.wake_id) end)

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

  ## Proofs 2 + 3 — supervision prods, and prod-turn attribution end to end

  test "proofs 2 and 3: a prod carries its tier, its wake carries the assignment, and the delivered turn is attributed",
       ctx do
    db = ctx.db
    work_item(db, "wi_prod")
    session(db, "supervisor")
    session(db, "holder", "supervisor")
    assignment(db, "asg_prod", "wi_prod", "holder")
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

  test "proof 2: prod_answered emits ONE event per previously-unseen attest, in id order", ctx do
    db = ctx.db
    work_item(db, "wi_answer")
    session(db, "supervisor")
    session(db, "holder", "supervisor")
    assignment(db, "asg_answer", "wi_answer", "holder")
    handlers = Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), default_harness: :claude})

    assert {:prodded, 1} = evaluate(db, handlers, "holder")
    assert answered(db) == []

    # TWO attests land between evaluations; each keeps its own edge.
    attest(db, "att_b", "asg_answer")
    attest(db, "att_a", "asg_answer")

    evaluate(db, handlers, "holder")
    assert answered(db) == ["att_a", "att_b"], "one event per attest, ordered by attest id"

    # Re-evaluating sees nothing new: this table is its own watermark.
    evaluate(db, handlers, "holder")
    assert answered(db) == ["att_a", "att_b"]

    # A LATER attest gets its own event, and only its own.
    attest(db, "att_c", "asg_answer")
    evaluate(db, handlers, "holder")
    assert answered(db) == ["att_a", "att_b", "att_c"]
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

  test "F5: a post-migration attest does NOT backfill pre-v2 attest history", ctx do
    db = ctx.db
    work_item(db, "wi_pre")
    session(db, "supervisor")
    session(db, "holder", "supervisor")
    assignment(db, "asg_pre", "wi_pre", "holder")
    handlers = Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), default_harness: :claude})

    # A pre-v2 database: three attests already exist and are already COUNTED, but
    # causal_events is empty because the table did not exist when they landed.
    for id <- ["att_old_a", "att_old_b", "att_old_c"], do: attest(db, id, "asg_pre")

    :ok =
      DB.execute(db, """
      INSERT INTO assignment_prods
        (assignmentId, attemptCount, prodCount, deniedStreak, attestCount)
      VALUES ('asg_pre', 0, 1, 0, 3)
      """)

    assert answered(db) == []

    # ONE new attest arrives after migration.
    attest(db, "att_new", "asg_pre")
    evaluate(db, handlers, "holder")

    assert answered(db) == ["att_new"],
           "only the attest that actually arrived gets an event; history stays NULL"
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
        params: %{prompt: "an ordinary conversational wake", after_ms: 0, nudge: false,
                  assignment_id: "asg_victim"}
      })
    end

    # An AGENT supplying assignment_id gets it dropped: a conversational wake is
    # NULL, and no forged carrier can reach the turn or the trace (Law 0).
    %{wake_id: agent_wake} = forge.({:session, "agent-session"})
    assert is_nil(Wakes.get(db, agent_wake).assignment_id)

    # The SUBSTRATE's own principal — which the router reserves and refuses to
    # mint for a wire caller — is the only one that may stamp it.
    %{wake_id: substrate_wake} = forge.({:process, "tightbeam"})
    assert Wakes.get(db, substrate_wake).assignment_id == "asg_victim"
  end

  ## Helpers

  # One turn-end shift. A prod leaves a PENDING wake, and the turn-end schedule's
  # pending-wake gate halts before the ladder while one exists — delivery is what
  # clears it in production, so fire it here.
  defp evaluate(db, handlers, session_key) do
    {:ok, _} = DB.query(db, "UPDATE wakes SET state = 'fired', firedAt = 1 WHERE state = 'pending'")
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

  defp attest(db, id, assignment_id) do
    :ok =
      DB.execute(db, """
      INSERT INTO attests (id, assignmentId, kind, bySession, ts)
      VALUES ('#{id}', '#{assignment_id}', 'completion', 'holder', 1)
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
      model: "claude-fable-5"
    })
  end

  defp turn(db, session_key, opts \\ []) do
    {:ok, seq} =
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

  defp notified_in_txn(episode, txn) do
    Txn.q(
      txn,
      "UPDATE adjudication_episodes SET status='notified' WHERE sessionKey=?1 AND condition=?2",
      [episode.session_key, episode.condition]
    )

    episode
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

  defp assert_keys(map, keys), do: assert(Map.keys(map) |> Enum.sort() == Enum.sort(keys))
end
