defmodule Tightbeam.AssignmentHoldsRealPathTest do
  # Spec held-assignment-supervision v2 section 7, T10 (action half) and T13, on
  # real lifecycle paths: assignments, completion attests, terminal notices and
  # their completion-handoff reminders, decision requests, cannot-proceed records
  # and condition facts, delivered through the real wake scheduler. The other
  # section 7 tests live in assignment_holds_test.exs.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    Escalation,
    Gateway,
    Ledger,
    Model,
    Org,
    Wakes,
    WorkItems
  }

  # Long enough that no inactivity wake comes due while a scenario runs.
  @period_ms 3_600_000
  @far_future 9_999_999_999_999

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, _session_key}, _from, parent),
      do: {:reply, :ok, parent}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "hold-real-path-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})
    %{root: root}
  end

  test "T10 every real notice and wake of held cards matches unheld controls row for row",
       ctx do
    held = run_t10(ctx, :held)
    control = run_t10(ctx, :control)

    # Imposition left every listed pending wake pending.
    assert held.listed_after_imposition == Enum.map(held.listed, fn _ -> "pending" end)

    # Both pairs settled, and every non-inactivity row matches the control.
    assert held.cannot_proceed == [["settled", "release-fact"], ["settled", "disposed"]]
    assert held.snapshot == control.snapshot

    # The holds stayed active and kept inactivity supervision quiet throughout,
    # including after both cannot-proceed settlements; the controls resumed.
    assert held.holds == ["held", "held"]
    quiet = %{deadlines: 0, climbs: 0, prompts: 0}
    assert held.after_settlement == [quiet, quiet]
    assert held.inactivity == quiet
    assert control.holds == [nil, nil]
    assert Enum.map(control.after_settlement, & &1.deadlines) == [1, 1]
    assert control.inactivity.deadlines == 2
  end

  test "T13 a standing hold delivers every child result notice and stays quiet between them",
       ctx do
    world = start_world(ctx, "t13")
    card = assign(world, {:session, "opener"}, "holder", "standing PO card")
    hold(world, card.id, "standing")

    for n <- 1..3 do
      {_child_id, root} = complete_child(world, "standing child #{n}")
      settle(world)

      assert Wakes.get(world.db, root.wake_id).state == "fired"

      assert [%{batch_state: "delivered", delivery_wake_id: carrier}] =
               Tightbeam.NoticeBatcher.source_refs(world.db, root.wake_id)

      assert {:ok, [["holder", "delivered"]]} =
               DB.query(world.db, "SELECT sessionKey,status FROM turns WHERE wakeId=?1", [carrier])

      assert inactivity(world.db, [card.id]) == %{deadlines: 0, climbs: 0, prompts: 0}
      assert hold_kinds(world, [card.id]) == ["standing"]
    end

    stop_world(world)
  end

  # One T10 world: two cards held by the same holder, one settling its
  # cannot-proceed by release fact and one by accepted answer.
  defp run_t10(ctx, mode) do
    world = start_world(ctx, Atom.to_string(mode))
    fact_card = assign(world, {:session, "opener"}, "holder", "fact pair card")
    answer_card = assign(world, {:session, "opener"}, "holder", "answer pair card")
    cards = [fact_card.id, answer_card.id]

    # Pending at imposition: a real completion-handoff reminder for a finished
    # child and a real cannot-proceed decision wake per card, plus an explicit
    # wake and a dependency-wait wake naming each card, scheduled directly as in
    # the imposition half of T10 in assignment_holds_test.exs.
    {finished_child, finished} = complete_child(world, "finished child")
    settle(world)
    [reminder] = await_pending_reminders(world.db, finished.wake_id)

    # Nothing fires between building the pending set and imposing the holds.
    stop_supervised!({:scheduler, world.db})

    fact_cp =
      cannot_proceed(world, fact_card.id, %{
        release_fact_kind: "dependency-ready",
        release_fact_scope: fact_card.id,
        release_fact_principal_ref: "agent:holder"
      })

    answer_cp = cannot_proceed(world, answer_card.id, %{})

    explicit =
      for card <- cards,
          {origin, ref} <- [{"agent:opener", nil}, {"process:tightbeam", "dependency-wait:held"}] do
        Wakes.schedule(world.db, %{
          session_key: "holder",
          origin: origin,
          prompt: "pending #{ref || "explicit"} wake",
          assignment_id: card,
          obligation_ref: ref,
          due_at: @far_future
        })
      end

    listed =
      [reminder.wake_id, fact_cp.decisionWake.wake_id, answer_cp.decisionWake.wake_id] ++
        Enum.map(explicit, & &1.wake_id)

    if mode == :held, do: Enum.each(cards, &hold(world, &1, "held"))

    listed_after_imposition = Enum.map(listed, &Wakes.get(world.db, &1).state)
    start_scheduler(world.db)

    # Then on both: a child completes; a decision is answered; the cannot-proceed
    # settles by release fact on one card and by accepted answer on the other;
    # the completion-handoff reminder is discharged.
    complete_child(world, "second child")
    settle(world)

    question = ask(world, answer_card.id, "Which boundary should I keep?")
    settle(world)
    answer(world, question.id, {:session, "opener"})
    settle(world)

    assert {:ok, %{fact_id: _}} =
             DB.transaction(world.db, fn txn ->
               ConditionFacts.file_in_txn(txn, %{
                 kind: "dependency-ready",
                 scope: fact_card.id,
                 origin: "agent:holder"
               })
             end)

    after_fact = inactivity(world.db, [fact_card.id])
    answer(world, answer_cp.decisionRequest.id, {:user, "flynn"})
    # Sampled before delivery: a delivered turn is holder activity, which
    # re-arms (unheld) or clears (held) supervision on its own.
    after_settlement = [after_fact, inactivity(world.db, [answer_card.id])]
    settle(world)

    note = action_note(finished_child, finished, "kept", "kept the finished child")

    assert %{attest: %{kind: "progress"}} =
             handle(world, "attest", %{
               principal: {:session, "holder"},
               params: %{assignment_id: fact_card.id, kind: "progress", note: note}
             })

    assert Wakes.get(world.db, reminder.wake_id).state == "canceled"
    settle(world)

    result = %{
      listed: listed,
      listed_after_imposition: listed_after_imposition,
      cannot_proceed: cannot_proceed_states(world.db, cards),
      holds: hold_kinds(world, cards),
      after_settlement: after_settlement,
      inactivity: inactivity(world.db, cards),
      snapshot: snapshot(world.db)
    }

    stop_world(world)
    result
  end

  defp start_world(ctx, label) do
    db = :"hold_real_path_#{label}_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db}, id: db)
    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{
      "lab1" => %{ssh: nil, base_dir: Application.fetch_env!(:tightbeam, :base_dir), cli_bin: nil}
    })

    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',0,1)")
    Enum.each(~w(holder opener child), &session(db, &1))

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 60_000})
    load_law!(Path.join(ctx.root, label), Map.keys(handlers))

    scheduler = start_scheduler(db)

    item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "held supervision"}
      })

    %{db: db, handlers: handlers, scheduler: scheduler, work_item_id: item.id}
  end

  # The shipped row-reaction rules for completion handoff, terminal action and
  # assignment inactivity. Without the inactivity rule, supervision is off and a
  # hold would have nothing to suppress.
  defp load_law!(root, verbs) do
    rules = Path.join(root, "identity/rules")
    File.mkdir_p!(rules)

    for name <-
          ~w(row-reaction-handoff.toml row-reaction-terminal-action.toml row-reaction-assignment-inactivity.toml) do
      source = Path.join([:code.priv_dir(:tightbeam), "kungfu/agentic-engineering/rules", name])
      File.cp!(source, Path.join(rules, name))
    end

    Tightbeam.Rules.load!(root, verbs)
  end

  defp start_scheduler(db) do
    scheduler = Tightbeam.WakeScheduler

    start_supervised!(
      Supervisor.child_spec(
        {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: &deliver_wake(db, &1)},
        id: {:scheduler, db}
      )
    )

    scheduler
  end

  defp stop_world(world) do
    stop_supervised!({:scheduler, world.db})
    stop_supervised!(world.db)
  end

  defp assign(world, principal, target, subject) do
    handle(world, "assign", %{
      principal: principal,
      session_key: target,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: @period_ms,
      params: %{
        subject: subject,
        idempotency_key: nil,
        work_item_id: world.work_item_id,
        effect_kind: "coordination"
      }
    })
  end

  # The holder opens a child and the child completes it; returns the child's id
  # and the terminal notice the holder receives.
  defp complete_child(world, subject) do
    child = assign(world, {:session, "holder"}, "child", subject)

    assert %{attest: %{kind: "completion"}} =
             handle(world, "attest", %{
               principal: {:session, "child"},
               params: %{assignment_id: child.id, kind: "completion"}
             })

    {:ok, rows} =
      DB.query(
        world.db,
        "SELECT wakeId FROM wakes WHERE obligationRef LIKE 'terminal-child-owner-notification:%' AND prompt LIKE ?1",
        ["%" <> child.id <> "%"]
      )

    [[wake_id]] = rows
    {child.id, Wakes.get(world.db, wake_id)}
  end

  defp cannot_proceed(world, assignment_id, release) do
    handle(world, "attest", %{
      principal: {:session, "holder"},
      params:
        Map.merge(
          %{
            assignment_id: assignment_id,
            kind: "cannot-proceed",
            note: "blocked #{assignment_id}",
            release_fact_kind: nil,
            release_fact_scope: nil,
            release_fact_principal_ref: nil
          },
          release
        )
    })
  end

  defp ask(world, assignment_id, question) do
    Escalation.ask(world.db, %{
      verb: "ask",
      origin: "session:holder",
      principal: {:session, "holder"},
      session_key: "opener",
      params: %{question: question, assignment_id: assignment_id}
    })
  end

  defp answer(world, request_id, principal) do
    assert %{status: "answered"} =
             Escalation.answer(world.db, %{
               verb: "answer",
               principal: principal,
               origin: origin(principal),
               params: %{request: request_id, answer: "Proceed"}
             })
  end

  defp hold(world, assignment_id, kind) do
    assert %{kind: ^kind, releasedAt: nil} =
             world.handlers["assignment-hold"].(%{
               principal: {:user, "flynn"},
               origin: "user:flynn",
               params: %{
                 assignment_id: assignment_id,
                 kind: kind,
                 reason: "intentional pause",
                 release: "owner resumes the duty",
                 release_fact_kind: nil,
                 release_fact_scope: nil,
                 release_fact_principal_ref: nil,
                 idempotency_key: nil
               }
             })
  end

  defp handle(world, verb, call) do
    call = Map.merge(%{verb: verb, origin: origin(call.principal), session_key: nil}, call)
    Assignments.__handle__(world.db, verb, call)
  end

  # Fire due wakes and finish every delivered turn until nothing is left queued.
  defp settle(world, passes \\ 10) do
    assert :ok = Wakes.fire_due(world.scheduler)

    finished =
      for session <- ~w(holder opener child), reduce: 0 do
        count -> count + finish_queued_turns(world.db, session)
      end

    if finished > 0 and passes > 1, do: settle(world, passes - 1), else: :ok
  end

  defp finish_queued_turns(db, session, count \\ 0) do
    case Ledger.claim_next(db, session, "hold-real-path-test") do
      {:ok, %{seq: seq, owner_lease: lease}} ->
        assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: lease)
        finish_queued_turns(db, session, count + 1)

      _ ->
        count
    end
  end

  defp await_pending_reminders(db, root_id, attempts \\ 200) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE obligationRef=?1 AND state='pending' ORDER BY rowid",
        ["terminal-child-owner-action-reminder:" <> root_id]
      )

    case rows do
      [] when attempts > 0 ->
        Process.sleep(10)
        await_pending_reminders(db, root_id, attempts - 1)

      rows ->
        Enum.map(rows, fn [id] -> Wakes.get(db, id) end)
    end
  end

  defp action_note(child_id, root, action, detail) do
    fields =
      root.prompt
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> {key, value}
          [line] -> {line, nil}
        end
      end)

    [source_kind, source_token] =
      Enum.map(~w(source_kind source_token), &JSON.decode!(fields[&1]))

    "completion-handoff-action #{child_id} #{source_kind} #{source_token} #{action}: #{detail}"
  end

  defp cannot_proceed_states(db, cards) do
    Enum.map(cards, fn card ->
      {:ok, [row]} =
        DB.query(
          db,
          "SELECT state,settlementKind FROM assignment_cannot_proceed WHERE assignmentId=?1",
          [card]
        )

      row
    end)
  end

  defp hold_kinds(world, cards) do
    Enum.map(cards, fn card ->
      case world.handlers["assignment-get"].(%{
             principal: {:user, "flynn"},
             params: %{assignment_id: card, fact_id: nil}
           }) do
        %{hold: %{kind: kind}} -> kind
        %{hold: nil} -> nil
      end
    end)
  end

  defp inactivity(db, cards) do
    count = fn sql ->
      cards
      |> Enum.map(fn card ->
        {:ok, [[n]]} = DB.query(db, sql, [card])
        n
      end)
      |> Enum.sum()
    end

    %{
      deadlines:
        count.(
          "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer='assignment_inactivity_deadline' AND state='pending'"
        ),
      climbs:
        count.(
          "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer='assignment_inactivity_climb' AND state='pending'"
        ),
      prompts:
        count.(
          "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
        )
    }
  end

  # Every notice, wake, cancellation, decision, cannot-proceed record and
  # delivered turn outside inactivity supervision, in creation order, with ids
  # and clock values replaced so two databases can be compared row for row.
  defp snapshot(db) do
    outside_inactivity = """
    w.consumer NOT IN ('assignment_inactivity_deadline','assignment_inactivity_climb')
      AND COALESCE(w.obligationRef,'') NOT LIKE 'assignment-inactivity-episode-v1:%'
    """

    {:ok, wakes} =
      DB.query(
        db,
        """
        SELECT w.wakeId,w.sessionKey,w.origin,w.creatorSessionKey,w.assignmentId,w.consumer,
               w.class,w.state,w.obligationRef,w.conditionKind,w.conditionScope,w.prompt,
               CASE WHEN w.dueAt>=#{@far_future} THEN 'fixed'
                    ELSE CAST(ROUND((w.dueAt-w.createdAt)/1000.0) AS INTEGER) END,
               w.firedAt IS NOT NULL, w.deliveredTurnSeq IS NOT NULL
        FROM wakes w WHERE #{outside_inactivity} ORDER BY w.rowid
        """
      )

    {:ok, cancellations} =
      DB.query(
        db,
        """
        SELECT c.wakeId,c.reasonKind,c.causalSourceKind,c.actionNeeded,c.outcomeKind
        FROM wake_cancellations c JOIN wakes w ON w.wakeId=c.wakeId
        WHERE #{outside_inactivity} ORDER BY w.rowid
        """
      )

    {:ok, decisions} =
      DB.query(
        db,
        "SELECT id,kind,status,raiserSessionKey,expecterSessionKey,assignmentId,answer FROM decision_requests ORDER BY rowid"
      )

    {:ok, cannot_proceed} =
      DB.query(
        db,
        "SELECT assignmentId,state,settlementKind,releaseFactKind,releaseFactScope FROM assignment_cannot_proceed ORDER BY rowid"
      )

    {:ok, turns} =
      DB.query(
        db,
        "SELECT t.sessionKey,t.status,t.wakeId,t.prompt FROM turns t JOIN wakes w ON w.wakeId=t.wakeId WHERE #{outside_inactivity} ORDER BY t.seq"
      )

    normalize(%{
      wakes: wakes,
      cancellations: cancellations,
      decisions: decisions,
      cannot_proceed: cannot_proceed,
      turns: turns
    })
  end

  @id ~r/\b(?:asg|wi|att|dr|cp|w|wr|nb|nbt|fact|cf|req|msg|evt|hold)_[A-Za-z0-9_-]{6,}/
  @clock ~r/\b1[0-9]{12}\b/
  # Digests of id-bearing content, and rendered wall-clock minutes.
  @digest ~r/\b[0-9a-f]{64}\b/
  @utc ~r/\b\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC\b/

  defp normalize(snapshot) do
    {ids, _} =
      Regex.scan(@id, inspect(snapshot, limit: :infinity, printable_limit: :infinity))
      |> List.flatten()
      |> Enum.reduce({%{}, 0}, fn id, {seen, n} ->
        if Map.has_key?(seen, id), do: {seen, n}, else: {Map.put(seen, id, "<id#{n}>"), n + 1}
      end)

    Map.new(snapshot, fn {table, rows} ->
      {table,
       Enum.map(rows, fn row ->
         row
         |> inspect(limit: :infinity, printable_limit: :infinity)
         |> then(&Regex.replace(@id, &1, fn id -> Map.fetch!(ids, id) end))
         |> then(&Regex.replace(@clock, &1, "<clock>"))
         |> then(&Regex.replace(@digest, &1, "<digest>"))
         |> then(&Regex.replace(@utc, &1, "<utc>"))
       end)}
    end)
  end

  defp deliver_wake(db, wake) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        Gateway.deliver_prompt_in_txn(
          txn,
          wake.session_key,
          wake.origin,
          wake.prompt,
          wake_id: wake.wake_id,
          sender: wake.origin,
          target_gate: wake,
          fire_wake_in_txn: true
        )
      end)

    case result do
      {:staged, _} -> result
      other -> Gateway.complete_delivery(db, other)
    end
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, id}), do: "user:#{id}"

  defp session(db, key) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "lab1"
    })
  end
end
