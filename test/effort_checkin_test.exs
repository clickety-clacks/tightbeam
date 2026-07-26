defmodule Tightbeam.EffortCheckinTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Archetypes,
    Assignments,
    ConditionFacts,
    DB,
    Devices,
    EffortCheckin,
    Escalation,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Placement,
    Projection,
    Roles,
    Wakes,
    WorkItems
  }

  setup do
    db = :"effort_#{System.unique_integer([:positive])}"

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-effort-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Tightbeam.CausalEvents,
          Devices,
          ConditionFacts,
          Idempotency,
          Ledger,
          EventLog,
          Escalation,
          Wakes,
          Projection,
          Org,
          Roles,
          WorkItems,
          Assignments
        ] do
      :ok = module.ensure_schema(db)
    end

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('h1',0,1),('h2',0,1),('admin',1,1)"
      )

    host = Placement.local_host_name()
    parent = session(db, "parent", "h1", host)
    holder = session(db, "holder", "h2", host, %{spawned_by: "parent"})
    config = %{db: db, base_dir: base_dir, port: 4_321, effort_checkin_horizon_ms: 10}
    root = Placement.workdir_path(config, holder)
    init_repo(root)

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
      open = fire_probe(ctx, item.id)
      assignment(ctx, "attest", {:session, "holder"}, nil, %{assignment_id: item.id, kind: kind})
      assert bracket_state(ctx.db, item.id) == "canceled"
      assert request(ctx.db, open.id).status == "superseded"
      assert Wakes.get(ctx.db, open.deadline_wake_id).state == "canceled"
    end

    revoked = dispatch(ctx, {:session, "parent"}, "holder", "revoked")

    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{
      assignment_id: revoked.id
    })

    assert bracket_state(ctx.db, revoked.id) == "canceled"

    retired = dispatch(ctx, {:session, "parent"}, "holder", "retired")
    retired_open = fire_probe(ctx, retired.id)

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(txn, "holder", "h2")
      end)

    assert bracket_state(ctx.db, retired.id) == "canceled"
    assert request(ctx.db, retired_open.id).status == "superseded"
    assert Wakes.get(ctx.db, retired_open.deadline_wake_id).state == "canceled"
  end

  test "proofs 2, 3, 8, 8c: tracked, untracked, commit and nested effects are silent; stall/unobservable differ",
       ctx do
    tracked = dispatch(ctx, {:session, "parent"}, "holder", "tracked")
    File.write!(Path.join(ctx.root, "tracked.txt"), "changed\n")
    fire_probe(ctx, tracked.id)
    assert silent_rearm(ctx.db, tracked.id)

    untracked = dispatch(ctx, {:session, "parent"}, "holder", "untracked")
    File.write!(Path.join(ctx.root, "created.tmp"), "effect")
    fire_probe(ctx, untracked.id)
    assert silent_rearm(ctx.db, untracked.id)

    File.rm!(Path.join(ctx.root, "created.tmp"))
    staged = dispatch(ctx, {:session, "parent"}, "holder", "staged create")
    File.write!(Path.join(ctx.root, "staged.txt"), "staged effect")
    git!(ctx.root, ["add", "staged.txt"])
    fire_probe(ctx, staged.id)
    assert silent_rearm(ctx.db, staged.id)
    git!(ctx.root, ["reset", "--", "staged.txt"])
    File.rm!(Path.join(ctx.root, "staged.txt"))

    File.write!(Path.join(ctx.root, ".gitignore"), "*.ignored\n")
    git!(ctx.root, ["add", ".gitignore"])
    git!(ctx.root, ["commit", "-m", "ignore build output"])
    ignored = dispatch(ctx, {:session, "parent"}, "holder", "ignored output")
    File.write!(Path.join(ctx.root, "cache.ignored"), "coarse effect")
    fire_probe(ctx, ignored.id)
    assert silent_rearm(ctx.db, ignored.id)
    File.rm!(Path.join(ctx.root, "cache.ignored"))

    commit = dispatch(ctx, {:session, "parent"}, "holder", "commit")
    git!(ctx.root, ["add", "tracked.txt"])
    git!(ctx.root, ["commit", "-m", "effect"])
    fire_probe(ctx, commit.id)
    assert silent_rearm(ctx.db, commit.id)

    mixed_backward =
      dispatch(ctx, {:session, "parent"}, "holder", "mixed reset with identical bytes")

    git!(ctx.root, ["reset", "--mixed", "HEAD^"])
    mixed_request = fire_probe(ctx, mixed_backward.id)
    assert mixed_request.context["outcome"] == "zero_edits"
    git!(ctx.root, ["reset", "--mixed", "ORIG_HEAD"])

    git!(ctx.root, ["commit", "--allow-empty", "-m", "temporary tip"])
    backward = dispatch(ctx, {:session, "parent"}, "holder", "backward reset")
    git!(ctx.root, ["reset", "--hard", "HEAD^"])
    backward_request = fire_probe(ctx, backward.id)
    assert backward_request.context["outcome"] == "zero_edits"

    content_backward =
      dispatch(ctx, {:session, "parent"}, "holder", "backward reset with content change")

    git!(ctx.root, ["reset", "--hard", "HEAD^"])
    fire_probe(ctx, content_backward.id)
    assert silent_rearm(ctx.db, content_backward.id)

    nested_root = Path.join(ctx.root, "nested")
    init_repo(nested_root)
    nested = dispatch(ctx, {:session, "parent"}, "holder", "nested")
    File.write!(Path.join(nested_root, "tracked.txt"), "nested change")
    git!(nested_root, ["add", "tracked.txt"])
    git!(nested_root, ["commit", "-m", "inner"])
    fire_probe(ctx, nested.id)
    assert silent_rearm(ctx.db, nested.id)

    File.write!(Path.join(ctx.root, "baseline-only.tmp"), "x")
    deletion = dispatch(ctx, {:session, "parent"}, "holder", "deletion")
    File.rm!(Path.join(ctx.root, "baseline-only.tmp"))
    request = fire_probe(ctx, deletion.id)
    assert request.context["outcome"] == "zero_edits"
    assert request.question =~ "outcome: zero_edits"

    stalled = dispatch(ctx, {:session, "parent"}, "holder", "stall")
    wake = current_wake(ctx.db, stalled.id)

    for terminal <- ~w(delivered failed failed_unknown canceled) do
      terminal_turn(ctx.db, "holder", terminal)
    end

    queued_turn(ctx.db, "holder")
    request = fire_probe(ctx, stalled.id)
    assert request.context["outcome"] == "zero_edits"
    assert request.context["turnsSinceArmed"] == 3

    assert request.context["actions"] == [
             "wake",
             "continue",
             "dismiss",
             "revoke-assignment",
             "dispatch"
           ]

    assert :ok = EffortCheckin.probe(ctx.db, ctx.config, wake)

    assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [
             stalled.id
           ]) == [[1]]

    missing = dispatch(ctx, {:session, "parent"}, "holder", "missing")
    File.rm_rf!(ctx.root)
    request = fire_probe(ctx, missing.id)
    assert request.context["outcome"] == "unobservable"
    assert request.question =~ "outcome: unobservable"
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

    request = fire_probe(ctx, assignment.id)
    first_deadline = request.deadline_wake_id
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, first_deadline))

    assert rows(
             ctx.db,
             """
             SELECT assignmentId, jobRef
             FROM turns
             WHERE prompt LIKE '%Effort check-in%'
             ORDER BY seq
             """,
             []
           ) == [
             [assignment.id, item.id],
             [assignment.id, item.id]
           ]
  end

  test "dispatch replay precedes current holder placement and performs no new probe", ctx do
    calls = :counters.new(1, [])

    config =
      Map.put(ctx.config, :effort_probe, fn _session, _root, _config ->
        :counters.add(calls, 1, 1)
        {:ok, %{repos: [%{path: ".", head: "same", tracked: "same"}], untracked: []}}
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
      File.write!(Path.join(ctx.root, "tracked.txt"), "busy horizon #{horizon}\n")
      Enum.each(assignments, &fire_probe(ctx, &1.id))
    end

    assert rows(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE kind='effort'", []) == [
             [0]
           ]

    assert rows(ctx.db, "SELECT COUNT(*) FROM condition_facts", []) == [[0]]
  end

  test "proofs 5 and 8b: continue doubles/caps, effect resets, dismiss refreshes, close supersedes",
       ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "rulings")
    first = fire_probe(ctx, item.id)

    assert %{status: "ruled", decision: "continue"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(first.id, "continue", {:session, "parent"})
             )

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

    File.write!(Path.join(ctx.root, "tracked.txt"), "reset\n")
    fire_probe(ctx, item.id)
    assert current_multiplier(ctx.db, item.id) == 1

    later = fire_probe(ctx, item.id)
    assert later.id != first.id

    File.write!(Path.join(ctx.root, "tracked.txt"), "changed before dismiss\n")
    EffortCheckin.rule(ctx.db, ctx.config, effort_call(later.id, "dismiss", {:session, "parent"}))
    assert current_multiplier(ctx.db, item.id) == 1
    assert Wakes.get(ctx.db, later.deadline_wake_id).state == "canceled"

    open = fire_probe(ctx, item.id)
    assignment(ctx, "revoke-assignment", {:session, "parent"}, nil, %{assignment_id: item.id})
    assert request(ctx.db, open.id).status == "superseded"
    assert Wakes.get(ctx.db, open.deadline_wake_id).state == "canceled"

    first_sibling = dispatch(ctx, {:session, "parent"}, "holder", "holder reset A")
    second_sibling = dispatch(ctx, {:session, "parent"}, "holder", "holder reset B")
    first_request = fire_probe(ctx, first_sibling.id)
    second_request = fire_probe(ctx, second_sibling.id)

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

  test "proofs 6, 11, 12, 13: expecter authority, self/user routing, deadlines and exact menu",
       ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "session opener")
    request = fire_probe(ctx, item.id)

    assert request.expecter_session_key == "parent"

    assert %{code: "not_authorized"} =
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

    assert %{status: "ruled"} =
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
    self_request = fire_probe(ctx, self.id)
    assert self_request.expecter_session_key == "parent"

    held_parent =
      session(ctx.db, "held-parent", "h1", Placement.local_host_name(), %{
        spawned_by: "parent"
      })

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE sessions SET adjudicationHold='blocked' WHERE sessionKey='held-parent'"
      )

    held_opener =
      dispatch(ctx, {:session, held_parent.session_key}, "holder", "held opener")

    held_request = fire_probe(ctx, held_opener.id)
    assert held_request.expecter_session_key == "parent"

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

    retired_request = fire_probe(ctx, retired_opener.id)
    assert retired_request.expecter_session_key == "parent"

    user_item = dispatch(ctx, {:user, "h1"}, "holder", "user")
    user_request = fire_probe(ctx, user_item.id)
    assert user_request.expecter_user_id == "h1"

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
    chained_request = fire_probe(ctx, chained.id)
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

    assert %{code: "not_authorized"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(parent_rung.id, "dismiss", {:session, "mid"})
             )

    assert %{status: "ruled"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(parent_rung.id, "dismiss", {:session, "parent"})
             )

    skipped = dispatch(ctx, {:session, mid.session_key}, "holder", "held chain")
    skipped_request = fire_probe(ctx, skipped.id)

    :ok =
      DB.execute(ctx.db, "UPDATE sessions SET adjudicationHold='held' WHERE sessionKey='parent'")

    EffortCheckin.deadline(
      ctx.db,
      ctx.config,
      Wakes.get(ctx.db, skipped_request.deadline_wake_id)
    )

    assert request(ctx.db, skipped_request.id).expecter_user_id == "h1"

    :ok =
      DB.execute(ctx.db, "UPDATE sessions SET adjudicationHold=NULL WHERE sessionKey='parent'")

    pinned = dispatch(ctx, {:session, "parent"}, "holder", "pinned")
    pinned_request = fire_probe(ctx, pinned.id)

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

    assert %{code: "not_authorized"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(human.id, "continue", {:session, "parent"})
             )

    assert %{code: "not_authorized"} =
             assignment(ctx, "revoke-assignment", {:user, "h1"}, nil, %{
               assignment_id: pinned.id
             })

    assert %{status: "ruled"} =
             EffortCheckin.rule(
               ctx.db,
               ctx.config,
               effort_call(human.id, "continue", {:user, "h1"})
             )
  end

  test "proof 7: placement satellite probe is bounded and SSH failure is unobservable", ctx do
    satellite = %{ctx.holder | host: "satellite"}
    prior_hosts = Application.get_env(:tightbeam, :hosts)

    on_exit(fn ->
      if prior_hosts,
        do: Application.put_env(:tightbeam, :hosts, prior_hosts),
        else: Application.delete_env(:tightbeam, :hosts)
    end)

    Application.put_env(:tightbeam, :hosts, %{
      "satellite" => %{ssh: "satellite.example", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    test_pid = self()

    remote_config =
      Map.put(ctx.config, :sh, fn invocation ->
        send(test_pid, {:probe_invocation, invocation})
        {"R\t.\thead\ttracked\nU\tnew.txt\n", 0}
      end)

    assert {:ok,
            %{
              repos: [%{path: ".", head: "head", tracked: "tracked"}],
              untracked: ["new.txt"]
            }} = Placement.effort_manifest(remote_config, satellite, "/satellite/work")

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
                      _
                    ]}

    failed_remote = Map.put(ctx.config, :sh, fn _ -> {"ssh unavailable", 255} end)

    assert {:error, reason} =
             Placement.effort_manifest(failed_remote, satellite, "/satellite/work")

    assert reason =~ "ssh unavailable"

    raising_remote = Map.put(ctx.config, :sh, fn _ -> raise "ssh exploded" end)

    assert {:error, raised_reason} =
             Placement.effort_manifest(raising_remote, satellite, "/satellite/work")

    assert raised_reason =~ "ssh exploded"

    hung_remote =
      ctx.config
      |> Map.put(:effort_probe_timeout_ms, 20)
      |> Map.put(:sh, fn _ -> receive do: (:never -> {"", 0}) end)

    assert {:error, "probe timed out"} =
             Placement.effort_manifest(hung_remote, satellite, "/satellite/work")

    :ok = DB.execute(ctx.db, "UPDATE sessions SET host='satellite' WHERE sessionKey='holder'")
    calls = :counters.new(1, [])

    changing_remote =
      Map.put(ctx.config, :sh, fn _invocation ->
        :counters.add(calls, 1, 1)
        n = :counters.get(calls, 1)
        head = if n == 1, do: "baseline", else: "changed"
        new_commit = if n == 1, do: "0", else: "1"
        {"R\t.\t#{head}\ttracked\t#{new_commit}\n", 0}
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

    request = fire_probe(%{ctx | config: failed_config}, failed.id)
    assert request.context["outcome"] == "unobservable"
  end

  test "proof 8d: pre-change wakes and requests rebuild and preserve rows" do
    db = :"effort_migration_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db}, id: {:migration, db})

    :ok =
      DB.execute(
        db,
        """
        CREATE TABLE wakes (
          wakeId TEXT PRIMARY KEY, sessionKey TEXT NOT NULL, targetRole TEXT,
          origin TEXT NOT NULL, prompt TEXT NOT NULL, dueAt INTEGER NOT NULL,
          state TEXT NOT NULL, createdAt INTEGER NOT NULL, firedAt INTEGER,
          reresolve TEXT, reresolveSeed TEXT, reresolveRung INTEGER,
          conditionKind TEXT, conditionScope TEXT, conditionAfterId INTEGER,
          firedBy TEXT, creatorSessionKey TEXT, rumination INTEGER NOT NULL DEFAULT 0,
          work_item_id TEXT
        );
        INSERT INTO wakes (wakeId,sessionKey,origin,prompt,dueAt,state,createdAt)
          VALUES ('old-wake','holder','agent:parent','old prompt',9,'pending',1);
        CREATE TABLE decision_requests (
          id TEXT PRIMARY KEY, raiserId TEXT NOT NULL, raiserSessionKey TEXT,
          ownerUserId TEXT NOT NULL, assignmentId TEXT, raisedAt INTEGER NOT NULL,
          deadlineAt INTEGER NOT NULL, statuteName TEXT NOT NULL, actionKey TEXT NOT NULL,
          question TEXT NOT NULL, options TEXT, context TEXT NOT NULL, status TEXT NOT NULL,
          decision TEXT, rationale TEXT, ruledBy TEXT, ruledAt INTEGER, rulingFactId INTEGER,
          consumedAt INTEGER, parkWakeId TEXT, withdrawnBy TEXT, withdrawnReason TEXT,
          withdrawnAt INTEGER
        );
        INSERT INTO decision_requests
          (id,raiserId,ownerUserId,raisedAt,deadlineAt,statuteName,actionKey,question,context,status)
          VALUES ('old-request','session:parent','h1',1,2,'old-statute','digest','why','{}','open');
        """
      )

    assert :ok = Wakes.ensure_schema(db)
    assert :ok = Escalation.ensure_schema(db)
    assert %{consumer: "prompt", prompt: "old prompt"} = Wakes.get(db, "old-wake")

    assert rows(db, "SELECT kind,status FROM decision_requests WHERE id='old-request'", []) == [
             ["statute", "open"]
           ]
  end

  test "proofs 6 and 8b: commits survive crashes before request and deadline notifications",
       ctx do
    item = dispatch(ctx, {:session, "parent"}, "holder", "notify crash")
    probe_wake = current_wake(ctx.db, item.id)
    crash = Map.put(ctx.config, :effort_notify, fn _request -> exit(:notify_crash) end)

    assert catch_exit(EffortCheckin.probe(ctx.db, crash, probe_wake)) == :notify_crash

    [[request_id, old_deadline_id]] =
      rows(
        ctx.db,
        "SELECT id,deadlineWakeId FROM decision_requests WHERE assignmentId=?1 AND status='open'",
        [item.id]
      )

    assert Wakes.get(ctx.db, old_deadline_id).state == "pending"

    surface =
      Map.put(ctx.config, :effort_notify, fn surfaced ->
        send(self(), {:surfaced, surfaced.id, surfaced.deadline_wake_id})
      end)

    :ok = EffortCheckin.deadline(ctx.db, surface, Wakes.get(ctx.db, old_deadline_id))
    first_advanced = request(ctx.db, request_id)
    assert_receive {:surfaced, ^request_id, first_deadline}
    assert first_deadline == first_advanced.deadline_wake_id

    second = dispatch(ctx, {:session, "parent"}, "holder", "deadline notify crash")
    second_request = fire_probe(ctx, second.id)
    second_old_deadline = second_request.deadline_wake_id

    assert catch_exit(
             EffortCheckin.deadline(ctx.db, crash, Wakes.get(ctx.db, second_old_deadline))
           ) == :notify_crash

    advanced = request(ctx.db, second_request.id)
    assert advanced.deadline_wake_id != second_old_deadline
    assert Wakes.get(ctx.db, advanced.deadline_wake_id).state == "pending"

    :ok =
      EffortCheckin.deadline(
        ctx.db,
        surface,
        Wakes.get(ctx.db, advanced.deadline_wake_id)
      )

    assert_receive {:surfaced, surfaced_id, next_deadline}
    assert surfaced_id == second_request.id
    assert next_deadline == request(ctx.db, second_request.id).deadline_wake_id

    :ok = EffortCheckin.deadline(ctx.db, surface, Wakes.get(ctx.db, second_old_deadline))
    refute_receive {:surfaced, _, _}
  end

  test "proof 10: workspace motion supersedes old evidence and re-arms on the new holder/host",
       ctx do
    bare = assignment(ctx, "assign", {:user, "h1"}, "holder", %{subject: "bare motion"})
    item = dispatch(ctx, {:session, "parent"}, "holder", "motion")
    open = fire_probe(ctx, item.id)

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

    prior_hosts = Application.get_env(:tightbeam, :hosts)

    on_exit(fn ->
      if prior_hosts,
        do: Application.put_env(:tightbeam, :hosts, prior_hosts),
        else: Application.delete_env(:tightbeam, :hosts)
    end)

    Application.put_env(:tightbeam, :hosts, %{
      "satellite" => %{ssh: "satellite.example", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    test_pid = self()
    race = :counters.new(1, [])

    sh = fn invocation ->
      if String.contains?(Enum.join(invocation, " "), "dotgits=") do
        :counters.add(race, 1, 1)

        if :counters.get(race, 1) == 1 do
          raced = dispatch(ctx, {:session, "parent"}, "holder", "concurrent motion dispatch")
          send(test_pid, {:raced_assignment, raced.id})
        end

        {"R\t.\tremote-head\tremote-tracked\n", 0}
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

    reopened = fire_probe(%{ctx | config: moved_config}, item.id)
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

  defp assignment(ctx, verb, principal, holder, params) do
    call = %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      params: params,
      effort_config: ctx.config
    }

    Assignments.__handle__(ctx.db, verb, call)
  end

  defp fire_probe(ctx, assignment_id) do
    wake = current_wake(ctx.db, assignment_id)
    :ok = EffortCheckin.probe(ctx.db, ctx.config, wake)

    case rows(
           ctx.db,
           "SELECT id FROM decision_requests WHERE kind='effort' AND assignmentId=?1 ORDER BY rowid DESC LIMIT 1",
           [assignment_id]
         ) do
      [[id]] -> request(ctx.db, id)
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
        decision
      ]
    ] =
      rows(
        db,
        "SELECT id,kind,assignmentId,expecterSessionKey,expecterUserId,lineageRung,effortGeneration,deadlineWakeId,question,options,context,status,decision FROM decision_requests WHERE id=?1",
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
      decision: decision
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

  defp silent_rearm(db, assignment_id) do
    rows(db, "SELECT COUNT(*) FROM decision_requests WHERE assignmentId=?1", [assignment_id]) == [
      [0]
    ] and
      rows(
        db,
        "SELECT generation,multiplier,state FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      ) == [[2, 1, "armed"]]
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
          model: "fable",
          host: host
        },
        overrides
      )
    )
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
