defmodule Tightbeam.EffortCheckinTest do
  use Tightbeam.TestCase, async: false
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
    Org,
    Placement,
    Wakes,
    WorkItems
  }

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

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('h1',0,1),('h2',0,1),('admin',1,1)"
      )

    host = Placement.local_host_name()
    parent = session(db, "parent", "h1", host)
    holder = session(db, "holder", "h2", host, %{spawned_by: "parent"})
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

  test "proof 1: dispatch arms one bracket; bare assign does not; roots validate; all closes cancel",
       ctx do
    bare = assignment(ctx, "assign", {:user, "h1"}, "holder", %{subject: "bare"})

    assert rows(ctx.db, "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1", [
             bare.id
           ]) == [[0]]

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
      open = escalate(ctx, item.id)
      assignment(ctx, "attest", {:session, "holder"}, nil, %{assignment_id: item.id, kind: kind})
      assert bracket_state(ctx.db, item.id) == "canceled"
      assert request(ctx.db, open.id).status == "superseded"
      assert Wakes.get(ctx.db, open.deadline_wake_id).state == "canceled"

      assert %{
               requester: "tightbeam:assignments",
               reason: "obligation_disposed",
               source_kind: "assignment_transition",
               source_id: source_assignment_id,
               outcome: "disposition",
               disposition_kind: "assignment_transition",
               disposition_id: disposition_assignment_id
             } = cancellation(ctx.db, open.deadline_wake_id)

      assert source_assignment_id == item.id
      assert disposition_assignment_id == item.id
    end

    revoked = dispatch(ctx, {:session, "parent"}, "holder", "revoked")

    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{
      assignment_id: revoked.id
    })

    assert bracket_state(ctx.db, revoked.id) == "canceled"

    retired = dispatch(ctx, {:session, "parent"}, "holder", "retired")
    retired_open = escalate(ctx, retired.id)
    generation_state_before_refusal = bracket_state(ctx.db, retired.id)

    assert generation_state_before_refusal == "probed"

    assert {:error,
            %ArgumentError{message: "retirement interruption requires a durable principal"}} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.interrupt_for_retire_in_txn(txn, "holder", "h2", nil)
             end)

    assert rows(ctx.db, "SELECT state FROM assignments WHERE id=?1", [retired.id]) == [["open"]]
    assert bracket_state(ctx.db, retired.id) == generation_state_before_refusal
    assert request(ctx.db, retired_open.id).status == "open"
    assert Wakes.get(ctx.db, retired_open.deadline_wake_id).state == "pending"

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(txn, "holder", "h2", "user:h2")
      end)

    assert bracket_state(ctx.db, retired.id) == "canceled"
    assert request(ctx.db, retired_open.id).status == "superseded"
    assert Wakes.get(ctx.db, retired_open.deadline_wake_id).state == "canceled"

    assert %{
             requester: "tightbeam:retirement",
             reason: "obligation_disposed",
             source_kind: "assignment_transition",
             source_id: retired_source_id,
             outcome: "disposition",
             disposition_kind: "assignment_transition",
             disposition_id: retired_disposition_id
           } = cancellation(ctx.db, retired_open.deadline_wake_id)

    assert retired_source_id == retired.id
    assert retired_disposition_id == retired.id
  end

  test "acceptance 4 and 5: writes are detected with no git anywhere; a stall is not effect",
       ctx do
    # Acceptance 4: this workspace has no repository under it at all. Every case
    # below is a WRITE, and none of them produces `unobservable` or a nag.
    refute File.exists?(Path.join(ctx.root, ".git"))

    modified = dispatch(ctx, {:session, "parent"}, "holder", "modified file")
    File.write!(Path.join(ctx.root, "src/tracked.txt"), "changed\n")
    assert nil == fire_probe(ctx, modified.id)
    assert silent_rearm(ctx.db, modified.id)
    assert prods(ctx.db, "holder") == []

    created = dispatch(ctx, {:session, "parent"}, "holder", "created file")
    File.write!(Path.join(ctx.root, "created.tmp"), "effect")
    assert nil == fire_probe(ctx, created.id)
    assert silent_rearm(ctx.db, created.id)

    deleted = dispatch(ctx, {:session, "parent"}, "holder", "deleted file")
    File.rm!(Path.join(ctx.root, "created.tmp"))
    assert nil == fire_probe(ctx, deleted.id)
    assert silent_rearm(ctx.db, deleted.id)

    nested = dispatch(ctx, {:session, "parent"}, "holder", "nested write")
    File.mkdir_p!(Path.join(ctx.root, "deep/deeper"))
    File.write!(Path.join(ctx.root, "deep/deeper/note.md"), "nested")
    assert nil == fire_probe(ctx, nested.id)
    assert silent_rearm(ctx.db, nested.id)

    # A repository under the root is neither required nor special: git motion is
    # only ever visible here as the writes git makes.
    git_root = Path.join(ctx.root, "repo")
    init_repo(git_root)
    committed = dispatch(ctx, {:session, "parent"}, "holder", "commit")
    File.write!(Path.join(git_root, "tracked.txt"), "committed\n")
    git!(git_root, ["add", "tracked.txt"])
    git!(git_root, ["commit", "-m", "effect"])
    assert nil == fire_probe(ctx, committed.id)
    assert silent_rearm(ctx.db, committed.id)

    # ACCEPTED MISS-CASE (documented, not fixed): an mtime-preserving copy of a
    # file that is already listed writes bytes the probe cannot see. It fails
    # SAFE — one prod, answered by an attest. A copy to a NEW path is caught by
    # the listing, so the miss needs an existing destination.
    File.write!(Path.join(ctx.root, "src/dest.txt"), "old")
    File.write!(Path.join(ctx.root, "src/source.txt"), "new bytes")
    File.touch!(Path.join(ctx.root, "src/source.txt"), 1_700_000_000)
    File.touch!(Path.join(ctx.root, "src/dest.txt"), 1_700_000_000)
    preserved = dispatch(ctx, {:session, "parent"}, "holder", "mtime-preserving copy")
    {_out, 0} = System.cmd("cp", ["-p", src(ctx, "src/source.txt"), src(ctx, "src/dest.txt")])
    assert File.read!(src(ctx, "src/dest.txt")) == "new bytes"
    assert nil == fire_probe(ctx, preserved.id)
    assert [prod] = prods(ctx.db, "holder")
    assert prod.prompt =~ "no writes, artifacts, attests, or work-item updates"

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

    request = fire_probe(ctx, stalled.id)
    assert request.context["outcome"] == "zero_effect"

    assert request.context["channels"] == %{
             "writes" => "none",
             "artifacts" => 0,
             "attests" => 0,
             "workItems" => 0
           }

    assert request.context["actions"] == [
             "wake",
             "continue",
             "dismiss",
             "revoke-assignment",
             "dispatch"
           ]

    # A replayed probe of an already-probed generation is inert.
    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, wake)

    assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [
             stalled.id
           ]) == [[1]]

    # An absent workspace is stated as a fact on the channel it belongs to, not
    # raised as its own alarm.
    missing = dispatch(ctx, {:session, "parent"}, "holder", "missing")
    File.rm_rf!(ctx.root)
    request = escalate(ctx, missing.id)
    assert request.context["outcome"] == "zero_effect"
    assert request.context["channels"]["writes"] == "unobservable"
    assert request.question =~ "workspace writes: unobservable"
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

  test "job-linked initial and deadline effort notifications stamp assignment and job", ctx do
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
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, first_deadline))

    # `assignmentId` on the notification wake is the carrier that replaced the
    # deleted explicit `assignment_id`/`job_ref` delivery opts.
    assert [assignment.id, assignment.id] ==
             Enum.map(notification_wakes(ctx.db), & &1.assignment_id)

    drain_notifications!(ctx)

    # Delivery derives the SAME attribution through `wake_attribution/2` — for
    # the agent prod that opened the bracket's first rung as well as for the two
    # owner notifications.
    assert rows(
             ctx.db,
             """
             SELECT assignmentId, jobRef
             FROM turns
             WHERE prompt LIKE '%effort check-in%'
             ORDER BY seq
             """,
             []
           ) == [
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

  test "proof 8: a busy org editing across multiple horizons emits zero visible artifacts", ctx do
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

    # A working agent is not prodded either: the prod is a rung of the alarm,
    # not a heartbeat.
    assert prods(ctx.db, "holder") == []
  end

  test "proofs 5 and 8b: continue doubles/caps, effect resets, dismiss refreshes, close supersedes",
       ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "rulings")
    first = escalate(ctx, item.id)

    assert %{status: "ruled", decision: "continue"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(first.id, "continue", {:session, "parent"})
             )

    assert %{
             requester: "tightbeam:effort-checkin",
             reason: "obligation_disposed",
             source_kind: "decision_request",
             source_id: first_source_id,
             outcome: "disposition",
             disposition_kind: "decision_request_transition",
             disposition_id: first_disposition_id,
             liveness_kind: "supervision_entitlement",
             liveness_id: first_liveness_id,
             action_needed: 1
           } = cancellation(ctx.db, first.deadline_wake_id)

    assert first_source_id == first.id
    assert first_disposition_id == first.id
    assert first_liveness_id == "#{item.id}#1"

    # The agent was prodded once at the top of this silent streak; every later
    # bracket in the same streak goes straight to the owner.
    assert current_multiplier(ctx.db, item.id) == 2
    second = fire_probe(ctx, item.id)

    EffortCheckin.rule(
      ctx.db,
      ctx.config,
      effort_call(second.id, "continue", {:session, "parent"})
    )

    assert current_multiplier(ctx.db, item.id) == 4
    third = fire_probe(ctx, item.id)

    EffortCheckin.rule(
      ctx.db,
      ctx.config,
      effort_call(third.id, "continue", {:session, "parent"})
    )

    assert current_multiplier(ctx.db, item.id) == 4

    # Effect resets the backoff AND the prod rung: a working agent that goes
    # quiet again is prodded before its owner is asked anything.
    File.write!(Path.join(ctx.root, "src/tracked.txt"), "reset\n")
    assert nil == fire_probe(ctx, item.id)
    assert current_multiplier(ctx.db, item.id) == 1

    later = escalate(ctx, item.id)
    assert later.id != first.id

    File.write!(Path.join(ctx.root, "src/tracked.txt"), "changed before dismiss\n")
    EffortCheckin.rule(ctx.db, ctx.config, effort_call(later.id, "dismiss", {:session, "parent"}))
    assert current_multiplier(ctx.db, item.id) == 1
    assert Wakes.get(ctx.db, later.deadline_wake_id).state == "canceled"

    open = escalate(ctx, item.id)
    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{assignment_id: item.id})
    assert request(ctx.db, open.id).status == "superseded"
    assert Wakes.get(ctx.db, open.deadline_wake_id).state == "canceled"

    first_sibling = dispatch(ctx, {:session, "parent"}, "holder", "holder reset A")
    second_sibling = dispatch(ctx, {:session, "parent"}, "holder", "holder reset B")
    first_request = escalate(ctx, first_sibling.id)
    second_request = escalate(ctx, second_sibling.id)

    assert %{status: "ruled", decision: "dismiss"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(first_request.id, "dismiss", {:session, "parent"})
             )

    assert request(ctx.db, second_request.id).status == "superseded"
    assert Wakes.get(ctx.db, second_request.deadline_wake_id).state == "canceled"
    assert bracket_state(ctx.db, first_sibling.id) == "armed"
    assert bracket_state(ctx.db, second_sibling.id) == "armed"
  end

  test "proofs 6, 11, 12, 13: responder preference, self/user routing, deadlines and exact menu",
       ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "session opener")
    request = escalate(ctx, item.id)

    assert request.expecter_session_key == "parent"

    assert %{status: "ruled", ruled_by: "session:holder"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(request.id, "continue", {:session, "holder"})
             )

    assert %{code: "not_authorized"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               %{effort_call(request.id, "continue", {:session, "parent"}) | principal: nil}
             )

    assert %{code: "not_open"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(request.id, "continue", {:session, "parent"})
             )

    assert %{code: "invalid"} =
             Escalation.withdraw(ctx.db, %{
               origin: "process:tightbeam",
               principal: nil,
               params: %{request_id: request.id, reason: "generic path"}
             })

    self = dispatch(ctx, {:session, "holder"}, "holder", "self")
    self_request = escalate(ctx, self.id)
    assert self_request.expecter_session_key == "parent"

    retired_parent =
      session(ctx.db, "retired-parent", "h1", Placement.local_host_name(), %{
        spawned_by: "parent"
      })

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE sessions SET state='retired' WHERE sessionKey='retired-parent'"
      )

    retired_opener =
      dispatch(ctx, {:session, retired_parent.session_key}, "holder", "retired opener")

    retired_request = escalate(ctx, retired_opener.id)
    assert retired_request.expecter_session_key == "parent"

    user_item = dispatch(ctx, {:user, "h1"}, "holder", "user")
    user_request = escalate(ctx, user_item.id)
    assert user_request.expecter_user_id == "h1"

    assert %{code: "not_authorized"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(user_request.id, "dismiss", {:user, "h2"})
             )

    assert Enum.any?(
             Escalation.list(
               ctx.db,
               %{principal: {:user, "h1"}, origin: "user:h1", params: %{}}
             ),
             &(&1.id == user_request.id)
           )

    old_deadline = user_request.deadline_wake_id
    EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, old_deadline))
    advanced = request(ctx.db, user_request.id)
    assert advanced.expecter_user_id == "h1"
    assert advanced.lineage_rung == user_request.lineage_rung
    assert advanced.deadline_wake_id != old_deadline
    EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, old_deadline))
    assert request(ctx.db, user_request.id).deadline_wake_id == advanced.deadline_wake_id

    assert %{status: "ruled"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(user_request.id, "dismiss", {:user, "h1"})
             )

    mid =
      session(ctx.db, "mid", "h1", Placement.local_host_name(), %{spawned_by: "parent"})

    chained = dispatch(ctx, {:session, mid.session_key}, "holder", "chain")
    chained_request = escalate(ctx, chained.id)
    assert chained_request.expecter_session_key == "mid"
    assert Wakes.get(ctx.db, chained_request.deadline_wake_id).state == "pending"

    EffortCheckin.deadline(
      ctx.db,
      ctx.config,
      Wakes.get(ctx.db, chained_request.deadline_wake_id)
    )

    parent_rung = request(ctx.db, chained_request.id)
    assert parent_rung.expecter_session_key == "parent"
    assert Wakes.get(ctx.db, parent_rung.deadline_wake_id).state == "pending"

    assert %{status: "ruled", ruled_by: "session:mid"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(parent_rung.id, "dismiss", {:session, "mid"})
             )

    assert %{code: "not_open"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(parent_rung.id, "dismiss", {:session, "parent"})
             )

    skipped = dispatch(ctx, {:session, mid.session_key}, "holder", "held chain")
    skipped_request = escalate(ctx, skipped.id)

    :ok =
      DB.execute(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='parent'")

    EffortCheckin.deadline(
      ctx.db,
      ctx.config,
      Wakes.get(ctx.db, skipped_request.deadline_wake_id)
    )

    assert request(ctx.db, skipped_request.id).expecter_user_id == "h1"

    :ok =
      DB.execute(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey='parent'")

    pinned = dispatch(ctx, {:session, "parent"}, "holder", "pinned")
    pinned_request = escalate(ctx, pinned.id)

    assert pinned_request.context["actions"] == [
             "wake",
             "continue",
             "dismiss",
             "revoke-assignment",
             "dispatch"
           ]

    # Rotate to H1, who does not own holder H2: each power is intersected independently.
    EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, pinned_request.deadline_wake_id))
    human = request(ctx.db, pinned_request.id)
    assert human.expecter_user_id == "h1"

    assert human.context["actions"] == ["wake", "continue", "dismiss"]

    assert %{status: "ruled", ruled_by: "session:parent"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(human.id, "continue", {:session, "parent"})
             )

    assert %{code: "not_authorized"} =
             assignment(ctx, "revoke-assignment", {:user, "h1"}, nil, %{
               assignment_id: pinned.id
             })

    assert %{code: "not_open"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(human.id, "continue", {:user, "h1"})
             )
  end

  test "two authorized delegates racing one request produce one attributed winner", ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "raced response")
    request = escalate(ctx, item.id)
    before = rows(ctx.db, "SELECT COUNT(*) FROM effort_checkin_generations", [])
    parent = self()

    contenders =
      for key <- ["parent", "holder"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              {key,
               EffortCheckin.rule(
                 ctx.db,
                 ctx.config,
                 effort_call(request.id, "continue", {:session, key})
               )}
          end
        end)
      end

    pids =
      for _ <- contenders do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(contenders, &Task.await/1)

    assert [{winner, %{status: "ruled", decision: "continue", ruled_by: actor}}] =
             Enum.filter(results, fn {_key, result} -> result[:status] == "ruled" end)

    assert actor == "session:" <> winner

    assert [{_loser, %{code: "not_open"}}] =
             Enum.filter(results, fn {_key, result} -> result[:code] == "not_open" end)

    assert request(ctx.db, request.id).ruled_by == actor

    assert rows(ctx.db, "SELECT COUNT(*) FROM effort_checkin_generations", []) ==
             Enum.map(before, fn [count] -> [count + 1] end)
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
    assert silent_rearm(ctx.db, item.id)

    failed_config = Map.put(ctx.config, :sh, fn _ -> {"ssh unavailable", 255} end)

    failed =
      assignment(%{ctx | config: failed_config}, "dispatch", {:session, "parent"}, "holder", %{
        subject: "remote failure",
        brief: "remote failure"
      })

    request = escalate(%{ctx | config: failed_config}, failed.id)
    assert request.context["channels"]["writes"] == "unobservable"
    assert request.context["outcome"] == "zero_effect"
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
    assert prod.prompt =~ "no writes, artifacts, attests, or work-item updates"
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
    assert prod.prompt =~ "no writes, artifacts, attests, or work-item updates"

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

  test "acceptance 3: silence after the prod escalates to the owner naming all four channels",
       ctx do
    item = work_item!(ctx.db, "acceptance three")

    silent = dispatch_for_item(ctx, {:session, "parent"}, "holder", "still silent", item.id)

    assert nil == fire_probe(ctx, silent.id)
    assert [_prod] = prods(ctx.db, "holder")

    request = fire_probe(ctx, silent.id)
    assert request.expecter_session_key == "parent"
    assert request.context["outcome"] == "zero_effect"
    assert request.context["agentProdded"] == true

    assert request.context["channels"] == %{
             "writes" => "none",
             "artifacts" => 0,
             "attests" => 0,
             "workItems" => 0
           }

    assert request.question =~ "The holder was prodded and stayed silent"
    assert request.question =~ "workspace writes: none"
    assert request.question =~ "artifacts recorded: 0"
    assert request.question =~ "attests: 0"
    assert request.question =~ "work-item updates: 0"

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

  test "proofs 6 and 8b: request and notification commit together and stay pending until delivered",
       ctx do
    personal_key = Org.personal_session_key("h1")
    session(ctx.db, personal_key, "h1", Placement.local_host_name())

    item = dispatch(ctx, {:session, "parent"}, "holder", "notify durability")

    # Rung one is the agent prod; the owner's request is rung two.
    :ok = EffortCheckin.probe(ctx.db, ctx.config, current_wake(ctx.db, item.id))
    :ok = EffortCheckin.probe(ctx.db, ctx.config, current_wake(ctx.db, item.id))

    [[request_id, old_deadline_id]] =
      rows(
        ctx.db,
        "SELECT id,deadlineWakeId FROM decision_requests WHERE assignmentId=?1 AND status='open'",
        [item.id]
      )

    # Proof 6: the notification committed WITH the request. Nothing has been
    # delivered — a death here still leaves the intent durable and pending.
    assert [%{state: "pending", target_gate: 0} = opened] = notification_wakes(ctx.db)
    assert opened.prompt =~ "Effort check-in #{request_id}"
    assert Wakes.get(ctx.db, old_deadline_id).state == "pending"
    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [opened.wake_id]) == [[0]]
    assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.wake_id == opened.wake_id))

    # Ordinary wake recovery surfaces it without waiting for the deadline.
    scheduler = drain_notifications!(ctx)
    assert Wakes.get(ctx.db, opened.wake_id).state == "fired"
    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [opened.wake_id]) == [[1]]
    assert Wakes.get(ctx.db, old_deadline_id).state == "pending"

    # Proof 8b: the winning deadline advance commits the new rung, its
    # replacement deadline wake, and the new-rung notification atomically.
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, old_deadline_id))
    advanced = request(ctx.db, request_id)
    assert advanced.deadline_wake_id != old_deadline_id
    assert Wakes.get(ctx.db, advanced.deadline_wake_id).state == "pending"
    assert Wakes.get(ctx.db, old_deadline_id).state == "fired"

    assert [%{state: "fired"}, %{state: "pending", target_gate: 0} = rung] =
             notification_wakes(ctx.db)

    assert rung.session_key == (advanced.expecter_session_key || personal_key)
    assert rung.prompt =~ "Effort check-in #{request_id}"

    :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, rung.wake_id).state == "fired"
    assert rows(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [rung.wake_id]) == [[1]]

    # A stale deadline replay still no-ops on deadlineWakeId mismatch: no rung
    # rotation, no third notification.
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, old_deadline_id))
    assert request(ctx.db, request_id).deadline_wake_id == advanced.deadline_wake_id
    assert Enum.map(notification_wakes(ctx.db), & &1.wake_id) == [opened.wake_id, rung.wake_id]
  end

  test "proof 10: workspace motion supersedes old evidence and re-arms on the new holder/host",
       ctx do
    bare = assignment(ctx, "assign", {:user, "h1"}, "holder", %{subject: "bare motion"})
    item = dispatch(ctx, {:session, "parent"}, "holder", "motion")
    open = escalate(ctx, item.id)

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

    assert request(ctx.db, open.id).status == "superseded"
    assert bracket_state(ctx.db, item.id) == "armed"

    replacement_wake = current_wake(ctx.db, item.id)

    assert %{
             requester: "tightbeam:effort-checkin",
             reason: "superseded",
             outcome: "replacement",
             replacement_wake_id: replacement_wake_id
           } = cancellation(ctx.db, open.deadline_wake_id)

    assert replacement_wake_id == replacement_wake.wake_id

    assert rows(ctx.db, "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1", [
             bare.id
           ]) == [[0]]

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

    reopened = escalate(%{ctx | config: moved_config}, item.id)
    assert reopened.status == "open"

    replacement = session(ctx.db, "replacement", "h2", Placement.local_host_name())

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

    assert rows(ctx.db, "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1", [
             bare.id
           ]) == [[0]]
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

  defp effort_call(id, action, principal) do
    %{
      verb: "effort-rule",
      origin: origin(principal),
      principal: principal,
      params: %{request_id: id, action: action}
    }
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

  defp current_multiplier(db, assignment_id) do
    [[multiplier]] =
      rows(
        db,
        "SELECT multiplier FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed' ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      )

    multiplier
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

  # Notification wakes are the ungated (targetGate = 0) prompt wakes.
  defp notification_wakes(db) do
    db
    |> rows("SELECT wakeId FROM wakes WHERE targetGate = 0 ORDER BY rowid", [])
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

  defp init_repo(path) do
    File.mkdir_p!(path)
    git!(path, ["init"])
    git!(path, ["config", "user.email", "test@example.invalid"])
    git!(path, ["config", "user.name", "Test"])
    File.write!(Path.join(path, "tracked.txt"), "baseline\n")
    git!(path, ["add", "tracked.txt"])
    git!(path, ["commit", "-m", "baseline"])
  end

  defp git!(path, args) do
    {_output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    :ok
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

    :ok = DB.execute(db, "UPDATE turns SET status='running' WHERE seq=#{seq}")
    :ok = Ledger.finish(db, seq, terminal)
  end
end
