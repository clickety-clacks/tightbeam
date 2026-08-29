defmodule Tightbeam.EffortCheckinTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    Artifacts,
    Assignments,
    ConnRegistry,
    DB,
    Devices,
    EffortCheckin,
    Gateway,
    Ledger,
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

  setup do
    db = :"effort_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-effort-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:paired, _device} =
      claim_org(db, %{device_id: "effort-device", claimed_name: "h1", platform: nil, model: nil})

    Devices.add_user(db, "h2", false)
    Devices.add_user(db, "admin", true)

    host = Placement.local_host_name()
    main_key = Org.personal_session_key("h1")

    main = Org.get(db, main_key)

    ensure_main_session(db, "h2")
    parent = session(db, "parent", "h1", host)
    holder = session(db, "holder", "h2", host, %{spawned_by: "parent"})
    # The extra keys are what `Gateway.children_after_preflight/1` reads: the
    # notification drain uses the REAL prompt-wake child, not a test closure.
    config = %{
      db: db,
      base_dir: base_dir,
      cursor_signing: cursor_signing!(base_dir),
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

    %{
      db: db,
      base_dir: base_dir,
      config: config,
      main: main,
      parent: parent,
      holder: holder,
      root: root
    }
  end

  test "proof 1: assign and dispatch each arm one bracket; roots validate; all closes cancel",
       ctx do
    bare = assignment(ctx, "assign", {:user, "h1"}, "holder", %{subject: "bare"})

    assert [[1, "armed", bare_wake_id]] =
             rows(
               ctx.db,
               "SELECT generation,state,wakeId FROM effort_checkin_generations WHERE assignmentId=?1",
               [bare.id]
             )

    assert %{consumer: "effort_probe", state: "pending"} = Wakes.get(ctx.db, bare_wake_id)

    for bad <- ["/absolute", "../escape", "a/../escape"] do
      assert %{code: "invalid_workdir_root"} =
               assignment(ctx, "dispatch", {:session, "parent"}, "holder", %{
                 subject: "bad",
                 brief: "bad",
                 workdir_root: bad
               })
    end

    dispatched =
      assignment(ctx, "dispatch", {:session, "parent"}, "holder", %{
        subject: "scoped",
        brief: "work",
        workdir_root: "."
      })

    assert [[1, "armed", wake_id]] =
             rows(
               ctx.db,
               "SELECT generation,state,wakeId FROM effort_checkin_generations WHERE assignmentId=?1",
               [dispatched.id]
             )

    assert %{consumer: "effort_probe", state: "pending"} = Wakes.get(ctx.db, wake_id)

    for kind <- ["completion", "surrender"] do
      item = dispatch(ctx, {:session, "parent"}, "holder", kind)
      assignment(ctx, "attest", {:session, "holder"}, nil, %{assignment_id: item.id, kind: kind})
      assert bracket_state(ctx.db, item.id) == "canceled"

      assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [
               item.id
             ]) == [[0]]
    end

    revoked = dispatch(ctx, {:session, "parent"}, "holder", "revoked")

    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{
      assignment_id: revoked.id
    })

    assert bracket_state(ctx.db, revoked.id) == "canceled"

    retired = dispatch(ctx, {:session, "parent"}, "holder", "retired")
    fire_probe(ctx, retired.id)
    generation_state_before_refusal = bracket_state(ctx.db, retired.id)

    assert generation_state_before_refusal == "armed"

    assert {:error,
            %ArgumentError{message: "retirement interruption requires a durable principal"}} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.interrupt_for_retire_in_txn(txn, "holder", "h2", nil)
             end)

    assert rows(ctx.db, "SELECT state FROM assignments WHERE id=?1", [retired.id]) == [["open"]]
    assert bracket_state(ctx.db, retired.id) == generation_state_before_refusal

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(txn, "holder", "h2", "user:h2")
      end)

    assert bracket_state(ctx.db, retired.id) == "canceled"
  end

  test "priority inherits from the work item, scales the four-hour window, and reprioritizes live probes",
       ctx do
    config = Map.put(ctx.config, :effort_checkin_horizon_ms, 14_400_000)
    ctx = %{ctx | config: config}

    horizons =
      for {priority, expected} <- [{3, 28_800_000}, {4, 14_400_000}, {5, 7_200_000}],
          into: %{} do
        item =
          WorkItems.__handle__(ctx.db, "work-item-create", %{
            verb: "work-item-create",
            origin: "user:h1",
            principal: {:user, "h1"},
            session_key: nil,
            params: %{title: "priority #{priority}", priority: priority}
          })

        assignment =
          dispatch_for_item(ctx, {:session, "parent"}, "holder", "priority #{priority}", item.id)

        assert assignment.priority == priority

        assert [[^priority]] =
                 rows(
                   ctx.db,
                   "SELECT priority FROM assignment_priorities WHERE assignmentId=?1",
                   [
                     assignment.id
                   ]
                 )

        assert [[^expected, ^expected]] =
                 rows(
                   ctx.db,
                   """
                   SELECT g.baseHorizonMs,w.dueAt-g.armedAt
                   FROM effort_checkin_generations AS g
                   JOIN wakes AS w ON w.wakeId=g.wakeId
                   WHERE g.assignmentId=?1 AND g.state='armed'
                   """,
                   [assignment.id]
                 )

        {priority, {item, assignment}}
      end

    {item, assignment} = horizons[4]

    updated =
      Gateway.handlers(ctx.config)["work-item-update"].(%{
        verb: "work-item-update",
        origin: "agent:holder",
        principal: {:session, "holder"},
        session_key: "holder",
        params: %{work_item_id: item.id, priority: 6}
      })

    assert updated.priority == 6

    assert [[6, 3_600_000, 3_600_000]] =
             rows(
               ctx.db,
               """
               SELECT ap.priority,g.baseHorizonMs,w.dueAt-g.armedAt
               FROM assignment_priorities AS ap
               JOIN effort_checkin_generations AS g ON g.assignmentId=ap.assignmentId
               JOIN wakes AS w ON w.wakeId=g.wakeId
               WHERE ap.assignmentId=?1 AND g.state='armed'
               """,
               [assignment.id]
             )

    closed_item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:h1",
        principal: {:user, "h1"},
        session_key: nil,
        params: %{title: "closed priority", priority: 4}
      })

    closed =
      dispatch_for_item(
        ctx,
        {:session, "parent"},
        "holder",
        "closed priority",
        closed_item.id
      )

    assignment(ctx, "attest", {:session, "holder"}, nil, %{
      assignment_id: closed.id,
      kind: "completion"
    })

    assert bracket_state(ctx.db, closed.id) == "canceled"

    assert %{priority: 6} =
             Gateway.handlers(ctx.config)["work-item-update"].(%{
               verb: "work-item-update",
               origin: "agent:holder",
               principal: {:session, "holder"},
               session_key: "holder",
               params: %{work_item_id: closed_item.id, priority: 6}
             })

    assert [[6]] =
             rows(
               ctx.db,
               "SELECT priority FROM assignment_priorities WHERE assignmentId=?1",
               [closed.id]
             )

    reopened =
      assignment(ctx, "reopen-assignment", {:session, "parent"}, nil, %{
        assignment_id: closed.id,
        reason: "the card carries work again"
      })

    assert reopened.state == "open"

    assert [[2, "armed", 3_600_000, 3_600_000]] =
             rows(
               ctx.db,
               """
               SELECT g.generation,g.state,g.baseHorizonMs,w.dueAt-g.armedAt
               FROM effort_checkin_generations AS g
               JOIN wakes AS w ON w.wakeId=g.wakeId
               WHERE g.assignmentId=?1
               ORDER BY g.generation DESC LIMIT 1
               """,
               [closed.id]
             )
  end

  test "a standing work-blocked fact suppresses the check and an ineligible icebox cancels it",
       ctx do
    blocked = dispatch(ctx, {:session, "parent"}, "holder", "blocked")

    {:ok, %{kind: "work-blocked"}} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "work-blocked",
          scope: "holder",
          origin: "agent:holder"
        })
      end)

    assert nil == fire_probe(ctx, blocked.id)
    assert silent_rearm(ctx.db, blocked.id)
    assert prods(ctx.db, "holder") == []

    item = work_item!(ctx.db, "legacy icebox")
    legacy = dispatch_for_item(ctx, {:session, "parent"}, "holder", "legacy icebox", item.id)
    :ok = DB.execute(ctx.db, "UPDATE work_items SET state='iceboxed' WHERE id='#{item.id}'")
    wake = current_wake(ctx.db, legacy.id)

    assert nil == fire_probe(ctx, legacy.id)
    assert bracket_state(ctx.db, legacy.id) == "canceled"
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
    assert prods(ctx.db, "holder") == []
  end

  test "acceptance 4 and 5: workspace writes are not activity; a stall is not effect",
       ctx do
    # Filesystem activity is not one of the four authorized card activities.
    # A write therefore cannot hide an otherwise inactive card.
    modified = dispatch(ctx, {:session, "parent"}, "holder", "workspace-only activity")
    File.write!(Path.join(ctx.root, "src/tracked.txt"), "changed\n")
    assert nil == fire_probe(ctx, modified.id)
    assert [prod] = Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == modified.id))
    assert prod.prompt =~ "no artifacts, attests, or work-item updates"
    refute prod.prompt =~ "writes"
    refute prod.prompt =~ "workspace"

    File.write!(Path.join(ctx.root, "created.tmp"), "more workspace activity")
    assert nil == fire_probe(ctx, modified.id)
    assert [%{session_key: "parent"}] = escalation_wakes(ctx.db, modified.id)

    # A stall is turns without effect: turns are reported, never counted.
    stalled = dispatch(ctx, {:session, "parent"}, "holder", "stall")
    wake = current_wake(ctx.db, stalled.id)

    for terminal <- ~w(delivered failed failed_unknown canceled) do
      terminal_turn(ctx.db, "holder", terminal)
    end

    queued_turn(ctx.db, "holder")
    assert nil == fire_probe(ctx, stalled.id)

    assert [stall_prod] = Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == stalled.id))
    assert stall_prod.prompt =~ "3 turns taken"

    fire_probe(ctx, stalled.id)
    assert [parent_escalation] = escalation_wakes(ctx.db, stalled.id)
    assert parent_escalation.session_key == "parent"
    assert parent_escalation.prompt =~ "no artifacts, attests, or work-item updates"

    # A replayed probe of an already-probed generation is inert.
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, wake)

    assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [
             stalled.id
           ]) == [[0]]
  end

  test "proof 4: internal wakes create no turn and stay out of pending/inspection", ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "internal")
    wake = current_wake(ctx.db, item.id)

    before =
      rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE sessionKey='holder'", []) |> hd() |> hd()

    assert Wakes.pending_count(ctx.db, "holder") == 0
    refute Enum.any?(Wakes.list_pending(ctx.db), &(&1.wake_id == wake.wake_id))

    EffortCheckin.probe(ctx.db, ctx.config, wake)

    after_count =
      rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE sessionKey='holder'", []) |> hd() |> hd()

    assert after_count == before
  end

  test "job-linked holder and parent notifications stamp assignment and job", ctx do
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

    assert %{session_key: "parent"} = escalate(ctx, assignment.id)
    assert nil == fire_probe(ctx, assignment.id)

    # `assignmentId` on each prompt wake carries the work attribution through
    # the holder prod, the immediate parent, and terminal Main.
    assert [assignment.id, assignment.id, assignment.id] ==
             Enum.map(notification_wakes(ctx.db), & &1.assignment_id)

    assert Enum.map(escalation_wakes(ctx.db, assignment.id), & &1.session_key) == [
             "parent",
             ctx.main.session_key
           ]

    assert no_effort_requests?(ctx.db, assignment.id)

    drain_notifications!(ctx)

    # Delivery derives the SAME attribution through `wake_attribution/2` — for
    # the agent prod and both operational-parent rungs.
    assert Enum.map(notification_wakes(ctx.db), fn wake ->
             [attribution] =
               rows(ctx.db, "SELECT assignmentId,jobRef FROM turns WHERE wakeId=?1", [
                 wake.wake_id
               ])

             attribution
           end) == [
             [assignment.id, item.id],
             [assignment.id, item.id],
             [assignment.id, item.id]
           ]
  end

  test "dispatch replay precedes current holder placement and performs no new probe", ctx do
    calls = :counters.new(1, [])

    # The REAL mechanism runs; only the counting is injected. A fake that
    # replaced the probe would prove the replay path calls something once, not
    # that it observes once.
    config =
      Map.put(ctx.config, :sh, fn invocation ->
        if String.contains?(Enum.join(invocation, " "), "priorState="),
          do: :counters.add(calls, 1, 1)

        System.cmd(hd(invocation), tl(invocation), stderr_to_stdout: true)
      end)

    params = %{
      subject: "idempotent dispatch",
      brief: "idempotent dispatch",
      idempotency_key: "effort-idempotency"
    }

    first =
      assignment(%{ctx | config: config}, "dispatch", {:session, "parent"}, "holder", params)

    :ok = DB.execute(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='holder'")

    replay =
      assignment(%{ctx | config: config}, "dispatch", {:session, "parent"}, "holder", params)

    assert replay.id == first.id
    assert :counters.get(calls, 1) == 1
  end

  test "proof 8: holder-wide workspace activity cannot suppress card inactivity", ctx do
    assignments =
      for index <- 1..3 do
        dispatch(ctx, {:session, "parent"}, "holder", "busy #{index}")
      end

    for horizon <- 1..3 do
      File.write!(Path.join(ctx.root, "src/tracked.txt"), "busy horizon #{horizon}\n")
      Enum.each(assignments, &fire_probe(ctx, &1.id))
    end

    assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE kind='effort'", []) == [
             [0]
           ]

    assert rows(ctx.db, "SELECT COUNT(*) FROM condition_facts", []) == [[0]]

    assert Enum.sort(Enum.map(prods(ctx.db, "holder"), & &1.assignment_id)) ==
             Enum.sort(Enum.map(assignments, & &1.id))
  end

  test "proofs 5 and 8b: effect resets the parent rung and Main terminates escalation", ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "parent ladder")

    assert %{session_key: "parent"} = escalate(ctx, item.id)

    assert [[3, 1, "armed", 2]] =
             rows(
               ctx.db,
               "SELECT generation,multiplier,state,agentProdded FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation DESC LIMIT 1",
               [item.id]
             )

    # An assignment-local attest resets the streak, including its parent-ladder position.
    assignment(ctx, "attest", {:session, "holder"}, nil, %{
      assignment_id: item.id,
      kind: "progress",
      note: "material assignment progress"
    })

    assert nil == fire_probe(ctx, item.id)
    assert silent_rearm(ctx.db, item.id, 4)

    assert %{session_key: "parent"} = escalate(ctx, item.id)
    assert nil == fire_probe(ctx, item.id)

    assert Enum.map(escalation_wakes(ctx.db, item.id), & &1.session_key) == [
             "parent",
             "parent",
             ctx.main.session_key
           ]

    assert bracket_state(ctx.db, item.id) == "probed"
    assert no_effort_requests?(ctx.db, item.id)

    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{assignment_id: item.id})
    assert bracket_state(ctx.db, item.id) == "canceled"
  end

  test "Main-held inactivity terminates after the holder prod without climbing its self-parent",
       ctx do
    main_root = Placement.workdir_path(ctx.config, ctx.main)
    init_workspace(main_root)

    item = dispatch(ctx, {:user, "h1"}, ctx.main.session_key, "Main-held assignment")
    fire_probe(ctx, item.id)
    fire_probe(ctx, item.id)

    assert escalation_wakes(ctx.db, item.id) == []
    assert bracket_state(ctx.db, item.id) == "probed"
    assert no_effort_requests?(ctx.db, item.id)
  end

  test "reparenting during a silent streak wakes each live effective parent before Main", ctx do
    new_parent = session(ctx.db, "new-parent", "h1", Placement.local_host_name())

    item = dispatch(ctx, {:user, "h1"}, "holder", "live reparent")
    assert %{session_key: "parent"} = escalate(ctx, item.id)

    Org.set_operational_parent(ctx.db, "holder", new_parent.session_key)

    assert %{session_key: "new-parent"} = fire_parent_probe(ctx, item.id)
    assert %{session_key: main_key} = fire_parent_probe(ctx, item.id)
    assert main_key == ctx.main.session_key

    assert Enum.map(escalation_wakes(ctx.db, item.id), & &1.session_key) == [
             "parent",
             "new-parent",
             ctx.main.session_key
           ]

    assert bracket_state(ctx.db, item.id) == "probed"
    assert no_effort_requests?(ctx.db, item.id)
  end

  test "proofs 6, 11, 12, 13: escalation follows operational parents and terminates at Main",
       ctx do
    mid =
      session(ctx.db, "mid", "h1", Placement.local_host_name(), %{
        spawned_by: ctx.main.session_key
      })

    Org.set_operational_parent(ctx.db, mid.session_key, "parent")

    assert %{spawned_by: "parent"} = Org.set_operational_parent(ctx.db, "holder", mid.session_key)

    item = dispatch(ctx, {:user, "h1"}, "holder", "operational ladder")
    assert %{session_key: "mid"} = escalate(ctx, item.id)
    assert nil == fire_probe(ctx, item.id)
    assert nil == fire_probe(ctx, item.id)

    assert Enum.map(escalation_wakes(ctx.db, item.id), & &1.session_key) == [
             "mid",
             "parent",
             ctx.main.session_key
           ]

    assert no_effort_requests?(ctx.db, item.id)
    assert bracket_state(ctx.db, item.id) == "probed"

    # Retired sessions stay in the parent graph but are skipped as escalation targets.
    retired =
      session(ctx.db, "retired-parent", "h1", Placement.local_host_name(), %{
        spawned_by: ctx.main.session_key
      })

    Org.set_operational_parent(ctx.db, retired.session_key, "parent")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        retired.session_key
      ])

    Org.set_operational_parent(ctx.db, "holder", retired.session_key)

    skipped = dispatch(ctx, {:session, retired.session_key}, "holder", "retired rung")
    assert %{session_key: "parent"} = escalate(ctx, skipped.id)
    assert Enum.map(escalation_wakes(ctx.db, skipped.id), & &1.session_key) == ["parent"]
    assert no_effort_requests?(ctx.db, skipped.id)
  end

  test "proof 7: placement satellite probe is bounded and SSH failure is unobservable", ctx do
    satellite = %{ctx.holder | host: "satellite"}

    register_hosts(ctx.db, %{
      "satellite" => %{ssh: "satellite.example", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    test_pid = self()

    remote_config =
      Map.put(ctx.config, :sh, fn invocation ->
        send(test_pid, {:probe_invocation, invocation})
        {"B\tobserved\t2\n/satellite/work\n/satellite/work/new.txt\n", 0}
      end)

    assert {:ok, %{prior: "observed", writes: 2, entries: 2, digest: digest, stamp: stamp}} =
             Placement.effort_observation(remote_config, satellite, "/satellite/work")

    assert digest =~ ~r/^[0-9a-f]{64}$/
    assert String.contains?(stamp, "/.tightbeam-effort/")

    assert_receive {:probe_invocation,
                    [
                      "ssh",
                      "-o",
                      "BatchMode=yes",
                      "-o",
                      "ConnectTimeout=5",
                      "satellite.example",
                      "sh",
                      "-lc",
                      command
                    ]}

    # The remote command carries no git at all — that is the point of v2.
    refute command =~ "git"

    failed_remote = Map.put(ctx.config, :sh, fn _ -> {"ssh unavailable", 255} end)

    assert {:error, reason} =
             Placement.effort_observation(failed_remote, satellite, "/satellite/work")

    assert reason =~ "ssh unavailable"

    raising_remote = Map.put(ctx.config, :sh, fn _ -> raise "ssh exploded" end)

    assert {:error, raised_reason} =
             Placement.effort_observation(raising_remote, satellite, "/satellite/work")

    assert raised_reason =~ "ssh exploded"

    hung_remote =
      ctx.config
      |> Map.put(:effort_probe_timeout_ms, 20)
      |> Map.put(:sh, fn _ -> receive do: (:never -> {"", 0}) end)

    assert {:error, "probe timed out"} =
             Placement.effort_observation(hung_remote, satellite, "/satellite/work")

    :ok = DB.execute(ctx.db, "UPDATE sessions SET host='satellite' WHERE sessionKey='holder'")
    calls = :counters.new(1, [])

    changing_remote =
      Map.put(ctx.config, :sh, fn _invocation ->
        :counters.add(calls, 1, 1)
        writes = if :counters.get(calls, 1) == 1, do: 0, else: 1
        {"B\tobserved\t#{writes}\n/srv/tightbeam/work\n", 0}
      end)

    item =
      assignment(%{ctx | config: changing_remote}, "dispatch", {:session, "parent"}, "holder", %{
        subject: "remote",
        brief: "remote"
      })

    assert nil == fire_probe(%{ctx | config: changing_remote}, item.id)
    assert [prod] = Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == item.id))
    assert prod.prompt =~ "no artifacts, attests, or work-item updates"

    failed_config = Map.put(ctx.config, :sh, fn _ -> {"ssh unavailable", 255} end)

    failed =
      assignment(%{ctx | config: failed_config}, "dispatch", {:session, "parent"}, "holder", %{
        subject: "remote failure",
        brief: "remote failure"
      })

    escalation = escalate(%{ctx | config: failed_config}, failed.id)
    assert escalation.session_key == "parent"
    assert escalation.prompt =~ "no artifacts, attests, or work-item updates"
    assert no_effort_requests?(ctx.db, failed.id)
  end

  test "acceptance 1: turns without effect prod the agent; one recorded artifact is silence",
       ctx do
    item = work_item!(ctx.db, "acceptance one")

    silent = dispatch_for_item(ctx, {:session, "parent"}, "holder", "turns only", item.id)

    for _ <- 1..2, do: terminal_turn(ctx.db, "holder", "delivered")

    assert nil == fire_probe(ctx, silent.id)

    assert [prod] = prods(ctx.db, "holder")
    assert prod.session_key == "holder"
    assert prod.assignment_id == silent.id
    assert prod.state == "pending"
    assert prod.prompt =~ "no artifacts, attests, or work-item updates"
    assert prod.prompt =~ "artifact-record"
    assert prod.prompt =~ "2 turns taken"
    assert prod.prompt =~ "new material result or evidence"
    assert prod.prompt =~ "exact new blocker or refusal"
    assert prod.prompt =~ "bounded decision request"
    assert prod.prompt =~ "one new, unexpired bounded checkpoint"
    assert prod.prompt =~ "next action or condition and its deadline"
    assert prod.prompt =~ "Do not file generic or duplicate status"
    assert prod.prompt =~ "schedule a concrete continuation wake"
    assert prod.prompt =~ "next action or dependency condition and when to resume"
    refute prod.prompt =~ "or say what is happening"

    assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [
             silent.id
           ]) == [[0]]

    # The identical setup, plus one recorded artifact: the holder took the same
    # turns, wrote nothing in the workdir, and is left alone.
    recorded =
      dispatch_for_item(ctx, {:session, "parent"}, "holder", "turns and an artifact", item.id)

    for _ <- 1..2, do: terminal_turn(ctx.db, "holder", "delivered")
    artifact!(ctx.db, "holder", item.id, "/srv/www/index.html")

    assert nil == fire_probe(ctx, recorded.id)
    assert silent_rearm(ctx.db, recorded.id)
    assert Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == recorded.id)) == []
  end

  test "artifacts count only for the card's work item and unthreaded cards have none", ctx do
    item = work_item!(ctx.db, "artifact scope")
    other_item = work_item!(ctx.db, "unrelated artifact scope")

    scoped = dispatch_for_item(ctx, {:session, "parent"}, "holder", "scoped", item.id)
    artifact!(ctx.db, "holder", other_item.id, "other-card.md")

    assert nil == fire_probe(ctx, scoped.id)

    assert [_prod] =
             Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == scoped.id))

    matching = dispatch_for_item(ctx, {:session, "parent"}, "holder", "matching", item.id)
    artifact!(ctx.db, "holder", item.id, "this-card.md")

    assert nil == fire_probe(ctx, matching.id)
    assert silent_rearm(ctx.db, matching.id)
    assert Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == matching.id)) == []

    unthreaded = assignment(ctx, "assign", {:user, "h1"}, "holder", %{subject: "unthreaded"})
    artifact!(ctx.db, "holder", item.id, "still-threaded.md")

    assert nil == fire_probe(ctx, unthreaded.id)

    assert [_prod] =
             Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == unthreaded.id))
  end

  test "acceptance 1 on the PRODUCTION path: the dispatch's own doorbell is not the holder's work",
       ctx do
    item = work_item!(ctx.db, "production path")
    handlers = Gateway.handlers(ctx.config)

    params = %{subject: "turns only", brief: "turns only", work_item_id: item.id}

    call = %{
      verb: "dispatch",
      origin: "agent:parent",
      principal: {:session, "parent"},
      session_key: "holder",
      target_role: nil,
      role_fallback: false,
      params: params
    }

    assert %{rumination_required: true} = handlers["dispatch"].(call)

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE wakes SET state='fired' WHERE rumination=1 AND work_item_id='#{item.id}'"
      )

    assignment = handlers["dispatch"].(call)

    # The gateway's composition doorbell fired for THIS dispatch — the row the
    # bracket would have read as the holder's work.
    assert [["composition"]] =
             rows(ctx.db, "SELECT kind FROM work_item_events WHERE workItemId=?1", [item.id])

    for _ <- 1..2, do: terminal_turn(ctx.db, "holder", "delivered")

    assert nil == fire_probe(ctx, assignment.id)

    assert [prod] = Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == assignment.id))
    assert prod.prompt =~ "no artifacts, attests, or work-item updates"

    # And a real work-item UPDATE by the holder still counts, on the same path.
    silent = dispatch_for_item(ctx, {:session, "parent"}, "holder", "second bracket", item.id)

    handlers["work-item-update"].(%{
      verb: "work-item-update",
      origin: "agent:holder",
      principal: {:session, "holder"},
      session_key: "holder",
      params: %{work_item_id: item.id, title: "production path, sharpened"}
    })

    assert nil == fire_probe(ctx, silent.id)
    assert silent_rearm(ctx.db, silent.id)
    assert Enum.filter(prods(ctx.db, "holder"), &(&1.assignment_id == silent.id)) == []
  end

  test "an observation never removes the stamp it read", ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "stamp relay")
    armed = generation_stamp(ctx.db, item.id, 1)
    assert File.exists?(armed)

    # Two observers can hold the same armed snapshot — observation runs before
    # the CAS that picks a winner — so a loser removing the stamp the winner's
    # row points at would silently blind the next bracket.
    assert nil == fire_probe(ctx, item.id)
    assert File.exists?(armed)
    assert generation_stamp(ctx.db, item.id, 2) != armed
  end

  test "a broken channel is not a channel that saw nothing", ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "broken substrate")
    :ok = DB.execute(ctx.db, "DROP TABLE artifacts")

    # Reading a missing table as zero would fire a prod off the breakage.
    assert_raise MatchError, fn -> fire_probe(ctx, item.id) end
  end

  test "acceptance 2: an agent working only on another machine is never prodded", ctx do
    item = work_item!(ctx.db, "stand up the web server")

    remote = dispatch_for_item(ctx, {:session, "parent"}, "holder", "remote only", item.id)

    # Nothing is ever written in this workdir: the work is on another machine and
    # every horizon's worth of it is DECLARED, which is all the substrate needs.
    for horizon <- 1..3 do
      artifact!(ctx.db, "holder", item.id, "shrdlu:/etc/nginx/sites-enabled/app.#{horizon}")
      terminal_turn(ctx.db, "holder", "delivered")
      assert nil == fire_probe(ctx, remote.id)
      assert silent_rearm(ctx.db, remote.id, horizon + 1)
    end

    assert prods(ctx.db, "holder") == []

    assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [
             remote.id
           ]) == [[0]]
  end

  test "acceptance 3: silence after the prod escalates to the parent naming all channels",
       ctx do
    item = work_item!(ctx.db, "acceptance three")

    silent = dispatch_for_item(ctx, {:session, "parent"}, "holder", "still silent", item.id)

    assert nil == fire_probe(ctx, silent.id)
    assert [_prod] = prods(ctx.db, "holder")

    assert nil == fire_probe(ctx, silent.id)
    assert [escalation] = escalation_wakes(ctx.db, silent.id)
    assert escalation.session_key == "parent"
    assert escalation.prompt =~ "Child session holder remains inactive"
    assert escalation.prompt =~ "no artifacts, attests, or work-item updates"
    assert no_effort_requests?(ctx.db, silent.id)

    # One prod per silent streak, not one per bracket.
    assert length(prods(ctx.db, "holder")) == 1
  end

  test "acceptance 6: an attest verifies the artifacts the holder recorded, and never rejects",
       ctx do
    register_hosts(ctx.db, %{
      "satellite" => %{ssh: "satellite.example", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    item = work_item!(ctx.db, "referent verification")
    assignment = dispatch_for_item(ctx, {:session, "parent"}, "holder", "build it", item.id)

    # One local artifact that is really there, one that is not, one on another
    # machine, and one naming a machine this org has never heard of.
    File.write!(Path.join(ctx.root, "report.md"), "the thing I claimed")
    artifact!(ctx.db, "holder", item.id, "report.md")
    artifact!(ctx.db, "holder", item.id, "vanished.md")
    artifact!(ctx.db, "holder", item.id, "satellite:/srv/www/index.html")
    artifact!(ctx.db, "holder", item.id, "atlantis:/srv/www/index.html")

    test_pid = self()

    # Only the ssh leg is faked; the local leg runs the real shell against the
    # real filesystem, so present/absent here is a genuine write-detection.
    reachable =
      Map.put(ctx.config, :sh, fn invocation ->
        if Enum.any?(invocation, &(&1 == "satellite.example")) do
          send(test_pid, {:origin_check, invocation})
          {"P\t1700000042\t/srv/www/index.html\n", 0}
        else
          System.cmd(hd(invocation), tl(invocation), stderr_to_stdout: true)
        end
      end)

    %{referents: referents} =
      assignment(%{ctx | config: reachable}, "attest", {:session, "holder"}, nil, %{
        assignment_id: assignment.id,
        kind: "progress",
        note: "wired the vhost up"
      })

    by_origin = Map.new(referents, &{&1.originPath, &1})

    # A stat, not an existence check: the present ones carry the mtime the host
    # reported, which is the write-detection evidence.
    assert by_origin["report.md"].status == "present"
    assert by_origin["report.md"].host == Placement.local_host_name()
    {:ok, %File.Stat{mtime: mtime}} = File.stat(src(ctx, "report.md"), time: :posix)
    assert by_origin["report.md"].mtime == mtime
    assert by_origin["vanished.md"].status == "absent"
    assert by_origin["vanished.md"].mtime == nil

    # The remote one was checked over ssh, on its own host, in one bounded call.
    assert by_origin["satellite:/srv/www/index.html"].status == "present"
    assert by_origin["satellite:/srv/www/index.html"].host == "satellite"
    assert by_origin["satellite:/srv/www/index.html"].mtime == 1_700_000_042

    assert_receive {:origin_check,
                    [
                      "ssh",
                      "-o",
                      "BatchMode=yes",
                      "-o",
                      "ConnectTimeout=5",
                      "satellite.example"
                      | _
                    ]}

    # An origin naming a machine the org does not have says exactly that.
    unknown = by_origin["atlantis:/srv/www/index.html"]
    assert unknown.status == "unverifiable"
    assert unknown.reason =~ "atlantis"
    assert unknown.reason =~ "not a registered host"

    # The attest itself stands: filed, readable, never rejected by any of this.
    assert [%{kind: "progress", note: "wired the vhost up"}] =
             Assignments.__handle__(ctx.db, "attests", %{
               verb: "attests",
               origin: "agent:holder",
               principal: {:session, "holder"},
               params: %{assignment_id: assignment.id}
             }).attests

    # An unreachable host reports the CHECK's failure, and says nothing about
    # the claim or the credential that could not reach it.
    unreachable =
      Map.put(ctx.config, :sh, fn invocation ->
        if Enum.any?(invocation, &(&1 == "satellite.example")),
          do: {"ssh: connect to host satellite.example port 22: Host is down", 255},
          else: System.cmd(hd(invocation), tl(invocation), stderr_to_stdout: true)
      end)

    %{referents: offline} =
      assignment(%{ctx | config: unreachable}, "attest", {:session, "holder"}, nil, %{
        assignment_id: assignment.id,
        kind: "progress",
        note: "still going"
      })

    remote = Enum.find(offline, &(&1.host == "satellite"))
    assert remote.status == "unverifiable"
    assert remote.reason =~ "Host is down"
    refute remote.reason =~ "credential"
    refute remote.reason =~ "claim"
  end

  test "referents are every artifact the holder recorded, as of the moment the claim was filed",
       ctx do
    other_item = work_item!(ctx.db, "some other thread")
    item = work_item!(ctx.db, "this thread")
    assignment = dispatch_for_item(ctx, {:session, "parent"}, "holder", "build it", item.id)

    # Recorded against a DIFFERENT work item: still this holder's work, still a
    # referent. Narrowing by work item would have hidden it.
    File.write!(Path.join(ctx.root, "elsewhere.md"), "recorded under another item")
    artifact!(ctx.db, "holder", other_item.id, "elsewhere.md")

    # Released — external work, out of custody but exactly where it says it is.
    File.write!(Path.join(ctx.root, "released.md"), "released")
    released = artifact!(ctx.db, "holder", item.id, "released.md")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE artifacts SET state='released' WHERE artifactId=?1", [
        released.artifact_id
      ])

    # Archived — archival moved these bytes into `home` itself, so originPath is
    # knowingly stale and stat-ing it would manufacture an absence we caused.
    archived = artifact!(ctx.db, "holder", item.id, "archived.md")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE artifacts SET state='archived', home='/archive/archived.md' WHERE artifactId=?1",
        [archived.artifact_id]
      )

    %{referents: referents} =
      assignment(ctx, "attest", {:session, "holder"}, nil, %{
        assignment_id: assignment.id,
        kind: "progress",
        note: "checkpoint"
      })

    origins = Enum.map(referents, & &1.originPath)
    assert "elsewhere.md" in origins
    assert "released.md" in origins
    refute "archived.md" in origins

    # An artifact recorded AFTER the claim was filed is not something the claim
    # pointed at.
    artifact!(ctx.db, "holder", item.id, "later.md")
    assert Enum.map(referents, & &1.originPath) == origins
  end

  test "an attest, and a work-item update, are each effect on their own", ctx do
    item = work_item!(ctx.db, "channel coverage")

    attested = dispatch_for_item(ctx, {:session, "parent"}, "holder", "attest only", item.id)

    assignment(ctx, "attest", {:session, "holder"}, nil, %{
      assignment_id: attested.id,
      kind: "progress",
      note: "root-caused it, still working"
    })

    assert nil == fire_probe(ctx, attested.id)
    assert silent_rearm(ctx.db, attested.id)
    assert prods(ctx.db, "holder") == []

    updated =
      dispatch_for_item(ctx, {:session, "parent"}, "holder", "work-item update only", item.id)

    # Through the gateway handler, which is what wires the work_item_events
    # doorbell the channel reads.
    Gateway.handlers(ctx.config)["work-item-update"].(%{
      verb: "work-item-update",
      origin: "agent:holder",
      principal: {:session, "holder"},
      session_key: "holder",
      params: %{work_item_id: item.id, title: "channel coverage, sharpened"}
    })

    assert nil == fire_probe(ctx, updated.id)
    assert silent_rearm(ctx.db, updated.id)
    assert prods(ctx.db, "holder") == []
  end

  test "proofs 6 and 8b: parent notification and next rung commit before delivery", ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "notify durability")

    first_probe = current_wake(ctx.db, item.id)
    assert nil == fire_probe(ctx, item.id)

    assert %{session_key: "parent", state: "pending", target_gate: 1} =
             parent_wake = fire_parent_probe(ctx, item.id)

    assert [[3, "armed", next_probe_id, 2]] =
             rows(
               ctx.db,
               "SELECT generation,state,wakeId,agentProdded FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation DESC LIMIT 1",
               [item.id]
             )

    assert Wakes.get(ctx.db, next_probe_id).state == "pending"

    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [parent_wake.wake_id]) == [
             [0]
           ]

    assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.wake_id == parent_wake.wake_id))
    assert no_effort_requests?(ctx.db, item.id)

    # Ordinary wake recovery surfaces it without waiting for the deadline.
    scheduler = drain_notifications!(ctx)
    assert Wakes.get(ctx.db, parent_wake.wake_id).state == "fired"

    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [parent_wake.wake_id]) == [
             [1]
           ]

    # The scheduler also fires the already-due next internal probe. It reaches
    # Main, which closes the ladder without another monitor.
    assert [%{session_key: "parent"}, %{session_key: main_key}] =
             escalation_wakes(ctx.db, item.id)

    assert main_key == ctx.main.session_key
    assert bracket_state(ctx.db, item.id) == "probed"

    # A stale probe replay stays inert and cannot produce another escalation.
    before_replay = Enum.map(escalation_wakes(ctx.db, item.id), & &1.wake_id)
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, first_probe)
    assert Enum.map(escalation_wakes(ctx.db, item.id), & &1.wake_id) == before_replay
    assert no_effort_requests?(ctx.db, item.id)
    assert :ok = Wakes.fire_due(scheduler)
  end

  test "proof 10: workspace motion supersedes old evidence and re-arms on the new holder/host",
       ctx do
    bare = assignment(ctx, "assign", {:user, "h1"}, "holder", %{subject: "bare motion"})
    item = dispatch(ctx, {:session, "parent"}, "holder", "motion")
    assert nil == fire_probe(ctx, item.id)
    old_probe = current_wake(ctx.db, item.id)

    manifests = Path.join([ctx.base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(
      Path.join(manifests, "default.toml"),
      """
      name = "default"
      where = ["#{Placement.local_host_name()}", "satellite"]
      """
    )

    Archetypes.load!(ctx.base_dir)
    on_exit(fn -> :persistent_term.erase(Archetypes) end)

    register_hosts(ctx.db, %{
      "satellite" => %{ssh: "satellite.example", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    test_pid = self()
    race = :counters.new(1, [])

    sh = fn invocation ->
      if String.contains?(Enum.join(invocation, " "), "priorState=") do
        :counters.add(race, 1, 1)

        if :counters.get(race, 1) == 1 do
          raced = dispatch(ctx, {:session, "parent"}, "holder", "concurrent motion dispatch")
          send(test_pid, {:raced_assignment, raced.id})
        end

        {"B\tobserved\t0\n/srv/tightbeam/work\n", 0}
      else
        {"", 0}
      end
    end

    moved_config = Map.put(ctx.config, :sh, sh)
    tune = Gateway.handlers(moved_config)["tune"]

    assert %{ok: true, host: "satellite"} =
             tune.(%{
               origin: "user:h2",
               principal: {:user, "h2"},
               session_key: "holder",
               params: %{setting: "set_host", host: "satellite"}
             })

    assert_receive {:raced_assignment, raced_assignment_id}

    assert bracket_state(ctx.db, item.id) == "armed"

    replacement_wake = current_wake(ctx.db, item.id)

    assert %{
             requester: "tightbeam:effort-checkin",
             reason: "superseded",
             outcome: "replacement",
             replacement_wake_id: replacement_wake_id
           } = cancellation(ctx.db, old_probe.wake_id)

    assert replacement_wake_id == replacement_wake.wake_id

    assert [[2, "satellite"]] =
             rows(
               ctx.db,
               "SELECT generation,host FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [bare.id]
             )

    assert [[host, root]] =
             rows(
               ctx.db,
               "SELECT host,root FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [item.id]
             )

    assert host == "satellite"
    assert String.starts_with?(root, "/srv/tightbeam/work/")

    assert [["satellite"]] =
             rows(
               ctx.db,
               "SELECT host FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [raced_assignment_id]
             )

    assert %{session_key: "parent"} = escalate(%{ctx | config: moved_config}, item.id)
    assert no_effort_requests?(ctx.db, item.id)

    replacement = session(ctx.db, "replacement", "h2", Placement.local_host_name())
    Org.set_operational_parent(ctx.db, replacement.session_key, "parent")

    prepared =
      EffortCheckin.prepare_transferred_rearms(
        ctx.db,
        ctx.config,
        replacement,
        [item.id, bare.id]
      )

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Tightbeam.DB.Txn.q(
          txn,
          "UPDATE assignments SET holderKey='replacement' WHERE id IN (?1, ?2)",
          [item.id, bare.id]
        )

        EffortCheckin.apply_prepared_rearms_in_txn(
          txn,
          ctx.config,
          replacement.session_key,
          prepared
        )
      end)

    replacement_key = replacement.session_key

    assert [[^replacement_key]] =
             rows(
               ctx.db,
               "SELECT holderKey FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [item.id]
             )

    assert [[3, ^replacement_key]] =
             rows(
               ctx.db,
               "SELECT generation,holderKey FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [bare.id]
             )
  end

  test "A-05: a dismiss snapshot change refuses stale and a fresh retry rules once", ctx do
    observer = session(ctx.db, "dismiss-observer", "h1", Placement.local_host_name())
    target = dispatch(ctx, {:session, "parent"}, "holder", "dismiss target")
    moving = dispatch(ctx, {:session, "parent"}, "holder", "concurrent holder motion")
    request_id = open_effort_request(ctx, target, "parent")
    raced = :atomics.new(1, [])

    race_config =
      Map.put(ctx.config, :sh, fn invocation ->
        if :atomics.compare_exchange(raced, 1, 0, 1) == :ok do
          prepared =
            EffortCheckin.prepare_transferred_rearms(
              ctx.db,
              ctx.config,
              ctx.holder,
              [moving.id]
            )

          assert {:ok, :ok} =
                   DB.transaction(ctx.db, fn txn ->
                     EffortCheckin.apply_prepared_rearms_in_txn(
                       txn,
                       ctx.config,
                       ctx.holder.session_key,
                       prepared
                     )
                   end)
        end

        System.cmd(hd(invocation), tl(invocation), stderr_to_stdout: true)
      end)

    call = effort_rule_call(observer.session_key, request_id, "dismiss")

    assert %{code: "stale_effort_snapshot"} = EffortCheckin.rule(ctx.db, race_config, call)
    assert [["open", nil, nil]] = request_ruling(ctx.db, request_id)

    assert %{status: "ruled", decision: "dismiss", ruled_by: ruled_by} =
             EffortCheckin.rule(ctx.db, ctx.config, call)

    assert ruled_by == "session:#{observer.session_key}"
    assert [["ruled", "dismiss", ^ruled_by]] = request_ruling(ctx.db, request_id)

    assert rows(
             ctx.db,
             "SELECT COUNT(*) FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject=?1",
             [request_id]
           ) == [[0]]
  end

  test "A-10: deadline and distinct-session rulings preserve one winner in both orders", ctx do
    continuing = session(ctx.db, "continue-observer", "h1", Placement.local_host_name())
    dismissing = session(ctx.db, "dismiss-observer-two", "h1", Placement.local_host_name())

    ruling_first = dispatch(ctx, {:session, "parent"}, "holder", "ruling wins first")
    continue_id = open_effort_request(ctx, ruling_first, "parent")
    continue_deadline = request_deadline_wake(ctx.db, continue_id)
    before_continue = generation_count(ctx.db, ruling_first.id)

    assert %{status: "ruled", decision: "continue", ruled_by: continue_actor} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_rule_call(continuing.session_key, continue_id, "continue")
             )

    assert continue_actor == "session:#{continuing.session_key}"
    assert :ok = EffortCheckin.deadline(ctx.db, ctx.config, continue_deadline)
    assert generation_count(ctx.db, ruling_first.id) == before_continue + 1
    assert [["ruled", "continue", ^continue_actor]] = request_ruling(ctx.db, continue_id)
    assert Wakes.get(ctx.db, continue_deadline.wake_id).state == "canceled"

    deadline_first = dispatch(ctx, {:session, "parent"}, "holder", "deadline wins first")
    dismiss_id = open_effort_request(ctx, deadline_first, "parent")
    first_deadline = request_deadline_wake(ctx.db, dismiss_id)
    before_dismiss = generation_count(ctx.db, deadline_first.id)

    assert :ok = EffortCheckin.deadline(ctx.db, ctx.config, first_deadline)

    assert [["open", nil, nil, replacement_wake_id]] =
             rows(
               ctx.db,
               "SELECT status,decision,ruledBy,deadlineWakeId FROM decision_requests WHERE id=?1",
               [dismiss_id]
             )

    refute replacement_wake_id == first_deadline.wake_id
    assert Wakes.get(ctx.db, first_deadline.wake_id).state == "fired"

    assert %{status: "ruled", decision: "dismiss", ruled_by: dismiss_actor} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_rule_call(dismissing.session_key, dismiss_id, "dismiss")
             )

    assert dismiss_actor == "session:#{dismissing.session_key}"
    assert generation_count(ctx.db, deadline_first.id) == before_dismiss + 1
    assert [["ruled", "dismiss", ^dismiss_actor]] = request_ruling(ctx.db, dismiss_id)
    assert Wakes.get(ctx.db, replacement_wake_id).state == "canceled"

    for request_id <- [continue_id, dismiss_id] do
      assert rows(
               ctx.db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject=?1",
               [request_id]
             ) == [[0]]
    end
  end

  defp dispatch(ctx, principal, holder, subject) do
    assignment(ctx, "dispatch", principal, holder, %{subject: subject, brief: subject})
  end

  # A session's FIRST dispatch against a work item is sent to ruminate; the
  # re-issue is the dispatch. These proofs are about the bracket, not that rung.
  defp dispatch_for_item(ctx, principal, holder, subject, work_item_id) do
    params = %{subject: subject, brief: subject, work_item_id: work_item_id}

    case assignment(ctx, "dispatch", principal, holder, params) do
      %{rumination_required: true} ->
        :ok =
          DB.execute(
            ctx.db,
            "UPDATE wakes SET state='fired' WHERE rumination=1 AND work_item_id='#{work_item_id}'"
          )

        assignment(ctx, "dispatch", principal, holder, params)

      result ->
        result
    end
  end

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
    wake = current_wake(ctx.db, assignment_id)
    :ok = EffortCheckin.probe(ctx.db, ctx.config, wake)
    nil
  end

  defp fire_parent_probe(ctx, assignment_id) do
    before = Enum.map(escalation_wakes(ctx.db, assignment_id), & &1.wake_id)
    fire_probe(ctx, assignment_id)

    case Enum.reject(escalation_wakes(ctx.db, assignment_id), &(&1.wake_id in before)) do
      [wake] -> wake
      other -> flunk("expected one new operational-parent wake, got: #{inspect(other)}")
    end
  end

  # Zero effect prods the holder first; the next bracket wakes its operational parent.
  defp escalate(ctx, assignment_id) do
    fire_probe(ctx, assignment_id)
    fire_parent_probe(ctx, assignment_id)
  end

  defp escalation_wakes(db, assignment_id) do
    db
    |> rows(
      "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND prompt LIKE '[effort escalation]%' ORDER BY rowid",
      [assignment_id]
    )
    |> Enum.map(fn [wake_id] -> Wakes.get(db, wake_id) end)
  end

  defp no_effort_requests?(db, assignment_id),
    do:
      rows(db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [assignment_id]) ==
        [[0]]

  defp open_effort_request(ctx, assignment, expecter_session_key) do
    [[generation]] =
      rows(
        ctx.db,
        "SELECT MAX(generation) FROM effort_checkin_generations WHERE assignmentId=?1",
        [assignment.id]
      )

    deadline =
      Wakes.schedule(ctx.db, %{
        session_key: expecter_session_key,
        origin: "process:tightbeam",
        consumer: "effort_deadline",
        due_at: System.system_time(:millisecond) + 60_000,
        assignment_id: assignment.id
      })

    request_id = "dr_effort_#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,ownerUserId,assignmentId,expecterSessionKey,lineageRung,
                  effortGeneration,deadlineWakeId,raisedAt,deadlineAt,question,options,context,status)
               VALUES (?1,'effort','process:tightbeam','h1',?2,?3,1,?4,?5,?6,?7,
                       'Continue or dismiss?','["continue","dismiss"]',
                       '{"actions":["continue","dismiss"]}','open')
               """,
               [
                 request_id,
                 assignment.id,
                 expecter_session_key,
                 generation,
                 deadline.wake_id,
                 now,
                 now + 60_000
               ]
             )

    request_id
  end

  defp effort_rule_call(session_key, request_id, action) do
    %{
      verb: "effort-rule",
      origin: "agent:caller-supplied-alias",
      principal: {:session, session_key},
      session_key: nil,
      params: %{request: request_id, action: action}
    }
  end

  defp request_deadline_wake(db, request_id) do
    [[wake_id]] =
      rows(db, "SELECT deadlineWakeId FROM decision_requests WHERE id=?1", [request_id])

    Wakes.get(db, wake_id)
  end

  defp request_ruling(db, request_id) do
    rows(db, "SELECT status,decision,ruledBy FROM decision_requests WHERE id=?1", [request_id])
  end

  defp generation_count(db, assignment_id) do
    [[count]] =
      rows(db, "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1", [
        assignment_id
      ])

    count
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

  defp silent_rearm(db, assignment_id, generation \\ 2) do
    rows(db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [assignment_id]) == [
      [0]
    ] and
      rows(
        db,
        "SELECT generation,multiplier,state,agentProdded FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      ) == [[generation, 1, "armed", 0]]
  end

  defp bracket_state(db, assignment_id) do
    [[state]] =
      rows(
        db,
        "SELECT state FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      )

    state
  end

  defp rows(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp cancellation(db, wake_id) do
    [
      [
        requester,
        reason,
        source_kind,
        source_id,
        outcome,
        replacement_wake_id,
        disposition_kind,
        disposition_id,
        liveness_kind,
        liveness_id,
        action_needed
      ]
    ] =
      rows(
        db,
        """
        SELECT requesterId,reasonKind,causalSourceKind,causalSourceId,outcomeKind,
               replacementWakeId,dispositionKind,dispositionId,livenessTriggerKind,
               livenessTriggerId,actionNeeded
        FROM wake_cancellations WHERE wakeId=?1
        """,
        [wake_id]
      )

    %{
      requester: requester,
      reason: reason,
      source_kind: source_kind,
      source_id: source_id,
      outcome: outcome,
      replacement_wake_id: replacement_wake_id,
      disposition_kind: disposition_kind,
      disposition_id: disposition_id,
      liveness_kind: liveness_kind,
      liveness_id: liveness_id,
      action_needed: action_needed
    }
  end

  # Effort notifications are ordinary prompt wakes with assignment attribution.
  defp notification_wakes(db) do
    db
    |> rows(
      "SELECT wakeId FROM wakes WHERE assignmentId IS NOT NULL AND prompt LIKE '[effort %' ORDER BY rowid",
      []
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

  defp session(db, key, owner, host, overrides \\ %{}) do
    overrides =
      if Map.has_key?(overrides, :spawned_by) and not Map.has_key?(overrides, :operational_parent),
        do: Map.put(overrides, :operational_parent, overrides.spawned_by),
        else: overrides

    Org.create(
      db,
      Map.merge(
        %{
          session_key: key,
          display_name: key,
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

  defp src(ctx, relative), do: Path.join(ctx.root, relative)

  defp generation_stamp(db, assignment_id, generation) do
    [[baseline]] =
      rows(
        db,
        "SELECT baseline FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=?2",
        [assignment_id, generation]
      )

    JSON.decode!(baseline)["observation"]["stamp"]
  end

  # The prod is a wake to the HOLDER; the owner request's notification is a wake
  # to the expecter. Only the holder's carries the check-in text.
  defp prods(db, session_key) do
    db
    |> rows(
      "SELECT wakeId FROM wakes WHERE sessionKey = ?1 AND prompt LIKE '[effort check-in]%' ORDER BY rowid",
      [session_key]
    )
    |> Enum.map(fn [wake_id] -> Wakes.get(db, wake_id) end)
  end

  defp artifact!(db, session_key, work_item_id, path) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO messages (id, sessionKey, role, content, timestamp, llmVisibleMessageId)
        VALUES (?1, ?2, 'assistant', 'artifact-record', 1, ?1)
        """,
        ["msg_#{System.unique_integer([:positive])}_#{session_key}", session_key]
      )

    [[message_id]] =
      rows(
        db,
        "SELECT id FROM messages WHERE sessionKey = ?1 ORDER BY rowid DESC LIMIT 1",
        [session_key]
      )

    row =
      Artifacts.record(db, %{
        principal: {:session, session_key},
        session_key: session_key,
        recorded_message_id: message_id,
        params: %{
          kind: "report",
          title: "Remote work",
          origin_path: path,
          work_item_id: work_item_id
        }
      })

    row
  end

  defp work_item!(db, title) do
    WorkItems.__handle__(db, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:h1",
      principal: {:user, "h1"},
      session_key: nil,
      params: %{title: title}
    })
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, user}), do: "user:#{user}"

  defp queued_turn(db, session_key) do
    id = "m_#{System.unique_integer([:positive])}"

    {:ok, _seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: id,
        origin: "agent:test",
        prompt: id
      })
  end

  defp terminal_turn(db, session_key, terminal) do
    id = "m_#{System.unique_integer([:positive])}"

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: id,
        origin: "agent:test",
        prompt: id
      })

    lease = "ol_test_#{System.unique_integer([:positive])}"

    {:ok, :appended} =
      DB.transaction(db, fn txn ->
        DB.Txn.q(
          txn,
          "UPDATE turns SET status='running', startedAt=?2, owner='test' WHERE seq=?1 AND status='queued'",
          [seq, System.system_time(:millisecond)]
        )

        Tightbeam.TurnLifecycle.append_in_txn(txn, seq, %{
          event_key: "claimed",
          producer_event_id: "effort-checkin-fixture:claimed",
          kind: "claimed",
          cause: "test-fixture:claim",
          principal: "process:tightbeam",
          owner_lease: lease,
          detail: %{v: 1, owner: "test"}
        })
      end)

    :ok = Ledger.finish(db, seq, terminal, nil, owner_lease: lease)
  end
end
