defmodule Tightbeam.SupervisionTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    HarnessProcess,
    Ledger,
    NoticeBatcher,
    Org,
    Projection,
    RailRemedy,
    Roles,
    Rules,
    Schema,
    Supervision,
    Wakes
  }

  defmodule LaneDoorbell do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  defmodule RaceLane do
    use GenServer
    def start_link({name, callback}), do: GenServer.start_link(__MODULE__, callback, name: name)
    def init(callback), do: {:ok, callback}

    def handle_call({:ensure_lane, key}, _from, callback) do
      callback.(key)
      {:reply, :ok, callback}
    end
  end

  defmodule ParkRaceDB do
    use GenServer

    def start_link({name, db, parent, transition}),
      do: GenServer.start_link(__MODULE__, {db, parent, transition}, name: name)

    def init({db, parent, transition}),
      do: {:ok, %{db: db, parent: parent, transition: transition, request_reads: 0}}

    def handle_call({:query, sql, _params} = request, _from, state) do
      result = GenServer.call(state.db, request)

      if current_request_query?(sql) do
        request_reads = state.request_reads + 1
        {:ok, [[id | _]]} = result

        if request_reads == 1 do
          transition_request(state.db, id, state.transition)
          send(state.parent, {:request_changed_before_park, state.transition, id})
        else
          send(state.parent, {:request_rechecked, state.transition, request_reads})
        end

        {:reply, result, %{state | request_reads: request_reads}}
      else
        {:reply, result, state}
      end
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.db, request), state}

    defp current_request_query?(sql) do
      String.contains?(sql, "FROM decision_requests WHERE kind = 'statute' AND raiserId") and
        String.contains?(sql, "ORDER BY rowid DESC LIMIT 1")
    end

    defp transition_request(db, id, :rule_allow) do
      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_requests SET status = 'ruled', decision = 'allow', ruledAt = 1 WHERE id = ?1 AND status = 'open'",
          [id]
        )
    end

    defp transition_request(db, id, :withdraw) do
      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = 'session:holder', withdrawnReason = 'race', withdrawnAt = 1 WHERE id = ?1 AND status = 'open'",
          [id]
        )
    end
  end

  setup do
    db = :"supervision_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    supervisor = session(db, "supervisor", main.session_key)
    holder = session(db, "holder", supervisor.session_key)
    assignment(db, "asg_1", holder.session_key, "ship it", 1)

    # Resolved, not just joined: containment refuses a write root with a symlink component,
    # and macOS's tmp dir is one (`/var` → `/private/var`). A script-tier statute under an
    # unresolved base never reaches its check.
    {tmp, 0} = System.cmd("/bin/realpath", [System.tmp_dir!()])

    base =
      Path.join(String.trim(tmp), "tb-supervision-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 60_000})
    Rules.load!(base, Map.keys(handlers))
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      db: db,
      handlers: handlers,
      main: main,
      supervisor: supervisor,
      holder: holder,
      base: base
    }
  end

  test "schema and neutral row APIs expose the exact durable state", ctx do
    assert Assignments.oldest_open(ctx.db, "holder").id == "asg_1"
    assert Assignments.attest_count(ctx.db, "asg_1") == 0
    assert Ledger.pending_count(ctx.db, "holder") == 0
    assert Ledger.last_terminal_seq(ctx.db, "holder") == nil
    assert Wakes.pending_count(ctx.db, "holder") == 0
    assert Supervision.prod_state(ctx.db, "asg_1") == nil
    assert Supervision.watermark(ctx.db, "holder") == nil

    assert {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(supervision_watermarks)")
    names = Enum.map(columns, &Enum.at(&1, 1))

    assert names ==
             ~w(sessionKey assignmentId lastEvaluatedTerminal pendingBranch pendingAssignment pendingK pendingN)

    refute "pendingTarget" in names
  end

  test "the prod-shape gate authorizes assignment prodding and rejects other consumers", ctx do
    assert {:ok, :acted} =
             DB.transaction(ctx.db, fn txn ->
               HarnessHealth.prod_shape_act_in_txn(
                 txn,
                 "assignment_prodder",
                 "asg_1",
                 "claude",
                 "gibson",
                 fn -> :acted end
               )
             end)

    assert {:error, %ArgumentError{message: "unreviewed_prod_shape_consumer"}} =
             DB.transaction(ctx.db, fn txn ->
               HarnessHealth.prod_shape_act_in_txn(
                 txn,
                 "test_sink",
                 "asg_1",
                 "claude",
                 "gibson",
                 fn -> flunk("unreviewed sink was executed") end
               )
             end)
  end

  test "the real prod wake sink runs behind the gate transaction and denial has no effect",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    parent = self()
    actual_wake = ctx.handlers["wake"]

    instrumented =
      Map.put(ctx.handlers, "wake", fn call ->
        send(parent, {:prod_wake_sink, match?(%DB.Txn{}, call[:txn])})
        actual_wake.(call)
      end)

    terminal = terminal!(ctx.db, "holder")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, instrumented, 3, "holder", terminal)

    assert_receive {:prod_wake_sink, true}
    before_denial = Enum.map(Wakes.list_pending(ctx.db), & &1.wake_id)
    assert length(before_denial) == 1

    open_rate_limit_incident!(ctx)
    denial_terminal = terminal!(ctx.db, "holder")

    assert :harness_unavailable =
             Supervision.evaluate(ctx.db, instrumented, 3, "holder", denial_terminal)

    refute_receive {:prod_wake_sink, _}
    assert Enum.map(Wakes.list_pending(ctx.db), & &1.wake_id) == before_denial
  end

  test "idle cleanup backfills quiet sessions with private evidence and no retirement", ctx do
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 1_000)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms),
        else: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous)
    end)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=1,updatedAt=1 WHERE sessionKey='supervisor'"
      )

    main_key = ctx.main.session_key
    start_liveness!(ctx, sweep_ms: 60_000, name: :idle_cleanup_backfill_supervision)

    cleanup_wakes =
      Enum.filter(Wakes.list_pending(ctx.db), fn wake ->
        is_binary(wake.obligation_ref) and
          String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
      end)

    assert [%{session_key: ^main_key} = wake] = cleanup_wakes
    assert wake.prompt =~ "child=supervisor"
    assert wake.prompt =~ "ageMs="
    assert wake.prompt =~ "lastAssignment=none"
    assert wake.prompt =~ "outcome=none"
    assert wake.prompt =~ "workItem=none"
    assert wake.prompt =~ "custody=none"
    assert wake.prompt =~ "cause=idle_cleanup_quiet; principal=process:tightbeam"
    refute wake.prompt =~ "ship it"
    refute wake.prompt =~ "assignment:"

    assert {:ok, [["active"]]} =
             DB.query(ctx.db, "SELECT state FROM sessions WHERE sessionKey='supervisor'")

    assert [%{kind: "idle_cleanup_prompt_claimed"}] =
             Enum.filter(EventLog.lifecycle_events(ctx.db), &(&1.subject == wake.wake_id))
  end

  test "idle cleanup applies its horizon and excludes open or pending sessions", ctx do
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 10_000)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms),
        else: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous)
    end)

    pending = session(ctx.db, "pending-child", ctx.supervisor.session_key)
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=?1,updatedAt=?1 WHERE sessionKey IN ('supervisor','pending-child')",
        [now - 9_000]
      )

    pending_wake =
      Wakes.schedule(ctx.db, %{
        session_key: pending.session_key,
        origin: "user:flynn",
        prompt: "pending ordinary wake",
        due_at: now + 60_000
      })

    main_key = ctx.main.session_key
    start_liveness!(ctx, sweep_ms: 60_000, name: :idle_cleanup_horizon_supervision)

    refute Enum.any?(Wakes.list_pending(ctx.db), fn wake ->
             is_binary(wake.obligation_ref) and
               String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
           end)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=?1,updatedAt=?1 WHERE sessionKey='supervisor'",
        [System.system_time(:millisecond) - 11_000]
      )

    sweep_liveness!(:idle_cleanup_horizon_supervision)

    cleanup_wakes =
      Enum.filter(Wakes.list_pending(ctx.db), fn wake ->
        is_binary(wake.obligation_ref) and
          String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
      end)

    assert [%{session_key: ^main_key}] = cleanup_wakes
    assert Wakes.get(ctx.db, pending_wake.wake_id).state == "pending"
  end

  test "idle cleanup mixes sibling eligibility, deduplicates, and escalates one group", ctx do
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 1_000)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms),
        else: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous)
    end)

    child_a = session(ctx.db, "child-a", ctx.supervisor.session_key)
    child_b = session(ctx.db, "child-b", ctx.supervisor.session_key)
    supervisor_key = ctx.supervisor.session_key
    main_key = ctx.main.session_key
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=?1,updatedAt=?1 WHERE sessionKey='child-a'",
        [
          now - 3_000
        ]
      )

    Wakes.schedule(ctx.db, %{
      session_key: ctx.supervisor.session_key,
      origin: "user:flynn",
      prompt: "parent activity",
      due_at: now + 60_000
    })

    start_liveness!(ctx, prod_limit: 1, sweep_ms: 60_000, name: :idle_cleanup_group_supervision)

    cleanup_wakes =
      Enum.filter(Wakes.list_pending(ctx.db), fn wake ->
        is_binary(wake.obligation_ref) and
          String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
      end)

    assert [%{session_key: ^supervisor_key, prompt: first_prompt} = first] = cleanup_wakes
    assert first_prompt =~ "child=child-a"
    refute first_prompt =~ "child=child-b"
    assert first_prompt =~ "delivered=0"
    assert first_prompt =~ "targetDepth=0"

    # A second sweep and a second Supervision process see the same pending wake.
    sweep_liveness!(:idle_cleanup_group_supervision)
    assert :ok = stop_supervised(Supervision)
    start_liveness!(ctx, prod_limit: 1, sweep_ms: 60_000, name: :idle_cleanup_group_restart)

    assert 1 ==
             Enum.count(Wakes.list_pending(ctx.db), fn wake ->
               is_binary(wake.obligation_ref) and
                 String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
             end)

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: first.session_key,
               message_id: "idle-cleanup-generation-1",
               wake_id: first.wake_id,
               origin: first.origin,
               prompt: first.prompt
             })

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1",
        [first.wake_id, System.system_time(:millisecond) - 2_000]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=?1,updatedAt=?1 WHERE sessionKey='child-b'",
        [
          System.system_time(:millisecond) - 3_000
        ]
      )

    sweep_liveness!(:idle_cleanup_group_restart)

    cleanup_wakes =
      Enum.filter(Wakes.list_pending(ctx.db), fn wake ->
        is_binary(wake.obligation_ref) and
          String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
      end)

    assert [%{session_key: ^main_key, prompt: second_prompt}] = cleanup_wakes
    assert second_prompt =~ "child=child-a"
    assert second_prompt =~ "child=child-b"
    assert second_prompt =~ "child=child-a;"
    assert second_prompt =~ "delivered=1"
    assert second_prompt =~ "targetDepth=1"
    assert child_a.session_key == "child-a"
    assert child_b.session_key == "child-b"

    assert {:ok, [["active"], ["active"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM sessions WHERE sessionKey IN ('child-a','child-b') ORDER BY sessionKey"
             )
  end

  test "idle cleanup climbs dormant or retired parents and routes living ancestors or Main",
       ctx do
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 1_000)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms),
        else: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous)
    end)

    dormant_parent = session(ctx.db, "dormant-parent", ctx.supervisor.session_key)
    _dormant_child = session(ctx.db, "dormant-child", dormant_parent.session_key)
    retired_parent = session(ctx.db, "retired-parent", ctx.supervisor.session_key)
    _retired_child = session(ctx.db, "retired-child", retired_parent.session_key)
    living_parent = session(ctx.db, "living-parent", ctx.supervisor.session_key)
    living_child = session(ctx.db, "living-child", living_parent.session_key)
    _orphan = session(ctx.db, "orphan", nil)
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='retired-parent'")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=?1,updatedAt=?1 WHERE sessionKey IN ('supervisor','dormant-parent','dormant-child','retired-child','living-child','orphan')",
        [now - 3_000]
      )

    start_liveness!(ctx, sweep_ms: 60_000, name: :idle_cleanup_routing_supervision)

    cleanup_wakes =
      Enum.filter(Wakes.list_pending(ctx.db), fn wake ->
        is_binary(wake.obligation_ref) and
          String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
      end)

    assert Enum.any?(cleanup_wakes, fn wake -> wake.session_key == living_parent.session_key end)

    assert Enum.all?(cleanup_wakes, fn wake ->
             wake.session_key in [ctx.main.session_key, living_parent.session_key]
           end)

    main_prompts =
      cleanup_wakes
      |> Enum.filter(&(&1.session_key == ctx.main.session_key))
      |> Enum.map(& &1.prompt)
      |> Enum.join("\n")

    assert main_prompts =~ "child=dormant-child"
    assert main_prompts =~ "child=retired-child"
    assert main_prompts =~ "child=orphan"
    assert living_child.session_key == "living-child"
  end

  test "idle cleanup pauses on the existing shared harness incident", ctx do
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 1_000)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms),
        else: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous)
    end)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=1,updatedAt=1 WHERE sessionKey='supervisor'"
      )

    open_rate_limit_incident!(ctx)
    start_liveness!(ctx, sweep_ms: 60_000, name: :idle_cleanup_incident_supervision)

    refute Enum.any?(Wakes.list_pending(ctx.db), fn wake ->
             is_binary(wake.obligation_ref) and
               String.starts_with?(wake.obligation_ref, "idle-cleanup-v1:")
           end)

    assert [%{kind: "harness_health_incident_opened"}] =
             Enum.filter(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "harness_health_incident_opened")
             )
  end

  test "idle cleanup declines a stale batch at actual delivery and replaces only due siblings",
       ctx do
    idle_cleanup_fixture!(ctx, ["idle-a", "idle-b", "idle-c"])
    name = start_liveness!(ctx, sweep_ms: 60_000, name: :idle_revalidation)
    [batch] = idle_cleanup_wakes(ctx.db)

    assignment(
      ctx.db,
      "idle-a-assignment",
      "idle-a",
      "new work",
      System.system_time(:millisecond)
    )

    pending =
      Wakes.schedule(ctx.db, %{
        session_key: "idle-b",
        origin: "user:flynn",
        prompt: "causal operator notice",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert :skipped = admit_supervision_wake!(ctx.db, batch)
    assert Wakes.get(ctx.db, batch.wake_id).state == "fired"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [batch.wake_id])

    assert Wakes.get(ctx.db, pending.wake_id).state == "pending"

    sweep_liveness!(name)
    [replacement] = idle_cleanup_wakes(ctx.db)
    assert replacement.prompt =~ "child=idle-c;"
    refute replacement.prompt =~ "child=idle-a;"
    refute replacement.prompt =~ "child=idle-b;"
    assert :appended = admit_supervision_wake!(ctx.db, replacement)
    assert {:duplicate, _} = admit_supervision_wake!(ctx.db, replacement)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [replacement.wake_id])
  end

  test "idle cleanup declines changed claimed evidence without changing activity or eligibility",
       ctx do
    idle_cleanup_fixture!(ctx, ["idle-child", "idle-sibling"])
    assignment(ctx.db, "idle-last", "idle-child", "private subject", 1)
    attach_work_item!(ctx.db, "idle-last", "idle-item")
    persist_terminal_race!(ctx.db, "idle-last", 1)
    name = start_liveness!(ctx, sweep_ms: 60_000, name: :idle_claim_evidence)

    changes = [
      {fn -> attach_work_item!(ctx.db, "asg_1", "idle-item") end, "custody=held-elsewhere"},
      {fn ->
         DB.query(ctx.db, "INSERT INTO work_item_priorities (workItemId,priority) VALUES (?,?)", [
           "idle-item",
           5
         ])
       end, "priority=5; thresholdMs=30000"},
      {fn -> Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 120_000) end,
       "priority=5; thresholdMs=60000"},
      {fn ->
         DB.query(ctx.db, "UPDATE sessions SET displayName=? WHERE sessionKey='idle-child'", [
           "renamed child"
         ])
       end, "name=\"renamed child\""}
    ]

    for {change, expected} <- changes do
      [claimed] = idle_cleanup_wakes(ctx.db)
      [_, json] = String.split(claimed.obligation_ref, "\n", parts: 2)
      claimed_members = JSON.decode!(json)["members"]
      change.()

      assert :skipped = admit_supervision_wake!(ctx.db, claimed)
      assert Wakes.get(ctx.db, claimed.wake_id).prompt == claimed.prompt

      assert {:ok, [[0]]} =
               DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [claimed.wake_id])

      sweep_liveness!(name)
      [replacement] = idle_cleanup_wakes(ctx.db)
      assert replacement.wake_id != claimed.wake_id
      assert replacement.prompt =~ expected
      assert replacement.prompt =~ "child=idle-sibling;"
      assert length(Regex.scan(~r/delivered=0;/, replacement.prompt)) == 2
      [_, replacement_json] = String.split(replacement.obligation_ref, "\n", parts: 2)
      assert JSON.decode!(replacement_json)["members"] == claimed_members
    end

    [current] = idle_cleanup_wakes(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, current)
    assert Wakes.get(ctx.db, current.wake_id).prompt == current.prompt

    assert {:ok, [[1, 1], [1, 1]]} =
             DB.query(
               ctx.db,
               "SELECT createdAt,updatedAt FROM sessions WHERE sessionKey IN ('idle-child','idle-sibling')"
             )
  end

  test "idle cleanup scheduler defers a post-claim incident without consuming a generation",
       ctx do
    idle_cleanup_fixture!(ctx, ["idle-child"])
    start_liveness!(ctx, sweep_ms: 60_000, name: :idle_incident_delivery)
    [batch] = idle_cleanup_wakes(ctx.db)
    open_rate_limit_incident!(ctx)
    scheduler = idle_cleanup_scheduler!(ctx)

    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, batch.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [batch.wake_id])

    resolve_rate_limit_incident!(ctx, 1)
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, batch.wake_id).state == "fired"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [batch.wake_id])

    assert :ok = Wakes.fire_due(scheduler)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [batch.wake_id])
  end

  test "idle cleanup rechecks a recipient incident separately from eligible children", ctx do
    idle_cleanup_fixture!(ctx, ["idle-child"])

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET host='other-host' WHERE sessionKey='idle-child'")

    start_liveness!(ctx, sweep_ms: 60_000, name: :idle_target_incident)
    [batch] = idle_cleanup_wakes(ctx.db)
    open_rate_limit_incident!(ctx)

    assert {:idle_cleanup_deferred, :shared_harness_incident} =
             admit_supervision_wake!(ctx.db, batch)

    assert Wakes.get(ctx.db, batch.wake_id).state == "pending"
    resolve_rate_limit_incident!(ctx, 2)
    assert :appended = admit_supervision_wake!(ctx.db, batch)
  end

  test "idle cleanup delivery reroutes a retired or newly dormant parent in the enqueue transaction",
       ctx do
    idle_cleanup_fixture!(ctx, ["idle-child"])
    start_liveness!(ctx, sweep_ms: 60_000, name: :idle_target_delivery)
    [batch] = idle_cleanup_wakes(ctx.db)
    assert batch.session_key == "supervisor"

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=1,updatedAt=1 WHERE sessionKey='supervisor'"
      )

    assert {:error, %RuntimeError{message: "rollback delivery"}} =
             DB.transaction(ctx.db, fn txn ->
               assert {:appended, target, _, _} =
                        Gateway.deliver_prompt_in_txn(
                          txn,
                          batch.session_key,
                          batch.origin,
                          batch.prompt,
                          wake_id: batch.wake_id
                        )

               assert target == ctx.main.session_key
               raise "rollback delivery"
             end)

    assert Wakes.get(ctx.db, batch.wake_id).state == "pending"
    assert Wakes.get(ctx.db, batch.wake_id).session_key == "supervisor"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [batch.wake_id])

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='supervisor'")

    assert :appended = admit_supervision_wake!(ctx.db, batch)
    delivered = Wakes.get(ctx.db, batch.wake_id)
    assert delivered.session_key == ctx.main.session_key
    assert delivered.prompt =~ "requestedDepth=0; targetDepth=1"
    assert delivered.state == "fired"
  end

  test "idle cleanup resets only sweep-observed canceled wakes and preserves cancellation-first history",
       ctx do
    idle_cleanup_fixture!(ctx, ["observed-child", "unobserved-child"])
    name = start_liveness!(ctx, prod_limit: 1, sweep_ms: 60_000, name: :idle_occurrence)
    [batch] = idle_cleanup_wakes(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, batch)
    idle_cleanup_elapsed!(ctx.db, batch)
    sweep_liveness!(name)
    [second] = idle_cleanup_wakes(ctx.db)
    assert second.session_key == ctx.main.session_key
    assert second.prompt =~ "delivered=1; N=1; requestedDepth=1; targetDepth=1"
    assert :appended = admit_supervision_wake!(ctx.db, second)

    observed =
      Wakes.schedule(ctx.db, %{
        session_key: "observed-child",
        origin: "user:flynn",
        prompt: "parent intervention",
        due_at: System.system_time(:millisecond) + 60_000
      })

    sweep_liveness!(name)
    sweep_liveness!(name)
    cancel_wake!(ctx.db, observed)

    unobserved =
      Wakes.schedule(ctx.db, %{
        session_key: "unobserved-child",
        origin: "user:flynn",
        prompt: "between sweeps",
        due_at: System.system_time(:millisecond) + 60_000
      })

    cancel_wake!(ctx.db, unobserved)

    observations =
      Enum.filter(
        EventLog.lifecycle_events(ctx.db),
        &(&1.kind == "idle_cleanup_pending_observed")
      )

    assert Enum.count(observations, &(&1.subject == observed.wake_id)) == 1
    refute Enum.any?(observations, &(&1.subject == unobserved.wake_id))
    delivered_before = [Wakes.get(ctx.db, batch.wake_id), Wakes.get(ctx.db, second.wake_id)]

    assert :ok = stop_supervised(Supervision)
    name = start_liveness!(ctx, prod_limit: 1, sweep_ms: 60_000, name: :idle_occurrence_restart)
    [next] = idle_cleanup_wakes(ctx.db)
    assert next.session_key == "supervisor"
    assert next.prompt =~ "child=observed-child;"
    refute next.prompt =~ "child=unobserved-child;"

    assert length(Regex.scan(~r/delivered=0; N=1; requestedDepth=0; targetDepth=0/, next.prompt)) ==
             1

    sweep_liveness!(name)
    assert [^next] = idle_cleanup_wakes(ctx.db)

    assert delivered_before == [
             Wakes.get(ctx.db, batch.wake_id),
             Wakes.get(ctx.db, second.wake_id)
           ]

    assert {:ok, [[1, 1], [1, 1]]} =
             DB.query(
               ctx.db,
               "SELECT createdAt,updatedAt FROM sessions WHERE sessionKey IN ('observed-child','unobserved-child')"
             )

    assert :appended = admit_supervision_wake!(ctx.db, next)
    idle_cleanup_elapsed!(ctx.db, second)
    sweep_liveness!(name)
    [survivor] = idle_cleanup_wakes(ctx.db)
    assert survivor.session_key == ctx.main.session_key
    assert survivor.prompt =~ "child=unobserved-child;"
    refute survivor.prompt =~ "child=observed-child;"
    assert survivor.prompt =~ "delivered=2; N=1; requestedDepth=2; targetDepth=1"
    assert :appended = admit_supervision_wake!(ctx.db, survivor)
  end

  test "idle cleanup retains actual ancestor depth and Main across recovery with N greater than one",
       ctx do
    idle_cleanup_fixture!(ctx, ["idle-child"])
    session(ctx.db, "grandparent", ctx.main.session_key)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET spawnedBy='grandparent',createdAt=1,updatedAt=1 WHERE sessionKey='supervisor'"
      )

    name = start_liveness!(ctx, prod_limit: 3, sweep_ms: 60_000, name: :idle_depth)

    first =
      Enum.find(idle_cleanup_wakes(ctx.db), &String.contains?(&1.prompt, "child=idle-child;"))

    assert first.session_key == "grandparent"
    assert first.prompt =~ "requestedDepth=0; targetDepth=1"
    assert :appended = admit_supervision_wake!(ctx.db, first)
    idle_cleanup_elapsed!(ctx.db, first)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET updatedAt=?1 WHERE sessionKey='supervisor'", [
        System.system_time(:millisecond)
      ])

    assert :ok = stop_supervised(Supervision)
    name = start_liveness!(ctx, prod_limit: 3, sweep_ms: 60_000, name: name)

    second =
      Enum.find(idle_cleanup_wakes(ctx.db), &String.contains?(&1.prompt, "child=idle-child;"))

    assert second.session_key == "grandparent"
    assert second.prompt =~ "delivered=1; N=3; requestedDepth=0; targetDepth=1"

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='grandparent'")

    assert :appended = admit_supervision_wake!(ctx.db, second)
    assert Wakes.get(ctx.db, second.wake_id).session_key == ctx.main.session_key
    assert Wakes.get(ctx.db, second.wake_id).prompt =~ "targetDepth=2"
    idle_cleanup_elapsed!(ctx.db, second)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET state='active',updatedAt=?1 WHERE sessionKey='grandparent'",
        [System.system_time(:millisecond)]
      )

    sweep_liveness!(name)

    third =
      Enum.find(idle_cleanup_wakes(ctx.db), &String.contains?(&1.prompt, "child=idle-child;"))

    assert third.session_key == ctx.main.session_key
    assert third.prompt =~ "delivered=2; N=3; requestedDepth=0; targetDepth=2"
  end

  test "idle cleanup refuses corrupt custody and configuration with row identities and remedy",
       ctx do
    idle_cleanup_fixture!(ctx, ["idle-child"])
    assignment(ctx.db, "idle-last", "idle-child", "private subject", 1)
    attach_work_item!(ctx.db, "idle-last", "idle-corrupt-item")
    persist_terminal_race!(ctx.db, "idle-last", 1)
    attach_work_item!(ctx.db, "asg_1", "idle-corrupt-item")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE work_items SET state='closed' WHERE id='idle-corrupt-item'")

    name = start_liveness!(ctx, sweep_ms: 60_000, name: :idle_invalid_evidence)
    assert idle_cleanup_wakes(ctx.db) == []
    refusal = Enum.find(EventLog.lifecycle_events(ctx.db), &(&1.kind == "idle_cleanup_refused"))
    assert refusal.subject == "idle-child"
    assert refusal.detail =~ "terminal_work_item_still_held"
    assert refusal.detail =~ "idle-corrupt-item"
    assert refusal.detail =~ "remedy=repair_named_ledger_or_configuration_evidence"
    refute refusal.detail =~ "private subject"

    {:ok, _} = DB.query(ctx.db, "UPDATE work_items SET state='open' WHERE id='idle-corrupt-item'")

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT OR REPLACE INTO org_settings (key,value,updatedAt) VALUES ('default-priority','broken',1)"
      )

    sweep_liveness!(name)

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "idle_cleanup_refused" and &1.subject == "idle-child" and
                 String.contains?(&1.detail, "invalid_priority"))
           )

    {:ok, _} = DB.query(ctx.db, "DELETE FROM org_settings WHERE key='default-priority'")
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 0)
    sweep_liveness!(name)

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "idle_cleanup_refused" and &1.subject == "idle-child" and
                 String.contains?(&1.detail, "invalid_horizon"))
           )

    assert idle_cleanup_wakes(ctx.db) == []
  end

  defp idle_cleanup_fixture!(ctx, children) do
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 60_000)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms),
        else: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous)
    end)

    for child <- children do
      session(ctx.db, child, ctx.supervisor.session_key)

      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET createdAt=1,updatedAt=1 WHERE sessionKey=?1", [
          child
        ])
    end
  end

  defp idle_cleanup_wakes(db) do
    Enum.filter(
      Wakes.list_pending(db),
      &String.starts_with?(&1.obligation_ref || "", "idle-cleanup-v1:")
    )
  end

  defp idle_cleanup_elapsed!(db, wake) do
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET firedAt=?2 WHERE wakeId=?1", [
        wake.wake_id,
        System.system_time(:millisecond) - 61_000
      ])
  end

  defp idle_cleanup_scheduler!(ctx) do
    registry = start_supervised!({ConnRegistry, name: :idle_cleanup_delivery_registry})
    lane = start_supervised!({LaneDoorbell, :idle_cleanup_delivery_lane})

    start_supervised!(
      {Wakes,
       db: ctx.db,
       deliver: delivery_fun(ctx.db, registry, lane),
       tick_ms: 60_000,
       name: :idle_cleanup_delivery_scheduler}
    )
  end

  test "startup refuses noncanonical liveness epoch provenance", ctx do
    {:ok, _} = DB.query(ctx.db, "DELETE FROM supervision_liveness_epoch")

    assert_raise RuntimeError, ~r/invalid supervision_liveness_epoch/, fn ->
      start_liveness!(ctx,
        name: :invalid_liveness_epoch_supervision,
        sweep_ms: 60_000
      )
    end
  end

  test "work-item liveness selects its current bracket before another assignment", ctx do
    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, state, createdByUser, createdAt)
        VALUES ('wi_bracket_first', 'Bracket first', 'flynn', 'open', 'flynn', 1);
        UPDATE assignments SET workItemId='wi_bracket_first' WHERE id='asg_1';
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration,
           claimClock, basisKind, basisId, terminusAt, cause, principal,
           supervisionIntervalMs)
        VALUES
          ('asg_1', 4, 5000, 'armed', NULL, NULL, 'assignment_open',
           'asg_1', NULL, 'assignment_open', 'user:flynn', 1000);
        """
      )

    bracket =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "process:tightbeam",
        prompt: "route the remaining work",
        due_at: 4_000,
        work_item_id: "wi_bracket_first"
      })

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE work_items SET slateWakeId=?2 WHERE id=?1",
        ["wi_bracket_first", bracket.wake_id]
      )

    assert {:ok, {:ok, %{kind: "routing_bracket", id: "wi_bracket_first"}}} =
             DB.transaction(ctx.db, fn txn ->
               Supervision.liveness_trigger_in_txn(txn, {:work_item, "wi_bracket_first"})
             end)
  end

  test "prod fired observation is tied to the winning evaluation", ctx do
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: true})
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    drain = fn drain, remaining ->
      assert remaining > 0
      assert_receive {:firehose_notice, notice}
      Hub.delivered(hub, self())
      if notice["class"] == "prod.fired", do: notice, else: drain.(drain, remaining - 1)
    end

    notice = drain.(drain, 20)
    assert notice["refs"]["assignmentId"] == "asg_1"
    assert notice["refs"]["sessionKey"] == "holder"
    assert notice["payload"]["kind"] == "prod_fired"
    assert notice["payload"]["detail"]["tier"] == 1
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 99, "holder", seq)
    refute_receive {:firehose_notice, %{"class" => "prod.fired"}}
    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")
  end

  test "prod claims once, counts delivery once, and freezes its outbox numbers", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 99, "holder", seq)

    assert %{attemptCount: 1, prodCount: 1, deniedStreak: 0} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{
             lastEvaluatedTerminal: ^seq,
             pendingBranch: nil,
             pendingAssignment: nil,
             pendingK: nil,
             pendingN: nil
           } = Supervision.watermark(ctx.db, "holder")

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == "holder"
    assert wake.origin == "process:tightbeam"
    assert wake.prompt =~ "prod 1 of 3"
    assert wake.reresolve == nil

    assert [%{"decision" => "none", "ref" => "asg_1", "statute" => nil}] =
             rail_sweep_details(ctx.db, "holder")
  end

  # GH #23. asg_1 is open with no entitlement, which is the storm population: the
  # prod ladder answers :unarmed, the one branch that returned without a
  # watermark, so before the fix every tick re-ran the shift, re-adjudicated the
  # rail to the same :allow, and appended another identical
  # rail_sweep(decision=none). One host held 1,059,688 of them, 100% decision none.
  test "an unarmed assignment records its no-op once per terminal, not once per tick", ctx do
    seq = terminal!(ctx.db, "holder")

    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert [%{"decision" => "none", "ref" => "asg_1"}] = rail_sweep_details(ctx.db, "holder")

    # The audit evidence is written; what must stop is the repetition.
    for _ <- 1..25 do
      assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    end

    assert [%{"decision" => "none", "ref" => "asg_1"}] = rail_sweep_details(ctx.db, "holder")
    assert %{lastEvaluatedTerminal: ^seq} = Supervision.watermark(ctx.db, "holder")
  end

  test "a later meaningful change is still evaluated after an allowed no-op", ctx do
    first = terminal!(ctx.db, "holder")
    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", first)
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", first)
    assert length(rail_sweep_details(ctx.db, "holder")) == 1

    # A new terminal is new evidence: suppression is per-terminal, never permanent.
    second = terminal!(ctx.db, "holder")
    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", second)
    assert length(rail_sweep_details(ctx.db, "holder")) == 2

    # And the assignment stays eligible to be acted on once it is armed, which is
    # what recover_liveness does for exactly this population on a later tick.
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    third = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", third)
    assert %{attemptCount: 1, prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")
  end

  # The unarmed branch marks the terminal evaluated; it does not act, so it must
  # not disturb the pending columns. write_terminal_watermark_in_txn updates
  # lastEvaluatedTerminal only, unlike write_watermark/4, whose ON CONFLICT nulls
  # all four — correct for the acting arms that just resolved what they clear.
  test "the unarmed no-op advances only lastEvaluatedTerminal", ctx do
    seq = terminal!(ctx.db, "holder")
    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert {:ok, [[^seq, nil, nil, nil, nil]]} =
             DB.query(
               ctx.db,
               """
               SELECT lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN
               FROM supervision_watermarks WHERE sessionKey='holder' AND assignmentId='asg_1'
               """
             )
  end

  # The suppression is keyed on the assignment and lives in the branch that runs
  # only for a matched production, so a retractable no-match is untouched: a
  # work-blocked holder must still re-match this very terminal when the block is
  # lifted. That contract is asserted in full at "a standing work-blocked fact
  # unmatches the prod production until it is retracted"; this pins the watermark
  # specifically, since that is what the fix adds.
  test "a work-blocked holder is left re-matchable at the same terminal", ctx do
    file_fact(ctx.db, "work-blocked", "holder")
    seq = terminal!(ctx.db, "holder")

    assert :blocked = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Supervision.watermark(ctx.db, "holder") == nil

    file_fact(ctx.db, "work-unblocked", "holder")
    assert {:match, %{id: "asg_1"}} = Supervision.prod_production_matches?(ctx.db, "holder", seq)
  end

  # The suppression is keyed on the rail having adjudicated and allowed. A
  # pending self-created continuation short-circuits rail_step before it decides
  # anything, so that pass says nothing about whether the obligation is
  # satisfied, and cancelling the continuation must leave this same terminal
  # re-matchable. The remedy that then fires is asserted at "only a durable
  # self-created continuation suppresses the turn-end remedy"; this pins the
  # watermark, which is what the fix adds.
  test "a continuation-suppressed pass leaves the terminal re-matchable", ctx do
    self_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "self continuation",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "holder"
      })

    seq = terminal!(ctx.db, "holder")
    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert rail_sweep_details(ctx.db, "holder") == []
    assert Supervision.watermark(ctx.db, "holder") == nil

    cancel_wake!(ctx.db, self_wake)
    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert [%{"decision" => "none", "ref" => "asg_1"}] = rail_sweep_details(ctx.db, "holder")
    assert %{lastEvaluatedTerminal: ^seq} = Supervision.watermark(ctx.db, "holder")
  end

  test "an internal effort wake does not suppress the no-filing prod", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    Wakes.schedule(ctx.db, %{
      session_key: "holder",
      origin: "process:tightbeam",
      consumer: "effort_probe",
      due_at: System.system_time(:millisecond) + 60_000
    })

    assert Wakes.pending_count(ctx.db, "holder") == 0
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
  end

  test "the August 31 Cards 1, 3, 4, and 5 durable filings rebase liveness", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq1 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)
    [wake] = Wakes.list_pending(ctx.db)
    cancel_wake!(ctx.db, wake)

    # Exact wi_4ee303fa liveness specimens: Card 1's four filings; Card 3's
    # dependency fallback; Card 4's durable progress; and Card 5's dependency
    # fallback. att_99c4c115 remains the original valid dependency receipt.
    # This receipt-selection fixture deliberately does not model stale
    # post-closure state or unexpired-wake eligibility, which have separate
    # boundaries.
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests (id, assignmentId, kind, bySession, ts)
        VALUES
          ('att_44706a9f','asg_1','progress','holder',2),
          ('att_38a1a229','asg_1','progress','holder',3),
          ('att_f0f735ae','asg_1','progress','holder',4),
          ('att_7b4d29c1','asg_1','progress','holder',5),
          ('att_a6051dd2','asg_1','progress','holder',6),
          ('att_c532a60d','asg_1','progress','holder',7),
          ('att_de16e957','asg_1','progress','holder',8),
          ('att_99c4c115','asg_1','progress','holder',9)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts)
        VALUES
          ('att_cc66ba00','asg_1','verdict','cannot-proceed-external-main-red','flynn',10),
          ('att_c4f2d593','asg_1','verdict','liveness-crediting-false-stall','flynn',11),
          ('att_46f3b9a5','asg_1','verdict','liveness-crediting-false-stall','flynn',12),
          ('att_8ca4dfcd','asg_1','verdict','liveness-crediting-false-stall','flynn',13)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'"
      )

    seq2 = terminal!(ctx.db, "holder")
    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    assert %{attemptCount: 0, prodCount: 0, attestCount: 12, stalledAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok,
            [
              ["progress", "att_44706a9f"],
              ["progress", "att_38a1a229"],
              ["progress", "att_f0f735ae"],
              ["progress", "att_7b4d29c1"],
              ["progress", "att_a6051dd2"],
              ["progress", "att_c532a60d"],
              ["progress", "att_de16e957"],
              ["progress", "att_99c4c115"],
              ["verdict", "att_cc66ba00"],
              ["verdict", "att_c4f2d593"],
              ["verdict", "att_46f3b9a5"],
              ["verdict", "att_8ca4dfcd"]
            ]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId FROM supervision_liveness_receipts ORDER BY receiptId"
             )
  end

  # Immutable authority: art_201ab36d, SHA-256
  # fe0945a8a210d50db4b8ae27f5c46dcb63f63d6dcef5884a41d3402a662c590a.
  # These cases drive explicit durable rows or synchronous process barriers. They
  # deliberately do not sleep, poll, widen a timeout, or infer a deadline from the
  # wall clock.
  test "pending reminder coalescing releases reassessment without recording notification success",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq)

    assert {:ok, [[claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert is_map(JSON.decode!(claim)["pending"])

    assert {:ok, before_prods} =
             DB.query(
               ctx.db,
               "SELECT prodCount,lastProdAt FROM assignment_prods WHERE assignmentId='asg_1'"
             )

    before_events = EventLog.lifecycle_events(ctx.db)
    # Reconstruct the outstanding dispatch branch left by an earlier evaluation.
    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE supervision_watermarks SET pendingBranch='prod',pendingAssignment='asg_1',pendingK=2,pendingN=2 WHERE sessionKey='holder'"
             )

    result = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq)
    refute match?({:refused, _}, result)

    assert {:ok, [[nil]]} =
             DB.query(
               ctx.db,
               "SELECT pendingBranch FROM supervision_watermarks WHERE sessionKey='holder'"
             )

    assert {:ok, [[^claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert {:ok, ^before_prods} =
             DB.query(
               ctx.db,
               "SELECT prodCount,lastProdAt FROM assignment_prods WHERE assignmentId='asg_1'"
             )

    assert EventLog.lifecycle_events(ctx.db) == before_events
    assert length(Wakes.list_pending(ctx.db)) == 1
  end

  test "only proven unconsumed cancellation releases a reminder without success", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq)
    [wake] = Wakes.list_pending(ctx.db)

    assert {:ok, [[encoded]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert {:ok, :unresolved_consumer} =
             DB.transaction(
               ctx.db,
               &Tightbeam.ReminderDelivery.canceled_in_txn(&1, "asg_1", wake.wake_id)
             )

    assert {:ok, [[^encoded]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: true})
    cancel_wake!(ctx.db, wake)
    assert_receive {:firehose_notice, %{"class" => "wake.canceled", "payload" => payload}}
    assert payload["wakeId"] == wake.wake_id
    assert payload["state"] == "canceled"
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    assert {:ok, [[canceled]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    state = JSON.decode!(canceled)
    assert state["pending"] == nil
    assert state["claimEpoch"] == 2

    assert state["lastDisposition"] == %{
             "kind" => "canceled",
             "consumer" => %{"wake" => wake.wake_id},
             "epoch" => 1,
             "intent" => wake.wake_id
           }

    refute Map.has_key?(state, "lastDeliveredAt")
    refute Map.has_key?(state, "nextEligibleAt")

    assert {:ok, :no_claim} =
             DB.transaction(
               ctx.db,
               &Tightbeam.ReminderDelivery.canceled_in_txn(&1, "asg_1", wake.wake_id)
             )

    assert {:ok, [[^canceled]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")
  end

  for authority <- [:opener, :admin] do
    @tag repair_authority: authority
    test "external #{authority} repair requires matching incident and delivers its owned successor",
         %{repair_authority: authority} = ctx do
      Tightbeam.SupervisionConsumerFixture.run!(1, authority)
    end
  end

  test "attributed consequence API preserves newer pending evidence through real terminal success",
       ctx do
    Tightbeam.SupervisionConsumerFixture.run!(2, nil)
  end

  test "an unknown consumed reminder cannot be canceled or lose its owned claim", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", terminal!(ctx.db, "holder"))

    [wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, wake)
    assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "unknown-consumer")
    assert :ok = Ledger.finish(ctx.db, turn.seq, "failed_unknown")

    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: true})

    assert {:ok, [[claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, %{
                 wake_id: wake.wake_id,
                 expected_origin: wake.origin,
                 requester: %{kind: "process", id: "tightbeam"},
                 reason_kind: "requester_withdrew",
                 causal_source: %{kind: "verb_call"},
                 outcome: %{kind: "no_replacement"}
               })
             end)

    assert {:ok, :unresolved_consumer} =
             DB.transaction(
               ctx.db,
               &Tightbeam.ReminderDelivery.canceled_in_txn(&1, "asg_1", wake.wake_id)
             )

    assert {:ok, [[^claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert {:ok, [["failed_unknown"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [turn.seq])

    refute Map.has_key?(JSON.decode!(claim), "lastDeliveredAt")
    refute_receive {:firehose_notice, _}
  end

  test "a verdict is a typed fact receipt and resets the ladder once", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq1 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)
    cancel_wake!(ctx.db, hd(Wakes.list_pending(ctx.db)))

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_verdict','asg_1','verdict','verified','flynn',2)"
      )

    seq2 = terminal!(ctx.db, "holder")
    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    assert %{
             attemptCount: 0,
             prodCount: 0,
             supervisionGeneration: 3,
             supervisionBasisKind: "liveness_receipt"
           } =
             Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, [["verdict", "att_verdict", 3]]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId,generation FROM supervision_liveness_receipts"
             )

    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    seq3 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq3)
  end

  test "several typed effects produce one generation with exact source receipts", ctx do
    attach_work_item!(ctx.db, "asg_1", "wi_receipts")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 9_000_000_000_000)
    name = start_liveness!(ctx, sweep_ms: 60_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_fact','asg_1','verdict','verified','flynn',9000000000000)"
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_item_events (ts, workItemId, kind) VALUES (9000000001000, 'wi_receipts', 'metadata')"
      )

    sweep_liveness!(name)

    assert {:ok, [["verdict", "att_fact", 2], ["work_item_update", "1", 2]]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId,generation FROM supervision_liveness_receipts ORDER BY receiptId"
             )

    assert %{
             supervisionState: "armed",
             supervisionGeneration: 2,
             supervisionDueAt: 9_000_000_061_000,
             supervisionIntervalMs: 60_000,
             supervisionBasisKind: "liveness_receipt",
             supervisionCause: "liveness_receipt",
             supervisionPrincipal: "process:tightbeam"
           } = Supervision.prod_state(ctx.db, "asg_1")

    sweep_liveness!(name)

    assert %{supervisionGeneration: 2, supervisionDueAt: 9_000_000_061_000} =
             Supervision.prod_state(ctx.db, "asg_1")
  end

  test "an assignment artifact is an effect receipt; an unrelated artifact is not", ctx do
    attach_work_item!(ctx.db, "asg_1", "wi_receipts")
    insert_entitlement!(ctx.db, "asg_1", generation: 4, due_at: 0, interval: 60_000)
    insert_artifact!(ctx.db, "art_other", "holder", "wi_other", 9_000_000_000_000)
    insert_artifact!(ctx.db, "art_effect", "holder", "wi_receipts", 9_000_000_001_000)

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert %{
             supervisionState: "armed",
             supervisionGeneration: 5,
             supervisionDueAt: 9_000_000_061_000,
             supervisionBasisKind: "liveness_receipt"
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, [["artifact", "art_effect"]]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId FROM supervision_liveness_receipts"
             )

    assert Wakes.list_pending(ctx.db) == []
  end

  test "one bounded assignment checkpoint resets; repeats need a later effect", ctx do
    attach_work_item!(ctx.db, "asg_1", "wi_checkpoint")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0, interval: 60_000)
    now = System.system_time(:millisecond)

    {first, seq1} =
      schedule_checkpoint_via_gateway!(ctx, "resume receipt work", 60_000)

    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)

    {second, seq2} =
      schedule_checkpoint_via_gateway!(ctx, "same checkpoint again", 120_000)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)
    prod = Enum.find(Wakes.list_pending(ctx.db), &(&1.origin == "process:tightbeam"))
    cancel_wake!(ctx.db, prod)

    insert_artifact!(ctx.db, "art_checkpoint_reset", "holder", "wi_checkpoint", now + 1)
    seq3 = terminal!(ctx.db, "holder")
    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq3)

    {third, seq4} =
      schedule_checkpoint_via_gateway!(ctx, "checkpoint after durable effect", 180_000)

    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq4)

    assert {:ok,
            [
              ["checkpoint", first_id],
              ["artifact", "art_checkpoint_reset"],
              ["checkpoint", third_id]
            ]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId FROM supervision_liveness_receipts ORDER BY receiptId"
             )

    assert first_id == first.wake_id
    assert third_id == third.wake_id
    refute second.wake_id in [first_id, third_id]
  end

  test "unrelated progress and unbound, unrelated, or expired wakes are not receipts", ctx do
    assignment(ctx.db, "asg_other", "holder", "other work", 2)
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    now = System.system_time(:millisecond)

    for input <- [
          %{prompt: "unbound", due_at: now + 60_000},
          %{prompt: "other assignment", due_at: now + 60_000, assignment_id: "asg_other"},
          %{prompt: "expired", due_at: 1, assignment_id: "asg_1"}
        ] do
      Wakes.schedule(
        ctx.db,
        Map.merge(
          %{
            session_key: "holder",
            origin: "session:holder",
            creator_session_key: "holder"
          },
          input
        )
      )
    end

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id,assignmentId,kind,note,bySession,ts) VALUES ('att_unrelated','asg_other','progress','other work','holder',?1)",
        [now]
      )

    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq)
    assert {:ok, []} = DB.query(ctx.db, "SELECT receiptId FROM supervision_liveness_receipts")
  end

  test "a receipt waits for an already-issued controller and resets after it settles", ctx do
    terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 4, due_at: 0, interval: 60_000)

    name = start_liveness!(ctx, sweep_ms: 60_000)
    assert [%{assignment_id: "asg_1"} = charged] = Wakes.list_pending(ctx.db)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_after_due','asg_1','verdict','verified','flynn',9000000000000)"
      )

    sweep_liveness!(name)
    assert Wakes.get(ctx.db, charged.wake_id).state == "pending"
    assert :appended = admit_supervision_wake!(ctx.db, charged)
    assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "receipt-after-controller")
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")

    sweep_liveness!(name)

    assert %{
             supervisionState: "armed",
             supervisionGeneration: 6,
             supervisionDueAt: 9_000_000_060_000,
             supervisionBasisKind: "liveness_receipt",
             attemptCount: 0,
             prodCount: 0
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert Ledger.last_terminal_seq(ctx.db, "holder") == turn.seq
  end

  test "settled controller verdict reset then holder typed wait survives restart and suppresses due sweep",
       ctx do
    Tightbeam.SupervisionConsumerFixture.run!(3, nil)
  end

  test "restart preserves an armed deadline and a later receipt captures the replacement interval",
       ctx do
    insert_entitlement!(ctx.db, "asg_1",
      generation: 7,
      due_at: 9_000_000_000_000,
      interval: 1_000
    )

    _first = start_liveness!(ctx, sweep_ms: 1_000)
    assert :ok = stop_supervised(Supervision)

    second = start_liveness!(ctx, sweep_ms: 2_000)

    assert %{
             supervisionGeneration: 7,
             supervisionDueAt: 9_000_000_000_000,
             supervisionIntervalMs: 1_000
           } = Supervision.prod_state(ctx.db, "asg_1")

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_restart','asg_1','verdict','verified','flynn',9000000032000)"
      )

    sweep_liveness!(second)

    assert %{
             supervisionGeneration: 8,
             supervisionDueAt: 9_000_000_034_000,
             supervisionIntervalMs: 2_000,
             supervisionBasisKind: "liveness_receipt"
           } = Supervision.prod_state(ctx.db, "asg_1")
  end

  test "restart drains one durable claimed branch and later sweeps retry without recounting",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 5_000, interval: 1_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET state='claimed', claimClock=5000, lastAttemptGeneration=2, cause='deadline'
        WHERE assignmentId='asg_1'
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO assignment_prods
          (assignmentId, attemptCount, prodCount, deniedStreak)
        VALUES ('asg_1', 1, 0, 0)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment,
           pendingK, pendingN)
        VALUES ('holder', 0, 'prod', 'asg_1', 1, 2)
        """
      )

    test_pid = self()

    retrying =
      Map.put(ctx.handlers, "wake", fn _call ->
        send(test_pid, :claimed_branch_drained)
        %{code: "server_error"}
      end)

    name =
      start_liveness!(%{ctx | handlers: retrying},
        name: :claimed_branch_recovery,
        sweep_ms: 1_000
      )

    assert_receive :claimed_branch_drained
    refute_receive :claimed_branch_drained

    assert %{attemptCount: 1, supervisionGeneration: 2, supervisionState: "claimed"} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: "prod", pendingAssignment: "asg_1"} =
             Supervision.watermark(ctx.db, "holder")

    sweep_liveness!(name)
    assert_receive :claimed_branch_drained
    refute_receive :claimed_branch_drained

    assert %{attemptCount: 1, supervisionGeneration: 2, supervisionState: "claimed"} =
             Supervision.prod_state(ctx.db, "asg_1")
  end

  test "an unbound continuation does not defer a due entitlement", ctx do
    terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 9, due_at: 0, interval: 60_000)

    continuation =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "session:holder",
        prompt: "continue later",
        due_at: 9_000_000_000_000
      })

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert %{supervisionState: "armed", supervisionGeneration: 10, prodCount: 1} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert Wakes.get(ctx.db, continuation.wake_id).state == "pending"
    assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.assignment_id == "asg_1"))
  end

  test "terminal recovery and retirement remove child entitlements permanently", ctx do
    assignment(ctx.db, "asg_completed", "holder", "complete", 2)
    assignment(ctx.db, "asg_surrendered", "holder", "surrender", 3)
    assignment(ctx.db, "asg_revoked", "holder", "revoke", 4)

    for id <- ~w(asg_completed asg_surrendered asg_revoked) do
      insert_entitlement!(ctx.db, id, generation: 1, due_at: 9_000_000_000_000)
    end

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES
          ('att_completed','asg_completed','completion','holder',10),
          ('att_surrendered','asg_surrendered','surrender','holder',11)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='completed', closedAt=10, closedBySession='holder', closingAttestId='att_completed' WHERE id='asg_completed'"
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='surrendered', closedAt=11, closedBySession='holder', closingAttestId='att_surrendered' WHERE id='asg_surrendered'"
      )

    :ok = persist_terminal_race!(ctx.db, "asg_revoked", 12)

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM supervision_entitlements WHERE assignmentId IN ('asg_completed','asg_surrendered','asg_revoked')"
             )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET generation=3, dueAt=9000000000000, state='armed',
            lastAttemptGeneration=NULL, claimClock=NULL, basisKind='assignment_open',
            basisId='asg_1', cause='assignment_open', principal='user:flynn',
            supervisionIntervalMs=60000
        WHERE assignmentId='asg_1'
        """
      )

    retire!(ctx.db, "holder")

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id='asg_1'")

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )
  end

  test "startup recovery revokes an open assignment whose holder is already retired", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 4, due_at: 9_000_000_000_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET state='retired', updatedAt=2 WHERE sessionKey='holder'"
      )

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id='asg_1'")

    assert {:ok, [["interrupted-by-retire"]]} =
             DB.query(
               ctx.db,
               "SELECT reason FROM assignment_interruptions WHERE assignmentId='asg_1'"
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )
  end

  test "durable parent-turn admission replaces the child row with one virtual transfer proof",
       ctx do
    terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", terminal_seq)

    assert [escalation] = Wakes.list_pending(ctx.db)
    assert escalation.reresolve == "lineage"

    assert :appended = admit_supervision_wake!(ctx.db, escalation)

    assert %{
             supervisionState: "parent_elevated",
             supervisionTransferWakeId: transfer_wake,
             supervisionTransferSessionKey: "supervisor",
             supervisionDueAt: nil,
             supervisionTerminusAt: nil
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert transfer_wake == escalation.wake_id

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT 1 FROM supervision_entitlements WHERE assignmentId='asg_1'")
  end

  test "Gateway parent retirement rearms an active holder with the supervision override", ctx do
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    # An inactive intermediate ancestor is skipped by lineage resolution and by
    # the active-subtree retirement walk, leaving the holder available to rearm.
    session(ctx.db, "retired_bridge", "supervisor")
    Org.retire(ctx.db, "retired_bridge", "user:flynn", 1_000)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy='retired_bridge' WHERE sessionKey='holder'")

    terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0, interval: 1_234)
    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 10, supervision_interval_ms: 4_321})

    assert {:ok, [[0, 1_234]]} =
             DB.query(
               ctx.db,
               "SELECT dueAt, supervisionIntervalMs FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, handlers, 0, "holder", terminal_seq)

    assert [escalation] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, escalation)

    assert %{supervisionState: "parent_elevated", supervisionTransferSessionKey: "supervisor"} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT dueAt FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )

    assert {:ok, [["running"]]} =
             DB.query(
               ctx.db,
               "SELECT mechanicalStatus FROM sessions WHERE sessionKey=\'supervisor\'"
             )

    assert {:ok, [[prior_updated_at]]} =
             DB.query(
               ctx.db,
               "SELECT updatedAt FROM sessions WHERE sessionKey=\'supervisor\'"
             )

    result =
      handlers["retire"].(%{
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: "supervisor",
        params: %{}
      })

    assert result.retired_session_keys == ["supervisor"]
    assert Org.get(ctx.db, "holder").state == "active"
    assert {:ok, [["open"]]} = DB.query(ctx.db, "SELECT state FROM assignments WHERE id='asg_1'")

    assert {:ok, [["parent_retirement", "parent_target_retired", 4_321, due_at]]} =
             DB.query(
               ctx.db,
               "SELECT basisKind, cause, supervisionIntervalMs, dueAt FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )

    assert {:ok, [["child_rearm", epoch]]} =
             DB.query(
               ctx.db,
               "SELECT retirementOutcomeKind, retirementEpoch FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert due_at == epoch + 4_321

    assert {:ok, [["retired", "idle", updated_at]]} =
             DB.query(
               ctx.db,
               "SELECT state,mechanicalStatus,updatedAt FROM sessions WHERE sessionKey=\'supervisor\'"
             )

    assert updated_at >= epoch
    assert updated_at > prior_updated_at
  end

  test "startup uses the newest valid parent transfer when history has earlier transfers", ctx do
    Tightbeam.SupervisionConsumerFixture.run!(4, nil)
  end

  test "startup normalizes legacy lineage markers and starts fresh bounded supervision", ctx do
    :ok = DB.execute(ctx.db, "DROP TRIGGER supervision_lineage_fire_requires_sidecar")

    legacy =
      Wakes.schedule(ctx.db, %{
        session_key: "supervisor",
        origin: "process:tightbeam",
        prompt: "legacy escalation history",
        due_at: 0,
        assignment_id: "asg_1",
        reresolve: "lineage",
        reresolve_seed: "holder",
        reresolve_rung: 1
      })

    assert {:ok, {:appended, _target, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 "supervisor",
                 legacy.origin,
                 legacy.prompt,
                 wake_id: legacy.wake_id,
                 sender: legacy.origin,
                 target_gate: legacy,
                 fire_wake_in_txn: true,
                 assignment_id: "asg_1"
               )
             end)

    expected_prompt = "[from process:tightbeam]\n\nlegacy escalation history"

    assert {:ok, [[turn_seq, message_id, ^expected_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT seq, messageId, prompt FROM turns WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert {:ok, [[message_content]]} =
             DB.query(ctx.db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert message_content =~ "legacy escalation history"

    assert {:ok, [["lineage", "holder", 1]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert :ok = Schema.ensure_all(ctx.db)

    name = start_liveness!(ctx, name: :legacy_marker_cleanup, sweep_ms: 60_000)
    assert is_pid(Process.whereis(name))

    assert {:ok, [[nil, nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [legacy.wake_id]
             )

    migration_id = "0.1.6/normalize-sidecarless-lineage-v1"

    assert {:ok, [[^migration_id, 1, "release_upgrade", "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               "SELECT migrationId,affectedRows,cause,principal FROM supervision_liveness_migrations"
             )

    assignment(ctx.db, "asg_post_receipt", "holder", "post receipt", 10)

    post_receipt =
      Wakes.schedule(ctx.db, %{
        session_key: "supervisor",
        origin: "process:tightbeam",
        prompt: "post-receipt ordinary delivery",
        due_at: 0,
        assignment_id: "asg_post_receipt"
      })

    assert {:ok, {:appended, _target, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 post_receipt.session_key,
                 post_receipt.origin,
                 post_receipt.prompt,
                 wake_id: post_receipt.wake_id,
                 sender: post_receipt.origin,
                 target_gate: post_receipt,
                 fire_wake_in_txn: true,
                 assignment_id: "asg_post_receipt"
               )
             end)

    assert {:ok, [[0, 0]]} =
             DB.query(
               ctx.db,
               """
               SELECT
                 (SELECT COUNT(*) FROM supervision_liveness_sidecar WHERE wakeId=?1),
                 (SELECT COUNT(*) FROM supervision_entitlements WHERE assignmentId='asg_post_receipt')
               """,
               [post_receipt.wake_id]
             )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE wakes SET reresolve='lineage',reresolveSeed='holder',reresolveRung=1 WHERE wakeId=?1",
        [post_receipt.wake_id]
      )

    assert_raise RuntimeError, ~r/invalid_parent_transfer/, fn ->
      Supervision.recover_liveness!(ctx.db, 60_000)
    end

    assert {:ok, [["lineage", "holder", 1]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [post_receipt.wake_id]
             )

    assert {:ok, [[nil, nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM supervision_liveness_migrations WHERE migrationId=?1",
               [migration_id]
             )

    assert {:ok, [[^turn_seq, ^message_id, ^expected_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT seq, messageId, prompt FROM turns WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert {:ok, [[^message_content]]} =
             DB.query(ctx.db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert %{
             attemptCount: 0,
             prodCount: 0,
             supervisionState: "armed",
             supervisionGeneration: 1,
             supervisionBasisKind: "recovery_backfill"
           } = Supervision.prod_state(ctx.db, "asg_1")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'"
      )

    fresh_terminal = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", fresh_terminal)

    assert [%{assignment_id: "asg_1", wake_id: fresh_wake_id}] = Wakes.list_pending(ctx.db)
    refute fresh_wake_id == legacy.wake_id

    assert {:ok, [["prod", "pending", 2]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind, controllerState, chargedGeneration FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [fresh_wake_id]
             )
  end

  test "startup migrates one legacy retired parent transfer to Main exactly once", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, state, createdByUser, createdAt)
        VALUES ('wi_legacy_transfer', 'legacy transfer', 'flynn', 'open', 'flynn', 1)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET workItemId='wi_legacy_transfer' WHERE id='asg_1'"
      )

    terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", terminal_seq)

    assert [source_wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, source_wake)

    assert {:ok, [[source_turn_seq]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [source_wake.wake_id])

    assert {:ok, [["running"]]} =
             DB.query(
               ctx.db,
               "SELECT mechanicalStatus FROM sessions WHERE sessionKey=\'supervisor\'"
             )

    source_evidence = "asg_1##{source_turn_seq}"

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET state='retired', updatedAt=2 WHERE sessionKey='supervisor'"
      )

    assert {:ok, [[activation_epoch]]} =
             DB.query(ctx.db, "SELECT activatedAt FROM supervision_liveness_epoch WHERE id=0")

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok,
            [
              [
                ^source_evidence,
                ^activation_epoch,
                "supervisor",
                "main_elevation",
                successor_id,
                main_key,
                "legacy_parent_target_retired",
                "process:tightbeam",
                1
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT transferEvidenceId, retirementEpoch, retiringSessionKey,
                      retirementOutcomeKind, retirementOutcomeId,
                      retirementTargetSessionKey, retirementCause,
                      retirementPrincipal, retirementActionNeeded
               FROM supervision_liveness_sidecar
               WHERE wakeId=?1
               """,
               [source_wake.wake_id]
             )

    assert main_key == ctx.main.session_key

    assert {:ok, [["retired", "idle"]]} =
             DB.query(
               ctx.db,
               "SELECT state,mechanicalStatus FROM sessions WHERE sessionKey=\'supervisor\'"
             )

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [
               source_turn_seq
             ])

    ["asg_1", successor_turn] = String.split(successor_id, "#", parts: 2)
    {successor_turn_seq, ""} = Integer.parse(successor_turn)

    assert {:ok,
            [
              [
                successor_wake_id,
                ^main_key,
                "fired",
                "retirement_elevation",
                "escalation",
                "settled",
                nil
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT w.wakeId, t.sessionKey, w.state, s.controllerOrigin, s.wakeKind,
                      s.controllerState, s.chargedGeneration
               FROM turns t
               JOIN wakes w ON w.wakeId=t.wakeId
               JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
               WHERE t.seq=?1
               """,
               [successor_turn_seq]
             )

    assert successor_wake_id != source_wake.wake_id

    assert %{
             supervisionState: "parent_elevated",
             supervisionCause: "legacy_parent_target_retired",
             supervisionPrincipal: "process:tightbeam",
             supervisionTransferWakeId: ^successor_wake_id,
             supervisionTransferSessionKey: ^main_key,
             supervisionRetirementEpoch: ^activation_epoch,
             supervisionRetirementOutcomeKind: "main_elevation",
             supervisionRetirementOutcomeId: ^successor_id,
             supervisionActionNeeded: true
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, [[2, 2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*), COUNT(DISTINCT wakeId) FROM turns WHERE assignmentId='asg_1'"
             )

    assert :ok = stop_supervised(Supervision)
    _replay = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok, [[2, 2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*), COUNT(DISTINCT wakeId) FROM turns WHERE assignmentId='asg_1'"
             )
  end

  test "n zero escalates, retired rungs are skipped, and the holder-seeded cycle sinks at Main",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.reresolve == "lineage"
    assert wake.reresolve_seed == "holder"
    assert wake.reresolve_rung == 1

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy = 'holder' WHERE sessionKey = 'supervisor'")

    assert Supervision.ladder_target(ctx.db, "holder", 1) == "supervisor"
    assert Supervision.ladder_target(ctx.db, "holder", 2) == ctx.main.session_key

    retire!(ctx.db, "supervisor")
    assert Supervision.ladder_target(ctx.db, "holder", 1) == ctx.main.session_key
  end

  # The ladder's last rung is the owner's MAIN session, and that key is composed
  # from a user id rather than read from a row. Every substrate notice addressed
  # to a user with no main session went to a session that does not exist, was
  # accepted by delivery, and queued forever — six of them in one soak.
  test "the ladder answers nobody rather than composing a key for a session that has no row",
       ctx do
    assert Supervision.ladder_target(ctx.db, "holder", 2) == ctx.main.session_key

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM sessions WHERE sessionKey = ?1", [ctx.main.session_key])

    assert Supervision.ladder_target(ctx.db, "holder", 2) == nil
    # Rungs above the chain are the same answer, not a deeper composed key.
    assert Supervision.ladder_target(ctx.db, "holder", 9) == nil
  end

  test "a retired main session is nobody too — the ladder verifies, it does not compose", ctx do
    retire!(ctx.db, ctx.main.session_key)
    assert Supervision.ladder_target(ctx.db, "holder", 2) == nil
  end

  # Review finding 2. The watermark row says "escalation"; retiring it as
  # terminus must clear THAT row. Clearing against a rewritten branch loses the
  # CAS silently, and a watermark that never clears re-enters this path — and
  # re-logs it — on every one-second sweep, forever.
  test "an escalation whose ladder empties at drain time clears its watermark", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    # Re-arm a pending ESCALATION on the row, then empty the ladder underneath
    # it. Re-evaluating the SAME terminal keeps evaluate on its :duplicate path,
    # so nothing rewrites the watermark after the drain — which is the only way
    # to see whether the drain itself cleared it. Re-evaluating a NEW terminal
    # masks the bug: claim_and_act overwrites the whole row regardless.
    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_watermarks SET lastEvaluatedTerminal=?1, pendingBranch='escalation', pendingAssignment='asg_1', pendingK=1, pendingN=0 WHERE sessionKey='holder'",
        [seq]
      )

    retire!(ctx.db, "supervisor")

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM sessions WHERE sessionKey = ?1", [ctx.main.session_key])

    Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    # THE property: the row the drain cleared is the row the database holds.
    assert %{pendingBranch: nil, pendingAssignment: nil} = Supervision.watermark(ctx.db, "holder")
  end

  # The reproduction, end to end: this is the exact shape of the six orphans —
  # `process:tightbeam` re-resolving a lineage whose owner has no main session.
  test "a lineage notice for an owner with no main session enqueues nothing and is named", ctx do
    retire!(ctx.db, "supervisor")

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM sessions WHERE sessionKey = ?1", [ctx.main.session_key])

    gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :skipped =
                 Gateway.deliver_prompt(
                   ctx.main.session_key,
                   "process:tightbeam",
                   "a notice with no deliverable holder",
                   db: ctx.db,
                   sender: "process:tightbeam",
                   target_gate: gate
                 )
      end)

    assert log =~ "undeliverable"
    assert log =~ "holder"

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
    assert Ledger.non_terminal_older_than(ctx.db, -1) == []
  end

  # Review finding 4, on the GATE-LESS arm — the one path that reaches the echo,
  # because it accepts its session key without re-resolving anything. The echo
  # commits in the same transaction and cannot be taken back, so a refused
  # delivery must write NOTHING: a message with no turn is history nobody can
  # answer, and it surfaces as ghost transcript if that key is ever created.
  test "a refused delivery commits no message, not just no turn", ctx do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :skipped =
                 Gateway.deliver_prompt(
                   "agent:main:clawline:nobody:main",
                   "process:tightbeam",
                   "a notice for a key that names no session",
                   db: ctx.db,
                   sender: "process:tightbeam"
                 )
      end)

    assert log =~ "refusing a turn addressed to agent:main:clawline:nobody:main"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", [
               "agent:main:clawline:nobody:main"
             ])
  end

  test "retirement revokes the held assignment and cancels its pending wake", ctx do
    existing =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    seq = terminal!(ctx.db, "holder")
    retire!(ctx.db, "holder")

    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.get(ctx.db, existing.wake_id).state == "canceled"
    assert Assignments.list(ctx.db, %{holder_key: "holder", state: "open"}) == []

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id='asg_1'")
  end

  test "turn-end remedy acts once through the episode claim and records run-remedy", ctx do
    prepare_review_gate(ctx)
    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live", occurrence: 1, producer_key: producer_key} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert is_binary(producer_key)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = 'asg_1'"
             )

    assert [
             %{
               "decision" => "run-remedy",
               "ref" => "asg_1",
               "statute" => "completion-needs-review"
             }
           ] = rail_sweep_details(ctx.db, "holder")

    assert Supervision.prod_state(ctx.db, "asg_1") == nil
  end

  test "turn-end escalation still opens and parks the same decision request", ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert {:ok, [[id, "open", park_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT id, status, parkWakeId FROM decision_requests WHERE statuteName = 'completion-needs-owner'"
             )

    assert is_binary(id)
    assert is_binary(park_wake_id)

    assert %{condition_kind: "escalation-ruled", condition_scope: ^id} =
             Wakes.get(ctx.db, park_wake_id)

    assert [
             %{
               "decision" => "escalate-park",
               "ref" => "asg_1",
               "statute" => "completion-needs-owner"
             }
           ] = rail_sweep_details(ctx.db, "holder")
  end

  test "a permanently skipped park does not re-evaluate inline or starve the server", ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    {:ok, [[id, park_wake_id]]} =
      DB.query(ctx.db, "SELECT id, parkWakeId FROM decision_requests")

    proxy = :"park_rule_race_db_#{System.unique_integer([:positive])}"
    start_supervised!({ParkRaceDB, {proxy, ctx.db, self(), :rule_allow}})
    name = :"park_no_spin_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision,
       db: proxy, handlers: ctx.handlers, prod_limit: 3, sweep_ms: 60_000, name: name}
    )

    :sys.get_state(name)
    cancel_wake!(ctx.db, Wakes.get(ctx.db, park_wake_id))

    {:ok, _} =
      DB.query(ctx.db, "UPDATE decision_requests SET parkWakeId = NULL WHERE id = ?1", [id])

    retry_seq = terminal!(ctx.db, "holder")
    Supervision.notify_terminal(name, "holder", retry_seq)

    assert_receive {:request_changed_before_park, :rule_allow, ^id}

    # The first barrier proves the terminal handler returned. If that handler self-cast a
    # retry, the cast may sit just behind this already-queued call; the second barrier is
    # necessarily behind it and therefore proves that no inline retry was left to run.
    :sys.get_state(name)
    :sys.get_state(name)
    refute_receive {:request_rechecked, :rule_allow, _}

    assert {:ok, [["ruled", nil]]} =
             DB.query(ctx.db, "SELECT status, parkWakeId FROM decision_requests WHERE id = ?1", [
               id
             ])

    refute match?(
             %{lastEvaluatedTerminal: ^retry_seq},
             Supervision.watermark(ctx.db, "holder")
           )
  end

  test "the production sweep re-drives a permanent skip and parks a still-live obligation",
       ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    {:ok, [[stale_id, park_wake_id]]} =
      DB.query(ctx.db, "SELECT id, parkWakeId FROM decision_requests")

    proxy = :"park_withdraw_race_db_#{System.unique_integer([:positive])}"
    start_supervised!({ParkRaceDB, {proxy, ctx.db, self(), :withdraw}})
    cancel_wake!(ctx.db, Wakes.get(ctx.db, park_wake_id))

    {:ok, _} =
      DB.query(ctx.db, "UPDATE decision_requests SET parkWakeId = NULL WHERE id = ?1", [stale_id])

    # Finish the old park before starting supervision. Keep the production timer long enough
    # to prove the terminal notification owns the permanent skip; the test timer below then
    # delivers the real scheduled-sweep handler that must re-drive it.
    name = :"park_sweep_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision,
       db: proxy, handlers: ctx.handlers, prod_limit: 3, sweep_ms: 120_000, name: name}
    )

    :sys.get_state(name)
    retry_seq = terminal!(ctx.db, "holder")
    Supervision.notify_terminal(name, "holder", retry_seq)

    assert_receive {:request_changed_before_park, :withdraw, ^stale_id}
    :sys.get_state(name)
    :sys.get_state(name)
    refute_receive {:request_rechecked, :withdraw, _}
    Process.send_after(name, :scheduled_sweep, 0)

    try do
      assert_receive {:request_rechecked, :withdraw, 2}
    rescue
      error in ExUnit.AssertionError ->
        # Capture only this synthetic arena after the original assertion fails.
        # Never trigger a sweep, retry a query through the proxy, or extend the wait.
        for {label, read} <- [
              {:supervisor,
               fn ->
                 case Process.whereis(name) do
                   nil -> :not_running
                   pid -> Process.info(pid, [:status, :current_stacktrace, :message_queue_len])
                 end
               end},
              {:proxy, fn -> :sys.get_state(proxy, 100) end},
              {:watermarks, fn -> DB.query(ctx.db, "SELECT * FROM supervision_watermarks") end},
              {:requests,
               fn ->
                 DB.query(
                   ctx.db,
                   "SELECT id,status,parkWakeId FROM decision_requests ORDER BY rowid"
                 )
               end},
              {:wakes, fn -> DB.query(ctx.db, "SELECT wakeId,state,assignmentId FROM wakes") end},
              {:lifecycle,
               fn ->
                 DB.query(
                   ctx.db,
                   "SELECT kind,subject,detail FROM lifecycle_events ORDER BY id DESC LIMIT 20"
                 )
               end}
            ] do
          result =
            try do
              read.()
            rescue
              diagnostic_error -> {:diagnostic_error, Exception.message(diagnostic_error)}
            catch
              kind, reason -> {:diagnostic_error, kind, reason}
            end

          IO.inspect(result, label: "park-race-failure #{label}", limit: :infinity)
        end

        reraise error, __STACKTRACE__
    end

    assert eventually(fn ->
             match?(
               {:ok, [[^stale_id, "withdrawn", nil], [new_id, "open", park_wake_id]]}
               when new_id != stale_id and is_binary(park_wake_id),
               DB.query(
                 ctx.db,
                 "SELECT id, status, parkWakeId FROM decision_requests ORDER BY rowid"
               )
             )
           end),
           "the scheduled supervision sweep never parked the replacement request"

    assert %{lastEvaluatedTerminal: ^retry_seq} = Supervision.watermark(ctx.db, "holder")
  end

  test "only a durable self-created continuation suppresses the turn-end remedy", ctx do
    prepare_review_gate(ctx)

    self_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "self continuation",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "holder"
      })

    assert Wakes.self_pending_count(ctx.db, "holder") == 1
    seq = terminal!(ctx.db, "holder")
    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1") == nil
    assert Supervision.prod_state(ctx.db, "asg_1") == nil

    cancel_wake!(ctx.db, self_wake)

    reminder =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "user reminder",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: nil
      })

    assert Wakes.pending_count(ctx.db, "holder") == 1
    assert Wakes.self_pending_count(ctx.db, "holder") == 0

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert Wakes.get(ctx.db, reminder.wake_id).state == "pending"
    assert Supervision.prod_state(ctx.db, "asg_1") == nil
  end

  test "an unrelated selected classed fyi wake does not suppress the turn-end remedy", ctx do
    prepare_review_gate(ctx)

    {:ok, _policy} =
      DB.transaction(ctx.db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          %{session_key: "holder", target_role: nil},
          true,
          "notice-batching-test-policy:supervision-held-fyi",
          "agent:test-policy",
          "supervision-fixture",
          1
        )
      end)

    held =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "process:tightbeam",
        prompt: "unrelated fyi, held by the batcher",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "holder",
        class: "fyi"
      })

    assert held.delivery_rule == Wakes.digest_rule()
    refute held.digest
    assert Wakes.self_pending_count(ctx.db, "holder") == 0

    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert Wakes.get(ctx.db, held.wake_id).state == "pending"
  end

  test "a default-off legacy fyi wake does not suppress the turn-end remedy", ctx do
    prepare_review_gate(ctx)

    held =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "process:tightbeam",
        prompt: "default-off unrelated fyi",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "holder",
        class: "fyi"
      })

    assert held.delivery_rule == "turn-boundary-digest r1"
    assert NoticeBatcher.source_refs(ctx.db, held.wake_id) == []
    assert Wakes.self_pending_count(ctx.db, "holder") == 0

    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert Wakes.get(ctx.db, held.wake_id).state == "pending"
  end

  test "turn-end denial without a remedy records re-obligate and uses the normal prod", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    load_turn_end_deny(ctx)
    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert [
             %{
               "decision" => "re-obligate",
               "ref" => "asg_1",
               "statute" => "completion-still-owed"
             }
           ] = rail_sweep_details(ctx.db, "holder")
  end

  # The sweep is the second actor, so the ruling of 2026-07-29 (rails-mechanism §A3) has
  # to reach it too: a rail-check timeout summons a mind here as well. What it must NOT do
  # is park the session — parking is the escalate EFFECT's consequence, and the ruling
  # changed what a timeout additionally does, not what it decides. So the sweep outcome
  # stays the pure deny's: re-obligate, then the normal prod.
  test "a turn-end timeout summons a mind and still re-obligates without parking", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    stage_rail_wrapper(ctx, "rail-timeout")

    write_rules(ctx, """
    [[rule]]
    name = "completion-check-times-out"
    verb = "attest"
    text = "completion is gated on a check"
    edges = ["turn-end"]
    [rule.check]
    script = "rail-timeout"
    returns = ["pass"]
    [rule.check.effects]
    pass = "allow"
    """)

    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert [
             %{
               "decision" => "re-obligate",
               "ref" => "asg_1",
               "statute" => "completion-check-times-out"
             }
           ] = rail_sweep_details(ctx.db, "holder")

    assert {:ok, [["completion-check-times-out", "open", nil]]} =
             DB.query(ctx.db, "SELECT statuteName, status, parkWakeId FROM decision_requests")
  end

  # Recovery through the SWEEP, driven by the real `Supervision.evaluate/5` wiring rather
  # than by calling `Rules.decide` and the close by hand — the point is that the sweep
  # actually runs its `to_close`, which hand-calling the pieces would assume rather than
  # prove. The sensor heals between two turn-ends and the episode closes with no operator
  # verb anywhere in the loop.
  test "the turn-end sweep recovers an episode once the check answers again", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    stage_rail_wrapper(ctx, "rail-timeout")

    gate = fn script ->
      write_rules(ctx, """
      [[rule]]
      name = "completion-check-times-out"
      verb = "attest"
      text = "completion is gated on a check"
      edges = ["turn-end"]
      [rule.check]
      script = "#{script}"
      returns = ["pass"]
      [rule.check.effects]
      pass = "allow"
      """)
    end

    gate.("rail-timeout")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, [[id, "open"]]} =
             DB.query(ctx.db, "SELECT id, status FROM decision_requests")

    # A pending prod wake suppresses the next sweep, so clear it the way the prod-counter
    # tests do — the turn under test is the one AFTER the sensor heals.
    for wake <- Wakes.list_pending(ctx.db), do: cancel_wake!(ctx.db, wake)

    # The check recovers. The next sweep renders an observed verdict and the episode goes
    # with it — through the sweep's own actor path.
    stage_rail_script(ctx, "rail-pass", "#!/bin/sh\nprintf pass\n")
    gate.("rail-pass")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1' AND state='armed'"
      )

    assert {:prodded, _} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, [["withdrawn", "process:tightbeam", "sensor-recovered"]]} =
             DB.query(
               ctx.db,
               "SELECT status, withdrawnBy, withdrawnReason FROM decision_requests WHERE id = ?1",
               [id]
             )
  end

  test "atomic target gate skips plain dead targets and re-runs the ladder for escalation", ctx do
    registry = start_supervised!({ConnRegistry, name: :supervision_conn_registry})
    lane = start_supervised!({LaneDoorbell, :supervision_lane_manager})
    retire!(ctx.db, "supervisor")

    plain =
      Wakes.schedule(ctx.db, %{
        session_key: "supervisor",
        target_role: nil,
        origin: "process:tightbeam",
        prompt: "plain",
        due_at: 0
      })

    assert :skipped =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "plain",
               db: ctx.db,
               wake_id: plain.wake_id,
               sender: "process:tightbeam",
               target_gate: plain,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, "supervisor") == 0
    assert Wakes.get(ctx.db, plain.wake_id).state == "pending"
    cancel_wake!(ctx.db, plain)

    gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

    assert :appended =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "escalate",
               db: ctx.db,
               wake_id: "w_lineage",
               sender: "process:tightbeam",
               target_gate: gate,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 1
    assert Ledger.pending_count(ctx.db, "holder") == 0
  end

  test "supervision wake is fired in the enqueue transaction before its provoked terminal", ctx do
    Tightbeam.SupervisionConsumerFixture.run!(5, nil)
  end

  test "external direct wake keeps deliver-then-mark ordering", ctx do
    external =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "process:ci",
        prompt: "external",
        due_at: 0
      })

    parent = self()
    registry = start_supervised!({ConnRegistry, name: :external_order_registry})

    lane =
      start_supervised!(
        {RaceLane,
         {:external_order_lane,
          fn "holder" ->
            send(parent, {:external_state_at_nudge, Wakes.get(ctx.db, external.wake_id).state})
          end}}
      )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :external_order_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:external_state_at_nudge, "pending"}
    assert Wakes.get(ctx.db, external.wake_id).state == "fired"
  end

  test "repeated synchronous delivery racer advances every prod and quiesces only at Main terminus",
       ctx do
    Tightbeam.SupervisionConsumerFixture.run!(6, nil)
  end

  test "delivered prod and escalation prompts match the stamped templates byte for byte", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    registry = start_supervised!({ConnRegistry, name: :template_registry})
    lane = start_supervised!({LaneDoorbell, :template_lane})

    prod_seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", prod_seq)
    [prod] = Wakes.list_pending(ctx.db)

    assert :appended =
             Gateway.deliver_prompt(prod.session_key, prod.origin, prod.prompt,
               db: ctx.db,
               wake_id: prod.wake_id,
               sender: prod.origin,
               target_gate: prod,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    expected_prod =
      "[from process:tightbeam]\n\n" <>
        "Your turn ended with no qualifying receipt or admitted continuation covering assignment asg_1 — \"ship it\". " <>
        "File a qualifying receipt, register an obligation-scoped continuation, or file truthful completion or surrender. This is prod 1 of 3; " <>
        "a reply without a row escalates to your spawner."

    assert {:ok, [[^expected_prod]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId = ?1", [prod.wake_id])

    # v1 excluded prod turns from attribution for want of a durable carrier;
    # job-forensics-v2 gives the wake one, so the delivered turn now inherits it.
    # jobRef stays NULL here because this assignment belongs to no work item.
    assert prod.assignment_id == "asg_1"

    assert {:ok, [["asg_1", nil]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId, jobRef FROM turns WHERE wakeId = ?1",
               [prod.wake_id]
             )

    session(ctx.db, "escalating-holder", ctx.supervisor.session_key)
    assignment(ctx.db, "asg_escalation", "escalating-holder", "investigate", 3)
    insert_entitlement!(ctx.db, "asg_escalation", generation: 1, due_at: 0)
    escalation_seq = terminal!(ctx.db, "escalating-holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "escalating-holder", escalation_seq)

    [escalation] = Wakes.list_pending(ctx.db)

    assert {:ok, [["escalation", "pending", 2]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind,controllerState,chargedGeneration FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert {:error, %DB.Error{message: pending_sidecar_update}} =
             DB.query(
               ctx.db,
               "UPDATE supervision_liveness_sidecar SET wakeKind='prod' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert pending_sidecar_update =~ "pending supervision controller permits settlement only"

    assert {:error, %DB.Error{message: pending_sidecar_delete}} =
             DB.query(
               ctx.db,
               "DELETE FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert pending_sidecar_delete =~ "pending supervision controller sidecar is required"

    assert {:error, %DB.Error{message: pending_wake_update}} =
             DB.query(
               ctx.db,
               "UPDATE wakes SET sessionKey='holder' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert pending_wake_update =~ "pending supervision controller wake identity is immutable"

    incoherent =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "process:ci",
        prompt: "not a supervision controller",
        due_at: 0,
        assignment_id: "asg_escalation"
      })

    assert {:error, %DB.Error{message: incoherent_insert}} =
             DB.query(
               ctx.db,
               """
               INSERT INTO supervision_liveness_sidecar
                 (wakeId,assignmentId,controllerOrigin,wakeKind,controllerState,chargedGeneration)
               VALUES (?1,'asg_escalation','scheduled','prod','pending',2)
               """,
               [incoherent.wake_id]
             )

    assert incoherent_insert =~ "supervision sidecar requires coherent pending wake"

    assert :appended =
             Gateway.deliver_prompt(escalation.session_key, escalation.origin, escalation.prompt,
               db: ctx.db,
               wake_id: escalation.wake_id,
               sender: escalation.origin,
               target_gate: escalation,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    expected_escalation =
      "[from process:tightbeam]\n\n" <>
        "Assignment asg_escalation — \"investigate\" — held by escalating-holder is stalled: " <>
        "0 prods produced no qualifying receipt and no admitted continuation covering it. This is escalation 1 for this assignment. " <>
        "Why, and what happens next, is your judgment — the substrate only reports the rows."

    assert {:ok, [[^expected_escalation]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId = ?1", [escalation.wake_id])

    assert {:error, %DB.Error{message: delete_message}} =
             DB.query(
               ctx.db,
               "DELETE FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert delete_message =~ "fired supervision lineage sidecar is required"

    assert {:error, %DB.Error{message: update_message}} =
             DB.query(
               ctx.db,
               "UPDATE supervision_liveness_sidecar SET wakeKind='prod' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert update_message =~ "fired supervision lineage sidecar identity is immutable"

    assert {:error, %DB.Error{message: state_message}} =
             DB.query(
               ctx.db,
               "UPDATE supervision_liveness_sidecar SET controllerState='pending' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert state_message =~ "fired supervision lineage sidecar identity is immutable"

    assert {:error, %DB.Error{message: turn_update_message}} =
             DB.query(
               ctx.db,
               """
               UPDATE turns
               SET seq=seq+100000, sessionKey='holder',
                   wakeId='w_rewritten', assignmentId=NULL
               WHERE wakeId=?1
               """,
               [escalation.wake_id]
             )

    assert turn_update_message =~ "fired supervision lineage turn attribution is immutable"

    assert {:error, %DB.Error{message: turn_delete_message}} =
             DB.query(ctx.db, "DELETE FROM turns WHERE wakeId=?1", [escalation.wake_id])

    assert turn_delete_message =~ "fired supervision lineage turn is required"

    assert {:ok, [["escalation", "settled"]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind,controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )
  end

  test "wake validation requires the complete re-resolution triple and nudge false leaves due work pending",
       ctx do
    wake = ctx.handlers["wake"]

    invalid = %{
      origin: "process:tightbeam",
      session_key: "holder",
      params: %{prompt: "x", reresolve: "lineage"}
    }

    assert %{code: "invalid"} = wake.(invalid)

    valid = %{
      origin: "process:tightbeam",
      session_key: "supervisor",
      params: %{
        prompt: "x",
        after_ms: 0,
        nudge: false,
        reresolve: "lineage",
        reresolve_seed: "holder",
        reresolve_rung: 1
      }
    }

    assert %{state: "pending"} = wake.(valid)
    assert [%{reresolve: "lineage"}] = Wakes.list_pending(ctx.db)
  end

  test "supervision wake creation and controller sidecar commit atomically", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0, interval: 60_000)
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    assert {:ok, [[wake_id, "escalation", "pending", 2]]} =
             DB.query(
               ctx.db,
               """
               SELECT w.wakeId, s.wakeKind, s.controllerState, s.chargedGeneration
               FROM wakes w
               JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
               WHERE w.assignmentId='asg_1'
               """
             )

    assert is_binary(wake_id)
  end

  test "a rejected supervision controller schedule rolls back its wake row", ctx do
    insert_entitlement!(ctx.db, "asg_1",
      generation: 1,
      due_at: 9_000_000_000_000,
      interval: 60_000
    )

    wake = ctx.handlers["wake"]

    assert_raise RuntimeError, ~r/controller schedule :duplicate/, fn ->
      wake.(%{
        origin: "process:tightbeam",
        principal: {:process, "tightbeam"},
        session_key: "holder",
        params: %{
          prompt: "must not strand a controller wake",
          after_ms: 0,
          nudge: false,
          assignment_id: "asg_1",
          supervision_wake_kind: "prod"
        }
      })
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_1'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar")
  end

  test "a supervision controller without an entitlement rolls back its wake row", ctx do
    {:ok, _} = DB.query(ctx.db, "DELETE FROM supervision_entitlements WHERE assignmentId='asg_1'")
    wake = ctx.handlers["wake"]

    assert_raise RuntimeError, ~r/controller schedule :duplicate/, fn ->
      wake.(%{
        origin: "process:tightbeam",
        principal: {:process, "tightbeam"},
        session_key: "holder",
        params: %{
          prompt: "stale pending supervision branch",
          after_ms: 0,
          nudge: false,
          assignment_id: "asg_1",
          supervision_wake_kind: "prod"
        }
      })
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_1'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar")
  end

  test "an unknown internal supervision controller kind rolls back its wake row", ctx do
    wake = ctx.handlers["wake"]

    assert_raise RuntimeError, ~r/unknown controller kind "mystery"/, fn ->
      wake.(%{
        origin: "process:tightbeam",
        principal: {:process, "tightbeam"},
        session_key: "holder",
        params: %{
          prompt: "invalid controller kind",
          after_ms: 0,
          nudge: false,
          assignment_id: "asg_1",
          supervision_wake_kind: "mystery"
        }
      })
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_1'")
  end

  test "production scheduler cancels an unavailable supervision target without stranding its controller",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    terminal_seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal_seq)

    assert [wake] = Wakes.list_pending(ctx.db)

    assert {:ok, [["prod", "pending", 2]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind,controllerState,chargedGeneration FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [wake.wake_id]
             )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='holder'")

    registry = start_supervised!({ConnRegistry, name: :unavailable_target_registry})
    lane = start_supervised!({LaneDoorbell, :unavailable_target_lane})

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :unavailable_target_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)

    assert %{state: "canceled", fired_at: nil} = Wakes.get(ctx.db, wake.wake_id)

    assert {:ok, [["settled"]]} =
             DB.query(
               ctx.db,
               "SELECT controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok, [["target_unresolvable", "scheduler_delivery", "no_replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,causalSourceKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok, []} = DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])
    assert Wakes.list_pending(ctx.db) == []

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "supervision_controller_unavailable" and &1.subject == "asg_1")
           )
  end

  test "transient refusal preserves the outbox and a later edge drains without recounting", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq1 = terminal!(ctx.db, "holder")

    assert {:refused, "server_error"} =
             Supervision.evaluate(ctx.db, transient, 3, "holder", seq1)

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: "prod", pendingK: 1, pendingN: 3} =
             Supervision.watermark(ctx.db, "holder")

    seq2 = terminal!(ctx.db, "holder")
    assert :not_due = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq2)
    assert %{attemptCount: 1, prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{lastEvaluatedTerminal: ^seq2, pendingBranch: nil} =
             Supervision.watermark(ctx.db, "holder")

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "supervision_dispatch_failed")
           ) == 1
  end

  test "statute-tier denials clear atomically, count attempts only, and block at the threshold",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    denied = Map.put(ctx.handlers, "wake", fn _ -> %{code: "rule_denied"} end)
    seq1 = terminal!(ctx.db, "holder")
    seq2 = terminal!(ctx.db, "holder")

    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq1)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET generation=2, dueAt=0, state='armed', lastAttemptGeneration=NULL,
            claimClock=NULL, cause='policy_denied', principal='process:tightbeam'
        WHERE assignmentId='asg_1' AND state='claimed'
        """
      )

    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq2)

    assert %{attemptCount: 2, prodCount: 0, deniedStreak: 2, lastProdAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq2} =
             Supervision.watermark(ctx.db, "holder")

    lifecycle = EventLog.lifecycle_events(ctx.db)
    assert Enum.count(lifecycle, &(&1.kind == "supervision_prod_denied")) == 2
    assert Enum.count(lifecycle, &(&1.kind == "supervision_blocked")) == 1
    assert Wakes.list_pending(ctx.db) == []
  end

  test "a policy denial event, counter, branch settlement, and successor share one transaction",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 3, due_at: 5_000, interval: 1_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET state='claimed', claimClock=5000, lastAttemptGeneration=3, cause='deadline'
        WHERE assignmentId='asg_1'
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO assignment_prods
          (assignmentId, attemptCount, prodCount, deniedStreak)
        VALUES ('asg_1', 1, 0, 0)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment,
           pendingK, pendingN)
        VALUES ('holder', 7, 'prod', 'asg_1', 1, 2)
        """
      )

    assert {:error, %RuntimeError{message: "forced policy rollback"}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 """
                 INSERT INTO events
                   (ts, kind, verb, origin, principal, sessionKey, payload)
                 VALUES (5000, 'denied', 'wake', 'process:tightbeam',
                         'process:tightbeam', 'holder', '{}')
                 """
               )

               [[event_id]] = Tightbeam.DB.Txn.q(txn, "SELECT last_insert_rowid()")

               assert {:armed, 4} =
                        Supervision.transition_in_txn(txn, %{
                          kind: "policy_denied",
                          assignment_id: "asg_1",
                          event_id: event_id,
                          evaluation_clock: 5_000
                        })

               raise "forced policy rollback"
             end)

    assert {:ok, [[3, "claimed", 5_000]]} =
             DB.query(
               ctx.db,
               "SELECT generation, state, claimClock FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT deniedStreak FROM assignment_prods WHERE assignmentId='asg_1'"
             )

    assert {:ok, [["prod", "asg_1"]]} =
             DB.query(
               ctx.db,
               "SELECT pendingBranch, pendingAssignment FROM supervision_watermarks WHERE sessionKey='holder'"
             )

    assert {:ok, event_id} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 """
                 INSERT INTO events
                   (ts, kind, verb, origin, principal, sessionKey, payload)
                 VALUES (5000, 'denied', 'wake', 'process:tightbeam',
                         'process:tightbeam', 'holder', '{}')
                 """
               )

               [[event_id]] = Tightbeam.DB.Txn.q(txn, "SELECT last_insert_rowid()")

               assert {:armed, 4} =
                        Supervision.transition_in_txn(txn, %{
                          kind: "policy_denied",
                          assignment_id: "asg_1",
                          event_id: event_id,
                          evaluation_clock: 5_000
                        })

               event_id
             end)

    assert {:ok,
            [[4, 6_000, "armed", "policy_denied", basis_id, "policy_denied", "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               """
               SELECT generation, dueAt, state, basisKind, basisId, cause, principal
               FROM supervision_entitlements
               WHERE assignmentId='asg_1'
               """
             )

    assert basis_id == to_string(event_id)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT deniedStreak FROM assignment_prods WHERE assignmentId='asg_1'"
             )

    assert {:ok, [[nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT pendingBranch, pendingAssignment FROM supervision_watermarks WHERE sessionKey='holder'"
             )
  end

  test "drain precedes idle and dedupe for a stale closed-assignment promise", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq = terminal!(ctx.db, "holder")
    assert {:refused, "server_error"} = Supervision.evaluate(ctx.db, transient, 3, "holder", seq)

    :ok = persist_terminal_race!(ctx.db, "asg_1", 2)

    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq} =
             Supervision.watermark(ctx.db, "holder")

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert Wakes.list_pending(ctx.db) == []
  end

  test "Main self-target takes the no-wake terminus exactly once", ctx do
    assignment(ctx.db, "asg_main", ctx.main.session_key, "main work", 2)
    insert_entitlement!(ctx.db, "asg_main", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, ctx.main.session_key)

    assert :terminus =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert :duplicate =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert %{attemptCount: 1, prodCount: 0, stalledAt: stalled} =
             Supervision.prod_state(ctx.db, "asg_main")

    assert is_integer(stalled)
    assert Wakes.list_pending(ctx.db) == []

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "supervision_terminus")) ==
             1
  end

  test "an unrelated pending wake does not suppress or duplicate a prod", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    continuation =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.get(ctx.db, continuation.wake_id).state == "pending"
    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")
  end

  test "total catch contains exits and records evaluation failure without losing the claim",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    exiting = Map.put(ctx.handlers, "wake", fn _ -> exit(:handler_exit) end)
    seq = terminal!(ctx.db, "holder")
    name = :"supervision_exit_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!({Supervision, db: ctx.db, handlers: exiting, prod_limit: 3, name: name})

    Supervision.notify_terminal(name, "holder", seq)

    assert eventually(fn ->
             Enum.any?(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "supervision_evaluate_failed")
             )
           end),
           "the contained exit was never recorded as an evaluation failure"

    assert Process.alive?(pid)
    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert %{pendingBranch: "prod"} = Supervision.watermark(ctx.db, "holder")
  end

  test "retirement handling is total-caught before the server continues", ctx do
    name = :"supervision_retired_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Supervision, db: ctx.db, handlers: ctx.handlers, prod_limit: 3, name: name}
      )

    :ok = DB.execute(ctx.db, "DROP TABLE decision_requests")
    Supervision.notify_retired(name, "holder")

    assert eventually(fn ->
             Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
               event.kind == "supervision_evaluate_failed" and event.subject == "holder"
             end)
           end),
           "the caught retirement failure was never recorded for holder"

    assert Process.alive?(pid)
    Supervision.request_sweep(name)

    # Same cast barrier: alive? proves nothing about a sweep still sitting in the
    # mailbox, and alive? was this test's only other assertion.
    :sys.get_state(name)
    assert Process.alive?(pid)
  end

  test "retiring a holder revokes its assignments without a stranded-work notice",
       ctx do
    name = start_retirement_supervision(ctx)

    retire!(ctx.db, "holder")
    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, "supervisor", nil, 10) == []
    assert Ledger.pending_count(ctx.db, "supervisor") == 0
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []

    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, "supervisor", nil, 10) == []
    assert Ledger.pending_count(ctx.db, "supervisor") == 0
  end

  test "retirement revocation does not create a fallback stranded-work notice",
       ctx do
    name = start_retirement_supervision(ctx)

    retire!(ctx.db, "supervisor")
    retire!(ctx.db, "holder")
    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, "supervisor", nil, 10) == []
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 0
  end

  test "retiring a holder without open assignments delivers no strand notice", ctx do
    idle = session(ctx.db, "idle-holder", ctx.supervisor.session_key)
    name = start_retirement_supervision(ctx)

    retire!(ctx.db, idle.session_key)
    Supervision.notify_retired(name, idle.session_key)
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, ctx.supervisor.session_key, nil, 10) == []
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []
    assert Ledger.pending_count(ctx.db, ctx.supervisor.session_key) == 0
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 0
  end

  test "N=0 cross-assignment re-entry exceeds N+1 and then quiesces at Main", ctx do
    Tightbeam.SupervisionConsumerFixture.run!(7, nil)
  end

  test "past-sink open assignment emits one escalation per external terminal and duplicate re-entry is inert",
       ctx do
    Tightbeam.SupervisionConsumerFixture.run!(8, nil)
  end

  test "atomic delivery concurrent-retirement race has only before-or-after outcomes", ctx do
    registry = start_supervised!({ConnRegistry, name: :race_conn_registry})
    lane = start_supervised!({LaneDoorbell, :race_lane_manager})

    for iteration <- 1..20 do
      target = "race_target_#{iteration}"
      session(ctx.db, target, ctx.main.session_key)

      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?1 WHERE sessionKey='holder'", [target])

      gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

      delivery =
        Task.async(fn ->
          Gateway.deliver_prompt(target, "process:tightbeam", "race",
            db: ctx.db,
            wake_id: "w_race_#{iteration}",
            sender: "process:tightbeam",
            target_gate: gate,
            conn_registry: registry,
            lane_manager: lane
          )
        end)

      retirement = Task.async(fn -> retire!(ctx.db, target) end)
      assert :appended = Task.await(delivery)
      Task.await(retirement)

      {:ok, rows} =
        DB.query(ctx.db, "SELECT sessionKey FROM turns WHERE wakeId=?1", ["w_race_#{iteration}"])

      assert [[recipient]] = rows
      assert recipient in [target, ctx.main.session_key]
      refute recipient == "holder"
    end
  end

  # spec production-machine-v1 §The prod production: work-blocked is not
  # suppression bolted onto the prodder — the production does not match, the
  # same absence-of-match as a session with no open assignment.
  test "a standing work-blocked fact unmatches the prod production until it is retracted", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    file_fact(ctx.db, "work-blocked", "holder")

    # The queue is never gated by the standing fact: the blocked holder's
    # turn is accepted, claimed, and finished as ever — a parent that orders
    # a retry must be able to land one.
    seq = terminal!(ctx.db, "holder")

    assert {:no_match, :work_blocked, %{id: "asg_1"}} =
             Supervision.prod_production_matches?(ctx.db, "holder", seq)

    assert :blocked = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.list_pending(ctx.db) == []
    # Nothing was claimed and nothing watermarked: retraction re-matches this
    # very terminal from current state.
    assert Supervision.watermark(ctx.db, "holder") == nil

    file_fact(ctx.db, "work-unblocked", "holder")

    assert {:match, %{id: "asg_1"}} =
             Supervision.prod_production_matches?(ctx.db, "holder", seq)

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
  end

  # Recognition happens at act time or it is not recognition: the claim and
  # the dispatch are two phases, and a fact filed between them must still be
  # seen by the drain.
  test "a pending branch claimed before work-blocked is discarded at drain, not dispatched",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq = terminal!(ctx.db, "holder")
    assert {:refused, "server_error"} = Supervision.evaluate(ctx.db, transient, 3, "holder", seq)
    assert %{pendingBranch: "prod"} = Supervision.watermark(ctx.db, "holder")

    file_fact(ctx.db, "work-blocked", "holder")

    # The drain re-reads the standing fact and clears the branch without
    # dispatching. The claim already advanced the dedupe watermark, so this
    # terminal reads duplicate afterwards.
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert %{pendingBranch: nil} = Supervision.watermark(ctx.db, "holder")
    assert Wakes.list_pending(ctx.db) == []
    assert %{prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")

    file_fact(ctx.db, "work-unblocked", "holder")
    seq2 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq2)
  end

  # The prodder's TRUE act time is the wake FIRE (spec §The prod production;
  # the e2e that forced this fix watched a prod land after the block): a wake
  # scheduled by a pre-block drain is suppressed at delivery, consumed as
  # canceled with the reason named, never delivered.
  test "a prod wake scheduled before work-blocked is suppressed at fire, not delivered", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert [%{wake_id: wake_id}] = Wakes.list_pending(ctx.db)

    file_fact(ctx.db, "work-blocked", "holder")

    parent = self()

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: fn wake ->
           send(parent, {:delivered, wake.wake_id})
           true
         end,
         tick_ms: 60_000,
         name: :suppression_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, ^wake_id}, 200

    assert Wakes.get(ctx.db, wake_id).state == "canceled"

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "supervision_wake_suppressed" and &1.subject == wake_id)
           )

    # The rung is REFUNDED: schedule claimed prodCount 1, the suppressed fire
    # voided it. Without this, suppressed prods consume the ladder and a
    # blocked holder gets escalated over — the SMOKE 42 shrdlu finding.
    assert %{prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")

    # An agent's own wake to the SAME blocked session still delivers — the
    # fact suppresses supervision's mail, never anyone else's.
    agent_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "session:supervisor",
        prompt: "a colleague checking in",
        due_at: 0
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, delivered_id}, 500
    assert delivered_id == agent_wake.wake_id
  end

  test "work-blocked standing on another session leaves this holder's prods matching", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    file_fact(ctx.db, "work-blocked", "supervisor")
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
  end

  test "a shared harness incident suppresses only affected holders and resolution re-arms them",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    healthy = session(ctx.db, "healthy", ctx.supervisor.session_key)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET harness='codex', provider='openai' WHERE sessionKey=?1",
        [
          healthy.session_key
        ]
      )

    assignment(ctx.db, "asg_healthy", healthy.session_key, "healthy work", 2)
    insert_entitlement!(ctx.db, "asg_healthy", generation: 1, due_at: 0)
    open_rate_limit_incident!(ctx)

    assert {:no_match, :harness_unavailable, %{id: "asg_1"}} =
             Supervision.prod_production_matches?(ctx.db, ctx.holder.session_key, nil)

    assert :harness_unavailable =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, ctx.holder.session_key, nil)

    affected_terminal = terminal!(ctx.db, ctx.holder.session_key)
    healthy_terminal = terminal!(ctx.db, healthy.session_key)

    assert {:no_match, :harness_unavailable, %{id: "asg_1"}} =
             Supervision.prod_production_matches?(
               ctx.db,
               ctx.holder.session_key,
               affected_terminal
             )

    assert :harness_unavailable =
             Supervision.evaluate(
               ctx.db,
               ctx.handlers,
               3,
               ctx.holder.session_key,
               affected_terminal
             )

    assert Supervision.watermark(ctx.db, ctx.holder.session_key) == nil

    assert %{attemptCount: 0, prodCount: 0, supervisionState: "armed"} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert Wakes.list_pending(ctx.db) == []

    assert {:match, %{id: "asg_healthy"}} =
             Supervision.prod_production_matches?(
               ctx.db,
               healthy.session_key,
               healthy_terminal
             )

    assert {:prodded, 1} =
             Supervision.evaluate(
               ctx.db,
               ctx.handlers,
               3,
               healthy.session_key,
               healthy_terminal
             )

    resolve_rate_limit_incident!(ctx, affected_terminal)

    assert {:match, %{id: "asg_1"}} =
             Supervision.prod_production_matches?(
               ctx.db,
               ctx.holder.session_key,
               affected_terminal
             )

    assert {:prodded, 1} =
             Supervision.evaluate(
               ctx.db,
               ctx.handlers,
               3,
               ctx.holder.session_key,
               affected_terminal
             )
  end

  test "a harness incident discards a claimed branch before dispatch", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    terminal = terminal!(ctx.db, ctx.holder.session_key)

    assert {:refused, "server_error"} =
             Supervision.evaluate(ctx.db, transient, 3, ctx.holder.session_key, terminal)

    assert %{pendingBranch: "prod"} = Supervision.watermark(ctx.db, ctx.holder.session_key)
    assert %{supervisionCause: prior_cause} = Supervision.prod_state(ctx.db, "asg_1")
    open_rate_limit_incident!(ctx)

    assert :harness_unavailable =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, ctx.holder.session_key, terminal)

    assert %{pendingBranch: nil} = Supervision.watermark(ctx.db, ctx.holder.session_key)

    assert %{prodCount: 0, supervisionCause: ^prior_cause} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert Wakes.list_pending(ctx.db) == []
  end

  test "both supervision gates suppress every typed harness failure class", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    classes = [
      "auth-dead",
      "rate-limit-dead",
      "adapter_unavailable",
      "model_unavailable",
      "task_crash",
      "interrupted-outcome-unknown"
    ]

    Enum.with_index(classes, 1)
    |> Enum.each(fn {failure_class, index} ->
      open_authoritative_harness_incident!(ctx, failure_class, index)

      assert {:no_match, :harness_unavailable, %{id: "asg_1"}} =
               Supervision.prod_production_matches?(ctx.db, ctx.holder.session_key, nil)

      assert {:ok, true} =
               DB.transaction(
                 ctx.db,
                 &Supervision.harness_unavailable_in_txn?(&1, ctx.holder.session_key)
               )

      resolve_harness_incident!(ctx, failure_class, index)

      assert {:ok, false} =
               DB.transaction(
                 ctx.db,
                 &Supervision.harness_unavailable_in_txn?(&1, ctx.holder.session_key)
               )
    end)
  end

  defp real_consumer_fixture!(ctx, opts \\ []) do
    alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

    unless Process.whereis(Tightbeam.LaneRegistry),
      do: start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})

    unless Process.whereis(Tightbeam.ConnRegistry),
      do:
        start_supervised!(
          Supervisor.child_spec({ConnRegistry, name: Tightbeam.ConnRegistry},
            id: :r1_consumer_registry
          )
        )

    task_sup = start_supervised!({Task.Supervisor, []})

    {:ok, responder} =
      Task.Supervisor.start_child(task_sup, fn ->
        loop = fn loop ->
          receive do
            {:prompt_started, adapter} ->
              send(adapter, :continue_prompt)
              loop.(loop)

            _ ->
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET host=?1", [
               Tightbeam.Placement.local_host_name()
             ])

    adapter = start_supervised!({AdapterStub, {:unique_sessions, responder}})
    start_supervised!({CoordinatorStub, adapter})

    config = %{
      base_dir: Path.join(ctx.base, "gateway-consumer"),
      cwd: ctx.base,
      port: 0,
      db: ctx.db,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 60_000,
      onboarding_lease_ms: 1_800_000
    }

    {Tightbeam.LaneManager, options} =
      Enum.find(Gateway.children(config), &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(options, :runner)

    fn key ->
      assert {:ok, [[seq, wake_id, assignment_id]]} =
               DB.query(
                 ctx.db,
                 "SELECT seq,wakeId,assignmentId FROM turns WHERE sessionKey=?1 AND status='queued' ORDER BY seq",
                 [key]
               )

      receiver = self()

      {:ok, lane} =
        Tightbeam.SessionLane.start_link(
          session_key: key,
          db: ctx.db,
          task_sup: task_sup,
          runner: runner,
          on_terminal: fn _key, terminal_seq ->
            send(receiver, {:consumer_terminal, terminal_seq})
          end
        )

      try do
        assert_receive {:consumer_terminal, ^seq}, 60_000

        assert {:ok, [["delivered"]]} =
                 DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])

        assert {:ok, [[encoded]]} =
                 DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [
                   assignment_id
                 ])

        state = JSON.decode!(encoded)
        assert state["pending"] == nil
        expected_consumer = if is_nil(wake_id), do: %{"turn" => seq}, else: %{"wake" => wake_id}
        assert state["lastConsumer"] == expected_consumer

        assert (state["nextEligibleAt"] - state["lastDeliveredAt"]) in [
                 300_000,
                 900_000,
                 1_800_000
               ]

        # Explicit ladder-test clock setup, only AFTER actual successful terminal
        # delivery and its selected gap are proved. Do not fabricate success.
        if Keyword.get(opts, :expire_gap, true) do
          assert {:ok, _} =
                   DB.query(ctx.db, "UPDATE assignments SET reminderState=?2 WHERE id=?1", [
                     assignment_id,
                     JSON.encode!(Map.put(state, "nextEligibleAt", 0))
                   ])
        end

        %{seq: seq, wake_id: wake_id}
      after
        if Process.alive?(lane), do: GenServer.stop(lane)
      end
    end
  end

  # Model a committed terminal row before its downstream reconciliation. Keep the
  # real audit and generation constraints; using the full revoke handler here
  # would consume the callback race that these three tests exercise.
  defp persist_terminal_race!(db, assignment_id, at) do
    revocation_id = "rev_race_#{System.unique_integer([:positive])}"

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO assignment_revocations
                   (id, assignmentId, revokedAt, revokedByUser, reason)
                 VALUES (?1, ?2, ?3, 'flynn', 'synthetic terminal race')
                 """,
                 [revocation_id, assignment_id, at]
               )

               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO assignment_revocation_generations
                   (revocationId, assignmentId, reopeningId)
                 VALUES (?1, ?2, NULL)
                 """,
                 [revocation_id, assignment_id]
               )

               DB.Txn.q(
                 txn,
                 """
                 UPDATE assignments SET state='closed', outcome='revoked',
                   closedAt=?2, closedByUser='flynn'
                 WHERE id=?1 AND state='open'
                 """,
                 [assignment_id, at]
               )

               assert DB.Txn.changes(txn) == 1
               :ok
             end)

    :ok
  end

  defp cancel_wake!(db, wake) do
    {requester, principal, session_key} = cancellation_requester(wake.origin)

    assert {:ok, {:accepted_in_txn, event_id, %{canceled: true}}} =
             DB.transaction(db, fn txn ->
               trigger = ensure_cancellation_trigger_in_txn(txn, wake)

               outcome =
                 case trigger do
                   {:ok, liveness_trigger} ->
                     %{kind: "no_replacement", liveness_trigger: liveness_trigger}

                   :none ->
                     %{kind: "no_replacement"}
                 end

               Wakes.cancel_in_txn(txn, %{
                 wake_id: wake.wake_id,
                 expected_origin: wake.origin,
                 requester: requester,
                 reason_kind: "requester_withdrew",
                 causal_source: %{
                   kind: "verb_call",
                   accepted_event: %{
                     origin: wake.origin,
                     session_key: session_key,
                     principal: principal
                   }
                 },
                 outcome: outcome
               })
             end)

    assert event_id > 0

    :ok
  end

  defp ensure_cancellation_trigger_in_txn(txn, %{assignment_id: assignment_id})
       when is_binary(assignment_id) do
    case DB.Txn.q(
           txn,
           """
           SELECT a.state, a.openedAt, e.assignmentId
           FROM assignments a
           LEFT JOIN supervision_entitlements e ON e.assignmentId=a.id
           WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [["open", opened_at, nil]] ->
        Supervision.transition_in_txn(txn, %{
          kind: "assignment_open",
          assignment_id: assignment_id,
          opened_at: opened_at,
          supervision_interval_ms: 60_000,
          principal: "process:tightbeam"
        })

      _ ->
        :ok
    end

    Supervision.liveness_trigger_in_txn(txn, {:assignment, assignment_id})
  end

  defp ensure_cancellation_trigger_in_txn(txn, %{work_item_id: work_item_id})
       when is_binary(work_item_id) do
    Supervision.liveness_trigger_in_txn(txn, {:work_item, work_item_id})
  end

  defp ensure_cancellation_trigger_in_txn(_txn, _wake), do: :none

  defp cancellation_requester("user:" <> id), do: {%{kind: "user", id: id}, {:user, id}, nil}

  defp cancellation_requester("session:" <> id),
    do: {%{kind: "session", id: id}, {:session, id}, id}

  defp cancellation_requester("process:" <> id),
    do: {%{kind: "process", id: id}, {:process, id}, nil}

  defp start_liveness!(ctx, opts) do
    name = Keyword.get(opts, :name, :immutable_liveness_supervision)

    start_supervised!(
      {Supervision,
       db: ctx.db,
       handlers: ctx.handlers,
       prod_limit: Keyword.get(opts, :prod_limit, 2),
       sweep_ms: Keyword.fetch!(opts, :sweep_ms),
       name: name}
    )

    :sys.get_state(name)
    name
  end

  defp sweep_liveness!(name) do
    Supervision.request_sweep(name)
    :sys.get_state(name)
    :ok
  end

  defp insert_entitlement!(db, assignment_id, opts) do
    generation = Keyword.fetch!(opts, :generation)
    due_at = Keyword.fetch!(opts, :due_at)
    interval = Keyword.get(opts, :interval, 60_000)
    basis_kind = Keyword.get(opts, :basis_kind, "assignment_open")
    basis_id = Keyword.get(opts, :basis_id, assignment_id)
    cause = Keyword.get(opts, :cause, "assignment_open")

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
           basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
        VALUES (?1, ?2, ?3, 'armed', NULL, NULL, ?4, ?5, NULL, ?6,
                'process:tightbeam', ?7)
        """,
        [assignment_id, generation, due_at, basis_kind, basis_id, cause, interval]
      )

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT OR IGNORE INTO supervision_liveness_receipt_state
          (assignmentId, artifactCursor, attestCursor, workItemEventCursor, wakeCursor,
           baselineCause, baselinePrincipal)
        VALUES (?1,
                (SELECT COALESCE(MAX(rowid), 0) FROM artifacts),
                (SELECT COALESCE(MAX(rowid), 0) FROM attests),
                (SELECT COALESCE(MAX(id), 0) FROM work_item_events),
                (SELECT COALESCE(MAX(rowid), 0) FROM wakes),
                'assignment_open', 'process:tightbeam')
        """,
        [assignment_id]
      )

    :ok
  end

  defp terminal!(db, session_key) do
    message_id = "m_#{System.unique_integer([:positive])}"

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "user:flynn",
        prompt: "external"
      })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, session_key, "test")
    assert :ok = Ledger.finish(db, seq, "delivered")
    seq
  end

  defp schedule_checkpoint_via_gateway!(ctx, prompt, after_ms) do
    message_id = "checkpoint-turn-#{System.unique_integer([:positive])}"

    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: "holder",
               message_id: message_id,
               origin: "user:flynn",
               prompt: "checkpoint source turn",
               assignment_id: "asg_1",
               job_ref: "wi_checkpoint"
             })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, "holder", "checkpoint-writer")

    assert %{wake_id: wake_id, state: "pending"} =
             ctx.handlers["wake"].(%{
               origin: "user:flynn",
               principal: {:session, "holder"},
               session_key: "holder",
               params: %{
                 prompt: prompt,
                 after_ms: after_ms,
                 nudge: false
               }
             })

    wake = Wakes.get(ctx.db, wake_id)
    assert wake.assignment_id == nil
    assert wake.creator_session_key == "holder"

    assert {:ok, [["asg_1", "holder", ^seq, "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId,holderSessionKey,sourceTurnSeq,principal FROM supervision_liveness_checkpoint_bindings WHERE wakeId=?1",
               [wake_id]
             )

    assert :ok = Ledger.finish(ctx.db, seq, "delivered")
    {wake, seq}
  end

  defp prepare_review_gate(ctx) do
    reviewer = session(ctx.db, "reviewer", ctx.main.session_key)
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET harness='codex' WHERE sessionKey='reviewer'")
    Roles.create!(ctx.db, "reviewer", "flynn", reviewer.session_key)

    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-review"
      verb = "attest"
      text = "completion requires review"
      edges = ["verb", "turn-end"]
      effect = "remedy"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" },
        { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
      ]
      [rule.remedy]
      action = "assign"
      produces = "reviewed-clean"
      target_role = "reviewer"
      [rule.remedy.params]
      subject = "review of assignment {assignment_id}"
      reviews = "{assignment_id}"
      """
    )
  end

  defp load_turn_end_deny(ctx) do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-still-owed"
      verb = "attest"
      text = "completion remains owed"
      edges = ["turn-end"]
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )
  end

  # A script-tier statute needs the wrapper, the script, and a holder the rail will accept
  # as local — `invocation_context` refuses a non-local holder before anything is spawned,
  # which would class as `script_error` and never reach the timeout under test.
  defp stage_rail_wrapper(ctx, script) do
    # The rail resolves the holder's workdir through the host registry, so the table has
    # to exist; without it the resolution fails and the deny classes `script_error`.
    :ok = Tightbeam.Schema.ensure_all(ctx.db)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET host = 'testhost' WHERE sessionKey = ?1", [
        "holder"
      ])

    scripts = Path.join([ctx.base, "identity", "rails", "scripts"])
    bin = Path.join(ctx.base, "bin")
    File.mkdir_p!(scripts)
    File.mkdir_p!(bin)

    stage_rail_script(ctx, script, "#!/bin/sh\nexit 0\n")

    wrapper = Path.join(bin, "tightbeam")
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)
  end

  defp stage_rail_script(ctx, name, body) do
    path = Path.join([ctx.base, "identity", "rails", "scripts", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp write_rules(ctx, contents) do
    rules_dir = Path.join(ctx.base, "identity/rules")
    File.mkdir_p!(rules_dir)
    File.write!(Path.join(rules_dir, "turn-end.toml"), contents)
    Rules.load!(ctx.base, Map.keys(ctx.handlers))
  end

  # Agent origin on purpose: work-blocked is an agent-only kind, and
  # ConditionFacts refuses it from process:tightbeam — the substrate never
  # decides a session is blocked (spec production-machine-v1 §Standing facts).
  defp file_fact(db, kind, scope) do
    {:ok, %{fact_id: _}} =
      DB.transaction(
        db,
        &ConditionFacts.file_in_txn(&1, %{kind: kind, scope: scope, origin: "session:supervisor"})
      )

    :ok
  end

  defp open_rate_limit_incident!(ctx) do
    first = %{
      harness: "claude",
      host: "eezo",
      failure_class: "rate-limit-dead",
      evidence_kind: "terminal-failure",
      session_key: ctx.holder.session_key,
      assignment_id: "asg_1",
      observed_at: 100,
      correlation_id: "supervision-rate-limit-holder",
      cause: "terminal recovery-chain failure",
      principal: "process:tightbeam"
    }

    second = %{
      first
      | session_key: ctx.supervisor.session_key,
        assignment_id: nil,
        observed_at: 101,
        correlation_id: "supervision-rate-limit-supervisor"
    }

    assert {:pending, _} = HarnessHealth.observe(ctx.db, first)
    assert {:opened, _} = HarnessHealth.observe(ctx.db, second)
    :ok
  end

  defp resolve_rate_limit_incident!(ctx, terminal_seq) do
    :ok = HarnessProcess.complete_park(ctx.db, {:claude, "shared", "eezo"})

    assert {:resolved, _} =
             HarnessHealth.resolve(ctx.db, %{
               harness: "claude",
               host: "eezo",
               failure_class: "rate-limit-dead",
               session_key: ctx.holder.session_key,
               assignment_id: "asg_1",
               observed_at: 200,
               correlation_id: "supervision-normal-turn-#{terminal_seq}",
               cause: "normal turn delivered",
               principal: "process:tightbeam"
             })

    :ok
  end

  defp open_authoritative_harness_incident!(ctx, failure_class, index) do
    assert {:opened, _} =
             HarnessHealth.observe(ctx.db, %{
               harness: "claude",
               host: "eezo",
               failure_class: failure_class,
               evidence_kind: "authoritative-provider",
               session_key: ctx.holder.session_key,
               assignment_id: "asg_1",
               observed_at: 1_000 + index,
               correlation_id: "supervision-all-class-#{failure_class}-#{index}",
               cause: "typed harness failure #{failure_class}",
               principal: "process:tightbeam"
             })

    :ok
  end

  defp resolve_harness_incident!(ctx, failure_class, index) do
    if failure_class == "rate-limit-dead" do
      :ok = HarnessProcess.complete_park(ctx.db, {:claude, "shared", "eezo"})
    end

    assert {:resolved, _} =
             HarnessHealth.resolve(ctx.db, %{
               harness: "claude",
               host: "eezo",
               failure_class: failure_class,
               session_key: ctx.holder.session_key,
               assignment_id: "asg_1",
               observed_at: 2_000 + index,
               correlation_id: "supervision-all-class-resolved-#{failure_class}-#{index}",
               cause: "typed harness recovered #{failure_class}",
               principal: "process:tightbeam"
             })

    :ok
  end

  defp rail_sweep_details(db, session_key) do
    db
    |> EventLog.lifecycle_events()
    |> Enum.filter(&(&1.kind == "rail_sweep" and &1.subject == session_key))
    |> Enum.map(&JSON.decode!(&1.detail))
  end

  defp assignment(db, id, holder, subject, opened_at) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES (?1, ?2, ?3, 'flynn', ?4)",
        [id, subject, holder, opened_at]
      )
  end

  defp attach_work_item!(db, assignment_id, work_item_id) do
    ensure_work_item!(db, work_item_id)

    {:ok, _} =
      DB.query(db, "UPDATE assignments SET workItemId=?2 WHERE id=?1", [
        assignment_id,
        work_item_id
      ])

    :ok
  end

  defp ensure_work_item!(db, work_item_id) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT OR IGNORE INTO work_items
          (id,title,ownerUserId,state,createdByUser,createdAt)
        VALUES (?1,?1,'flynn','open','flynn',1)
        """,
        [work_item_id]
      )

    :ok
  end

  defp insert_artifact!(db, artifact_id, session_key, work_item_id, created_at) do
    ensure_work_item!(db, work_item_id)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO artifacts
          (artifactId,kind,title,createdBySession,workItemId,originPath,
           recordedTurnEvidence,state,createdAt,updatedAt)
        VALUES (?1,'report',?1,?2,?3,?1,'none','in-workspace',?4,?4)
        """,
        [artifact_id, session_key, work_item_id, created_at]
      )

    :ok
  end

  defp retire!(db, session_key) do
    {:ok, retired} =
      DB.transaction(db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(
          txn,
          session_key,
          "flynn",
          "user:flynn"
        )

        Org.retire_in_txn(txn, session_key, "user:flynn", 1_000)
      end)

    retired
  end

  defp session(db, key, spawned_by, built_in \\ false) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      kind: if(built_in, do: "main", else: "custom"),
      is_built_in: built_in,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end

  defp fire_all_pending(db, consume \\ nil) do
    for wake <- Wakes.list_pending(db) do
      case DB.query(
             db,
             "SELECT 1 FROM supervision_liveness_sidecar WHERE wakeId=?1 AND controllerState='pending'",
             [wake.wake_id]
           ) do
        {:ok, [[1]]} ->
          assert :appended = admit_supervision_wake!(db, wake)

          if consume do
            consume.(wake.session_key)
          else
            assert {:ok, %{seq: seq}} = Ledger.claim_next(db, wake.session_key, "test-controller")
            assert :ok = Ledger.finish(db, seq, "delivered")
          end

        {:ok, []} ->
          {:ok, _} =
            DB.query(
              db,
              "UPDATE wakes SET state='fired', firedAt=?2 WHERE wakeId=?1 AND state='pending'",
              [wake.wake_id, System.system_time(:millisecond)]
            )
      end
    end

    :ok
  end

  defp delivery_fun(db, registry, lane) do
    fn wake ->
      Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
        db: db,
        wake_id: wake.wake_id,
        sender: wake.origin,
        target_gate: wake,
        fire_wake_in_txn: wake.origin == "process:tightbeam",
        conn_registry: registry,
        lane_manager: lane
      )
    end
  end

  defp admit_supervision_wake!(db, wake) do
    assert {:ok, delivery} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 wake.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 target_gate: wake,
                 fire_wake_in_txn: true,
                 assignment_id: wake.assignment_id
               )
             end)

    case delivery do
      {:appended, _target, _message, _opts} -> :appended
      other -> other
    end
  end

  defp start_retirement_supervision(ctx) do
    suffix = System.unique_integer([:positive])
    registry = :"retirement_conn_registry_#{suffix}"
    lane = :"retirement_lane_manager_#{suffix}"
    name = :"retirement_supervision_#{suffix}"

    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({LaneDoorbell, lane})

    start_supervised!(
      {Supervision,
       db: ctx.db,
       handlers: ctx.handlers,
       prod_limit: 3,
       conn_registry: registry,
       lane_manager: lane,
       name: name}
    )

    name
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  # ── THE ORDER PIN (supervision-impl r21) ──────────────────────────────────
  # This assertion is the executable lease on the turn-end shift: the
  # schedule in Supervision.@turn_end_schedule may only change together with
  # (1) this literal, (2) the termination argument in supervision-impl-v1
  # §r21, and (3) a semantic justification for the new position — order is
  # meaning here (statutes outrank the ladder). If this test surprised you
  # red, you changed the shift without signing the lease — go read the
  # schedule comment in supervision.ex.
  test "the turn-end schedule is exactly the r21 shift, in order" do
    assert Tightbeam.Supervision.turn_end_schedule() == [
             :rail_enforcement,
             :prod_ladder
           ]
  end
end
