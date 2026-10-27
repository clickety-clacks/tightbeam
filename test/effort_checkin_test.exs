defmodule Tightbeam.EffortCheckinTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{Assignments, DB, EffortCheckin, Gateway, Org, Placement, Wakes}

  setup do
    db = :"effort_retirement_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('owner',0,1),('holder-owner',0,1)"
      )

    host = Placement.local_host_name()
    session(db, "parent", "owner", host)
    session(db, "holder", "holder-owner", host)
    {:ok, _} = DB.query(db, "UPDATE sessions SET spawnedBy='parent' WHERE sessionKey='holder'")

    %{db: db}
  end

  test "new assignments never arm effort generations, even with the retired setting", ctx do
    refute EffortCheckin.enabled?(%{
             effort_checkins_enabled: true,
             effort_checkin_horizon_ms: 1
           })

    assignment = assign(ctx.db)

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1",
             [
               assignment.id
             ]
           ) == 0

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer IN ('effort_probe','effort_deadline')",
             [assignment.id]
           ) == 0

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1 AND kind='effort'",
             [assignment.id]
           ) == 0
  end

  test "upgraded effort wakes and prompts are canceled without changing generations", ctx do
    assignment = assign(ctx.db)
    due_at = System.system_time(:millisecond) + 60_000

    probe = old_wake(ctx.db, assignment.id, "effort_probe", due_at)
    deadline = old_wake(ctx.db, assignment.id, "effort_deadline", due_at)

    holder_prod =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "process:tightbeam",
        consumer: "prompt",
        prompt: "[effort check-in] legacy holder prompt",
        due_at: due_at,
        assignment_id: assignment.id,
        obligation_ref: "effort-holder-prod:" <> assignment.id,
        target_gate: 0
      })

    expiry_prompt =
      Wakes.schedule(ctx.db, %{
        session_key: "parent",
        origin: "process:tightbeam",
        consumer: "prompt",
        prompt: "Effort check-in dr_legacy expired after 24 hours without a decision.",
        due_at: due_at,
        assignment_id: assignment.id,
        target_gate: 0
      })

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO effort_checkin_generations
                 (assignmentId,generation,state,baseHorizonMs,multiplier,armedAt,
                  terminalSeqWatermark,holderKey,host,root,baseline,wakeId,
                  agentProdded,artifactWatermark,attestWatermark,workItemWatermark,
                  reliefExcludedMs)
               VALUES (?1,1,'armed',86400000,1,?2,0,'holder',?3,'.','{}',?4,0,0,0,0,0)
               """,
               [
                 assignment.id,
                 System.system_time(:millisecond),
                 Placement.local_host_name(),
                 probe.wake_id
               ]
             )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: :effort_retired_scheduler,
         tick_ms: 60_000,
         deliver: fn _wake -> :ok end}
      )

    for wake <- [probe, deadline, holder_prod, expiry_prompt], do: due!(ctx.db, wake.wake_id)
    assert :ok = Wakes.fire_due(scheduler)

    for wake <- [probe, deadline, holder_prod, expiry_prompt] do
      assert %{state: "canceled"} = Wakes.get(ctx.db, wake.wake_id)

      assert count(
               ctx.db,
               "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1 AND reasonKind='consumer_unavailable'",
               [wake.wake_id]
             ) == 1
    end

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1 AND kind='effort'",
             [assignment.id]
           ) == 0

    # Historical rows remain, unchanged; the scheduler never queries them.
    probe_wake_id = probe.wake_id

    assert [["armed", ^probe_wake_id]] =
             rows(
               ctx.db,
               "SELECT state,wakeId FROM effort_checkin_generations WHERE assignmentId=?1",
               [
                 assignment.id
               ]
             )

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM turns WHERE sessionKey IN ('parent','holder') AND status='queued'",
             []
           ) == 0
  end

  test "an existing effort request remains answerable and answering it arms nothing", ctx do
    assignment = assign(ctx.db)

    deadline =
      old_wake(
        ctx.db,
        assignment.id,
        "effort_deadline",
        System.system_time(:millisecond) + 60_000
      )

    request_id = "dr_legacy_effort"
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,ownerUserId,assignmentId,expecterSessionKey,lineageRung,
                  effortGeneration,deadlineWakeId,raisedAt,deadlineAt,question,options,context,status)
               VALUES (?1,'effort','process:tightbeam','owner',?2,'parent',0,1,?3,?4,?5,
                       'Continue or dismiss?',?6,'{}','open')
               """,
               [
                 request_id,
                 assignment.id,
                 deadline.wake_id,
                 now,
                 now + 86_400_000,
                 JSON.encode!(["continue", "dismiss"])
               ]
             )

    handlers = Gateway.handlers(%{db: ctx.db})

    assert %{decision_request: %{id: ^request_id, status: "open"}} =
             handlers["decision-request"].(%{
               verb: "decision-request",
               origin: "agent:parent",
               principal: {:session, "parent"},
               params: %{request_id: request_id}
             })

    result =
      handlers["effort-rule"].(%{
        verb: "effort-rule",
        origin: "agent:parent",
        principal: {:session, "parent"},
        params: %{request_id: request_id, action: "continue"}
      })

    assert %{status: "ruled", decision: "continue"} = result
    assert %{state: "canceled"} = Wakes.get(ctx.db, deadline.wake_id)

    assert %{decision_request: %{id: ^request_id, status: "ruled", decision: "continue"}} =
             handlers["decision-request"].(%{
               verb: "decision-request",
               origin: "agent:parent",
               principal: {:session, "parent"},
               params: %{request_id: request_id}
             })

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1",
             [
               assignment.id
             ]
           ) == 0

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer='effort_probe' AND state='pending'",
             [assignment.id]
           ) == 0
  end

  defp assign(db) do
    result =
      Assignments.__handle__(db, "assign", %{
        verb: "assign",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: "holder",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{subject: "retired check-in proof", brief: "exercise assignment behavior"}
      })

    assert %{id: id} = result
    %{id: id}
  end

  defp old_wake(db, assignment_id, consumer, due_at) do
    Wakes.schedule(db, %{
      session_key: "parent",
      origin: "process:tightbeam",
      consumer: consumer,
      prompt: nil,
      due_at: due_at,
      assignment_id: assignment_id
    })
  end

  defp due!(db, wake_id) do
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [
        wake_id,
        System.system_time(:millisecond) - 1
      ])

    :ok
  end

  defp session(db, key, owner, host) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: host
    })
  end

  defp count(db, sql, params \\ []) do
    [[count]] = rows(db, sql, params)
    count
  end

  defp rows(db, sql, params \\ []) do
    {:ok, result} = DB.query(db, sql, params)
    result
  end
end
