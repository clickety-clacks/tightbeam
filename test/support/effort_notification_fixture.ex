defmodule Tightbeam.EffortNotificationFixture do
  import ExUnit.Assertions
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    Artifacts,
    Assignments,
    ConnRegistry,
    DB,
    EffortCheckin,
    Escalation,
    Gateway,
    Ledger,
    NoticeBatcher,
    Org,
    Placement,
    Wakes,
    WorkItems
  }

  alias Tightbeam.ConditionFacts

  defmodule LaneDoorbell do
    @moduledoc false
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:lane_nudged, session_key})
      {:reply, :ok, parent}
    end
  end

  def run!(tmp, scenario) do
    %{executable: executable, args: args, env: env} =
      Tightbeam.GuardRuntimeFixture.prepare!(tmp, "effort_notification_runtime.exs")

    {output, status} =
      System.cmd(executable, args ++ [Integer.to_string(scenario)],
        env: env,
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)
    assert status == 0, output
    assert output =~ "effort-notification: #{scenario}: ok"
  end

  def run_case!(scenario, base) do
    {:ok, fixtures} = Supervisor.start_link([], strategy: :one_for_one)
    Process.put({__MODULE__, :supervisor}, fixtures)

    try do
      ctx = setup!(base)
      :ok = DB.assert_base_admitted!(ctx.db, base)
      marker = File.read!(Path.join(base, "build-owner.json"))
      scenario(scenario, ctx)
      assert File.read!(Path.join(base, "build-owner.json")) == marker
    after
      if Process.alive?(fixtures), do: Supervisor.stop(fixtures)
    end

    IO.puts("effort-notification: #{scenario}: ok")
  end

  defp setup!(base_dir) do
    db = :"effort_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})

    start_supervised!({DB, path: Path.join(base_dir, "state.db"), name: db, guard_inputs: []})

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('h1',0,1),('h2',0,1),('admin',1,1)"
      )

    host = Placement.local_host_name()
    parent = session(db, "parent", "h1", host)
    holder = session(db, "holder", "h2", host)

    # Preserve the historical cross-owner provenance exercised by these
    # delivery proofs without treating it as a newly admissible spawn.
    {:ok, _} =
      DB.query(db, "UPDATE sessions SET spawnedBy='parent' WHERE sessionKey='holder'")

    holder = Org.get(db, holder.session_key)
    # The extra keys are what `Gateway.children_after_preflight/1` reads: the
    # notification drain uses the REAL prompt-wake child, not a test closure.
    config = %{
      db: db,
      base_dir: base_dir,
      port: 4_321,
      effort_checkin_horizon_ms: 10,
      cwd: base_dir,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 60_000,
      onboarding_lease_ms: 1_800_000
    }

    # A plain directory: no git anywhere in this suite except where a proof is
    # ABOUT git being irrelevant. v2 observes writes, not repositories.
    root = Placement.workdir_path(config, holder)
    init_workspace(root)

    %{db: db, base_dir: base_dir, config: config, parent: parent, holder: holder, root: root}
  end

  defp scenario(0, ctx) do
    personal_key = Org.personal_session_key("h1")
    session(ctx.db, personal_key, "h1", Placement.local_host_name())

    item =
      assignment(ctx, "dispatch", {:user, "h1"}, "holder", %{
        subject: "effort remains due",
        brief: "effort remains due"
      })

    assert {:ok, ordinary} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.ReminderDelivery.schedule_in_txn(txn, item.id, "prod", "holder", fn ->
                 Wakes.schedule_in_txn(txn, %{
                   session_key: "holder",
                   origin: "process:tightbeam",
                   prompt: "Ordinary reminder remains owned",
                   due_at: 9_000_000_000_000,
                   assignment_id: item.id
                 })
               end)
             end)

    assert [[claim]] =
             rows(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [item.id])

    assert JSON.decode!(claim)["pending"]["consumer"] == %{"wake" => ordinary.wake_id}
    request = escalate(ctx, item.id)
    assert request.deadline_wake_id != nil

    notices = Enum.reject(notification_wakes(ctx.db), &(&1.wake_id == ordinary.wake_id))
    assert length(notices) == 1
    assert Enum.all?(notices, &(&1.assignment_id == item.id))

    scheduler = drain_notifications!(ctx)

    assert Enum.all?(notices, fn notice ->
             Wakes.get(ctx.db, notice.wake_id).state == "fired" and
               match?(
                 [%{batch_state: "delivered"}],
                 NoticeBatcher.source_refs(ctx.db, notice.wake_id)
               )
           end)

    finish_queued_turns!(ctx, "holder", scheduler)
    make_request_deadline_due!(ctx.db, request)

    assert :ok =
             EffortCheckin.deadline(
               ctx.db,
               ctx.config,
               Wakes.get(ctx.db, request.deadline_wake_id)
             )

    assert [%{state: "pending", assignment_id: assignment_id} = notice] =
             expiry_notice_wakes(ctx.db, item.id)

    assert assignment_id == item.id
    assert notice.session_key == "holder"
    assert notice.prompt =~ "expired after 24 hours"
    :ok = Wakes.fire_due(scheduler)

    assert [%{delivery_wake_id: carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, notice.wake_id)

    assert Wakes.get(ctx.db, notice.wake_id).state == "fired"

    assert [[1]] = rows(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [carrier_id])

    assert [[carrier_assignment_id, _job_id]] =
             rows(ctx.db, "SELECT assignmentId, jobRef FROM turns WHERE wakeId=?1", [carrier_id])

    assert carrier_assignment_id == item.id

    assert [[^claim]] =
             rows(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [item.id])

    assert Wakes.get(ctx.db, ordinary.wake_id).state == "pending"
    assert [] == rows(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [ordinary.wake_id])
  end

  defp scenario(1, ctx) do
    personal_key = Org.personal_session_key("h1")
    session(ctx.db, personal_key, "h1", Placement.local_host_name())

    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:h1",
        principal: {:user, "h1"},
        session_key: nil,
        params: %{title: "Effort trace"}
      })

    assignment =
      assignment(ctx, "dispatch", {:user, "h1"}, "holder", %{
        subject: "linked effort",
        brief: "linked effort",
        work_item_id: item.id
      })

    request = escalate(ctx, assignment.id)
    first_deadline = request.deadline_wake_id

    # The open request notice and later expiry notice both retain the card's
    # assignment/work-item attribution through the normal batching path.
    scheduler = drain_notifications!(ctx)
    [opened_notice] = notification_wakes(ctx.db)

    assert [%{delivery_wake_id: opened_carrier, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, opened_notice.wake_id)

    assert [[turn_assignment_id, turn_job_ref]] =
             rows(ctx.db, "SELECT assignmentId, jobRef FROM turns WHERE wakeId=?1", [
               opened_carrier
             ])

    assert turn_assignment_id == assignment.id
    assert turn_job_ref == item.id

    finish_queued_turns!(ctx, "holder", scheduler)
    make_request_deadline_due!(ctx.db, request)
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, first_deadline))

    assert [%{state: "pending", session_key: "holder"} = expiry_notice] =
             expiry_notice_wakes(ctx.db, assignment.id)

    :ok = Wakes.fire_due(scheduler)

    assert [%{delivery_wake_id: expiry_carrier, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, expiry_notice.wake_id)

    assert [[expiry_assignment_id, expiry_job_ref]] =
             rows(ctx.db, "SELECT assignmentId, jobRef FROM turns WHERE wakeId=?1", [
               expiry_carrier
             ])

    assert expiry_assignment_id == assignment.id
    assert expiry_job_ref == item.id
  end

  defp scenario(2, ctx) do
    personal_key = Org.personal_session_key("h1")
    session(ctx.db, personal_key, "h1", Placement.local_host_name())

    item = dispatch(ctx, {:session, "parent"}, "holder", "notify durability")

    # Rung one is the agent prod; the owner's request is the next bracket.
    :ok = EffortCheckin.probe(ctx.db, ctx.config, current_wake(ctx.db, item.id))
    :ok = EffortCheckin.probe(ctx.db, ctx.config, current_wake(ctx.db, item.id))

    [[request_id, old_deadline_id]] =
      rows(
        ctx.db,
        "SELECT id,deadlineWakeId FROM decision_requests WHERE assignmentId=?1 AND status='open'",
        [item.id]
      )

    # The request and its decision notification commit together, before delivery.
    assert [%{state: "pending", target_gate: 0} = opened] = notification_wakes(ctx.db)
    assert opened.prompt =~ "Effort check-in #{request_id}"
    assert Wakes.get(ctx.db, old_deadline_id).state == "pending"
    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [opened.wake_id]) == [[0]]
    assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.wake_id == opened.wake_id))

    # Ordinary wake recovery delivers the original request notice.
    scheduler = drain_notifications!(ctx)
    assert Wakes.get(ctx.db, opened.wake_id).state == "fired"

    assert [%{delivery_wake_id: opened_carrier, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, opened.wake_id)

    assert Wakes.get(ctx.db, opened_carrier).state == "fired"
    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [opened.wake_id]) == [[0]]
    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [opened_carrier]) == [[1]]
    assert Wakes.get(ctx.db, old_deadline_id).state == "pending"

    finish_queued_turns!(ctx, "holder", scheduler)

    make_request_deadline_due!(ctx.db, %{id: request_id, deadline_wake_id: old_deadline_id})
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, old_deadline_id))

    expired = request(ctx.db, request_id)
    assert expired.status == "withdrawn"
    assert expired.decision == nil
    assert expired.deadline_wake_id == old_deadline_id
    assert Wakes.get(ctx.db, old_deadline_id).state == "fired"

    assert [%{state: "pending", session_key: "holder", target_gate: 1} = expiry_notice] =
             expiry_notice_wakes(ctx.db, item.id)

    :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, expiry_notice.wake_id).state == "fired"

    assert [%{delivery_wake_id: expiry_carrier, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, expiry_notice.wake_id)

    assert Wakes.get(ctx.db, expiry_carrier).state == "fired"

    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [expiry_notice.wake_id]) ==
             [[0]]

    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [expiry_carrier]) == [[1]]

    # Replaying the fired deadline cannot reopen the request or re-arm a timer.
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, old_deadline_id))
    assert request(ctx.db, request_id).deadline_wake_id == old_deadline_id
    assert length(expiry_notice_wakes(ctx.db, item.id)) == 1

    assert rows(
             ctx.db,
             "SELECT COUNT(*) FROM wakes WHERE consumer='effort_deadline' AND assignmentId=?1 AND state='pending'",
             [item.id]
           ) == [[0]]
  end

  defp dispatch(ctx, principal, holder, subject) do
    assignment(ctx, "dispatch", principal, holder, %{subject: subject, brief: subject})
  end

  # A session's FIRST dispatch against a work item is sent to ruminate; the
  # re-issue is the dispatch. These proofs are about the bracket, not that rung.

  defp assignment(ctx, verb, principal, holder, params) do
    call = %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      params: params,
      effort_config: ctx.config,
      supervision_interval_ms: ctx.config.wake_tick_ms
    }

    Assignments.__handle__(ctx.db, verb, call)
  end

  defp fire_probe(ctx, assignment_id) do
    before = latest_request_id(ctx.db, assignment_id)
    wake = current_wake(ctx.db, assignment_id)
    :ok = EffortCheckin.probe(ctx.db, ctx.config, wake)

    case latest_request_id(ctx.db, assignment_id) do
      ^before -> nil
      nil -> nil
      id -> request(ctx.db, id)
    end
  end

  # Zero effect prods the AGENT first; the owner's request is the NEXT bracket.
  # Every proof that is about the request, not the rung order, walks both.

  defp escalate(ctx, assignment_id) do
    fire_probe(ctx, assignment_id) || fire_probe(ctx, assignment_id)
  end

  defp latest_request_id(db, assignment_id) do
    case rows(
           db,
           "SELECT id FROM decision_requests WHERE kind='effort' AND assignmentId=?1 ORDER BY rowid DESC LIMIT 1",
           [assignment_id]
         ) do
      [[id]] -> id
      [] -> nil
    end
  end

  defp current_wake(db, assignment_id) do
    [[wake_id]] =
      rows(
        db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed' ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      )

    Wakes.get(db, wake_id)
  end

  defp request(db, id) do
    call = %{principal: {:session, "parent"}, origin: "agent:parent", params: %{}}
    Escalation.get(db, call, id, owner_user_id: "h1") || raw_request(db, id)
  end

  defp raw_request(db, id) do
    [
      [
        id,
        kind,
        assignment_id,
        expecter_session,
        expecter_user,
        rung,
        generation,
        wake_id,
        question,
        options,
        context,
        status,
        decision,
        ruled_by
      ]
    ] =
      rows(
        db,
        "SELECT id,kind,assignmentId,expecterSessionKey,expecterUserId,lineageRung,effortGeneration,deadlineWakeId,question,options,context,status,decision,ruledBy FROM decision_requests WHERE id=?1",
        [id]
      )

    %{
      id: id,
      kind: kind,
      assignment_id: assignment_id,
      expecter_session_key: expecter_session,
      expecter_user_id: expecter_user,
      lineage_rung: rung,
      effort_generation: generation,
      deadline_wake_id: wake_id,
      question: question,
      options: JSON.decode!(options),
      context: JSON.decode!(context),
      status: status,
      decision: decision,
      ruled_by: ruled_by
    }
  end

  defp rows(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp notification_wakes(db) do
    db
    |> rows("SELECT wakeId FROM wakes WHERE targetGate = 0 AND digest = 0 ORDER BY rowid", [])
    |> Enum.map(fn [wake_id] -> Wakes.get(db, wake_id) end)
  end

  defp make_request_deadline_due!(db, request) do
    due_at = System.system_time(:millisecond) - 1

    {:ok, _} =
      DB.query(db, "UPDATE decision_requests SET deadlineAt=?2 WHERE id=?1", [request.id, due_at])

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [request.deadline_wake_id, due_at])

    :ok
  end

  defp expiry_notice_wakes(db, assignment_id) do
    db
    |> rows(
      """
      SELECT w.wakeId FROM wakes w
      WHERE w.assignmentId=?1 AND w.consumer='prompt' AND w.targetGate=1
        AND w.prompt LIKE '%expired after 24 hours%'
        AND NOT EXISTS (SELECT 1 FROM notice_batches b WHERE b.deliveryWakeId=w.wakeId)
      ORDER BY w.rowid
      """,
      [assignment_id]
    )
    |> Enum.map(fn [wake_id] -> Wakes.get(db, wake_id) end)
  end

  # Drain through the REAL gateway prompt-wake child: its closure, its delivery
  # config, its targetGate handling and wake attribution — not a test stand-in.

  defp drain_notifications!(ctx) do
    name = :"effort_wakes_#{System.unique_integer([:positive])}"

    {Wakes, opts} =
      ctx.config
      |> Gateway.children_after_preflight()
      |> Enum.find(&match?({Wakes, _}, &1))

    start_supervised!({Wakes, Keyword.merge(opts, name: name, tick_ms: 60_000)}, id: name)
    :ok = Wakes.fire_due(name)
    name
  end

  defp finish_queued_turns!(ctx, session_key, scheduler) do
    case Ledger.claim_next(ctx.db, session_key, "effort-notification-fixture") do
      {:ok, turn} ->
        :ok = Ledger.finish(ctx.db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
        :ok = Wakes.fire_due(scheduler)
        finish_queued_turns!(ctx, session_key, scheduler)

      :none ->
        :ok

      :busy ->
        flunk("cannot deliver notifications to #{session_key}: a turn is still running")

      {:unclaimable, reason} ->
        flunk("cannot deliver notifications to #{session_key}: #{inspect(reason)}")
    end
  end

  defp session(db, key, owner, host, overrides \\ %{}) do
    Org.create(
      db,
      Map.merge(
        %{
          session_key: key,
          display_name: key,
          kind: if(key == Org.personal_session_key(owner), do: "main", else: "custom"),
          owner_user_id: owner,
          origin: "user:#{owner}",
          archetype: "default",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("fable"),
          host: host
        },
        overrides
      )
    )
  end

  defp init_workspace(path) do
    File.mkdir_p!(Path.join(path, "src"))
    File.write!(Path.join(path, "src/tracked.txt"), "baseline\n")
  end

  defp origin({:session, key}), do: "agent:#{key}"

  defp origin({:user, user}), do: "user:#{user}"

  defp start_supervised!(child, opts \\ []) do
    spec = Supervisor.child_spec(child, opts)
    {:ok, pid} = Supervisor.start_child(Process.get({__MODULE__, :supervisor}), spec)
    pid
  end

  defp stop_supervised!(id) do
    sup = Process.get({__MODULE__, :supervisor})
    :ok = Supervisor.terminate_child(sup, id)
    :ok = Supervisor.delete_child(sup, id)
  end
end
