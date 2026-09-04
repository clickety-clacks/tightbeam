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
    holder = session(db, "holder", "h1", host, %{spawned_by: "parent"})
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

    for kind <- ["completion"] do
      item = dispatch(ctx, {:session, "parent"}, "holder", kind)
      assignment(ctx, "attest", {:session, "holder"}, nil, %{assignment_id: item.id, kind: kind})
      assert bracket_state(ctx.db, item.id) == "canceled"

      assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [
               item.id
             ]) == [[0]]
    end

    blocked = dispatch(ctx, {:session, "parent"}, "holder", "cannot-proceed")

    assignment(ctx, "attest", {:session, "holder"}, nil, %{
      assignment_id: blocked.id,
      kind: "cannot-proceed",
      note: "needs the parent"
    })

    assert bracket_state(ctx.db, blocked.id) == "armed"

    revoked = dispatch(ctx, {:session, "parent"}, "holder", "revoked")

    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{
      assignment_id: revoked.id,
      reason: "test revocation"
    })

    assert bracket_state(ctx.db, revoked.id) == "canceled"

    retired = dispatch(ctx, {:session, "parent"}, "holder", "retired")
    fire_probe(ctx, retired.id)
    generation_state_before_refusal = bracket_state(ctx.db, retired.id)

    assert generation_state_before_refusal == "armed"

    assert {:error,
            %ArgumentError{message: "retirement interruption requires a durable principal"}} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.interrupt_for_retire_in_txn(txn, "holder", "h1", nil)
             end)

    assert rows(ctx.db, "SELECT state FROM assignments WHERE id=?1", [retired.id]) == [["open"]]
    assert bracket_state(ctx.db, retired.id) == generation_state_before_refusal

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(txn, "holder", "h1", "user:h1")
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

    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{
      assignment_id: item.id,
      reason: "test revocation"
    })

    # EGR-2: a probed selected generation retains its state at terminal close; the
    # bracket is retired by stamping retirement fields, not by rewriting probed->canceled.
    assert bracket_state(ctx.db, item.id) == "probed"

    assert [["probed", "revoked", "assignment-terminal:revoked:" <> _, "session:parent"]] =
             rows(
               ctx.db,
               "SELECT state,retiredOutcome,retiredCause,retiredPrincipal FROM effort_checkin_generations WHERE assignmentId=?1 AND retiredAt IS NOT NULL ORDER BY generation DESC LIMIT 1",
               [item.id]
             )
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
               origin: "user:h1",
               principal: {:user, "h1"},
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

  test "an exact effort transition cancels its own deadline after supervision liveness disappears",
       ctx do
    for action <- ["continue", "dismiss"] do
      assignment = dispatch(ctx, {:session, "parent"}, "holder", "stale #{action}")
      request_id = open_effort_request(ctx, assignment, "parent")
      deadline = request_deadline_wake(ctx.db, request_id)
      drop_supervision_liveness(ctx.db, assignment.id)

      assert %{code: "not_authorized", message: "current expecter required"} =
               EffortCheckin.rule(
                 ctx.db,
                 ctx.config,
                 %{
                   verb: "effort-rule",
                   origin: "user:h2",
                   principal: {:user, "h2"},
                   session_key: nil,
                   params: %{request: request_id, action: action}
                 }
               )

      actor = "session:parent"

      assert %{
               id: ^request_id,
               kind: "effort",
               assignment_id: assignment_id,
               deadline_wake_id: deadline_wake_id,
               status: "ruled",
               decision: ^action,
               ruled_by: ^actor
             } =
               EffortCheckin.rule(
                 ctx.db,
                 ctx.config,
                 effort_rule_call("parent", request_id, action)
               )

      assert assignment_id == assignment.id
      assert deadline_wake_id == deadline.wake_id
      assert Wakes.get(ctx.db, deadline.wake_id).state == "canceled"

      assert %{
               requester: "tightbeam:effort-checkin",
               reason: "obligation_disposed",
               source_kind: "decision_request",
               source_id: ^request_id,
               outcome: "disposition",
               disposition_kind: "decision_request_transition",
               disposition_id: ^request_id,
               liveness_kind: nil,
               liveness_id: nil,
               action_needed: 0
             } = cancellation(ctx.db, deadline.wake_id)
    end
  end

  test "the terminal effort exception rejects mismatched requests and follows a concurrent deadline",
       ctx do
    mismatched = dispatch(ctx, {:session, "parent"}, "holder", "mismatched deadline")
    mismatched_request = open_effort_request(ctx, mismatched, "parent")
    mismatched_deadline = request_deadline_wake(ctx.db, mismatched_request)
    drop_supervision_liveness(ctx.db, mismatched.id)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET status='ruled',decision='continue',ruledBy='session:parent',ruledAt=1 WHERE id=?1",
               [mismatched_request]
             )

    unrelated =
      Wakes.schedule(ctx.db, %{
        session_key: "parent",
        origin: "process:tightbeam",
        consumer: "effort_deadline",
        due_at: System.system_time(:millisecond) + 60_000,
        assignment_id: mismatched.id
      })

    command = %{
      requester: %{kind: "process", id: "tightbeam:effort-checkin"},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "decision_request", id: mismatched_request},
      outcome: %{
        kind: "disposition",
        disposition_kind: "decision_request_transition",
        disposition_id: mismatched_request
      }
    }

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, Map.put(command, :wake_id, unrelated.wake_id))
             end)

    assert Wakes.get(ctx.db, unrelated.wake_id).state == "pending"
    assert Wakes.get(ctx.db, mismatched_deadline.wake_id).state == "pending"

    raced = dispatch(ctx, {:session, "parent"}, "holder", "deadline advanced first")
    raced_request = open_effort_request(ctx, raced, "parent")
    first_deadline = request_deadline_wake(ctx.db, raced_request)
    drop_supervision_liveness(ctx.db, raced.id)

    assert :ok = EffortCheckin.deadline(ctx.db, ctx.config, first_deadline)
    replacement = request_deadline_wake(ctx.db, raced_request)
    refute replacement.wake_id == first_deadline.wake_id

    assert %{id: ^raced_request, status: "ruled", decision: "continue"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_rule_call("parent", raced_request, "continue")
             )

    assert Wakes.get(ctx.db, first_deadline.wake_id).state == "fired"
    assert Wakes.get(ctx.db, replacement.wake_id).state == "canceled"
  end

  test "a forged terminal effort payload cannot cancel an open request deadline", ctx do
    assignment = dispatch(ctx, {:session, "parent"}, "holder", "forged terminal payload")
    request_id = open_effort_request(ctx, assignment, "parent")
    deadline = request_deadline_wake(ctx.db, request_id)
    drop_supervision_liveness(ctx.db, assignment.id)

    command = %{
      wake_id: deadline.wake_id,
      requester: %{kind: "process", id: "tightbeam:effort-checkin"},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "decision_request", id: request_id},
      outcome: %{
        kind: "disposition",
        disposition_kind: "decision_request_transition",
        disposition_id: request_id,
        terminal_request: %{
          id: request_id,
          kind: "effort",
          assignment_id: assignment.id,
          deadline_wake_id: deadline.wake_id,
          status: "ruled",
          decision: "continue"
        }
      }
    }

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn -> Wakes.cancel_in_txn(txn, command) end)

    assert Wakes.get(ctx.db, deadline.wake_id).state == "pending"

    assert rows(ctx.db, "SELECT status FROM decision_requests WHERE id=?1", [request_id]) == [
             ["open"]
           ]
  end

  # ==================================================================
  # Assignment-terminal effort-generator retirement: acceptance EGR-A1..A11
  #
  # Main-line outcome mapping. The spec's three terminal closes {completion,
  # surrender, revoke} map to main's three generator-retiring terminal
  # transitions {completion, revoke-assignment, holder-retire}. Commit c321d74a
  # renamed the public surrender transition to cannot-proceed AND made it
  # NON-terminal (it re-arms and files a decision request), so `surrendered` is
  # unreachable as a terminal close on main; holder-retire is the third distinct
  # terminal transition (outcome=revoked, durable principal). dr_15c79322 (repo
  # migration authority) and the c321d74a rename are settled adjudications; this
  # suite implements them, it does not re-file them.
  # ==================================================================

  # The retirement SET (EGR-3) = {max unretired generation} UNION {source
  # generation of each pending owned wake}. Captured dynamically so assertions
  # do not hard-code ladder counts.
  defp owned_selected(db, assignment_id) do
    [[max_gen]] =
      rows(
        db,
        "SELECT MAX(generation) FROM effort_checkin_generations WHERE assignmentId=?1 AND retiredAt IS NULL",
        [assignment_id]
      )

    pending =
      db
      |> rows(
        """
        SELECT o.wakeId, o.generation, o.role
        FROM effort_checkin_wake_ownership o JOIN wakes w ON w.wakeId = o.wakeId
        WHERE o.assignmentId = ?1 AND w.state = 'pending' ORDER BY o.generation, o.wakeId
        """,
        [assignment_id]
      )
      |> Enum.map(fn [w, g, r] -> %{wake_id: w, generation: g, role: r} end)

    {max_gen, pending}
  end

  defp gen_state(db, assignment_id, generation) do
    [[state]] =
      rows(
        db,
        "SELECT state FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=?2",
        [assignment_id, generation]
      )

    state
  end

  defp retired_count(db, assignment_id) do
    [[count]] =
      rows(
        db,
        "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1 AND retiredAt IS NOT NULL",
        [assignment_id]
      )

    count
  end

  # Close the assignment via `close_fn` and prove EGR-2/EGR-4: the exact
  # selected-set generations carry the terminal retirement fields (armed ->
  # canceled, probed retained), only that assignment's pending owned wakes
  # cancel, and no generation outside the set is retired.
  defp assert_terminal_retirement(ctx, assignment_id, close_fn, outcome, principal) do
    {max_gen, pending} = owned_selected(ctx.db, assignment_id)
    refute is_nil(max_gen)
    selected = Enum.uniq([max_gen | Enum.map(pending, & &1.generation)])
    states_before = Map.new(selected, &{&1, gen_state(ctx.db, assignment_id, &1)})

    close_fn.(ctx, assignment_id)

    assert [["closed", ^outcome]] =
             rows(ctx.db, "SELECT state,outcome FROM assignments WHERE id=?1", [assignment_id])

    cause = "assignment-terminal:" <> outcome <> ":" <> assignment_id

    for gen <- selected do
      expected_state =
        if states_before[gen] == "armed", do: "canceled", else: states_before[gen]

      assert [[^expected_state, ^outcome, ^cause, ^principal, retired_at]] =
               rows(
                 ctx.db,
                 "SELECT state,retiredOutcome,retiredCause,retiredPrincipal,retiredAt FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=?2",
                 [assignment_id, gen]
               )

      refute is_nil(retired_at)
    end

    assert retired_count(ctx.db, assignment_id) == length(selected)

    for %{wake_id: w} <- pending do
      assert %{state: "canceled"} = Wakes.get(ctx.db, w)
    end

    {selected, pending}
  end

  # Climb the parent ladder to Main so the current generation is `probed`
  # (holder-held brackets re-arm to `armed` until escalation tops out at Main).
  defp climb_to_probed_tip(ctx, assignment_id) do
    escalate(ctx, assignment_id)

    assignment(ctx, "attest", {:session, "holder"}, nil, %{
      assignment_id: assignment_id,
      kind: "progress",
      note: "material"
    })

    fire_probe(ctx, assignment_id)
    escalate(ctx, assignment_id)
    fire_probe(ctx, assignment_id)
    assert bracket_state(ctx.db, assignment_id) == "probed"
    :ok
  end

  test "EGR-A1: three terminal outcomes retire the generator; only owned wakes cancel; armed cancels, probed retains; empty set and rollback",
       ctx do
    host = Placement.local_host_name()
    holder_b = session(ctx.db, "holderB", "h2", host, %{spawned_by: "parent"})
    init_workspace(Placement.workdir_path(ctx.config, holder_b))

    complete = fn c, id ->
      assignment(c, "attest", {:session, "holder"}, nil, %{assignment_id: id, kind: "completion"})
    end

    revoke = fn c, id ->
      assignment(c, "revoke-assignment", {:session, "parent"}, nil, %{
        assignment_id: id,
        reason: "A1 revoke"
      })
    end

    # holder-retirement is session-wide, so its target lives on a dedicated
    # session; retiring it cannot touch the other three holder-held assignments.
    retire_b = fn c, _id ->
      {:ok, _} =
        DB.transaction(c.db, fn txn ->
          Assignments.interrupt_for_retire_in_txn(txn, "holderB", "h2", "user:h2")
        end)
    end

    a_complete = dispatch(ctx, {:session, "parent"}, "holder", "A1 completion")
    a_revoke = dispatch(ctx, {:session, "parent"}, "holder", "A1 revoke")
    a_retire = dispatch(ctx, {:session, "parent"}, "holderB", "A1 holder-retire")

    # Each fresh assignment: generation 1 armed with one pending owned probe.
    for a <- [a_complete, a_revoke, a_retire] do
      assert [[1, "armed", wake_id]] =
               rows(
                 ctx.db,
                 "SELECT generation,state,wakeId FROM effort_checkin_generations WHERE assignmentId=?1",
                 [a.id]
               )

      assert [["probe"]] =
               rows(ctx.db, "SELECT role FROM effort_checkin_wake_ownership WHERE wakeId=?1", [
                 wake_id
               ])

      assert %{state: "pending"} = Wakes.get(ctx.db, wake_id)
    end

    # Drive the revoke target's current generation to `probed` (proves probed
    # retention and multi-generation union retirement across the climb's wakes).
    climb_to_probed_tip(ctx, a_revoke.id)

    assert_terminal_retirement(ctx, a_complete.id, complete, "completed", "session:holder")
    assert_terminal_retirement(ctx, a_revoke.id, revoke, "revoked", "session:parent")
    assert_terminal_retirement(ctx, a_retire.id, retire_b, "revoked", "user:h2")

    # Rollback: a fault on any retirement write rolls back the whole close.
    a_rollback = dispatch(ctx, {:session, "parent"}, "holder", "A1 rollback")

    [[rb_wake]] =
      rows(ctx.db, "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1", [
        a_rollback.id
      ])

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TEMP TRIGGER egr_a1_fault BEFORE UPDATE OF retiredCause ON effort_checkin_generations BEGIN SELECT RAISE(ABORT,'egr-a1 fault'); END"
      )

    _ =
      try do
        complete.(ctx, a_rollback.id)
      rescue
        e -> {:rescued, e}
      catch
        kind, value -> {:caught, kind, value}
      end

    :ok = DB.execute(ctx.db, "DROP TRIGGER egr_a1_fault")

    assert rows(ctx.db, "SELECT state FROM assignments WHERE id=?1", [a_rollback.id]) == [
             ["open"]
           ]

    assert [[nil]] =
             rows(
               ctx.db,
               "SELECT retiredAt FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=1",
               [a_rollback.id]
             )

    assert %{state: "pending"} = Wakes.get(ctx.db, rb_wake)

    # Empty retirement set: a reopened-without-arm assignment (the boot-replay
    # shape) re-closes as a no-op. No new generation, no rewrite of the already-
    # stamped retirement fields, no wake change.
    a_empty = dispatch(ctx, {:session, "parent"}, "holder", "A1 empty")
    complete.(ctx, a_empty.id)

    retired_before =
      rows(
        ctx.db,
        "SELECT generation,retiredAt,retiredOutcome,retiredCause,retiredPrincipal,state FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation",
        [a_empty.id]
      )

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE assignments SET state='open', outcome=NULL, closedAt=NULL, closedByUser=NULL, closedBySession=NULL, closingAttestId=NULL WHERE id='#{a_empty.id}'"
      )

    complete.(ctx, a_empty.id)

    retired_after =
      rows(
        ctx.db,
        "SELECT generation,retiredAt,retiredOutcome,retiredCause,retiredPrincipal,state FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation",
        [a_empty.id]
      )

    assert retired_after == retired_before
    assert generation_count(ctx.db, a_empty.id) == 1
  end

  # Drives an assignment through the real scheduling seams until all five owned
  # roles are present, then returns the pending owned wakes keyed by role:
  #   probe (armed tip), holder_checkin (gen1 prod), parent_escalation (gen2),
  #   decision_deadline + decision_notification (deadline advance on the tip).
  defp arm_five(ctx, assignment, expecter) do
    # escalate = fire gen1 probe (zero-effect, prods holder -> owned
    # holder_checkin on gen1, re-arms gen2) then fire gen2 probe (prodded,
    # escalates parent -> owned parent_escalation on gen2, re-arms gen3).
    escalate(ctx, assignment.id)

    # Open a real effort request on the armed tip and fire its deadline: the
    # advance seam schedules the owned decision_deadline replacement and the
    # owned decision_notification, both on the request's generation.
    request_id = open_effort_request(ctx, assignment, expecter)
    deadline = request_deadline_wake(ctx.db, request_id)
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, deadline)

    ctx.db
    |> rows(
      """
      SELECT o.role, o.wakeId, o.generation
      FROM effort_checkin_wake_ownership o
      JOIN wakes w ON w.wakeId = o.wakeId
      WHERE o.assignmentId = ?1 AND w.state = 'pending'
      """,
      [assignment.id]
    )
    |> Map.new(fn [role, wake_id, generation] ->
      {String.to_atom(role), %{wake_id: wake_id, generation: generation}}
    end)
  end

  defp wake_row(db, wake_id) do
    rows(
      db,
      "SELECT wakeId,sessionKey,targetRole,origin,prompt,consumer,dueAt,state,createdAt,firedAt,conditionKind,conditionScope,assignmentId,canceledAt FROM wakes WHERE wakeId=?1",
      [wake_id]
    )
  end

  defp gen_rows(db, assignment_id) do
    rows(
      db,
      "SELECT generation,state,wakeId,retiredAt,retiredOutcome,retiredCause,retiredPrincipal FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation",
      [assignment_id]
    )
  end

  defp ownership_rows(db, assignment_id, role) do
    rows(
      db,
      "SELECT wakeId,generation FROM effort_checkin_wake_ownership WHERE assignmentId=?1 AND role=?2",
      [assignment_id, role]
    )
  end

  defp all_ownership(db, assignment_id) do
    rows(
      db,
      "SELECT wakeId,generation,role FROM effort_checkin_wake_ownership WHERE assignmentId=?1 ORDER BY generation,role,wakeId",
      [assignment_id]
    )
  end

  defp owned_wake_states(db, assignment_id) do
    rows(
      db,
      """
      SELECT w.wakeId, w.state, w.firedAt, w.canceledAt
      FROM wakes w JOIN effort_checkin_wake_ownership o ON o.wakeId = w.wakeId
      WHERE o.assignmentId = ?1
      ORDER BY w.wakeId
      """,
      [assignment_id]
    )
  end

  defp request_snapshot(db, request_id) do
    rows(
      db,
      "SELECT status,expecterSessionKey,expecterUserId,lineageRung,effortGeneration,deadlineWakeId,deadlineAt,options,context FROM decision_requests WHERE id=?1",
      [request_id]
    )
  end

  defp insert_unowned_wake(ctx, assignment_id, consumer, condition_kind) do
    wake_id = "wk_unowned_#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO wakes
                 (wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt,
                  conditionKind,conditionScope,assignmentId,targetGate)
               VALUES (?1,'holder','process:tightbeam','unowned fixture',?2,?3,'pending',?4,?5,?6,?7,1)
               """,
               [
                 wake_id,
                 consumer,
                 now + 60_000,
                 now,
                 condition_kind,
                 condition_kind && "holder",
                 assignment_id
               ]
             )

    wake_id
  end

  defp fail_ownership_at(ctx, role, drive_fn) do
    trigger = "egr_a2_fail_#{role}"

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TEMP TRIGGER #{trigger} BEFORE INSERT ON effort_checkin_wake_ownership " <>
          "WHEN NEW.role='#{role}' BEGIN SELECT RAISE(ABORT,'egr-a2 #{role}'); END"
      )

    _ =
      try do
        drive_fn.()
      rescue
        e -> {:rescued, e}
      catch
        kind, value -> {:caught, kind, value}
      end

    :ok = DB.execute(ctx.db, "DROP TRIGGER #{trigger}")
  end

  test "EGR-A2: each seam commits wake and ownership atomically; forced ownership failure commits nothing; close cancels only A's owned wakes and leaves the sibling and unowned wakes untouched",
       ctx do
    # ---- Part 1: A and B each reach all five owned roles through real seams ----
    a = dispatch(ctx, {:session, "parent"}, "holder", "A2 A")
    b = dispatch(ctx, {:session, "parent"}, "holder", "A2 B")

    a_roles = arm_five(ctx, a, "parent")
    b_roles = arm_five(ctx, b, "parent")

    expected_roles = [
      :decision_deadline,
      :decision_notification,
      :holder_checkin,
      :parent_escalation,
      :probe
    ]

    assert Enum.sort(Map.keys(a_roles)) == expected_roles
    assert Enum.sort(Map.keys(b_roles)) == expected_roles

    # Each seam committed its wake and exactly one ownership row for that wake,
    # stamped with the exact assignment, generation, and role.
    a_id = a.id

    for {role, %{wake_id: wake_id, generation: generation}} <- a_roles do
      role_string = Atom.to_string(role)

      assert [[^a_id, ^generation, ^role_string]] =
               rows(
                 ctx.db,
                 "SELECT assignmentId,generation,role FROM effort_checkin_wake_ownership WHERE wakeId=?1",
                 [wake_id]
               )

      assert %{state: "pending", assignment_id: owned_assignment} = Wakes.get(ctx.db, wake_id)
      assert owned_assignment == a.id
    end

    # ---- Part 2: forcing the ownership insert to fail commits nothing ----
    # probe seam: a fresh dispatch arms in one transaction. The ownership fault
    # rolls the whole dispatch back, so no assignment, generation, or wake lands.
    fail_ownership_at(ctx, "probe", fn ->
      dispatch(ctx, {:session, "parent"}, "holder", "A2 probe-fail")
    end)

    assert rows(ctx.db, "SELECT COUNT(*) FROM assignments WHERE subject=?1", ["A2 probe-fail"]) ==
             [[0]]

    # holder_checkin seam: a fresh armed gen1 (never prodded). The probe fire
    # marks probed and prods the holder; the ownership fault rolls that back to
    # an armed, unfired probe with no holder prompt.
    hc = dispatch(ctx, {:session, "parent"}, "holder", "A2 holder-checkin-fail")
    hc_before = gen_rows(ctx.db, hc.id)
    fail_ownership_at(ctx, "holder_checkin", fn -> fire_probe(ctx, hc.id) end)
    assert gen_rows(ctx.db, hc.id) == hc_before
    assert ownership_rows(ctx.db, hc.id, "holder_checkin") == []

    # parent_escalation seam: prod gen1 first (succeeds), then the gen2 probe
    # fire escalates the parent. The ownership fault rolls that back to an
    # armed gen2 with no escalation wake.
    pe = dispatch(ctx, {:session, "parent"}, "holder", "A2 parent-escalation-fail")
    fire_probe(ctx, pe.id)
    pe_before = gen_rows(ctx.db, pe.id)
    fail_ownership_at(ctx, "parent_escalation", fn -> fire_probe(ctx, pe.id) end)
    assert gen_rows(ctx.db, pe.id) == pe_before
    assert ownership_rows(ctx.db, pe.id, "parent_escalation") == []

    # decision_deadline seam: the advance schedules the owned replacement first.
    # The ownership fault rolls back the whole advance: request unchanged, no
    # replacement wake, no notification.
    dd = dispatch(ctx, {:session, "parent"}, "holder", "A2 decision-deadline-fail")
    dd_request = open_effort_request(ctx, dd, "parent")
    dd_row_before = request_snapshot(ctx.db, dd_request)

    fail_ownership_at(ctx, "decision_deadline", fn ->
      EffortCheckin.deadline(ctx.db, ctx.config, request_deadline_wake(ctx.db, dd_request))
    end)

    assert request_snapshot(ctx.db, dd_request) ==
             dd_row_before

    assert ownership_rows(ctx.db, dd.id, "decision_deadline") == []
    assert ownership_rows(ctx.db, dd.id, "decision_notification") == []

    # decision_notification seam: the advance schedules the deadline replacement
    # then the notification. The notification ownership fault rolls back the
    # whole advance, including the already-scheduled replacement.
    dn = dispatch(ctx, {:session, "parent"}, "holder", "A2 decision-notification-fail")
    dn_request = open_effort_request(ctx, dn, "parent")
    dn_row_before = request_snapshot(ctx.db, dn_request)

    fail_ownership_at(ctx, "decision_notification", fn ->
      EffortCheckin.deadline(ctx.db, ctx.config, request_deadline_wake(ctx.db, dn_request))
    end)

    assert request_snapshot(ctx.db, dn_request) ==
             dn_row_before

    assert ownership_rows(ctx.db, dn.id, "decision_deadline") == []
    assert ownership_rows(ctx.db, dn.id, "decision_notification") == []

    # ---- Part 3: close A cancels only A's owned pending wakes ----
    ordinary = insert_unowned_wake(ctx, a.id, "prompt", nil)
    condition = insert_unowned_wake(ctx, a.id, "prompt", "work-blocked")
    supervision = insert_unowned_wake(ctx, a.id, "supervision", nil)
    unowned = [ordinary, condition, supervision]
    unowned_before = Map.new(unowned, &{&1, wake_row(ctx.db, &1)})

    # A's fired probe wakes (gen1, gen2) are owned but not pending; they must
    # not be re-touched by the close.
    a_fired =
      rows(ctx.db, "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND state='fired'", [a.id])

    a_fired_before = Map.new(a_fired, fn [w] -> {w, wake_row(ctx.db, w)} end)

    b_gens_before = gen_rows(ctx.db, b.id)
    b_owned_before = Map.new(b_roles, fn {_role, %{wake_id: w}} -> {w, wake_row(ctx.db, w)} end)

    assignment(ctx, "attest", {:session, "holder"}, nil, %{
      assignment_id: a.id,
      kind: "completion"
    })

    assert [["closed", "completed"]] =
             rows(ctx.db, "SELECT state,outcome FROM assignments WHERE id=?1", [a.id])

    # Only A's five pending owned wakes cancel.
    for {_role, %{wake_id: wake_id}} <- a_roles do
      assert %{state: "canceled"} = Wakes.get(ctx.db, wake_id)
    end

    # A's already-fired owned probes are untouched.
    for {wake_id, before} <- a_fired_before do
      assert wake_row(ctx.db, wake_id) == before
    end

    # A's unowned wakes are byte-for-byte unchanged.
    for {wake_id, before} <- unowned_before do
      assert wake_row(ctx.db, wake_id) == before
    end

    # The sibling B's generator and every owned wake are byte-for-byte unchanged.
    assert gen_rows(ctx.db, b.id) == b_gens_before

    for {wake_id, before} <- b_owned_before do
      assert wake_row(ctx.db, wake_id) == before
    end
  end

  # The single pending owned wake for a role. holder_checkin and parent_escalation
  # are consumer='prompt' wakes the gateway delivers into a message + turn; probe
  # and decision_deadline are internal-consumer wakes that never produce a turn.
  defp owned_prompt_wake(db, assignment_id, role) do
    [[wake_id, generation]] =
      rows(
        db,
        """
        SELECT o.wakeId, o.generation
        FROM effort_checkin_wake_ownership o
        JOIN wakes w ON w.wakeId = o.wakeId
        WHERE o.assignmentId = ?1 AND o.role = ?2 AND w.state = 'pending'
        """,
        [assignment_id, role]
      )

    %{wake_id: wake_id, generation: generation}
  end

  defp turn_count(db, wake_id),
    do: rows(db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id]) |> hd() |> hd()

  defp wake_cancellations(db, wake_id) do
    rows(
      db,
      "SELECT dispositionKind,dispositionId,reasonKind,wakeState FROM wake_cancellations WHERE wakeId=?1",
      [wake_id]
    )
  end

  # A wake's ownership row joined to its source generation's retirement stamp.
  defp ownership_retirement(db, wake_id) do
    rows(
      db,
      """
      SELECT o.role, o.generation, g.state, g.retiredOutcome, g.retiredCause, g.retiredPrincipal
      FROM effort_checkin_wake_ownership o
      JOIN effort_checkin_generations g
        ON g.assignmentId = o.assignmentId AND g.generation = o.generation
      WHERE o.wakeId = ?1
      """,
      [wake_id]
    )
  end

  defp gen_retirement(db, assignment_id, generation) do
    rows(
      db,
      "SELECT state,retiredOutcome,retiredCause,retiredPrincipal FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=?2",
      [assignment_id, generation]
    )
  end

  test "EGR-A3: delivery race — close-before-delivery cancels the owned wake, delivery-before-close leaves it fired",
       ctx do
    complete = fn id ->
      assignment(ctx, "attest", {:session, "holder"}, nil, %{
        assignment_id: id,
        kind: "completion"
      })
    end

    # A and B reach ONE identical pending owned holder-checkin prompt wake each: a
    # fresh dispatch, then one probe fire prods the holder (owned holder_checkin
    # prompt wake on gen1, pending) and re-arms gen2. The wakes are identical in
    # role, consumer, target, and state; only the close/delivery order differs.
    a = dispatch(ctx, {:session, "parent"}, "holder", "A3 close-before-delivery")
    b = dispatch(ctx, {:session, "parent"}, "holder", "A3 delivery-before-close")

    fire_probe(ctx, a.id)
    fire_probe(ctx, b.id)

    a_hc = owned_prompt_wake(ctx.db, a.id, "holder_checkin")
    b_hc = owned_prompt_wake(ctx.db, b.id, "holder_checkin")

    for w <- [a_hc.wake_id, b_hc.wake_id] do
      assert [["pending", "prompt", nil]] =
               rows(ctx.db, "SELECT state,consumer,canceledAt FROM wakes WHERE wakeId=?1", [w])

      assert turn_count(ctx.db, w) == 0
      assert wake_cancellations(ctx.db, w) == []
    end

    a_id = a.id
    a_hc_gen = a_hc.generation

    # ---- A: close commits BEFORE delivery. The pending owned wake is canceled. ----
    complete.(a.id)

    assert [["canceled", canceled_at]] =
             rows(ctx.db, "SELECT state,canceledAt FROM wakes WHERE wakeId=?1", [a_hc.wake_id])

    assert is_integer(canceled_at)

    # Exactly one typed cancellation, the assignment-terminal disposition.
    assert [["assignment_transition", ^a_id, "obligation_disposed", "canceled"]] =
             wake_cancellations(ctx.db, a_hc.wake_id)

    # No message or turn: it never reached the delivery seam.
    assert turn_count(ctx.db, a_hc.wake_id) == 0

    # Its ownership row joins directly to its source generation's retirement cause
    # and principal. gen1 was `probed` by the probe fire, so it retains that state
    # while receiving the terminal stamp.
    assert [["holder_checkin", ^a_hc_gen, "probed", "completed", a_cause, "session:holder"]] =
             ownership_retirement(ctx.db, a_hc.wake_id)

    assert a_cause == "assignment-terminal:completed:" <> a.id

    # ---- B: delivery commits BEFORE close. The wake fires; close then leaves it. ----
    # Barrier at the delivery seam: push gen2's internal probe out of the due window
    # so the real gateway drain delivers exactly the wake under test (b_hc). Firing
    # the probe would escalate and re-arm, muddying the generation set.
    b_probe = current_wake(ctx.db, b.id)

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE wakes SET dueAt=#{System.system_time(:millisecond) + 3_600_000} WHERE wakeId='#{b_probe.wake_id}'"
      )

    drain_notifications!(ctx)

    # Delivered: fired with its message and turn.
    assert [["fired"]] = rows(ctx.db, "SELECT state FROM wakes WHERE wakeId=?1", [b_hc.wake_id])
    assert turn_count(ctx.db, b_hc.wake_id) == 1

    [[b_message_id]] = rows(ctx.db, "SELECT messageId FROM turns WHERE wakeId=?1", [b_hc.wake_id])
    assert [[_]] = rows(ctx.db, "SELECT seq FROM messages WHERE id=?1", [b_message_id])
    assert wake_cancellations(ctx.db, b_hc.wake_id) == []

    # EGR-8 forbids retirement from rewriting the fired wake or its turn. The
    # sibling queued-turn amendment wi_154bf46b — which would dispose the queued
    # turn at close — is ABSENT from this checkout and owns a separate acceptance
    # lane per the spec's Architecture section ("runs beside, not inside ... Neither
    # owns the other's tables or acceptance lane"), so A3 asserts only that MY
    # retirement mutation leaves the fired wake and its queued turn untouched.
    b_hc_before = wake_row(ctx.db, b_hc.wake_id)

    b_turn_before =
      rows(ctx.db, "SELECT seq,messageId,wakeId,status,owner FROM turns WHERE wakeId=?1", [
        b_hc.wake_id
      ])

    [[b_max_gen]] =
      rows(
        ctx.db,
        "SELECT MAX(generation) FROM effort_checkin_generations WHERE assignmentId=?1",
        [b.id]
      )

    b_id = b.id

    complete.(b.id)

    # The fired wake and its turn are byte-for-byte unchanged; no cancellation added.
    assert wake_row(ctx.db, b_hc.wake_id) == b_hc_before

    assert rows(ctx.db, "SELECT seq,messageId,wakeId,status,owner FROM turns WHERE wakeId=?1", [
             b_hc.wake_id
           ]) == b_turn_before

    assert wake_cancellations(ctx.db, b_hc.wake_id) == []
    assert turn_count(ctx.db, b_hc.wake_id) == 1

    # The maximum unretired generation records the retirement.
    assert [["canceled", "completed", b_cause, "session:holder"]] =
             gen_retirement(ctx.db, b.id, b_max_gen)

    assert b_cause == "assignment-terminal:completed:" <> b_id

    # The fired wake's own source generation stays out of the retirement set: only
    # pending owned wakes and the maximum unretired generation are selected, and
    # gen1's owned wake fired rather than remaining pending, so gen1 is unstamped.
    assert [["probed", nil, nil, nil]] = gen_retirement(ctx.db, b.id, b_hc.generation)
  end

  defp holder_checkin_wake_count(db, assignment_id) do
    [[count]] =
      rows(
        db,
        "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND prompt LIKE '[effort check-in]%'",
        [assignment_id]
      )

    count
  end

  test "EGR-A4: probe race and re-arm — a close-wins probe emits nothing and makes no generation; a probe-wins prompt and generation are retired on close; replays make no row",
       ctx do
    complete = fn c, id ->
      assignment(c, "attest", {:session, "holder"}, nil, %{assignment_id: id, kind: "completion"})
    end

    # ---- close wins: the armed probe fires AFTER close and emits nothing ----
    a = dispatch(ctx, {:session, "parent"}, "holder", "A4 close-wins")
    a_probe = current_wake(ctx.db, a.id)

    complete.(ctx, a.id)

    # gen1 was armed; close canceled+stamped it and canceled its probe wake.
    assert generation_count(ctx.db, a.id) == 1
    assert bracket_state(ctx.db, a.id) == "canceled"

    # The EGR-6 recheck: firing the consumed probe creates no generation, no
    # holder prompt, and no output — and replaying it again is still inert.
    a_before = gen_rows(ctx.db, a.id)
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, a_probe)
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, a_probe)
    assert generation_count(ctx.db, a.id) == 1
    assert gen_rows(ctx.db, a.id) == a_before
    assert ownership_rows(ctx.db, a.id, "holder_checkin") == []
    assert holder_checkin_wake_count(ctx.db, a.id) == 0

    # ---- probe wins: the probe emits a prompt + new generation, then close retires both ----
    b = dispatch(ctx, {:session, "parent"}, "holder", "A4 probe-wins")
    b_gen1_probe = current_wake(ctx.db, b.id)

    fire_probe(ctx, b.id)

    # Emitted: gen1 marked `probed` with one owned holder_checkin prompt, and a
    # fresh armed gen2 (the re-arm).
    assert generation_count(ctx.db, b.id) == 2
    assert bracket_state(ctx.db, b.id) == "armed"
    assert [[hc_wake, 1]] = ownership_rows(ctx.db, b.id, "holder_checkin")
    assert %{state: "pending", consumer: "prompt"} = Wakes.get(ctx.db, hc_wake)
    b_gen2_probe = current_wake(ctx.db, b.id)

    # Close cancels that prompt and the new probe, retires gen2 (the max unretired
    # generation), and retains gen1's consumed `probed` state while stamping it.
    assert_terminal_retirement(ctx, b.id, complete, "completed", "session:holder")

    assert [["probed"]] =
             rows(
               ctx.db,
               "SELECT state FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=1",
               [b.id]
             )

    assert [["canceled"]] =
             rows(
               ctx.db,
               "SELECT state FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=2",
               [b.id]
             )

    assert %{state: "canceled"} = Wakes.get(ctx.db, hc_wake)

    # Replaying either callback creates no row: both source generations are past
    # `armed`, so the probe recheck is inert.
    b_snap = gen_rows(ctx.db, b.id)
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, b_gen1_probe)
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, b_gen2_probe)
    assert generation_count(ctx.db, b.id) == 2
    assert gen_rows(ctx.db, b.id) == b_snap
  end

  # EGR-A5 exercises the MAIN line only: the fixture is the migrated legacy open
  # effort request (`open_effort_request` — a hand-built legacy-shaped row with an
  # unowned deadline wake, the pre-0.1.9 shape). Its deadline advance is the seam
  # that schedules the owned `decision_deadline` replacement and owned
  # `decision_notification`, so a main-line request reaches the notification
  # boundary only after one advance. The spec's "0.1.9 fixture also exercises new
  # request creation" is a separate acceptance lane on that line, out of scope here.
  test "EGR-A5: decision races on deadline, notification, and continue-ruling boundaries in both orders; a ruled request's pending notification cancels with its row and ruling unchanged",
       ctx do
    complete = fn c, id ->
      assignment(c, "attest", {:session, "holder"}, nil, %{assignment_id: id, kind: "completion"})
    end

    # A migrated legacy request whose deadline fires once: the advance seam
    # schedules the owned decision_deadline replacement and owned
    # decision_notification on the request's generation and marks the legacy
    # deadline wake fired.
    advance = fn assignment ->
      request = open_effort_request(ctx, assignment, "parent")
      :ok = EffortCheckin.deadline(ctx.db, ctx.config, request_deadline_wake(ctx.db, request))
      request
    end

    # ---- deadline boundary, close wins: supersede + cancel the deadline wake; the late callback makes nothing ----
    dl_c = dispatch(ctx, {:session, "parent"}, "holder", "A5 deadline close-wins")
    dl_c_req = open_effort_request(ctx, dl_c, "parent")
    dl_c_deadline = request_deadline_wake(ctx.db, dl_c_req)
    dl_c_gens = generation_count(ctx.db, dl_c.id)

    complete.(ctx, dl_c.id)

    assert [["superseded", nil, nil]] = request_ruling(ctx.db, dl_c_req)
    assert %{state: "canceled"} = Wakes.get(ctx.db, dl_c_deadline.wake_id)

    # EGR-6: the losing deadline callback rechecks the closed assignment and
    # creates no replacement wake, deadline, or generation.
    assert :ok = EffortCheckin.deadline(ctx.db, ctx.config, dl_c_deadline)
    assert generation_count(ctx.db, dl_c.id) == dl_c_gens

    assert rows(ctx.db, "SELECT deadlineWakeId FROM decision_requests WHERE id=?1", [dl_c_req]) ==
             [[dl_c_deadline.wake_id]]

    assert ownership_rows(ctx.db, dl_c.id, "decision_deadline") == []

    # ---- deadline boundary, action wins: the advance owns a replacement + notification; close retires them ----
    dl_w = dispatch(ctx, {:session, "parent"}, "holder", "A5 deadline action-wins")
    dl_w_req = advance.(dl_w)
    dl_w_d2 = request_deadline_wake(ctx.db, dl_w_req)
    dl_w_n = owned_prompt_wake(ctx.db, dl_w.id, "decision_notification")

    assert %{state: "pending"} = Wakes.get(ctx.db, dl_w_d2.wake_id)
    assert %{state: "pending"} = Wakes.get(ctx.db, dl_w_n.wake_id)

    # Close cancels each pending owned replacement and retires the current
    # generation (assert_terminal_retirement checks every pending owned wake).
    assert_terminal_retirement(ctx, dl_w.id, complete, "completed", "session:holder")
    assert %{state: "canceled"} = Wakes.get(ctx.db, dl_w_d2.wake_id)
    assert %{state: "canceled"} = Wakes.get(ctx.db, dl_w_n.wake_id)

    # ---- notification boundary, close wins: the pending owned notification cancels before it can deliver ----
    nt_c = dispatch(ctx, {:session, "parent"}, "holder", "A5 notification close-wins")
    nt_c_req = advance.(nt_c)
    nt_c_n = owned_prompt_wake(ctx.db, nt_c.id, "decision_notification")

    complete.(ctx, nt_c.id)

    assert %{state: "canceled"} = Wakes.get(ctx.db, nt_c_n.wake_id)
    # Losing action creates no replacement: no message or turn ever landed.
    assert turn_count(ctx.db, nt_c_n.wake_id) == 0
    assert [["superseded", nil, nil]] = request_ruling(ctx.db, nt_c_req)

    # ---- continue-ruling boundary, close wins: the ruling finds a superseded request and makes nothing ----
    rl_c = dispatch(ctx, {:session, "parent"}, "holder", "A5 ruling close-wins")
    rl_c_req = open_effort_request(ctx, rl_c, "parent")
    rl_c_gens = generation_count(ctx.db, rl_c.id)

    complete.(ctx, rl_c.id)

    assert [["superseded", nil, nil]] = request_ruling(ctx.db, rl_c_req)

    assert %{code: "not_open"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_rule_call("parent", rl_c_req, "continue")
             )

    assert generation_count(ctx.db, rl_c.id) == rl_c_gens

    # ---- continue-ruling boundary, action wins: the ruling arms a new generation; close retires it ----
    rl_w = dispatch(ctx, {:session, "parent"}, "holder", "A5 ruling action-wins")
    rl_w_req = open_effort_request(ctx, rl_w, "parent")
    rl_w_deadline = request_deadline_wake(ctx.db, rl_w_req)

    assert %{status: "ruled", decision: "continue"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_rule_call("parent", rl_w_req, "continue")
             )

    # The ruling cancels the request's own deadline wake and arms a fresh generation.
    assert %{state: "canceled"} = Wakes.get(ctx.db, rl_w_deadline.wake_id)
    assert generation_count(ctx.db, rl_w.id) == 2

    assert_terminal_retirement(ctx, rl_w.id, complete, "completed", "session:holder")
    assert [["ruled", "continue", _]] = request_ruling(ctx.db, rl_w_req)

    # ---- ruled request with a pending owned notification: close cancels the notification; row and ruling unchanged ----
    rn = dispatch(ctx, {:session, "parent"}, "holder", "A5 ruled with pending notification")
    rn_req = advance.(rn)
    rn_n = owned_prompt_wake(ctx.db, rn.id, "decision_notification")

    assert %{status: "ruled", decision: "continue"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_rule_call("parent", rn_req, "continue")
             )

    # The ruling cancels only the request's deadline wake; the owned notification
    # remains pending until close.
    assert %{state: "pending"} = Wakes.get(ctx.db, rn_n.wake_id)
    rn_row_before = request_snapshot(ctx.db, rn_req)
    rn_ruling_before = request_ruling(ctx.db, rn_req)

    complete.(ctx, rn.id)

    # EGR-8: close cancels the pending owned notification, but the ruled request
    # row and its ruling are byte-for-byte unchanged.
    assert %{state: "canceled"} = Wakes.get(ctx.db, rn_n.wake_id)
    assert request_snapshot(ctx.db, rn_req) == rn_row_before
    assert request_ruling(ctx.db, rn_req) == rn_ruling_before

    # ---- notification boundary, action wins: the notification delivers first; close leaves it fired ----
    nt_w = dispatch(ctx, {:session, "parent"}, "holder", "A5 notification action-wins")
    nt_w_req = advance.(nt_w)
    nt_w_n = owned_prompt_wake(ctx.db, nt_w.id, "decision_notification")
    nt_w_d2 = request_deadline_wake(ctx.db, nt_w_req)

    # Barrier at the delivery seam: defer every other pending wake so the real
    # gateway drain delivers exactly the notification under test.
    :ok =
      DB.execute(
        ctx.db,
        "UPDATE wakes SET dueAt=#{System.system_time(:millisecond) + 3_600_000} WHERE state='pending' AND wakeId != '#{nt_w_n.wake_id}'"
      )

    drain_notifications!(ctx)

    assert [["fired"]] = rows(ctx.db, "SELECT state FROM wakes WHERE wakeId=?1", [nt_w_n.wake_id])
    assert turn_count(ctx.db, nt_w_n.wake_id) == 1
    nt_w_n_before = wake_row(ctx.db, nt_w_n.wake_id)

    complete.(ctx, nt_w.id)

    # Close cancels the still-pending owned deadline replacement and retires the
    # current generation; the won notification stays fired byte-for-byte.
    assert %{state: "canceled"} = Wakes.get(ctx.db, nt_w_d2.wake_id)
    assert wake_row(ctx.db, nt_w_n.wake_id) == nt_w_n_before
    assert wake_cancellations(ctx.db, nt_w_n.wake_id) == []
    assert turn_count(ctx.db, nt_w_n.wake_id) == 1

    [[nt_w_max]] =
      rows(
        ctx.db,
        "SELECT MAX(generation) FROM effort_checkin_generations WHERE assignmentId=?1",
        [nt_w.id]
      )

    assert [["canceled", "completed", _, "session:holder"]] =
             gen_retirement(ctx.db, nt_w.id, nt_w_max)
  end

  # EGR-A6 verifies EGR-7 (no resurrection). It drives every replay vector EGR-7
  # names — boot, callback replay, terminal-command retry, and terminal-
  # publication replay — against a retired generator carrying canceled, fired,
  # and ruled history, then proves both reopen shapes: a reopen WITHOUT a new arm
  # re-closes as an empty-set no-op, and the lawful `reopen-assignment` arm
  # commits exactly one new generation with a greater number and one owned probe.
  # `Ledger.recover_running/1` is the boot reconciler that also drives the
  # terminal-publication feed, so one call covers both the boot and publication-
  # replay vectors; the paired `Escalation.recover_retired/1` completes the boot
  # sequence exactly as `Tightbeam.Boot` runs it (boot.ex:52-53).
  test "EGR-A6: boot, callback replay, and terminal retries leave a retired generator byte-for-byte unchanged; reopen-without-arm is an empty-set no-op; the lawful arm commits one greater generation",
       ctx do
    complete = fn c, id ->
      assignment(c, "attest", {:session, "holder"}, nil, %{assignment_id: id, kind: "completion"})
    end

    boot = fn ->
      _ = Ledger.recover_running(ctx.db)
      :ok = Tightbeam.Escalation.recover_retired(ctx.db)
    end

    # ---- Build a retired generator with canceled, fired, and ruled history ----
    w = dispatch(ctx, {:session, "parent"}, "holder", "A6 retired generator")

    # Keep the holder non-empty for the whole test. The completion-review
    # production (a DIFFERENT card's seam) opens a completion_escalations row on
    # a completion only when it drains the holder's LAST open assignment
    # (remaining == 0 -> status 'open'), and that table carries a UNIQUE partial
    # index over one 'open' row per childSessionKey. A6 deliberately forces the
    # EGR-7 resurrection shape (a raw reopen-without-arm, then a re-close the
    # real system never permits), so a drained holder would make the re-close
    # collide on that unrelated production's guard and mask the effort-generator
    # seam this test exists to prove. A live sibling assignment keeps every
    # completion at remaining >= 1 ('notice-only', which the index ignores),
    # exactly the condition under which EGR-A1's empty-set reopen already passes.
    _sibling = dispatch(ctx, {:session, "parent"}, "holder", "A6 holder stays non-empty")

    # A migrated legacy open effort request on gen1; its deadline fires (a FIRED
    # legacy wake) and schedules the owned decision_deadline replacement and the
    # owned decision_notification, exactly like the EGR-A5 `advance` seam.
    req = open_effort_request(ctx, w, "parent")
    legacy_deadline = request_deadline_wake(ctx.db, req)
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, legacy_deadline)
    assert %{state: "fired"} = Wakes.get(ctx.db, legacy_deadline.wake_id)

    # The continue ruling arms gen2, cancels the request's owned deadline
    # replacement (CANCELED history), and leaves gen1's probe and the owned
    # notification pending until close.
    deadline_replacement = request_deadline_wake(ctx.db, req)

    assert %{status: "ruled", decision: "continue"} =
             EffortCheckin.rule(ctx.db, ctx.config, effort_rule_call("parent", req, "continue"))

    assert %{state: "canceled"} = Wakes.get(ctx.db, deadline_replacement.wake_id)
    assert [["ruled", "continue", _]] = request_ruling(ctx.db, req)
    assert generation_count(ctx.db, w.id) == 2

    # Capture gen2's probe before close for the callback-replay vector.
    gen2_probe = current_wake(ctx.db, w.id)

    # Close retires every generation: gen2 is the max, gen1 carries a pending
    # owned probe and the pending owned notification, so the retirement set is
    # {gen1, gen2} and no unretired generation remains.
    {selected, _pending} =
      assert_terminal_retirement(ctx, w.id, complete, "completed", "session:holder")

    assert Enum.sort(selected) == [1, 2]

    # The fired legacy wake and the ruled request survive the close untouched.
    assert %{state: "fired"} = Wakes.get(ctx.db, legacy_deadline.wake_id)
    assert [["ruled", "continue", _]] = request_ruling(ctx.db, req)

    # ---- Snapshot the fully retired generator ----
    gens0 = gen_rows(ctx.db, w.id)
    own0 = all_ownership(ctx.db, w.id)
    wakes0 = owned_wake_states(ctx.db, w.id)
    legacy0 = wake_row(ctx.db, legacy_deadline.wake_id)
    req0 = request_snapshot(ctx.db, req)
    ruling0 = request_ruling(ctx.db, req)
    count0 = generation_count(ctx.db, w.id)
    assert count0 == 2

    snapshot = fn ->
      assert gen_rows(ctx.db, w.id) == gens0
      assert all_ownership(ctx.db, w.id) == own0
      assert owned_wake_states(ctx.db, w.id) == wakes0
      assert wake_row(ctx.db, legacy_deadline.wake_id) == legacy0
      assert request_snapshot(ctx.db, req) == req0
      assert request_ruling(ctx.db, req) == ruling0
      assert generation_count(ctx.db, w.id) == count0
    end

    # ---- EGR-7 replay vectors: none may change a retired row ----
    # Boot twice (recover_running also drives the terminal-publication feed).
    boot.()
    boot.()
    # Terminal-command retry: re-attest completion on the closed assignment.
    complete.(ctx, w.id)
    # Callback replay: a stale probe callback for a retired generation is inert.
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, gen2_probe)

    snapshot.()

    # ---- Reopen WITHOUT a new arm: the re-close is an empty-set no-op ----
    # Raw state flip (no reopen-assignment arm), the same shape EGR-A1 uses to
    # reach the close seam with no armed or pending-owned generation.
    :ok =
      DB.execute(
        ctx.db,
        "UPDATE assignments SET state='open', outcome=NULL, closedAt=NULL, closedByUser=NULL, closedBySession=NULL, closingAttestId=NULL WHERE id='#{w.id}'"
      )

    complete.(ctx, w.id)

    # No new generation, no retirement field overwritten, no pre-reopen output
    # fired: every prior row is byte-for-byte unchanged.
    snapshot.()

    # ---- Reopen WITH the lawful arm, then boot: exactly one greater generation ----
    reopened =
      assignment(ctx, "reopen-assignment", {:session, "parent"}, nil, %{
        assignment_id: w.id,
        reason: "A6 the card carries work again"
      })

    assert reopened.state == "open"
    boot.()

    # Exactly one new generation, numbered greater than every stored generation,
    # armed, with exactly one owned probe.
    assert generation_count(ctx.db, w.id) == count0 + 1

    assert [[3, "armed", new_probe]] =
             rows(
               ctx.db,
               "SELECT generation,state,wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=?2",
               [w.id, count0 + 1]
             )

    assert Enum.filter(ownership_rows(ctx.db, w.id, "probe"), fn [_w, g] -> g == 3 end) ==
             [[new_probe, 3]]

    assert %{state: "pending"} = Wakes.get(ctx.db, new_probe)

    # The retired generations are untouched by the prospective arm.
    assert Enum.take(gen_rows(ctx.db, w.id), 2) == gens0
  end

  # EGR-A8 verifies EGR-10. One work item carries: a CLOSED assignment whose
  # completion retires its generations and cancels its pending owned wakes
  # (the canceled-owned-wake and retired-generation cases), the fired owned
  # probe wakes the escalation consumed (the fired case), and a second, still
  # OPEN assignment whose owned probe is untouched (the unaffected case). The
  # authorized reader sees the stored role on every effort-owned wake entry,
  # the four retirement fields on the retired generations, an unchanged typed
  # cancellation disposition, and effortRole null on a non-effort wake. The
  # unauthorized reader keeps the pre-amendment not_found refusal with no
  # ownership or retirement data.
  test "EGR-A8: authorized work-item trace exposes effort roles on owned wakes and the four retirement fields on retired generations; unauthorized reader keeps the not_found refusal",
       ctx do
    host = Placement.local_host_name()
    item = work_item!(ctx.db, "A8 trace exposure")

    # The assignment that closes: arm all five owned roles, then complete it.
    closing = dispatch_for_item(ctx, {:session, "parent"}, "holder", "A8 closing", item.id)
    owned = arm_five(ctx, closing, "parent")

    # A fired owned wake: escalate's consumed probes keep their ownership rows.
    fired_probe =
      case rows(
             ctx.db,
             """
             SELECT o.wakeId
             FROM effort_checkin_wake_ownership o JOIN wakes w ON w.wakeId = o.wakeId
             WHERE o.assignmentId = ?1 AND o.role = 'probe' AND w.state = 'fired'
             ORDER BY o.generation LIMIT 1
             """,
             [closing.id]
           ) do
        [[wake_id]] -> wake_id
        other -> flunk("expected a fired owned probe, got: #{inspect(other)}")
      end

    # The unaffected case: a second assignment on the same item stays open, so
    # its owned probe never cancels and its generation never retires.
    _open_holder = session(ctx.db, "holderB", "h1", host, %{spawned_by: "parent"})
    init_workspace(Placement.workdir_path(ctx.config, _open_holder))
    open = dispatch_for_item(ctx, {:session, "parent"}, "holderB", "A8 open", item.id)

    unaffected_wake =
      case rows(
             ctx.db,
             """
             SELECT o.wakeId
             FROM effort_checkin_wake_ownership o JOIN wakes w ON w.wakeId = o.wakeId
             WHERE o.assignmentId = ?1 AND w.state = 'pending' ORDER BY o.generation LIMIT 1
             """,
             [open.id]
           ) do
        [[wake_id]] ->
          wake_id

        other ->
          flunk("expected a pending owned wake on the open assignment, got: #{inspect(other)}")
      end

    canceled_wake = owned.decision_notification.wake_id

    assignment(ctx, "attest", {:session, "holder"}, nil, %{
      assignment_id: closing.id,
      kind: "completion"
    })

    # The pre-amendment refusal is unchanged and leaks no timeline.
    refusal = work_item_trace(ctx, {:user, "other"}, item.id)
    assert %{code: "not_found", message: "work item not found"} = refusal
    refute Map.has_key?(refusal, :timeline)

    timeline = ctx |> work_item_trace({:user, "h1"}, item.id) |> Map.fetch!(:timeline)

    entry = fn type, id ->
      case Enum.filter(timeline, &(&1.type == type and &1.id == id)) do
        [one] -> one
        other -> flunk("expected one #{type} entry for #{inspect(id)}, got: #{inspect(other)}")
      end
    end

    # The canceled owned wake: its stored role is exposed and the existing
    # typed cancellation disposition is intact (effortRole is added beside it,
    # renaming and removing nothing).
    canceled_entry = entry.("wake_canceled", canceled_wake)
    assert canceled_entry.effortRole == "decision_notification"
    assert canceled_entry.provenanceStatus == "proven"
    assert Map.has_key?(canceled_entry, :dispositionKind)

    # The fired owned wake exposes its stored 'probe' role.
    assert entry.("wake_fired", fired_probe).effortRole == "probe"

    # The unaffected owned wake is still scheduled and exposes its role; its
    # generation is not retired, so all four retirement fields are null.
    assert entry.("wake_scheduled", unaffected_wake).effortRole == "probe"

    open_gen = entry.("effort_generation", "gen:#{open.id}:1")

    assert {open_gen.retiredAt, open_gen.retiredOutcome, open_gen.retiredCause,
            open_gen.retiredPrincipal} == {nil, nil, nil, nil}

    # A retired generation of the closed assignment carries the terminal cause
    # and principal in the four retirement fields.
    retired =
      Enum.filter(
        timeline,
        &(&1.type == "effort_generation" and &1.assignmentId == closing.id and
            not is_nil(&1.retiredAt))
      )

    assert retired != []

    for gen <- retired do
      assert gen.retiredOutcome == "completed"
      assert gen.retiredCause == "assignment-terminal:completed:" <> closing.id
      assert gen.retiredPrincipal == "session:holder"
    end

    # EGR-10 null-when-absent: a non-effort wake (the fired rumination wake on
    # this item) carries effortRole nil, proving the field is added, not gated.
    assert Enum.any?(timeline, &(&1.type == "wake_scheduled" and is_nil(&1.effortRole)))
  end

  # EGR-A9 (idempotency half; the migration halves live in schema_shape_test).
  # EGR-A6 already proves the retired ROWS survive boot, terminal retry, and
  # callback replay byte-for-byte. This adds the missing EGR-10 guarantee: the
  # work-item TRACE projection of the retirement is equally stable across a
  # close retry and repeated boot replay.
  test "EGR-A9: a completed retirement is stable in rows and in the work-item trace across a close retry and repeated boot replay",
       ctx do
    boot = fn ->
      _ = Ledger.recover_running(ctx.db)
      :ok = Tightbeam.Escalation.recover_retired(ctx.db)
    end

    complete = fn id ->
      assignment(ctx, "attest", {:session, "holder"}, nil, %{
        assignment_id: id,
        kind: "completion"
      })
    end

    item = work_item!(ctx.db, "A9 idempotency")
    w = dispatch_for_item(ctx, {:session, "parent"}, "holder", "A9 retired", item.id)

    # Keep the holder non-empty so a re-close stays notice-only and never
    # collides on the completion-review production's unique open-row index
    # (the guard EGR-A6 documents in detail).
    _sibling = dispatch(ctx, {:session, "parent"}, "holder", "A9 holder stays non-empty")

    complete.(w.id)

    effort_trace = fn ->
      ctx
      |> work_item_trace({:user, "h1"}, item.id)
      |> Map.fetch!(:timeline)
      |> Enum.filter(
        &(&1.type in ["effort_generation", "wake_scheduled", "wake_fired", "wake_canceled"])
      )
      |> Enum.sort_by(&{&1.type, &1.id, &1.at})
    end

    gens0 = gen_rows(ctx.db, w.id)
    own0 = all_ownership(ctx.db, w.id)
    wakes0 = owned_wake_states(ctx.db, w.id)
    count0 = generation_count(ctx.db, w.id)
    trace0 = effort_trace.()

    # A retried close and repeated boot replay change no row and no trace entry.
    complete.(w.id)
    boot.()
    boot.()

    assert gen_rows(ctx.db, w.id) == gens0
    assert all_ownership(ctx.db, w.id) == own0
    assert owned_wake_states(ctx.db, w.id) == wakes0
    assert generation_count(ctx.db, w.id) == count0
    assert effort_trace.() == trace0
  end

  defp work_item_trace(ctx, principal, work_item_id) do
    WorkItems.__handle__(ctx.db, "work-item-trace", %{
      verb: "work-item-trace",
      principal: principal,
      origin: origin(principal),
      session_key: nil,
      params: %{work_item_id: work_item_id}
    })
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

  defp drop_supervision_liveness(db, assignment_id) do
    assert {:ok, _} =
             DB.query(db, "DELETE FROM supervision_entitlements WHERE assignmentId=?1", [
               assignment_id
             ])

    assert rows(db, "SELECT COUNT(*) FROM supervision_entitlements WHERE assignmentId=?1", [
             assignment_id
           ]) == [[0]]

    :ok
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
